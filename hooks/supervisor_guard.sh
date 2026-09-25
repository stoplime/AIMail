#!/usr/bin/env bash
# hooks/supervisor_guard.sh — a Stop hook for the SUPERVISOR seat only: the turn cannot end
# unless the supervisor has actually looked at the fleet and the budget pool recently.
#
# ⛔ THE FAILURE THIS CLOSES (2026-09-21, the owner's words: "I don't want apologies and I
#   don't want promises, I need real mechanisms that force a correction"): the supervisor
#   seat defaulted to reactive, single-thread focus and let an account imbalance and idle
#   capacity build up unnoticed — twice in one day, and three times before that with a
#   written "lesson" each time that did not stick. poller_guard.sh already proved the
#   shape that works: not a reminder, a Stop hook that refuses to let a turn end until the
#   thing is done. This is that hook for "did I look".
#
# MECHANISM: `aimail fleet`, `aimail budget pool` and `aimail budget balance` touch
#   $STATE_DIR/supervisor_scan when they are run from the supervisor's own session (the
#   session is mapped to its seat by stop_guard.sh's registration, so no second registry).
#   On Stop, this hook allows the turn to end iff that marker is younger than
#   AIMAIL_SUPERVISOR_SCAN_MAX_MIN (default 30) minutes; otherwise it BLOCKS (exit 2) and
#   prints the two commands. Any other seat's session: allow, always. `stop_hook_active`
#   (the platform's loop-breaker) is honoured exactly as stop_guard.sh does.
#
# WIRING: add to the supervisor's settings.json Stop hooks, additively, next to stop_guard:
#   {"type": "command", "command": "bash /path/to/AIMail/hooks/supervisor_guard.sh hook"}
#   Registration is stop_guard.sh's (`stop_guard.sh register <seat>`); nothing extra.
#   `supervisor_guard.sh status` prints the current verdict without ending anything.
#   AIMAIL_SUPERVISOR (default assistant) names the seat this applies to.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"

SCAN_MARKER() { echo "$STATE_DIR/supervisor_scan"; }
LOGF="$STATE_DIR/supervisor_guard.log"
_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"; }
_seat_for_session() { local f="$STATE_DIR/stopguard/session.$(_sid)"; [[ -f "$f" ]] && head -1 "$f" | tr -d '[:space:]'; }
_log() { mkdir -p "$STATE_DIR"; printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "${1:-?}" "$(_sid)" "${2:-?}" >> "$LOGF"; }

_age_min() { local m; m="$(SCAN_MARKER)"; [[ -f "$m" ]] || { echo ""; return; }; echo $(( ( $(now_epoch) - $(stat -c %Y "$m") ) / 60 )); }

case "${1:-}" in
  hook)
    hook_json="$(cat 2>/dev/null || true)"
    seat="$(_seat_for_session)"
    active="$(printf '%s' "$hook_json" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print("1" if d.get("stop_hook_active") else "0")
