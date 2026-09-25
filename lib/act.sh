#!/usr/bin/env bash
# lib/act.sh — T-917 item 4: the balancer ACTS. Announce-then-do, one seat per tick, never mid-turn.
#
# the owner 2026-09-22 17:03 (via assistant): "at the 50%/80% crossings, the balancer actually MOVES
# seats using the resume-by-default migrate, one at a time, never a seat that's mid-turn (wait for
# it to go idle), and verifies each move. No more mailing recommendations that nobody acts on. At
# 16:55 it mailed 6 recommendations and nothing moved. Start it in 'announce then do' mode for a day."
#
# Behind AIMAIL_BALANCE_ACT=1 (default 0: nothing here runs). Each `budget autopilot` tick:
#   1. a move IN PROGRESS (lock with a live pid) -> report, do nothing else.
#   2. an INTENT exists ->
#        cancelled (aimail budget act cancel)  -> drop it, log, done;
#        not due yet                            -> wait;
#        due: the seat is still idle/between AND placement still says OK -> EXECUTE the move through
#             the resume-by-default migrate (one seam: AIMAIL_BALANCE_MIGRATE_CMD, default the real
#             `seat_migrate`), verify by its exit, mail DONE/FAILED, log, drop the intent;
#             the seat went mid-turn -> DEFER (intent kept, next tick retries);
#             placement now refuses     -> ABANDON (intent dropped, mailed).
#   3. no intent -> look for a trigger: an account at/over AIMAIL_BALANCE_ACT_LEVEL (default 80) on
#      its block gauge, or over its fair share. Candidate = a non-pinned seat on that account, idle
#      first (activity 0, then 1; 3 = mid-turn and 9 = unknown are never candidates), whose
#      placement_pick has a target that placement_check_move accepts. Write the intent (due =
#      now + AIMAIL_BALANCE_ACT_DELAY_MIN, default 10) and ANNOUNCE it to the supervisor + human seat.
# A pinned seat is never a candidate (R1). Every step lands in state/balance/acts.log.

ACT_INTENT()  { echo "$(BALANCE_DIR)/intent"; }
ACT_CANCEL()  { echo "$(BALANCE_DIR)/intent.cancel"; }
ACT_LOCK()    { echo "$(BALANCE_DIR)/act.lock"; }
ACT_LOG()     { echo "$(BALANCE_DIR)/acts.log"; }
_act_now()    { echo "${AIMAIL_NOW:-$(now_epoch)}"; }
_act_log()    { mkdir -p "$(BALANCE_DIR)"; printf '%s\t%s\t%s\n' "$(_act_now)" "$1" "${2:-}" >> "$(ACT_LOG)"; }

# _act_block_pct <account> -> the block % from the freshest reading, or nothing
_act_block_pct() { local lc; lc="$(_last_callout "$1" 2>/dev/null || true)"; [[ -n "$lc" ]] && cut -f2 <<<"$lc"; return 0; }

# _act_triggered <account> -> prints the reason when the account needs relief, else nothing
_act_triggered() {
  local acct="$1" pct lvl="${AIMAIL_BALANCE_ACT_LEVEL:-80}" share n
  pct="$(_act_block_pct "$acct")"
  if [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= lvl )); then echo "block at ${pct}% >= ${lvl}%"; return 0; fi
  share="$(placement_fair_share)"; n="$(_pl_nonpinned_on "$acct")"
  if (( share > 0 && n > share )); then echo "over fair share ($n seats > $share)"; return 0; fi
  return 0
}

# _act_candidate <hot-account> -> "seat<TAB>target<TAB>activity" for the best move, or nothing
_act_candidate() {
  local hot="$1" seats s act best="" best_act=99 target pk
  seats="$(_pl_seats_by_account | awk -F'\t' -v a="$hot" '$1==a{print $2}')"
  local -a others=(); local a2; for a2 in $(_pl_accounts); do [[ "$a2" != "$hot" ]] && others+=("$a2"); done
  for s in $seats; do
    [[ -n "$s" ]] || continue
    _pl_is_pinned "$s" && continue
    act="$(_bal_seat_activity "$s")"; (( act <= 1 )) || continue
    (( act < best_act )) || continue
    pk="$(placement_pick "$s" "${others[@]:-}" 2>/dev/null || true)"; [[ -n "$pk" ]] || continue
    [[ "$(placement_check_move "$s" "$pk" 2>/dev/null | cut -f1)" == "OK" ]] || continue
    best="$s"; best_act="$act"; target="$pk"
  done
  [[ -n "$best" ]] && printf '%s\t%s\t%s\n' "$best" "$target" "$best_act"
  return 0
}

