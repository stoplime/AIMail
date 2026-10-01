#!/usr/bin/env bash
# lib/warnings.sh — the 50% / 80% crossing warnings, per account, on THREE gauges
#   (the 5-hour block, the weekly, the Fable-model weekly), plus a PROJECTED warning when the current
#   burn reaches the block cap before the block resets. the owner 2026-09-22 17:03 (via assistant):
#   "at the 50%/80% crossings ... no more mailing recommendations that nobody acts on" — the
#   balancer action (lib/act.sh, announce-then-do) hangs off the same crossing events; this file emits them and records them.
#
# One warning per (account, gauge, level, window). A window is the gauge's own reset epoch (block:
# the ledger row's reset column; weekly/fable: the weekly file's reset column) — the same reading
# crossing 50 twice in one window mails ONCE; the next window mails again. One marker file per
# (account, gauge, level) under state/warnings/ RECORDS the window it last armed for; a rerun of
# the probe is idempotent by comparing the current window against that recorded value within a
# tolerance (see _warn_is_same_window), not by encoding the window in the marker's path — a fixed
# quantization of the path was tried and abandoned (2026-09-24) because the reset epoch a reading
# carries can jitter by a second or two between consecutive probes of the same real window, and
# any FIXED grid still has boundary points a jittered pair can straddle. Levels are configurable
# (AIMAIL_WARN_LEVELS, default "50 80"); the mail goes to the supervisor and the human seat; a
# marker is written whether or not the mail succeeded (a failed mail is logged, not retried into a storm).
#
# Readers, not writers: this file reads the ledgers the probe already writes (_last_callout,
# _last_weekly, _last_fable_weekly) and the placement helpers (R5 projection). It never probes.

WARN_DIR() { echo "$STATE_DIR/warnings"; }
_warn_log() { mkdir -p "$(WARN_DIR)"; printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "${2:-}" >> "$(WARN_DIR)/warnings.log"; }
warn_levels() { echo "${AIMAIL_WARN_LEVELS:-50 80}"; }

# _warn_gauges <account> — one line per gauge: gauge<TAB>pct<TAB>window<TAB>cap
#   window = reset epoch when the reading carries one, else "nowindow"; unmeasured gauges are skipped.
_warn_gauges() {
  local acct="$1" lc wl fw pct win
  lc="$(_last_callout "$acct" 2>/dev/null || true)"
  if [[ -n "$lc" ]]; then pct="$(cut -f2 <<<"$lc")"; win="$(cut -f3 <<<"$lc")"
    [[ "$pct" =~ ^[0-9]+$ ]] && printf 'block\t%s\t%s\t%s\n' "$pct" "${win:-nowindow}" "$(account_cap "$acct")"; fi
  wl="$(_last_weekly "$acct" 2>/dev/null || true)"
  if [[ -n "$wl" ]]; then pct="$(cut -f2 <<<"$wl")"; win="$(cut -f3 <<<"$wl")"
    [[ "$pct" =~ ^[0-9]+$ ]] && printf 'weekly\t%s\t%s\t%s\n' "$pct" "${win:-nowindow}" "$(weekly_cap "$acct")"; fi
  fw="$(_last_fable_weekly "$acct" 2>/dev/null || true)"
  if [[ -n "$fw" ]]; then pct="$(cut -f2 <<<"$fw")"; win="$(cut -f3 <<<"$fw")"
    [[ "$pct" =~ ^[0-9]+$ ]] && printf 'fable\t%s\t%s\t100\n' "$pct" "${win:-nowindow}"; fi
}

