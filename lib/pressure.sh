#!/usr/bin/env bash
# lib/pressure.sh -- RAM/CPU pressure watchdog, orphan reaper, and the battery resource guard.
#
# WHY: a machine shared by a whole fleet plus a parallel test battery ran out of memory and
# swapped hard; leaked pool workers (parent pid 1) kept holding memory after their runs ended.
# Nothing noticed until a person did. This file is the detector (`fleet pressure`, cron every
# minute), the reaper for leaked workers, and the guard `bin/run_canonical_battery.sh` uses to
# refuse to start, and to run capped, under pressure.
#
# Generic on purpose: no project, company or plan names, and NO settings for a human to maintain:
# every threshold below is either derived from the machine at run time (MemTotal, SwapTotal) or a
# constant with its reason beside it. Tests override the plain shell variables below AFTER sourcing
# this file (they are not read from the environment); the one wrapper-level test edits a COPY of
# this file instead.

PRESSURE_PROC_ROOT_DIR=/proc          # tests point this at a temp dir of fake /proc files
PRESSURE_PROC_ROOT() { printf '%s' "$PRESSURE_PROC_ROOT_DIR"; }

# Memory: a fraction of the machine, not a GB figure, so it fits a 16 GB laptop and a 256 GB server.
# WARN below 20% of MemTotal available: a parallel test run starts pushing the page cache out and
# the desktop feels it. CRIT below 10%: the OOM killer is close, so new batteries are refused.
PRESSURE_WARN_AVAIL_PCT=20
PRESSURE_CRIT_AVAIL_PCT=10
# Swap used: the kernel swaps cold pages out long before trouble, so a high figure alone is weak.
# It warns above 60%, and is critical above 85% ONLY together with real memory pressure (see
# pressure_level); by itself it never stops a battery.
PRESSURE_WARN_SWAP_PCT=60
PRESSURE_CRIT_SWAP_PCT=85
# PSI avg60 = percent of the last minute a task waited. Memory "some" > 10: tasks regularly stall on
# memory (reclaim/swap). Memory "full" > 5: EVERY task stalled for 5% of a minute, a near-freeze.
# CPU "some" > 40: runnable work waited a large share of the minute. CPU usage itself never alerts;
# only waiting does, because waiting is what a person feels.
PRESSURE_WARN_MEM_PSI=10
PRESSURE_CRIT_MEM_PSI_FULL=5
PRESSURE_WARN_CPU_PSI=40
# Leaked worker pools: the generic shape is a multiprocessing spawn child whose parent died, so its
# parent is init (pid 1) or the `systemd --user` manager. 120 s keeps a worker that is merely between
# parents from being killed; real leaks sit for hours.
ORPHAN_REAP_PATTERN="multiprocessing.spawn"
ORPHAN_MIN_AGE_S=120
PRESSURE_TOP_N=10                     # processes listed in an alert mail
PRESSURE_CLK_TCK=100                  # USER_HZ: /proc start times are in 1/100 s on Linux
PRESSURE_UID=""                       # empty = this user; tests set a fixed uid
REAP_GRACE_S=5                        # seconds between TERM and KILL
PRESSURE_STATE_PATH=""                # empty = <state dir>/pressure
BATTERY_LOCK_FILE=/tmp/aimail-battery.lock
# Battery sizing. MEASURED (2026-09-30, one battery alone, summed RSS of the wrapper's whole process
# tree sampled every 2 s, which over-counts shared pages): FAST (--workers auto) peaked at 11.1 GB;
# FULL (serial) peaked at 1.7 GB. A battery is refused when less than NEED is available: the FAST peak
# plus about 40% headroom. Its systemd scope is capped at MemTotal minus RESERVE, so a runaway
# battery is killed inside its own scope while the desktop and the fleet keep a fixed reserve.
BATTERY_NEED_GB=16
BATTERY_RESERVE_GB=12

PRESSURE_STATE_DIR() {
  [[ -n "$PRESSURE_STATE_PATH" ]] && { printf '%s' "$PRESSURE_STATE_PATH"; return; }
  printf '%s/pressure' "${STATE_DIR:-${AIMAIL_ROOT:-$HOME/.aimail}/state}"
}
PRESSURE_STOP_FILE() { printf '%s/pressure-stop' "$(PRESSURE_STATE_DIR)"; }

