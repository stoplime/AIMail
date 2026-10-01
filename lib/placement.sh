# shellcheck shell=bash
# placement.sh — WHERE a seat belongs, as pure decisions over existing state (the owner's
# requirements of 2026-09-22).
#
# ⛔ THE INCIDENT: r2 parked at 16:55 with 6 of 9 seats on it while research sat at 8%. The
#   balancer had mailed six recommendations and nothing moved; the pick logic had recommended
#   moving the assistant itself off work. the owner: "never again."
#
# THE RULES, each a named function below, one definition each:
#   R1 PINNED    `AIMAIL_PINNED_SEATS` (default: the supervisor and the vice) never move and are
#                never recommended; `--owner-approved` on `seat migrate` is the one override.
#   R2 PRECIOUS  the supervisor's account ("work") is the most precious: a non-pinned seat is
#                never PLACED there while any other account has headroom; it carries overflow only.
#   R3 FABLE     the fable seat is placed by its OWN model's weekly headroom (the probe's
#                fable-model weekly), not the account's general %, and moves first when that runs low.
#   R4 SPREAD    no account carries more than ceil(non-pinned seats / accounts with headroom)
#                non-pinned seats; a move that would exceed it is REFUSED; `fleet`/`budget status`
#                flag an imbalance on sight.
#   R5 PROJECTED among the eligible, the target is the account that LASTS LONGEST at its current
#                burn (minutes to the block cap, days to the weekly cap -- the smaller wins), not
#                the one with the highest headroom right now.
#
# INPUTS (all already on disk, none invented here): seats per account (`_autopilot_seat_groups`,
# or the AIMAIL_PLACEMENT_SEATS seam "acct:seat,seat acct2:seat"), block % per account (the
# ledger, `_last_callout`), weekly % per account (`_last_weekly`), fable-model weekly per account
# (`_last_fable_weekly`), caps (`account_cap`/`weekly_cap`), park flags (`THROTTLE_FLAG`), and the
# ledger's own history for the burn rate (two most recent probe/callout rows per account).
#
# ⚠ REPORT-ONLY BY DESIGN in this cut: nothing here launches or stops anything. `seat migrate`
#   asks `placement_check_move`; the balancer asks `placement_pick`; the dashboards ask
#   `placement_report`. Automatic moves are the next commit (AIMAIL_BALANCE_ACT, off by default).

_pl_pinned() { echo "${AIMAIL_PINNED_SEATS:-${AIMAIL_SUPERVISOR:-assistant} ${AIMAIL_VICE_SUPERVISOR:-main}}"; }
_pl_is_pinned() { local p; for p in $(_pl_pinned); do [[ "$1" == "$p" ]] && return 0; done; return 1; }
_pl_fable_seat() { echo "${AIMAIL_FABLE_SEAT:-fable}"; }

