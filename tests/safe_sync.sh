#!/usr/bin/env bash
# tests/safe_sync.sh — the refuse-loudly guard's own dirty-detection.
#
# WHY: 2026-08-31, T-313 — a bare `git checkout <ref> -- <path>` silently destroyed
# an out-of-protocol uncommitted edit during a protocol-compliant landing's own sync
# step. `bin/safe_sync.sh` exists to make that class of loss impossible without a
# human decision in between. This file proves it actually refuses (⑤ exit codes
# captured, not swallowed), that a real destruction is what the mutation arm
# reproduces (③ paired accepts control), and that the clean path — including the
# ORDINARY POST-LANDING STATE where HEAD has already moved but the working tree
# hasn't caught up yet, which a naive HEAD-relative dirty check would misfire on —
# is unaffected.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="${SAFE_SYNC:-$(dirname "$HERE")/bin/safe_sync.sh}"

PASS=0; FAIL=0; declare -a FAILURES=()
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
        else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

REPO="$(mktemp -d)"
trap 'rm -rf "$REPO"' EXIT
cd "$REPO"
git init -q
git config user.email "test@test"
git config user.name "test"
echo "line one" > TODO.md
echo "unrelated" > unrelated.txt
git add TODO.md unrelated.txt
git commit -q -m "base"
OLD_SHA=$(git rev-parse HEAD)

echo "line one, edited by the landing" > TODO.md
git add TODO.md
git commit -q -m "the landing's own commit"
NEW_SHA=$(git rev-parse HEAD)

# Simulate the REAL post-landing moment throughout: HEAD has already been
# fast-forwarded to NEW_SHA via update-ref (git commit above already did that,
# same effect), but the WORKING TREE still holds OLD_SHA's content until sync
# runs -- exactly what the shared checkout looks like right after a detached
# worktree's own `git update-ref` moves the branch out from under it.
reset_to_pre_sync_state() { git checkout -q "$OLD_SHA" -- TODO.md unrelated.txt; }

echo "── ARM 1: the ORDINARY post-landing state (HEAD moved, worktree hasn't caught up) — must NOT false-positive ──"
reset_to_pre_sync_state
out=$("$S" "$OLD_SHA" "$NEW_SHA" TODO.md 2>&1); rc=$?
chk "ordinary sync exits 0 (this is the state a bad HEAD-relative check misfires on)" "$rc" "0"
chk "ordinary sync reports the file synced" "$(printf '%s' "$out" | grep -c "synced 'TODO.md'")" "1"
chk "content actually updated to the landed version" "$(cat TODO.md)" "line one, edited by the landing"

echo "── ARM 2: the actual incident, replayed — a live foreign edit on disk must be REFUSED, not clobbered ──"
reset_to_pre_sync_state
echo "line one" > TODO.md
echo "SOMEONE ELSE'S uncommitted block, out of protocol" >> TODO.md
out=$("$S" "$OLD_SHA" "$NEW_SHA" TODO.md 2>&1); rc=$?
chk "dirty sync REFUSED (exit 2)" "$rc" "2"
chk "refusal names the file" "$(printf '%s' "$out" | grep -c 'REFUSED')" "1"
chk "the foreign content is UNTOUCHED, not clobbered" \
    "$(grep -c "SOMEONE ELSE'S uncommitted block" TODO.md)" "1"
chk "the foreign diff is printed for the decision" \
    "$(printf '%s' "$out" | grep -c "SOMEONE ELSE'S uncommitted block")" "1"

echo "── ARM 3: staged-but-uncommitted must ALSO refuse (git add without commit is the same loss shape) ──"
reset_to_pre_sync_state
echo "staged foreign edit" >> TODO.md
git add TODO.md
out=$("$S" "$OLD_SHA" "$NEW_SHA" TODO.md 2>&1); rc=$?
chk "staged-dirty sync REFUSED too" "$rc" "2"
chk "staged content untouched" "$(grep -c 'staged foreign edit' TODO.md)" "1"
git reset -q TODO.md

echo "── ARM 4: multiple paths — one dirty path must block the WHOLE call, touch NOTHING ──"
echo "unrelated, edited by the landing" > unrelated.txt
git add unrelated.txt
git commit -q -m "unrelated file also changes at this landing"
NEW_SHA2=$(git rev-parse HEAD)
git checkout -q "$OLD_SHA" -- TODO.md unrelated.txt
echo "foreign dirt" >> TODO.md
out=$("$S" "$OLD_SHA" "$NEW_SHA2" TODO.md unrelated.txt 2>&1); rc=$?
chk "multi-path call REFUSED on the one dirty path" "$rc" "2"
chk "the OTHER, clean path was not synced either (all-or-nothing)" "$(cat unrelated.txt)" "unrelated"

