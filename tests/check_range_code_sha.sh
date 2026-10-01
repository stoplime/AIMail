#!/usr/bin/env bash
# tests/check_range_code_sha.sh — the code_sha-over-every-JSON range guard's own tests.
#
# WHY: a manual code_sha sweep found a9ec29542's
# corpus-manifest JSON carrying a pre-rebase code_sha, by hand -- named as a gap the
# existing probe-only pre-ff check didn't cover mechanically. bin/check_range_code_sha.py
# is that mechanical widening; this file proves it actually refuses a real mismatch,
# passes clean on a genuinely consistent range, and correctly ignores JSON that isn't
# part of the convention at all (no code_sha field, or not valid JSON).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${CHECK_RANGE:-$(dirname "$HERE")/bin/check_range_code_sha.py}"

PASS=0; FAIL=0; declare -a FAILURES=()
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
        else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
cd "$REPO"
git init -q
git config user.email "test@test"
git config user.name "test"

echo '{"note": "not part of the convention"}' > plain.json
git add plain.json
git commit -q -m "base"
BASE_SHA=$(git rev-parse HEAD)

echo "── ARM 1: a JSON with no code_sha field at all -- must be ignored, not a mismatch ──"
git commit -q --allow-empty -m "empty commit, no json touched"
NO_FIELD_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$BASE_SHA" "$NO_FIELD_SHA" --repo "$REPO" 2>&1); rc=$?
chk "no-json-touched commit exits 0" "$rc" "0"
chk "reports 0 JSON checked" "$(printf '%s' "$out" | grep -oE '[0-9]+ JSON')" "0 JSON"

echo "── ARM 2: a real, correctly-stamped code_sha (equals its own commit's real parent) -- must pass ──"
CORRECT_PARENT=$(git rev-parse HEAD)
python3 -c "import json; json.dump({'code_sha': '$CORRECT_PARENT', 'n': 1}, open('probe.json', 'w'))"
git add probe.json
git commit -q -m "probe output, correctly stamped"
GOOD_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$CORRECT_PARENT" "$GOOD_SHA" --repo "$REPO" 2>&1); rc=$?
chk "correctly-stamped code_sha exits 0" "$rc" "0"
chk "reports PASSED" "$(printf '%s' "$out" | grep -c 'PASSED')" "1"
chk "reports 1 JSON checked" "$(printf '%s' "$out" | grep -oE '[0-9]+ JSON' | head -1)" "1 JSON"

echo "── ARM 3: a stale/carried-forward code_sha (does NOT equal its own commit's real parent) -- must REFUSE ──"
STALE_PARENT_BEFORE=$(git rev-parse HEAD)
python3 -c "import json; json.dump({'code_sha': 'deadbeef0000000000000000000000000000000', 'n': 2}, open('probe.json', 'w'))"
git add probe.json
git commit -q -m "probe output, STALE code_sha (simulates a carried-forward rebase)"
STALE_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$STALE_PARENT_BEFORE" "$STALE_SHA" --repo "$REPO" 2>&1); rc=$?
chk "stale code_sha REFUSED (exit 2)" "$rc" "2"
chk "refusal names the file" "$(printf '%s' "$out" | grep -c 'probe.json')" "1"
chk "refusal shows the claimed value" "$(printf '%s' "$out" | grep -c 'deadbeef')" "1"
chk "refusal shows the real parent" "$(printf '%s' "$out" | grep -c "real parent is:  $STALE_PARENT_BEFORE")" "1"

echo "── ARM 4: a JSON deleted at a later commit -- must be ignored (nothing left to check) ──"
DELETE_BASE=$(git rev-parse HEAD)
git rm -q probe.json
git commit -q -m "delete probe output"
DELETE_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$DELETE_BASE" "$DELETE_SHA" --repo "$REPO" 2>&1); rc=$?
chk "deleting a code_sha-bearing json exits 0 (nothing to check post-delete)" "$rc" "0"

