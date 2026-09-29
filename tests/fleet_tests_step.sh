#!/usr/bin/env bash
# tests/fleet_tests_step.sh -- the FLEET_TESTS_EXIT step of bin/run_canonical_battery.sh.
#
# WHY: the step runs the guard tests kept outside the product repository. If it could pass without
# running them (a missing Ran line, a crashed runner) the guards would protect nothing while looking
# green. This extracts the step's own block from the wrapper and runs it against stub runners:
# a passing runner must give 0; a failing runner and a runner that prints no Ran line must give 1;
# a hub without the runner must skip with a reason and give 0; the wrapper's summary and final exit
# must both carry the value.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W="${WRAPPER:-$(dirname "$HERE")/bin/run_canonical_battery.sh}"

PASS=0; FAIL=0; declare -a FAILURES=()
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
        else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# The step's block: from its FLEET_TESTS_EXIT=0 line to the closing `fi` at column 0.
BLOCK="$TMP/block.sh"
awk '/^FLEET_TESTS_EXIT=0$/ {on=1} on {print} on && /^fi$/ {exit}' "$W" > "$BLOCK"
chk "the step's block was found in the wrapper" "$(grep -c FLEET_RUNNER= "$BLOCK")" "1"

run_step() {  # $1 = hub directory holding zignore/fleet_tests
  ( PLATFORM_ROOT="$1" WORKTREE="$TMP" SEAT=t TS=0 CONDA_PY=bash POC_ROOT=/nowhere
    ENV_ASSIGNMENTS=(X=1)
    source "$BLOCK"
    echo "EXIT=$FLEET_TESTS_EXIT DESC=$FLEET_TESTS_DESC" )
}
mkhub() {  # $1 = name, $2 = the runner's body
  mkdir -p "$TMP/$1/zignore/fleet_tests"; printf '%s\n' "$2" > "$TMP/$1/zignore/fleet_tests/run_fleet_tests.py"; }

echo "── ARM 1: a runner that ran tests and passed -- must give 0 (positive control) ──"
mkhub pass 'echo "Ran 5 tests in 0.1s"; exit 0'
out=$(run_step "$TMP/pass"); chk "passing runner -> EXIT=0" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=0"
chk "the Ran line is carried into the description" "$(echo "$out" | grep -c 'Ran 5 tests')" "1"

echo "── ARM 2: a runner that fails -- must give 1 ──"
mkhub fail 'echo "Ran 5 tests in 0.1s"; exit 1'
out=$(run_step "$TMP/fail"); chk "failing runner -> EXIT=1" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=1"

echo "── ARM 3: a runner that exits 0 but printed no Ran line -- must give 1 ──"
mkhub silent 'echo "nothing ran"; exit 0'
out=$(run_step "$TMP/silent"); chk "no Ran line -> EXIT=1" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=1"

echo "── ARM 3b: a runner that ran zero tests, and one whose only 'Ran' is inside other text -- must give 1 ──"
mkhub zero 'echo "Ran 0 tests in 0.0s"; exit 0'
out=$(run_step "$TMP/zero"); chk "Ran 0 tests -> EXIT=1" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=1"
mkhub junk 'echo "Ran into a problem but exiting cleanly"; exit 0'
out=$(run_step "$TMP/junk"); chk "a stray 'Ran ...' sentence is not a Ran line -> EXIT=1" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=1"

echo "── ARM 4: a hub with no runner -- must skip, say why, and give 0 ──"
mkdir -p "$TMP/none"
out=$(run_step "$TMP/none"); chk "no runner -> EXIT=0" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=0"
chk "the skip says it did not run" "$(echo "$out" | grep -c 'not run')" "1"

echo "── ARM 5: the wrapper reports and enforces the value ──"
chk "summary line present" "$(grep -c 'summ "FLEET_TESTS_EXIT=' "$W")" "1"
chk "final exit gates on it" "$(grep -c 'exit "\$FLEET_TESTS_EXIT"' "$W")" "1"

echo; echo "fleet_tests_step: $PASS/$((PASS+FAIL)) passed"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILURES[@]}"; exit 1; }
