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
# PARKING NEEDS A DATE OR A NAMED TRIGGER (drop-prevention guard 2). A row can be parked on
# someone (`--waiting-on`) only together with `--until <date>` (when the park ends and the row
# is stale-eligible again) or `--trigger "<the named event that ends it>"`; a park with neither
# is refused. An expired `--until` un-parks the row: it is listed STALE and escalated like any
# other untouched row. `ask park` is the same operation as a touch with a required park.
#
# THE OWNER'S DIGEST (guard 4): `aimail ask owner-digest` lists every open ask on one screen --
# owner seat, age, state, park date or trigger, next step -- plus the count of owner prompts not
# yet triaged (lib/prompts.sh), so "what is still owed" is one command, not a mailbox crawl.
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
# 19 park_until (epoch the park ends, 0/empty = none)  20 park_trigger (named event, or empty)
# 21 prompt_id (the owner prompt this ask was triaged from, or empty)
ASK_NCOLS=21
ASK_STATES="open waiting_owner done withdrawn"

_ask_clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

# A check that can never pass by itself: nothing will ever close the row except a person, so it
# needs an end (a date or a named trigger) exactly like a park does. The literal `false` is the
# documented case (the owner's verdict closes it). Any other always-failing check is not parked
# by the sweep -- it runs, fails and goes stale like any open row, so it is surfaced, not dropped.
_ask_check_never_passes() {  # <check> -> rc 0 when it can never pass
  local c; c="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$c" in
    false|/bin/false|/usr/bin/false|"! true") return 0 ;;
  esac
  return 1
}

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
  [[ -f "$f" ]] || printf 'id\tasked_at\towner\task\tnext\tcheck\trank\tstate\tlast_touch\ttouched_by\tstate_text\tevidence\tdone_at\tdone_output\tstale_mailed_at\tescalated_at\tasked_at_text\twaiting_on\tpark_until\tpark_trigger\tprompt_id\n' > "$f"
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

# A row is PARKED while it names who it waits on AND its park has not run out. A park with a
# date ends at that date (the row is then stale-eligible again); a park with only a trigger
# lasts until a touch clears it; a legacy park with neither (written before parking needed
# one) stays parked and is flagged "no date" in the digest.
_ask_parked() {  # <row> -> rc 0 when currently parked
  local row="$1" until_at
  [[ -n "$(_ask_field "$row" 18)" ]] || return 1
  until_at="$(_ask_field "$row" 19)"
  [[ "$until_at" =~ ^[0-9]+$ ]] && (( until_at > 0 )) && (( until_at <= $(now_epoch) )) && return 1
  return 0
}

_ask_owner_overdue() {  # <row> -> rc 0 when a never-passing row's own --until has passed
  local u; u="$(_ask_field "$1" 19)"
  [[ "$u" =~ ^[0-9]+$ ]] && (( u > 0 )) && (( u <= $(now_epoch) ))
}

_ask_is_stale() {  # open row, untouched past the stale window, and not currently parked
  local row="$1" st; st="$(_ask_field "$row" 8)"
  [[ "$st" == "open" ]] || return 1
  _ask_parked "$row" && return 1
  (( $(_ask_age "$row") > $(_ask_stale_sec) ))
}

# ─── add ─────────────────────────────────────────────────────────────────────────────────
_ask_add_locked() {
  local owner="$1" quote="$2" next="$3" check="$4" rank="$5" prompt_id="${6:-}" until_at="${7:-0}" trigger="${8:-}" id
  _ask_ensure_file
  id="$(_ask_next_id)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$(now_epoch)" "$owner" "$(_ask_clean "$quote")" "$(_ask_clean "$next")" \
    "$(_ask_clean "$check")" "$rank" "open" 0 "" "" "" 0 "" 0 0 "" "" "${until_at:-0}" "$(_ask_clean "$trigger")" "$prompt_id" >> "$(ASK_FILE)"
  printf '%s\n' "$id"
}

