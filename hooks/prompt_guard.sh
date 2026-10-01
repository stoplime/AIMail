#!/usr/bin/env bash
# hooks/prompt_guard.sh — the two hooks of the PROMPT LEDGER (lib/prompts.sh).
#
#   prompt_guard.sh capture   UserPromptSubmit hook. Records the owner's prompt as `untriaged`
#                             and tells the session its id in one context line. Never blocks.
#   prompt_guard.sh gate      Stop hook. Refuses to end the turn while THIS session still has an
#                             untriaged prompt: each needs `aimail prompt triage <id> --ask <k####>`
#                             or `--no-ask "<reason>"`.
#
# Wire both in the project's .claude/settings.json (see README "Prompt ledger"):
#   hooks.UserPromptSubmit[].hooks[] = {"type":"command","command":"bash /path/to/hooks/prompt_guard.sh capture"}
#   hooks.Stop[].hooks[]             = {"type":"command","command":"bash /path/to/hooks/prompt_guard.sh gate"}
#
# ⚠⚠ FAIL OPEN, EVERYWHERE (same law as hooks/stop_guard.sh). capture exits 0 whatever happens:
#    a failure degrades to "this prompt was not recorded", never to a blocked or altered prompt.
#    gate blocks only on a positive finding (an untriaged row for this very session), allows the
#    stop when the harness marks it a repeat (`stop_hook_active`: at most one block per stop
#    attempt, so a seat that cannot triage can never be trapped in a loop), and allows on any error.
#    A block does not lose the prompt: it stays `untriaged`, shows in `aimail ask owner-digest`,
#    and the NEXT stop attempt blocks again.
# Kill switches (a human's decision): AIMAIL_PROMPT_CAPTURE=0, AIMAIL_PROMPT_GATE=0.

set -u
_H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A failing source must not make the hook noisy or blocking.
source "$_H/../lib/core.sh" 2>/dev/null || exit 0
source "$_H/../lib/registry.sh" 2>/dev/null || exit 0
source "$_H/../lib/prompts.sh" 2>/dev/null || exit 0
set +e

GATE_LOG() { echo "$STATE_DIR/prompt_gate.log"; }
_glog() { printf '%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "$1" "$2" >> "$(GATE_LOG)" 2>/dev/null; }

_json_field() {  # <json> <field> -> value or ""
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
v = d.get(sys.argv[1])
sys.stdout.write("" if v is None else str(v))
' "$2" 2>/dev/null
}

case "${1:-}" in
  capture)
    [[ "${AIMAIL_PROMPT_CAPTURE:-1}" == "0" ]] && exit 0
    payload="$(cat 2>/dev/null)"
    sid="$(_json_field "$payload" session_id)"
    [[ -n "$sid" ]] || sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
    ensure_dirs 2>/dev/null
    pid="$(printf '%s' "$payload" | prompt_capture 2>/dev/null | tail -1)"
    if [[ "$pid" =~ ^p[0-9]+$ && "${AIMAIL_PROMPT_CAPTURE_QUIET:-0}" != "1" ]]; then
      printf 'Owner prompt %s recorded. Before this turn ends, resolve it: aimail prompt triage %s --ask <k####> (or aimail ask add … --prompt %s) | --no-ask "<reason>".\n' "$pid" "$pid" "$pid"
    fi
    exit 0 ;;

  gate)
    [[ "${AIMAIL_PROMPT_GATE:-1}" == "0" ]] && exit 0
    payload="$(cat 2>/dev/null)"
    [[ "$(_json_field "$payload" stop_hook_active)" =~ ^([Tt]rue|1)$ ]] && { _glog "-" "allow-stop-hook-active-loop-breaker"; exit 0; }
    sid="$(_json_field "$payload" session_id)"
    [[ -n "$sid" ]] || sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    [[ -n "$sid" ]] || { _glog "-" "allow-no-session"; exit 0; }
    ids="$(prompt_untriaged_ids "$sid" 2>/dev/null)"
    if [[ -z "$ids" ]]; then _glog "$sid" "allow-all-triaged"; exit 0; fi
    _glog "$sid" "BLOCK-untriaged:$(printf '%s' "$ids" | tr '\n' ',')"
    {
      echo "⛔ An owner prompt in this session has not been triaged. Ending the turn now could drop it."
      while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        echo "   $id  $(_prompt_field "$(_prompt_row "$id")" 8 | head -c 120)"
        echo "      ▶ aimail prompt triage $id --ask <k####>          (it created or maps to this ledger ask)"
        echo "        aimail ask add --owner <seat> --quote \"…\" --next \"…\" --check '…' --prompt $id   (new ask, triaged in one step)"
        echo "        aimail prompt triage $id --no-ask \"<reason it made no ask>\""
      done <<<"$ids"
    } >&2
    exit 2 ;;

  *) echo "usage: prompt_guard.sh capture|gate" >&2; exit 0 ;;
esac
