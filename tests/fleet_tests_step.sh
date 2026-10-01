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

# The step has two parts: START (launches the runner in the background, before the Platform tests)
# and COLLECT (waits for it and reads its verdict, after them). START runs from its FLEET_RUNNER=
# line to the closing `fi`; COLLECT from its FLEET_TESTS_EXIT=0 line to the closing `fi`.
START="$TMP/start.sh"; COLLECT="$TMP/collect.sh"
awk '/^FLEET_RUNNER=/ {on=1} on {print} on && /^fi$/ {exit}' "$W" > "$START"
awk '/^FLEET_TESTS_EXIT=0$/ {on=1} on {print} on && /^fi$/ {exit}' "$W" > "$COLLECT"
chk "the start part was found in the wrapper" "$(grep -c FLEET_RUNNER= "$START")" "1"
chk "the collect part was found in the wrapper" "$(grep -c 'wait "\$FLEET_PID"' "$COLLECT")" "1"
chk "the runner is called with --jobs 4" "$(grep -c -- '--fast --jobs 4' "$START")" "1"

run_step() {  # $1 = workspace directory holding fleet_tests
  ( PLATFORM_ROOT="$1/platform" FLEET_WORKSPACE="$1" WORKTREE="$TMP" SEAT=t TS=0 CONDA_PY=bash POC_ROOT=/nowhere
    ENV_ASSIGNMENTS=(X=1)
    source "$START"
    source "$COLLECT"
    echo "EXIT=$FLEET_TESTS_EXIT DESC=$FLEET_TESTS_DESC" )
}
mkhub() {  # $1 = name, $2 = the runner's body
  mkdir -p "$TMP/$1/fleet_tests"; printf '%s\n' "$2" > "$TMP/$1/fleet_tests/run_fleet_tests.py"; }

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

echo "── ARM 4a: a workspace the caller named explicitly, with no runner -- must FAIL, not skip ──"
out=$( PLATFORM_ROOT="$TMP/none/platform" FLEET_WORKSPACE="$TMP/none" FLEET_WORKSPACE_EXPLICIT=yes WORKTREE="$TMP" SEAT=t TS=0 CONDA_PY=bash POC_ROOT=/nowhere ENV_ASSIGNMENTS=(X=1)
       source "$START"; source "$COLLECT"; echo "EXIT=$FLEET_TESTS_EXIT DESC=$FLEET_TESTS_DESC" )
chk "explicit workspace, no runner -> EXIT=1" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=1"
chk "the failure says it was refused" "$(echo "$out" | grep -c 'REFUSED')" "1"

echo "── ARM 4b: the runner runs ALONGSIDE the caller's work, not after it ──"
mkhub slow 'sleep 3; echo "Ran 5 tests in 3s"; exit 0'
elapsed=$( PLATFORM_ROOT="$TMP/slow/platform" FLEET_WORKSPACE="$TMP/slow" WORKTREE="$TMP" SEAT=t TS=0 CONDA_PY=bash POC_ROOT=/nowhere ENV_ASSIGNMENTS=(X=1)
           s0=$(date +%s.%N); source "$START"; s1=$(date +%s.%N)
           echo "$s1 - $s0" | bc )
chk "starting the runner returns at once (well under its 3 s)" "$(echo "$elapsed < 1" | bc)" "1"
t0=$(date +%s)
out=$( PLATFORM_ROOT="$TMP/slow/platform" FLEET_WORKSPACE="$TMP/slow" WORKTREE="$TMP" SEAT=t TS=0 CONDA_PY=bash POC_ROOT=/nowhere ENV_ASSIGNMENTS=(X=1)
       source "$START"; sleep 2; source "$COLLECT"; echo "EXIT=$FLEET_TESTS_EXIT" )
t1=$(date +%s)
chk "start, 2 s of other work, collect: the runner's 3 s overlapped the work (total under 4 s)" "$([ $((t1 - t0)) -lt 4 ] && echo yes || echo no)" "yes"
chk "collect still reads the passing verdict after waiting" "$(echo "$out" | grep -o 'EXIT=[0-9]*' | head -1)" "EXIT=0"
chk "the runner starts before the Platform tests in the wrapper" \
    "$([ "$(grep -n '^ *FLEET_PID=\$!' "$W" | head -1 | cut -d: -f1)" -lt "$(grep -n '^TESTS_STARTED=1' "$W" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" "yes"
chk "a killed gate stops a still-running fleet run" "$(grep -c 'pkill -TERM -P "\$FLEET_PID"' "$W")" "1"

echo "── ARM 5: the wrapper reports and enforces the value ──"
chk "summary line present" "$(grep -c 'summ "FLEET_TESTS_EXIT=' "$W")" "1"
chk "final exit gates on it" "$(grep -c 'exit "\$FLEET_TESTS_EXIT"' "$W")" "1"

echo; echo "fleet_tests_step: $PASS/$((PASS+FAIL)) passed"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILURES[@]}"; exit 1; }
