# lib/ask.sh — the ASK LEDGER: a task the owner asked for is never silently dropped.
#
# ⛔ WHY THIS EXISTS (owner, 2026-09-23): "I ask for a task to get done and the fleet just lets
#    it drop. It doesn't matter how important the task is, a newer task ends up dropping the
#    older ones. A dropped task is expensive, now we have to spend time re-investigating what
#    state it was left in."
#
# The ledger is a flock'd TSV under $STATE_DIR. Every row is an ASK with an owner seat, the
# owner's own words, the next step, and a SHELL PREDICATE that decides when it is done. Nobody
# closes a row by hand: `ask sweep` (cron, every 10 min) runs each open row's predicate and
# closes the row only when the predicate exits 0, recording the predicate's own output as the
# evidence. The one manual close is `ask withdraw --owner-approved "<quote>"`.
#
# Every `ask touch` is a CURRENT-STATE snapshot ("where it stands", evidence, next step), so a
# stalled row says exactly where the work was left — the re-investigation the owner named is
# what a touch buys off in advance.
#
# Staleness (untouched longer than AIMAIL_ASK_STALE, default 1800 s): one mail per row per
# episode to the row's owner seat and the supervisor; at twice that, one line appended to the
# owner's inbox file (AIMAIL_OWNER_INBOX, a conf path; unset = skipped). A touch ends the
# episode. A predicate that is literally `false` means "closes only on the owner's verdict":
# the row is listed as WAITING-ON-OWNER and is never stale-escalated to the owner seat — the
# owner asked for a decision, not a reminder.
#
# A REAL (non-`false`) check can ALSO be practically blocked on someone's decision while it
# waits to become true (measured live: a16's check stayed unsatisfiable for hours after the
# feature it named was descoped, and stale-mailed every 30 min with nothing to act on each
# time). `ask touch <id> ... --waiting-on <who>` sets this without touching the check field:
# the row still auto-closes the moment its check passes, but the stale-mail/owner-inbox
# escalation is suppressed exactly like the false-check case. `ask digest [<who>]` lists every
# row blocked this way, one line each, for whoever wants the "what's still owed" view instead
# of a mail per row per episode. `ask touch <id> ... --waiting-on ''` clears it explicitly.
#
# The claim gate (bin/gateclaim.sh) REFUSES a new claim by a seat that owns a stale open row,
# naming the row — that is how "a newer task drops the older ones" becomes impossible by
# default. `--preempt-ok "<owner quote>"` records the quote on the row and proceeds.
#
# Visibility: `aimail fleet` (OPEN/STALE per seat), `aimail role write` (a seat's open rows are
# appended to its handover between markers), `aimail session` (printed at boot).
#
# Generic by design: no owner, company, project or seat names live in this file; seats come
# from the registry, the supervisor from AIMAIL_SUPERVISOR.

ASK_FILE()  { echo "$STATE_DIR/asks.tsv"; }
ASK_LOCK()  { echo "$STATE_DIR/asks.lock"; }
ASK_SEQ()   { echo "$STATE_DIR/asks.seq"; }

# TSV columns (tab-separated, one row per ask; tabs/newlines inside a field become spaces):
#  1 id  2 asked_at(epoch)  3 owner  4 ask  5 next  6 check  7 rank  8 state
#  9 last_touch(epoch)  10 touched_by  11 state_text  12 evidence  13 done_at  14 done_output
# 15 stale_mailed_at  16 escalated_at  17 asked_at_text (as given on import, else "")
# 18 waiting_on (seat name, or empty) -- see ask_touch's own --waiting-on
ASK_NCOLS=18
ASK_STATES="open waiting_owner done withdrawn"

_ask_clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

_ask_locked() {  # _ask_locked <fn> [args…]  -- run fn under the ledger lock
  ensure_dirs
  local lockf; lockf="$(ASK_LOCK)"
  (
    flock -w "${AIMAIL_ASK_LOCK_WAIT:-10}" 9 || die "ask: could not take the ledger lock in ${AIMAIL_ASK_LOCK_WAIT:-10}s"
    "$@"
  ) 9>"$lockf"
}

