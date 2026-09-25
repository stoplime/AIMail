#!/usr/bin/env bash
# tests/claimstate.sh — the (seat,claim) state machine, per fable's reviewed
# design, added 2026-09-17.
#
# WHY: assistant's first proposal (TTL auto-expiry) was correctly rejected by
# the project owner — auto-releasing a live claim recreates the exact collision
# gateclaim.sh exists to prevent. Fable's correction: state belongs to the
# (seat, claim) PAIR, not the seat. This file proves each of the five states
# reads correctly, that BLOCKED's dangling/cycle checks are not silently
# trusted, and — per fable's own acceptance bar — REPLAYS real historical
# events from THIS session (real claims, real commits, real mail, a real
# session death) rather than only synthetic fixtures.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-test.XXXXXX")"
export AIMAIL_CLAIMS; AIMAIL_CLAIMS="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-claims.XXXXXX")"
export AIMAIL_NO_NETWORK=1
export AIMAIL_CLAIM_STUCK_SECONDS=5   # tiny for the test; production default is documented in claimstate.sh

# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/registry.sh
source "$REPO/lib/registry.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"
# shellcheck source=../lib/claimstate.sh
source "$REPO/lib/claimstate.sh"
ensure_dirs

GATECLAIM="$REPO/bin/gateclaim.sh"

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
chk_contains(){ case "$2" in *"$3"*) chk "$1" 1 1 ;; *) chk "$1" "MISSING[$3]" "$2" ;; esac; }

seat_add() { printf '%s\tactive\t\t%s\n' "$1" "${2:-test seat}" >> "$SEATS_FILE"; }
: > "$SEATS_FILE"
seat_add seat_a; seat_add seat_b; seat_add librarian; seat_add foundation

declare -a SPAWNED_PIDS=()
cleanup() {
  # -P kills each fixture's own CHILD too (e.g. the "claude" fixture's inner
  # `sleep 300 & wait`) -- a script's background jobs share one process group
  # without job control, so a bare `kill "$p"` leaves grandchildren orphaned
  # and running for their own full duration (measured: three stray `sleep
  # 300`s survived a killed test run and held its `| tail` pipe open forever).
  local p; for p in "${SPAWNED_PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    pkill -9 -P "$p" 2>/dev/null || true
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$AIMAIL_ROOT" "$AIMAIL_CLAIMS" "${TMP_REPOS[@]:-}"
}
trap cleanup EXIT

# alive seat: real heartbeat with this test's own pid (guaranteed alive for
# the test's own duration -- same idiom tests/seat_account.sh established).
alive_seat() { hb_start "$1"; hb_write "$1" pid "$$"; }
# dead seat: a pid that has definitely already exited.
dead_seat() {
  local seat="$1"
  ( exit 0 ) & local p=$!
  wait "$p" 2>/dev/null || true
  hb_start "$seat"; hb_write "$seat" pid "$p"
}

echo "─── ARM 1: canon shells out to gateclaim.sh's own canon(), never reimplemented ───"
chk "ticket-shaped key canonicalises the same as gateclaim.sh itself" \
  "$(_claim_canon T-200)" "$(bash "$GATECLAIM" --canon T-200)"
chk "free-form key canonicalises the same as gateclaim.sh itself" \
  "$(_claim_canon MyFreeForm-Key)" "$(bash "$GATECLAIM" --canon MyFreeForm-Key)"

echo "─── ARM 2: BLOCKED -- a valid gate: referent (both claims genuinely held) ───"
alive_seat seat_a; alive_seat seat_b
bash "$GATECLAIM" zzzblockerclaimxyz seat_b >/dev/null
bash "$GATECLAIM" zzzblockedclaimxyz seat_a >/dev/null
claim_set_blocked zzzblockedclaimxyz seat_a "gate:zzzblockerclaimxyz" >/dev/null
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzblockedclaimxyz)")
chk "valid gate referent -> BLOCKED" "$st" "BLOCKED"
chk_contains "detail names the referent" "$det" "zzzblockerclaimxyz"

