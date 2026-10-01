#!/usr/bin/env bash
# tests/drop_guards.sh — the four DROP-PREVENTION GUARDS, driven through the real commands and
# the real hook script in a throwaway state root. For every guard: the bad case MUST be stopped
# and the nearest good case MUST pass (an always-refusing guard never fires on what it was built
# for, so each refusal arm is paired with an acceptance arm).
#
#   1. prompt ledger + triage gate  (lib/prompts.sh, hooks/prompt_guard.sh)
#   2. parking needs a date or a named trigger  (ask touch/park --waiting-on)
#   3. a work mail must cite an open ask id  (send, lib/mail.sh §2.4d)
#   4. the open-asks digest  (ask owner-digest)
#
# Runs standalone (`bash tests/drop_guards.sh`) and inside tests/run.sh (its own section).
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
HOOK="$REPO/hooks/prompt_guard.sh"
T="$(mktemp -d)"
export AIMAIL_ROOT="$T/root"
export AIMAIL_CONFIG="$T/aimail.conf"
export AIMAIL_CLAIMS="$T/claims"
export AIMAIL_STERILITY_TERMS=""
export AIMAIL_SUPERVISOR="sup"
export AIMAIL_ASK_STALE=2
export AIMAIL_SEND_IDENTITY_CHECK=0
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AIMAIL_PROMPT_GATE AIMAIL_PROMPT_CAPTURE AIMAIL_WORK_MAIL_GUARD \
      AIMAIL_AUTOMATED_PROMPT_RE AIMAIL_WORK_SUBJECT_RE AIMAIL_PROMPT_CAPTURE_QUIET
