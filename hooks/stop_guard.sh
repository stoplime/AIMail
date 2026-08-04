#!/usr/bin/env bash
# stop_guard.sh — a Stop hook that will not let a session end its turn while it
# has no live poller, and that logs every decision as an EVENT.
#
# ═══ TWO JOBS, AND THE SECOND IS THE UNDERRATED ONE ═══════════════════════════
#
# 1. THE GUARD. A session with no poller is unreachable: mail is the only channel
#    between seats and the poller is what delivers it. Detection after the fact
#    finds this 20-40 minutes late. This finds it at the only moment it can still
#    be fixed for free — as the session tries to stop.
#
# 2. THE EVENT LOG, which is what `aimail fleet` actually reads. The hook fires
#    at exactly the moment a session ENDS A TURN, so its log is a precise record
#    of "this seat stopped" — and that is what "idle" means. A process sample can
#    never answer "when did this last stop"; an event log answers only that.
#
# ⚠⚠ FAIL OPEN, EVERYWHERE. Every unknown allows the stop. The asymmetry is
#    decisive: a missed block costs the status quo we already live with, while a
#    false block traps a session — possibly a human's own — in a stop/continue
#    loop it cannot escape. A guard wired into a shared settings file must never
#    be able to do that.
#
# USAGE (CLI)
#   stop_guard.sh register <seat>   map THIS session to a seat (exact, no guessing)
#   stop_guard.sh on | off          global switch
#   stop_guard.sh done [seat]       "genuinely finished" → exempt from the block
#   stop_guard.sh resume [seat]     undo `done`
#   stop_guard.sh status            what is armed, who is mapped, who is exempt
#   stop_guard.sh selftest          prove it BLOCKS and prove it FAILS OPEN
#
# USAGE (hook) — reads the Stop-hook JSON on stdin. Wire it as:
#   .claude/settings.json → hooks.Stop[].hooks[] =
#     {"type":"command","command":"bash /path/to/hooks/stop_guard.sh hook"}

set -uo pipefail
_H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_H/../lib/core.sh"
source "$_H/../lib/registry.sh"
source "$_H/../lib/fleet.sh"

GUARD_DIR="$STATE_DIR/stopguard"
mkdir -p "$GUARD_DIR" "$STATE_DIR" 2>/dev/null

_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"; }
_seat_for_session() {
  local f="$GUARD_DIR/session.$(_sid)"
  [[ -f "$f" ]] && cat "$f" || echo ""
}

# _log — append one event. TSV, so a consumer reads it with awk -F'\t'.
_log() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(now_iso)" "${1:-?}" "$(_sid)" "$2" >> "$(STOPLOG)"
}