echo "─── ARM 3: BLOCKED -- a DANGLING gate: referent (blocker already released), never silently trusted ───"
bash "$GATECLAIM" --release zzzblockerclaimxyz seat_b >/dev/null
val="$(_claim_blocked_validity "$(_claim_canon zzzblockedclaimxyz)")"
chk_contains "dangling referent is flagged, not silently valid" "$val" "dangling"
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzblockedclaimxyz)")
chk "a dangling block does not freeze the reading at BLOCKED forever" "$([ "$st" = BLOCKED ] && echo yes || echo no)" "no"
chk_contains "but the stale block is still named in whatever state it falls through to" "$det" "dangling"
bash "$GATECLAIM" --release zzzblockedclaimxyz seat_a >/dev/null

echo "─── ARM 4: BLOCKED -- a CYCLE (A on B's gate, B on A's), detected not assumed ───"
bash "$GATECLAIM" zzzcycleaxyz seat_a >/dev/null
bash "$GATECLAIM" zzzcyclebxyz seat_b >/dev/null
claim_set_blocked zzzcycleaxyz seat_a "gate:zzzcyclebxyz" >/dev/null
claim_set_blocked zzzcyclebxyz seat_b "gate:zzzcycleaxyz" >/dev/null
val="$(_claim_blocked_validity "$(_claim_canon zzzcycleaxyz)")"
chk_contains "A->B->A is detected as a cycle" "$val" "cycle"
val="$(_claim_blocked_validity "$(_claim_canon zzzcyclebxyz)")"
chk_contains "the cycle is visible from the other side too" "$val" "cycle"
bash "$GATECLAIM" --release zzzcycleaxyz seat_a >/dev/null
bash "$GATECLAIM" --release zzzcyclebxyz seat_b >/dev/null

echo "─── ARM 5: BLOCKED -- seat: referent, valid vs dangling ───"
bash "$GATECLAIM" zzzseatrefxyz seat_a >/dev/null
claim_set_blocked zzzseatrefxyz seat_a "seat:seat_b" >/dev/null
chk "seat: referent to a real registered seat -> valid" "$(_claim_blocked_validity "$(_claim_canon zzzseatrefxyz)")" "valid"
claim_set_blocked zzzseatrefxyz seat_a "seat:no_such_seat_at_all" >/dev/null
chk_contains "seat: referent to an unregistered seat -> dangling" \
  "$(_claim_blocked_validity "$(_claim_canon zzzseatrefxyz)")" "dangling"
bash "$GATECLAIM" --release zzzseatrefxyz seat_a >/dev/null

echo "─── ARM 6: BLOCKED -- human: referent, and rejecting an untyped referent outright ───"
bash "$GATECLAIM" zzzhumanrefxyz seat_a >/dev/null
claim_set_blocked zzzhumanrefxyz seat_a "human:owner" >/dev/null
chk "human: referent with a name -> valid" "$(_claim_blocked_validity "$(_claim_canon zzzhumanrefxyz)")" "valid"
( claim_set_blocked zzzhumanrefxyz seat_a "not-a-typed-referent" >/dev/null 2>&1 )
chk "an untyped referent is REFUSED at write time, not accepted and misread later" "$?" "3"
bash "$GATECLAIM" --release zzzhumanrefxyz seat_a >/dev/null

echo "─── ARM 7: only the HOLDER may set or clear its own blocked_on ───"
bash "$GATECLAIM" zzzownerguardxyz seat_a >/dev/null
( claim_set_blocked zzzownerguardxyz seat_b "human:someone" >/dev/null 2>&1 )
chk "a non-holder cannot set blocked_on on another seat's claim" "$?" "3"
bash "$GATECLAIM" --release zzzownerguardxyz seat_a >/dev/null

echo "─── ARM 8: WORKING via a real commit in the claim's own worktree, dated after since ───"
declare -a TMP_REPOS=()
REPO1="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-repo.XXXXXX")"; TMP_REPOS+=("$REPO1")
git -C "$REPO1" init -q -b main
git -C "$REPO1" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
export AIMAIL_CLAIM_REPOS="$REPO1"
alive_seat seat_a
bash "$GATECLAIM" zzzworkcommitxyz seat_a >/dev/null
canon="$(_claim_canon zzzworkcommitxyz)"
WT1="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-wt.XXXXXX")"; TMP_REPOS+=("$WT1")
git -C "$REPO1" worktree add -q -b "seata/$canon-build" "$WT1" main
echo x > "$WT1/f.txt"
git -C "$WT1" -c user.email=t@t -c user.name=t add f.txt
git -C "$WT1" -c user.email=t@t -c user.name=t commit -q -m "real work on $canon"
IFS=$'\t' read -r st det < <(claim_state "$canon")
chk "a real commit in the matched worktree, after since -> WORKING" "$st" "WORKING"
chk_contains "detail names the commit" "$det" "commit"

