#!/usr/bin/env bash
# tests/ask_ledger.sh — the ASK LEDGER + `aimail land`, driven through the REAL commands in a
# throwaway state root and throwaway git repos. Every arm below was shown red first by breaking
# a throwaway copy (see the falsification notes in the landing request).
#
# Runs standalone (`bash tests/ask_ledger.sh`) and inside tests/run.sh (its own section).
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
GATECLAIM="$REPO/bin/gateclaim.sh"
T="$(mktemp -d)"
export AIMAIL_ROOT="$T/root"
export AIMAIL_CONFIG="$T/aimail.conf"
export AIMAIL_CLAIMS="$T/claims"
export AIMAIL_STERILITY_TERMS=""
export AIMAIL_SUPERVISOR="sup"
export AIMAIL_OWNER_INBOX="$T/owner_inbox.md"
export AIMAIL_ASK_STALE=2            # seconds; NON-default (default 1800) so the fixture proves the knob is read
export AIMAIL_ASK_CHECK_TIMEOUT=5
export AIMAIL_SEND_IDENTITY_CHECK=0  # no registered sessions in this fixture
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
mkdir -p "$AIMAIL_ROOT" "$AIMAIL_CLAIMS"
printf 'AIMAIL_ROOT="%s"\nAIMAIL_POLL_INTERVAL=1\n' "$AIMAIL_ROOT" > "$AIMAIL_CONFIG"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  ✖ %s\n' "$1"; }
# _has <grep args> — `grep -q` that reads ALL of its input first. With `set -o pipefail` a bare
# `cmd | grep -q X` fails whenever grep matches and exits before `cmd` has finished writing: cmd gets
# SIGPIPE, the pipeline reads 141, and a passing check reports red. That is the flake this replaces
# (it shows up only under load, when cmd is slow enough to still be writing).
_has() { local _all; _all="$(cat)"; grep -q "$@" <<<"$_all"; }
check() { if [[ "$1" == 0 ]]; then pass "$2"; else fail "$2${3:+ ($3)}"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# _backdate <id> <col> <seconds-ago> — set column <col> (9=last_touch, 2=asked_at)
# of row <id> to now-<seconds-ago>, DETERMINISTICALLY simulating age without a
# real-time sleep. Replaces `sleep N; ask sweep` throughout this file: under
# fleet load (many batteries running concurrently) a wall-clock sleep is exactly
# as long as scheduled, but a slow/starved process can still miss its own
# just-elapsed window before the NEXT command runs — flaked live under load
# (~10.7 loadavg, framing's gate on the --waiting-on feature branch, 2026-09-24)
# after 13 clean runs at low contention. Backdating the row itself removes the real-time
# dependency entirely: the age check reads as already-elapsed the instant this
# runs, regardless of how fast or slow the surrounding shell actually is.
_backdate() {
  local id="$1" col="$2" secs="$3" f="$AIMAIL_ROOT/state/asks.tsv" tmp
  tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$id" -v col="$col" -v ts="$(( $(date +%s) - secs ))" \
      'NR==1{print;next} $1==id{$col=ts} {print}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

"$AIMAIL" seat add sup   "supervisor (fixture)" >/dev/null 2>&1
"$AIMAIL" seat add alpha "worker a (fixture)"   >/dev/null 2>&1
"$AIMAIL" seat add beta  "worker b (fixture)"   >/dev/null 2>&1

section "ask ledger — add / touch / list / show"
ID1="$("$AIMAIL" ask add --owner alpha --quote "ship the widget" --next "alpha builds" --check "test -f $T/widget.done" --rank 5 2>/dev/null | tail -1)"
[[ "$ID1" =~ ^k[0-9]{4}$ ]]; check $? "ask add prints an id (got '$ID1')"
ID2="$("$AIMAIL" ask add --owner beta --quote "owner verdict needed on X" --next "wait" --check "false" 2>/dev/null | tail -1)"
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$ID1 *OPEN *alpha"; check $? "ask list shows the open row with its owner"
"$AIMAIL" ask show "$ID1" 2>/dev/null | _has "^state: *open"; check $? "ask show reads the row's state"
"$AIMAIL" ask touch "$ID1" --by alpha --state "half built" --evidence "sha0001" --next "tests" >/dev/null 2>&1
"$AIMAIL" ask show "$ID1" 2>/dev/null | _has "^state_text: *half built"; check $? "ask touch records the current-state snapshot"
"$AIMAIL" ask show "$ID1" 2>/dev/null | _has "^next: *tests"; check $? "ask touch updates the next step"
"$AIMAIL" ask done "$ID1" >/dev/null 2>&1; rc=$?; [[ $rc != 0 ]]; check $? "there is NO manual 'ask done' (refused, rc=$rc)"

section "ask ledger — sweep: the check closes the row, a stale row mails once and escalates once"
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" ask show "$ID1" 2>/dev/null | _has "^state: *open";   check $? "a failing check leaves the row open"
"$AIMAIL" ask show "$ID2" 2>/dev/null | _has "^state: *waiting_owner"; check $? "a literal 'false' check becomes WAITING-ON-OWNER"
"$AIMAIL" ask list --owner beta 2>/dev/null | _has "WAITING-ON-OWNER"; check $? "ask list labels the owner-verdict row"
_backdate "$ID1" 9 3   # past AIMAIL_ASK_STALE=2 with no touch
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" ask list --stale 2>/dev/null | _has "^$ID1 *STALE"; check $? "an untouched row past the stale window lists as STALE"
"$AIMAIL" ask list --stale 2>/dev/null | _has "^$ID2"; rc=$?; [[ $rc != 0 ]]; check $? "the waiting-on-owner row is NEVER listed stale"
# mail_send only QUEUES (inbox); a message moves to unacked/ on delivery
# (mail_deliver/poll), never on send itself -- deliver both recipients first.
"$AIMAIL" deliver alpha >/dev/null 2>&1; "$AIMAIL" deliver sup >/dev/null 2>&1
# `ls` lists filenames (kebab-cased from the subject, e.g. "...-stale-ask-k0001-...");
# the subject text itself ("STALE ask k0001", spaced, mixed case) lives only in each
# file's own content, so match content, not the filename.
N1="$(grep -rl "STALE ask $ID1" "$AIMAIL_ROOT/mail/alpha/unacked" 2>/dev/null | wc -l)"
NS="$(grep -rl "STALE ask $ID1" "$AIMAIL_ROOT/mail/sup/unacked" 2>/dev/null | wc -l)"
[[ "$N1" == 1 && "$NS" == 1 ]]; check $? "the stale row mails the owner AND the supervisor once (alpha=$N1 sup=$NS)"
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" deliver alpha >/dev/null 2>&1
N1b="$(grep -rl "STALE ask $ID1" "$AIMAIL_ROOT/mail/alpha/unacked" 2>/dev/null | wc -l)"
[[ "$N1b" == 1 ]]; check $? "a second sweep in the same episode does NOT mail again (still $N1b)"
_backdate "$ID1" 9 5   # further back: past 2x stale (>4)
"$AIMAIL" ask sweep >/dev/null 2>&1
grep -q "^STALLED $ID1: ship the widget" "$AIMAIL_OWNER_INBOX" 2>/dev/null; check $? "past 2x stale, ONE line lands in the owner inbox"
"$AIMAIL" ask sweep >/dev/null 2>&1
[[ "$(grep -c "^STALLED $ID1" "$AIMAIL_OWNER_INBOX")" == 1 ]]; check $? "the owner-inbox escalation happens once per episode"
"$AIMAIL" ask touch "$ID1" --by alpha --state "resumed" >/dev/null 2>&1
"$AIMAIL" ask list --stale 2>/dev/null | _has "^$ID1"; rc=$?; [[ $rc != 0 ]]; check $? "a touch ends the stale episode"
touch "$T/widget.done"
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" ask show "$ID1" 2>/dev/null | _has "^state: *done"; check $? "a passing check CLOSES the row"
"$AIMAIL" ask list 2>/dev/null | _has "^$ID1"; rc=$?; [[ $rc != 0 ]]; check $? "a done row leaves the default list (--all shows it)"
"$AIMAIL" ask list --all 2>/dev/null | _has "^$ID1 *DONE"; check $? "ask list --all shows DONE"
ID3="$("$AIMAIL" ask add --owner alpha --quote "withdraw me" --next "n" --check "false" 2>/dev/null | tail -1)"
"$AIMAIL" ask withdraw "$ID3" >/dev/null 2>&1; rc=$?; [[ $rc != 0 ]]; check $? "withdraw without --owner-approved is refused"
"$AIMAIL" ask withdraw "$ID3" --owner-approved "drop it, said the owner" >/dev/null 2>&1
"$AIMAIL" ask show "$ID3" 2>/dev/null | _has "^state: *withdrawn"; check $? "withdraw with the owner's quote closes the row"

section "ask ledger — --waiting-on: a REAL check blocked on someone, exempt from stale mail, still auto-closes"
# ⛔ THE BUG THIS FIXES: a16 (real fleet ledger, not this fixture) had a REAL check that was
#   practically unsatisfiable once the feature it named was descoped, and got stale-mailed
#   every 30 min for hours with nothing to act on -- unlike the literal `false` case, which
#   was ALREADY exempt. --waiting-on gives a real-check row the same exemption without
#   touching its check.
ID5="$("$AIMAIL" ask add --owner alpha --quote "blocked on carol" --next "n" --check "test -f $T/w5.done" 2>/dev/null | tail -1)"
"$AIMAIL" ask touch "$ID5" --by alpha --state "blocked" --waiting-on carol >/dev/null 2>&1
"$AIMAIL" ask show "$ID5" 2>/dev/null | _has "^waiting_on: *carol"; check $? "touch --waiting-on sets the column"
"$AIMAIL" ask list --all 2>/dev/null | _has "^$ID5 *WAITING-ON-CAROL"; check $? "ask list labels it WAITING-ON-<seat>, not OPEN/STALE"
_backdate "$ID5" 9 3   # past AIMAIL_ASK_STALE=2
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" deliver alpha >/dev/null 2>&1; "$AIMAIL" deliver sup >/dev/null 2>&1
N5="$(grep -rl "STALE ask $ID5" "$AIMAIL_ROOT/mail/alpha/unacked" "$AIMAIL_ROOT/mail/sup/unacked" 2>/dev/null | wc -l)"
[[ "$N5" == 0 ]]; check $? "a real-check row blocked --waiting-on is NOT stale-mailed (got $N5)"
"$AIMAIL" ask list --stale 2>/dev/null | _has "^$ID5"; rc=$?; [[ $rc != 0 ]]; check $? "…and never labeled STALE either"
# ⛔⛔ THE GAP FOUND BY DELIBERATELY BREAKING THIS: _ask_is_stale's own --waiting-on guard has
#   NO coverage through ask_list/ask_state_label (both short-circuit on waiting_on before ever
#   calling _ask_is_stale) -- removing that guard left every arm above GREEN. Its only other
#   caller is ask_stale_for, which gateclaim.sh's stale-owner refusal depends on directly. This
#   is the arm that actually exercises it: alpha's ONLY stale-by-age row is --waiting-on
#   blocked (age already past AIMAIL_ASK_STALE from the backdate above) -- gateclaim must NOT
#   refuse a new claim citing it.
"$GATECLAIM" alphawaitingtest alpha --desc "should not be refused" >"$T/gcw.out" 2>&1; rc=$?
[[ $rc == 0 ]]; check $? "gateclaim does NOT refuse a claim citing a row that is only --waiting-on stale, not neglected"
"$GATECLAIM" --release alphawaitingtest alpha >/dev/null 2>&1
touch "$T/w5.done"
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" ask show "$ID5" 2>/dev/null | _has "^state: *done"; check $? "the check STILL closes the row once it passes, even while --waiting-on is set"
# ⛔ THE OTHER DIRECTION: clearing it must restore ordinary stale-mailing -- an
#   always-exempting flag would just move the blind spot, not fix it.
ID6="$("$AIMAIL" ask add --owner alpha --quote "will be unblocked" --next "n" --check "test -f $T/w6.done" 2>/dev/null | tail -1)"
"$AIMAIL" ask touch "$ID6" --by alpha --state "blocked" --waiting-on carol >/dev/null 2>&1
"$AIMAIL" ask touch "$ID6" --by alpha --state "unblocked" --waiting-on "" >/dev/null 2>&1
"$AIMAIL" ask show "$ID6" 2>/dev/null | _has "^waiting_on: *$"; check $? "--waiting-on '' clears the column"
_backdate "$ID6" 9 3
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" deliver alpha >/dev/null 2>&1
N6="$(grep -rl "STALE ask $ID6" "$AIMAIL_ROOT/mail/alpha/unacked" 2>/dev/null | wc -l)"
[[ "$N6" == 1 ]]; check $? "…and an ordinary stale-mail episode fires normally again (got $N6)"
# clean up: close ID6 so alpha reads as having no stale row for the claim-gate section below.
touch "$T/w6.done"; "$AIMAIL" ask sweep >/dev/null 2>&1
# ⭐ the digest: what a per-row stale mail was replaced with for the blocked case.
"$AIMAIL" ask digest 2>/dev/null | _has "^$ID6"; rc=$?; [[ $rc != 0 ]]; check $? "digest never lists an unblocked row"
ID7="$("$AIMAIL" ask add --owner beta --quote "also blocked on carol" --next "n" --check "false2" 2>/dev/null | tail -1)"
"$AIMAIL" ask touch "$ID7" --by beta --state "blocked" --waiting-on carol >/dev/null 2>&1
"$AIMAIL" ask digest 2>/dev/null | _has "^$ID7.*owed by carol"; check $? "digest lists a blocked row with who it's owed by"
"$AIMAIL" ask digest nobodyhome 2>/dev/null | _has "^$ID7"; rc=$?; [[ $rc != 0 ]]; check $? "digest <who> filters to that one name only"
"$AIMAIL" ask digest carol 2>/dev/null | _has "^$ID7"; check $? "…and finds it under the matching name"

section "ask ledger — the claim gate refuses a seat that owns a stale open row"
ID4="$("$AIMAIL" ask add --owner beta --quote "older task" --next "n" --check "test -f $T/never" 2>/dev/null | tail -1)"
_backdate "$ID4" 2 3   # never touched -- age falls back to asked_at (col 2)
"$AIMAIL" ask sweep >/dev/null 2>&1
"$GATECLAIM" newshinytask beta --desc "newer task" >"$T/gc.out" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -q "$ID4" "$T/gc.out"; check $? "gateclaim REFUSES beta's new claim and names the stale row ($ID4)"
"$GATECLAIM" newshinytask alpha --desc "alpha is clean" >"$T/gc2.out" 2>&1; rc=$?
[[ $rc == 0 ]]; check $? "a seat with no stale row claims normally"
"$GATECLAIM" --release newshinytask alpha >/dev/null 2>&1
"$GATECLAIM" newshinytask beta --desc "newer task" --preempt-ok "the owner said: do the new one first" >"$T/gc3.out" 2>&1; rc=$?
[[ $rc == 0 ]]; check $? "--preempt-ok \"<owner quote>\" lets the claim through"
"$AIMAIL" ask show "$ID4" 2>/dev/null | _has "preempt"; check $? "the preemption is recorded on the stale row as a touch"
"$GATECLAIM" --release newshinytask beta >/dev/null 2>&1; rc=$?; [[ $rc == 0 ]]; check $? "--release is never refused by the ask gate"

section "ask ledger — visibility: fleet counts, role write block, import"
"$AIMAIL" fleet alpha 2>/dev/null | _has "ASKS"; check $? "aimail fleet has an ASKS column"
CNT="$("$AIMAIL" ask counts beta 2>/dev/null)"; [[ "$CNT" == "3/1" || "$CNT" == "3/0" ]]; check $? "ask counts <seat> prints open/stale (beta: $CNT)"
printf '# handover\nline one\n' > "$T/role.md"
"$AIMAIL" role write alpha "$T/role.md" >/dev/null 2>&1
grep -q "aimail:asks:begin" "$AIMAIL_ROOT/roles/alpha.md" 2>/dev/null; rc=$?
if "$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^k"; then check $rc "role write appends the seat's open asks between markers"; else [[ $rc != 0 ]]; check $? "role write appends nothing when the seat has no open asks"; fi
"$AIMAIL" role write alpha "$T/role.md" >/dev/null 2>&1
[[ "$(grep -c "aimail:asks:begin" "$AIMAIL_ROOT/roles/alpha.md" 2>/dev/null)" -le 1 ]]; check $? "a second role write does not duplicate the block"
printf 'id\tasked_at\towner\task\tnext\tdone_check\ns01\t09-23 10:2x\talpha\tseeded ask\tnext step\tfalse  # owner verdict\ns02\t09-23 11:00\tbeta\tseeded two\tn2\ttest -f %s/s02.done\n' "$T" > "$T/seed.tsv"
"$AIMAIL" ask import "$T/seed.tsv" >/dev/null 2>&1
"$AIMAIL" ask show s01 2>/dev/null | _has "^owner: *alpha"; check $? "import preserves ids and owners"
"$AIMAIL" ask show s01 2>/dev/null | _has "^state_text: *owner verdict"; check $? "import moves the check's trailing comment into state_text"
"$AIMAIL" ask import "$T/seed.tsv" 2>&1 | _has "2 already present"; check $? "a second import skips existing ids"

section "aimail land — locked, live-tip, fast-forward only, 3-arg move, verified"
G="$T/g"; git init -q -b main "$G"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
BASE="$(git -C "$G" rev-parse main)"
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m A; A="$(git -C "$G" rev-parse HEAD)"
git -C "$G" checkout -q -b sib "$BASE"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m B; B="$(git -C "$G" rev-parse HEAD)"
git -C "$G" checkout -q main; git -C "$G" update-ref refs/heads/main "$BASE"
"$AIMAIL" land "$G" refs/heads/main "$A" --from sup >"$T/land1.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$A" ]]; check $? "a fast-forward landing moves the ref and exits 0"
grep -q "^  .* A$\|A$" "$T/land1.out" && grep -q "diff --stat" "$T/land1.out"; check $? "the landing prints the oneline log and the stat for the mail"
"$AIMAIL" land "$G" refs/heads/main "$B" --from sup >"$T/land2.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$A" ]] && grep -q "NON-FAST-FORWARD" "$T/land2.out"; check $? "a sibling (non-FF) landing is REFUSED and the ref is untouched"
"$AIMAIL" land "$G" refs/heads/main "$A" --from sup 2>&1 | _has "already at"; check $? "landing the current tip is a no-op, not an error"
"$AIMAIL" land "$G" refs/heads/nope "$A" --from sup >/dev/null 2>&1; rc=$?; [[ $rc != 0 ]]; check $? "a ref that does not exist is refused (no silent creation)"
# the two-lander replay: both cut from $A; concurrent land calls -- exactly one wins, nothing lost
git -C "$G" checkout -q main; git -C "$G" reset -q --hard "$A"
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m X; X="$(git -C "$G" rev-parse HEAD)"
git -C "$G" checkout -q -b y "$A"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m Y; Y="$(git -C "$G" rev-parse HEAD)"
git -C "$G" checkout -q main; git -C "$G" update-ref refs/heads/main "$A"
"$AIMAIL" land "$G" refs/heads/main "$X" --from sup >"$T/lx.out" 2>&1 & p1=$!
"$AIMAIL" land "$G" refs/heads/main "$Y" --from sup >"$T/ly.out" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
TIP="$(git -C "$G" rev-parse main)"
[[ $(( (r1==0) + (r2==0) )) == 1 && ( "$TIP" == "$X" || "$TIP" == "$Y" ) ]]; check $? "two concurrent landings from one parent: exactly one lands (rc $r1/$r2), the ref holds the winner"
git -C "$G" cat-file -e "$X" && git -C "$G" cat-file -e "$Y"; check $? "the loser's commit still exists — nothing was lost silently"
# the 3-arg update-ref refuses a moved tip (the primitive the command relies on)
git -C "$G" update-ref refs/heads/main "$B" "$A" >/dev/null 2>&1; rc=$?; [[ $rc != 0 ]]; check $? "3-arg update-ref refuses when the expected-old is not the live tip"

