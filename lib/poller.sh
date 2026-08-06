# shellcheck shell=bash
# poller.sh — the wake loop. Exits when something needs the session's attention.
#
# A session cannot block on a socket, so it arms this as a harness-tracked
# background task. THE EXIT IS THE WAKE: the harness re-invokes the session when
# the background task completes.
#
# ⛔⛔ AN EXIT IS THEREFORE AMBIGUOUS BY CONSTRUCTION, and this is the single most
#    expensive property of the design: a poller that exits BECAUSE IT FOUND MAIL
#    and a poller that DIED look identical to the harness — both report
#    "completed". Every completion means two things at once, "you have mail" and
#    "you no longer have a poller", and the second is invisible in the
#    notification text. Seats have gone blind by reading a completion as
#    "nothing to do".
# ⇒ Every exit path here prints the re-arm obligation. Putting it in the wake
#   text is cheaper than each seat remembering it.

# ⛔⛔ FI-19 — EDITING A SCRIPT WHILE IT RUNS CORRUPTS IT. Bash reads a script
#    INCREMENTALLY and resumes at a byte offset, so bytes written at that offset
#    are executed as if they were the remainder of the original file. Measured:
#      in-place '>' during execution  → "line 5: unexpected EOF", exit 2
#      temp + 'mv' during execution   → ran to completion (new inode)
#    ⚠ And the failure is NOT reliably loud: a resume offset that happens to
#      parse can let a long-running loop skip a step silently.
# ⇒ The poller copies its own code to a private temp directory and re-execs from
#   there. It is then immune BY CONSTRUCTION rather than by everyone remembering
#   to install with `mv`. The previous system's rule — "wait until pgrep is
#   empty" — could never be satisfied, because pollers run permanently; a block
#   that can never clear is a permanent block wearing a safety check's name.
_poller_reexec_private() {
  [[ -n "${AIMAIL_PRIVATE_COPY:-}" ]] && return 0
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/aimail-poll.XXXXXX")" || return 0
  cp -r "$AIMAIL_HOME/bin" "$AIMAIL_HOME/lib" "$tmp/" 2>/dev/null || { rm -rf "$tmp"; return 0; }
  export AIMAIL_PRIVATE_COPY="$tmp" AIMAIL_CONFIG="${AIMAIL_CONFIG:-$AIMAIL_HOME/etc/aimail.conf}"
  # The private copy is removed when this process exits, however it exits.
  trap 'rm -rf "$tmp"' EXIT INT TERM
  exec "$tmp/bin/aimail" poll "$@"
}

_rearm_notice() {
  local seat="$1"
  echo
  echo "⚠ THIS POLLER HAS NOW EXITED — you no longer have one."
  echo "   An exit is the WAKE, not a failure. But until you re-arm, you are unreachable."
  echo "   ▶ aimail poll $seat        (run_in_background=true, absolute path)"
}