_ask_ensure_file() {
  local f; f="$(ASK_FILE)"
  [[ -f "$f" ]] || printf 'id\tasked_at\towner\task\tnext\tcheck\trank\tstate\tlast_touch\ttouched_by\tstate_text\tevidence\tdone_at\tdone_output\tstale_mailed_at\tescalated_at\tasked_at_text\twaiting_on\n' > "$f"
}

_ask_next_id() {
  local seqf n; seqf="$(ASK_SEQ)"
  n="$(cat "$seqf" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$seqf"
  printf 'k%04d' "$n"
}

_ask_rows() {  # every data row (no header)
  _ask_ensure_file
  tail -n +2 "$(ASK_FILE)"
}

_ask_row() {  # _ask_row <id> -> the row or nothing
  _ask_rows | awk -F'\t' -v id="$1" '$1==id {print; exit}'
}

_ask_field() {  # _ask_field <row> <n>
  printf '%s\n' "$1" | cut -f"$2"
}

# _ask_rewrite <id> <awk-assignments>  -- rewrite one row in place (under the lock)
# The assignments are awk statements over $N fields, e.g. '$8="done"; $13=now'.
_ask_rewrite() {
  local id="$1" prog="$2" f tmp
  f="$(ASK_FILE)"; tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$id" -v now="$(now_epoch)" \
      'NR==1 {print; next} $1==id {'"$prog"'} {print}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

_ask_stale_sec() { echo "${AIMAIL_ASK_STALE:-1800}"; }

# age of a row = now - last_touch (or asked_at when never touched)
_ask_age() {
  local row="$1" lt at
  lt="$(_ask_field "$row" 9)"; at="$(_ask_field "$row" 2)"
  [[ -n "$lt" && "$lt" != 0 ]] || lt="$at"
  echo $(( $(now_epoch) - lt ))
}

_ask_is_stale() {  # open row, untouched past the stale window, and not --waiting-on blocked
  local row="$1" st; st="$(_ask_field "$row" 8)"
  [[ "$st" == "open" ]] || return 1
  [[ -z "$(_ask_field "$row" 18)" ]] || return 1
  (( $(_ask_age "$row") > $(_ask_stale_sec) ))
}

# ─── add ─────────────────────────────────────────────────────────────────────────────────
_ask_add_locked() {
  local owner="$1" quote="$2" next="$3" check="$4" rank="$5" id
  _ask_ensure_file
  id="$(_ask_next_id)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$(now_epoch)" "$owner" "$(_ask_clean "$quote")" "$(_ask_clean "$next")" \
    "$(_ask_clean "$check")" "$rank" "open" 0 "" "" "" 0 "" 0 0 "" "" >> "$(ASK_FILE)"
  printf '%s\n' "$id"
}

ask_add() {
  local owner="" quote="" next="" check="" rank=100
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      --quote) quote="${2:-}"; shift 2 ;;
      --next)  next="${2:-}";  shift 2 ;;
      --check) check="${2:-}"; shift 2 ;;
      --rank)  rank="${2:-}";  shift 2 ;;
      *) refused "ask add: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$owner" && -n "$quote" && -n "$next" && -n "$check" ]] || refused \
    "usage: aimail ask add --owner <seat> --quote \"<owner's words>\" --next \"<step>\" --check '<shell predicate>' [--rank N]" \
    "  --check 'false' means: closes only on the owner's verdict (listed as WAITING-ON-OWNER, never stale-escalated)."
  owner="$(seat_resolve "$owner")" || exit $?
  [[ "$rank" =~ ^[0-9]+$ ]] || refused "ask add: --rank must be a non-negative integer"
  local id; id="$(_ask_locked _ask_add_locked "$owner" "$quote" "$next" "$check" "$rank")"
  ok "ask $id added — owner $owner, rank $rank: $(_ask_clean "$quote")"
  printf '%s\n' "$id"
}

# ─── touch ───────────────────────────────────────────────────────────────────────────────
# ⭐ --waiting-on <seat> (touch only, 2026-09-23): a REAL check (not the literal `false` that
#   already means "closes only on the owner's verdict") can be practically unsatisfiable while
#   blocked on an external decision -- measured live on a16, stale-mailed 6x every 30 min with
#   nothing to act on each time. Setting column 18 exempts the row from the sweep's stale-mail/
#   escalation branch (still evaluated for close -- a real check that later passes still closes
#   it) without touching the check field itself, and without silently reusing waiting_owner
#   (which is the false-check convention and must keep meaning exactly that). The sentinel
#   distinguishes "no --waiting-on given" (leave column 18 alone) from "--waiting-on ''"
#   (explicitly clear it) -- an ordinary touch must not silently drop an existing block.
_ASK_WAITING_ON_UNSET='__ask_waiting_on_not_given__'