# ⛔⛔ FIXED-GRID ROUNDING DOESN'T WORK HERE (2026-09-24, code-review's own catch): an
#   earlier version of this fix floor-rounded the window to a 60s grid before using it as
#   part of the dedupe key. That fails at grid BOUNDARIES by construction -- the live
#   incident's own two values (1790295600, 1790295599) straddle exactly such a boundary:
#   1790295600 is itself an exact multiple of 60 and floors to itself, while 1790295599,
#   one second earlier, floors into the PREVIOUS bucket -- so the "fix" would not have
#   deduped the very incident it cites. No fixed grid size closes this: jitter direction
#   and magnitude relative to a grid's boundary points isn't controlled by the grid's
#   width, only by luck.
#
# _warn_marker no longer encodes the window in the marker's PATH at all -- the marker is
# now one persistent file per (account, gauge, level), and its own CONTENT records the
# window it was last armed for. Whether a new reading counts as "the same window" is a
# direct comparison against that recorded value (_warn_is_same_window), never a
# quantization of either value alone.
_warn_marker() {
  echo "$(WARN_DIR)/${1//[^a-zA-Z0-9_]/_}_${2}_${3}"
}

# _warn_is_same_window <marker_file> <current_window> — true (rc 0) when <marker_file>
# exists and its recorded window (3rd TSV field) is the SAME window as <current_window>:
# for two numeric epochs, "same" means within AIMAIL_WARN_WINDOW_TOLERANCE_S (default
# 60s) of each other -- absorbs the reset-epoch jitter directly, with no grid to
# straddle, by comparing against the actual last-recorded value rather than quantizing
# either side. A non-numeric window (e.g. "nowindow") falls back to exact string
# equality, unchanged from the original per-window-in-filename behavior for that case.
# No marker, or a marker with nothing recorded in that field, is never "the same".
_warn_is_same_window() {
  local mk="$1" cur="$2" tol="${AIMAIL_WARN_WINDOW_TOLERANCE_S:-60}"
  [[ -f "$mk" ]] || return 1
  local rec; rec="$(cut -f3 "$mk" 2>/dev/null)"
  [[ -n "$rec" ]] || return 1
  if [[ "$rec" =~ ^[0-9]+$ && "$cur" =~ ^[0-9]+$ ]]; then
    local d=$(( rec > cur ? rec - cur : cur - rec ))
    (( d <= tol ))
    return $?
  fi
  [[ "$rec" == "$cur" ]]
}

# _warn_projected <account> — "minutes" when the block cap is projected to be hit BEFORE the block
#   resets at the current burn (R5), else nothing. Needs a reset epoch on the block reading.
_warn_projected() {
  local acct="$1" lc reset now mins
  command -v _pl_minutes_to_cap >/dev/null 2>&1 || return 0
  lc="$(_last_callout "$acct" 2>/dev/null || true)"; [[ -n "$lc" ]] || return 0
  reset="$(cut -f3 <<<"$lc")"; [[ "$reset" =~ ^[0-9]+$ ]] || return 0
  now="${AIMAIL_NOW:-$(now_epoch)}"; mins="$(_pl_minutes_to_cap "$acct")"
  [[ "$mins" =~ ^[0-9]+$ ]] || return 0
  (( mins < 99999 )) || return 0
  (( now + mins*60 < reset )) && echo "$mins"
  return 0
}

