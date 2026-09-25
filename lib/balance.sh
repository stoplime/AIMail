# shellcheck shell=bash
# balance.sh — proactive, gradual multi-account load balancing. FIRST CUT:
# the measurement layer and the read-only decision layer of
# docs/load_balancer_design_2026-09-21.md (§3.1–§3.4, §3.7), wired into the
# autopilot tick as READ-ONLY steps. Nothing here moves a seat, writes a
# placement marker, or mails anyone: §5 of the design says the pressure/streak
# machinery runs for a full weekly cycle and is read against what the fleet
# actually experienced before a recommendation is ever emitted. `aimail budget
# balance` prints what it WOULD recommend, so that reading is possible.
#
# ⭐ WHAT IT MEASURES
#   1. Per-seat usage ledger  state/seat_usage.tsv  (§3.1). One row per
#      (session, model) per tick, CUMULATIVE token counts from `ccusage session
#      --json` for the account dir the tick runs under. Deltas are derived at
#      read time from consecutive rows, so a missed tick loses nothing.
#      Session id → seat via the seat record, then poller instance files, then
#      stop-guard registrations; anything else is the seat `_unattributed`.
#   2. Reconciliation  state/seat_usage_status_<acct>  (§3.1 step 4): the sum
#      of every session's delta since the previous tick against the account's
#      active block total's delta over the same interval (from the cached
#      ccusage blocks JSON). Within AIMAIL_SEAT_USAGE_TOLERANCE (default 15%)
#      the tick is MEASURED; otherwise UNMEASURED and the balancer treats that
#      account's per-seat costs as unknown. Zero is never substituted.
#   3. Cost unit: weighted tokens (§3.1) — input 1.0, output 5.0, cache
#      creation 1.25, cache read 0.1 by default; AIMAIL_TOKEN_WEIGHTS="i o cc cr"
#      overrides all four. Dollars are carried for reporting only.
#   4. Account pressure (§3.2): burn (least-squares slope of the ledger's
#      weekly % over AIMAIL_BALANCE_WINDOW_H hours, ≥ AIMAIL_BALANCE_MIN_READINGS
#      readings) divided by sustainable (weekly headroom over hours to the
#      reset). Same for the 5-hour block. Parked = INF. Missing = UNMEASURED.
#   5. Streak (§3.3): arm when gap ≥ GAP_ON and hot ≥ 1.10 for K consecutive
#      evaluations; clear below GAP_OFF for K. state/balance/streak is the
#      audit trail, one line per evaluation. Missing readings count for
#      neither direction.
#   6. Candidate (§3.4): idlest first, then the smallest cost that narrows the
#      gap without flipping it; supervisor and claim-holders excluded.
#      PRINTED ONLY in this cut.
#
# TEST SEAMS: AIMAIL_CCUSAGE_SESSION_JSON (a file standing in for the CLI's
# output), AIMAIL_BALANCE_LIVE_STATE (whitespace list "seat=idle|working|mid" to
# stand in for the listing/claims read), AIMAIL_NOW (epoch override), plus
# budget.sh's own AIMAIL_ACCOUNT_DIR_<acct> / AIMAIL_FLEET_ACCOUNTS / caps.

SEAT_USAGE_LEDGER()      { echo "$STATE_DIR/seat_usage.tsv"; }
SEAT_USAGE_STATUS_FILE() { echo "$STATE_DIR/seat_usage_status_${1//[^a-zA-Z0-9_]/_}"; }
BALANCE_DIR()            { echo "$STATE_DIR/balance"; }
BALANCE_STREAK_FILE()    { echo "$(BALANCE_DIR)/streak"; }

_bal_now() { echo "${AIMAIL_NOW:-$(now_epoch)}"; }

# ─── §3.1 per-seat usage ledger ──────────────────────────────────────────────

# _bal_sid_to_seat <sid> — seat record, instance file, stop-guard registration, or ""
_bal_sid_to_seat() {
  local sid="$1" f seat
  local rdir="$STATE_DIR/seat_account"
  if [[ -d "$rdir" ]]; then
    for f in "$rdir"/*; do
      [[ -f "$f" ]] || continue
      if [[ "$(awk -F'\t' '$1=="session_id"{print $2}' "$f")" == "$sid" ]]; then basename "$f"; return 0; fi
    done
  fi
  local idir="$STATE_DIR/instances"
  if [[ -d "$idir" ]]; then
    for f in "$idir"/*/"$sid"; do [[ -f "$f" ]] && { basename "$(dirname "$f")"; return 0; }; done
  fi
  f="$STATE_DIR/stopguard/session.$sid"
  if [[ -f "$f" ]]; then
    seat="$(head -1 "$f" | tr -d '[:space:]')"
    [[ -n "$seat" ]] && { echo "$seat"; return 0; }
  fi
  return 1
}

