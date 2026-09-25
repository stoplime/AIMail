#!/usr/bin/env bash
# tests/seat_account.sh — per-seat account detection (seat_account_dir,
# seat_account, _autopilot_seat_groups), added 2026-09-17.
#
# WHY: cron's `budget autopilot` has no CLAUDE_CONFIG_DIR set, so account_id()
# fell through to the shared, mutable ~/.claude symlink -- which pointed at a
# DIFFERENT account than every live fleet seat's own session for 4+ hours,
# blinding the park-at-cap safety net until a hard rate-limit killed every
# session at once. This file proves the fix resolves a seat's REAL account
# from its own live poller process (never a mock), separates genuinely
# different accounts, collapses correctly to the single-account case, and
# falls back cleanly on a dead/missing signal -- never crashing, never
# guessing something new.
#
# Follows tests/run.sh's evidence rules: real background processes stand in
# for "seats" (not a mocked environ), every rejection/fallback arm is paired
# with an accepts arm, exit codes are captured out of pipes, denominator
# printed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-seatacct-test.XXXXXX")"
export AIMAIL_NO_NETWORK=1
# the operator's shell is not part of the fixture -- scrub inherited AIMAIL_* (tests/lib_env.sh);
# this suite keeps CLAUDE_CONFIG_DIR UNSET on purpose (the cron case), so no pin here
# shellcheck source=./lib_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_env.sh"; test_env_sanitize

# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/registry.sh
source "$REPO/lib/registry.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"
# shellcheck source=../lib/budget.sh
source "$REPO/lib/budget.sh"
ensure_dirs

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%r got=%r)\n' "$1" "$3" "$2" 2>/dev/null || printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

# Two REAL fake "account directories" a real background process will carry in
# its own environ -- distinct paths, never touched by the real fleet.
DIR_A="$AIMAIL_ROOT/fake-claude-r2"
DIR_B="$AIMAIL_ROOT/fake-claude-work"
mkdir -p "$DIR_A" "$DIR_B"

declare -a SPAWNED_PIDS=()
spawn_seat() {
  # A real background process carrying a REAL CLAUDE_CONFIG_DIR in its own
  # /proc/<pid>/environ -- exactly what a live seat's poller process is.
  local seat="$1" cfg_dir="$2"
  env CLAUDE_CONFIG_DIR="$cfg_dir" sleep 300 &
  local pid=$!
  SPAWNED_PIDS+=("$pid")
  hb_start "$seat"
  hb_write "$seat" pid "$pid"   # hb_start already wrote $$ (this test script's own pid) -- overwrite with the real spawned one
}
cleanup() { local p; for p in "${SPAWNED_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$AIMAIL_ROOT"; }
trap cleanup EXIT

echo "── ARM 1: seat_account_dir reads a REAL live process's REAL environ, not a mock ──"
spawn_seat seat_a "$DIR_A"
spawn_seat seat_b "$DIR_B"
sleep 0.3   # let the kernel populate /proc for the just-spawned pids
got_a="$(seat_account_dir seat_a)"
got_b="$(seat_account_dir seat_b)"
chk "seat_a resolves to its own real CLAUDE_CONFIG_DIR" "$got_a" "$(readlink -f "$DIR_A")"
chk "seat_b resolves to its own real CLAUDE_CONFIG_DIR" "$got_b" "$(readlink -f "$DIR_B")"
chk "the two seats resolve to DIFFERENT directories (real separation, not a coincidence)" \
  "$([ "$got_a" != "$got_b" ] && echo yes || echo no)" "yes"
chk "seat_account() applies the same basename/sed transform as account_id()" \
  "$(seat_account seat_a)" "$(basename "$got_a" | sed 's/^\.//; s/^claude-//; s/^claude$/default/')"

echo "── ARM 2: dead pid falls back cleanly to account_id() (never crashes, never guesses) ──"
# A pid that is DEFINITELY dead: spawn, wait for exit, reuse its number.
( exit 0 ) & dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
hb_start seat_dead
hb_write seat_dead pid "$dead_pid"
got_dead="$(seat_account_dir seat_dead)"
chk "dead pid -> seat_account_dir returns EMPTY (no crash, no stale guess)" "$got_dead" ""
chk "seat_account() on a dead pid falls back to account_id()'s current reading" \
  "$(seat_account seat_dead)" "$(account_id)"