_act_mail() { # <subject> <body-lines...>
  local subject="$1"; shift
  # mail.sh needs registry.sh (seat_resolve) -- the cron tick sources neither; load both, loudly on failure
  command -v seat_resolve >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/registry.sh" 2>/dev/null || { _act_log MAIL-FAILED "registry.sh not loadable"; return 0; }
  command -v mail_send >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/mail.sh" 2>/dev/null || { _act_log MAIL-FAILED "mail.sh not loadable"; return 0; }
  local sup="${AIMAIL_SUPERVISOR:-assistant}" human="${AIMAIL_HUMAN_ALERT_SEAT:-}"
  local -a to=(--to "$sup"); [[ -n "$human" && "$human" != "$sup" ]] && seat_exists "$human" 2>/dev/null && to+=(--to "$human")
  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/balance_act.XXXXXX" 2>/dev/null || mktemp)"
  { printf 'from: aimail budget act (cron, announce-then-do)\n\n'; printf '%s\n' "$@"; printf '\n'
    command -v placement_report >/dev/null 2>&1 && { printf 'Placement now:\n'; placement_report 2>/dev/null | sed 's/^/  /'; printf '\n'; }
    printf 'Cancel a pending move: aimail budget act cancel --why "<reason>". Status: aimail budget act.\n'
  } > "$body"
  ( mail_send "${to[@]}" --from "$sup" --subject "$subject" --body-file "$body" ) >/dev/null 2>&1 || _act_log MAIL-FAILED "$subject"
  rm -f "$body"
}

# the real move: the resume-by-default migrate, from the supervisor, with the tool's own handover wait
_act_migrate_real() {
  source "${BASH_SOURCE[0]%/*}/seatmigrate.sh" 2>/dev/null || return 1
  seat_migrate "$1" "$2" --from "${AIMAIL_SUPERVISOR:-assistant}"
}