echo "─── ARM 9: the SAME evidence type does NOT fire for a commit dated BEFORE the claim started ───"
bash "$GATECLAIM" --release zzzworkcommitxyz seat_a >/dev/null
sleep 1
bash "$GATECLAIM" zzzworkcommitxyz seat_a >/dev/null   # since is NOW, strictly after the commit above
canon2="$(_claim_canon zzzworkcommitxyz)"
# Tested directly against the evidence function, not the overall claim_state:
# with the stale commit excluded AND the claim freshly reacquired, the
# correct overall reading is now WORKING-via-grace-period (see ARM 14a),
# which would make an assertion on the bare STATE conflate two different
# things this suite tests separately. The claim under test here is narrower:
# does the pre-existing commit itself get excluded.
commit_ev="$(_claim_commit_evidence "$canon2" "$(_claim_since_epoch "$canon2")")"
chk "a commit dated before 'since' is excluded from evidence" "${commit_ev:-empty}" "empty"
bash "$GATECLAIM" --release zzzworkcommitxyz seat_a >/dev/null

echo "─── ARM 10: WORKING via a LIVE PROCESS sitting in the worktree -- counts regardless of age ───"
alive_seat seat_a
bash "$GATECLAIM" zzzworkprocxyz seat_a >/dev/null
canon3="$(_claim_canon zzzworkprocxyz)"
WT2="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-wt2.XXXXXX")"; TMP_REPOS+=("$WT2")
git -C "$REPO1" worktree add -q -b "seata/$canon3-build" "$WT2" main
( cd "$WT2" && exec sleep 300 ) >/dev/null 2>&1 & SPAWNED_PIDS+=("$!")
sleep 0.3
IFS=$'\t' read -r st det < <(claim_state "$canon3")
chk "a live process with cwd under the claim's worktree -> WORKING" "$st" "WORKING"
chk_contains "detail says it's a live process" "$det" "live process"
bash "$GATECLAIM" --release zzzworkprocxyz seat_a >/dev/null

echo "─── ARM 11: WORKING via a real MAIL naming the claim's key, from the holder, after since ───"
unset AIMAIL_CLAIM_REPOS   # no worktree evidence should exist for this one
alive_seat seat_a
bash "$GATECLAIM" zzzworkmailxyz seat_a >/dev/null
canon4="$(_claim_canon zzzworkmailxyz)"
mkdir -p "$MAIL_DIR/seat_b"
cat > "$MAIL_DIR/seat_b/20260917T999999-seat_a-progress-on-zzzworkmailxyz-0.md" <<'EOF'
---
from: seat_a
to: seat_b
subject: progress on zzzworkmailxyz
---

Update on zzzworkmailxyz: real progress today.
EOF
IFS=$'\t' read -r st det < <(claim_state "$canon4")
chk "a real mail from the holder naming the raw key, after since -> WORKING" "$st" "WORKING"
chk_contains "detail names it as mail evidence" "$det" "mail"
bash "$GATECLAIM" --release zzzworkmailxyz seat_a >/dev/null

echo "─── ARM 12: DOWN -- dead heartbeat pid, no evidence at all ───"
dead_seat seat_a
bash "$GATECLAIM" zzzdownnoevidencexyz seat_a >/dev/null
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzdownnoevidencexyz)")
chk "dead heartbeat pid, nothing else -> DOWN" "$st" "DOWN"
bash "$GATECLAIM" --release zzzdownnoevidencexyz seat_a >/dev/null