ask_add() {
  local owner="" quote="" next="" check="" rank=100 prompt_id="" until_text="" trigger=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --until) until_text="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-}"; shift 2 ;;
      --owner) owner="${2:-}"; shift 2 ;;
      --quote) quote="${2:-}"; shift 2 ;;
      --next)  next="${2:-}";  shift 2 ;;
      --check) check="${2:-}"; shift 2 ;;
      --rank)  rank="${2:-}";  shift 2 ;;
      --prompt) prompt_id="${2:-}"; shift 2 ;;
      *) refused "ask add: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$owner" && -n "$quote" && -n "$next" && -n "$check" ]] || refused \
    "usage: aimail ask add --owner <seat> --quote \"<owner's words>\" --next \"<step>\" --check '<shell predicate>' [--rank N] [--prompt <p####>] [--until <date> | --trigger \"<event>\"  (required with --check false)]" \
    "  --check 'false' means: closes only on the owner's verdict (listed as WAITING-ON-OWNER); it needs --until <date> or --trigger \"<event>\", and once --until passes it reads OWNER-OVERDUE and is mailed as stale. Renew with: ask touch <id> --until <date>."
  owner="$(seat_resolve "$owner")" || exit $?
  # ⛔ DROP-PREVENTION GUARD 2b: an ask with no machine check that can ever pass (the literal
  #   `false`: it closes only on the owner's verdict) has nothing that brings it back, so it needs
  #   an end -- a date (--until) or a named trigger (--trigger) -- the same rule as a park.
  local until_at=""
  if _ask_check_never_passes "$check"; then
    [[ -n "$until_text" || -n "$trigger" ]] || refused \
      "ask add: a check that can never pass (--check '$check') needs --until <date> or --trigger \"<the named event or decision>\"." \
      "  A row with no machine check closes only by a person; with no date and no trigger nothing ever brings it back." \
      "  Examples: --until +3d   --until 2026-10-05   --trigger \"owner picks option A or B\"."
  elif [[ -n "$until_text" || -n "$trigger" ]]; then
    refused "ask add: --until/--trigger only go with a check that can never pass (--check false); a real check closes the row itself."
  fi
  if [[ -n "$until_text" ]]; then
    until_at="$(_ask_parse_until "$until_text")" || refused \
      "ask add: --until '$until_text' is not a future date." "  Use YYYY-MM-DD, 'YYYY-MM-DD HH:MM', +Nd or +Nh, in the future."
  fi
  trigger="$(_ask_clean "$trigger")"
  [[ "$rank" =~ ^[0-9]+$ ]] || refused "ask add: --rank must be a non-negative integer"
  if [[ -n "$prompt_id" ]]; then
    # --prompt <p####> links this ask to the owner prompt it came from AND triages that prompt
    # in the same step (lib/prompts.sh), so "capture the prompt, add the ask" is one command.
    source "$(dirname "${BASH_SOURCE[0]}")/prompts.sh"
    prompt_exists "$prompt_id" || refused "ask add: no such captured prompt '$prompt_id' (aimail prompt list)"
  fi
  local id; id="$(_ask_locked _ask_add_locked "$owner" "$quote" "$next" "$check" "$rank" "$prompt_id" "$until_at" "$trigger")"
  [[ -n "$prompt_id" ]] && prompt_triage "$prompt_id" --ask "$id" --by "$owner" >/dev/null
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
  local id="$1" by="$2" state="$3" evidence="$4" next="$5" waiting_on="$6" until_at="$7" trigger="$8" renew="${9:-0}" row st
  row="$(_ask_row "$id")"; [[ -n "$row" ]] || refused "ask touch: no such ask '$id'"
  st="$(_ask_field "$row" 8)"
  [[ "$st" == "open" || "$st" == "waiting_owner" ]] || refused "ask touch: '$id' is $st, not open"
  local prog='$9=now; $10="'"$(_ask_clean "$by")"'"; $11="'"$(_ask_clean "$state")"'"'
  [[ -n "$evidence" ]] && prog="$prog"'; $12="'"$(_ask_clean "$evidence")"'"'
  [[ -n "$next" ]]     && prog="$prog"'; $5="'"$(_ask_clean "$next")"'"'
  if [[ "$waiting_on" != "$_ASK_WAITING_ON_UNSET" ]]; then
    # a park (non-empty waiting_on) carries its date and/or trigger; clearing it clears both
    prog="$prog"'; $18="'"$(_ask_clean "$waiting_on")"'"; $19='"${until_at:-0}"'; $20="'"$(_ask_clean "$trigger")"'"'
  fi
  if [[ "$renew" == 1 ]]; then
    prog="$prog"'; $19='"${until_at:-0}"'; $20="'"$(_ask_clean "$trigger")"'"'
  fi
  # a touch ends the stale episode: the next stale mail / escalation is allowed again
  prog="$prog"'; $15=0; $16=0'
  _ask_rewrite "$id" "$prog"
}