# _bal_ccusage_session_json — the CLI's per-session JSON for the ambient account dir, or fail
_bal_ccusage_session_json() {
  if [[ -n "${AIMAIL_CCUSAGE_SESSION_JSON:-}" ]]; then
    [[ -f "$AIMAIL_CCUSAGE_SESSION_JSON" ]] && cat "$AIMAIL_CCUSAGE_SESSION_JSON"; return
  fi
  [[ "${AIMAIL_NO_NETWORK:-}" == "1" ]] && return 1
  # the same resolver budget.sh's block_json uses (core.sh ccusage_cmd): AIMAIL_CCUSAGE_BIN, then
  # the PATH install, then npx -- one decision, two callers
  local -a cc=(); read -r -a cc <<<"$(ccusage_cmd 2>/dev/null || true)"; (( ${#cc[@]} )) || return 1
  timeout "${AIMAIL_CCUSAGE_TIMEOUT_SEC:-120}" "${cc[@]}" session --json 2>/dev/null
}

# seat_usage_tick [account] — append this tick's cumulative rows and reconcile.
# Prints one summary line; exit 0 always unless the CLI did not answer (exit 4).
seat_usage_tick() {
  local acct="${1:-$(account_id)}" now; now="$(_bal_now)"
  local json; json="$(_bal_ccusage_session_json)" || { warn "seat usage: ccusage did not answer for '$acct' — no rows this tick"; return 4; }
  [[ -n "$json" ]] || { warn "seat usage: empty ccusage output for '$acct'"; return 4; }
  ensure_dirs
  local ledger; ledger="$(SEAT_USAGE_LEDGER)"
  [[ -f "$ledger" ]] || printf '# epoch\taccount\tseat\tsid\tmodel\tcum_input\tcum_output\tcum_cache_create\tcum_cache_read\tcum_cost\n' > "$ledger"
  # rows: sid \t model \t in \t out \t cc \t cr \t cost   (one per model + one "all")
  local rows; rows="$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = d.get("session") if isinstance(d, dict) else d
if isinstance(rows, dict): rows = rows.get("sessions", [])
for r in rows or []:
    sid = r.get("period") or r.get("sessionId") or ""
    if not sid: continue
    print("\t".join([sid, "all", str(r.get("inputTokens", 0)), str(r.get("outputTokens", 0)),
                     str(r.get("cacheCreationTokens", 0)), str(r.get("cacheReadTokens", 0)), str(r.get("totalCost", 0))]))
    for m in r.get("modelBreakdowns") or []:
        print("\t".join([sid, m.get("modelName", "?"), str(m.get("inputTokens", 0)), str(m.get("outputTokens", 0)),
                         str(m.get("cacheCreationTokens", 0)), str(m.get("cacheReadTokens", 0)), str(m.get("cost", 0))]))
' 2>/dev/null)" || { warn "seat usage: ccusage output for '$acct' did not parse"; return 4; }
  local n=0 sid model i o cc cr cost seat
  local tmp; tmp="$(mktemp "$STATE_DIR/.seat_usage.XXXXXX")"
  while IFS=$'\t' read -r sid model i o cc cr cost; do
    [[ -n "$sid" ]] || continue
    seat="$(_bal_sid_to_seat "$sid" 2>/dev/null || echo _unattributed)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$acct" "$seat" "$sid" "$model" "$i" "$o" "$cc" "$cr" "$cost" >> "$tmp"
    n=$((n+1))
  done <<<"$rows"
  cat "$tmp" >> "$ledger"; rm -f "$tmp"
  _bal_reconcile "$acct" "$now"
  info "seat usage: $acct — $n rows appended, $(awk -F'\t' '$1=="verdict"{print $2}' "$(SEAT_USAGE_STATUS_FILE "$acct")" 2>/dev/null || echo UNMEASURED)"
}

# _bal_block_total <acct> — the active block's totalTokens from the cached ccusage blocks JSON, or ""
_bal_block_total() {
  local cache="$STATE_DIR/block.${1//[^a-zA-Z0-9_]/_}.json"
  [[ -f "$cache" ]] || return 1
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
act = [b for b in d.get("blocks", []) if b.get("isActive")]
b = act[0] if act else None
print(b.get("totalTokens", "") if b else "")
' "$cache" 2>/dev/null
}

# _bal_reconcile <acct> <now> — write state/seat_usage_status_<acct>
_bal_reconcile() {
  local acct="$1" now="$2" status; status="$(SEAT_USAGE_STATUS_FILE "$acct")"
  local prev_epoch prev_block prev_seats
  prev_epoch="$(awk -F'\t' '$1=="epoch"{print $2}' "$status" 2>/dev/null || echo '')"
  prev_block="$(awk -F'\t' '$1=="block_total"{print $2}' "$status" 2>/dev/null || echo '')"
  local block_total; block_total="$(_bal_block_total "$acct" 2>/dev/null || echo '')"
  # seats' raw-token total (all models, "all" rows) at this tick and at the previous tick
  local ledger; ledger="$(SEAT_USAGE_LEDGER)"
  local seats_now seats_prev
  seats_now="$(awk -F'\t' -v a="$acct" -v t="$now" '$2==a && $5=="all" && $1==t {s+=$6+$7+$8+$9} END{printf "%.0f", s}' "$ledger")"
  seats_prev="$(awk -F'\t' -v a="$acct" -v t="${prev_epoch:-x}" '$2==a && $5=="all" && $1==t {s+=$6+$7+$8+$9} END{printf "%.0f", s}' "$ledger")"
  local verdict="UNMEASURED" detail="first tick, or no block reading" block_delta="" seats_delta="" ratio=""
  if [[ -n "$prev_epoch" && -n "$prev_block" && -n "$block_total" && "$prev_block" =~ ^[0-9]+$ && "$block_total" =~ ^[0-9]+$ ]]; then
    block_delta=$(( block_total - prev_block )); seats_delta=$(( seats_now - seats_prev ))
    if (( block_delta < 0 )); then
      verdict="UNMEASURED"; detail="block rolled over between ticks (delta $block_delta) — next tick re-baselines"
    elif (( block_delta == 0 && seats_delta == 0 )); then
      verdict="MEASURED"; detail="idle interval, both deltas 0"; ratio="1.00"
    elif (( block_delta == 0 )); then
      verdict="UNMEASURED"; detail="seats moved $seats_delta tokens, block moved 0 — block cache stale?"
    else
      ratio="$(awk -v s="$seats_delta" -v b="$block_delta" 'BEGIN{printf "%.3f", s/b}')"
      local tol="${AIMAIL_SEAT_USAGE_TOLERANCE:-15}"
      if awk -v r="$ratio" -v t="$tol" 'BEGIN{exit !( (r-1)*100 <= t && (1-r)*100 <= t )}'; then
        verdict="MEASURED"; detail="seats/block = $ratio within ${tol}%"
      else
        verdict="UNMEASURED"; detail="seats/block = $ratio outside ${tol}% — attribution or block source disagree"
      fi
    fi
  fi
  { printf 'epoch\t%s\n' "$now"
    printf 'account\t%s\n' "$acct"
    printf 'block_total\t%s\n' "${block_total:-}"
    printf 'seats_total\t%s\n' "$seats_now"
    printf 'block_delta\t%s\n' "${block_delta:-}"
    printf 'seats_delta\t%s\n' "${seats_delta:-}"
    printf 'ratio\t%s\n' "${ratio:-}"
    printf 'verdict\t%s\n' "$verdict"
    printf 'detail\t%s\n' "$detail"
  } | atomic_write "$status"
}

# _bal_weights — "i o cc cr"
_bal_weights() { echo "${AIMAIL_TOKEN_WEIGHTS:-1.0 5.0 1.25 0.1}"; }

# seat_costs <acct> <window_h> — TSV: seat \t weighted_cost \t raw_tokens \t cost_usd \t model \t last_seen
# (weighted delta over the window, from the earliest row at/after window start to the latest,
#  per (sid, model) — a session that first appears inside the window counts from its first row)
seat_costs() {
  local acct="$1" win_h="${2:-3}" now; now="$(_bal_now)"
  local since=$(( now - win_h * 3600 ))
  local w; read -r wi wo wcc wcr <<<"$(_bal_weights)"
  awk -F'\t' -v a="$acct" -v since="$since" -v wi="$wi" -v wo="$wo" -v wcc="$wcc" -v wcr="$wcr" '
    $1 ~ /^#/ {next}
    $2!=a || $5=="all" {next}
    $1 < since {next}
    { k=$4 SUBSEP $5
      if (!(k in first)) { first[k]=$1; fi[k]=$6; fo[k]=$7; fcc[k]=$8; fcr[k]=$9; fcost[k]=$10; seat[k]=$3 }
      if ($1 >= last[k]) { last[k]=$1; li[k]=$6; lo[k]=$7; lcc[k]=$8; lcr[k]=$9; lcost[k]=$10 }
    }
    END {
      for (k in first) {
        di=li[k]-fi[k]; do_=lo[k]-fo[k]; dcc=lcc[k]-fcc[k]; dcr=lcr[k]-fcr[k]; dc=lcost[k]-fcost[k]
        if (di<0||do_<0||dcc<0||dcr<0) continue
        wt=di*wi+do_*wo+dcc*wcc+dcr*wcr; raw=di+do_+dcc+dcr
        split(k, p, SUBSEP); s=seat[k]; m=p[2]
        W[s]+=wt; R[s]+=raw; C[s]+=dc; if (wt>=BM[s]) { BM[s]=wt; M[s]=m } if (last[k]>L[s]) L[s]=last[k]
      }
      for (s in W) printf "%s\t%.0f\t%.0f\t%.4f\t%s\t%s\n", s, W[s], R[s], C[s], M[s], L[s]
    }' "$(SEAT_USAGE_LEDGER)" 2>/dev/null | sort -t$'\t' -k2,2nr
}

budget_seats() {
  local win_h="${AIMAIL_BALANCE_WINDOW_H:-3}" acct
  while (( $# )); do case "$1" in --window) win_h="${2%h}"; shift 2 ;; *) shift ;; esac; done
  [[ -f "$(SEAT_USAGE_LEDGER)" ]] || { info "no per-seat usage recorded yet (state/seat_usage.tsv) — the autopilot tick writes it; or run: aimail budget seats-tick"; return 0; }
  local -a accts=(); read -r -a accts <<< "${AIMAIL_FLEET_ACCOUNTS:-$(account_id)}"
  for acct in "${accts[@]}"; do
    [[ -n "$acct" ]] || continue
    local st; st="$(SEAT_USAGE_STATUS_FILE "$acct")"
    printf '\n%s — per-seat weighted cost, trailing %sh   [reconciliation: %s — %s]\n' "$acct" "$win_h" \
      "$(awk -F'\t' '$1=="verdict"{print $2}' "$st" 2>/dev/null || echo UNMEASURED)" \
      "$(awk -F'\t' '$1=="detail"{print $2}' "$st" 2>/dev/null || echo 'no tick yet')"
    printf '  %-16s %14s %14s %10s  %-24s %s\n' SEAT WEIGHTED RAW USD MODEL LAST
    local total; total="$(seat_costs "$acct" "$win_h" | awk -F'\t' '{s+=$2} END{printf "%.0f", s}')"
    seat_costs "$acct" "$win_h" | while IFS=$'\t' read -r s wt raw usd m last; do
      local share="-"; [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )) && share="$(awk -v w="$wt" -v t="$total" 'BEGIN{printf "%d%%", w*100/t}')"
      printf '  %-16s %14s %14s %10s  %-24s %s  %s\n' "$s" "$wt" "$raw" "$usd" "$m" "$(date -d "@$last" '+%H:%M' 2>/dev/null || echo '?')" "$share"
    done
  done
  echo
  info "weights (input output cache_create cache_read): $(_bal_weights) — AIMAIL_TOKEN_WEIGHTS overrides"
}

# ─── §3.2 pressure ───────────────────────────────────────────────────────────

# _bal_slope_per_hour <acct> <source> <window_s> <min_readings> — least-squares slope of pct/hour
# over the ledger rows of that source within the window; only the segment after the LAST reset
# inside the window counts. Prints "slope\tn\tlast_pct\tlast_reset_epoch" or exit 1 (UNMEASURED).
_bal_slope_per_hour() {
  local acct="$1" src="$2" win="$3" minn="$4" now; now="$(_bal_now)"
  [[ -s "$LEDGER" ]] || return 1
  awk -F'\t' -v a="$acct" -v s="$src" -v since="$(( now - win ))" -v minn="$minn" '
    $2==a && $4==s && $1>=since { n++; t[n]=$1; p[n]=$3; r[n]=$5 }
    END {
      if (n==0) exit 1
      # split at a reset: a drop of more than 30 points between consecutive readings
      start=1
      for (i=2;i<=n;i++) if (p[i] < p[i-1]-30) start=i
      m=0; for (i=start;i<=n;i++) { m++; x[m]=t[i]/3600.0; y[m]=p[i] }
      if (m < minn) exit 1
      sx=0; sy=0; sxx=0; sxy=0
      for (i=1;i<=m;i++) { sx+=x[i]; sy+=y[i]; sxx+=x[i]*x[i]; sxy+=x[i]*y[i] }
      den = m*sxx - sx*sx
      if (den==0) exit 1
      slope = (m*sxy - sx*sy)/den
      printf "%.4f|%d|%s|%s\n", slope, m, p[n], r[n]
    }' "$LEDGER"
}

# balance_pressure <acct> — 'pressure_w|pressure_s|detail' ('|'-separated: empty fields must survive the read)   (INF when parked; "" = UNMEASURED)
balance_pressure() {
  local acct="$1" now; now="$(_bal_now)"
  if [[ -f "$(THROTTLE_FLAG "$acct")" ]]; then printf 'INF|INF|parked\n'; return 0; fi
  local win_h="${AIMAIL_BALANCE_WINDOW_H:-3}" minn="${AIMAIL_BALANCE_MIN_READINGS:-6}"
  local pw="" ps="" det=""
  local r; if r="$(_bal_slope_per_hour "$acct" weekly $(( win_h*3600 )) "$minn")"; then
    local slope n last reset; IFS='|' read -r slope n last reset <<<"$r"
    local wcap; wcap="$(weekly_cap "$acct")"
    if [[ "$reset" =~ ^[0-9]+$ ]] && (( reset > now )); then
      local hours; hours="$(awk -v r="$reset" -v n="$now" 'BEGIN{printf "%.3f", (r-n)/3600.0}')"
      pw="$(awk -v s="$slope" -v cap="$wcap" -v last="$last" -v h="$hours" 'BEGIN{ head=cap-last; if (head<=0) {print "INF"; exit} sus=head/h; if (sus<=0) {print "INF"; exit} if (s<=0) {printf "0.00"; exit} printf "%.2f", s/sus }')"
      det="weekly slope ${slope}%/h over $n readings, headroom $(( wcap - ${last%%.*} ))% in ${hours}h"
    else det="weekly: no reset epoch on the last reading"; fi
  else det="weekly: fewer than $minn readings in ${win_h}h"; fi
  local swin="${AIMAIL_BALANCE_SESSION_WINDOW_MIN:-60}"
  if r="$(_bal_slope_per_hour "$acct" probe $(( swin*60 )) "$minn")"; then
    local slope n last reset; IFS='|' read -r slope n last reset <<<"$r"
    local scap; scap="$(account_cap "$acct")"
    if [[ "$reset" =~ ^[0-9]+$ ]] && (( reset > now )); then
      local hours; hours="$(awk -v r="$reset" -v n="$now" 'BEGIN{printf "%.3f", (r-n)/3600.0}')"
      ps="$(awk -v s="$slope" -v cap="$scap" -v last="$last" -v h="$hours" 'BEGIN{ head=cap-last; if (head<=0) {print "INF"; exit} sus=head/h; if (sus<=0) {print "INF"; exit} if (s<=0) {printf "0.00"; exit} printf "%.2f", s/sus }')"
      det="$det; block slope ${slope}%/h over $n"
    fi
  fi
  printf '%s|%s|%s\n' "$pw" "$ps" "$det"
}

# _bal_max <a> <b> — numeric/INF max; "" if both empty
_bal_max() {
  local a="$1" b="$2"
  [[ -z "$a" && -z "$b" ]] && { echo ""; return; }
  [[ "$a" == "INF" || "$b" == "INF" ]] && { echo INF; return; }
  [[ -z "$a" ]] && { echo "$b"; return; }; [[ -z "$b" ]] && { echo "$a"; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{print (a>b)?a:b}'
}

# ─── §3.3 streak + §3.4 candidate ────────────────────────────────────────────

# _bal_seat_counts — "acct n" lines: live seats per account (from _autopilot_seat_groups), or the
# AIMAIL_BALANCE_SEATS seam ("alpha:5 beta:1").
_bal_seat_counts() {
  if [[ -n "${AIMAIL_BALANCE_SEATS:-}" ]]; then local kv; for kv in $AIMAIL_BALANCE_SEATS; do printf '%s %s\n' "${kv%%:*}" "${kv#*:}"; done; return 0; fi
  local line acct seats
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    acct="$(cut -f2 <<<"$line")"; seats="$(cut -f3 <<<"$line")"
    [[ -n "$acct" ]] && printf '%s %s\n' "$acct" "$(wc -w <<<"$seats")"
  done < <(_autopilot_seat_groups 2>/dev/null || true)
}

# _bal_skew <hot> <cold> — code-review's AND rule (2026-09-21): the account with MORE live seats
# (>= AIMAIL_BALANCE_SKEW_SEATS more, default 3) is ALSO the one reading higher weekly % by
# >= AIMAIL_BALANCE_SKEW_POINTS (default 20). Prints "1 <detail>" when it holds, "0 <detail>" otherwise.
# A seat skew alone can be a deliberate allocation; a usage skew alone can be one seat's real
# work; the pair is the signal. Debounced by the same K as the pressure path.
_bal_skew() {
  local hot="$1" cold="$2" nh nc ph pc
  nh="$(_bal_seat_counts | awk -v a="$hot" '$1==a{print $2}')"; nc="$(_bal_seat_counts | awk -v a="$cold" '$1==a{print $2}')"
  ph="$(_last_weekly "$hot" 2>/dev/null | cut -f2)"; pc="$(_last_weekly "$cold" 2>/dev/null | cut -f2)"
  [[ "$nh" =~ ^[0-9]+$ && "$nc" =~ ^[0-9]+$ && "$ph" =~ ^[0-9]+$ && "$pc" =~ ^[0-9]+$ ]] || { echo "0 skew unmeasured (seats $nh/$nc, weekly $ph/$pc)"; return 0; }
  local ds=$(( nh - nc )) dp=$(( ph - pc ))
  if (( ds >= ${AIMAIL_BALANCE_SKEW_SEATS:-3} && dp >= ${AIMAIL_BALANCE_SKEW_POINTS:-20} )); then echo "1 seats $nh vs $nc, weekly ${ph}% vs ${pc}%"; else echo "0 seats $nh vs $nc, weekly ${ph}% vs ${pc}%"; fi
}

# _bal_seat_activity <seat> — 0 idle, 1 between, 3 mid-task, 9 not a candidate
_bal_seat_activity() {
  local seat="$1"
  if [[ -n "${AIMAIL_BALANCE_LIVE_STATE:-}" ]]; then
    local kv; for kv in $AIMAIL_BALANCE_LIVE_STATE; do
      [[ "${kv%%=*}" == "$seat" ]] && case "${kv#*=}" in idle) echo 0;; between) echo 1;; mid) echo 3;; *) echo 9;; esac && return 0
    done
    echo 9; return 0
  fi
  local st; st="$(poller_state "$seat" 2>/dev/null | head -1 || echo '')"
  case "$st" in ARMED*|RE-ARMING*) ;; *) echo 9; return 0 ;; esac
  if command -v gateclaim.sh >/dev/null 2>&1 && gateclaim.sh --list 2>/dev/null | awk '{print $2}' | grep -qx "$seat"; then echo 3; return 0; fi
  # a commit or handoff mail in the last 30 min would make it "mid"; without that signal here, "between"
  echo 1
}

