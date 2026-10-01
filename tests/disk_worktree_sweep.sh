#!/usr/bin/env bash
# tests/disk_worktree_sweep.sh — the disk-space/stale-worktree watchdog folded into
# fleet_sweep(), and the broadening of its occupancy detector.
#
# Follows tests/run.sh's evidence rules: every rejection/finding arm is paired with a clean
# control (③), exit codes captured out of pipes (⑤), denominator printed (④).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-disktest.XXXXXX")"
mkdir -p "$AIMAIL_ROOT/state" "$AIMAIL_ROOT/tmp"
STATE_DIR="$AIMAIL_ROOT/state"
trap 'rm -rf "$AIMAIL_ROOT" "${SCRATCH:-}"' EXIT

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

echo "── _stale_worktrees: real git repo, synthetic worktrees ──"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aimail-disktest-repo.XXXXXX")"
MAIN_REPO="$SCRATCH/main"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# ARM 1: a FRESH worktree (just created) must NOT be flagged -- the age check has a floor,
# not a trigger on every additional worktree that exists.
FRESH_WT="$SCRATCH/fresh-wt"
git -C "$MAIN_REPO" worktree add -q --detach "$FRESH_WT" main

# ARM 2: a worktree whose newest file is older than DISK_STALE_WORKTREE_DAYS must be flagged.
STALE_WT="$SCRATCH/stale-wt"
git -C "$MAIN_REPO" worktree add -q --detach "$STALE_WT" main
OLD_TS="$(date -d '10 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-10d +%Y%m%d%H%M)"
find "$STALE_WT" -type f -exec touch -t "$OLD_TS" {} \; 2>/dev/null

# ARM 3: a worktree git itself calls prunable (its own directory removed out from under it)
# must be flagged via the prunable path, independent of any age check.
PRUNABLE_WT="$SCRATCH/prunable-wt"
git -C "$MAIN_REPO" worktree add -q --detach "$PRUNABLE_WT" main
rm -rf "$PRUNABLE_WT"

DISK_KNOWN_REPOS=("$MAIN_REPO")
DISK_STALE_WORKTREE_DAYS=3
mapfile -t FOUND < <(_stale_worktrees)
FOUND_TXT="$(printf '%s\n' "${FOUND[@]}")"

chk "fresh worktree NOT flagged"     "$(grep -c "$FRESH_WT" <<<"$FOUND_TXT")"     "0"
chk "stale worktree IS flagged"      "$(grep -c "$STALE_WT" <<<"$FOUND_TXT")"     "1"
chk "prunable worktree IS flagged"   "$(grep -c "$PRUNABLE_WT" <<<"$FOUND_TXT")"  "1"
chk "prunable finding names 'prunable'" \
  "$(grep "$PRUNABLE_WT" <<<"$FOUND_TXT" | grep -c 'prunable')" "1"
chk "the repo's OWN working tree is never flagged" "$(grep -c "^$MAIN_REPO --" <<<"$FOUND_TXT")" "0"
chk "exactly 2 findings (stale + prunable, not fresh)" "${#FOUND[@]}" "2"

echo "── disk_worktree_sweep: dedup on the reading, alert only on a NEW number ──"
# Stub the two disk-measurement primitives and mail_send so this arm is deterministic and
# never touches the real filesystem size or sends real mail.
_root_free_gb() { echo 5; }     # below any real DISK_ALERT_GB -- forces a "reason"
_tmp_used_gb()  { echo 999; }
SENT_COUNT=0
mail_send() { SENT_COUNT=$((SENT_COUNT+1)); return 0; }
_stale_worktrees() { :; }        # no worktree findings for this arm -- isolates the disk check
seat_exists() { [ "$1" = "assistant" ]; }
info() { :; }; warn() { :; }     # silence for a clean pass/fail read

DISK_ALERT_GB=80
disk_worktree_sweep
chk "first crossing sends exactly one alert" "$SENT_COUNT" "1"
disk_worktree_sweep
chk "SAME reading again does NOT re-alert (dedup)" "$SENT_COUNT" "1"
_tmp_used_gb() { echo 1000; }   # the number actually changed -- a new finding
disk_worktree_sweep
chk "a CHANGED reading DOES re-alert" "$SENT_COUNT" "2"

echo "── disk_worktree_sweep: clean reading sends nothing ──"
rm -rf "$AIMAIL_ROOT/state/sweep_alerted"
_root_free_gb() { echo 200; }
_tmp_used_gb()  { echo 5; }
SENT_COUNT=0
disk_worktree_sweep
chk "clean reading sends no alert" "$SENT_COUNT" "0"

echo "── disk_worktree_sweep: T-<pending> a GROWING stale-worktree count, with real disk fine,"
echo "   must never alert on its own (mail 20260910T095113 -- a fleet creating worktrees"
echo "   continuously means this count almost never holds still, so keying dedup on it"
echo "   means the alert can never quiesce independent of whether disk is ever a problem) ──"
rm -rf "$AIMAIL_ROOT/state/sweep_alerted"
_root_free_gb() { echo 200; }   # nowhere near any real floor
_tmp_used_gb()  { echo 5; }     # nowhere near any real ceiling
SENT_COUNT=0
_stale_worktrees() { printf 'wt-a -- newest file 3d old, detached\n'; }
disk_worktree_sweep
chk "one stale worktree, disk fine: sends no alert" "$SENT_COUNT" "0"
_stale_worktrees() { printf 'wt-a -- newest file 4d old, detached\nwt-b -- newest file 3d old, detached\n'; }
disk_worktree_sweep
chk "stale count GREW (1->2), disk still fine: still no alert" "$SENT_COUNT" "0"
_stale_worktrees() { printf 'wt-a -- newest file 5d old, detached\nwt-b -- newest file 4d old, detached\nwt-c -- newest file 3d old, detached\n'; }
disk_worktree_sweep
chk "stale count GREW again (2->3), disk still fine: still no alert" "$SENT_COUNT" "0"
_root_free_gb() { echo 5; }    # NOW a real threshold breach, same stale count as above
disk_worktree_sweep
chk "real disk pressure appears: DOES alert" "$SENT_COUNT" "1"

echo
echo "── SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total ──"
if (( FAIL > 0 )); then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