echo "── ARM 5: nonexistent ref / path — a real setup error, not a silent no-op ──"
out=$("$S" "$OLD_SHA" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" TODO.md 2>&1); rc=$?
chk "unresolvable new-ref exits 3" "$rc" "3"
out=$("$S" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$NEW_SHA2" TODO.md 2>&1); rc=$?
chk "unresolvable old-ref exits 3" "$rc" "3"
out=$("$S" "$OLD_SHA" "$NEW_SHA2" no_such_file.md 2>&1); rc=$?
chk "path absent at new-ref exits 3" "$rc" "3"

echo "── ARM 6: usage error is distinct from every real-refusal code ──"
out=$("$S" 2>&1); rc=$?
chk "no args exits 1 (usage), not 0/2/3" "$rc" "1"
out=$("$S" "$OLD_SHA" "$NEW_SHA2" 2>&1); rc=$?
chk "refs with no paths exits 1 (usage)" "$rc" "1"

echo "── ARM 7 — the guard-the-instrument control: prove the test WOULD catch the bare-checkout regression ──"
# Simulate what the OLD, unguarded procedure did: a bare `git checkout <ref> --
# <path>` with no dirty check at all. This is not testing safe_sync.sh itself —
# it is proving arm 2's fixture is a real destruction, not a decoy, by showing
# the naive command actually clobbers it.
reset_to_pre_sync_state
echo "line one" > TODO.md
echo "SOMEONE ELSE'S uncommitted block, out of protocol" >> TODO.md
git checkout "$NEW_SHA" -- TODO.md
chk "the bare checkout (no guard) DOES destroy the foreign edit -- confirms arm 2 is real" \
    "$(grep -c "SOMEONE ELSE'S uncommitted block" TODO.md)" "0"

echo "── ARM 8 (2026-09-03, fable's ruling): ancestry guard catches a reversed old/new argument order ──"
# The suspected mechanism behind a real incident: a caller invoking
# safe_sync.sh with old-ref and new-ref SWAPPED. new_ref must descend from
# old_ref; passing NEW_SHA2 as old and OLD_SHA as new is exactly backwards
# (OLD_SHA does NOT descend from NEW_SHA2) and must be refused before any
# checkout runs, regardless of what's on disk.
reset_to_pre_sync_state
out=$("$S" "$NEW_SHA2" "$OLD_SHA" TODO.md 2>&1); rc=$?
chk "reversed old/new argument order exits 3 (ancestry guard)" "$rc" "3"
chk "ancestry refusal names the guard" "$(printf '%s' "$out" | grep -c 'ancestry guard')" "1"
chk "nothing was touched by the refused reversed call" "$(cat TODO.md)" "line one"

echo "── ARM 9 (2026-09-03): a same-ref call (old==new, a legitimate no-op re-sync) is NOT refused by the ancestry guard ──"
reset_to_pre_sync_state
git checkout -q "$NEW_SHA2" -- TODO.md unrelated.txt
out=$("$S" "$NEW_SHA2" "$NEW_SHA2" TODO.md 2>&1); rc=$?
chk "old==new exits 0 (a commit is its own ancestor)" "$rc" "0"

echo "── ARM 10 (2026-09-03): post-sync assertion — a real sync still reports verified-clean, not just 'synced' ──"
reset_to_pre_sync_state
out=$("$S" "$OLD_SHA" "$NEW_SHA2" TODO.md unrelated.txt 2>&1); rc=$?
chk "real sync with the new post-checkout assertion still exits 0" "$rc" "0"
chk "success message now says verified-clean, not just synced" \
    "$(printf '%s' "$out" | grep -c 'verified byte-identical, git status clean')" "2"

echo "── ARM 11 (2026-09-03): repo is derived from the PATH, not ambient cwd — a call from OUTSIDE the repo with an absolute path still works ──"
reset_to_pre_sync_state
OUTSIDE="$(mktemp -d)"
out=$(cd "$OUTSIDE" && "$S" "$OLD_SHA" "$NEW_SHA2" "$REPO/TODO.md" "$REPO/unrelated.txt" 2>&1); rc=$?
rm -rf "$OUTSIDE"
chk "absolute-path call from an unrelated cwd exits 0" "$rc" "0"
chk "content synced correctly despite wrong-repo cwd" "$(cat "$REPO/TODO.md")" "line one, edited by the landing"

echo "── ARM 12 (2026-09-03): --repo override resolves the repo explicitly, ignoring cwd and path-derivation ──"
reset_to_pre_sync_state
OUTSIDE2="$(mktemp -d)"
out=$(cd "$OUTSIDE2" && "$S" --repo "$REPO" "$OLD_SHA" "$NEW_SHA2" TODO.md unrelated.txt 2>&1); rc=$?
rm -rf "$OUTSIDE2"
chk "--repo override call exits 0 from an unrelated cwd with relative paths" "$rc" "0"

echo "── ARM 13 (2026-09-03, config-driven since the 2026-09-21 sterility scrub): AIMAIL_FROZEN_REPO_PREFIXES refuses a configured frozen subtree, leaves everything else alone ──"
# End-to-end, not a grep on the source: build a real repo under a fake "frozen" parent
# directory, point AIMAIL_CONFIG at a throwaway conf naming that parent as frozen, and
# invoke the real script -- covers both "does the config wire up" and "does the match
# behave right", the same two things the old hardcoded-pattern version checked in
# isolation.
FROZEN_PARENT="$(mktemp -d)"
FROZEN_REPO="$FROZEN_PARENT/frozen_child"
mkdir -p "$FROZEN_REPO"
( cd "$FROZEN_REPO" && git init -q && git commit -q --allow-empty -m init )
FROZEN_CONF="$(mktemp)"
printf 'AIMAIL_FROZEN_REPO_PREFIXES=("%s")\n' "$FROZEN_PARENT" > "$FROZEN_CONF"

out=$(cd /tmp && AIMAIL_CONFIG="$FROZEN_CONF" "$S" --repo "$FROZEN_REPO" x y TODO.md 2>&1); rc=$?
chk "a repo under the configured frozen prefix is refused (exit 1)" "$rc" "1"
chk "the refusal names the configured prefix" "$(printf '%s' "$out" | grep -c "$FROZEN_PARENT")" "1"

UNRELATED_REPO="$(mktemp -d)"
( cd "$UNRELATED_REPO" && git init -q && git config user.email t@t && git config user.name t \
    && echo v1 > f.txt && git add f.txt && git commit -q -m v1 )
U_OLD_SHA="$(git -C "$UNRELATED_REPO" rev-parse HEAD)"
( cd "$UNRELATED_REPO" && echo v2 > f.txt && git commit -qam v2 )
U_NEW_SHA="$(git -C "$UNRELATED_REPO" rev-parse HEAD)"
# Working tree needs to still be AT old_ref's content (the normal pre-sync state) --
# the commit above already advanced it past old_ref, same as a real fast-forward would.
git -C "$UNRELATED_REPO" checkout -q "$U_OLD_SHA" -- f.txt
out=$(cd /tmp && AIMAIL_CONFIG="$FROZEN_CONF" "$S" --repo "$UNRELATED_REPO" "$U_OLD_SHA" "$U_NEW_SHA" f.txt 2>&1); rc=$?
chk "a repo NOT under any configured frozen prefix is not caught by this guard" "$rc" "0"
rm -rf "$UNRELATED_REPO"

out=$(cd /tmp && AIMAIL_CONFIG=/nonexistent-conf-for-this-test "$S" --repo "$FROZEN_REPO" x y TODO.md 2>&1); rc=$?
chk "with no config at all (fresh install), it fails for an unrelated reason (bad ref), never the frozen-prefix message" \
    "$(printf '%s' "$out" | grep -c 'frozen')" "0"

rm -rf "$FROZEN_PARENT" "$FROZEN_CONF"

echo "── ARM 14 (2026-09-03): every invocation is appended to the AIMail state log, success or refusal ──"
LOGDIR="$(mktemp -d)"
export AIMAIL_ROOT="$LOGDIR"
export AIMAIL_SEAT="test-seat-arm14"
reset_to_pre_sync_state
"$S" "$OLD_SHA" "$NEW_SHA2" TODO.md unrelated.txt >/dev/null 2>&1
"$S" 2>/dev/null; true   # a deliberate usage error, still expected to log
LOGFILE="$LOGDIR/state/safe_sync_invocations.log"
chk "log file was created" "$([ -f "$LOGFILE" ] && echo yes || echo no)" "yes"
chk "log records the successful call's seat" "$(grep -c 'seat=test-seat-arm14' "$LOGFILE")" "2"
chk "log records at least one exit=0 line" "$([ "$(grep -c 'exit=0' "$LOGFILE")" -ge 1 ] && echo yes || echo no)" "yes"
chk "log records the usage-error call's exit=1" "$(grep -c 'exit=1' "$LOGFILE")" "1"
unset AIMAIL_ROOT AIMAIL_SEAT
rm -rf "$LOGDIR"

echo
echo "── denominator ──"
echo "PASS=$PASS FAIL=$FAIL of $((PASS+FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %s\n' "${FAILURES[@]}"
    exit 1
fi
exit 0