_ask_touch_locked() {
  local id="$1" by="$2" state="$3" evidence="$4" next="$5" waiting_on="$6" row st
  row="$(_ask_row "$id")"; [[ -n "$row" ]] || refused "ask touch: no such ask '$id'"
  st="$(_ask_field "$row" 8)"
  [[ "$st" == "open" || "$st" == "waiting_owner" ]] || refused "ask touch: '$id' is $st, not open"
  local prog='$9=now; $10="'"$(_ask_clean "$by")"'"; $11="'"$(_ask_clean "$state")"'"'
  [[ -n "$evidence" ]] && prog="$prog"'; $12="'"$(_ask_clean "$evidence")"'"'
  [[ -n "$next" ]]     && prog="$prog"'; $5="'"$(_ask_clean "$next")"'"'
  [[ "$waiting_on" != "$_ASK_WAITING_ON_UNSET" ]] && prog="$prog"'; $18="'"$(_ask_clean "$waiting_on")"'"'
  # a touch ends the stale episode: the next stale mail / escalation is allowed again
  prog="$prog"'; $15=0; $16=0'
  _ask_rewrite "$id" "$prog"
}

ask_touch() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || refused "usage: aimail ask touch <id> --by <seat> --state \"<where it stands>\" [--evidence <sha|path|mail id>] [--next \"<step>\"] [--waiting-on <seat>|'']"
  local by="" state="" evidence="" next="" waiting_on="$_ASK_WAITING_ON_UNSET"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) by="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --next) next="${2:-}"; shift 2 ;;
      --waiting-on) waiting_on="${2:-}"; shift 2 ;;
      *) refused "ask touch: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$by" && -n "$state" ]] || refused "ask touch: --by <seat> and --state \"<where it stands>\" are required"
  by="$(seat_resolve "$by")" || exit $?
  # ⚠ --waiting-on is a LABEL, not a mail address: who a row is blocked on is very often a
  #   human running the fleet, never registered as an aimail seat -- seat_resolve would
  #   wrongly refuse the exact case this flag exists for. Free text, cleaned like any other
  #   field (deliberately generic here: no operator/company/project name belongs in this
  #   shared source -- see lib/sterility.sh's own header).
  [[ "$waiting_on" != "$_ASK_WAITING_ON_UNSET" ]] && waiting_on="$(_ask_clean "$waiting_on")"
  _ask_locked _ask_touch_locked "$id" "$by" "$state" "$evidence" "$next" "$waiting_on"
  ok "ask $id touched by $by: $(_ask_clean "$state")$( [[ "$waiting_on" != "$_ASK_WAITING_ON_UNSET" ]] && printf ' (waiting_on=%s)' "${waiting_on:-<cleared>}" )"
}

# ─── withdraw (the ONLY hand close) ─────────────────────────────────────────────────────
_ask_withdraw_locked() {
  local id="$1" quote="$2" row st
  row="$(_ask_row "$id")"; [[ -n "$row" ]] || refused "ask withdraw: no such ask '$id'"
  st="$(_ask_field "$row" 8)"
  [[ "$st" == "open" || "$st" == "waiting_owner" ]] || refused "ask withdraw: '$id' is $st, not open"
  _ask_rewrite "$id" '$8="withdrawn"; $13=now; $14="withdrawn, owner-approved: '"$(_ask_clean "$quote")"'"'
}

ask_withdraw() {
  local id="${1:-}"; shift || true
  local quote=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner-approved) quote="${2:-}"; shift 2 ;;
      *) refused "ask withdraw: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$id" && -n "$quote" ]] || refused "usage: aimail ask withdraw <id> --owner-approved \"<owner quote>\"" \
    "  There is no 'aimail ask done'. A row closes when its --check exits 0 (ask sweep), or here, with the owner's words."
  _ask_locked _ask_withdraw_locked "$id" "$quote"
  ok "ask $id withdrawn (owner-approved)"
}