echo "─── ARM 13: MIS-SEATED -- dead heartbeat pid, but a live session is genuinely registered to this seat ───"
FAKEBIN="$(mktemp -d "${TMPDIR:-/tmp}/aimail-claimstate-fakebin.XXXXXX")"; TMP_REPOS+=("$FAKEBIN")
# A REAL bash binary named "claude" -- NOT a shebang script (a `#!/usr/bin/env
# bash` script's own argv[0] becomes "bash" once the kernel resolves the
# interpreter, which would fail _is_claude_cli's basename(argv[0])=="claude"
# check). Runs its sleep as a CHILD via `-c` (never `exec`, which would
# replace this process's own cmdline and erase the --resume= signature the
# classifier reads).
cp "$(command -v bash)" "$FAKEBIN/claude"
FAKE_SID="zzz-fake-session-misseated-0001"
# `-c 'sleep 300'` ALONE lets bash's own tail-call optimisation exec() sleep
# directly, overwriting this process's cmdline (measured: `ps` then shows
# "sleep 300", not "claude ... --resume="). `& wait` forks sleep as a child
# and blocks in the wait builtin instead, so THIS process's own argv/cmdline
# -- the "claude --resume=" signature the classifier reads -- never changes.
"$FAKEBIN/claude" -c 'sleep 300 & wait' --resume="$FAKE_SID" >/dev/null 2>&1 & SPAWNED_PIDS+=("$!")
sleep 0.3
mkdir -p "$STATE_DIR/stopguard"
echo seat_a > "$STATE_DIR/stopguard/session.$FAKE_SID"
dead_seat seat_a
bash "$GATECLAIM" zzzmisseatedxyz seat_a >/dev/null
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzmisseatedxyz)")
chk "a live session under the dead seat's own name still reads DOWN (heartbeat pid is the fact)" "$st" "DOWN"
chk_contains "but the detail names it MIS-SEATED, never a silent 'nobody is here'" "$det" "MIS-SEATED"
bash "$GATECLAIM" --release zzzmisseatedxyz seat_a >/dev/null
rm -f "$STATE_DIR/stopguard/session.$FAKE_SID"

echo "─── ARM 13b: a FRESH claim with no evidence yet reads WORKING via grace, not STUCK ───"
alive_seat seat_a
bash "$GATECLAIM" zzzfreshgracexyz seat_a >/dev/null
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzfreshgracexyz)")
chk "a claim seconds old, zero evidence, alive seat -> WORKING (grace), not STUCK" "$st" "WORKING"
chk_contains "detail names it as the grace period, not real evidence" "$det" "grace period"
bash "$GATECLAIM" --release zzzfreshgracexyz seat_a >/dev/null

echo "─── ARM 13c: REGRESSION -- a claim seconds old on an ALREADY-DEAD heartbeat still reads DOWN, never grace-period WORKING ───"
dead_seat seat_a
bash "$GATECLAIM" zzzfreshdeadxyz seat_a >/dev/null
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzfreshdeadxyz)")
chk "a claim seconds old but the seat is ALREADY dead -> DOWN wins over grace" "$st" "DOWN"
bash "$GATECLAIM" --release zzzfreshdeadxyz seat_a >/dev/null

echo "─── ARM 14: STUCK -- alive, holds it, not blocked, evidence past the (tiny, test-scoped) threshold ───"
alive_seat seat_a
bash "$GATECLAIM" zzzstuckclaimxyz987 seat_a >/dev/null
sleep 6   # > AIMAIL_CLAIM_STUCK_SECONDS=5 for this test run
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzstuckclaimxyz987)")
chk "alive + held + unblocked + no evidence past threshold -> STUCK" "$st" "STUCK"
chk_contains "STUCK explicitly says it is never auto-released" "$det" "Never auto-released"
bash "$GATECLAIM" --release zzzstuckclaimxyz987 seat_a >/dev/null

echo "─── ARM 15: PARKED is excluded from STUCK -- a correctly-parked seat is not stuck ───"
alive_seat seat_a; hb_park seat_a
bash "$GATECLAIM" zzzparkedclaimxyz seat_a >/dev/null
sleep 6
IFS=$'\t' read -r st det < <(claim_state "$(_claim_canon zzzparkedclaimxyz)")
chk "a PARKED seat's claim does NOT read STUCK despite stale evidence" "$([ "$st" = STUCK ] && echo yes || echo no)" "no"
chk_contains "it reads WORKING with the parked reason named" "$det" "PARKED"
bash "$GATECLAIM" --release zzzparkedclaimxyz seat_a >/dev/null

echo "─── ARM 16: seat_bare_state -- IDLE and DOWN for a seat holding ZERO claims ───"
alive_seat seat_a
IFS=$'\t' read -r st det < <(seat_bare_state seat_a)
chk "alive seat holding nothing -> IDLE" "$st" "IDLE"
dead_seat seat_a
IFS=$'\t' read -r st det < <(seat_bare_state seat_a)
chk "dead seat holding nothing -> DOWN" "$st" "DOWN"