' 2>/dev/null || echo 0)"
    if [[ "$active" == "1" ]]; then _log "${seat:-unmapped}" "allow-stop-hook-active-loop-breaker"; exit 0; fi
    sup="${AIMAIL_SUPERVISOR:-assistant}"
    [[ -z "$seat" ]] && { _log "unmapped" "allow-unmapped"; exit 0; }
    [[ "$seat" != "$sup" ]] && { _log "$seat" "allow-not-supervisor"; exit 0; }
    maxm="${AIMAIL_SUPERVISOR_SCAN_MAX_MIN:-30}"
    age="$(_age_min)"
    if [[ -n "$age" ]] && (( age <= maxm )); then _log "$seat" "allow-scan-${age}m"; exit 0; fi
    _log "$seat" "BLOCK-no-recent-scan-${age:-never}"
    echo "⛔ You have not looked at the fleet or the budget pool in the last ${maxm} min (${age:-never} min ago)." >&2
    echo "   A turn does not end for the supervisor seat until both have been read this stretch:" >&2
    echo "   ▶ aimail fleet            (who is idle, who is reachable, what is queued)" >&2
    echo "   ▶ aimail budget balance   (account pressure and what the balancer would move)" >&2
    echo "   Then check TODO.md / gateclaim.sh --list for unowned real backlog before ending the turn." >&2
    exit 2 ;;
  touch)
    # called by bin/aimail when a scan command runs from the supervisor's session
    mkdir -p "$STATE_DIR"; touch "$(SCAN_MARKER)"; exit 0 ;;
  status)
    seat="$(_seat_for_session)"; age="$(_age_min)"
    printf 'supervisor seat: %s   this session: %s (%s)   scan marker: %s\n' "${AIMAIL_SUPERVISOR:-assistant}" "${seat:-unmapped}" "$(_sid)" "${age:+${age} min ago}${age:-never}"
    [[ -f "$LOGF" ]] && { echo "last decisions:"; tail -3 "$LOGF"; }
    exit 0 ;;
  selftest)
    tmp="$(mktemp -d)"; export AIMAIL_ROOT="$tmp" AIMAIL_CONFIG=/dev/null CLAUDE_CODE_SESSION_ID=selftest AIMAIL_SUPERVISOR=assistant
    STATE_DIR="$tmp/state"; mkdir -p "$STATE_DIR/stopguard"; LOGF="$STATE_DIR/supervisor_guard.log"
    pass=0; fail=0
    _arm() { local name="$1" want="$2" json="${3:-{\}}"; local rc=0
      printf '%s' "$json" | bash "$0" hook >/dev/null 2>&1 || rc=$?
      if [[ "$rc" == "$want" ]]; then pass=$((pass+1)); echo "  ✔ $name (rc=$rc)"; else fail=$((fail+1)); echo "  ✖ $name got rc=$rc want $want"; fi; }
    _arm "unmapped session -> allow" 0
    printf 'audit\n' > "$STATE_DIR/stopguard/session.selftest"; _arm "another seat -> allow" 0
    printf 'assistant\n' > "$STATE_DIR/stopguard/session.selftest"; _arm "supervisor, no marker -> BLOCK" 2
    touch "$STATE_DIR/supervisor_scan"; _arm "supervisor, fresh marker -> allow" 0
    touch -d '2 hours ago' "$STATE_DIR/supervisor_scan"; _arm "supervisor, stale marker -> BLOCK" 2
    _arm "stop_hook_active honoured -> allow" 0 '{"stop_hook_active": true}'
    # ── END-TO-END WIRING (2026-09-21, code-review's gap on 501bf1b): the five arms above
    #   `touch` the marker BY HAND, so they would all still pass if bin/aimail stopped calling
    #   supervisor_scan_touch, or if core.sh and this hook disagreed on the marker's path or
    #   name -- and the supervisor seat would then be wedged on every Stop with no test red.
    #   These two arms drive the REAL `bin/aimail fleet` (not a stub, not a manual touch) in
    #   this same temp root and read the marker the hook itself reads. `fleet` may exit non-zero
    #   here (no seats registered in the temp root) -- irrelevant: the touch precedes the report.
    printf 'assistant\n' > "$STATE_DIR/stopguard/session.selftest"; rm -f "$STATE_DIR/supervisor_scan"
    _arm "wiring: supervisor, marker removed -> BLOCK (precondition)" 2
    bash "$REPO/bin/aimail" fleet >/dev/null 2>&1 || true
    _arm "wiring: real \`aimail fleet\` from the supervisor's session -> hook ALLOWS" 0
    printf 'audit\n' > "$STATE_DIR/stopguard/session.selftest"; rm -f "$STATE_DIR/supervisor_scan"
    bash "$REPO/bin/aimail" fleet >/dev/null 2>&1 || true
    if [[ ! -e "$STATE_DIR/supervisor_scan" ]]; then pass=$((pass+1)); echo "  ✔ wiring: real \`aimail fleet\` from a NON-supervisor session leaves no marker (touch is gated)"
    else fail=$((fail+1)); echo "  ✖ wiring: a non-supervisor session's \`aimail fleet\` wrote the marker -- the gate in supervisor_scan_touch is gone"; fi
    # ── CONFIGURABILITY (code-review 19087f6b on f8d0bcb, fable #276): with AIMAIL_SUPERVISOR set to
    #   the code's own default ("assistant"), the wiring arms above cannot tell "the variable is read"
    #   from "the name is hardcoded" -- falsified: a literal "assistant" in core.sh's comparison left
    #   9/9 green. These three arms use a NON-default name and exercise BOTH readers of the variable:
    #   core.sh's touch gate (arm 10 needs the marker written for 'main') and this hook's own seat check
    #   (arm 12 needs a session mapped 'assistant' to read as NOT the supervisor).
    export AIMAIL_SUPERVISOR=main
    printf 'main\n' > "$STATE_DIR/stopguard/session.selftest"; rm -f "$STATE_DIR/supervisor_scan"
    bash "$REPO/bin/aimail" fleet >/dev/null 2>&1 || true
    _arm "configurable: AIMAIL_SUPERVISOR=main, session mapped 'main', real \`aimail fleet\` -> hook ALLOWS (touch gate reads the variable)" 0
    printf 'assistant\n' > "$STATE_DIR/stopguard/session.selftest"; rm -f "$STATE_DIR/supervisor_scan"
    bash "$REPO/bin/aimail" fleet >/dev/null 2>&1 || true
    if [[ ! -e "$STATE_DIR/supervisor_scan" ]]; then pass=$((pass+1)); echo "  ✔ configurable: under AIMAIL_SUPERVISOR=main a session mapped 'assistant' writes no marker (the default is not hardcoded in the gate)"
    else fail=$((fail+1)); echo "  ✖ configurable: a session mapped 'assistant' wrote the marker under AIMAIL_SUPERVISOR=main -- supervisor_scan_touch hardcodes the default"; fi
    _arm "configurable: under AIMAIL_SUPERVISOR=main a session mapped 'assistant' is NOT the supervisor -> hook ALLOWS (hook reads the variable)" 0
    export AIMAIL_SUPERVISOR=assistant
    rm -rf "$tmp"; echo "supervisor_guard selftest: $pass passed, $fail failed"; (( fail == 0 )) ;;
  *) refused "unknown supervisor_guard command: '${1:-}'" "Try: hook | touch | status | selftest" ;;
esac