# _pl_seats_by_account — TSV: account \t seat seat ...  (the seam first, else the live grouping)
# _pl_seats_by_account — "<account>\t<seat seat ...>" per account. ⛔ THE SEAT REGISTRY IS THE SOURCE:
#   a seat's account is what it CONFIRMED (state/seat_account/<seat>, `aimail seat confirm`), whether or
#   not a live process resolves right now. The first cut read only the live process groups, so the
#   supervisor and the vice -- both on the precious account, neither running a poller -- counted as
#   0 seats there (assistant, 2026-09-23 02:01). Live groups now only ADD seats that have no record.
_pl_seats_by_account() {
  if [[ -n "${AIMAIL_PLACEMENT_SEATS:-}" ]]; then
    local kv; for kv in $AIMAIL_PLACEMENT_SEATS; do printf '%s\t%s\n' "${kv%%:*}" "${kv#*:}" | tr ',' ' '; done
    return 0
  fi
  local -A by=(); local -A seen=(); local f seat acct
  local rdir; rdir="$(SEAT_RECORD_DIR 2>/dev/null || echo "$STATE_DIR/seat_account")"
  for f in "$rdir"/*; do
    [[ -f "$f" ]] || continue
    seat="$(basename "$f")"; acct="$(awk -F'\t' '$1=="account"{print $2; exit}' "$f")"
    [[ -n "$acct" ]] || continue
    [[ "$(seat_field "$seat" 2 2>/dev/null)" == "retired" ]] && continue
    by["$acct"]="${by[$acct]:+${by[$acct]} }$seat"; seen["$seat"]=1
  done
  local line a seats s
  while IFS=$'\t' read -r a seats; do
    [[ -n "$a" ]] || continue
    for s in $seats; do [[ -n "${seen[$s]:-}" ]] && continue; by["$a"]="${by[$a]:+${by[$a]} }$s"; seen["$s"]=1; done
  done < <(_autopilot_seat_groups 2>/dev/null | awk -F'\t' '{print $2 "\t" $3}')
  for a in "${!by[@]}"; do printf '%s\t%s\n' "$a" "${by[$a]}"; done | sort
}
# ⚠ THE WORD IS THE KEY. An account is named by ONE word everywhere -- AIMAIL_FLEET_ACCOUNTS, the
#   `seat migrate` target, AIMAIL_PLACEMENT_SEATS, AIMAIL_PRECIOUS_ACCOUNT, and every reading file
#   (WEEKLY_FILE <word>, ledger column 2, THROTTLE_FLAG <word>). In production that word is the
#   config dir's label (`account_id()`: research, r2, work). tests/balance.sh names accounts by
#   alias (alpha -> acct-a dir) and keys its readings by the SAME alias, which is the same rule.
#   An earlier cut of this file mapped aliases to dir labels here; that broke every reading lookup
#   in balance.sh (2026-09-22 20:2x) -- the mapping is gone, the rule is the word.
_pl_accounts() {
  if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then printf '%s\n' $AIMAIL_FLEET_ACCOUNTS; return 0; fi
  # ⛔ 2026-09-25: prefer the configured pool (budget.sh's _configured_account_pool --
  #   AIMAIL_ACCOUNT_POOL / AIMAIL_FLEET_ACCOUNTS if set, else the live-seat grouping; NEVER a
  #   filesystem glob -- see that function's own header for the full history) over the seat-only
  #   list below. A seatless-but-idle account (r2, block rolled with zero seats on it) was never
  #   a placement candidate under the old seat-only enumeration, so the balancer kept
  #   recommending the near-cap account since the genuinely-idle one wasn't even in the running.
  #   Falls back to the seat-based list only if the configured pool itself finds nothing.
  source "${BASH_SOURCE[0]%/*}/budget.sh" 2>/dev/null || true
  if command -v _configured_account_pool >/dev/null 2>&1; then
    local pool; pool="$(_configured_account_pool 2>/dev/null || true)"
    [[ -n "$pool" ]] && { printf '%s\n' "$pool"; return 0; }
  fi
  _pl_seats_by_account | cut -f1
}
# the supervisor's own account: the registry/record first, then the live grouping
_pl_precious_account() {
  local sup="${AIMAIL_SUPERVISOR:-assistant}" a
  a="${AIMAIL_PRECIOUS_ACCOUNT:-}"; [[ -n "$a" ]] && { echo "$a"; return 0; }
  a="$(seat_record_read "$sup" account 2>/dev/null || true)"; [[ -n "$a" ]] && { echo "$a"; return 0; }
  _pl_seats_by_account | awk -F'\t' -v s="$sup" '{n=split($2,w," "); for(i=1;i<=n;i++) if(w[i]==s){print $1; exit}}'
}
_pl_nonpinned_on() { # <account> -> count of non-pinned seats there
  local seats; seats="$(_pl_seats_by_account | awk -F'\t' -v a="$1" '$1==a{print $2}')"
  local n=0 s; for s in $seats; do _pl_is_pinned "$s" || n=$((n+1)); done; echo "$n"
}
_pl_nonpinned_total() { local n=0 a; for a in $(_pl_accounts); do n=$((n + $(_pl_nonpinned_on "$a"))); done; echo "$n"; }

# _pl_headroom <account> — "block_headroom \t weekly_headroom" in percentage points (-1 = unmeasured)
# ⛔ THE UNMEASURED SENTINEL IS NOT A HEADROOM VALUE. Headroom is cap - pct with pct in [0,100] and
#   caps in [0,100], so every REAL reading lies in [-100, 100]; -1000 can only mean "no reading".
#   The first cut used -1, and a block reading exactly one point over its cap (91 vs 90 -- the
#   incident fixture's own precious account) read as UNMEASURED, counted as headroom under the
#   relaxed rule, and shrank the fair share to 1 so nothing was eligible (run.sh, 2026-09-22 20:5x).
_PL_UNMEASURED=-1000
_pl_headroom() {
  local acct="$1" lc wl bp="" wp=""
  lc="$(_last_callout "$acct" 2>/dev/null || true)"; [[ -n "$lc" ]] && bp="$(cut -f2 <<<"$lc")"
  wl="$(_last_weekly "$acct" 2>/dev/null || true)";  [[ -n "$wl" ]] && wp="$(cut -f2 <<<"$wl")"
  local bh=$_PL_UNMEASURED wh=$_PL_UNMEASURED
  [[ "$bp" =~ ^[0-9]+$ ]] && bh=$(( $(account_cap "$acct") - bp ))
  [[ "$wp" =~ ^[0-9]+$ ]] && wh=$(( $(weekly_cap "$acct") - wp ))
  printf '%s\t%s\n' "$bh" "$wh"
}
# _pl_has_headroom <account> — unparked, weekly MEASURED and under its cap, and the block reading
# either under its cap or UNMEASURED. ⚠ The first cut demanded a measured block reading too, and
# that made most idle accounts ineligible: a block (5h) reading exists only while something on
# that account probes or calls out, so a quiet account usually has a weekly file and no block
# row -- exactly the account a parked seat should move TO. run.sh's item-4d arm (a parked seat,
# one target with a weekly reading) went from a recommendation to "placement finds no eligible
# account" (2026-09-22 20:1x). Weekly is the binding constraint for placement (the same rule
# budget_pick_account has used since 2026-09-20); an unknown block reading is UNKNOWN, ranked
# last by placement_eligible, never a refusal. A MEASURED block reading at/over its cap still
# disqualifies.
_pl_has_headroom() {
  local acct="$1"; [[ -f "$(THROTTLE_FLAG "$acct")" ]] && return 1
  local bh wh; IFS=$'\t' read -r bh wh < <(_pl_headroom "$acct")
  (( wh > 0 )) && { (( bh == _PL_UNMEASURED )) || (( bh > 0 )); }
}
# _pl_fable_headroom <account> — fable-model weekly headroom in points, $_PL_UNMEASURED when unmeasured
_pl_fable_headroom() {
  local fw; fw="$(_last_fable_weekly "$1" 2>/dev/null || true)"
  local p; p="$(cut -f2 <<<"$fw")"
  [[ "$p" =~ ^[0-9]+$ ]] && echo $(( 100 - p )) || echo $_PL_UNMEASURED
}
# _pl_fable_expiry_risk <account> — how much of the account's fable-model weekly budget is at risk of
# EXPIRING UNUSED: remaining points per hour until that account's weekly reset, x1000 as an integer
# ($_PL_UNMEASURED when unmeasured). Correction of 2026-09-22 19:27 (project owner): fable goes where its budget
# would otherwise expire, not merely where headroom exists -- 72% left resetting in 4.4 days outranks
# 73% left resetting in 6.4 days. No reset epoch recorded -> assume a full week so pure headroom
# ordering degrades gracefully instead of refusing.
_pl_fable_expiry_risk() {
  local fw; fw="$(_last_fable_weekly "$1" 2>/dev/null || true)"
  local p r; p="$(cut -f2 <<<"$fw")"; r="$(cut -f3 <<<"$fw")"
  [[ "$p" =~ ^[0-9]+$ ]] || { echo $_PL_UNMEASURED; return 0; }
  local left=$(( 100 - p )) hours=168
  if [[ "$r" =~ ^[0-9]+$ ]]; then hours=$(( (r - $(now_epoch)) / 3600 )); (( hours < 1 )) && hours=1; fi
  echo $(( left * 1000 / hours ))
}
# _pl_burn_pct_per_min <account> — block % per minute from the two most recent ledger rows (0 when unknown)
# ⛔ SAME BASELINE RULE AS THE WEEKLY RATE (2026-09-23 02:01): integer percent five minutes apart is
#   noise; the burn is (newest - oldest row within AIMAIL_BLOCK_RATE_WINDOW_MIN minutes) / span and
#   counts only with span >= AIMAIL_BLOCK_RATE_MIN_SPAN_S and movement >= AIMAIL_BLOCK_RATE_MIN_PTS;
#   otherwise 0 (= unknown, "99999 min to cap"), never a projection from two adjacent ticks.
_pl_burn_pct_per_min() {
  [[ -s "$LEDGER" ]] || { echo 0; return 0; }
  local now; now="${AIMAIL_NOW:-$(now_epoch)}"
  awk -F'\t' -v a="$1" -v now="$now" -v win="$(( ${AIMAIL_BLOCK_RATE_WINDOW_MIN:-60} * 60 ))" \
      -v minspan="${AIMAIL_BLOCK_RATE_MIN_SPAN_S:-600}" -v minpts="${AIMAIL_BLOCK_RATE_MIN_PTS:-2}" '
    $2==a && ($4=="probe"||$4=="callout") && $1>=now-win { if(e0=="" || $1<e0) {e0=$1;p0=$3} if(e1=="" || $1>e1) {e1=$1;p1=$3} }
    END{ if(e0=="" || e1-e0<minspan || p1-p0<minpts) {print 0; exit} printf "%.4f", (p1-p0)/((e1-e0)/60) }' "$LEDGER"
}
# _pl_minutes_to_cap <account> — projected minutes until the BLOCK cap at the current burn
#   (99999 = no measurable burn or unlimited); the weekly side needs the weekly ledger (next commit)
_pl_minutes_to_cap() {
  local acct="$1" bh wh burn; IFS=$'\t' read -r bh wh < <(_pl_headroom "$acct")
  burn="$(_pl_burn_pct_per_min "$acct")"
  (( bh > 0 )) || { echo 0; return 0; }
  awk -v h="$bh" -v b="$burn" 'BEGIN{ if (b<=0) print 99999; else printf "%d", h/b }'
}

# placement_fair_share — ceil(non-pinned seats / accounts with headroom); 0 when no account has headroom
# _pl_measured <account> — both readings (block, weekly) are numbers; an unmeasured account is NOT "over cap"
_pl_measured() { local bh wh; IFS=$'\t' read -r bh wh < <(_pl_headroom "$1"); (( bh != _PL_UNMEASURED && wh != _PL_UNMEASURED )); }
# _pl_rostered <seat> — the seat appears in some account's roster
_pl_rostered() { _pl_seats_by_account | awk -F'\t' -v s="$1" '{n=split($2,w," "); for(i=1;i<=n;i++) if(w[i]==s){f=1}} END{exit !f}'; }
placement_fair_share() { # [seat] -- a seat being placed that is in no roster yet still counts toward the total
  local n_seats n_accts=0 a
  n_seats="$(_pl_nonpinned_total)"
  if [[ -n "${1:-}" ]] && ! _pl_is_pinned "$1" && ! _pl_rostered "$1"; then n_seats=$((n_seats+1)); fi
  for a in $(_pl_accounts); do _pl_has_headroom "$a" && n_accts=$((n_accts+1)); done
  (( n_accts > 0 )) || { echo 0; return 0; }
  echo $(( (n_seats + n_accts - 1) / n_accts ))
}

# placement_eligible <seat> [candidates...] — TSV rows "score \t account \t why", best first.
#   Applies R1-R5. Prints nothing when no account is eligible. The seat's CURRENT account counts
#   as eligible for staying put (a move is never recommended into the same account by the caller).
placement_eligible() {
  local seat="$1"; shift
  local -a cands=("$@"); (( ${#cands[@]} )) || read -r -a cands <<<"$(_pl_accounts | tr '\n' ' ')"
  local precious; precious="$(_pl_precious_account)"
  local share; share="$(placement_fair_share "$seat")"
  local others_with_headroom=0 a
  for a in "${cands[@]}"; do [[ "$a" != "$precious" ]] && _pl_has_headroom "$a" && others_with_headroom=1; done
  local fable=0; [[ "$seat" == "$(_pl_fable_seat)" ]] && fable=1
  local rows="" why score fh mins bh wh n
  for a in "${cands[@]}"; do
    [[ -n "$a" ]] || continue
    if _pl_is_pinned "$seat"; then
      # a pinned seat's only eligible account is the precious one
      [[ "$a" == "$precious" ]] || continue
    else
      _pl_has_headroom "$a" || continue                                   # parked / at cap / unmeasured
      if [[ "$a" == "$precious" ]] && (( others_with_headroom )); then continue; fi   # R2
      n="$(_pl_nonpinned_on "$a")"
      if (( share > 0 && n >= share )); then continue; fi                 # R4 (already at its share)
    fi
    IFS=$'\t' read -r bh wh < <(_pl_headroom "$a")
    mins="$(_pl_minutes_to_cap "$a")"
    if (( fable )); then
      fh="$(_pl_fable_headroom "$a")"; (( fh > 0 )) || continue          # R3: fable needs fable headroom
      local risk; risk="$(_pl_fable_expiry_risk "$a")"
      # rank by expiry risk (points/hour to the reset), headroom breaks ties -- see _pl_fable_expiry_risk
      score=$(( risk * 1000 + fh )); why="fable-model budget most at risk of expiring unused: ${fh}pt left, $(( risk )) pt/1000h to that account's weekly reset; ${mins} min to block cap"
    elif (( bh == _PL_UNMEASURED )); then
      # block reading unknown: eligible (weekly decides), ranked below every measured account
      score=$(( wh )); why="block headroom UNMEASURED (no probe/callout on this account), weekly headroom ${wh}pt -- ranked last among eligible"
    else
      score=$(( mins * 1000 + wh )); why="${mins} min to block cap at current burn, weekly headroom ${wh}pt, block headroom ${bh}pt"
    fi
    rows+="$(printf '%012d\t%s\t%s' "$score" "$a" "$why")"$'\n'
  done
  [[ -n "$rows" ]] && printf '%s' "$rows" | sort -r
}
# placement_pick <seat> [candidates...] — the best account, or exit 1
placement_pick() { local r; r="$(placement_eligible "$@" | head -1)"; [[ -n "$r" ]] || return 1; cut -f2 <<<"$r"; }

# placement_check_move <seat> <target> — "OK \t why" or "REFUSE \t why" (exit 1 on REFUSE)
placement_check_move() {
  local seat="$1" target="$2" precious; precious="$(_pl_precious_account)"
  if _pl_is_pinned "$seat"; then printf 'REFUSE\t%s is PINNED (AIMAIL_PINNED_SEATS: %s) -- only the owner moves it\n' "$seat" "$(_pl_pinned)"; return 1; fi
  [[ -f "$(THROTTLE_FLAG "$target")" ]] && { printf 'REFUSE\t%s is parked\n' "$target"; return 1; }
  # ⛔ unmeasured is NOT over cap. A rule refuses only what it can decide: a MEASURED target at/over a
  #   cap is refused; a target with no readings yet is allowed with a WARNING (the operator ran the
  #   command; the tool has no fact against it). Found by tests/seat_migrate.sh: 77 arms with no
  #   ledger at all read as "no headroom" and every ordinary move was refused.
  local unmeasured=0
  if ! _pl_measured "$target"; then unmeasured=1
  elif ! _pl_has_headroom "$target"; then printf 'REFUSE\t%s is at/over a cap (block headroom %s, weekly %s)\n' "$target" "$(_pl_headroom "$target" | cut -f1)" "$(_pl_headroom "$target" | cut -f2)"; return 1; fi
  if [[ "$target" == "$precious" ]]; then
    local a; for a in $(_pl_accounts); do
      [[ "$a" != "$precious" ]] && _pl_has_headroom "$a" && { printf 'REFUSE\t%s is the supervisor'"'"'s account (most precious); %s still has headroom -- a non-pinned seat goes there first\n' "$target" "$a"; return 1; }
    done
  fi
  local share n; share="$(placement_fair_share "$seat")"; n="$(_pl_nonpinned_on "$target")"
  # the seat's own current account is not a move: leaving it there never breaks the spread
  local cur; cur="$(_pl_seats_by_account | awk -F'\t' -v s="$seat" '{n=split($2,w," "); for(i=1;i<=n;i++) if(w[i]==s){print $1; exit}}')"
  if [[ "$cur" != "$target" ]] && (( share > 0 && n + 1 > share )); then printf 'REFUSE\t%s already carries %s non-pinned seat(s); the fair share is %s (spread rule)\n' "$target" "$n" "$share"; return 1; fi
  if [[ "$seat" == "$(_pl_fable_seat)" ]]; then
    local fh; fh="$(_pl_fable_headroom "$target")"
    if (( fh == _PL_UNMEASURED )); then unmeasured=1; elif (( fh <= 0 )); then printf 'REFUSE\t%s has no fable-model headroom (%spt)\n' "$target" "$fh"; return 1; fi
  fi
  if (( unmeasured )); then printf 'OK\tWARNING: %s has no measured readings yet (no probe/callout, or no weekly) -- the move is allowed, the rule could not be decided; run aimail budget probe there\n' "$target"; return 0; fi
  printf 'OK\t%s\n' "$(placement_eligible "$seat" "$target" | head -1 | cut -f3)"; return 0
}

# placement_report — one line per account + an IMBALANCE verdict; exit 1 when imbalanced
placement_report() {
  local share precious a n bh wh mins fh flag=0 seats
  share="$(placement_fair_share)"; precious="$(_pl_precious_account)"
  # SEATS reads "total(non-pinned)": the spread rule (R4) counts NON-PINNED seats only, so the precious
  # account with just the supervisor and the vice showed "0" and read as empty (assistant 02:26).
  printf '%-10s %-8s %-9s %-9s %-9s %-10s %s\n' ACCOUNT 'SEATS(NP)' SHARE BLOCK-HR WEEKLY-HR MIN-TO-CAP NOTE
  for a in $(_pl_accounts); do
    n="$(_pl_nonpinned_on "$a")"; IFS=$'\t' read -r bh wh < <(_pl_headroom "$a"); mins="$(_pl_minutes_to_cap "$a")"
    local tot; tot="$(_pl_seats_by_account | awk -F'\t' -v x="$a" '$1==x{print split($2,w," ")}')"; tot="${tot:-0}"
    local note=""; [[ "$a" == "$precious" ]] && note="precious (supervisor)"
    [[ -f "$(THROTTLE_FLAG "$a")" ]] && note="${note:+$note; }PARKED"
    if (( share > 0 && n > share )); then note="${note:+$note; }OVER SHARE"; flag=1; fi
    printf '%-10s %-8s %-9s %-9s %-9s %-10s %s\n' "$a" "${tot}(${n})" "$share" "$bh" "$wh" "$mins" "$note"
  done
  if (( flag )); then
    local other=0; for a in $(_pl_accounts); do n="$(_pl_nonpinned_on "$a")"; (( share > 0 && n < share )) && _pl_has_headroom "$a" && other=1; done
    if (( other )); then warn "PLACEMENT IMBALANCE: an account is over its fair share while another with headroom is under it -- the balancer should move seats (aimail budget balance)"; return 1; fi
  fi
  return 0
}
