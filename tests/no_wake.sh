#!/usr/bin/env bash
# tests/no_wake.sh — `aimail send --no-wake`: a notice that is delivered but never wakes the seat by
# itself. Driven through the real bin/aimail in a throwaway state root. Bounded real pollers (a 4-second
# `timeout`) prove the wake predicate; function-level arms read the header and the count directly.
# Runs standalone (`bash tests/no_wake.sh`) and inside tests/run.sh.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AIMAIL_ROOT="$T/root" AIMAIL_CONFIG="$T/aimail.conf"
# the operator's shell is not part of the fixture: drop every inherited AIMAIL_* knob first
# shellcheck source=./lib_env.sh
source "$REPO/tests/lib_env.sh"; test_env_sanitize
export AIMAIL_STERILITY_TERMS="" AIMAIL_SUPERVISOR="sup" AIMAIL_SEND_IDENTITY_CHECK=0
export AIMAIL_ASK_STALE=2 AIMAIL_ASK_CHECK_TIMEOUT=5 AIMAIL_POLL_INTERVAL=1 AIMAIL_POLL_DEPRECATION_QUIET=1
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AIMAIL_POLL_HEARTBEAT_SEC
mkdir -p "$AIMAIL_ROOT"; printf 'AIMAIL_ROOT="%s"\n' "$AIMAIL_ROOT" > "$AIMAIL_CONFIG"
# shellcheck source=/dev/null
source "$REPO/lib/core.sh"; source "$REPO/lib/mail.sh"   # in this shell, so the arms below count in the totals
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  ✖ %s (expected %s, got %s)\n' "$1" "$3" "$2"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
send() { # <to> <subject> [flags...]  (body is the subject text)
  local to="$1" subj="$2"; shift 2
  printf 'body of %s\n' "$subj" > "$T/body.md"
  "$AIMAIL" send --to "$to" --from sup --subject "$subj" --body-file "$T/body.md" "$@" >/dev/null 2>&1
}
inbox_n() { find "$AIMAIL_ROOT/mail/$1" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' '; }
# poll_for <seat> : a bounded real poller; prints its output, rc in $POLL_RC
poll_for() { timeout 4 "$AIMAIL" poll "$1" > "$T/poll.out" 2>&1; echo $? > "$T/poll.rc"; cat "$T/poll.out"; }
POLL_RC() { cat "$T/poll.rc"; }
fresh() { rm -rf "$AIMAIL_ROOT/mail/$1" "$AIMAIL_ROOT/state/shown/$1" "$AIMAIL_ROOT/state/last_delivered/$1"; mkdir -p "$AIMAIL_ROOT/mail/$1/unacked"; }
for s in sup alpha beta; do "$AIMAIL" seat add "$s" "fixture $s" >/dev/null 2>&1; done

section "send --help"
H="$("$AIMAIL" send --help 2>&1)"
check "help describes --no-wake in its own entry" "$(grep -c -- '^  --no-wake ' <<<"$H")" 1
check "help describes --wake in its own entry"    "$(grep -c -- '^  --wake ' <<<"$H")" 1
check "the usage line shows both flags"           "$(grep -c -- '^usage:.*--no-wake.*--wake' <<<"$H")" 1

section "header: only a --no-wake mail carries the held marker"
send alpha "plain mail"
send alpha "held notice" --no-wake
F_PLAIN="$(grep -l '^subject: plain mail$' "$AIMAIL_ROOT"/mail/alpha/*.md)"
F_HELD="$(grep -l '^subject: held notice$' "$AIMAIL_ROOT"/mail/alpha/*.md)"
check "a plain mail has no wake: no header" "$(grep -c '^wake: no$' "$F_PLAIN")" 0
check "a --no-wake mail has the wake: no header" "$(grep -c '^wake: no$' "$F_HELD")" 1
check "both are delivered into the inbox" "$(inbox_n alpha)" 2
send alpha "forced notice" --no-wake --wake
F_FORCED="$(grep -l '^subject: forced notice$' "$AIMAIL_ROOT"/mail/alpha/*.md)"
check "--wake given with --no-wake overrides it (no held header)" "$(grep -c '^wake: no$' "$F_FORCED")" 0
send alpha "reversed order" --wake --no-wake
F_REV="$(grep -l '^subject: reversed order$' "$AIMAIL_ROOT"/mail/alpha/*.md)"
check "--wake wins whichever order the flags come in" "$(grep -c '^wake: no$' "$F_REV")" 0

section "wake predicate: a held notice alone does not wake; counting"
fresh beta
send beta "only a notice" --no-wake
check "pending-wake count ignores the held notice (inbox has $(inbox_n beta))" "$(mail_pending_wake_count beta)" 0
mail_has_held beta; check "the held notice is still reported as held" "$?" 0
OUT="$(poll_for beta)"
check "a real poller does NOT wake on a --no-wake mail alone (still running at the timeout)" "$(POLL_RC)" 124
check "  ...and printed no WAKE line" "$(grep -c '^WAKE=' <<<"$OUT")" 0
check "  ...and the notice is still waiting in the inbox" "$(inbox_n beta)" 1