section "aimail land — a must-prove (repo,ref) refuses without a green, tree-matched --gate-summary"
git -C "$G" update-ref refs/heads/main "$TIP"
# detached, so a plain `git commit` here never itself moves refs/heads/main -- only
# `aimail land` is allowed to do that in this section.
git -C "$G" checkout -q --detach "$TIP"
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m C; CC="$(git -C "$G" rev-parse HEAD)"
export AIMAIL_LAND_REQUIRE_GATE="$G|refs/heads/main"
"$AIMAIL" land "$G" refs/heads/main "$CC" --from sup >"$T/gate_none.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$TIP" ]] && grep -q "requires a --gate-summary" "$T/gate_none.out"
check $? "no --gate-summary at all is REFUSED, ref untouched"

GATE_MISSING="$T/does-not-exist.summary"
"$AIMAIL" land "$G" refs/heads/main "$CC" --from sup --gate-summary "$GATE_MISSING" >"$T/gate_missing.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$TIP" ]] && grep -q "did not pass check_battery_summary.sh" "$T/gate_missing.out"
check $? "a --gate-summary that does not exist on disk is REFUSED, ref untouched"

GATE_WRONG_TREE="$T/wrong_tree.summary"
cat > "$GATE_WRONG_TREE" <<EOF
▶ worktree HEAD:   $A
BATTERY_EXIT=0
CORPUS_EXIT=0
COUNT_EXIT=0
NAME_SET_EXIT=0
REAL_TIER_EXIT=0
SKIP_NAMES_EXIT=0
EOF
"$AIMAIL" land "$G" refs/heads/main "$CC" --from sup --gate-summary "$GATE_WRONG_TREE" >"$T/gate_wrong.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$TIP" ]]; check $? "a --gate-summary for a DIFFERENT tree than the sha being landed is REFUSED"
grep -q "(exit 3)" "$T/gate_wrong.out"; check $? "…and the refusal PRINTS the real exit 3 (the gate_rc capture-order bug, once fixed)"