poller_run() {
  local seat_arg="${1:-}"
  [[ -n "$seat_arg" ]] || refused "usage: aimail poll <seat>"

  # ⛔ RESOLVE THE SEAT BEFORE LOOPING. An unvalidated name points the loop at a
  #    directory that does not exist; with no match the loop simply runs forever
  #    and NEVER FIRES — a silent no-poller that is indistinguishable from a
  #    quiet inbox. The one failure mode this must never have is "running but
  #    cannot wake you."
  local seat; seat="$(seat_resolve "$seat_arg")" || exit $?

  _poller_reexec_private "$seat"

  local interval="${AIMAIL_POLL_INTERVAL:-5}"
  local maxb="${POLLER_DRAIN_MAXB:-60000}"
  mkdir -p "$MAIL_DIR/$seat/unacked"

  # ⭐⭐ THE HEARTBEAT, AND WHY IT RECORDS A *REASON*: finished, killed and
  #    crashed all leave identical evidence — no process. A supervisor sampling
  #    `ps` therefore cannot tell a poller that DID ITS JOB from one that was
  #    killed, and the predecessor reported the second as the first for 25
  #    minutes while a seat sat unreachable.
  # ⇒ Every deliberate exit below writes `exit_reason`. An absent exit record
  #   with no live process is then a POSITIVE finding — it means the poller did
  #   not stop on purpose — instead of an ambiguity. A completed run must leave
  #   a verdict artifact, not merely stop.
  source "$AIMAIL_LIB/fleet.sh"
  hb_start "$seat"
  # Covers the paths a trap can see. SIGKILL is deliberately NOT trappable, and
  # that is exactly the case the missing-exit-record rule is designed to catch.
  trap 'hb_exit "$seat" signal; exit 143' INT TERM

  echo "$(instrument_id) — polling '$seat' every ${interval}s"
  echo "state: $AIMAIL_ROOT"

  while true; do
    # ─── PARK, never exit, while a throttle flag is set ───────────────────────
    # ⛔⛔ A THROTTLE STOPS *WORK*, NOT *POLLERS*. NEVER DISARM TO SAVE TOKENS.
    #    An armed poller is a sleeping shell and costs ZERO tokens; tokens are
    #    spent only when it FIRES. So the thing to suppress under a budget cap
    #    is the WAKE EVENT, never the wake CAPABILITY.
    # ⭐ MEASURED COST OF GETTING THIS BACKWARDS: on one night a coordinator told
    #    every seat to disarm at the cap. The window reopened at 06:24 and the
    #    ramp had nothing left to wake; three seats never woke at all and it took
    #    a human 3h24m later to end it. A PARKED poller costs nothing and wakes
    #    itself. A DISARMED poller costs nothing and NEVER WAKES. They are
    #    identical on a token bill and opposite in recoverability.
    # ⭐ AR-09 — write the PARK heartbeat every cycle spent here, on ITS OWN key
    #    (`hb_beat` is deliberately NOT called: a parked poller must not look
    #    busy). Without this, `poller_state` had only a staling `beat` to judge
    #    health by, and a correctly parked poller reads WEDGED after `limit`
    #    seconds — the dashboard then tells a human to kill a healthy process.
    if [[ -f "$STATE_DIR/throttled" ]]; then
      hb_park "$seat"
      sleep "$interval"; continue
    fi

    # ─── Ramp: the throttle's own end condition ──────────────────────────────
    if [[ -f "$STATE_DIR/ramp_at" ]]; then
      local rat; rat="$(awk -F'\t' '$1=="at"{print $2}' "$STATE_DIR/ramp_at" 2>/dev/null)"
      if [[ "$rat" =~ ^[0-9]+$ ]] && (( $(now_epoch) >= rat )); then
        echo "WAKE=ramp: the parked window ended at $(date -d "@$rat" '+%F %H:%M')."
        echo "  ⚠ This is a CONDITION, not a permission. It reports that a window rolled;"
        echo "    it cannot see a weekly cap or a human-imposed hold, and it does not lift one."
        hb_exit "$seat" ramp; _rearm_notice "$seat"; return 0
      fi
    fi

    # ─── Mail: the primary wake ──────────────────────────────────────────────
    local pending
    pending=$( { find "$MAIL_DIR/$seat"         -maxdepth 1 -name '*.md' 2>/dev/null
                 find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' 2>/dev/null; } | wc -l )
    if (( pending > 0 )); then
      echo "WAKE=mail: $pending message(s) for '$seat'."
      mail_deliver "$seat" "$maxb"
      # ⇒ `reason=mail` is what turns this exit from "the poller is gone" into
      #   "the poller fired and the seat is now reading". `aimail fleet` reads it
      #   and reports RE-ARMING rather than DOWN for the whole grace window.
      hb_exit "$seat" mail
      _rearm_notice "$seat"
      return 0
    fi

    hb_beat "$seat"
    sleep "$interval"
  done
}