# balance_evaluate — one evaluation: pressures, hot/cold, streak update, would-recommend. Prints a report.
balance_evaluate() {
  ensure_dirs; mkdir -p "$(BALANCE_DIR)"
  local now; now="$(_bal_now)"
  local -a accts=(); read -r -a accts <<< "${AIMAIL_FLEET_ACCOUNTS:-$(account_id)}"
  local gap_on="${AIMAIL_BALANCE_GAP_ON:-0.40}" gap_off="${AIMAIL_BALANCE_GAP_OFF:-0.20}" k="${AIMAIL_BALANCE_K:-6}" hot_min="${AIMAIL_BALANCE_HOT_MIN:-1.10}"
  local acct pw ps det p hot="" cold="" hotp="" coldp="" unmeasured=""
  local -A P=()
  local -a measured=()
  for acct in "${accts[@]}"; do
    [[ -n "$acct" ]] || continue
    IFS='|' read -r pw ps det <<<"$(balance_pressure "$acct")"
    p="$(_bal_max "$pw" "$ps")"
    if [[ -z "$p" ]]; then unmeasured="${unmeasured:+$unmeasured }$acct"; P["$acct"]=""; continue; fi
    P["$acct"]="$p"; measured+=("$acct")
  done
  # hot = the highest pressure (INF beats all; first wins ties); cold = the lowest among the OTHER
  # measured, non-parked accounts (first wins ties) -- so two accounts at equal pressure still
  # yield a hot/cold pair with gap 0, which is how a closed gap gets counted toward CLEAR.
  for acct in "${measured[@]}"; do
    p="${P[$acct]}"
    if [[ -z "$hotp" ]]; then hot="$acct"; hotp="$p"; continue; fi
    [[ "$hotp" == "INF" ]] && continue
    if [[ "$p" == "INF" ]] || awk -v a="$p" -v b="$hotp" 'BEGIN{exit !(a>b)}'; then hot="$acct"; hotp="$p"; fi
  done
  for acct in "${measured[@]}"; do
    [[ "$acct" == "$hot" ]] && continue
    p="${P[$acct]}"; [[ "$p" == "INF" ]] && continue
    if [[ -z "$coldp" ]] || awk -v a="$p" -v b="$coldp" 'BEGIN{exit !(a<b)}'; then cold="$acct"; coldp="$p"; fi
  done
  # the cold account must be measured, not parked, and not the hot one
  local gap="" armed_prev streak_prev armed=0 streak=0
  local sf; sf="$(BALANCE_STREAK_FILE)"
  if [[ -s "$sf" ]]; then
    armed_prev="$(tail -1 "$sf" | cut -f6)"; streak_prev="$(tail -1 "$sf" | cut -f7)"
  else armed_prev=0; streak_prev=0; fi
  [[ "$armed_prev" =~ ^[01]$ ]] || armed_prev=0; [[ "$streak_prev" =~ ^[0-9]+$ ]] || streak_prev=0
  local verdict="UNMEASURED" reason=""
  if [[ -n "$hot" && -n "$cold" && "$hot" != "$cold" && -n "$hotp" && -n "$coldp" ]]; then
    if [[ "$hotp" == "INF" ]]; then gap="INF"; else gap="$(awk -v a="$hotp" -v b="$coldp" 'BEGIN{printf "%.2f", a-b}')"; fi
    local over_on over_off hot_ok
    if [[ "$gap" == "INF" ]]; then over_on=1; over_off=1; hot_ok=1; else
      over_on="$(awk -v g="$gap" -v t="$gap_on" 'BEGIN{print (g>=t)?1:0}')"
      over_off="$(awk -v g="$gap" -v t="$gap_off" 'BEGIN{print (g>=t)?1:0}')"
      hot_ok="$(awk -v h="$hotp" -v t="$hot_min" 'BEGIN{print (h>=t)?1:0}')"
    fi
    local skew skew_on skew_det; skew="$(_bal_skew "$hot" "$cold")"; skew_on="${skew%% *}"; skew_det="${skew#* }"
    if (( armed_prev == 0 )); then
      if (( (over_on && hot_ok) || skew_on )); then streak=$(( streak_prev + 1 )); else streak=0; fi
      if (( streak >= k )); then
        armed=1; verdict="ARMED"
        if (( over_on && hot_ok )); then reason="pressure: gap $gap ≥ $gap_on and hot $hotp ≥ $hot_min for $streak evaluations$( (( skew_on )) && printf '; skew also holds (%s)' "$skew_det")"
        else reason="skew: $skew_det for $streak evaluations (pressure gap $gap below $gap_on)"; fi
        streak=0   # the clear streak starts fresh
      else armed=0; verdict="WATCHING"; reason="gap $gap; skew ${skew_on:-0} ($skew_det); arming streak $streak/$k"; fi
    else
      if (( over_off == 0 && skew_on == 0 )); then streak=$(( streak_prev + 1 )); else streak=0; fi
      if (( streak >= k )); then armed=0; verdict="CLEARED"; reason="gap $gap < $gap_off for $streak evaluations"; streak=0   # the arming streak starts fresh
      else armed=1; verdict="ARMED"; reason="still armed; gap $gap (clear streak $streak/$k)"; fi
    fi
  else
    # a missing reading: keep the previous armed state and streak, count nothing
    armed="$armed_prev"; streak="$streak_prev"; verdict="UNMEASURED"
    reason="hot/cold not both measured (unmeasured: ${unmeasured:-none}; hot=${hot:-?} cold=${cold:-?})"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "${hot:-}" "${cold:-}" "${gap:-}" "$verdict" "$armed" "$streak" "$reason" >> "$sf"
  # report
  info "balance $(date -d "@$now" '+%F %H:%M' 2>/dev/null): $verdict — $reason"
  for acct in "${accts[@]}"; do [[ -n "$acct" ]] && printf '  %-10s pressure %s\n' "$acct" "${P[$acct]:-UNMEASURED}"; done
  if (( armed )); then
    local rec; rec="$(_bal_would_recommend "$hot" "$cold" "$hotp" "$coldp")"
    info "$rec"
    _bal_alert "$now" "$verdict" "$hot" "$cold" "$gap" "$rec"
  fi
  return 0
}