# ─── list / show ─────────────────────────────────────────────────────────────────────────
_ask_fmt_age() { local s="$1"; if (( s < 3600 )); then echo "$((s/60))m"; elif (( s < 86400 )); then echo "$((s/3600))h"; else echo "$((s/86400))d"; fi; }

_ask_state_label() {  # <row> -> OPEN | STALE | WAITING-ON-<seat> | WAITING-ON-OWNER | DONE | WITHDRAWN
  local row="$1" st wo; st="$(_ask_field "$row" 8)"; wo="$(_ask_field "$row" 18)"
  case "$st" in
    open) if [[ -n "$wo" ]]; then echo "WAITING-ON-${wo^^}"
          elif _ask_is_stale "$row"; then echo "STALE"
          else echo "OPEN"; fi ;;
    waiting_owner) echo "WAITING-ON-OWNER" ;;
    done) echo "DONE" ;;
    withdrawn) echo "WITHDRAWN" ;;
    *) echo "$st" ;;
  esac
}

ask_list() {
  local owner="" only_stale=0 all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      --stale) only_stale=1; shift ;;
      --all) all=1; shift ;;
      *) refused "ask list: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$owner" ]] && { owner="$(seat_resolve "$owner")" || exit $?; }
  _ask_ensure_file
  local n=0 row label
  printf '%-6s %-17s %-10s %-5s %-6s  %s\n' ID STATE OWNER RANK AGE ASK
  # order: rank asc, then asked_at asc (oldest first)
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    local st; st="$(_ask_field "$row" 8)"
    if (( ! all )); then [[ "$st" == "open" || "$st" == "waiting_owner" ]] || continue; fi
    [[ -n "$owner" && "$(_ask_field "$row" 3)" != "$owner" ]] && continue
    label="$(_ask_state_label "$row")"
    if (( only_stale )); then [[ "$label" == "STALE" ]] || continue; fi
    n=$((n+1))
    # ⛔ ONE WRITE PER RECORD, not one per line. A reader that stops as soon as
    #   it matches (e.g. `grep -q pattern-on-the-first-line`) closes its end
    #   of the pipe the instant it is satisfied; a SECOND, separate printf for
    #   the SAME record then hits a closed pipe and SIGPIPE-kills this script
    #   (measured live: `ask list --owner alpha | grep -q "^k0001.*OPEN"`
    #   exited 141, not the grep's own 0). Building the whole record as one
    #   string and printing it in a single call makes it one atomic write.
    local _rec
    _rec="$(printf '%-6s %-17s %-10s %-5s %-6s  %s' "$(_ask_field "$row" 1)" "$label" "$(_ask_field "$row" 3)" \
      "$(_ask_field "$row" 7)" "$(_ask_fmt_age "$(_ask_age "$row")")" "$(_ask_field "$row" 4)")"
    _rec="${_rec}"$'\n'"$(printf '%-6s   next: %s' "" "$(_ask_field "$row" 5)")"
    local stx; stx="$(_ask_field "$row" 11)"
    [[ -n "$stx" ]] && _rec="${_rec}"$'\n'"$(printf '%-6s   last: %s (%s, by %s)' "" "$stx" "$(_ask_fmt_age $(( $(now_epoch) - $(_ask_field "$row" 9) )))" "$(_ask_field "$row" 10)")"
    printf '%s\n' "$_rec"
  done < <(_ask_rows | sort -t$'\t' -k7,7n -k2,2n)
  (( n )) || info "(no ask rows$( [[ -n "$owner" ]] && printf ' for %s' "$owner" )$( (( only_stale )) && printf ' stale' ))"
  return 0
}

