# lib/prompts.sh — the PROMPT LEDGER: every message the owner types is captured, and none is
# left without an answer to "did that create an ask?".
#
# ⛔ WHY THIS EXISTS: asks were dropped because the step between "the owner said it" and "a row
#    exists in the ask ledger" was left to memory. A prompt that was an instruction, answered in
#    passing, then crowded out by the next prompt, never became a row, so nothing could ever
#    surface it. This closes that step mechanically:
#
#      1. a UserPromptSubmit hook (hooks/prompt_guard.sh capture) writes one row per genuine
#         owner prompt, state `untriaged`;
#      2. a Stop hook (hooks/prompt_guard.sh gate) refuses to let the turn end while this
#         session has untriaged prompts, naming the two ways to resolve each:
#            aimail prompt triage <p####> --ask <k####>        (the prompt created / maps to this ask)
#            aimail prompt triage <p####> --no-ask "<reason>"  (an explicit, recorded "no ask")
#         `aimail ask add … --prompt <p####>` does the add and the triage in one step.
#
# What is NOT an owner prompt: harness notifications, poller wakes, task events and reminders are
# machine text that arrives in the same channel. AIMAIL_AUTOMATED_PROMPT_RE (extended regex over the
# start of the text) names them; those are never recorded. A false negative here only means a
# machine line gets a triage row; the gate never blocks on anything but recorded rows.
#
# The ledger is a flock'd TSV under $STATE_DIR (prompts.tsv). Columns (tab-separated):
#  1 id (p####)  2 captured_at (epoch)  3 session  4 state (untriaged|ask|no_ask)
#  5 ref (ask id, or the no-ask reason)  6 triaged_at  7 triaged_by  8 text (first 400 chars)
#
# Generic by design: no owner, company, project or seat names live in this file.

PROMPT_FILE() { echo "$STATE_DIR/prompts.tsv"; }
PROMPT_LOCK() { echo "$STATE_DIR/prompts.lock"; }
PROMPT_SEQ()  { echo "$STATE_DIR/prompts.seq"; }

_PROMPT_DEFAULT_AUTOMATED_RE='^[[:space:]]*(\[SYSTEM NOTIFICATION|<task-notification|<system-reminder|WAKE=|<command-name>|<local-command)'

_prompt_clean() { printf '%s' "$1" | tr '\t\n\r' '   '; }

_prompt_locked() {
  ensure_dirs
  local lockf; lockf="$(PROMPT_LOCK)"
  (
    flock -w "${AIMAIL_PROMPT_LOCK_WAIT:-10}" 9 || die "prompt: could not take the prompt ledger lock in ${AIMAIL_PROMPT_LOCK_WAIT:-10}s"
    "$@"
  ) 9>"$lockf"
}

_prompt_ensure_file() {
  local f; f="$(PROMPT_FILE)"
  [[ -f "$f" ]] || printf 'id\tcaptured_at\tsession\tstate\tref\ttriaged_at\ttriaged_by\ttext\n' > "$f"
}

_prompt_rows() { _prompt_ensure_file; tail -n +2 "$(PROMPT_FILE)"; }
_prompt_row()  { _prompt_rows | awk -F'\t' -v id="$1" '$1==id {print; exit}'; }
_prompt_field() { printf '%s\n' "$1" | cut -f"$2"; }

_prompt_next_id() {
  local seqf n; seqf="$(PROMPT_SEQ)"
  n="$(cat "$seqf" 2>/dev/null || echo 0)"; n=$((n+1)); printf '%s' "$n" > "$seqf"
  printf 'p%04d' "$n"
}

prompt_exists() { [[ -n "$(_prompt_row "$1")" ]]; }

prompt_is_automated() {  # <text> -> rc 0 when the text is machine-generated, not the owner's
  local text="$1" re="${AIMAIL_AUTOMATED_PROMPT_RE:-$_PROMPT_DEFAULT_AUTOMATED_RE}"
  [[ -z "${text//[[:space:]]/}" ]] && return 0
  [[ "$text" =~ $re ]]
}

_prompt_add_locked() {
  local session="$1" text="$2" id
  _prompt_ensure_file
  id="$(_prompt_next_id)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(now_epoch)" "$session" "untriaged" "" 0 "" \
    "$(_prompt_clean "${text:0:400}")" >> "$(PROMPT_FILE)"
  printf '%s\n' "$id"
}

# prompt_capture [--session <id>] [--text <text>]  -- or the UserPromptSubmit JSON on stdin
# (fields session_id, prompt). Prints the new id, or nothing when the text is automated.
prompt_capture() {
  local session="" text="" have_text=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) session="${2:-}"; shift 2 ;;
      --text) text="${2:-}"; have_text=1; shift 2 ;;
      *) refused "prompt capture: unknown argument '$1'" ;;
    esac
  done
  if (( ! have_text )); then
    local json; json="$(cat 2>/dev/null || true)"
    local parsed
    parsed="$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
sid = str(d.get("session_id") or "")
txt = d.get("prompt")
if txt is None:
    txt = d.get("user_prompt") or ""