# _bal_alert <now> <verdict> <hot> <cold> <gap> <recommendation> — §3.5's mail, gated:
#   always: one line appended to state/balance/alerts.log (the human-readable trail).
#   AIMAIL_BALANCE_MAIL=1 (default 0 until the owner flips it): ONE mail per armed episode
#   (dedup: state/balance/mailed_episode holds the epoch the current episode armed at) to the
#   supervisor and, when set and registered, AIMAIL_HUMAN_ALERT_SEAT — two channels, so the
#   alert never depends on the one seat whose lapse it exists to catch. Recommend-only: the
#   mail carries the --dry-run line, nothing here moves a seat.
_bal_alert() {
  local now="$1" verdict="$2" hot="$3" cold="$4" gap="$5" rec="$6"
  mkdir -p "$(BALANCE_DIR)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$(date -d "@$now" '+%F %H:%M' 2>/dev/null)" "$verdict" "$hot>$cold" "$gap" "$rec" >> "$(BALANCE_DIR)/alerts.log"
  [[ "${AIMAIL_BALANCE_MAIL:-0}" == "1" ]] || return 0
  # the episode key: the epoch of the evaluation that ARMED (first ARMED line after the last non-armed one)
  local ep; ep="$(awk -F'\t' '$6==0 {a=""} $6==1 && a=="" {a=$1} END{print a}' "$(BALANCE_STREAK_FILE)" 2>/dev/null)"
  [[ -n "$ep" ]] || ep="$now"
  local mf; mf="$(BALANCE_DIR)/mailed_episode"
  [[ -f "$mf" && "$(cat "$mf")" == "$ep" ]] && return 0
  command -v mail_send >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/mail.sh" 2>/dev/null || return 0
  local sup="${AIMAIL_SUPERVISOR:-assistant}" human="${AIMAIL_HUMAN_ALERT_SEAT:-}"
  local -a to=(--to "$sup"); [[ -n "$human" ]] && seat_exists "$human" 2>/dev/null && to+=(--to "$human")
  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/balance_alert.XXXXXX" 2>/dev/null || mktemp)"
  { printf 'from: aimail budget balance (cron)\n\nBUDGET PRESSURE ALERT -- %s\n\n' "$(date -d "@$now" '+%F %H:%M' 2>/dev/null)"
    printf 'Account %s has been burning faster than it can sustain to its reset, relative to %s, for the full arming window (gap %s; design docs/load_balancer_design_2026-09-21.md §3.3).\n\n' "$hot" "$cold" "$gap"
    printf '%s\n\nThis is a RECOMMENDATION. Nothing has been moved. The command above is --dry-run; drop the flag to act. aimail budget balance shows the live picture.\n' "$rec"
  } > "$body"
  local mrc=0
  # subshell: mail_send fails LOUD (exit) on an unwritable inbox (FI-61); the episode marker below must still be written
  ( mail_send "${to[@]}" --from "$sup" --subject "BUDGET PRESSURE: $hot vs $cold, gap $gap -- balancer recommends one move (recommend-only)" --body-file "$body" ) >/dev/null 2>&1 || mrc=$?
  # one attempt per episode either way: a persistently failing mailbox must not turn into a mail every 5 min
  printf '%s' "$ep" > "$mf"
  (( mrc == 0 )) || printf '%s\t%s\tMAIL-FAILED rc=%s\t%s\n' "$now" "$(date -d "@$now" '+%F %H:%M' 2>/dev/null)" "$mrc" "recipients: ${to[*]}" >> "$(BALANCE_DIR)/alerts.log"
  rm -f "$body"
}