GATE_RED="$T/red.summary"
cat > "$GATE_RED" <<EOF
▶ worktree HEAD:   $CC
BATTERY_EXIT=1
CORPUS_EXIT=0
COUNT_EXIT=0
NAME_SET_EXIT=0
REAL_TIER_EXIT=0
SKIP_NAMES_EXIT=0
EOF
"$AIMAIL" land "$G" refs/heads/main "$CC" --from sup --gate-summary "$GATE_RED" >"$T/gate_red.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$TIP" ]]; check $? "a --gate-summary citing a RED battery (BATTERY_EXIT=1) for the right tree is REFUSED"
grep -q "(exit 5)" "$T/gate_red.out"; check $? "…and the refusal PRINTS the real exit 5, not a stale/always-0 code"

GATE_GREEN="$T/green.summary"
cat > "$GATE_GREEN" <<EOF
▶ worktree HEAD:   $CC
BATTERY_EXIT=0
CORPUS_EXIT=0
COUNT_EXIT=0
NAME_SET_EXIT=0
REAL_TIER_EXIT=0
SKIP_NAMES_EXIT=0
EOF
"$AIMAIL" land "$G" refs/heads/main "$CC" --from sup --gate-summary "$GATE_GREEN" >"$T/gate_ok.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$CC" ]]; check $? "a --gate-summary citing a GREEN, tree-matched battery for the exact sha lands normally"
unset AIMAIL_LAND_REQUIRE_GATE
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m D >/dev/null; DD="$(git -C "$G" rev-parse HEAD)"
"$AIMAIL" land "$G" refs/heads/main "$DD" --from sup >"$T/gate_unlisted.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$DD" ]]; check $? "with AIMAIL_LAND_REQUIRE_GATE unset, an ordinary (repo,ref) not in the default set lands with no citation, unchanged from before this feature"