sys.stdout.write(sid + "\x1f" + str(txt))
' 2>/dev/null || true)"
    [[ -z "$session" ]] && session="${parsed%%$'\x1f'*}"
    text="${parsed#*$'\x1f'}"
  fi
  [[ -n "$session" ]] || session="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  prompt_is_automated "$text" && return 0
  _prompt_locked _prompt_add_locked "$session" "$text"
}

_prompt_triage_locked() {
  local id="$1" state="$2" ref="$3" by="$4" f tmp row cur
  row="$(_prompt_row "$id")"; [[ -n "$row" ]] || refused "prompt triage: no such prompt '$id' (aimail prompt list)"
  cur="$(_prompt_field "$row" 4)"
  [[ "$cur" == "untriaged" ]] || refused "prompt triage: '$id' is already triaged ($cur: $(_prompt_field "$row" 5))."
  f="$(PROMPT_FILE)"; tmp="$f.tmp.$$"
  awk -F'\t' -v OFS='\t' -v id="$id" -v st="$state" -v ref="$(_prompt_clean "$ref")" -v by="$(_prompt_clean "$by")" -v now="$(now_epoch)" \
      'NR==1 {print; next} $1==id {$4=st; $5=ref; $6=now; $7=by} {print}' "$f" > "$tmp" && mv -f "$tmp" "$f"
}

# prompt_triage <p####> (--ask <k####> | --no-ask "<reason>") [--by <who>]
prompt_triage() {
  local id="${1:-}"; shift || true
  local ask="" reason="" by="${AIMAIL_SEAT:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ask) ask="${2:-}"; shift 2 ;;
      --no-ask) reason="${2:-}"; shift 2 ;;
      --by) by="${2:-}"; shift 2 ;;
      *) refused "prompt triage: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$id" && ( -n "$ask" || -n "$reason" ) ]] || refused \
    "usage: aimail prompt triage <p####> --ask <k####>  |  --no-ask \"<reason>\"  [--by <seat>]" \
    "  Every owner prompt ends in exactly one of: a ledger ask, or a recorded reason that it made none."
  [[ -z "$ask" || -z "$reason" ]] || refused "prompt triage: give --ask OR --no-ask, not both."
  if [[ -n "$ask" ]]; then
    # the ask must exist in the ledger -- an id typed from memory is not a triage
    source "$(dirname "${BASH_SOURCE[0]}")/ask.sh"
    [[ -n "$(_ask_row "$ask")" ]] || refused "prompt triage: no such ask '$ask' in the ledger (aimail ask list --all)."
    _prompt_locked _prompt_triage_locked "$id" "ask" "$ask" "$by" || exit $?
    ok "prompt $id triaged -> ask $ask"
  else
    # a reason of a few characters ("n/a", "ok") records nothing: say what the prompt was
    (( ${#reason} >= 8 )) || refused "prompt triage: --no-ask needs a real reason (8+ characters), e.g. \"answered the question in-turn, no work\"."
    _prompt_locked _prompt_triage_locked "$id" "no_ask" "$reason" "$by" || exit $?
    ok "prompt $id triaged -> no ask: $(_prompt_clean "$reason")"
  fi
}

prompt_list() {
  local only_untriaged=0 session=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --untriaged) only_untriaged=1; shift ;;
      --session) session="${2:-}"; shift 2 ;;
      *) refused "prompt list: unknown argument '$1'" ;;
    esac
  done
  local row out="" n=0
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    [[ -n "$session" && "$(_prompt_field "$row" 3)" != "$session" ]] && continue
    (( only_untriaged )) && [[ "$(_prompt_field "$row" 4)" != "untriaged" ]] && continue
    n=$((n+1))
    out="${out}$(printf '%-6s %-10s %-6s %s  %s' "$(_prompt_field "$row" 1)" "$(_prompt_field "$row" 4)" \
      "$(_prompt_field "$row" 5 | head -c 12)" "$(date -d "@$(_prompt_field "$row" 2)" '+%m-%d %H:%M' 2>/dev/null)" \
      "$(_prompt_field "$row" 8 | head -c 100)")"$'\n'
  done < <(_prompt_rows)
  (( n )) || { info "(no prompts$( (( only_untriaged )) && printf ' untriaged' ))"; return 0; }
  printf '%s' "$out"
}

prompt_untriaged_count() {  # [<session>] -> count of untriaged rows (all sessions when none given)
  local session="${1:-}"
  _prompt_rows | awk -F'\t' -v s="$session" '$4=="untriaged" && (s=="" || $3==s) {n++} END {print n+0}'
}

prompt_untriaged_ids() {  # <session> -> ids, one per line
  _prompt_rows | awk -F'\t' -v s="$1" '$4=="untriaged" && $3==s {print $1}'
}

prompt_dispatch() {
  trap '' PIPE
  local sub="${1:-}"; shift || true
  case "$sub" in
    capture) prompt_capture "$@" ;;
    triage)  prompt_triage "$@" ;;
    list)    prompt_list "$@" ;;
    count)   prompt_untriaged_count "${1:-}" ;;
    *) refused "usage: aimail prompt capture|triage|list|count …" \
         "  capture  [--session <id> --text <text>]   (or the UserPromptSubmit JSON on stdin)" \
         "  triage   <p####> --ask <k####> | --no-ask \"<reason>\"" \
         "  list     [--untriaged] [--session <id>]" ;;
  esac
}
