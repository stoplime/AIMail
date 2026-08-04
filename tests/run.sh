#!/usr/bin/env bash
# tests/run.sh — dependency-free test harness.
#
# ═══ THE EVIDENCE RULES THIS HARNESS ENFORCES ═════════════════════════════════
# These are the fleet's standing rules, encoded rather than written down:
#
#  ① SHOW THE ARM FAILING FIRST. A check that isn't running looks exactly like a
#    check that passes. Every guard here is exercised with an input that MUST
#    trip it.
#
#  ② EVERY REJECTION ARM NEEDS A POSITIVE CONTROL, and the control must use a
#    form the instrument claims to detect. A quiet control may simply not
#    qualify — proving nothing while looking rigorous.
#
#  ③ AND CONTROL THE OTHER DIRECTION TOO. An always-refusing guard never fires
#    on the case it was built for, which is the dangerous direction. So every
#    `refuses` test is paired with an `accepts` test on the nearest valid input.
#
#  ④ PRINT THE DENOMINATOR. The summary reports pass/total, never just failures.
#
#  ⑤ CAPTURE THE EXIT CODE OUT OF ANY PIPE. Nothing here pipes a command whose
#    status is the measurement.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
AIMAIL="$REPO/bin/aimail"

PASS=0; FAIL=0; declare -a FAILURES=()

# Isolated data root per run — the tests can never touch a real mailbox.
# ⚠ The predecessor's test suite once wrote ~190 fabricated rows into the live
#   billing ledger, because the script derived its state path from its own
#   location and offered no override. Isolation here is by construction: the
#   root is an env var the tests set to a temp dir.
export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-test.XXXXXX")"
export AIMAIL_CONFIG=/dev/null
trap 'rm -rf "$AIMAIL_ROOT"' EXIT

_run() { "$AIMAIL" "$@" >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; echo $?; }

# accepts <desc> -- <cmd…>   : must exit 0
accepts() {
  local desc="$1"; shift; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "0" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc)"); printf '  ✖ %s — exit %s\n' "$desc" "$rc"
       sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6; fi
}

# refuses <desc> <expect-substring> -- <cmd…> : must exit 3 AND explain
# ⚠ The substring matters. A test that only asserts "nonzero" passes when the
#   tool fails for an unrelated reason — the guard could be absent entirely.
refuses() {
  local desc="$1" expect="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "3" ]] && grep -qiF -- "$expect" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc, wanted 3 + '$expect')")
    printf '  ✖ %s — exit %s, wanted 3 containing %s\n' "$desc" "$rc" "'$expect'"
    sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
  fi
}

# unmeasurable_test <desc> <expect> -- <cmd…> : must exit 4, distinctly from 3.
# ⚠ 3 and 4 are deliberately different exits. "You asked wrongly" (REFUSED) and
#   "I could not measure" (UNMEASURABLE) are different claims, and collapsing
#   them is how "unmeasurable" ends up rendering as "clean".
unmeasurable_test() {
  local desc="$1" expect="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "4" ]] && grep -qiF -- "$expect" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc, wanted 4 + '$expect')")
    printf '  ✖ %s — exit %s, wanted 4 containing %s\n' "$desc" "$rc" "'$expect'"
    sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ══════════════════════════════════════════════════════════════════════════════
section "registry — the address space"
accepts "register a seat"                      -- seat add main "General work"
accepts "register a seat with an alias"        -- seat add metrics-report "Metrics" "metrics,metr"
accepts "list seats"                           -- seat list

# ① the arm failing first — the exact defect that motivated the registry
refuses "unregistered name is refused" "not a registered seat" \
  -- send --to metrcs --from main --subject x --body-file /etc/hostname
# ③ …and the other direction: the near-miss real name still works
accepts "the real seat still accepts mail" \
  -- send --to metrics-report --from main --subject x --body-file /etc/hostname
# ② positive control in the form the tool claims to detect: an ALIAS resolves
accepts "a registered alias resolves"          -- seat resolve metrics
refuses "an invalid seat name is refused" "not a valid seat name" -- seat add "ALL:"
accepts "register a seat that will be retired"  -- seat add oldseat "To be retired"
accepts "retire it, naming a successor"         -- seat retire oldseat main
refuses "a retired seat refuses mail" "RETIRED" \
  -- send --to oldseat --from main --subject x --body-file /etc/hostname