# _psi_avg60 FILE KIND  -> prints the avg60 of the "some" or "full" line (integer part), or empty.
_psi_avg60() {
  local f="$1" kind="$2" line tok
  [[ -r "$f" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == "$kind "* ]] || continue
    for tok in $line; do
      [[ "$tok" == avg60=* ]] && { tok="${tok#avg60=}"; printf '%s' "${tok%%.*}"; return 0; }
    done
  done < "$f"
}

# _meminfo_kb FIELD -> kB value of a /proc/meminfo field, or empty.
_meminfo_kb() {
  local f; f="$(PRESSURE_PROC_ROOT)/meminfo"
  [[ -r "$f" ]] || return 0
  local k v rest
  while read -r k v rest; do
    [[ "$k" == "$1:" ]] && { printf '%s' "$v"; return 0; }
  done < "$f"
}

# pressure_read -> sets PR_MEM_AVAIL_GB PR_SWAP_PCT PR_MEM_SOME PR_MEM_FULL PR_CPU_SOME
# ("" = unmeasured; an unmeasured signal never trips a level).
pressure_read() {
  local avail swt swf root; root="$(PRESSURE_PROC_ROOT)"
  avail="$(_meminfo_kb MemAvailable)"; PR_MEM_TOTAL_KB="$(_meminfo_kb MemTotal)"
  swt="$(_meminfo_kb SwapTotal)"; swf="$(_meminfo_kb SwapFree)"
  PR_MEM_AVAIL_GB=""; PR_SWAP_PCT=""
  PR_MEM_AVAIL_KB="$avail"
  [[ -n "$avail" ]] && PR_MEM_AVAIL_GB=$(( avail / 1048576 ))
  if [[ -n "$swt" && -n "$swf" ]] && (( swt > 0 )); then
    PR_SWAP_PCT=$(( (swt - swf) * 100 / swt ))
  fi
  PR_MEM_SOME="$(_psi_avg60 "$root/pressure/memory" some)"
  PR_MEM_FULL="$(_psi_avg60 "$root/pressure/memory" full)"
  PR_CPU_SOME="$(_psi_avg60 "$root/pressure/cpu" some)"
}

# pressure_level -> prints OK | WARN | CRIT from the PR_* values; PR_REASON lists what tripped.
pressure_level() {
  local lvl=OK; PR_REASON=""
  _trip() { # _trip LEVEL TEXT
    [[ "$1" == CRIT ]] && lvl=CRIT
    [[ "$1" == WARN && "$lvl" == OK ]] && lvl=WARN
    PR_REASON+="$1: $2; "
  }
  if [[ -n "$PR_MEM_AVAIL_KB" && -n "$PR_MEM_TOTAL_KB" ]] && (( PR_MEM_TOTAL_KB > 0 )); then
    local pct=$(( PR_MEM_AVAIL_KB * 100 / PR_MEM_TOTAL_KB ))
    if (( pct < PRESSURE_CRIT_AVAIL_PCT )); then
      _trip CRIT "MemAvailable ${PR_MEM_AVAIL_GB}GB is ${pct}% of memory (< ${PRESSURE_CRIT_AVAIL_PCT}%)"
    elif (( pct < PRESSURE_WARN_AVAIL_PCT )); then
      _trip WARN "MemAvailable ${PR_MEM_AVAIL_GB}GB is ${pct}% of memory (< ${PRESSURE_WARN_AVAIL_PCT}%)"
    fi
  fi
  # Swap used only ever creeps up as cold pages move out, so a high figure ALONE says nothing is wrong:
  # it is critical only together with a second reading that shows real memory pressure (available
  # memory under the WARN fraction, or memory stalls over their WARN value). Otherwise it stays a
  # warning. Without this rule a full swap with plenty of free memory would set the stop file and
  # refuse every battery, with nobody able to override it.
  local strained=0
  [[ -n "$PR_MEM_AVAIL_KB" && -n "$PR_MEM_TOTAL_KB" ]] && (( PR_MEM_TOTAL_KB > 0 )) \
    && (( PR_MEM_AVAIL_KB * 100 / PR_MEM_TOTAL_KB < PRESSURE_WARN_AVAIL_PCT )) && strained=1
  [[ -n "$PR_MEM_SOME" ]] && (( PR_MEM_SOME > PRESSURE_WARN_MEM_PSI )) && strained=1
  if [[ -n "$PR_SWAP_PCT" ]]; then
    if (( PR_SWAP_PCT > PRESSURE_CRIT_SWAP_PCT && strained )); then
      _trip CRIT "swap ${PR_SWAP_PCT}% > ${PRESSURE_CRIT_SWAP_PCT}% with memory under pressure"
    elif (( PR_SWAP_PCT > PRESSURE_WARN_SWAP_PCT )); then
      _trip WARN "swap ${PR_SWAP_PCT}% > ${PRESSURE_WARN_SWAP_PCT}%"
    fi
  fi
  [[ -n "$PR_MEM_FULL" ]] && (( PR_MEM_FULL > PRESSURE_CRIT_MEM_PSI_FULL )) && _trip CRIT "memory PSI full avg60 ${PR_MEM_FULL} > ${PRESSURE_CRIT_MEM_PSI_FULL}"
  [[ -n "$PR_MEM_SOME" ]] && (( PR_MEM_SOME > PRESSURE_WARN_MEM_PSI )) && _trip WARN "memory PSI some avg60 ${PR_MEM_SOME} > ${PRESSURE_WARN_MEM_PSI}"
  [[ -n "$PR_CPU_SOME" ]] && (( PR_CPU_SOME > PRESSURE_WARN_CPU_PSI )) && _trip WARN "cpu PSI some avg60 ${PR_CPU_SOME} > ${PRESSURE_WARN_CPU_PSI}"
  PR_LEVEL="$lvl"; printf '%s' "$lvl"
}

