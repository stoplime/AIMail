#!/usr/bin/env bash
# tests/battery_wait_queue.sh -- the --wait FIFO queue of the battery wrapper.
#
# WHY: refuse-and-retry made admission "whoever retries fastest" and starved FULL runs. These
# arms prove, with real files in a disposable queue dir and fake pids: FULL tickets sort ahead of
# FAST; stale tickets are swept; reservations count and expire; the wrapper refuses a non-wait
# launch while anything is queued; a --wait launch behind a head times out with a clear line;
# a --wait launch at the head is admitted (ticket dropped, reservation written); a FULL waits on a
# held sharedcorpus and, when free, takes the claim at admission and releases it on exit.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$(dirname "$HERE")/bin"
W="$BIN/run_canonical_battery.sh"

PASS=0; FAIL=0; declare -a FAILURES=()
chk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
        else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export BATTERY_QUEUE_DIR="$TMP/queue"
export AIMAIL_CLAIMS="$TMP/claims"
# the RAM guard is tested in tests/pressure_watchdog.sh; here the real machine's memory, lock and
# stop file must not decide these arms
# The library reads no environment variable, so these arms run a COPY of the tree whose pressure.sh
# points at a fake /proc, a temp state dir and a temp lock.
FP="$TMP/fakeproc"; mkdir -p "$FP" "$TMP/repo"
cp -r "$BIN" "$(dirname "$BIN")/lib" "$(dirname "$BIN")/etc" "$TMP/repo/"
printf 'MemTotal: 67108864 kB\nMemAvailable: %s kB\n' $((40*1048576)) > "$FP/meminfo"
sed -i -e "s#^PRESSURE_PROC_ROOT_DIR=/proc#PRESSURE_PROC_ROOT_DIR=$FP#" \
       -e "s#^PRESSURE_STATE_PATH=\"\"#PRESSURE_STATE_PATH=\"$TMP/pressure\"#" \
       -e "s#^BATTERY_LOCK_FILE=.*#BATTERY_LOCK_FILE=$TMP/battery.lock#" "$TMP/repo/lib/pressure.sh"
W="$TMP/repo/bin/run_canonical_battery.sh"
mkdir -p "$AIMAIL_CLAIMS" "$TMP/wt"
OTHER=99999991   # a fake live pid; never our own
export BATTERY_QUEUE_LIVE_PIDS="$OTHER"

echo "── ARM 1: library -- FULL sorts ahead of an older FAST; stale ticket swept ──"
( . "$BIN/battery_queue.sh"
  fast="$(bq_take fast seatA $OTHER 4)"; sleep 0.01
  full="$(bq_take full seatB $OTHER 1)"
  stale="$(bq_take fast seatC 99999977 4)"   # pid not in the live list -> stale
  head="$(bq_head)"
  chk "head is the FULL ticket although the FAST was queued first" "$head" "$full"
  chk "FAST position is 2 of 2 (stale one swept)" "$(bq_position "$fast")" "2 2"
  chk "stale ticket file removed" "$([ -e "$BATTERY_QUEUE_DIR/$stale" ] && echo present || echo gone)" "gone"
  chk "describe names seat/class" "$(bq_describe "$full")" "seatB/full"
  bq_drop "$fast"; bq_drop "$full"
  chk "queue empty after drops" "$(bq_live_tickets | grep -c .)" "0"
  r="$(bq_reserve seatA $OTHER 4)"; : > "$BATTERY_QUEUE_DIR/starting.1000000000.seatZ.$OTHER.9"
  chk "reservation sums fresh, drops expired" "$(bq_reserved_slots)" "4"
  chk "expired reservation removed" "$(ls "$BATTERY_QUEUE_DIR" | grep -c '^starting.1000000000')" "0"
  bq_unreserve seatA $OTHER
  chk "unreserve clears own reservation" "$(bq_reserved_slots)" "0"
  exit $FAIL ) ; sub=$?; PASS=$((PASS+9-sub)); FAIL=$((FAIL+sub))

echo "── ARM 2: wrapper -- --wait must be a whole number of minutes ──"
out=$(bash "$W" --gate fast --wait abc "$TMP/wt" bqtest 2>&1); rc=$?
chk "--wait abc exits 2" "$rc" "2"
chk "refusal names the rule" "$(printf '%s' "$out" | grep -c 'whole number of minutes')" "1"

echo "── ARM 3: wrapper -- a launch WITHOUT --wait is refused while a ticket is live ──"
( . "$BIN/battery_queue.sh"; bq_take full other $OTHER 1 >/dev/null )
out=$(bash "$W" --gate fast "$TMP/wt" bqtest 2>&1); rc=$?
chk "non-wait launch behind a queued FULL exits 2" "$rc" "2"
chk "refusal says queued and names the head" "$(printf '%s' "$out" | grep -c 'queued for a slot (head: other/full)')" "1"
chk "refusal points at --wait" "$(printf '%s' "$out" | grep -c 'pass --wait')" "1"