ask_show() {
  local id="${1:-}"; [[ -n "$id" ]] || refused "usage: aimail ask show <id>"
  local row; row="$(_ask_row "$id")"; [[ -n "$row" ]] || refused "ask show: no such ask '$id'"
  local names=(id asked_at owner ask next check rank state last_touch touched_by state_text evidence done_at done_output stale_mailed_at escalated_at asked_at_text waiting_on)
  local i _out=""
  # ⛔ ONE WRITE FOR THE WHOLE RECORD, not one per field -- see ask_list's own
  #   note above for the exact SIGPIPE this avoids (`ask show <id> | grep -q
  #   "^state: *open"` matches partway through 17 lines and closes the pipe;
  #   a later field's own separate printf then dies).
  for i in $(seq 1 $ASK_NCOLS); do
    _out="${_out}$(printf '%-16s %s' "${names[$((i-1))]}:" "$(_ask_field "$row" "$i")")"$'\n'
  done
  printf '%s' "$_out"
}

# ─── internal readers for the gate, the fleet, the handover, the boot check ─────────────
ask_stale_for() {  # <seat> -> stale OPEN row ids + asks, one per line; exit 0 iff at least one
  local seat="$1" row n=0
  _ask_ensure_file
  while IFS= read -r row; do
    [[ -n "$row" && "$(_ask_field "$row" 3)" == "$seat" ]] || continue
    _ask_is_stale "$row" || continue
    n=$((n+1)); printf '%s\t%s\n' "$(_ask_field "$row" 1)" "$(_ask_field "$row" 4)"
  done < <(_ask_rows)
  (( n ))
}

ask_counts() {  # <seat> -> "<open>/<stale>" (open includes waiting_owner; stale ⊂ open)
  local seat="$1" row o=0 s=0 st
  _ask_ensure_file
  while IFS= read -r row; do
    [[ -n "$row" && "$(_ask_field "$row" 3)" == "$seat" ]] || continue
    st="$(_ask_field "$row" 8)"
    [[ "$st" == "open" || "$st" == "waiting_owner" ]] || continue
    o=$((o+1)); _ask_is_stale "$row" && s=$((s+1))
  done < <(_ask_rows)
  printf '%s/%s\n' "$o" "$s"
}

ASK_ROLE_BEGIN='<!-- aimail:asks:begin (auto-appended by aimail role write; edit the ledger, not this block) -->'
ASK_ROLE_END='<!-- aimail:asks:end -->'

ask_role_block() {  # <seat> -> a markdown block of the seat's open rows (empty when none)
  local seat="$1" body
  body="$(ask_list --owner "$seat" 2>/dev/null | tail -n +2)"
  [[ -n "$body" && "$body" != "(no ask rows"* ]] || return 0
  printf '%s\n## OPEN ASKS for %s (ledger, %s)\n\n```\n%s\n```\n%s\n' "$ASK_ROLE_BEGIN" "$seat" "$(date '+%Y-%m-%d %H:%M')" "$body" "$ASK_ROLE_END"
}

# ─── digest: rows --waiting-on someone, surfaced once instead of stale-mailed every sweep ──
ask_digest() {  # [<who>] -> one line per open row with a non-empty waiting_on
  local who="${1:-}" row wo n=0
  _ask_ensure_file
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ "$(_ask_field "$row" 8)" == "open" ]] || continue
    wo="$(_ask_field "$row" 18)"; [[ -n "$wo" ]] || continue
    [[ -n "$who" && "$wo" != "$who" ]] && continue
    n=$((n+1))
    printf '%s  owed by %-10s  owner %-10s  %s (age %s)\n' \
      "$(_ask_field "$row" 1)" "$wo" "$(_ask_field "$row" 3)" \
      "$(_ask_field "$row" 4)" "$(_ask_fmt_age "$(_ask_age "$row")")"
  done < <(_ask_rows | sort -t$'\t' -k7,7n -k2,2n)
  (( n )) || info "(no rows waiting on anyone$( [[ -n "$who" ]] && printf ' named %s' "$who" ))"
  return 0
}

# ─── sweep (cron; every 10 min) ─────────────────────────────────────────────────────────
_ask_run_check() {  # <id> <check> -> rc 0 done; 1 not done; 124 timeout; prints output on stdout
  local id="$1" check="$2" out rc
  out="$(cd "$STATE_DIR" && AIMAIL_ASK_ID="$id" timeout "${AIMAIL_ASK_CHECK_TIMEOUT:-30}" bash -c "$check" 2>&1)"; rc=$?
  printf '%s' "$out" | head -c 400
  return $rc
}

