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

# ⭐ AR-12 — ONE atomic write, not four sequential hb_write calls. Each hb_write
#    is its own mktemp+mv; four of them left a window — file truncated-but-empty,
#    or `pid` present without `beat` yet — where a concurrent `poller_state` read
#    a partial record and reported CRASHED (no pid yet) or WEDGED (pid present,
#    beat absent → stale computed against a phantom 0). Measured: 10 healthy
#    starts → 1 WEDGED, 1 CRASHED. A single mv makes every reader see either the
#    prior file (pre-start) or the fully-populated one — never a half record.
hb_start() {
  local seat="$1" now f tmp; f="$(HB_FILE "$seat")"; now="$(now_epoch)"
  mkdir -p "$(HB_DIR)"
  tmp="$(mktemp "$(HB_DIR)/.hb.XXXXXX")"
  { printf 'pid\t%s\n' "$$"
    printf 'ppid\t%s\n' "$PPID"
    printf 'started\t%s\n' "$now"
    printf 'beat\t%s\n' "$now"
  } > "$tmp"
  mv -f "$tmp" "$f"
}
hb_beat() { hb_write "$1" beat "$(now_epoch)"; }
# ⭐ AR-09 — the park heartbeat. Written on its OWN key (never `beat`) so a
#   correctly-parked poller stays distinguishable from one that stopped beating
#   for an unknown reason. See poller_state()'s PARKED branch below.
hb_park() { hb_write "$1" park_beat "$(now_epoch)"; }
hb_exit() {
  local seat="$1" reason="$2"
  hb_write "$seat" exit_at "$(now_epoch)"
  hb_write "$seat" exit_reason "$reason"
}

# ─── poller_state <seat> — ONE implementation, seven distinct states ──────────
# Prints: STATE<TAB>detail
#
# ⭐ Seven states, where a process count had two. Every extra state is one the
#    predecessor could not see and therefore misreported:
#      ARMED       heartbeat fresh, process alive          → reachable
#      PARKED      throttled, park heartbeat fresh          → correctly idle, NOT hung
#      RE-ARMING   exited with a reason, inside the grace   → WORKING, do not nudge
#      STALLED     exited with a reason, past the grace     → should have re-armed
#      WEDGED      process alive but heartbeat is stale     → hung, not working
#      CRASHED     no exit record and no live process       → killed; needs a human
#      NEVER       no heartbeat ever written                → never started
#
# ⭐ AR-09 — PARKED did not exist. `poller.sh`'s throttle branch `continue`s
#    without calling `hb_beat`, by design (a parked poller must not look busy).
#    But that left park and hang sharing one signal — a stale `beat` — so a
#    correctly parked poller crossed into WEDGED after `limit` seconds and the
#    dashboard told a human to kill a healthy process. `hb_park()` now writes
#    its OWN key each time through the park loop; a fresh `park_beat` is
#    positive evidence the loop is alive and cycling in the park branch
#    specifically, not an inference from a global flag that says nothing about
#    which poller is actually parked vs. stuck elsewhere.
poller_state() {
  local seat="$1" now pid beat exit_at reason interval park_beat
  now="$(now_epoch)"
  interval="${AIMAIL_POLL_INTERVAL:-5}"

  if ! [[ -f "$(HB_FILE "$seat")" ]]; then
    printf 'NEVER\tno heartbeat has ever been written for this seat\n'; return 0
  fi
  pid="$(hb_read "$seat" pid || echo '')"
  beat="$(hb_read "$seat" beat || echo 0)"
  exit_at="$(hb_read "$seat" exit_at || echo '')"
  reason="$(hb_read "$seat" exit_reason || echo '')"
  park_beat="$(hb_read "$seat" park_beat || echo 0)"

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

  local limit=$(( interval * 6 + 30 ))

  # PARKED takes priority over the beat-staleness check below: while parked,
  # `beat` is EXPECTED to go stale (that is the whole design), so judging
  # health by `beat` here would always read a healthy park as WEDGED. Judge it
  # by the channel that is actually still advancing instead.
  if (( alive == 1 )) && (( now - park_beat <= limit )); then
    printf 'PARKED\tpid %s, park heartbeat %ss ago — correctly idle under a throttle\n' \
      "$pid" "$(( now - park_beat ))"
    return 0
  fi

  # No exit record, not parked. Is it beating?
  local stale=$(( now - beat ))
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
  else
    # Default view (no seat args): every seat the registry does NOT mark
    # `retired`. A retired row is kept deliberately (see lib/registry.sh) so a
    # message to it can name its successor, but it has no reader and does not
    # belong on a dashboard of who is working.
    #
    # This is the same filter `budget.sh` and `role.sh` already apply, so the
    # three agree on what "the fleet" means rather than each keeping its own
    # list. ⛔ Do NOT hardcode seat names here: this file ships to other fleets
    # whose seats are not these, and a fixed roster silently omits theirs.
    #
    # AIMAIL_FLEET_SEATS overrides with an explicit space-separated list for
    # anyone who wants a narrower default. An explicit `aimail fleet <seat>`
    # resolves against the FULL registry above either way, unaffected.
    local s
    if [[ -n "${AIMAIL_FLEET_SEATS:-}" ]]; then
      for s in $AIMAIL_FLEET_SEATS; do seat_exists "$s" && seats+=("$s"); done
    else
      while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        [[ "$(seat_field "$s" 2)" == "retired" ]] && continue
        seats+=("$s")
      done < <(seat_names)
    fi
  fi

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
      PARKED)
        verdict="PARKED — correctly idle under a throttle. ⛔ DO NOT KILL, do not nudge" ;;
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
    # FI-58: retirement-aware. A retired seat has no reader, so its inbox count is
    # ORPHANED (unreadable), never live QUEUED, and it is not "startable". Without
    # this it falls to the NEVER case -> "NOT STARTED", which reads as a new seat you
    # can start. Mirror of the retired guard `sweep` already uses below.
    if [[ "$(seat_field "$seat" 2)" == "retired" ]]; then
      verdict="RETIRED — no reader; ${q} file(s) ORPHANED (unreadable), not live QUEUED"
    fi
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