# _ask_parse_until <text> -> epoch on stdout, or rc 1. Accepts an absolute date/time
# ("2026-10-05", "2026-10-05 14:00") or a relative one ("+3d", "+12h"). Must lie in the future:
# a park that is already over is not a park.
_ask_parse_until() {
  local t="$1" e
  case "$t" in
    +[0-9]*d) e=$(( $(now_epoch) + ${t//[^0-9]/} * 86400 )) ;;
    +[0-9]*h) e=$(( $(now_epoch) + ${t//[^0-9]/} * 3600 )) ;;
    *) e="$(date -d "$t" +%s 2>/dev/null)" || return 1 ;;
  esac
  [[ "$e" =~ ^[0-9]+$ ]] && (( e > $(now_epoch) )) || return 1
  printf '%s' "$e"
}

ask_touch() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || refused "usage: aimail ask touch <id> --by <seat> --state \"<where it stands>\" [--evidence <sha|path|mail id>] [--next \"<step>\"] [--waiting-on <seat> (--until <date> | --trigger \"<event>\")|'']"
  local by="" state="" evidence="" next="" waiting_on="$_ASK_WAITING_ON_UNSET" until_text="" trigger=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) by="${2:-}"; shift 2 ;;
      --state) state="${2:-}"; shift 2 ;;
      --evidence) evidence="${2:-}"; shift 2 ;;
      --next) next="${2:-}"; shift 2 ;;
      --waiting-on) waiting_on="${2:-}"; shift 2 ;;
      --until) until_text="${2:-}"; shift 2 ;;
      --trigger) trigger="${2:-}"; shift 2 ;;
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
  local until_at="" _row _renew=0
  _row="$(_ask_row "$id")"
  # a row whose check can never pass carries its own end (--until/--trigger on add); a touch may renew it
  if [[ -n "$_row" ]] && _ask_check_never_passes "$(_ask_field "$_row" 6)" \
     && { [[ -n "$until_text" ]] || [[ -n "$trigger" ]]; } \
     && [[ "$waiting_on" == "$_ASK_WAITING_ON_UNSET" || -z "$waiting_on" ]]; then
    _renew=1
    if [[ -n "$until_text" ]]; then
      until_at="$(_ask_parse_until "$until_text")" || refused "ask touch: --until '$until_text' is not a future date."
    fi
    trigger="$(_ask_clean "$trigger")"
  elif [[ "$waiting_on" == "$_ASK_WAITING_ON_UNSET" || -z "$waiting_on" ]]; then
    # no park is being set (nothing given, or an explicit clear): a date/trigger would be orphaned
    [[ -z "$until_text" && -z "$trigger" ]] || refused "ask touch: --until/--trigger only go with --waiting-on <who>." \
      "  They say when and why a PARK ends; without --waiting-on there is no park to attach them to."
  else
    # ⛔ DROP-PREVENTION GUARD 2: parking an ask needs a date or a named trigger. A row parked on
    #   "someone" with no end is exactly how an ask is forgotten: nothing ever brings it back.
    [[ -n "$until_text" || -n "$trigger" ]] || refused \
      "ask touch: parking '$id' on '$waiting_on' needs --until <date> or --trigger \"<the named event that ends the park>\"." \
      "  A park with no end date and no named trigger is how an ask gets dropped: nothing brings it back." \
      "  Examples: --until 2026-10-05   --until +3d   --trigger \"owner answers the scope question\"."
    if [[ -n "$until_text" ]]; then
      until_at="$(_ask_parse_until "$until_text")" || refused \
        "ask touch: --until '$until_text' is not a future date." \
        "  Use YYYY-MM-DD, 'YYYY-MM-DD HH:MM', +Nd or +Nh, in the future."
    fi
    trigger="$(_ask_clean "$trigger")"
  fi
  _ask_locked _ask_touch_locked "$id" "$by" "$state" "$evidence" "$next" "$waiting_on" "$until_at" "$trigger" "$_renew"
  ok "ask $id touched by $by: $(_ask_clean "$state")$( [[ "$waiting_on" != "$_ASK_WAITING_ON_UNSET" ]] && printf ' (waiting_on=%s%s%s)' "${waiting_on:-<cleared>}" "${until_at:+, until $(date -d @"$until_at" '+%F %H:%M')}" "${trigger:+, trigger: $trigger}" )"
}