section "registry — a refusal must name the seat you meant"
# ⚠ A guard that refuses without naming the alternative is a wall, not a guard.
#   `metrcs` -> `metrics-report` is edit distance 8 against the full name,
#   so a naive threshold misses the exact case this registry was built for.
accepts "register the seats the real typos target"  -- seat add review "Review"
for t in metrcs reveiw; do
  rc="$(_run seat resolve "$t")"
  want="$([[ $t == metrcs ]] && echo metrics-report || echo review)"
  if [[ "$rc" == "3" ]] && grep -qF "$want" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s refuses and suggests %s\n' "$t" "$want"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$t did not suggest $want")
    printf '  ✖ %s did not suggest %s (exit %s)\n' "$t" "$want" "$rc"
  fi
done
# ③ the other direction — the suggester must NOT match everything, or a
#    suggestion carries no information at all.
rc="$(_run seat resolve totallyunrelated)"
if [[ "$rc" == "3" ]] && grep -qF "no similar registered names" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ an unrelated name suggests nothing\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("suggester matched an unrelated name")
  printf '  ✖ suggester matched an unrelated name\n'
fi

section "send — the body is never touched by the shell"
BODY="$AIMAIL_ROOT/body.md"
printf '# real body\n\n```\ncode\n```\n' > "$BODY"
accepts "a balanced body sends"                -- send --to main --from main --subject "ok" --body-file "$BODY"

# ① FI-06: the corruption signature — an unclosed fence
printf '# gutted\n\n```\ncode that never closes\n' > "$AIMAIL_ROOT/bad.md"
refuses "unbalanced code fence is refused" "UNCLOSED" \
  -- send --to main --from main --subject "bad" --body-file "$AIMAIL_ROOT/bad.md"
# ③ …but --force still allows it, so the guard cannot become a permanent block
accepts "--force overrides the fence check" \
  -- send --to main --from main --subject "bad" --body-file "$AIMAIL_ROOT/bad.md" --force

refuses "--body string argument does not exist" "no --body string argument" \
  -- send --to main --from main --subject x --body "inline"
refuses "a caller-supplied timestamp is refused" "may not supply a timestamp" \
  -- send --to main --from main --subject x --body-file "$BODY" --date 2026-01-01
refuses "missing --from is refused" "--from is required" \
  -- send --to main --subject x --body-file "$BODY"
refuses "an unknown flag is refused, not ignored" "unknown argument" \
  -- send --to main --from main --subject x --body-file "$BODY" --cc other

section "broadcast — N recipients means N files, and pronouns need a referent"
printf 'Your claim about the gate was wrong.\n' > "$AIMAIL_ROOT/pron.md"
refuses "second person in a broadcast is refused" "second-person pronouns" \
  -- send --to main --to metrics-report --from main --subject x --body-file "$AIMAIL_ROOT/pron.md"
printf 'The gate claim was wrong; nobody in the chain read it.\n' > "$AIMAIL_ROOT/third.md"
accepts "the same claim in third person broadcasts" \
  -- send --to main --to metrics-report --from main --subject x --body-file "$AIMAIL_ROOT/third.md"
accepts "second person to ONE seat is fine" \
  -- send --to main --from main --subject x --body-file "$AIMAIL_ROOT/pron.md"