balance_act() {
  [[ "${AIMAIL_BALANCE_ACT:-0}" == "1" ]] || return 0
  ensure_dirs; mkdir -p "$(BALANCE_DIR)"
  local now; now="$(_act_now)"
  local lock; lock="$(ACT_LOCK)"
  if [[ -f "$lock" ]]; then
    local lpid; lpid="$(cut -f1 "$lock")"
    if [[ "$lpid" =~ ^[0-9]+$ ]] && kill -0 "$lpid" 2>/dev/null; then info "act: a move is IN PROGRESS (pid $lpid, $(cut -f2- "$lock")) -- nothing else this tick"; return 0; fi
    _act_log STALE-LOCK "$(cat "$lock")"; rm -f "$lock"
  fi
  local intent; intent="$(ACT_INTENT)"
  if [[ -s "$intent" ]]; then
    local created seat from to due reason
    IFS=$'\t' read -r created seat from to due reason < "$intent"
    if [[ -f "$(ACT_CANCEL)" ]]; then
      _act_log CANCELLED "$seat $from->$to: $(cat "$(ACT_CANCEL)")"; info "act: intent to move $seat $from->$to CANCELLED ($(cat "$(ACT_CANCEL)"))"
      rm -f "$intent" "$(ACT_CANCEL)"; return 0
    fi
    if (( now < due )); then info "act: intent to move $seat $from->$to is due at $(date -d "@$due" '+%H:%M' 2>/dev/null) ($(( (due-now+59)/60 )) min) -- waiting"; return 0; fi
    local act; act="$(_bal_seat_activity "$seat")"
    if (( act > 1 )); then _act_log DEFERRED "$seat is mid-turn (activity $act)"; info "act: $seat is mid-turn (activity $act) -- deferred, the intent stands"; return 0; fi
    local chk; chk="$(placement_check_move "$seat" "$to" 2>/dev/null || true)"
    if [[ "$(cut -f1 <<<"$chk")" != "OK" ]]; then
      _act_log ABANDONED "$seat $from->$to: ${chk#*$'\t'}"; rm -f "$intent"
      _act_mail "BALANCER: move of $seat to $to ABANDONED -- placement now refuses" "The announced move of '$seat' from '$from' to '$to' was dropped before execution:" "  ${chk#*$'\t'}" "Nothing was moved."
      return 0
    fi
    printf '%s\t%s %s->%s since %s\n' "$$" "$seat" "$from" "$to" "$(date -d "@$now" '+%H:%M' 2>/dev/null)" > "$lock"
    _act_log EXECUTING "$seat $from->$to ($reason)"; info "act: EXECUTING move of $seat $from->$to"
    local out rc=0
    out="$(${AIMAIL_BALANCE_MIGRATE_CMD:-_act_migrate_real} "$seat" "$to" 2>&1)" || rc=$?
    rm -f "$lock" "$intent"
    if (( rc == 0 )); then
      _act_log DONE "$seat $from->$to"
      _act_mail "BALANCER: moved $seat from $from to $to (announced $(date -d "@$created" '+%H:%M' 2>/dev/null), done $(date -d "@$now" '+%H:%M' 2>/dev/null))" "Executed: aimail seat migrate $seat $to (resume by default). Reason at announcement: $reason." "Migrate output (tail):" "$(tail -8 <<<"$out" | sed 's/^/  /')"
    else
      _act_log FAILED "$seat $from->$to rc=$rc"
      _act_mail "BALANCER: move of $seat to $to FAILED (rc=$rc) -- a human must look" "aimail seat migrate $seat $to returned $rc. Its own refusal text says what is and is not changed; the tool never leaves a half-moved seat unrecorded." "Output (tail):" "$(tail -12 <<<"$out" | sed 's/^/  /')"
    fi
    return 0
  fi
  # no intent: look for a trigger, then a candidate
  local acct why cand delay="${AIMAIL_BALANCE_ACT_DELAY_MIN:-10}"
  for acct in $(_pl_accounts); do
    why="$(_act_triggered "$acct")"; [[ -n "$why" ]] || continue
    cand="$(_act_candidate "$acct")"
    if [[ -z "$cand" ]]; then _act_log NO-CANDIDATE "$acct: $why (no idle non-pinned seat with an accepted target)"; info "act: $acct needs relief ($why) but no idle non-pinned seat has an accepted target"; continue; fi
    local seat target act; IFS=$'\t' read -r seat target act <<<"$cand"
    local due=$(( now + delay*60 ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$seat" "$acct" "$target" "$due" "$why" > "$intent"
    _act_log ANNOUNCED "$seat $acct->$target due $(date -d "@$due" '+%H:%M' 2>/dev/null) ($why)"
    info "act: ANNOUNCED move of $seat $acct->$target, due $(date -d "@$due" '+%H:%M' 2>/dev/null) ($why)"
    _act_mail "BALANCER WILL MOVE $seat from $acct to $target at $(date -d "@$due" '+%H:%M' 2>/dev/null) unless cancelled" \
      "Trigger: $acct -- $why." "Candidate: '$seat' (activity $act: 0 idle / 1 between turns), target '$target' by placement (R1-R5)." \
      "The move runs on the first autopilot tick after $(date -d "@$due" '+%H:%M' 2>/dev/null) if the seat is still idle and placement still agrees: aimail seat migrate $seat $target (resume by default, transcript carried)."
    return 0   # one announcement per tick
  done
  return 0
}

budget_act() {
  local sub="${1:-status}"; shift || true
  case "$sub" in
    tick) balance_act ;;
    cancel)
      local why=""; while (( $# )); do case "$1" in --why) why="${2:-}"; shift 2 ;; *) shift ;; esac; done
      [[ -n "$why" ]] || refused "budget act cancel: --why <reason> is mandatory (it is logged beside the cancelled intent)"
      [[ -s "$(ACT_INTENT)" ]] || { info "act: no pending intent to cancel"; return 0; }
      mkdir -p "$(BALANCE_DIR)"; printf '%s\n' "$why" > "$(ACT_CANCEL)"; info "act: cancel recorded -- the next tick drops the intent ($(cut -f2-4 "$(ACT_INTENT)" | tr '\t' ' '))" ;;
    status|"")
      info "budget act -- AIMAIL_BALANCE_ACT=${AIMAIL_BALANCE_ACT:-0} (1 = announce-then-do), level ${AIMAIL_BALANCE_ACT_LEVEL:-80}%, delay ${AIMAIL_BALANCE_ACT_DELAY_MIN:-10} min"
      if [[ -s "$(ACT_INTENT)" ]]; then local c s f t d r; IFS=$'\t' read -r c s f t d r < "$(ACT_INTENT)"; printf '  INTENT: move %s %s->%s, due %s (%s)%s\n' "$s" "$f" "$t" "$(date -d "@$d" '+%F %H:%M' 2>/dev/null)" "$r" "$([[ -f "$(ACT_CANCEL)" ]] && echo ' -- CANCEL PENDING')"; else echo "  no pending intent"; fi
      [[ -f "$(ACT_LOCK)" ]] && printf '  LOCK: %s\n' "$(cat "$(ACT_LOCK)")"
      if [[ -s "$(ACT_LOG)" ]]; then echo "  last acts:"; tail -6 "$(ACT_LOG)" | while IFS=$'\t' read -r e k d; do printf '    %s  %-13s %s\n' "$(date -d "@$e" '+%m-%d %H:%M' 2>/dev/null)" "$k" "$d"; done; fi ;;
    *) refused "budget act: unknown subcommand '$sub' (status | cancel --why <r> | tick)" ;;
  esac
}