case "${1:-hook}" in
  register)
    seat="$(seat_resolve "${2:?usage: stop_guard.sh register <seat>}")" || exit $?
    printf '%s' "$seat" > "$GUARD_DIR/session.$(_sid)"
    ok "session $(_sid) → seat '$seat'"; exit 0 ;;
  on)   : > "$GUARD_DIR/enabled"; ok "stop guard ARMED globally"; exit 0 ;;
  off)  rm -f "$GUARD_DIR/enabled"; ok "stop guard DISARMED globally"; exit 0 ;;
  done)
    seat="${2:-$(_seat_for_session)}"
    [[ -n "$seat" ]] || die "no seat: register first, or pass one"
    : > "$GUARD_DIR/exempt.$seat"; ok "'$seat' exempt — it may stop without a poller"; exit 0 ;;
  resume)
    seat="${2:-$(_seat_for_session)}"
    rm -f "$GUARD_DIR/exempt.$seat"; ok "'$seat' no longer exempt"; exit 0 ;;
  status)
    info "global: $([[ -f "$GUARD_DIR/enabled" ]] && echo ARMED || echo disarmed)"
    _s="$(_seat_for_session)"; info "this session: $(_sid) → ${_s:-<unmapped>}"
    info "exempt seats: $(ls "$GUARD_DIR" 2>/dev/null | sed -n 's/^exempt\.//p' | tr '\n' ' ')"
    info "event log: $(STOPLOG) ($(wc -l < "$(STOPLOG)" 2>/dev/null || echo 0) events)"
    exit 0 ;;

  selftest)
    # ⛔⛔ A CHECK THAT ISN'T RUNNING LOOKS EXACTLY LIKE A CHECK THAT PASSES.
    #    The first version of this selftest set GUARD_DIR as a shell variable and
    #    then invoked the hook as a SUBPROCESS, which re-derived GUARD_DIR from
    #    AIMAIL_ROOT. The two paths disagreed, so every arm fell through to
    #    `allow-disarmed` and returned 0 — the blocking arm reported FAILED and
    #    **the two "allow" arms reported PASS while proving nothing at all.**
    #    ⇒ An allow-arm that passes because the guard never ran is the most
    #      dangerous kind of green: it certifies a guard that is switched off.
    #      Every arm below now asserts the DECISION it logged, not just the exit
    #      code, so an arm cannot pass via a path it did not intend to take.
    tmp="$(mktemp -d)"
    export AIMAIL_ROOT="$tmp" AIMAIL_CONFIG=/dev/null CLAUDE_CODE_SESSION_ID=selftest
    G="$tmp/state/stopguard"; mkdir -p "$G"
    "$_H/../bin/aimail" seat add testseat "selftest" >/dev/null 2>&1
    printf 'testseat' > "$G/session.selftest"

    _arm() { # _arm <name> <want-rc> <want-decision>
      local name="$1" wrc="$2" wdec="$3" rc dec
      : > "$tmp/state/stophook.log"
      echo '{}' | bash "$_H/stop_guard.sh" hook >/dev/null 2>&1; rc=$?
      dec="$(awk -F'\t' 'END{print $5}' "$tmp/state/stophook.log" 2>/dev/null)"
      if [[ "$rc" == "$wrc" && "$dec" == "$wdec" ]]; then ok "$name (rc=$rc decision=$dec)"
      else warn "$name FAILED — got rc=$rc decision='$dec', wanted rc=$wrc decision=$wdec"; fi
    }

    : > "$G/enabled"
    _arm "ARM 1 blocks a stop with no poller"     2 "BLOCK-no-poller"

    # ② POSITIVE CONTROL IN THE FORM THE GUARD CLAIMS TO DETECT: a genuinely
    #    armed poller must be ALLOWED. Without this arm, a guard that blocks
    #    unconditionally would pass every other test here.
    mkdir -p "$tmp/state/poller"
    printf 'pid\t%s\nbeat\t%s\nstarted\t%s\n' "$$" "$(now_epoch)" "$(now_epoch)" \
      > "$tmp/state/poller/testseat.hb"
    _arm "ARM 2 allows a seat with a live poller" 0 "allow-poller-armed"
    rm -f "$tmp/state/poller/testseat.hb"

    : > "$G/exempt.testseat"
    _arm "ARM 3 allows an exempt seat"            0 "allow-exempt"
    rm -f "$G/exempt.testseat"

    rm -f "$G/enabled"
    _arm "ARM 4 allows when globally disarmed"    0 "allow-disarmed"

    : > "$G/enabled"; rm -f "$G/session.selftest"
    _arm "ARM 5 fails open on an unmapped session" 0 "allow-unmapped"

    rm -rf "$tmp"; exit 0 ;;

  hook)
    cat >/dev/null 2>&1 || true   # drain the hook JSON; we key on env, not its fields
    seat="$(_seat_for_session)"

    # Fail open: unmapped session. We do not guess which seat this is — guessing
    # is how a block lands on the wrong session.
    [[ -z "$seat" ]] && { _log "unmapped" "allow-unmapped"; exit 0; }
    [[ -f "$GUARD_DIR/enabled" ]] || { _log "$seat" "allow-disarmed"; exit 0; }
    [[ -f "$GUARD_DIR/exempt.$seat" ]] && { _log "$seat" "allow-exempt"; exit 0; }

    st="$(poller_state "$seat" | cut -f1)"
    case "$st" in
      ARMED)
        _log "$seat" "allow-poller-armed"; exit 0 ;;
      RE-ARMING)
        # ⚠ The poller fired THIS turn and the seat has not re-armed yet. That is
        #   the normal shape of a wake, not a fault — but stopping now would end
        #   the turn unreachable, so this is exactly when the reminder is worth
        #   its cost.
        _log "$seat" "BLOCK-rearm-pending"
        echo "⛔ Your poller fired this turn and you have not re-armed." >&2
        echo "   Ending the turn now leaves you unreachable — mail cannot wake you." >&2
        echo "   ▶ aimail poll $seat   (run_in_background=true)" >&2
        echo "   If you are genuinely finished: aimail-stop-guard done $seat" >&2
        exit 2 ;;
      *)
        _log "$seat" "BLOCK-no-poller"
        echo "⛔ You have no live poller ($st). You would be unreachable." >&2
        echo "   ▶ aimail poll $seat   (run_in_background=true)" >&2
        echo "   If you are genuinely finished: aimail-stop-guard done $seat" >&2
        exit 2 ;;
    esac ;;

  *) refused "unknown stop_guard command: '$1'" "Try: register | on | off | done | resume | status | selftest | hook" ;;
esac