section "a held notice rides the next real wake, in full, with the normal mail"
send beta "normal mail"
check "pending-wake count is 1 once a normal mail arrives" "$(mail_pending_wake_count beta)" 1
OUT="$(poll_for beta)"
check "the poller wakes on the normal mail" "$(grep -c '^WAKE=mail' <<<"$OUT")" 1
check "  ...the normal mail is printed in full" "$(grep -c 'body of normal mail' <<<"$OUT")" 1
check "  ...the held notice is printed in full on the same wake" "$(grep -c 'body of only a notice' <<<"$OUT")" 1
check "  ...both moved to unacked/, nothing left in the inbox" "$(inbox_n beta)" 0
OUT2="$("$AIMAIL" deliver beta 2>&1)"
check "the shown-once rule is unchanged: a second delivery prints neither body again" "$(grep -c 'body of' <<<"$OUT2")" 0
check "  ...both are summary lines until acked" "$(grep -c 'previously-shown message(s) remain UN-ACKED' <<<"$OUT2")" 1

section "a --wake mail wakes the seat"
fresh beta
send beta "urgent" --no-wake --wake
OUT="$(poll_for beta)"
check "a mail sent with --no-wake --wake wakes the poller" "$(grep -c '^WAKE=mail' <<<"$OUT")" 1

section "the marker is a header, not a body line"
fresh beta
printf 'wake: no\nthis body merely contains the marker text\n' > "$T/body.md"
"$AIMAIL" send --to beta --from sup --subject "body mentions marker" --body-file "$T/body.md" >/dev/null 2>&1
check "a body line 'wake: no' does not hold a normal mail" "$(mail_pending_wake_count beta)" 1

section "heartbeat wake delivers held notices"
fresh beta
send beta "held for the heartbeat" --no-wake
OUT="$(AIMAIL_POLL_HEARTBEAT_SEC=1 timeout 6 "$AIMAIL" poll beta 2>&1)"
check "the heartbeat wake fires" "$(grep -c '^WAKE=heartbeat' <<<"$OUT")" 1
check "  ...and prints the held notice in full" "$(grep -c 'body of held for the heartbeat' <<<"$OUT")" 1

section "built-in notices are sent no-wake"
fresh sup; fresh alpha
ID="$("$AIMAIL" ask add --owner alpha --quote "ship the widget" --next "build" --check "test -f $T/never" 2>/dev/null | tail -1)"
f="$AIMAIL_ROOT/state/asks.tsv"
awk -F'\t' -v OFS='\t' -v id="$ID" -v ts="$(( $(date +%s) - 60 ))" 'NR==1{print;next} $1==id{$9=ts} {print}' "$f" > "$f.t" && mv -f "$f.t" "$f"
"$AIMAIL" ask sweep >/dev/null 2>&1
S_FILE="$(grep -l "^subject: STALE ask $ID" "$AIMAIL_ROOT"/mail/sup/*.md 2>/dev/null | head -1)"
check "the stale-ask alert to the supervisor exists" "$([[ -n "$S_FILE" ]] && echo 1 || echo 0)" 1
check "  ...and carries the no-wake header" "$([[ -n "$S_FILE" ]] && grep -c '^wake: no$' "$S_FILE" || echo 0)" 1
A_FILE="$(grep -l "^subject: STALE ask $ID" "$AIMAIL_ROOT"/mail/alpha/*.md 2>/dev/null | head -1)"
check "  ...and so does the copy to the owning seat" "$([[ -n "$A_FILE" ]] && grep -c '^wake: no$' "$A_FILE" || echo 0)" 1

# The classification itself is pinned: each automatic sender is named here with the wake decision it was
# given, so a new or changed sender cannot silently flip a notice into a wake or a wake into a notice.
sender_has_flag() { # <file> <subject-fragment> -> 1 if the mail_send call naming it carries --no-wake
  grep -B3 -A1 -- "$2" "$REPO/lib/$1" | grep -q -- '--no-wake' && echo 1 || echo 0
}
for spec in "ask.sh|STALE ask" "warnings.sh|BUDGET CROSSING" "balance.sh|BUDGET PRESSURE" \
            "budget.sh|BUDGET: \$seat crossed" "budget.sh|Migration recommendation" \
            "fleet.sh|SWEEP: disk/worktree" "fleet.sh|SWEEP: idle capacity" "handover.sh|WEEKLY-CAP MOVE DONE"; do
  check "notice sender '${spec#*|}' is no-wake" "$(sender_has_flag "${spec%%|*}" "${spec#*|}")" 1
done
for spec in "budget.sh|CHECKPOINT write ROLE.md" "seatmigrate.sh|MIGRATION in" "watchdog.sh|SUPERVISOR UNREACHABLE" \
            "watchdog.sh|WITH pending mail" "watchdog.sh|TWO live" "fleet.sh|SWEEP: \$seat is" "pressure.sh|PRESSURE \${lvl}" \
            "budget.sh|AUTOPILOT BLIND" "handover.sh|WEEKLY CAP on"; do
  check "action-needed sender '${spec#*|}' still wakes" "$(sender_has_flag "${spec%%|*}" "${spec#*|}")" 0
done

echo; printf 'no_wake: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