# ─── sweep — AR-20: an ACTIVE loop, not a dashboard nobody calls ──────────────
# ⛔⛔ THE DEFECT: `aimail fleet` is a complete, correct dashboard, but nothing
#   calls it unless a human already suspects trouble — a CRASHED seat is
#   invisible until someone looks. Five watchdog loops in the predecessor
#   became ZERO here; the README calls that "subsumed by aimail fleet", but a
#   read-only report is not a sweep. This is the active half: run it from
#   cron (same shape as budget_autopilot) and it tells someone, unprompted,
#   instead of waiting to be asked.
#     */5 * * * * /path/to/bin/aimail fleet sweep >> ~/.aimail/state/sweep.log 2>&1
#
# ⛔⛔ AR-22 — STALLED WAS EXEMPT, AND THAT IS THE EXACT SHAPE OF THE OVERNIGHT
#   INCIDENT. A poller launched outside the harness's own tracking (`&`,
#   `nohup`, a shell that disowns it) still delivers mail and still writes a
#   clean `hb_exit` — the heartbeat cannot tell an untracked poller from a
#   tracked one, because "does the harness hold a task id for this" is not
#   visible from `/proc` at all, by anyone, from outside the process. What IS
#   visible: the poller exited with a reason, and nothing re-armed it. That is
#   STALLED, and sweep skipped it on purpose — `case … *) continue ;;` — because
#   a seat mid-turn looks identical for the first few minutes. MEASURED: main
#   dead ~7h (21 queued), audit dead ~90m (5 queued), neither raised because a
#   dashboard nobody was looking at is not a sweep. ⇒ Alert on STALLED too, but
#   only past a threshold generous enough that a real turn never trips it —
#   AIMAIL_STALL_ALERT, default 20 minutes, an order of magnitude past
#   REARM_GRACE (3 min) on purpose, since REARM_GRACE exists to label the
#   dashboard for a HUMAN reading it live, not to gate an unattended alert.
STALL_ALERT="${AIMAIL_STALL_ALERT:-1200}"
SWEEP_ALERT_DIR() { echo "$STATE_DIR/sweep_alerted"; }
fleet_sweep() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  mkdir -p "$(SWEEP_ALERT_DIR)"
  local -a seats=()
  while IFS= read -r s; do [[ -n "$s" ]] && seats+=("$s"); done < <(seat_names)
  (( ${#seats[@]} == 0 )) && unmeasurable "no seats registered — there is nothing to sweep" \
    "This is an empty address space, not a healthy fleet."

  local seat st detail marker key n_alerts=0 n_checked=0
  for seat in "${seats[@]}"; do
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    n_checked=$((n_checked+1))
    IFS=$'\t' read -r st detail < <(poller_state "$seat")
    case "$st" in
      CRASHED|WEDGED) : ;;   # the two states `aimail fleet` itself marks ⛔ — needs a human
      STALLED)
        # Past the dashboard's grace already (poller_state only returns STALLED
        # there); gate the ALERT on a second, much longer threshold so a seat
        # genuinely mid-task for ten minutes never pages anyone.
        local exit_at; exit_at="$(hb_read "$seat" exit_at 2>/dev/null || echo 0)"
        (( $(now_epoch) - exit_at < STALL_ALERT )) && continue
        ;;
      *) continue ;;
    esac
    # ⭐ DEDUP ON THE UNDERLYING EVENT, NOT ON "still bad". Keyed on the
    #   (pid, beat) this specific reading was computed from: the SAME ongoing
    #   crash re-sweeps silently — no repeat alert every 5 minutes for one
    #   incident — but a NEW crash, even of the same seat, even reading as the
    #   same state NAME, gets its own alert, because its (pid,beat) pair
    #   differs from the last one that was reported. For STALLED the same pair
    #   holds for the whole stall (nothing writes to the heartbeat again once
    #   the poller has exited), so this reuses the identical dedup for free.
    marker="$(SWEEP_ALERT_DIR)/$seat"
    key="$st:$(hb_read "$seat" pid 2>/dev/null || echo '?'):$(hb_read "$seat" beat 2>/dev/null || echo '?')"
    [[ "$(cat "$marker" 2>/dev/null)" == "$key" ]] && continue
    if seat_exists "$supervisor"; then
      local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/sweep.XXXXXX")"
      { printf '# 🔴 SWEEP: %s is %s\n\n%s\n\n' "$seat" "$st" "$detail"
        printf 'No human asked for this — the sweep found it unprompted.\n'
        printf 'Run `aimail fleet %s` to confirm current state before acting.\n' "$seat"
      } > "$body"
      if mail_send --to "$supervisor" --from "$supervisor" \
           --subject "SWEEP: $seat is $st" --body-file "$body" >/dev/null 2>&1; then
        printf '%s' "$key" > "$marker"; n_alerts=$((n_alerts+1))
      fi
      rm -f "$body"
    else
      warn "sweep: '$seat' is $st but supervisor '$supervisor' is not registered — no alert sent"
    fi
  done
  info "sweep: checked $n_checked seat(s), $n_alerts new alert(s)"
  return 0
}