# _warn_projected_weekly <account> — "<hours_to_cap> <days_before_reset> <rate>" when the WEEKLY cap is
#   projected to be hit BEFORE the weekly reset at the current rate, else nothing. Rate = points per
#   hour from the two most recent weekly ledger rows; reset from the weekly reading's own 3rd column.
#   The case that asked for it (2026-09-22 23:09): an account at 84% weekly rising ~1.2 pt/h with a
#   98 cap caps in ~11 h, days before its reset -- the free reset is the cheapest headroom there is,
#   so the warning says so instead of only reporting the crossing.
_warn_projected_weekly() {
  local acct="$1" wl pct reset now cap rate hours left_h
  wl="$(_last_weekly "$acct" 2>/dev/null || true)"; [[ -n "$wl" ]] || return 0
  pct="$(cut -f2 <<<"$wl")"; reset="$(cut -f3 <<<"$wl")"
  [[ "$pct" =~ ^[0-9]+$ && "$reset" =~ ^[0-9]+$ ]] || return 0
  [[ -s "$LEDGER" ]] || return 0
  # ⛔ RATE OVER A REAL BASELINE, never the two newest rows. Percent is stored as an integer and probes
  #   are 5 minutes apart, so two adjacent rows one point apart read 12 pt/h (live cron, 02:00: work
  #   86->87 in 300 s -> "caps in ~0 h"; the true rate was ~1.2 pt/h). The rate is (newest - oldest
  #   row within the last AIMAIL_WEEKLY_RATE_WINDOW_H hours) / span, and it counts only when the span
  #   is >= AIMAIL_WEEKLY_RATE_MIN_SPAN_S and the movement >= AIMAIL_WEEKLY_RATE_MIN_PTS. Anything
  #   shorter is quantization noise, and no projection is made from it.
  now="${AIMAIL_NOW:-$(now_epoch)}"
  rate="$(awk -F'\t' -v a="$acct" -v now="$now" -v win="$(( ${AIMAIL_WEEKLY_RATE_WINDOW_H:-6} * 3600 ))" \
       -v minspan="${AIMAIL_WEEKLY_RATE_MIN_SPAN_S:-3600}" -v minpts="${AIMAIL_WEEKLY_RATE_MIN_PTS:-2}" '
    $2==a && $4=="weekly" && $1>=now-win { if(e0=="" || $1<e0) {e0=$1;p0=$3} if(e1=="" || $1>e1) {e1=$1;p1=$3} }
    END{ if(e0=="" || e1-e0<minspan || p1-p0<minpts) {print 0; exit} printf "%.3f", (p1-p0)/((e1-e0)/3600) }' "$LEDGER")"
  awk -v r="$rate" 'BEGIN{exit !(r>0)}' || return 0
  cap="$(weekly_cap "$acct")"
  (( cap > pct )) || return 0
  hours="$(awk -v c="$cap" -v p="$pct" -v r="$rate" 'BEGIN{printf "%d", (c-p)/r}')"
  left_h=$(( (reset - now) / 3600 ))
  (( hours < left_h )) || return 0
  printf '%s %s %s\n' "$hours" "$(( (left_h - hours) / 24 ))" "$rate"
  return 0
}

