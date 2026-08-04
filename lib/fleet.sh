# shellcheck shell=bash
# fleet.sh — who is working, who is reachable, who needs a human.
#
# ⛔⛔ THE MISTAKE THIS FILE EXISTS TO MAKE IMPOSSIBLE: using a poller's presence
#    to decide whether a session is alive. **A poller is DOWN in both of these
#    cases, and they demand opposite responses:**
#
#      down → the session is MID-TURN. It consumed its wake and has not re-armed
#             yet. Reading its mail and re-arming takes time. Nudging it queues
#             behind work already in flight.
#      down → the session is DEAD. It cannot be reached at all and only a human
#             can restart it.
#
#    A process sample cannot tell those apart, and guessing produced both failure
#    directions repeatedly — redundant nudges, and one seat sitting idle ~25
#    minutes before a hand check found it.
#
# ⭐ THE FIX IS TO STOP SAMPLING PROCESSES AND START READING EVENTS.
#    Two event sources, neither of which is a `pgrep`:
#
#    1. THE POLLER'S HEARTBEAT, which records WHY it stopped. An exit that says
#       `reason=mail` is a poller that DID ITS JOB — the wake fired and the seat
#       is now reading. An absent heartbeat with no exit record is a poller that
#       was KILLED. Those look identical to `ps` and are opposite facts.
#       ⇒ This is the general rule the predecessor kept relearning: A COMPLETED
#         RUN MUST LEAVE A VERDICT ARTIFACT, NOT MERELY STOP. Finished, killed
#         and crashed all leave the same evidence — no process — unless the
#         finishing path writes something the other two cannot.
#
#    2. THE STOP HOOK'S EVENT LOG, which records the exact moment a session ENDED
#       A TURN. That is what "idle" actually means. A process sample can never
#       answer "when did this last stop"; an event log answers only that.
#
# ⚠ AND THE GRACE WINDOW IS THE WHOLE POINT OF COMBINING THEM. Between a poller
#   firing and the seat re-arming there is a legitimate gap — the seat is reading
#   its mail. Reporting that gap as "DOWN" is the single most common false alarm
#   in fleet supervision. `AIMAIL_REARM_GRACE` names it, so the dashboard can say
#   RE-ARMING instead of guessing.

REARM_GRACE="${AIMAIL_REARM_GRACE:-180}"
HB_DIR() { echo "$STATE_DIR/poller"; }
HB_FILE() { echo "$(HB_DIR)/$1.hb"; }
STOPLOG() { echo "$STATE_DIR/stophook.log"; }

# ─── Heartbeat, written by the poller ─────────────────────────────────────────
hb_write() {
  local seat="$1" key="$2" val="$3" f; f="$(HB_FILE "$seat")"
  mkdir -p "$(HB_DIR)"
  local tmp; tmp="$(mktemp "$(HB_DIR)/.hb.XXXXXX")"
  { [[ -f "$f" ]] && awk -F'\t' -v k="$key" '$1!=k' "$f"; printf '%s\t%s\n' "$key" "$val"; } > "$tmp"
  mv -f "$tmp" "$f"
}
hb_read() {
  local seat="$1" key="$2" f; f="$(HB_FILE "$seat")"
  [[ -f "$f" ]] || return 1
  # ⛔ awk -F'\t', never `IFS=$'\t' read`. Tab is IFS whitespace, so consecutive
  #    tabs COLLAPSE and every field after an empty one shifts left. That defect
  #    silently blinded a cold-start guard in the predecessor and would have
  #    re-throttled the whole fleet on a fabricated rate.
  awk -F'\t' -v k="$key" '$1==k{print $2; found=1} END{exit !found}' "$f"
}

hb_start() {
  local seat="$1"
  mkdir -p "$(HB_DIR)"
  : > "$(HB_FILE "$seat")"
  hb_write "$seat" pid "$$"
  hb_write "$seat" ppid "$PPID"
  hb_write "$seat" started "$(now_epoch)"
  hb_write "$seat" beat "$(now_epoch)"
}
hb_beat() { hb_write "$1" beat "$(now_epoch)"; }
hb_exit() {
  local seat="$1" reason="$2"
  hb_write "$seat" exit_at "$(now_epoch)"
  hb_write "$seat" exit_reason "$reason"
}