# ─── process table (from PROC_ROOT, so a fake table works) ───────────────────────────────────
# _proc_stat_field PID N -> field N of /proc/PID/stat after the ")" (N=1 is state, 2 ppid,
# 20 starttime). The comm field may contain spaces, so split after the last ")".
_proc_stat_fields() {
  local f; f="$(PRESSURE_PROC_ROOT)/$1/stat"
  [[ -r "$f" ]] || return 1
  local s; s="$(<"$f")"
  PROC_FIELDS=( ${s##*) } )
}
_proc_cmdline() { local f; f="$(PRESSURE_PROC_ROOT)/$1/cmdline"; [[ -r "$f" ]] && tr '\0' ' ' < "$f"; }
_proc_uid() {
  local f; f="$(PRESSURE_PROC_ROOT)/$1/status"; [[ -r "$f" ]] || return 1
  local k v rest
  while read -r k v rest; do [[ "$k" == "Uid:" ]] && { printf '%s' "$v"; return 0; }; done < "$f"
}
_proc_rss_kb() {
  local f; f="$(PRESSURE_PROC_ROOT)/$1/status"; [[ -r "$f" ]] || return 1
  local k v rest
  while read -r k v rest; do [[ "$k" == "VmRSS:" ]] && { printf '%s' "$v"; return 0; }; done < "$f"
  printf '0'
}
# _proc_age_s PID -> process age in seconds. Uptime and clock ticks come from PROC_ROOT/uptime
# and PRESSURE_CLK_TCK so a fake table stays deterministic.
_proc_age_s() {
  _proc_stat_fields "$1" || return 1
  local start="${PROC_FIELDS[19]}" up tck="$PRESSURE_CLK_TCK"
  read -r up _ < "$(PRESSURE_PROC_ROOT)/uptime" || return 1
  up="${up%%.*}"
  printf '%s' $(( up - start / tck ))
}
_proc_list() {
  local d root; root="$(PRESSURE_PROC_ROOT)"
  for d in "$root"/[0-9]*; do [[ -d "$d" ]] && printf '%s\n' "${d##*/}"; done
}
_proc_cwd() { local l; l="$(readlink "$(PRESSURE_PROC_ROOT)/$1/cwd" 2>/dev/null)"; printf '%s' "$l"; }

# _parent_is_init_like PPID -> 0 when the parent is pid 1 or a `systemd --user` process.
_parent_is_init_like() {
  [[ "$1" == 1 ]] && return 0
  local c; c="$(_proc_cmdline "$1")" || return 1
  [[ "$c" == *"systemd --user"* ]]
}

# orphan_find -> prints "pid age_s" for each of this user's processes that match the pattern,
# whose parent is init-like, and older than ORPHAN_MIN_AGE_S.
orphan_find() {
  local me="${PRESSURE_UID:-$(id -u)}" pid uid cmd age ppid
  while read -r pid; do
    uid="$(_proc_uid "$pid")" || continue
    [[ "$uid" == "$me" ]] || continue
    cmd="$(_proc_cmdline "$pid")" || continue
    [[ "$cmd" == *"$ORPHAN_REAP_PATTERN"* ]] || continue
    _proc_stat_fields "$pid" || continue
    ppid="${PROC_FIELDS[1]}"
    _parent_is_init_like "$ppid" || continue
    age="$(_proc_age_s "$pid")" || continue
    (( age > ORPHAN_MIN_AGE_S )) || continue
    printf '%s %s\n' "$pid" "$age"
  done < <(_proc_list)
}

# _pressure_signal SIG PID -> the one place a signal is sent (tests redefine it to record).
_pressure_signal() { kill "-$1" "$2" 2>/dev/null; }
_pressure_sleep() { sleep "$REAP_GRACE_S"; }

# orphan_reap -> TERM then KILL every orphan_find hit; logs each pid to the reap log and sets
# PR_REAPED_LINES (one line per pid) for the next mail.
orphan_reap() {
  PR_REAPED_LINES=""
  local -a hits=(); local line pid age cmd log
  while IFS= read -r line; do [[ -n "$line" ]] && hits+=("$line"); done < <(orphan_find)
  (( ${#hits[@]} )) || return 0
  mkdir -p "$(PRESSURE_STATE_DIR)"
  log="$(PRESSURE_STATE_DIR)/reap.log"
  local -A cmds=()
  for line in "${hits[@]}"; do
    pid="${line%% *}"
    cmds[$pid]="$(_proc_cmdline "$pid")"
    _pressure_signal TERM "$pid"
  done
  _pressure_sleep
  for line in "${hits[@]}"; do
    pid="${line%% *}"; age="${line##* }"; cmd="${cmds[$pid]}"
    [[ -d "$(PRESSURE_PROC_ROOT)/$pid" ]] && _pressure_signal KILL "$pid"
    printf '%s reaped pid=%s age=%ss cmd=%s\n' "$(date -u +%FT%TZ)" "$pid" "$age" "${cmd:0:160}" >> "$log"
    PR_REAPED_LINES+="pid ${pid} (age ${age}s): ${cmd:0:120}"$'\n'
  done
}

# pressure_top_rss -> top N processes by RSS: pid ppid age rss-MB seat/worktree-hint cmd.
pressure_top_rss() {
  local pid rss ppid age cwd cmd
  while read -r pid; do
    rss="$(_proc_rss_kb "$pid")" || continue
    [[ -n "$rss" ]] && printf '%s %s\n' "$rss" "$pid"
  done < <(_proc_list) | sort -rn | head -n "$PRESSURE_TOP_N" | while read -r rss pid; do
    _proc_stat_fields "$pid" || continue
    ppid="${PROC_FIELDS[1]}"; age="$(_proc_age_s "$pid")"
    cwd="$(_proc_cwd "$pid")"; cmd="$(_proc_cmdline "$pid")"
    printf 'pid=%s ppid=%s age=%ss rss=%sMB cwd=%s cmd=%s\n' "$pid" "$ppid" "${age:-?}" "$(( rss / 1024 ))" "${cwd:--}" "${cmd:0:120}"
  done
}

# pressure_stop_set / pressure_stop_clear: the file the battery wrapper reads.
pressure_stop_set() { mkdir -p "$(PRESSURE_STATE_DIR)"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" > "$(PRESSURE_STOP_FILE)"; }
pressure_stop_clear() { rm -f "$(PRESSURE_STOP_FILE)"; }
pressure_stop_active() { [[ -f "$(PRESSURE_STOP_FILE)" ]]; }

# fleet_pressure -> the cron entry point. One reading, reap orphans, mail on a level CHANGE
# (dedup by level like the disk check), CRIT also sets the stop file. Mail to the supervisor is the
# ONLY alert channel: no desktop pop-ups, by design.
fleet_pressure() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}" lvl marker prev
  mkdir -p "$(PRESSURE_STATE_DIR)"
  pressure_read
  pressure_level >/dev/null; lvl="$PR_LEVEL"   # not $(...): PR_REASON must survive
  orphan_reap
  marker="$(PRESSURE_STATE_DIR)/level"
  prev="$(cat "$marker" 2>/dev/null)"

  if [[ "$lvl" == CRIT ]]; then pressure_stop_set "$PR_REASON"; else pressure_stop_clear; fi

  if [[ "$lvl" == OK ]]; then
    printf 'OK' > "$marker"
    info "pressure: OK (mem avail=${PR_MEM_AVAIL_GB:-?}GB swap=${PR_SWAP_PCT:-?}% psi mem some=${PR_MEM_SOME:-?} full=${PR_MEM_FULL:-?} cpu some=${PR_CPU_SOME:-?}); reaped: $(printf '%s' "$PR_REAPED_LINES" | grep -c .)"
    return 0
  fi

  local send=0
  [[ "$prev" != "$lvl" ]] && send=1
  [[ -n "$PR_REAPED_LINES" ]] && send=1
  if (( ! send )); then
    info "pressure: $lvl unchanged since last alert, not re-sent"
    return 0
  fi

  if seat_exists "$supervisor"; then
    local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/pressure.XXXXXX")"
    {
      printf '# PRESSURE %s: %s\n\n' "$lvl" "$PR_REASON"
      printf 'Readings: MemAvailable=%sGB swap=%s%% memory-PSI some=%s full=%s cpu-PSI some=%s\n\n' \
        "${PR_MEM_AVAIL_GB:-?}" "${PR_SWAP_PCT:-?}" "${PR_MEM_SOME:-?}" "${PR_MEM_FULL:-?}" "${PR_CPU_SOME:-?}"
      [[ "$lvl" == CRIT ]] && printf 'New batteries are refused while this holds (stop file set).\n\n'
      if [[ -n "$PR_REAPED_LINES" ]]; then
        printf 'Reaped orphaned workers (pattern "%s", parent init, older than %ss):\n%s\n' \
          "$ORPHAN_REAP_PATTERN" "$ORPHAN_MIN_AGE_S" "$PR_REAPED_LINES"
      fi
      printf 'Top %s processes by RSS:\n' "$PRESSURE_TOP_N"
      pressure_top_rss
      printf '\nNo human asked for this -- the sweep found it unprompted.\n'
    } > "$body"
    if mail_send --to "$supervisor" --from "$supervisor" \
         --subject "PRESSURE ${lvl}: memory/cpu threshold crossed" --body-file "$body" >/dev/null 2>&1; then
      printf '%s' "$lvl" > "$marker"
    fi
    rm -f "$body"
  else
    warn "pressure: $lvl but supervisor '$supervisor' is not registered -- no alert sent"
  fi
}

# ─── battery guard ──────────────────────────────────────────────────────────────────────────
# battery_pressure_verdict GATE -> 0 go; 1 refuse with BATTERY_PRESSURE_REFUSAL set.
# Refuses when the stop file is set or MemAvailable is below the measured need for that gate.
battery_pressure_verdict() {
  local gate="$1" need avail_kb
  BATTERY_PRESSURE_REFUSAL=""
  if pressure_stop_active; then
    BATTERY_PRESSURE_REFUSAL="REFUSED: pressure-stop is set ($(cat "$(PRESSURE_STOP_FILE)" 2>/dev/null))"
    return 1
  fi
  need="$BATTERY_NEED_GB"
  avail_kb="$(_meminfo_kb MemAvailable)"
  if [[ -n "$avail_kb" ]] && (( avail_kb / 1048576 < need )); then
    BATTERY_PRESSURE_REFUSAL="REFUSED: MemAvailable $(( avail_kb / 1048576 ))GB is below the measured need ${need}GB for a ${gate} battery"
    return 1
  fi
  return 0
}

# battery_scope_prefix -> fills BATTERY_PREFIX=( ... ) with the wrapper command prefix.
# Always nice 19 + ionice idle (the fleet wins every CPU and disk contention). When a systemd user
# scope is usable, also a scope with MemoryMax = MemTotal - RESERVE, no swap, and CPUWeight=20 (the
# default weight is 100, so the fleet gets 5x the share under contention). CPU has no hard quota:
# CPUWeight plus nice already make a battery yield, and a quota would slow it on an idle machine.
# Without a usable scope the battery still runs niced, and BATTERY_SCOPE_NOTE says out loud that it
# has NO memory cap.
battery_scope_prefix() {
  BATTERY_PREFIX=( nice -n 19 ionice -c3 ); BATTERY_SCOPE_NOTE=""
  local total_kb cap_gb; total_kb="$(_meminfo_kb MemTotal)"
  cap_gb=$(( ${total_kb:-0} / 1048576 - BATTERY_RESERVE_GB ))
  (( cap_gb < BATTERY_NEED_GB )) && cap_gb=$BATTERY_NEED_GB   # a small machine still gets a usable cap
  # A cron or background-job shell often has no user-bus variables even though the user manager
  # is running; point them at the standard per-user paths before probing.
  local rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local bus="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$rt/bus}"
  if command -v systemd-run >/dev/null 2>&1 \
     && XDG_RUNTIME_DIR="$rt" DBUS_SESSION_BUS_ADDRESS="$bus" systemd-run --user --scope --quiet true >/dev/null 2>&1; then
    BATTERY_PREFIX+=( env "XDG_RUNTIME_DIR=$rt" "DBUS_SESSION_BUS_ADDRESS=$bus"
                      systemd-run --user --scope --quiet -p "MemoryMax=${cap_gb}G" -p MemorySwapMax=0 -p CPUWeight=20 )
  else
    BATTERY_SCOPE_NOTE="systemd-run --user scope unavailable: running with nice/ionice only, NO memory cap"
  fi
  return 0
}

# battery_lock_acquire -> 0 when this process holds (or now takes) the one machine-wide battery
# lock. Non-blocking: a second battery is refused (or keeps waiting in the --wait loop), never
# run alongside. The lock is on fd 9, which child processes inherit: it is released when the wrapper AND
# its children exit, so a worker that outlives its wrapper keeps it until the exit trap, or the orphan
# reaper after 120 s, kills that worker. That is intended: memory is still held until then.
battery_lock_acquire() {
  [[ "${BATTERY_LOCK_HELD:-0}" == 1 ]] && return 0
  local lock="$BATTERY_LOCK_FILE"
  # an unwritable lock path fails open, like the other readers. No `2>/dev/null` on the exec:
  # on a bare `exec` a redirect is permanent and would silence this shell's stderr for good.
  [[ -w "$lock" || ( ! -e "$lock" && -w "$(dirname "$lock")" ) ]] || return 0
  exec 9>"$lock" || return 0
  if flock -n 9; then BATTERY_LOCK_HELD=1; return 0; fi
  exec 9>&-
  return 1
}

# proc_descendants PID -> every descendant pid of PID (children first-level then deeper), one per
# line, from the process table under PROC_ROOT.
proc_descendants() {
  local root="$1" pid ppid
  local -A kids=()
  while read -r pid; do
    _proc_stat_fields "$pid" || continue
    ppid="${PROC_FIELDS[1]}"
    kids[$ppid]+="$pid "
  done < <(_proc_list)
  local -a queue=("$root"); local cur c
  while (( ${#queue[@]} )); do
    cur="${queue[0]}"; queue=("${queue[@]:1}")
    for c in ${kids[$cur]:-}; do printf '%s\n' "$c"; queue+=("$c"); done
  done
}

# battery_reap_descendants PID -> TERM then KILL every descendant of PID (the wrapper's own
# workers), logging each pid to the reap log.
battery_reap_descendants() {
  local -a pids=(); local p log
  while read -r p; do [[ -n "$p" ]] && pids+=("$p"); done < <(proc_descendants "$1")
  (( ${#pids[@]} )) || return 0
  mkdir -p "$(PRESSURE_STATE_DIR)" 2>/dev/null
  log="$(PRESSURE_STATE_DIR)/reap.log"
  for p in "${pids[@]}"; do _pressure_signal TERM "$p"; done
  _pressure_sleep
  for p in "${pids[@]}"; do
    [[ -d "$(PRESSURE_PROC_ROOT)/$p" ]] && _pressure_signal KILL "$p"
    printf '%s battery-exit reaped pid=%s of wrapper=%s\n' "$(date -u +%FT%TZ)" "$p" "$1" >> "$log" 2>/dev/null
  done
}