mkdir -p "$AIMAIL_ROOT" "$AIMAIL_CLAIMS"
printf 'AIMAIL_ROOT="%s"\nAIMAIL_POLL_INTERVAL=1\n' "$AIMAIL_ROOT" > "$AIMAIL_CONFIG"
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  ✖ %s\n' "$1"; }
_has() { local _all; _all="$(cat)"; grep -q "$@" <<<"$_all"; }
check() { if [[ "$1" == 0 ]]; then pass "$2"; else fail "$2${3:+ ($3)}"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# _backdate <id> <col> <seconds-ago>: deterministic age, no sleeping (see tests/ask_ledger.sh)
_backdate() {
  local id="$1" col="$2" secs="$3" f="$AIMAIL_ROOT/state/asks.tsv" tmp
  tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$id" -v col="$col" -v ts="$(( $(date +%s) - secs ))" \
      'NR==1{print;next} $1==id{$col=ts} {print}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
_setcol() {  # <id> <col> <value>
  local id="$1" col="$2" val="$3" f="$AIMAIL_ROOT/state/asks.tsv" tmp
  tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$id" -v col="$col" -v v="$val" 'NR==1{print;next} $1==id{$col=v} {print}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}
_hook() {  # _hook <capture|gate> <json>  -> rc; stdout in $T/h.out, stderr in $T/h.err
  printf '%s' "$2" | bash "$HOOK" "$1" >"$T/h.out" 2>"$T/h.err"; echo $?
}
_run() { "$AIMAIL" "$@" >"$T/c.out" 2>"$T/c.err"; echo $?; }

"$AIMAIL" seat add sup   "supervisor (fixture)" >/dev/null 2>&1
"$AIMAIL" seat add alpha "worker a (fixture)"   >/dev/null 2>&1
"$AIMAIL" seat add beta  "worker b (fixture)"   >/dev/null 2>&1

# ════════════════════════════════════════════════════════════════════════════════════════════
section "guard 1 — prompt capture: an owner prompt becomes a row, machine text does not"
rc="$(_hook capture '{"session_id":"s1","prompt":"please ship the widget by friday"}')"
[[ "$rc" == 0 ]]; check $? "capture exits 0"
grep -q "p0001" "$T/h.out"; check $? "capture tells the session the prompt id (stdout context line)"
"$AIMAIL" prompt list --untriaged 2>/dev/null | _has "^p0001 .*untriaged"; check $? "the prompt is recorded as untriaged"
rc="$(_hook capture '{"session_id":"s1","prompt":"[SYSTEM NOTIFICATION - NOT USER INPUT] poller woke"}')"
[[ "$rc" == 0 && ! -s "$T/h.out" ]]; check $? "an automated notification is not recorded and prints nothing"
[[ "$("$AIMAIL" prompt count s1)" == "1" ]]; check $? "still exactly one untriaged prompt after the machine line"
rc="$(_hook capture 'this is not json')"
[[ "$rc" == 0 ]]; check $? "capture fails OPEN on garbage input (rc 0, never blocks a prompt)"
AIMAIL_PROMPT_CAPTURE=0 _hook capture '{"session_id":"s9","prompt":"kill switch case"}' >/dev/null
[[ "$("$AIMAIL" prompt count s9)" == "0" ]]; check $? "AIMAIL_PROMPT_CAPTURE=0 records nothing"

section "guard 1 — the Stop gate: BAD case (untriaged prompt) is blocked, GOOD case (triaged) passes"
rc="$(_hook gate '{"session_id":"s1"}')"
[[ "$rc" == 2 ]]; check $? "gate BLOCKS (rc 2) while the session has an untriaged prompt" "rc=$rc"
_has "p0001" < "$T/h.err"; check $? "the block names the prompt id"
_has "prompt triage p0001 --ask" < "$T/h.err"; check $? "the block names the exact triage commands"
rc="$(_hook gate '{"session_id":"s1","stop_hook_active":true}')"
[[ "$rc" == 0 ]]; check $? "gate honours stop_hook_active (one block per stop attempt, never a loop)" "rc=$rc"
rc="$(_hook gate '{"session_id":"s2"}')"
[[ "$rc" == 0 ]]; check $? "another session's untriaged prompt does not block this session (gate is per session)"
rc="$(AIMAIL_PROMPT_GATE=0 _hook gate '{"session_id":"s1"}')"
[[ "$rc" == 0 ]]; check $? "AIMAIL_PROMPT_GATE=0 is the kill switch"
rc="$(_hook gate '')"
[[ "$rc" == 0 ]]; check $? "gate fails OPEN with no session id and no payload"
rc="$(_run prompt triage p0001)"
[[ "$rc" == 3 ]]; check $? "triage with neither --ask nor --no-ask is refused" "rc=$rc"
rc="$(_run prompt triage p0001 --no-ask "ok")"
[[ "$rc" == 3 ]] && _has "real reason" < "$T/c.err"; check $? "a one-word --no-ask reason is refused (it records nothing)"
rc="$(_run prompt triage p0001 --ask k9999)"
[[ "$rc" == 3 ]] && _has "no such ask" < "$T/c.err"; check $? "triage to an ask id that is not in the ledger is refused"
rc="$(_run prompt triage p0001 --no-ask "answered in-turn, no work" )"
[[ "$rc" == 0 ]]; check $? "a real --no-ask reason triages the prompt"
rc="$(_hook gate '{"session_id":"s1"}')"
[[ "$rc" == 0 ]]; check $? "gate now PASSES (rc 0): the prompt is triaged"
rc="$(_run prompt triage p0001 --no-ask "answered in-turn, no work" )"
[[ "$rc" == 3 ]]; check $? "a prompt cannot be triaged twice"

section "guard 1 — a prompt that is an ask: ask add --prompt creates the row and triages in one step"
_hook capture '{"session_id":"s1","prompt":"build the report and mail it"}' >/dev/null
[[ "$(_hook gate '{"session_id":"s1"}')" == 2 ]]; check $? "the new prompt blocks the stop again (a fresh stop attempt)"
rc="$(_run ask add --owner alpha --quote "build the report and mail it" --next "alpha builds" --check false --prompt p0002)"
[[ "$rc" == 0 ]]; check $? "ask add --prompt <id> succeeds"
KID="$(tail -1 "$T/c.out")"
"$AIMAIL" prompt list 2>/dev/null | _has "^p0002 *ask *$KID"; check $? "the prompt is triaged to the new ask ($KID)"
[[ "$(_hook gate '{"session_id":"s1"}')" == 0 ]]; check $? "gate passes after the one-step add"
rc="$(_run ask add --owner alpha --quote "x" --next "y" --check false --prompt p7777)"
[[ "$rc" == 3 ]] && _has "no such captured prompt" < "$T/c.err"; check $? "ask add --prompt with an unknown prompt id is refused"
rc="$(_run ask show "$KID")"; _has "^prompt_id: *p0002" < "$T/c.out"; check $? "the ask row records which prompt it came from"

# ════════════════════════════════════════════════════════════════════════════════════════════
section "guard 2 — parking needs a date or a named trigger"
PID="$("$AIMAIL" ask add --owner alpha --quote "do the thing" --next "alpha does it" --check "test -f $T/never" 2>/dev/null | tail -1)"
rc="$(_run ask touch "$PID" --by alpha --state "blocked" --waiting-on beta)"
[[ "$rc" == 3 ]] && _has "needs --until" < "$T/c.err"; check $? "BAD: a park with no date and no trigger is refused" "rc=$rc"
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$PID *OPEN"; check $? "…and the row stays OPEN, not parked"
rc="$(_run ask touch "$PID" --by alpha --state "blocked" --waiting-on beta --until 2001-01-01)"
[[ "$rc" == 3 ]] && _has "not a future date" < "$T/c.err"; check $? "BAD: a park until a date in the past is refused"
rc="$(_run ask touch "$PID" --by alpha --state "blocked" --waiting-on beta --until not-a-date)"
[[ "$rc" == 3 ]]; check $? "BAD: an unparseable date is refused"
rc="$(_run ask touch "$PID" --by alpha --state "note" --until +3d)"
[[ "$rc" == 3 ]] && _has "only go with --waiting-on" < "$T/c.err"; check $? "BAD: --until without --waiting-on has nothing to attach to"
rc="$(_run ask touch "$PID" --by alpha --state "waiting on beta's review" --waiting-on beta --until +3d)"
[[ "$rc" == 0 ]]; check $? "GOOD: a park with --until +3d is accepted" "rc=$rc"
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$PID *WAITING-ON-BETA"; check $? "the row now reads WAITING-ON-BETA"
"$AIMAIL" ask show "$PID" 2>/dev/null | _has "^park_until: *[1-9]"; check $? "the park date is stored"
"$AIMAIL" ask digest 2>/dev/null | _has "$PID .*until 20"; check $? "ask digest shows the park date"
rc="$(_run ask touch "$PID" --by alpha --state "waiting on the owner's decision" --waiting-on owner --trigger "owner answers the scope question")"
[[ "$rc" == 0 ]]; check $? "GOOD: a park with only a named trigger is accepted"
"$AIMAIL" ask digest 2>/dev/null | _has "trigger: owner answers the scope question"; check $? "ask digest shows the named trigger"
rc="$(_run ask park "$PID" --by alpha --state "parked again" --waiting-on beta)"
[[ "$rc" == 3 ]]; check $? "BAD: the explicit 'ask park' verb enforces the same rule"
rc="$(_run ask park "$PID" --by alpha --state "parked again" --waiting-on beta --until +1d)"
[[ "$rc" == 0 ]]; check $? "GOOD: 'ask park' with --until is accepted"
rc="$(_run ask touch "$PID" --by alpha --state "unblocked" --waiting-on '')"
[[ "$rc" == 0 ]]; check $? "clearing a park (--waiting-on '') needs no date"
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$PID *OPEN"; check $? "…and the row is OPEN again"

section "guard 2 — an expired park brings the row back (it goes STALE and is mailed)"
rc="$(_run ask touch "$PID" --by alpha --state "waiting" --waiting-on beta --until +1d)"
_backdate "$PID" 9 7200                       # untouched for 2h, well past the 2 s stale window
"$AIMAIL" ask sweep >/dev/null 2>&1
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$PID *WAITING-ON-BETA"; check $? "while the park runs the row stays parked despite its age"
[[ ! -d "$AIMAIL_ROOT/mail/sup/unacked" ]] || ! grep -rlq "STALE ask $PID" "$AIMAIL_ROOT/mail/sup/" 2>/dev/null; check $? "…and no stale mail goes out"
_setcol "$PID" 19 "$(( $(date +%s) - 60 ))"   # the park date has now passed
"$AIMAIL" ask list --owner alpha 2>/dev/null | _has "^$PID *STALE"; check $? "BAD→caught: once --until passes the row reads STALE"
"$AIMAIL" ask sweep >/dev/null 2>&1
grep -rlq "STALE ask $PID" "$AIMAIL_ROOT/mail/" 2>/dev/null; check $? "…and the sweep sends the stale mail"
# a legacy park (written before parking needed an end): stays parked, flagged in the digest
LID="$("$AIMAIL" ask add --owner beta --quote "legacy parked thing" --next "n" --check "test -f $T/never2" 2>/dev/null | tail -1)"
_setcol "$LID" 18 "someone"
"$AIMAIL" ask digest 2>/dev/null | _has "$LID .*no date or trigger (legacy park)"; check $? "a legacy park with no end is still listed, flagged as having none"

# ════════════════════════════════════════════════════════════════════════════════════════════
section "guard 3 — a work mail must cite an open ask id"
BODY="$T/body.md"; printf 'please do the work\n' > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Task: trace the overshoot" --body-file "$BODY")"
[[ "$rc" == 3 ]] && _has "must cite the ledger ask" < "$T/c.err"; check $? "BAD: 'Task:' mail with no ledger id is refused" "rc=$rc"
printf 'please do the work, see k9999\n' > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Task: trace the overshoot" --body-file "$BODY")"
[[ "$rc" == 3 ]] && _has "none of the ids it names" < "$T/c.err"; check $? "BAD: a cited id that is not in the ledger is refused"
printf 'please do the work, see %s\n' "$KID" > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Task: trace the overshoot" --body-file "$BODY")"
[[ "$rc" == 0 ]]; check $? "GOOD: the same mail citing an open ask id ($KID) in the body is sent" "rc=$rc"
printf 'plain body\n' > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Assignment: $PID follow-up" --body-file "$BODY")"
[[ "$rc" == 0 ]]; check $? "GOOD: the id may sit in the subject instead"
rc="$(_run send --to beta --from alpha --subject "Task: x" --body-file "$BODY" )"
[[ "$rc" == 3 ]]; check $? "BAD again (control): no id anywhere is still refused after the good sends"
# a closed ask gives the work no home
DID="$("$AIMAIL" ask add --owner beta --quote "closed thing" --next "n" --check "true" 2>/dev/null | tail -1)"
"$AIMAIL" ask sweep >/dev/null 2>&1
printf 'work for %s\n' "$DID" > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Task: more of the closed thing" --body-file "$BODY")"
[[ "$rc" == 3 ]] && _has "OPEN ask" < "$T/c.err"; check $? "BAD: citing an ask that is already done is refused"
printf 'FYI the task list is long, nothing to do\n' > "$BODY"
rc="$(_run send --to beta --from alpha --subject "Re: the task list" --body-file "$BODY")"
[[ "$rc" == 0 ]]; check $? "GOOD: a non-work subject that merely mentions 'task' is not touched"
printf 'no id here\n' > "$BODY"
rc="$(AIMAIL_WORK_MAIL_GUARD=0 _run send --to beta --from alpha --subject "Task: kill switch" --body-file "$BODY")"
[[ "$rc" == 0 ]]; check $? "AIMAIL_WORK_MAIL_GUARD=0 is the kill switch"

# ════════════════════════════════════════════════════════════════════════════════════════════
section "guard 4 — the owner's open-asks digest"
rc="$(_run ask owner-digest)"
[[ "$rc" == 0 ]]; check $? "owner-digest runs"
_has "^OPEN ASKS: [1-9]" < "$T/c.out"; check $? "header gives the number of open asks"
_has "$KID .*seat alpha .*age " < "$T/c.out"; check $? "each ask line carries its seat and age ($KID)"
_has "next: alpha builds" < "$T/c.out"; check $? "…and its next step"
_has "$LID .*seat beta" < "$T/c.out"; check $? "…for every seat's rows"
_has "parked on someone: no date or trigger (legacy park)" < "$T/c.out"; check $? "…with the park end (or its absence) shown"
! _has "$DID" < "$T/c.out"; check $? "a done ask is not listed"
rc="$(_run ask owner-digest --owner alpha)"
! _has "seat beta" < "$T/c.out" && _has "seat alpha" < "$T/c.out"; check $? "--owner filters to one seat"
_hook capture '{"session_id":"s1","prompt":"one more thing to track"}' >/dev/null
rc="$(_run ask owner-digest)"
_has "UNTRIAGED OWNER PROMPTS: 1" < "$T/c.out"; check $? "the digest counts owner prompts that were never triaged (BAD state is visible)"
_has "prompt triage <id> --ask" < "$T/c.out"; check $? "…and says how to resolve them"
"$AIMAIL" prompt triage p0003 --no-ask "informational remark, nothing to do" >/dev/null 2>&1
rc="$(_run ask owner-digest)"
_has "UNTRIAGED OWNER PROMPTS: 0" < "$T/c.out"; check $? "…and the count returns to 0 once triaged"
# empty ledger
rm -f "$AIMAIL_ROOT/state/asks.tsv"
rc="$(_run ask owner-digest)"
_has "(no open asks)" < "$T/c.out"; check $? "an empty ledger says so"

printf '\nSUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ))