# budget_warnings [--dry-run] — evaluate every account, emit each NEW crossing once, print a table.
#   Exit 0 always (a cron tick). Lines: account gauge pct level window state(NEW|SEEN|-)
budget_warnings() {
  local dry=0; [[ "${1:-}" == "--dry-run" ]] && dry=1
  ensure_dirs; mkdir -p "$(WARN_DIR)"
  local -a accts=(); read -r -a accts <<< "${AIMAIL_FLEET_ACCOUNTS:-$(account_id)}"
  local acct gauge pct win cap lvl mk state proj n_new=0
  local -a new_lines=()
  printf '%-10s %-7s %-4s %-5s %-11s %s\n' ACCOUNT GAUGE PCT LEVEL WINDOW STATE
  for acct in "${accts[@]}"; do
    [[ -n "$acct" ]] || continue
    while IFS=$'\t' read -r gauge pct win cap; do
      [[ -n "$gauge" ]] || continue
      local top="-"
      for lvl in $(warn_levels); do
        (( pct >= lvl )) || continue
        top="$lvl"; mk="$(_warn_marker "$acct" "$gauge" "$lvl")"
        if _warn_is_same_window "$mk" "$win"; then state=SEEN; else
          state=NEW; n_new=$((n_new+1)); new_lines+=("$acct $gauge at ${pct}% crossed ${lvl}% (cap ${cap}%, window ${win})")
          (( dry )) || printf '%s\t%s\t%s\n' "$(date +%s)" "$pct" "$win" > "$mk"
        fi
        printf '%-10s %-7s %-4s %-5s %-11s %s\n' "$acct" "$gauge" "$pct" "$lvl" "${win:0:11}" "$state"
      done
      [[ "$top" == "-" ]] && printf '%-10s %-7s %-4s %-5s %-11s %s\n' "$acct" "$gauge" "$pct" "-" "${win:0:11}" "-"
    done < <(_warn_gauges "$acct")
    local wproj; wproj="$(_warn_projected_weekly "$acct")"
    if [[ -n "$wproj" ]]; then
      local wh wd wr; read -r wh wd wr <<<"$wproj"
      win="$(_last_weekly "$acct" 2>/dev/null | cut -f3)"; mk="$(_warn_marker "$acct" wprojected cap)"
      if _warn_is_same_window "$mk" "$win"; then state=SEEN; else
        state=NEW; n_new=$((n_new+1)); new_lines+=("$acct weekly PROJECTED to hit its weekly cap in ~${wh} h, about ${wd} day(s) BEFORE its reset (${wr} pt/h) -- consider the account's free reset: whatever it does not burn before then expires unused")
        (( dry )) || printf '%s\t%s\t%s\n' "$(date +%s)" "$wh" "$win" > "$mk"
      fi
      printf '%-10s %-7s %-4s %-5s %-11s %s\n' "$acct" wproj "~${wh}h" cap "${win:0:11}" "$state"
    fi
    proj="$(_warn_projected "$acct")"
    if [[ -n "$proj" ]]; then
      win="$(_last_callout "$acct" 2>/dev/null | cut -f3)"; mk="$(_warn_marker "$acct" projected cap)"
      if _warn_is_same_window "$mk" "$win"; then state=SEEN; else
        state=NEW; n_new=$((n_new+1)); new_lines+=("$acct PROJECTED to hit its block cap in ~${proj} min, BEFORE the block resets (window ${win})")
        (( dry )) || printf '%s\t%s\t%s\n' "$(date +%s)" "$proj" "$win" > "$mk"
      fi
      printf '%-10s %-7s %-4s %-5s %-11s %s\n' "$acct" projected "~${proj}m" cap "${win:0:11}" "$state"
    fi
  done
  (( n_new > 0 )) || return 0
  printf '%s\t%s\n' "$(date +%s)" "$(printf '%s; ' "${new_lines[@]}")" >> "$(WARN_DIR)/warnings.log"
  (( dry )) && { printf 'dry-run: %s new crossing(s), nothing mailed, no markers written\n' "$n_new"; return 0; }
  _warn_mail "${new_lines[@]}"
  return 0
}

_warn_mail() {
  # mail.sh needs registry.sh (seat_resolve) -- the cron tick sources neither; load both, loudly on failure
  command -v seat_resolve >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/registry.sh" 2>/dev/null || { _warn_log MAIL-FAILED "registry.sh not loadable"; return 0; }
  command -v mail_send >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/mail.sh" 2>/dev/null || { _warn_log MAIL-FAILED "mail.sh not loadable"; return 0; }
  local sup="${AIMAIL_SUPERVISOR:-assistant}" human="${AIMAIL_HUMAN_ALERT_SEAT:-}"
  local -a to=(--to "$sup"); [[ -n "$human" && "$human" != "$sup" ]] && seat_exists "$human" 2>/dev/null && to+=(--to "$human")
  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/budget_warning.XXXXXX" 2>/dev/null || mktemp)"
  { printf 'from: aimail budget warnings (cron)\n\nBUDGET CROSSING -- %s\n\n' "$(date '+%F %H:%M')"
    printf '%s\n' "$@"; printf '\n'
    if command -v placement_report >/dev/null 2>&1; then printf 'Placement now:\n'; placement_report 2>/dev/null | sed 's/^/  /'; printf '\n'; fi
    printf 'One mail per (account, gauge, level, window). aimail budget warnings prints the live table; aimail placement <seat> the target for a move.\n'
  } > "$body"
  local mrc=0
  ( mail_send "${to[@]}" --from "$sup" --subject "BUDGET CROSSING: $1" --body-file "$body" ) >/dev/null 2>&1 || mrc=$?
  (( mrc == 0 )) || printf '%s\tMAIL-FAILED rc=%s\t%s\n' "$(date +%s)" "$mrc" "recipients: ${to[*]}" >> "$(WARN_DIR)/warnings.log"
  rm -f "$body"
}