section "aimail land — refuses a CAS move when a queued-or-unacked mail names the sha with HOLD"
"$AIMAIL" seat add holdcheck "hold-check testseat" >/dev/null 2>&1

git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E1 >/dev/null; E1="$(git -C "$G" rev-parse HEAD)"
printf 'HOLD: do not land %s -- verifying a downstream dependency first\n' "$E1" > "$T/hold1.md"
"$AIMAIL" send --to holdcheck --from sup --subject "HOLD on ${E1:0:8}" --body-file "$T/hold1.md" >/dev/null 2>&1
"$AIMAIL" land "$G" refs/heads/main "$E1" --from holdcheck >"$T/hold_queued.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$DD" ]] && grep -qi 'HOLD' "$T/hold_queued.out"
check $? "a HOLD mail still QUEUED (never delivered) refuses the landing, ref untouched"

"$AIMAIL" deliver holdcheck >/dev/null 2>&1
"$AIMAIL" land "$G" refs/heads/main "$E1" --from holdcheck >"$T/hold_unacked.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$DD" ]] && grep -qi 'HOLD' "$T/hold_unacked.out"
check $? "…and still refuses once delivered (unacked/), same mail, different directory"

HOLD_FILE="$(ls "$AIMAIL_ROOT"/mail/holdcheck/unacked/*.md | head -1)"
HOLD_SHA="$(grep '^body-sha256:' "$HOLD_FILE" | awk '{print $2}' | cut -c1-8)"
"$AIMAIL" ack holdcheck --all --sha "$HOLD_SHA" >/dev/null 2>&1
"$AIMAIL" land "$G" refs/heads/main "$E1" --from holdcheck >"$T/hold_cleared.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$E1" ]]; check $? "…and no longer refuses once the hold mail is acked/archived"

