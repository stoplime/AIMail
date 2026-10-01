#!/usr/bin/env bash
# tests/check_battery_summary.sh -- check_battery_summary.sh's own tests.
#
# WHY: the acceptance rule is "a gate recipe refuses a run with no summary file; refuses a
# summary whose worktree HEAD doesn't match the requested tip" -- this proves both refusals fire,
# and that a genuine match passes,
# using real files in a disposable temp dir, matching this repo's own safe_sync.sh/
# check_range_code_sha.sh test convention.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${CHECK_SUMMARY:-$(dirname "$HERE")/bin/check_battery_summary.sh}"

PASS=0; FAIL=0; declare -a FAILURES=()
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
        else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FULL_SHA="4a33efb4d4fb32ab27aa51489111760a2d0bd519"
OTHER_SHA="9a7bf737cfb5a06835318c505d8d0ed3b576cb90"

echo "── ARM 1: no summary file at all -- must REFUSE (exit 2) ──"
out=$(bash "$C" "$TMP/does-not-exist.summary" "$FULL_SHA" 2>&1); rc=$?
chk "missing summary file exits 2" "$rc" "2"
chk "refusal names 'no summary file'" "$(printf '%s' "$out" | grep -c 'no summary file')" "1"

echo "── ARM 2: a real summary whose worktree HEAD matches (full sha) -- must PASS (exit 0) ──"
GOOD="$TMP/good.summary"
cat > "$GOOD" <<EOF
▶ gate mode:       full
▶ worktree:        /some/worktree
▶ worktree HEAD:   $FULL_SHA
gate=full
Ran 100 tests in 1.0s
OK
BATTERY_EXIT=0
CORPUS_EXIT=0
COUNT_EXIT=0 (...)
NAME_SET_EXIT=0 (...)
REAL_TIER_EXIT=0 (...)
SKIP_NAMES_EXIT=0 (...)
EOF
out=$(bash "$C" "$GOOD" "$FULL_SHA" 2>&1); rc=$?
chk "matching worktree HEAD (full sha) exits 0" "$rc" "0"
chk "reports a match" "$(printf '%s' "$out" | grep -c 'matches the requested tip')" "1"

echo "── ARM 3: a real summary whose worktree HEAD matches a SHORT PREFIX -- must PASS (exit 0) ──"
out=$(bash "$C" "$GOOD" "${FULL_SHA:0:8}" 2>&1); rc=$?
chk "matching worktree HEAD (short prefix) exits 0" "$rc" "0"

echo "── ARM 4: a real summary whose worktree HEAD does NOT match -- must REFUSE (exit 3) ──"
out=$(bash "$C" "$GOOD" "$OTHER_SHA" 2>&1); rc=$?
chk "mismatched worktree HEAD exits 3" "$rc" "3"
chk "refusal names the mismatch" "$(printf '%s' "$out" | grep -c 'does not match')" "1"

echo "── ARM 5: a summary with NO worktree HEAD line at all -- must REFUSE (exit 3) ──"
NO_HEAD="$TMP/no_head.summary"
printf 'gate=full\nRan 1 tests in 0.1s\nOK\n' > "$NO_HEAD"
out=$(bash "$C" "$NO_HEAD" "$FULL_SHA" 2>&1); rc=$?
chk "no worktree HEAD line exits 3" "$rc" "3"

echo "── ARM 6: a summary with TWO worktree HEAD lines -- must REFUSE (exit 3), ambiguous ──"
TWO_HEAD="$TMP/two_head.summary"
printf '▶ worktree HEAD:   %s\n▶ worktree HEAD:   %s\n' "$FULL_SHA" "$OTHER_SHA" > "$TWO_HEAD"
out=$(bash "$C" "$TWO_HEAD" "$FULL_SHA" 2>&1); rc=$?
chk "two worktree HEAD lines exits 3" "$rc" "3"

echo "── ARM 7: usage error -- wrong argument count ──"
out=$(bash "$C" "$GOOD" 2>&1); rc=$?
chk "missing second arg exits 1" "$rc" "1"

echo "── ARM 8: worktree HEAD matches, but the summary is TRUNCATED (a killed battery) -- must REFUSE (exit 4) ──"
TRUNCATED="$TMP/truncated.summary"
cat > "$TRUNCATED" <<EOF
▶ gate mode:       full
▶ worktree:        /some/worktree
▶ worktree HEAD:   $FULL_SHA
EOF
out=$(bash "$C" "$TRUNCATED" "$FULL_SHA" 2>&1); rc=$?
chk "truncated summary (HEAD matches, no trailer) exits 4" "$rc" "4"
chk "refusal names it INCOMPLETE once per missing exit line (all 6 missing here)" \
    "$(printf '%s' "$out" | grep -c 'INCOMPLETE')" "6"

echo "── ARM 9: worktree HEAD matches, one exit line DUPLICATED -- must REFUSE (exit 4), ambiguous ──"
DUPE_EXIT="$TMP/dupe_exit.summary"
cat > "$DUPE_EXIT" <<EOF
▶ worktree HEAD:   $FULL_SHA
BATTERY_EXIT=0
BATTERY_EXIT=1
CORPUS_EXIT=0
COUNT_EXIT=0
NAME_SET_EXIT=0
REAL_TIER_EXIT=0
SKIP_NAMES_EXIT=0
EOF
out=$(bash "$C" "$DUPE_EXIT" "$FULL_SHA" 2>&1); rc=$?
chk "duplicated exit line exits 4" "$rc" "4"

echo "── ARM 10: worktree HEAD matches, all six exit lines present exactly once -- must PASS (exit 0) ──"
chk "the ARM 2 good file (already has all six) still exits 0" "$(bash "$C" "$GOOD" "$FULL_SHA" > /dev/null 2>&1; echo $?)" "0"

echo "── ARM 11: worktree HEAD matches, summary complete, but BATTERY_EXIT is not 0 -- must REFUSE (exit 5) ──"
RED="$TMP/red.summary"
cat > "$RED" <<EOF
▶ worktree HEAD:   $FULL_SHA
Ran 100 tests in 1.0s
FAILED (failures=3)
BATTERY_EXIT=1
CORPUS_EXIT=0
COUNT_EXIT=0
NAME_SET_EXIT=0
REAL_TIER_EXIT=0
SKIP_NAMES_EXIT=0
EOF
out=$(bash "$C" "$RED" "$FULL_SHA" 2>&1); rc=$?
chk "BATTERY_EXIT=1 (tree-matched, complete) exits 5" "$rc" "5"
chk "refusal names the non-zero BATTERY_EXIT" "$(printf '%s' "$out" | grep -c 'BATTERY_EXIT=1')" "1"
chk "a genuinely green summary (ARM 2's GOOD file) is unaffected -- still exits 0" \
    "$(bash "$C" "$GOOD" "$FULL_SHA" > /dev/null 2>&1; echo $?)" "0"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %s\n' "${FAILURES[@]}" >&2
    exit 1
fi
