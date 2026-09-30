#!/usr/bin/env bash
# tests/pressure_watchdog.sh -- lib/pressure.sh: the RAM/CPU pressure levels, the `fleet pressure`
# alerting, the orphan reaper and the battery guard.
#
# Everything reads a FAKE /proc (AIMAIL_PROC_ROOT -> a temp dir of files). Nothing here starts a
# process that is then signalled: signals go to a recording stub, and "the process died" is a fake
# process directory being removed. No assertion depends on an order the code does not guarantee
# (sets are compared sorted; TERM-before-KILL is shown by a process that dies on TERM never
# receiving KILL, not by comparing positions in a log).
#
# Follows tests/run.sh's evidence rules: every refusal/finding arm has a clean control next to it,
# exit codes are captured out of pipes, the denominator is printed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-pressuretest.XXXXXX")"
mkdir -p "$AIMAIL_ROOT/state" "$AIMAIL_ROOT/tmp"
STATE_DIR="$AIMAIL_ROOT/state"
trap 'rm -rf "$AIMAIL_ROOT"' EXIT

# Stubs for what lib/core.sh normally supplies, recorded rather than performed.
MAILS=(); info() { :; }; warn() { :; }
seat_exists() { [[ "$1" == assistant ]]; }
mail_send() { # mail_send --to X --from Y --subject S --body-file F
  local subj="" bf=""
  while [[ $# -gt 0 ]]; do case "$1" in --subject) subj="$2"; shift 2;; --body-file) bf="$2"; shift 2;; *) shift;; esac; done
  MAILS+=("$subj"); LAST_BODY="$(cat "$bf")"; return 0
}
# shellcheck source=../lib/pressure.sh
source "$REPO/lib/pressure.sh"

# Redefined AFTER sourcing: the library's own real versions would otherwise win.
SIGNALS=()                 # "SIG pid"
DIE_ON_TERM=""             # space-separated pids whose fake process vanishes on TERM
_pressure_signal() {
  SIGNALS+=("$1 $2")
  if [[ "$1" == TERM && " $DIE_ON_TERM " == *" $2 "* ]]; then rm -rf "$FAKE/$2"; fi
}
_pressure_sleep() { :; }


PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

FAKE="$AIMAIL_ROOT/proc"
# plain shell variables (the library reads no environment), set after sourcing
PRESSURE_PROC_ROOT_DIR="$FAKE"; PRESSURE_UID=1000; REAP_GRACE_S=0
ME=1000

# mk_sys AVAIL_GB SWAP_TOTAL_GB SWAP_FREE_GB MEM_SOME MEM_FULL CPU_SOME  (PSI "" = file absent)
mk_sys() {
  rm -rf "$FAKE"; mkdir -p "$FAKE/pressure"
  printf 'MemTotal: 67108864 kB\nMemAvailable: %s kB\nSwapTotal: %s kB\nSwapFree: %s kB\n' \
    $(( $1 * 1048576 )) $(( $2 * 1048576 )) $(( $3 * 1048576 )) > "$FAKE/meminfo"
  [[ -n "$4" ]] && printf 'some avg10=0.00 avg60=%s.00 avg300=0.00 total=1\nfull avg10=0.00 avg60=%s.00 avg300=0.00 total=1\n' "$4" "${5:-0}" > "$FAKE/pressure/memory"
  [[ -n "$6" ]] && printf 'some avg10=0.00 avg60=%s.00 avg300=0.00 total=1\n' "$6" > "$FAKE/pressure/cpu"
  echo "100000.00 1000.00" > "$FAKE/uptime"
}
# mk_proc PID PPID AGE_S UID RSS_KB CMD...   (clock ticks = 100/s; uptime 100000 s)
mk_proc() {
  local pid=$1 ppid=$2 age=$3 uid=$4 rss=$5; shift 5
  mkdir -p "$FAKE/$pid"
  printf '%s (comm with) space) S %s 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "$pid" "$ppid" $(( (100000 - age) * 100 )) > "$FAKE/$pid/stat"
  printf 'Name:\tx\nUid:\t%s\t%s\t%s\t%s\nVmRSS:\t%s kB\n' "$uid" "$uid" "$uid" "$uid" "$rss" > "$FAKE/$pid/status"
  printf '%s\0' "$@" > "$FAKE/$pid/cmdline"
}
level() { pressure_read; pressure_level; }

echo "── ARM 1: levels -- each signal trips its own level, each with a clean control ──"
mk_sys 40 8 8 1 0 1;  chk "healthy machine reads OK" "$(level)" OK
mk_sys 12 8 8 1 0 1;  chk "MemAvailable 12GB of 64 (18.8%, under 20%) is WARN" "$(level)" WARN
mk_sys 13 8 8 1 0 1;  chk "MemAvailable 13GB of 64 (20.3%) is OK" "$(level)" OK
mk_sys 6 8 8 1 0 1;   chk "MemAvailable 6GB of 64 (9.4%, under 10%) is CRIT" "$(level)" CRIT
mk_sys 7 8 8 1 0 1;   chk "MemAvailable 7GB of 64 (10.9%) is WARN, not CRIT" "$(level)" WARN
mk_sys 40 10 3 1 0 1; chk "swap 70% used is WARN" "$(level)" WARN
mk_sys 40 10 4 1 0 1; chk "swap 60% used (the ceiling itself) is OK" "$(level)" OK
mk_sys 40 100 10 1 0 1; chk "swap 90% used is CRIT" "$(level)" CRIT
mk_sys 40 8 8 11 0 1; chk "memory PSI some 11 is WARN" "$(level)" WARN
mk_sys 40 8 8 10 0 1; chk "memory PSI some 10 is OK" "$(level)" OK
mk_sys 40 8 8 2 6 1;  chk "memory PSI full 6 is CRIT" "$(level)" CRIT
mk_sys 40 8 8 2 5 1;  chk "memory PSI full 5 is OK" "$(level)" OK
mk_sys 40 8 8 1 0 41; chk "cpu PSI some 41 is WARN" "$(level)" WARN
mk_sys 40 8 8 1 0 40; chk "cpu PSI some 40 is OK" "$(level)" OK
mk_sys 40 0 0 "" "" "";  chk "no swap and no PSI files reads OK (unmeasured never trips)" "$(level)" OK
mk_sys 5 0 0 "" "" "";   chk "low memory still trips with no swap/PSI files" "$(level)" CRIT
mk_sys 12 0 0 "" "" ""; PR_T=$(sed -i "s/MemTotal: 67108864/MemTotal: 33554432/" "$FAKE/meminfo"; level); chk "the same 12GB free on a 32GB machine (37.5%) is OK: thresholds follow the machine" "$PR_T" OK

echo "── ARM 2: CPU usage is not an alert -- a saturated machine with low cpu PSI stays OK ──"
mk_sys 40 8 8 1 0 5
mk_proc 7001 1 10 $ME 100 busy-loop
chk "busy process, cpu PSI 5: OK" "$(level)" OK

echo "── ARM 3: fleet_pressure -- mail on change, dedup on repeat, CRIT sets the stop file ──"
PRESSURE_STATE_PATH="$AIMAIL_ROOT/state/pressure"
mk_sys 40 8 8 1 0 1
mk_proc 7002 500 3000 $ME 4000000 python big-consumer.py
mk_proc 7003 500 10 $ME 1000 small
mk_sys 40 8 8 1 0 1 2>/dev/null; mk_proc 7002 500 3000 $ME 4000000 python big-consumer.py; mk_proc 7003 500 10 $ME 1000 small
fleet_pressure;  chk "OK sends nothing" "${#MAILS[@]}" 0
chk "OK leaves no stop file" "$([[ -f "$(PRESSURE_STOP_FILE)" ]] && echo set || echo clear)" clear
mk_sys 10 8 8 1 0 1; mk_proc 7002 500 3000 $ME 4000000 python big-consumer.py; mk_proc 7003 500 10 $ME 1000 small
fleet_pressure;  chk "first WARN sends one mail" "${#MAILS[@]}" 1
chk "WARN mail names the level" "${MAILS[0]}" "PRESSURE WARN: memory/cpu threshold crossed"
chk "WARN mail lists the biggest process by RSS" "$([[ "$LAST_BODY" == *"pid=7002"*"rss=3906MB"* ]] && echo yes || echo no)" yes
chk "WARN mail carries ppid and age for it" "$([[ "$LAST_BODY" == *"pid=7002 ppid=500 age=3000s"* ]] && echo yes || echo no)" yes
chk "WARN does not set the stop file" "$([[ -f "$(PRESSURE_STOP_FILE)" ]] && echo set || echo clear)" clear
fleet_pressure;  chk "the same WARN again is not re-sent" "${#MAILS[@]}" 1
mk_sys 4 8 8 1 0 1; mk_proc 7002 500 3000 $ME 4000000 python big-consumer.py
fleet_pressure
chk "WARN -> CRIT is a change: second mail" "${#MAILS[@]}" 2
chk "CRIT sets the stop file" "$([[ -f "$(PRESSURE_STOP_FILE)" ]] && echo set || echo clear)" set
# No desktop pop-ups, ever: these stand-ins (in-process functions, so nothing reaches a real bus)
# would record a call, and a CRIT mail was sent above.
DESKTOP_CALLS=0; notify-send() { DESKTOP_CALLS=$((DESKTOP_CALLS+1)); }; gdbus() { DESKTOP_CALLS=$((DESKTOP_CALLS+1)); }
mk_sys 3 8 8 1 0 1; fleet_pressure
chk "a CRIT never calls notify-send or gdbus" "$DESKTOP_CALLS" 0
chk "an unchanged CRIT re-sends nothing" "${#MAILS[@]}" 2
rm -f "$PRESSURE_STATE_PATH/level"
fleet_pressure
chk "a re-sent CRIT still never calls the desktop" "$DESKTOP_CALLS" 0
mk_sys 40 8 8 1 0 1; fleet_pressure
chk "back to OK clears the stop file" "$([[ -f "$(PRESSURE_STOP_FILE)" ]] && echo set || echo clear)" clear

echo "── ARM 4: orphan reaper on a fake process table ──"
SIGNALS=(); MAILS=(); mk_sys 40 8 8 1 0 1
mk_proc 100 1     500 $ME 10 python -c multiprocessing.spawn    # orphan, old, ours          -> reaped
mk_proc 101 1      60 $ME 10 python -c multiprocessing.spawn    # orphan but under 120 s     -> kept
mk_proc 102 900   500 $ME 10 python -c multiprocessing.spawn    # live parent                -> kept
mk_proc 103 1     500 2000 10 python -c multiprocessing.spawn   # someone else's             -> kept
mk_proc 104 1     500 $ME 10 python editor.py                   # not the pattern            -> kept
mk_proc 105 800   500 $ME 10 python -c multiprocessing.spawn    # parent is systemd --user   -> reaped
mk_proc 800 1    9000 $ME 10 /usr/lib/systemd/systemd --user
mk_proc 106 1     121 $ME 10 python -c multiprocessing.spawn    # just over the 120 s floor  -> reaped
mk_proc 107 1     120 $ME 10 python -c multiprocessing.spawn    # exactly at the floor       -> kept
found="$(orphan_find | awk '{print $1}' | sort -n | tr '\n' ' ')"
chk "orphan_find selects exactly the reapable set" "$found" "100 105 106 "
DIE_ON_TERM="100"
orphan_reap
chk "every reapable pid got TERM" "$(printf '%s\n' "${SIGNALS[@]}" | awk '$1=="TERM"{print $2}' | sort -n | tr '\n' ' ')" "100 105 106 "
chk "a pid that died on TERM is not KILLed" "$(printf '%s\n' "${SIGNALS[@]}" | awk '$1=="KILL"{print $2}' | sort -n | tr '\n' ' ')" "105 106 "
chk "no non-orphan was signalled" "$(printf '%s\n' "${SIGNALS[@]}" | awk '{print $2}' | sort -un | tr '\n' ' ')" "100 105 106 "
chk "every reaped pid is logged" "$(grep -c 'reaped pid=' "$(PRESSURE_STATE_DIR)/reap.log")" 3
chk "the report lists each reaped pid" "$(printf '%s' "$PR_REAPED_LINES" | grep -c '^pid ')" 3
DIE_ON_TERM=""; SIGNALS=()
rm -rf "$FAKE"/10[0-7]; orphan_reap
chk "nothing to reap: no signal, empty report" "${#SIGNALS[@]}:${PR_REAPED_LINES}" "0:"
mk_proc 110 1 500 $ME 10 python -c multiprocessing.spawn
ORPHAN_REAP_PATTERN=other-pattern
chk "only the reaped pattern matches" "$(orphan_find | wc -l)" 0
ORPHAN_REAP_PATTERN=multiprocessing.spawn
mk_sys 40 8 8 1 0 1; mk_proc 120 1 500 $ME 10 python -c multiprocessing.spawn; MAILS=(); SIGNALS=()
rm -f "$PRESSURE_STATE_PATH/level"; fleet_pressure
chk "an OK machine still reaps every tick" "$(printf '%s\n' "${SIGNALS[@]}" | awk '$1=="TERM"{print $2}' | sort -n | tr '\n' ' ')" "120 "

echo "── ARM 5: the battery guard refuses under pressure and starts when clear ──"
mk_sys 40 8 8 1 0 1; pressure_stop_clear
battery_pressure_verdict fast; chk "plenty of memory, no stop file: go" "$?" 0
mk_sys 15 8 8 1 0 1
battery_pressure_verdict fast; chk "15GB free is below the 16GB measured need: refuse" "$?" 1
chk "the refusal names memory" "$([[ "$BATTERY_PRESSURE_REFUSAL" == *"MemAvailable 15GB"* ]] && echo yes || echo no)" yes
mk_sys 16 8 8 1 0 1; battery_pressure_verdict fast; chk "16GB free meets the need: go" "$?" 0
mk_sys 40 8 8 1 0 1; pressure_stop_set "test"
battery_pressure_verdict fast; chk "stop file set: refuse" "$?" 1
chk "the refusal names the stop file" "$([[ "$BATTERY_PRESSURE_REFUSAL" == *"pressure-stop"* ]] && echo yes || echo no)" yes
pressure_stop_clear
battery_pressure_verdict full; chk "stop file cleared: go again" "$?" 0

echo "── ARM 6: one battery machine-wide (flock) ──"
BATTERY_LOCK_FILE="$AIMAIL_ROOT/battery.lock"
exec 8>"$BATTERY_LOCK_FILE"; flock -n 8
BATTERY_LOCK_HELD=0; battery_lock_acquire; chk "a held lock refuses the second battery" "$?" 1
flock -u 8; exec 8>&-
BATTERY_LOCK_HELD=0; battery_lock_acquire; chk "a free lock is taken" "$?" 0
battery_lock_acquire;  chk "taking it again in the same run is idempotent" "$?" 0
exec 9>&-; BATTERY_LOCK_HELD=0

echo "── ARM 7: the wrapper's own descendants are reaped, nobody else's ──"
SIGNALS=(); mk_sys 40 8 8 1 0 1
mk_proc 200 1   500 $ME 10 wrapper
mk_proc 201 200 400 $ME 10 python run_unit_tests.py
mk_proc 202 201 300 $ME 10 python -c multiprocessing.spawn
mk_proc 203 202 200 $ME 10 grandchild
mk_proc 300 1   500 $ME 10 some-other-battery
mk_proc 301 300 400 $ME 10 its-worker
chk "descendants are the wrapper's subtree only" "$(proc_descendants 200 | sort -n | tr '\n' ' ')" "201 202 203 "
battery_reap_descendants 200
chk "each descendant got TERM" "$(printf '%s\n' "${SIGNALS[@]}" | awk '$1=="TERM"{print $2}' | sort -n | tr '\n' ' ')" "201 202 203 "
chk "the other battery was left alone" "$(printf '%s\n' "${SIGNALS[@]}" | awk '$2>=300' | wc -l)" 0
SIGNALS=(); rm -rf "$FAKE"/20[1-3]; battery_reap_descendants 200
chk "no descendants: nothing signalled" "${#SIGNALS[@]}" 0

echo "── ARM 8: the capped-scope command prefix ──"
systemd-run() { return 0; }
battery_scope_prefix
chk "prefix always lowers cpu and io priority" "${BATTERY_PREFIX[*]:0:5}" "nice -n 19 ionice -c3"
chk "cap is MemTotal minus the reserve (64 - 12 = 52G), no swap, low CPUWeight" "$([[ "${BATTERY_PREFIX[*]}" == *"MemoryMax=52G"*"MemorySwapMax=0"*"CPUWeight=20"* ]] && echo yes || echo no)" yes
chk "there is no hard CPU quota" "$([[ "${BATTERY_PREFIX[*]}" == *CPUQuota* ]] && echo yes || echo no)" no
chk "a working scope says nothing" "$BATTERY_SCOPE_NOTE" ""
chk "the user-bus variables are supplied when the shell has none" "$(unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS; battery_scope_prefix; [[ "${BATTERY_PREFIX[*]}" == *"DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/"*"/bus systemd-run"* ]] && echo yes || echo no)" yes
sed -i "s/MemTotal: 67108864/MemTotal: 8388608/" "$FAKE/meminfo"; battery_scope_prefix
chk "an 8GB machine still gets the measured need as its cap, not less" "$([[ "${BATTERY_PREFIX[*]}" == *"MemoryMax=16G"* ]] && echo yes || echo no)" yes
systemd-run() { return 1; }
battery_scope_prefix
chk "no usable scope: falls back to nice/ionice" "${BATTERY_PREFIX[*]}" "nice -n 19 ionice -c3"
chk "the fallback is said out loud" "$([[ "$BATTERY_SCOPE_NOTE" == *"NO memory cap"* ]] && echo yes || echo no)" yes

echo
echo "pressure_watchdog: $PASS/$((PASS+FAIL)) checks passed"
if (( FAIL )); then printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