section "delivery state machine — archive is unreachable by delivery"
accepts "deliver moves inbox → unacked"        -- deliver main
UNACKED=$(find "$AIMAIL_ROOT/mail/main/unacked" -name '*.md' | wc -l)
ARCHIVED=$(find "$AIMAIL_ROOT/mail/main/archive" -name '*.md' 2>/dev/null | wc -l)
if (( UNACKED > 0 && ARCHIVED == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ delivery did NOT archive (%s un-acked, %s archived)\n' "$UNACKED" "$ARCHIVED"
else
  FAIL=$((FAIL+1)); FAILURES+=("delivery reached archive/ without an ack")
  printf '  ✖ delivery reached archive/: %s un-acked, %s archived\n' "$UNACKED" "$ARCHIVED"
fi
accepts "un-acked mail re-surfaces on the next deliver" -- deliver main
if grep -q '📬' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ re-delivery re-printed the un-acked mail\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("un-acked mail was not re-printed")
  printf '  ✖ un-acked mail was not re-printed\n'
fi
accepts "ack archives it"                      -- ack main --all
ARCHIVED=$(find "$AIMAIL_ROOT/mail/main/archive" -name '*.md' | wc -l)
if (( ARCHIVED > 0 )); then PASS=$((PASS+1)); printf '  ✔ ack archived %s message(s) into a month shard\n' "$ARCHIVED"
else FAIL=$((FAIL+1)); FAILURES+=("ack did not archive"); printf '  ✖ ack did not archive\n'; fi

section "where — a state, never a count"
accepts "where finds an archived message"      -- where main ok
# ⛔ The distinction this asserts is the whole point: `ls | wc -l` returns 0 both
#    when mail was delivered-and-consumed and when it was NEVER WRITTEN. Those
#    are opposite facts, and the previous system reported the second as the
#    first. A miss must exit 4 (UNMEASURABLE), never 0 with a count of zero.
unmeasurable_test "a message that never existed is UNMEASURABLE, not 0" "never written to this seat" \
  -- where main zzz-no-such-message

section "dispatcher — unknown verbs are refused"
refuses "unknown command is refused" "unknown command"      -- frobnicate
refuses "unknown seat subcommand is refused" "unknown 'seat' subcommand" -- seat frobnicate

section "fleet — the distinction a process count cannot make"
# ⛔ THE DEFECT UNDER TEST: a poller is DOWN both when a seat is mid-turn reading
#    its mail (normal — do not nudge) and when it was killed (needs a human).
#    `ps` cannot tell those apart. The exit record can, and these four arms prove
#    it does — including the two that must NOT alarm, because an instrument that
#    alarms on everything is as useless as one that alarms on nothing.
_hb() {  # _hb <seat> <key=value>…
  local seat="$1"; shift
  mkdir -p "$AIMAIL_ROOT/state/poller"
  : > "$AIMAIL_ROOT/state/poller/$seat.hb"
  local kv; for kv in "$@"; do
    printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$AIMAIL_ROOT/state/poller/$seat.hb"
  done
}
_fleet_says() {  # _fleet_says <seat> <expected-state> <desc>
  "$AIMAIL" fleet "$1" > "$AIMAIL_ROOT/.out" 2>&1
  if grep -qE "^$1 +$2" "$AIMAIL_ROOT/.out"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$3"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$3")
    printf '  ✖ %s — got: %s\n' "$3" "$(grep -E "^$1 " "$AIMAIL_ROOT/.out" | head -1)"
  fi
}
NOW=$(date +%s)
# ① the seat fired and is reading its mail — the false alarm we are killing
_hb main pid=999999 started=$((NOW-600)) beat=$((NOW-10)) exit_at=$((NOW-5)) exit_reason=mail
_fleet_says main "RE-ARMING" "a poller that exited delivering mail reads as RE-ARMING, not down"
# ③ the other direction — the SAME absent process, but killed, must still alarm
_hb main pid=999999 started=$((NOW-600)) beat=$((NOW-600))
_fleet_says main "CRASHED"   "no exit record + no process reads as CRASHED"
# ② positive control: a live, beating poller
_hb main pid=$$ started=$((NOW-600)) beat=$NOW
_fleet_says main "ARMED"     "a live beating poller reads as ARMED"
# and the grace boundary must actually expire, or RE-ARMING would mask a stall
_hb main pid=999999 started=$((NOW-9000)) beat=$((NOW-9000)) exit_at=$((NOW-9000)) exit_reason=mail
_fleet_says main "STALLED"   "an exit older than the grace window reads as STALLED"
rm -f "$AIMAIL_ROOT/state/poller/main.hb"

section "migrate — import without touching the source"
SRC="$AIMAIL_ROOT/oldbox"
mkdir -p "$SRC/legacy/archive"
printf 'old mail\n' > "$SRC/legacy/archive/2026-01-01-old.md"
printf 'unread\n'   > "$SRC/legacy/live.md"
printf 'role doc\n' > "$SRC/legacy/ROLE.md"
accepts "migrate --dry-run writes nothing"     -- migrate "$SRC" --dry-run
if [[ ! -d "$AIMAIL_ROOT/mail/legacy" ]]; then
  PASS=$((PASS+1)); printf '  ✔ dry run created no mail directory\n'
else FAIL=$((FAIL+1)); FAILURES+=("dry run wrote to the target"); printf '  ✖ dry run wrote to the target\n'; fi
accepts "migrate imports"                      -- migrate "$SRC"
ARCH=$(find "$AIMAIL_ROOT/mail/legacy/archive" -name '*.md' 2>/dev/null | wc -l)
LIVE=$(find "$AIMAIL_ROOT/mail/legacy" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
ROLE=$([[ -f "$AIMAIL_ROOT/roles/legacy.md" ]] && echo 1 || echo 0)
if (( ARCH == 1 && LIVE == 1 && ROLE == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ archive→shard, inbox→inbox, ROLE.md→roles/ (%s/%s/%s)\n' "$ARCH" "$LIVE" "$ROLE"
else
  FAIL=$((FAIL+1)); FAILURES+=("migrate routed files wrong: arch=$ARCH live=$LIVE role=$ROLE")
  printf '  ✖ migrate routed files wrong: arch=%s live=%s role=%s\n' "$ARCH" "$LIVE" "$ROLE"
fi
# ⛔ ROLE.md must NOT land in the inbox, or it is delivered forever as mail.
if [[ ! -f "$AIMAIL_ROOT/mail/legacy/ROLE.md" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ROLE.md did not land in the inbox\n'
else FAIL=$((FAIL+1)); FAILURES+=("ROLE.md landed in the inbox"); printf '  ✖ ROLE.md landed in the inbox\n'; fi
SRC_COUNT=$(find "$SRC" -name '*.md' | wc -l)
if (( SRC_COUNT == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ source untouched (%s files still there)\n' "$SRC_COUNT"
else FAIL=$((FAIL+1)); FAILURES+=("migrate modified the source"); printf '  ✖ migrate modified the source\n'; fi
accepts "migrate is idempotent (re-run is safe)" -- migrate "$SRC"

# ⛔ REGRESSION ARM — a real mailbox had a SECOND archive directory named
#    `_archive`, holding 12 genuine messages. The migrator read only `archive/`
#    and reported success. A per-seat reconciliation against the source caught
#    it; the tool's own summary did not. Any subdirectory holds mail.
mkdir -p "$SRC/oddball/_archive" "$SRC/oddball/archive/nested"
printf 'in _archive\n' > "$SRC/oddball/_archive/alt.md"
printf 'nested\n'      > "$SRC/oddball/archive/nested/deep.md"
printf 'normal\n'      > "$SRC/oddball/archive/plain.md"
accepts "migrate imports a seat with odd archive layouts" -- migrate "$SRC"
ODD=$(find "$AIMAIL_ROOT/mail/oddball/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ODD == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ all 3 archived messages found across _archive/, archive/ and archive/nested/\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("odd archive layouts: got $ODD of 3")
  printf '  ✖ odd archive layouts: got %s of 3 — a non-standard dir was skipped\n' "$ODD"
fi
# ③ the other direction: a dot-directory is tooling and must NOT be imported
mkdir -p "$SRC/oddball/.pytest_cache"; printf 'junk\n' > "$SRC/oddball/.pytest_cache/j.md"
accepts "migrate re-run with a dot-dir present"          -- migrate "$SRC"
if ! find "$AIMAIL_ROOT/mail/oddball" -name 'j.md' | grep -q .; then
  PASS=$((PASS+1)); printf '  ✔ dot-directory contents were NOT imported\n'
else FAIL=$((FAIL+1)); FAILURES+=("dot-dir imported"); printf '  ✖ dot-directory contents were imported\n'; fi

section "stop hook — five arms, each asserting its logged DECISION"
# ⚠ Run as part of the suite, not as a separate manual step. The first version of
#   this selftest lived outside the suite, and its two "allow" arms passed while
#   the guard was switched off entirely.
SG="$(bash "$REPO/hooks/stop_guard.sh" selftest 2>&1)"
while IFS= read -r line; do
  case "$line" in
    *"✔"*) PASS=$((PASS+1)); printf '  %s\n' "$line" ;;
    *FAILED*) FAIL=$((FAIL+1)); FAILURES+=("stop_guard: $line"); printf '  ✖ %s\n' "$line" ;;
  esac
done <<< "$SG"

section "doctor"
accepts "doctor runs"                          -- doctor

# ══════════════════════════════════════════════════════════════════════════════
TOTAL=$((PASS+FAIL))
echo; printf '%.0s─' {1..60}; echo
printf '\n%s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TOTAL"
if (( FAIL )); then printf '\nFAILURES:\n'; printf '  • %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