echo "── ARM 2.5: a probe-lane JSON stamped with the ALIAS code_sha_at_generation (correct value) -- must PASS, same as the real key ──"
mkdir -p tools/audit_probes
ALIAS_GOOD_PARENT=$(git rev-parse HEAD)
python3 -c "import json; json.dump({'code_sha_at_generation': '$ALIAS_GOOD_PARENT', 'n': 5}, open('tools/audit_probes/alias_good.json', 'w'))"
git add tools/audit_probes/alias_good.json
git commit -q -m "probe output, correctly-stamped ALIAS field"
ALIAS_GOOD_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$ALIAS_GOOD_PARENT" "$ALIAS_GOOD_SHA" --repo "$REPO" 2>&1); rc=$?
chk "correctly-stamped alias exits 0" "$rc" "0"
chk "alias reports PASSED" "$(printf '%s' "$out" | grep -c 'PASSED')" "1"
chk "alias reports 1 JSON checked" "$(printf '%s' "$out" | grep -oE '[0-9]+ JSON' | head -1)" "1 JSON"

echo "── ARM 2.6: the ALIAS field, but STALE (does not equal the real parent) -- must REFUSE, same comparison as the real key ──"
ALIAS_STALE_BEFORE=$(git rev-parse HEAD)
python3 -c "import json; json.dump({'code_sha_at_generation': 'deadbeef0000000000000000000000000000000', 'n': 6}, open('tools/audit_probes/alias_stale.json', 'w'))"
git add tools/audit_probes/alias_stale.json
git commit -q -m "probe output, STALE alias code_sha_at_generation"
ALIAS_STALE_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$ALIAS_STALE_BEFORE" "$ALIAS_STALE_SHA" --repo "$REPO" 2>&1); rc=$?
chk "stale alias REFUSED (exit 2)" "$rc" "2"
chk "stale-alias refusal names the file" "$(printf '%s' "$out" | grep -c 'alias_stale.json')" "1"

echo "── ARM 5.5: a tools/audit_probes/*.json with NO code_sha field -- must REFUSE (fable's 88c382733 follow-up, absence is a defect in this one lane) ──"
mkdir -p tools/audit_probes
NO_FIELD_PROBE_BASE=$(git rev-parse HEAD)
echo '{"n": 3}' > tools/audit_probes/some_census.json
git add tools/audit_probes/some_census.json
git commit -q -m "probe output, NO code_sha field at all"
NO_FIELD_PROBE_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$NO_FIELD_PROBE_BASE" "$NO_FIELD_PROBE_SHA" --repo "$REPO" 2>&1); rc=$?
chk "probe-lane missing code_sha REFUSED (exit 2)" "$rc" "2"
chk "refusal names the probe path" "$(printf '%s' "$out" | grep -c 'tools/audit_probes/some_census.json')" "1"
chk "refusal says MISSING, not MISMATCH" "$(printf '%s' "$out" | grep -c 'MISSING code_sha')" "1"

echo "── ARM 5.6: same shape, but OUTSIDE the probe lane -- must still SKIP (exit 0) ──"
OUTSIDE_BASE=$(git rev-parse HEAD)
echo '{"n": 4}' > other_dir_plain.json
mkdir -p other_dir_plain.json.d 2>/dev/null || true
rm -rf other_dir_plain.json.d
git add other_dir_plain.json
git commit -q -m "non-probe output, no code_sha field"
OUTSIDE_SHA=$(git rev-parse HEAD)
out=$(python3 "$C" "$OUTSIDE_BASE" "$OUTSIDE_SHA" --repo "$REPO" 2>&1); rc=$?
chk "non-probe-lane missing code_sha still exits 0" "$rc" "0"

echo "── ARM 5: usage errors -- an unresolvable ref, a non-repo --repo ──"
out=$(python3 "$C" "not-a-real-ref" HEAD --repo "$REPO" 2>&1); rc=$?
chk "unresolvable base-ref exits 1" "$rc" "1"
NOTREPO="$(mktemp -d)"
out=$(python3 "$C" HEAD HEAD --repo "$NOTREPO" 2>&1); rc=$?
chk "non-repo --repo exits 1" "$rc" "1"
rm -rf "$NOTREPO"

echo
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILURES: %s\n' "${FAILURES[*]}"
    exit 1
fi
exit 0