echo "── ARM 3: NEVER (no heartbeat ever written) falls back cleanly too ──"
chk "no .hb file at all -> seat_account_dir returns EMPTY" "$(seat_account_dir seat_never_existed_xyz)" ""
chk "seat_account() with no heartbeat falls back to account_id()" \
  "$(seat_account seat_never_existed_xyz)" "$(account_id)"

echo "── ARM 4: two live seats on genuinely different accounts -> two separate groups ──"
seat_add() { printf '%s\tactive\t\t%s\n' "$1" "${2:-test seat}" >> "$SEATS_FILE"; }
: > "$SEATS_FILE"
seat_add seat_a
seat_add seat_b
groups="$(_autopilot_seat_groups)"
n_lines="$(printf '%s\n' "$groups" | grep -c .)"
chk "exactly 2 groups for 2 seats on 2 different accounts" "$n_lines" "2"
line_a="$(printf '%s\n' "$groups" | awk -F'\t' -v d="$got_a" '$1==d')"
line_b="$(printf '%s\n' "$groups" | awk -F'\t' -v d="$got_b" '$1==d')"
chk "seat_a's own group lists exactly seat_a" "$(cut -f3 <<<"$line_a")" "seat_a"
chk "seat_b's own group lists exactly seat_b" "$(cut -f3 <<<"$line_b")" "seat_b"

echo "── ARM 5: two live seats on the SAME account -> ONE group, both seats listed (the common-case collapse) ──"
spawn_seat seat_c "$DIR_A"   # same directory as seat_a
sleep 0.3
: > "$SEATS_FILE"
seat_add seat_a
seat_add seat_c
groups2="$(_autopilot_seat_groups)"
n_lines2="$(printf '%s\n' "$groups2" | grep -c .)"
chk "exactly 1 group when both live seats share one account" "$n_lines2" "1"
seats_field="$(cut -f3 <<<"$groups2")"
chk "that one group's seat list contains seat_a" "$(grep -cw seat_a <<<"$seats_field")" "1"
chk "that one group's seat list contains seat_c" "$(grep -cw seat_c <<<"$seats_field")" "1"
chk "the collapsed group's dir is the SAME real dir the ambient env would already resolve to when CLAUDE_CONFIG_DIR is set to it (a no-op override in the true single-account case)" \
  "$(cut -f1 <<<"$groups2")" "$got_a"

echo "── ARM 6: a seat with NO live signal is folded into the AMBIENT fallback group, not dropped ──"
: > "$SEATS_FILE"
seat_add seat_a           # live, resolves to DIR_A
seat_add seat_never_existed_xyz   # no heartbeat at all
groups3="$(CLAUDE_CONFIG_DIR="$DIR_B" _autopilot_seat_groups)"   # ambient != DIR_A, on purpose
n_lines3="$(printf '%s\n' "$groups3" | grep -c .)"
chk "unresolved seat does NOT vanish -- gets its own fallback group distinct from seat_a's" "$n_lines3" "2"
fallback_line="$(printf '%s\n' "$groups3" | awk -F'\t' '$1==""')"
chk "the fallback group's dir field is EMPTY (caller must not override CLAUDE_CONFIG_DIR for it)" \
  "$(cut -f1 <<<"$fallback_line")" ""
chk "the fallback group carries the unresolved seat" "$(grep -cw seat_never_existed_xyz <<<"$fallback_line")" "1"

echo "── ARM 7: an unresolved seat folds INTO an existing group when the ambient happens to match it (no duplicate account probed twice) ──"
groups4="$(CLAUDE_CONFIG_DIR="$DIR_A" _autopilot_seat_groups)"   # ambient == seat_a's own real account this time
n_lines4="$(printf '%s\n' "$groups4" | grep -c .)"
chk "exactly ONE group when the unresolved seat's ambient fallback matches a real seat's own account" "$n_lines4" "1"
chk "that one group contains BOTH the live seat and the folded-in unresolved one" \
  "$(cut -f3 <<<"$groups4" | grep -cw seat_a)$(cut -f3 <<<"$groups4" | grep -cw seat_never_existed_xyz)" "11"