# ─── poller_state <seat> — ONE implementation, six distinct states ────────────
# Prints: STATE<TAB>detail
#
# ⭐ Six states, where a process count had two. Every extra state is one the
#    predecessor could not see and therefore misreported:
#      ARMED       heartbeat fresh, process alive          → reachable
#      RE-ARMING   exited with a reason, inside the grace   → WORKING, do not nudge
#      STALLED     exited with a reason, past the grace     → should have re-armed
#      WEDGED      process alive but heartbeat is stale     → hung, not working
#      CRASHED     no exit record and no live process       → killed; needs a human
#      NEVER       no heartbeat ever written                → never started
poller_state() {
  local seat="$1" now pid beat exit_at reason interval
  now="$(now_epoch)"
  interval="${AIMAIL_POLL_INTERVAL:-5}"

  if ! [[ -f "$(HB_FILE "$seat")" ]]; then
    printf 'NEVER\tno heartbeat has ever been written for this seat\n'; return 0
  fi
  pid="$(hb_read "$seat" pid || echo '')"
  beat="$(hb_read "$seat" beat || echo 0)"
  exit_at="$(hb_read "$seat" exit_at || echo '')"
  reason="$(hb_read "$seat" exit_reason || echo '')"

  local alive=0
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && alive=1

  # An exit record NEWER than the last beat means it stopped deliberately.
  if [[ "$exit_at" =~ ^[0-9]+$ ]] && (( exit_at >= beat )); then
    local since=$(( now - exit_at ))
    if (( since <= REARM_GRACE )); then
      printf 'RE-ARMING\texited %ss ago (reason=%s) — the seat is reading its mail\n' "$since" "$reason"
    else
      printf 'STALLED\texited %sm ago (reason=%s) and has not re-armed\n' "$(( since / 60 ))" "$reason"
    fi
    return 0
  fi

  # No exit record. Is it beating?
  local stale=$(( now - beat ))
  local limit=$(( interval * 6 + 30 ))
  if (( alive == 1 && stale <= limit )); then
    printf 'ARMED\tpid %s, last beat %ss ago\n' "$pid" "$stale"
  elif (( alive == 1 )); then
    printf 'WEDGED\tpid %s is alive but has not beaten for %ss (limit %ss)\n' "$pid" "$stale" "$limit"
  else
    # ⛔ THE DANGEROUS ONE, AND THE WHOLE REASON THE EXIT RECORD EXISTS. No live
    #    process AND no exit record means it was killed or the machine died. In
    #    the predecessor this was indistinguishable from a clean delivery, so a
    #    dead seat and a busy seat produced the same reading.
    printf 'CRASHED\tno live process and NO exit record — it did not stop on purpose\n'
  fi
}

# ─── last stop, from the hook's event log ─────────────────────────────────────
last_stop() {
  local seat="$1" log; log="$(STOPLOG)"
  [[ -s "$log" ]] || { printf '\t\t'; return 0; }
  # Anchor the seat to its own field. An unanchored match for `main` would also
  # match a future seat named `main-b2` — exactly the class of silent mismatch
  # that keeps costing time.
  awk -F'\t' -v s="$seat" '$3==s{e=$1; d=$5} END{printf "%s\t%s", (e?e:""), (d?d:"")}' "$log"
}

# ─── The dashboard ────────────────────────────────────────────────────────────
fleet_report() {
  local -a seats=()
  if (( $# )); then local s; for s in "$@"; do seats+=("$(seat_resolve "$s")") || exit $?; done
  else while IFS= read -r s; do [[ -n "$s" ]] && seats+=("$s"); done < <(seat_names); fi

  (( ${#seats[@]} == 0 )) && unmeasurable "no seats registered — there is no fleet to report on" \
    "This is an empty address space, not an idle fleet."

  local now; now="$(now_epoch)"
  printf '%-16s %-11s %-10s %6s %6s  %s\n' SEAT POLLER LAST-STOP QUEUED UNACK VERDICT
  printf '%.0s─' {1..88}; echo

  local seat st detail stop_e stop_d q u verdict ago
  for seat in "${seats[@]}"; do
    IFS=$'\t' read -r st detail < <(poller_state "$seat")
    IFS=$'\t' read -r stop_e stop_d < <(last_stop "$seat")
    q=$(find "$MAIL_DIR/$seat"         -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
    u=$(find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)

    if [[ "$stop_e" =~ ^[0-9]+$ ]]; then ago="$(( (now - stop_e) / 60 ))m"; else ago="never"; fi

    # ─── The verdict. Printed rather than left to the reader, because the same
    #     two columns support opposite conclusions and this fleet has drawn the
    #     wrong one before.
    case "$st" in
      ARMED)
        if [[ "$ago" == "never" ]]; then verdict="WORKING — never ended a turn yet"
        else verdict="IDLE & REACHABLE — mail will wake it, send work"; fi ;;
      RE-ARMING)
        verdict="WORKING — mid-turn, reading mail. ⛔ DO NOT NUDGE" ;;
      STALLED)
        verdict="CHECK — woke but never re-armed; may be mid-task or stuck" ;;
      WEDGED)
        verdict="⛔ HUNG — process alive, loop not running. Needs a kill + restart" ;;
      CRASHED)
        verdict="⛔ UNREACHABLE — killed, not finished. Only a human can restart it" ;;
      NEVER)
        verdict="NOT STARTED — no poller has ever run for this seat" ;;
    esac
    [[ "$stop_d" == BLOCK* ]] && verdict="$verdict  ⚠ last stop was BLOCKED"
    printf '%-16s %-11s %-10s %6s %6s  %s\n' "$seat" "$st" "$ago" "$q" "$u" "$verdict"
  done

  echo
  cat <<EOF
HOW TO READ THIS — the distinction that matters most:
  RE-ARMING is NOT down. The poller fired, the seat is reading its mail, and it
  will re-arm on its own. Nudging it queues behind work already in flight. The
  grace window is ${REARM_GRACE}s (AIMAIL_REARM_GRACE).

  CRASHED is different from every other row: there is NO exit record, so it did
  not stop on purpose. That is the only state a human has to fix.

⚠ "Stopped" is never "finished". A seat can end a turn mid-task waiting on a
  decision. Cross-check what it is actually working on before concluding it is done.
EOF
  return 0
}