echo "── ARM 4: wrapper -- --wait FAST behind a live FULL head times out with a clear line ──"
out=$(BATTERY_WAIT_MINUTE_S=2 BATTERY_WAIT_POLL_S=1 bash "$W" --gate fast --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "timed-out wait exits 5" "$rc" "5"
chk "summary says WAIT TIMED OUT" "$(printf '%s' "$out" | grep -c 'WAIT TIMED OUT after 1 min')" "1"
chk "progress line printed once (state unchanged) and names position + head" "$(printf '%s' "$out" | grep -c '^▶ WAIT: position 2 of 2, behind other/full')" "1"
chk "timeout line repeats the last state" "$(printf '%s' "$out" | grep -c 'last state: position 2 of 2, behind other/full')" "1"
chk "own ticket dropped on timeout" "$(ls "$BATTERY_QUEUE_DIR" | grep -c '\.bqtest\.')" "0"
rm -f "$BATTERY_QUEUE_DIR"/0.*.other.*

echo "── ARM 5: wrapper -- --wait FAST at the head with a free budget is admitted ──"
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 BATTERY_WAIT_POLL_S=1 bash "$W" --gate fast --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "admitted wait exits 0 (test knob)" "$rc" "0"
chk "summary says admitted" "$(printf '%s' "$out" | grep -c 'WAIT: admitted after')" "1"
chk "ticket dropped at admission" "$(ls "$BATTERY_QUEUE_DIR" | grep -c '^1\.')" "0"
chk "starting reservation cleared by the exit handler" "$(ls "$BATTERY_QUEUE_DIR" | grep -c '^starting\.')" "0"

echo "── ARM 6: wrapper -- --wait FULL waits while sharedcorpus is held, naming the holder ──"
mkdir -p "$AIMAIL_CLAIMS/sharedcorpus"; printf 'architect 2026-09-21T13:54:44-04:00 1 sid | astra\n' > "$AIMAIL_CLAIMS/sharedcorpus/claim"
out=$(BATTERY_WAIT_MINUTE_S=2 BATTERY_WAIT_POLL_S=1 bash "$W" --gate full --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "FULL behind a held sharedcorpus times out (exit 5)" "$rc" "5"
chk "progress line names the holder, once" "$(printf '%s' "$out" | grep -c '^▶ WAIT: at the head; sharedcorpus held by architect')" "1"
chk "did not take the claim" "$(cat "$AIMAIL_CLAIMS/sharedcorpus/claim" | grep -c '^architect')" "1"
rm -rf "$AIMAIL_CLAIMS/sharedcorpus"

echo "── ARM 7: wrapper -- --wait FULL with sharedcorpus free takes the claim at admission, releases on exit ──"
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 BATTERY_WAIT_POLL_S=1 bash "$W" --gate full --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "admitted FULL exits 0 (test knob)" "$rc" "0"
chk "claim line in the summary" "$(printf '%s' "$out" | grep -ci 'CLAIMED sharedcorpus')" "1"
chk "claim released on exit" "$([ -d "$AIMAIL_CLAIMS/sharedcorpus" ] && echo held || echo free)" "free"
chk "release line in the summary" "$(printf '%s' "$out" | grep -ci 'RELEASED sharedcorpus')" "1"

echo "── ARM 8: wrapper -- the RAM guard (fake /proc): low MemAvailable refuses, enough starts; stop file refuses; held lock refuses ──"
printf 'MemTotal: 67108864 kB\nMemAvailable: %s kB\n' $((8*1048576)) > "$FP/meminfo"
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 bash "$W" --gate fast "$TMP/wt" bqtest 2>&1); rc=$?
chk "8 GB free under the 16 GB measured need: the wrapper refuses to start" "$([ "$rc" -ne 0 ] && echo refused || echo started)" "refused"
chk "the refusal names available memory" "$(printf '%s' "$out" | grep -c 'MemAvailable 8GB is below the measured need 16GB')" "1"
printf 'MemTotal: 67108864 kB\nMemAvailable: %s kB\n' $((40*1048576)) > "$FP/meminfo"
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 BATTERY_WAIT_POLL_S=1 bash "$W" --gate fast --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "40 GB free: admitted" "$rc" "0"
mkdir -p "$TMP/pressure"; echo "now crit" > "$TMP/pressure/pressure-stop"
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 bash "$W" --gate fast "$TMP/wt" bqtest 2>&1); rc=$?
chk "stop file set: the wrapper refuses to start" "$([ "$rc" -ne 0 ] && echo refused || echo started)" "refused"
chk "the refusal names the stop file" "$(printf '%s' "$out" | grep -c 'pressure-stop is set')" "1"
rm -f "$TMP/pressure/pressure-stop"
exec 8>"$TMP/battery.lock"; flock -n 8
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 bash "$W" --gate fast "$TMP/wt" bqtest 2>&1); rc=$?
chk "another battery holds the lock: the wrapper refuses to start" "$([ "$rc" -ne 0 ] && echo refused || echo started)" "refused"
chk "the refusal says one battery at a time" "$(printf '%s' "$out" | grep -c 'one battery at a time')" "1"
flock -u 8; exec 8>&-
out=$(BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 BATTERY_WAIT_POLL_S=1 bash "$W" --gate fast --wait 1 "$TMP/wt" bqtest 2>&1); rc=$?
chk "lock free again: admitted" "$rc" "0"

TOTAL=$((PASS+FAIL))
printf '\n%s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TOTAL"
if (( FAIL )); then printf '\nFAILURES:\n'; printf '  • %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