git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E2 >/dev/null; E2="$(git -C "$G" rev-parse HEAD)"
printf 'FYI: %s is a routine cleanup commit, no concerns\n' "$E2" > "$T/fyi.md"
"$AIMAIL" send --to holdcheck --from sup --subject "status re ${E2:0:8}" --body-file "$T/fyi.md" >/dev/null 2>&1
"$AIMAIL" land "$G" refs/heads/main "$E2" --from holdcheck >"$T/hold_falsepos.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]]; check $? "a mail naming the sha WITHOUT the word 'hold' does NOT block the landing"

git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E3 >/dev/null; E3="$(git -C "$G" rev-parse HEAD)"
printf 'please hold on %s until the demo tomorrow\n' "${E3:0:8}" > "$T/hold3.md"
"$AIMAIL" send --to holdcheck --from sup --subject "re ${E3:0:8}" --body-file "$T/hold3.md" >/dev/null 2>&1
E3_HOLD_ID="$(basename "$(ls -t "$AIMAIL_ROOT"/mail/holdcheck/*.md 2>/dev/null | head -1)" .md)"
"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck >"$T/hold3_blocked.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]]; check $? "a lowercase 'hold' naming only the SHORT sha (in the body, not the subject) still refuses"

"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck --override-hold "" --reason "x" >"$T/hold3_empty_ids.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]] && grep -qi 'requires at least one message id' "$T/hold3_empty_ids.out"
check $? "--override-hold with NO ids is refused (usage error, before any mail is even scanned)"

"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck --override-hold "$E3_HOLD_ID" --reason "" >"$T/hold3_empty_override.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]] && grep -qi 'requires --reason' "$T/hold3_empty_override.out"
check $? "--override-hold with an EMPTY --reason is refused (usage error, before any mail is even scanned)"

"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck --override-hold "$E3_HOLD_ID" --reason "   " >"$T/hold3_ws_override.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]] && grep -qi 'requires --reason' "$T/hold3_ws_override.out"
check $? "--override-hold with a WHITESPACE-ONLY --reason is refused, same as empty"

"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck --override-hold "$E3_HOLD_ID" --reason "$(printf '\t')" >"$T/hold3_tab_override.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E2" ]] && grep -qi 'requires --reason' "$T/hold3_tab_override.out"
check $? "--override-hold with a single TAB --reason is refused, same as empty"

"$AIMAIL" land "$G" refs/heads/main "$E3" --from holdcheck --override-hold "$E3_HOLD_ID" --reason "confirmed via voice, hold mail read and accepted" >"$T/hold3_override.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$E3" ]] && grep -q 'confirmed via voice' "$T/hold3_override.out"
check $? "--override-hold <id> --reason \"<reason>\" naming the exact match bypasses it, lands, and prints the reason for the record"

git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E4 >/dev/null; E4="$(git -C "$G" rev-parse HEAD)"
printf 'HOLD on %s\n' "$E4" > "$T/hold4.md"
"$AIMAIL" send --to holdcheck --from sup --subject "HOLD ${E4:0:8}" --body-file "$T/hold4.md" >/dev/null 2>&1
E4_HOLD_ID="$(basename "$(ls -t "$AIMAIL_ROOT"/mail/holdcheck/*.md 2>/dev/null | head -1)" .md)"
"$AIMAIL" land "$G" refs/heads/main "$E4" --from holdcheck --override-hold "$E4_HOLD_ID" --reason "   confirmed, padded with spaces   " >"$T/hold4_trimmed.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$E4" ]] \
  && grep -q '("confirmed, padded with spaces")' "$T/hold4_trimmed.out" \
  && ! grep -q '("   confirmed' "$T/hold4_trimmed.out"
check $? "a real reason WITH surrounding whitespace is accepted, trimmed before it's printed for the record"

section "aimail land — --override-hold clears ONLY the id(s) it names, never a blanket skip (2026-09-25, after 09edd7ad landed over a real hold that a blind override skipped)"
git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E5 >/dev/null; E5="$(git -C "$G" rev-parse HEAD)"
printf 'HOLD on %s -- first reviewer\n' "$E5" > "$T/hold5a.md"
"$AIMAIL" send --to holdcheck --from sup --subject "HOLD(a) ${E5:0:8}" --body-file "$T/hold5a.md" >/dev/null 2>&1
E5_HOLD_A="$(basename "$(ls -t "$AIMAIL_ROOT"/mail/holdcheck/*.md 2>/dev/null | head -1)" .md)"
printf 'HOLD on %s -- second reviewer, independent concern\n' "$E5" > "$T/hold5b.md"
"$AIMAIL" send --to holdcheck --from sup --subject "HOLD(b) ${E5:0:8}" --body-file "$T/hold5b.md" >/dev/null 2>&1
E5_HOLD_B="$(basename "$(ls -t "$AIMAIL_ROOT"/mail/holdcheck/*.md 2>/dev/null | head -1)" .md)"

"$AIMAIL" land "$G" refs/heads/main "$E5" --from holdcheck --override-hold "$E5_HOLD_A" --reason "reviewer a's concern addressed" >"$T/hold5_one_named.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E4" ]] && grep -qi 'did not name every active hold' "$T/hold5_one_named.out" && grep -q "$E5_HOLD_B" "$T/hold5_one_named.out"
check $? "two active holds, only ONE named — refused, ref untouched, and the refusal names the unnamed match"

"$AIMAIL" land "$G" refs/heads/main "$E5" --from holdcheck --override-hold "$E5_HOLD_A,$E5_HOLD_B" --reason "both reviewers' concerns addressed" >"$T/hold5_both_named.out" 2>&1; rc=$?
[[ $rc == 0 && "$(git -C "$G" rev-parse main)" == "$E5" ]]; check $? "…and naming BOTH active holds lands normally"

git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m E6 >/dev/null; E6="$(git -C "$G" rev-parse HEAD)"
printf 'HOLD on %s\n' "$E6" > "$T/hold6.md"
"$AIMAIL" send --to holdcheck --from sup --subject "HOLD ${E6:0:8}" --body-file "$T/hold6.md" >/dev/null 2>&1
"$AIMAIL" land "$G" refs/heads/main "$E6" --from holdcheck --override-hold "not-a-real-message-id-typo" --reason "meant to override the real one" >"$T/hold6_typo.out" 2>&1; rc=$?
[[ $rc != 0 && "$(git -C "$G" rev-parse main)" == "$E5" ]] && grep -qi 'do not match any active hold' "$T/hold6_typo.out"
check $? "--override-hold naming an id that matches NO active hold refuses (typo guard), ref untouched"

"$AIMAIL" land "$G" refs/heads/main "$E2" --from holdcheck --reason "fat-fingered, meant --override-hold too" >"$T/reason_alone.out" 2>&1; rc=$?
[[ $rc != 0 ]] && grep -qi 'no effect without --override-hold' "$T/reason_alone.out"
check $? "--reason given ALONE (no --override-hold) is refused, not a silent no-op"

echo
echo "── SUMMARY: $PASS passed, $FAIL failed ──"
rm -rf "$T"
[[ "$FAIL" == 0 ]]