_ask_sweep_locked() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}" stale; stale="$(_ask_stale_sec)"
  local now; now="$(now_epoch)"
  local row id owner check st age mailed esc out rc closed=0 mailed_n=0 esc_n=0 waiting_n=0
  _ask_ensure_file
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    st="$(_ask_field "$row" 8)"
    [[ "$st" == "open" || "$st" == "waiting_owner" ]] || continue
    id="$(_ask_field "$row" 1)"; owner="$(_ask_field "$row" 3)"; check="$(_ask_field "$row" 6)"
    # literal `false` = the owner's verdict closes it; never run, never stale-escalated
    if [[ "$(printf '%s' "$check" | sed 's/[[:space:]]//g')" == "false" ]]; then
      [[ "$st" == "waiting_owner" ]] || _ask_rewrite "$id" '$8="waiting_owner"'
      waiting_n=$((waiting_n+1)); continue
    fi
    out="$(_ask_run_check "$id" "$check")"; rc=$?
    if [[ "$rc" == 0 ]]; then
      _ask_rewrite "$id" '$8="done"; $13=now; $14="'"$(_ask_clean "${out:-<no output>}")"'"'
      closed=$((closed+1)); info "ask $id DONE — check exited 0: $(_ask_clean "${out:-<no output>}" | head -c 120)"
      continue
    fi
    [[ "$rc" == 124 ]] && warn "ask $id: check timed out after ${AIMAIL_ASK_CHECK_TIMEOUT:-30}s (not done)"
    # --waiting-on <seat>: a REAL check (unlike the literal `false` case above) that has not
    # yet passed but is blocked on someone's decision -- the check is still evaluated every
    # sweep (so a later pass still closes the row), but staleness/mail is suppressed exactly
    # like the false-check case, without touching the check field or the waiting_owner state.
    if [[ -n "$(_ask_field "$row" 18)" ]]; then
      waiting_n=$((waiting_n+1)); continue
    fi
    age="$(_ask_age "$row")"
    (( age > stale )) || continue
    mailed="$(_ask_field "$row" 15)"; esc="$(_ask_field "$row" 16)"
    # one mail per row per stale episode (a touch resets $15/$16 to 0)
    if [[ "${mailed:-0}" == 0 ]]; then
      local body; body="$(mktemp "$AIMAIL_ROOT/tmp/ask.XXXXXX")"
      printf 'STALE ask %s (untouched %s, limit %s):\n  ask:   %s\n  owner: %s\n  next:  %s\n  last:  %s\n  evidence: %s\n\nTouch it: aimail ask touch %s --by %s --state "<where it stands>" --evidence <sha|path|mail id>\nIt closes only when its check exits 0 (aimail ask show %s), or with the owner'"'"'s words via ask withdraw.\n' \
        "$id" "$(_ask_fmt_age "$age")" "$(_ask_fmt_age "$stale")" "$(_ask_field "$row" 4)" "$owner" "$(_ask_field "$row" 5)" \
        "${row:+$(_ask_field "$row" 11)}" "$(_ask_field "$row" 12)" "$id" "$owner" "$id" > "$body"
      local -a to=(--to "$owner"); [[ "$owner" != "$supervisor" ]] && to+=(--to "$supervisor")
      if mail_send "${to[@]}" --from "$supervisor" --subject "STALE ask $id: $(_ask_field "$row" 4 | head -c 60)" --body-file "$body" >/dev/null 2>&1; then
        _ask_rewrite "$id" '$15=now'; mailed_n=$((mailed_n+1))
      else
        warn "ask $id: stale mail could not be sent (will retry next sweep)"
      fi
      rm -f "$body"
    fi
    # at 2x the stale window, one line into the owner's inbox file per episode
    if (( age > 2*stale )) && [[ "${esc:-0}" == 0 && -n "${AIMAIL_OWNER_INBOX:-}" ]]; then
      printf 'STALLED %s: %s; last state %s (%s); owner %s; next %s\n' "$id" "$(_ask_field "$row" 4)" \
        "${row:+$(_ask_field "$row" 11)}" "$(_ask_field "$row" 12)" "$owner" "$(_ask_field "$row" 5)" >> "$AIMAIL_OWNER_INBOX" \
        && { _ask_rewrite "$id" '$16=now'; esc_n=$((esc_n+1)); }
    fi
  done < <(_ask_rows)
  info "ask sweep: $closed closed by check, $mailed_n stale mail(s), $esc_n owner-inbox escalation(s), $waiting_n waiting on the owner"
}