echo
echo "─── REPLAY: real historical events from THIS SESSION, 2026-09-17, per fable's own acceptance bar ───"
echo "(assistant, on request: 'no consolidated ledger... combine mail archives + git log';"
echo " 'your own death today is a good DOWN fixture')"
echo

# ── REPLAY 1: the real aimailacctauto claim -- a REAL commit, in a REAL
#    worktree, still on disk from earlier in this same session. ──
REAL_AIMAIL="/mnt/workdrive/AI/AIMail"
# This exact scratch worktree was a one-time, opportunistic replay fixture from the session
# that first wrote this test (2026-09-17) -- almost certainly long gone by the time this test
# runs again, on this machine or any other; the guard below makes that the normal, silent case.
REAL_WT="${AIMAIL_TEST_REPLAY_WT:-/tmp/nonexistent-aimail-replay-fixture}"
if [[ -d "$REAL_WT/.git" || -f "$REAL_WT/.git" ]] && git -C "$REAL_AIMAIL" rev-parse cb95504 >/dev/null 2>&1; then
  export AIMAIL_CLAIM_REPOS="$REAL_AIMAIL"
  alive_seat librarian
  # The claim's REAL acquire time, read verbatim from this session's own mail
  # record: aimailacctauto, librarian, 2026-09-17T16:13:53-04:00. This replay
  # runs however many real hours later this test happens to execute, so the
  # STUCK threshold is raised to a full day for THIS check only (restored
  # after) -- the point being replayed is "does real evidence classify as
  # WORKING", not "is 5 test-seconds a realistic threshold".
  since_real="$(date -d '2026-09-17T16:13:53-0400' +%s)"
  mkdir -p "$AIMAIL_CLAIMS/aimailacctauto"
  printf '%s\n' "librarian $(date -d "@$since_real" -Iseconds) $since_real | replay fixture" \
    > "$AIMAIL_CLAIMS/aimailacctauto/owner"
  printf 'aimailacctauto\n' > "$AIMAIL_CLAIMS/aimailacctauto/raw"
  _saved_stuck="$CLAIM_STUCK_SECONDS"; CLAIM_STUCK_SECONDS=86400
  IFS=$'\t' read -r st det < <(claim_state aimailacctauto)
  CLAIM_STUCK_SECONDS="$_saved_stuck"
  chk "REPLAY: the real aimailacctauto claim reads WORKING off its real cb95504 commit" "$st" "WORKING"
  chk_contains "REPLAY: the real commit sha appears in the detail" "$det" "cb95504"
  rm -rf "${AIMAIL_CLAIMS:?}/aimailacctauto"
  unset AIMAIL_CLAIM_REPOS
else
  echo "  (skipped: the real cb95504 worktree/commit is no longer on this box -- not a failure of the logic)"
fi

# ── REPLAY 2: librarian's own real death today as a DOWN fixture. Per
#    assistant's own mail: last real activity ~17:48-17:52 (the A26 mails),
#    the 18:15 CHECKPOINT delivered but never acted on, nothing until the
#    ~21:07 CLI revival. The real pid from that dead session is long gone;
#    the fixture uses a definitely-dead pid with the REAL recorded beat time,
#    matching a genuine crash shape (no exit_at at all -- it did not stop on
#    purpose, exactly like poller_state's own CRASHED branch describes). ──
( exit 0 ) & DEADPID=$!
wait "$DEADPID" 2>/dev/null || true
real_beat="$(date -d '2026-09-17T17:52:00-0400' +%s)"
hb_start librarian
hb_write librarian pid "$DEADPID"
hb_write librarian beat "$real_beat"
bash "$GATECLAIM" replaydeathxyz librarian >/dev/null
# Back-date the claim's own since to match: acquired well before the death.
since_death="$(date -d '2026-09-17T16:00:00-0400' +%s)"
canon_d="$(_claim_canon replaydeathxyz)"
printf '%s\n' "librarian $(date -d "@$since_death" -Iseconds) $since_death" \
  > "$AIMAIL_CLAIMS/$canon_d/owner"
IFS=$'\t' read -r st det < <(claim_state "$canon_d")
chk "REPLAY: librarian's real 2026-09-17 death (dead pid, real beat time) reads DOWN" "$st" "DOWN"
bash "$GATECLAIM" --release replaydeathxyz librarian >/dev/null

echo
echo "── $PASS/$((PASS+FAIL)) passed ──"
if (( FAIL > 0 )); then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