# ask park <id> --by <seat> --state "<why>" --waiting-on <who> (--until <date> | --trigger "<event>")
# The explicit verb for the same operation: a touch that PARKS the row. Identical rules.
ask_park() {
  local id="${1:-}"; shift || true
  [[ -n "$id" ]] || refused "usage: aimail ask park <id> --by <seat> --state \"<why parked>\" --waiting-on <who> (--until <date> | --trigger \"<event>\")"
  local a have=0; for a in "$@"; do [[ "$a" == "--waiting-on" ]] && have=1; done
  (( have )) || refused "ask park: --waiting-on <who> is required (who or what the ask is parked on)."
  ask_touch "$id" "$@"
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
    open) if _ask_parked "$row"; then echo "WAITING-ON-${wo^^}"
          elif _ask_is_stale "$row"; then echo "STALE"
          else echo "OPEN"; fi ;;
    waiting_owner) if _ask_owner_overdue "$row"; then echo "OWNER-OVERDUE"; else echo "WAITING-ON-OWNER"; fi ;;
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
  local names=(id asked_at owner ask next check rank state last_touch touched_by state_text evidence done_at done_output stale_mailed_at escalated_at asked_at_text waiting_on park_until park_trigger prompt_id)
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
_ask_park_text() {  # <row> -> "until 2026-10-05 14:00" / "trigger: ..." / "no date or trigger (legacy park)"
  local row="$1" u t out=""
  u="$(_ask_field "$row" 19)"; t="$(_ask_field "$row" 20)"
  [[ "$u" =~ ^[0-9]+$ ]] && (( u > 0 )) && out="until $(date -d "@$u" '+%F %H:%M')"
  [[ -n "$t" ]] && out="${out:+$out; }trigger: $t"
  printf '%s' "${out:-no date or trigger (legacy park)}"
}

ask_digest() {  # [<who>] -> one line per open PARKED row, with its date or trigger
  local who="${1:-}" row wo n=0
  _ask_ensure_file
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ "$(_ask_field "$row" 8)" == "open" ]] || continue
    wo="$(_ask_field "$row" 18)"; [[ -n "$wo" ]] || continue
    [[ -n "$who" && "$wo" != "$who" ]] && continue
    n=$((n+1))
    printf '%s  owed by %-10s  owner %-10s  %s (age %s; %s)\n' \
      "$(_ask_field "$row" 1)" "$wo" "$(_ask_field "$row" 3)" \
      "$(_ask_field "$row" 4)" "$(_ask_fmt_age "$(_ask_age "$row")")" "$(_ask_park_text "$row")"
  done < <(_ask_rows | sort -t$'\t' -k7,7n -k2,2n)
  (( n )) || info "(no rows waiting on anyone$( [[ -n "$who" ]] && printf ' named %s' "$who" ))"
  return 0
}

