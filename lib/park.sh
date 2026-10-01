# shellcheck shell=bash
# park.sh — seat parking with a cost guard, and the cold-seat watchdog.
#
# A seat's session keeps its context warm in the model provider's cache only while it keeps being
# used. After about an hour of silence the cache is gone, and the next wake re-reads the whole
# context at full price. Two decisions follow, and this file makes both mechanical:
#
#  1. A seat with nothing to do for a long stretch should be PARKED, on purpose and on the record,
#     so its poller stops waking it for ordinary mail. `seat park <seat> (--until <time> |
#     --trigger "<event>") --reason "<why>"` writes a state file; the poller reads it. Mail sent with
#     `--wake` still wakes a parked seat; everything else is held in the inbox and printed, in full,
#     on the next real wake (the park ending, or an urgent mail).
#  2. Un-parking too soon is the expensive mistake: the seat went cold when it was parked, so waking
#     it again within the guard window pays the cold wake AND forfeits the saving. `seat unpark` is
#     REFUSED while the park is younger than the guard (default 5 hours, AIMAIL_PARK_GUARD_HOURS),
#     and states the park time and the time left. `--expensive-ok "<reason>"` bypasses it, and every
#     bypass is appended, with its reason, to an append-only log.
#
# A park that was given `--until` ends by itself at that time; an expired park no longer holds mail
# and `seat unpark` just removes it. A park given only a `--trigger` ends when someone un-parks.
#
# `seat cold-watch` (for a ten-minute cron) is the other half: a seat that has been idle for
# AIMAIL_COLD_IDLE_MIN minutes (default 45) and is not parked is about to go cold, so the supervisor
# gets ONE no-wake alert per idle stretch: "give it work or park it". Idle is measured from the
# stop hook's own event log, the same record the fleet dashboard's LAST-STOP column reads: the time
# since the seat's last turn ended. A seat with no stop record is unknown, never idle.
#
# State, all under $STATE_DIR:
#   seat_park_<seat>       key<TAB>value lines: parked_at, until, trigger, reason
#   seat_park.log          append-only: epoch, event (park|unpark|expired-removed), seat, detail
#   park_overrides.log     append-only: epoch, time, seat, reason, parked_at (one per bypass)
#   cold_alert/<seat>      the last-stop epoch of the idle stretch already alerted

# park_now — the clock for every park decision; AIMAIL_NOW overrides it (tests).
park_now() { echo "${AIMAIL_NOW:-$(now_epoch)}"; }

SEAT_PARK_FILE() { echo "$STATE_DIR/seat_park_$1"; }
SEAT_PARK_LOG()  { echo "$STATE_DIR/seat_park.log"; }
PARK_OVERRIDE_LOG() { echo "$STATE_DIR/park_overrides.log"; }
COLD_ALERT_DIR() { echo "$STATE_DIR/cold_alert"; }

# seat_park_read <seat> <key> — the value, or rc 1 when there is no such park/key.
seat_park_read() {
  local f; f="$(SEAT_PARK_FILE "$1")"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v k="$2" '$1==k{print $2; found=1; exit} END{exit !found}' "$f"
}

# seat_park_active <seat> — 0 when the seat is parked right now: a park file exists and it has no
# --until, or its --until is still in the future.
seat_park_active() {
  local f; f="$(SEAT_PARK_FILE "$1")"
  [[ -f "$f" ]] || return 1
  local u; u="$(seat_park_read "$1" until 2>/dev/null || true)"
  [[ -z "$u" ]] && return 0
  [[ "$u" =~ ^[0-9]+$ ]] || return 0      # an unreadable end is not an end: stay parked, visibly
  (( u > $(park_now) ))
}

# park_guard_secs — the guard length in seconds from AIMAIL_PARK_GUARD_HOURS (default 5; decimals ok).
park_guard_secs() {
  local h="${AIMAIL_PARK_GUARD_HOURS:-5}"
  [[ "$h" =~ ^[0-9]+([.][0-9]+)?$ ]] || refused "AIMAIL_PARK_GUARD_HOURS must be a number of hours (got '$h')."
  awk -v h="$h" 'BEGIN{printf "%d", h*3600}'
}

# park_fmt_hm <seconds> — XhYYm
park_fmt_hm() {
  local s="$1"; (( s < 0 )) && s=0
  printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
}