# _bal_would_recommend <hot> <cold> <hotp> <coldp> — §3.4, printed only (this cut)
_bal_would_recommend() {
  local hot="$1" cold="$2" hotp="$3" coldp="$4"
  local sup="${AIMAIL_SUPERVISOR:-assistant}"
  local line seat wt raw usd model last act best="" best_wt="" best_act=99
  local hot_total; hot_total="$(seat_costs "$hot" "${AIMAIL_BALANCE_WINDOW_H:-3}" | awk -F'\t' '$1!="_unattributed"{s+=$2} END{printf "%.0f", s}')"
  [[ "$hot_total" =~ ^[0-9]+$ ]] && (( hot_total > 0 )) || { echo "  would recommend: nothing — no measured per-seat cost on '$hot' (seat ledger UNMEASURED or empty)"; return 0; }
  # the gap to narrow, and how much of hot's pressure each seat carries (its share of hot's cost)
  local gap; [[ "$hotp" == "INF" ]] && gap="INF" || gap="$(awk -v a="$hotp" -v b="$coldp" 'BEGIN{printf "%.4f", a-b}')"
  while IFS=$'\t' read -r seat wt raw usd model last; do
    [[ "$seat" == "_unattributed" || "$seat" == "$sup" ]] && continue
    # R1 (T-917): pinned seats are never recommended -- the supervisor AND the vice
    source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
    command -v _pl_is_pinned >/dev/null 2>&1 && _pl_is_pinned "$seat" && continue
    act="$(_bal_seat_activity "$seat")"; (( act >= 9 )) && continue
    # moving seat s: hot' = hotp*(1-share), cold' = coldp + hotp*share  (same quota shape assumed)
    local share; share="$(awk -v w="$wt" -v t="$hot_total" 'BEGIN{printf "%.4f", w/t}')"
    local ok
    if [[ "$hotp" == "INF" ]]; then ok=1; else
      ok="$(awk -v h="$hotp" -v c="$coldp" -v s="$share" 'BEGIN{ h2=h*(1-s); c2=c+h*s; print (h2>=c2 && (h2-c2)<(h-c))?1:0 }')"
    fi
    (( ok )) || continue
    if (( act < best_act )) || { (( act == best_act )) && [[ -n "$best_wt" ]] && awk -v a="$wt" -v b="$best_wt" 'BEGIN{exit !(a<b)}'; }; then
      best="$seat"; best_wt="$wt"; best_act="$act"
    fi
  done < <(seat_costs "$hot" "${AIMAIL_BALANCE_WINDOW_H:-3}")
  if [[ -n "$best" ]]; then
    # R2-R5 (T-917): the TARGET is what placement says for THIS seat, not the coldest account by pressure
    local target="$cold"
    if command -v placement_pick >/dev/null 2>&1; then
      local -a others=(); local a2; for a2 in ${AIMAIL_FLEET_ACCOUNTS:-}; do [[ "$a2" != "$hot" ]] && others+=("$a2"); done
      local pk; pk="$(placement_pick "$best" "${others[@]:-}" 2>/dev/null || true)"
      if [[ -z "$pk" ]]; then echo "  would recommend: none — placement finds NO eligible account for '$best' (precious/spread/headroom rules); see aimail budget placement $best"; return 0; fi
      [[ "$pk" != "$cold" ]] && echo "  (placement overrides the pressure-coldest '$cold' with '$pk' for '$best')"
      target="$pk"
    fi
    cold="$target"
    echo "  would recommend (NOT acting): move '$best' from '$hot' to '$cold' — activity $best_act (0 idle/1 between/3 mid), cost $best_wt weighted tokens over the window: aimail seat migrate $best $cold --from $sup --dry-run"
  else
    echo "  would recommend: none — no single eligible seat on '$hot' narrows the gap without flipping it"
  fi
}