# ─── owner-digest (drop-prevention guard 4) ──────────────────────────────────────────────
# ONE command that answers "what is still open, who has it, how old, what is the next step":
# every open ask (open, parked, stale, waiting on the owner), oldest first within rank, then the
# count of captured owner prompts that were never triaged (lib/prompts.sh). Read-only.
ask_owner_digest() {
  local owner="" row n=0 label
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner) owner="${2:-}"; shift 2 ;;
      *) refused "ask owner-digest: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$owner" ]] && { owner="$(seat_resolve "$owner")" || exit $?; }
  _ask_ensure_file
  local _rec _all=""
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    local st; st="$(_ask_field "$row" 8)"
    [[ "$st" == "open" || "$st" == "waiting_owner" ]] || continue
    [[ -n "$owner" && "$(_ask_field "$row" 3)" != "$owner" ]] && continue
    n=$((n+1)); label="$(_ask_state_label "$row")"
    _rec="$(printf '%-6s %-18s seat %-10s age %-5s %s' "$(_ask_field "$row" 1)" "$label" "$(_ask_field "$row" 3)" \
      "$(_ask_fmt_age "$(_ask_age "$row")")" "$(_ask_field "$row" 4)")"
    _rec="${_rec}"$'\n'"$(printf '%-6s   next: %s' "" "$(_ask_field "$row" 5)")"
    if [[ -n "$(_ask_field "$row" 18)" ]]; then
      _rec="${_rec}"$'\n'"$(printf '%-6s   parked on %s: %s' "" "$(_ask_field "$row" 18)" "$(_ask_park_text "$row")")"
    fi
    _all="${_all}${_rec}"$'\n'
  done < <(_ask_rows | sort -t$'\t' -k7,7n -k2,2n)
  # ⛔ ONE WRITE for the whole digest (see ask_list's SIGPIPE note).
  local pend=0
  if declare -F prompt_untriaged_count >/dev/null 2>&1 || source "$(dirname "${BASH_SOURCE[0]}")/prompts.sh" 2>/dev/null; then
    pend="$(prompt_untriaged_count)"
  fi
  _all="OPEN ASKS: $n$( [[ -n "$owner" ]] && printf ' (seat %s)' "$owner" )   UNTRIAGED OWNER PROMPTS: $pend"$'\n'"$_all"
  (( n )) || _all="${_all}(no open asks)"$'\n'
  (( pend )) && _all="${_all}untriaged prompts: aimail prompt list --untriaged   (each needs: aimail prompt triage <id> --ask <k####> | --no-ask \"<reason>\")"$'\n'
  printf '%s' "$_all"
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
    if _ask_check_never_passes "$check"; then
      [[ "$st" == "waiting_owner" ]] || _ask_rewrite "$id" '$8="waiting_owner"'
      # its own --until has passed: surface it like a stale row (once per episode); a row with
      # only a trigger, or whose date is still ahead, keeps waiting quietly
      if _ask_owner_overdue "$row"; then
        :   # fall through to the stale mail below
      else
        waiting_n=$((waiting_n+1)); continue
      fi
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
    # (an EXPIRED --until is not parked any more: it falls through to the stale branch below)
    if _ask_parked "$row"; then
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
      if mail_send "${to[@]}" --no-wake --from "$supervisor" --subject "STALE ask $id: $(_ask_field "$row" 4 | head -c 60)" --body-file "$body" >/dev/null 2>&1; then
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$epoch" "$owner" "$(_ask_clean "$ask")" "$(_ask_clean "$next")" "$(_ask_clean "$check")" 100 "open" \
      0 "" "$(_ask_clean "${comment# }")" "" 0 "" 0 0 "$(_ask_clean "$at")" "" 0 "" "" >> "$(ASK_FILE)"
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
    park)      ask_park "$@" ;;
    owner-digest) ask_owner_digest "$@" ;;
    *) refused "usage: aimail ask add|touch|park|list|show|sweep|withdraw|import|stale-for|counts|digest|owner-digest …" \
         "  add      --owner <seat> --quote \"<owner's words>\" --next \"<step>\" --check '<predicate>' [--rank N]" \
         "  touch    <id> --by <seat> --state \"<where it stands>\" [--evidence <ref>] [--next \"<step>\"]" \
         "                                    [--waiting-on <who> (--until <date> | --trigger \"<event>\") | '']" \
         "  park     <id> --by <seat> --state \"<why>\" --waiting-on <who> (--until <date> | --trigger \"<event>\")" \
         "  owner-digest [--owner <seat>]   every open ask: seat, age, state, park date/trigger, next step" \
         "  list     [--owner <seat>] [--stale] [--all]        show <id>" \
         "  sweep    (cron, every 10 min: runs each open row's check; closes on exit 0; mails stale rows)" \
         "  withdraw <id> --owner-approved \"<quote>\"          import [<seed.tsv>]" \
         "  digest   [<who>]  (rows --waiting-on someone, one line each, instead of a stale mail)" ;;
  esac
}