_park_log() { # <event> <seat> <detail>
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\n' "$(park_now)" "$1" "$2" "$3" >> "$(SEAT_PARK_LOG)"
}

# _park_clean — one line of free text, tabs and newlines flattened.
_park_clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# seat_park_cmd <seat> (--until <time> | --trigger "<event>") --reason "<why>"
seat_park_cmd() {
  local usage='usage: aimail seat park <seat> (--until <time> | --trigger "<event>") --reason "<why>"'
  case "${1:-}" in -h|--help) info "$usage"; info "  <time>: YYYY-MM-DD, 'YYYY-MM-DD HH:MM', +3d or +12h; it must be in the future."
    info "  Nothing was changed."; exit 0 ;; esac
  [[ $# -ge 1 && "${1:0:1}" != "-" ]] || refused "$usage"
  local seat; seat="$(seat_resolve "$1")" || exit $?; shift
  local until_text="" trigger="" reason=""
  while (( $# )); do
    case "$1" in
      --until)   [[ $# -ge 2 ]] || refused "$usage"; until_text="$2"; shift 2 ;;
      --trigger) [[ $# -ge 2 ]] || refused "$usage"; trigger="$2"; shift 2 ;;
      --reason)  [[ $# -ge 2 ]] || refused "$usage"; reason="$2"; shift 2 ;;
      *) refused "seat park: unknown argument '$1'" "$usage" ;;
    esac
  done
  [[ -n "$until_text" || -n "$trigger" ]] || refused "a park needs an end: --until <time> or --trigger \"<event>\"." \
    "A park with neither is a seat nobody remembers to wake." "$usage"
  [[ -n "${reason// /}" ]] || refused "a park needs a reason: --reason \"<why>\"." "$usage"
  [[ "$(seat_field "$seat" 2)" == "retired" ]] && refused "seat '$seat' is retired; there is nothing to park."
  if seat_park_active "$seat"; then
    refused "seat '$seat' is already parked (since $(date -d "@$(seat_park_read "$seat" parked_at)" '+%F %H:%M'))." \
      "  aimail seat unpark $seat      (refused for the first $(awk -v s="$(park_guard_secs)" 'BEGIN{printf "%g", s/3600}') hours; see its message)"
  fi
  park_guard_secs >/dev/null || exit $?     # a bad guard setting is refused now, not after the state is written
  local now until_at=""
  now="$(park_now)"
  if [[ -n "$until_text" ]]; then
    case "$until_text" in
      +[0-9]*d) until_at=$(( now + ${until_text//[^0-9]/} * 86400 )) ;;
      +[0-9]*h) until_at=$(( now + ${until_text//[^0-9]/} * 3600 )) ;;
      *) until_at="$(date -d "$until_text" +%s 2>/dev/null)" || until_at="" ;;
    esac
    [[ "$until_at" =~ ^[0-9]+$ ]] && (( until_at > now )) \
      || refused "--until '$until_text' is not a future time." "Use YYYY-MM-DD, 'YYYY-MM-DD HH:MM', +3d or +12h."
  fi
  ensure_dirs
  {
    printf 'seat\t%s\n' "$seat"
    printf 'parked_at\t%s\n' "$now"
    printf 'until\t%s\n' "$until_at"
    printf 'trigger\t%s\n' "$(_park_clean "$trigger")"
    printf 'reason\t%s\n' "$(_park_clean "$reason")"
  } | atomic_write "$(SEAT_PARK_FILE "$seat")"
  _park_log park "$seat" "until=${until_at:--} trigger=$(_park_clean "$trigger") reason=$(_park_clean "$reason")"
  ok "seat '$seat' parked at $(date -d "@$now" '+%F %H:%M')$( [[ -n "$until_at" ]] && printf ', until %s' "$(date -d "@$until_at" '+%F %H:%M')")$( [[ -n "$trigger" ]] && printf ', trigger: %s' "$trigger")"
  info "  Ordinary mail is held, not lost: it prints in full on the seat's next real wake."
  info "  Mail sent with --wake still wakes it. Un-parking is refused for the first $(awk -v s="$(park_guard_secs)" 'BEGIN{printf "%g", s/3600}') hours (a cold wake costs more than keeping it warm)."
}

# seat_unpark_cmd <seat> [--expensive-ok "<reason>"]
seat_unpark_cmd() {
  local usage='usage: aimail seat unpark <seat> [--expensive-ok "<reason>"]'
  case "${1:-}" in -h|--help) info "$usage"; info "  Refused while the park is younger than the guard (AIMAIL_PARK_GUARD_HOURS, default 5)."
    info "  Nothing was changed."; exit 0 ;; esac
  [[ $# -ge 1 && "${1:0:1}" != "-" ]] || refused "$usage"
  local seat; seat="$(seat_resolve "$1")" || exit $?; shift
  local ok_reason="" ok_given=0
  while (( $# )); do
    case "$1" in
      --expensive-ok) [[ $# -ge 2 ]] || refused "$usage"; ok_reason="$2"; ok_given=1; shift 2 ;;
      *) refused "seat unpark: unknown argument '$1'" "$usage" ;;
    esac
  done
  (( ok_given )) && [[ -z "${ok_reason// /}" ]] && refused "--expensive-ok needs a reason: --expensive-ok \"<why waking now is worth the cost>\"."
  local f; f="$(SEAT_PARK_FILE "$seat")"
  if [[ ! -f "$f" ]]; then info "seat '$seat' is not parked. Nothing was changed."; return 0; fi
  local now parked_at; now="$(park_now)"; parked_at="$(seat_park_read "$seat" parked_at 2>/dev/null || true)"
  if ! seat_park_active "$seat"; then
    rm -f "$f"; _park_log expired-removed "$seat" "parked_at=${parked_at:-?}"
    ok "seat '$seat': the park had already expired; its record is removed. Nothing is held back any more."
    return 0
  fi
  [[ "$parked_at" =~ ^[0-9]+$ ]] || refused "seat '$seat': its park record has no readable parked_at; not guessing. See $f"
  local guard elapsed remain
  guard="$(park_guard_secs)" || exit $?; elapsed=$(( now - parked_at )); remain=$(( guard - elapsed ))
  if (( remain > 0 )); then
    if (( ! ok_given )); then
      refused "seat '$seat' was parked at $(date -d "@$parked_at" '+%F %H:%M') ($(park_fmt_hm "$elapsed") ago): too recent to un-park." \
        "Un-parking inside the first $(awk -v s="$guard" 'BEGIN{printf "%g", s/3600}') hours costs more than keeping the seat warm would have:" \
        "it went cold when it was parked, so a wake now pays the full cold-start price and the saving is gone." \
        "The guard lifts at $(date -d "@$(( parked_at + guard ))" '+%F %H:%M'), in $(park_fmt_hm "$remain")." \
        "To wake it anyway: aimail seat unpark $seat --expensive-ok \"<reason>\"  (the reason is logged)."
    fi
    ensure_dirs
    printf '%s\t%s\t%s\t%s\tparked_at=%s\n' "$now" "$(date -d "@$now" '+%Y-%m-%dT%H:%M:%S%z')" "$seat" "$(_park_clean "$ok_reason")" "$parked_at" >> "$(PARK_OVERRIDE_LOG)"
    warn "guard bypassed for '$seat' ($(park_fmt_hm "$remain") early); the reason is logged in $(PARK_OVERRIDE_LOG)."
  elif (( ok_given )); then
    info "the guard had already lifted for '$seat'; --expensive-ok was not needed and is not logged."
  fi
  rm -f "$f"; _park_log unpark "$seat" "parked_at=$parked_at"
  ok "seat '$seat' un-parked. Mail held during the park is delivered on its next wake."
}

# ─── idle time, from the stop hook's event log ────────────────────────────────
# park_last_stop_epoch <seat> — when the seat's last turn ended, or rc 1 when there is no stop record.
park_last_stop_epoch() {
  command -v last_stop >/dev/null 2>&1 || { source "$AIMAIL_LIB/fleet.sh"; }
  local e d; IFS=$'\t' read -r e d < <(last_stop "$1")
  [[ "$e" =~ ^[0-9]+$ ]] || return 1
  echo "$e"
}

# park_idle_secs <seat> — seconds since the seat's last turn ended; prints nothing (and returns 1)
# when there is no stop record, which is UNKNOWN and never 0. The one idle figure: the watchdog and
# the per-seat section of `budget pool` both read it here.
park_idle_secs() {
  local e; e="$(park_last_stop_epoch "$1")" || return 1
  local n=$(( $(park_now) - e )); (( n < 0 )) && n=0
  echo "$n"
}

# seat_cold_watch [--dry-run] — the ten-minute cron entry. One no-wake alert per idle stretch.
seat_cold_watch() {
  local dry=0
  case "${1:-}" in
    -h|--help) info "usage: aimail seat cold-watch [--dry-run]"
               info "  Cron, every 10 minutes: a seat idle ${AIMAIL_COLD_IDLE_MIN:-45}+ minutes and not parked gets ONE no-wake alert to the supervisor."
               info "  Nothing was changed."; exit 0 ;;
    --dry-run) dry=1 ;;
    "") ;;
    *) refused "seat cold-watch: unknown argument '$1'" "usage: aimail seat cold-watch [--dry-run]" ;;
  esac
  local supervisor="${AIMAIL_SUPERVISOR:-}"
  [[ -n "$supervisor" ]] || refused "seat cold-watch needs the supervisor seat: AIMAIL_SUPERVISOR is not set." \
    "Set it in etc/aimail.conf; the tool does not guess which seat that is."
  seat_exists "$supervisor" || refused "seat cold-watch: the supervisor seat '$supervisor' is not registered."
  local idle_min="${AIMAIL_COLD_IDLE_MIN:-45}" cold_min="${AIMAIL_COLD_AFTER_MIN:-60}"
  [[ "$idle_min" =~ ^[0-9]+$ && "$cold_min" =~ ^[0-9]+$ ]] && (( cold_min > idle_min )) \
    || refused "AIMAIL_COLD_IDLE_MIN and AIMAIL_COLD_AFTER_MIN must be whole minutes, the second larger than the first."
  command -v last_stop >/dev/null 2>&1 || source "$AIMAIL_LIB/fleet.sh"
  ensure_dirs; mkdir -p "$(COLD_ALERT_DIR)"
  local seat stop_e idle rec n_alert=0 n_idle=0 n_parked=0 n_seen=0
  while IFS= read -r seat; do
    [[ -n "$seat" ]] || continue
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    n_seen=$((n_seen+1))
    if seat_park_active "$seat"; then n_parked=$((n_parked+1)); continue; fi
    stop_e="$(park_last_stop_epoch "$seat")" || continue   # no stop record: unknown, never idle
    idle=$(( ( $(park_now) - stop_e ) / 60 ))
    (( idle >= idle_min )) || continue
    n_idle=$((n_idle+1))
    rec="$(cat "$(COLD_ALERT_DIR)/$seat" 2>/dev/null || true)"
    [[ "$rec" == "$stop_e" ]] && continue               # this idle stretch was already alerted
    # a seat in the middle of a long turn has not ended one, but it is not idle either
    if command -v _idle_seat_has_live_working_session >/dev/null 2>&1 && _idle_seat_has_live_working_session "$seat"; then continue; fi
    if (( dry )); then info "would alert: $seat idle ${idle}m"; continue; fi
    local body; body="$(mktemp "$AIMAIL_ROOT/tmp/coldwatch.XXXXXX")"
    printf '%s goes cold in about %s minutes: give it work or park it\n\n  idle %s minutes (last turn ended %s)\n  give it work, or:  aimail seat park %s --until <time> --reason "<why>"\n' \
      "$seat" "$(( cold_min - idle_min ))" "$idle" "$(date -d "@$stop_e" '+%F %H:%M')" "$seat" > "$body"
    if ( mail_send --to "$supervisor" --no-wake --from "$supervisor" \
           --subject "$seat goes cold in about $(( cold_min - idle_min )) minutes: give it work or park it" --body-file "$body" ) >/dev/null 2>&1; then
      printf '%s' "$stop_e" > "$(COLD_ALERT_DIR)/$seat"; n_alert=$((n_alert+1))
    else
      warn "cold-watch: could not mail '$supervisor' about '$seat'; will retry next run"
    fi
    rm -f "$body"
  done < <(seat_names)
  info "cold-watch: $n_seen seat(s) checked, $n_parked parked, $n_idle idle ${idle_min}m+, $n_alert alert(s) sent"
}