ask_sweep() { _ask_locked _ask_sweep_locked; }

# ─── import (seed) ───────────────────────────────────────────────────────────────────────
# Accepts a TSV with header id/asked_at/owner/ask/next/done_check. Ids are preserved; a row whose
# id already exists is skipped. `asked_at` like "09-23 10:2x" is parsed loosely (x -> 0) against
# the current year; unparseable text keeps now as the epoch and the text in column 17. A trailing
# "# comment" on the check is moved into state_text.
_ask_import_locked() {
  local src="$1" added=0 skipped=0 line id at owner ask next check comment epoch
  _ask_ensure_file
  while IFS=$'\t' read -r id at owner ask next check; do
    [[ -n "$id" && "$id" != "id" ]] || continue
    if [[ -n "$(_ask_row "$id")" ]]; then skipped=$((skipped+1)); continue; fi
    comment=""; if [[ "$check" == *"#"* ]]; then comment="${check#*#}"; check="${check%%#*}"; fi
    check="$(printf '%s' "$check" | sed 's/[[:space:]]*$//')"
    epoch="$(date -d "$(date +%Y)-$(printf '%s' "$at" | sed 's/x/0/g')" +%s 2>/dev/null || echo "")"
    [[ -n "$epoch" ]] || epoch="$(now_epoch)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$epoch" "$owner" "$(_ask_clean "$ask")" "$(_ask_clean "$next")" "$(_ask_clean "$check")" 100 "open" \
      0 "" "$(_ask_clean "${comment# }")" "" 0 "" 0 0 "$(_ask_clean "$at")" "" >> "$(ASK_FILE)"
    added=$((added+1))
  done < "$src"
  info "ask import: $added added, $skipped already present"
}

ask_import() {
  local src="${1:-$STATE_DIR/asks_seed.tsv}"
  [[ -f "$src" ]] || refused "ask import: no such file '$src'"
  _ask_locked _ask_import_locked "$src"
}

ask_dispatch() {
  # ⛔ A reader that stops early (`grep -q`, `head`) closes its end of the pipe
  # the instant it is satisfied; this process's own NEXT write then raises
  # SIGPIPE, whose default disposition kills the whole `aimail` invocation
  # mid-list/mid-show -- not a failure of the read, a crash of the write.
  # Ignoring it here means a closed reader just truncates our output (the
  # normal, safe `head`/`grep -q` behavior every other CLI gives you), for
  # the rest of this one invocation only (a fresh process next time).
  trap '' PIPE
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)       ask_add "$@" ;;
    touch)     ask_touch "$@" ;;
    list)      ask_list "$@" ;;
    show)      ask_show "$@" ;;
    sweep)     ask_sweep ;;
    withdraw)  ask_withdraw "$@" ;;
    import)    ask_import "$@" ;;
    stale-for) [[ $# -ge 1 ]] || refused "usage: aimail ask stale-for <seat>"; ask_stale_for "$(seat_resolve "$1")" ;;
    counts)    [[ $# -ge 1 ]] || refused "usage: aimail ask counts <seat>"; ask_counts "$(seat_resolve "$1")" ;;
    digest)    ask_digest "${1:-}" ;;
    *) refused "usage: aimail ask add|touch|list|show|sweep|withdraw|import|stale-for|counts|digest …" \
         "  add      --owner <seat> --quote \"<owner's words>\" --next \"<step>\" --check '<predicate>' [--rank N]" \
         "  touch    <id> --by <seat> --state \"<where it stands>\" [--evidence <ref>] [--next \"<step>\"]" \
         "                                    [--waiting-on <who>|'']  (blocks stale mail; check still evaluated)" \
         "  list     [--owner <seat>] [--stale] [--all]        show <id>" \
         "  sweep    (cron, every 10 min: runs each open row's check; closes on exit 0; mails stale rows)" \
         "  withdraw <id> --owner-approved \"<quote>\"          import [<seed.tsv>]" \
         "  digest   [<who>]  (rows --waiting-on someone, one line each, instead of a stale mail)" ;;
  esac
}