echo "── ARM 7b: a CONFIRMED seat with NO live process resolves to its RECORDED account (the 04:05 parked-r2 gap) ──"
: > "$SEATS_FILE"
seat_add seat_parked
DIR_R="$(mktemp -d "$AIMAIL_ROOT/acct-recorded.XXXX")"; export AIMAIL_ACCOUNT_DIR_recorded="$DIR_R"
mkdir -p "$AIMAIL_ROOT/state/seat_account"; printf 'seat\tseat_parked\naccount\trecorded\nsession_id\tdeadbeef\n' > "$AIMAIL_ROOT/state/seat_account/seat_parked"
groups7b="$(CLAUDE_CONFIG_DIR="$DIR_B" _autopilot_seat_groups)"
chk "no heartbeat, but a seat record naming account 'recorded' -> its own group, NOT the ambient fallback" "$(printf '%s\n' "$groups7b" | awk -F'\t' '$2=="recorded"{print $3}')" "seat_parked"
chk "…and that group's dir is the recorded account's dir, so the tick can probe and ramp it" "$(printf '%s\n' "$groups7b" | awk -F'\t' '$2=="recorded"{print $1}')" "$(readlink -f "$DIR_R")"
chk "…no ambient fallback group was created for it" "$(printf '%s\n' "$groups7b" | awk -F'\t' '$1==""' | grep -c .)" "0"
rm -f "$AIMAIL_ROOT/state/seat_account/seat_parked"; unset AIMAIL_ACCOUNT_DIR_recorded

echo "── ARM 8: budget_autopilot's own wrapper falls all the way back to a bare, single tick when NOTHING resolves (empty registry) ──"
: > "$SEATS_FILE"
groups5="$(_autopilot_seat_groups)"
chk "empty registry -> _autopilot_seat_groups prints nothing" "$groups5" ""

echo "── ARM 9: budget_autopilot() itself actually dispatches per group, with CLAUDE_CONFIG_DIR really reaching the callee ──"
# Replace the real tick with a recorder so this proves the WRAPPER's own
# dispatch logic (not the grouping helper in isolation, already proven above).
declare -a _TICK_CALLS=()
_budget_autopilot_tick() {
  _TICK_CALLS+=("acct=${1:-<none>} seats=[${2:-}] cfg=${CLAUDE_CONFIG_DIR:-<unset>}")
}
: > "$SEATS_FILE"
seat_add seat_a   # live, DIR_A
seat_add seat_b   # live, DIR_B (still running from ARM 1/4)
_TICK_CALLS=()
budget_autopilot
chk "two live seats on two accounts -> the tick ran exactly twice" "${#_TICK_CALLS[@]}" "2"
joined="$(printf '%s\n' "${_TICK_CALLS[@]}")"
chk "one call really saw CLAUDE_CONFIG_DIR=DIR_A inside the callee" \
  "$(grep -c "cfg=$got_a" <<<"$joined")" "1"
chk "one call really saw CLAUDE_CONFIG_DIR=DIR_B inside the callee" \
  "$(grep -c "cfg=$got_b" <<<"$joined")" "1"

: > "$SEATS_FILE"
seat_add seat_a
seat_add seat_c   # live, SAME dir as seat_a (DIR_A) -- the common-case collapse
_TICK_CALLS=()
budget_autopilot
chk "two live seats on the SAME account -> the tick ran exactly ONCE (no duplicate probe)" "${#_TICK_CALLS[@]}" "1"
chk "that one call's seat list carries both seat_a and seat_c" \
  "$(grep -cw seat_a <<<"${_TICK_CALLS[0]}")$(grep -cw seat_c <<<"${_TICK_CALLS[0]}")" "11"

: > "$SEATS_FILE"
_TICK_CALLS=()
budget_autopilot
chk "empty registry -> falls back to exactly one bare, unparameterized tick call" "${#_TICK_CALLS[@]}" "1"
chk "that bare call carries no acct/seat params (today's exact pre-2026-09-17 shape)" \
  "${_TICK_CALLS[0]}" "acct=<none> seats=[] cfg=${CLAUDE_CONFIG_DIR:-<unset>}"
unset -f _budget_autopilot_tick   # restore -- re-source would also work, this is cheaper
source "$REPO/lib/budget.sh"

echo
echo "── $PASS/$((PASS+FAIL)) passed ──"
if (( FAIL > 0 )); then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