budget_balance() {
  local plan=0; while (( $# )); do case "$1" in --plan) plan=1; shift ;; *) shift ;; esac; done
  local -a accts=(); read -r -a accts <<< "${AIMAIL_FLEET_ACCOUNTS:-$(account_id)}"
  info "budget balance — ${#accts[@]} account(s); window ${AIMAIL_BALANCE_WINDOW_H:-3}h; K=${AIMAIL_BALANCE_K:-6}; gap on/off ${AIMAIL_BALANCE_GAP_ON:-0.40}/${AIMAIL_BALANCE_GAP_OFF:-0.20}; READ-ONLY (no marker, no mail: design §5 step 2)"
  echo
  printf '%-10s %-9s %-9s %-9s  %s\n' ACCOUNT PARKED PRESS_W PRESS_S DETAIL
  local acct pw ps det
  for acct in "${accts[@]}"; do
    [[ -n "$acct" ]] || continue
    IFS='|' read -r pw ps det <<<"$(balance_pressure "$acct")"
    printf '%-10s %-9s %-9s %-9s  %s\n' "$acct" "$([[ -f "$(THROTTLE_FLAG "$acct")" ]] && echo yes || echo no)" "${pw:-?}" "${ps:-?}" "$det"
  done
  echo
  local sf; sf="$(BALANCE_STREAK_FILE)"
  if [[ -s "$sf" ]]; then
    info "streak (last 5 evaluations: epoch hot cold gap verdict armed streak reason)"
    tail -5 "$sf" | while IFS=$'\t' read -r e h c g v a s r; do printf '  %s  %-9s %-9s %-6s %-10s %s %s  %s\n' "$(date -d "@$e" '+%H:%M' 2>/dev/null)" "$h" "$c" "$g" "$v" "$a" "$s" "$r"; done
  else info "no evaluations yet (the autopilot tick writes state/balance/streak)"; fi
  echo
  budget_seats
  (( plan )) && info "--plan (§3.6 water-filling) is not built in this cut"
  return 0
}
