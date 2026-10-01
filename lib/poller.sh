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

_poller_reexec_private_persistent() {
  # ⛔ Deliberate near-duplicate of `_poller_reexec_private`, not a shared/parametrized helper --
  # same FI-19 self-corruption reasoning applies (this process, too, re-execs from a private
  # copy so an in-place edit of the live script mid-run cannot corrupt it), but the exec target
  # is `poll-persistent`, not `poll`. Duplicated rather than adding a subcommand parameter to
  # the existing function so `_poller_reexec_private` itself stays byte-identical -- item 1's own
  # safety plan asks that the existing `poll` path not change AT ALL while this is prototyped.
  [[ -n "${AIMAIL_PRIVATE_COPY:-}" ]] && return 0
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/aimail-poll.XXXXXX")" || return 0
  cp -r "$AIMAIL_HOME/bin" "$AIMAIL_HOME/lib" "$tmp/" 2>/dev/null || { rm -rf "$tmp"; return 0; }
  export AIMAIL_PRIVATE_COPY="$tmp" AIMAIL_CONFIG="${AIMAIL_CONFIG:-$AIMAIL_HOME/etc/aimail.conf}"
  trap 'rm -rf "$tmp"' EXIT INT TERM
  exec "$tmp/bin/aimail" poll-persistent "$@"
}

_rearm_notice() {
  local seat="$1"
  echo
  echo "⚠ THIS POLLER HAS NOW EXITED — you no longer have one."
  echo "   An exit is the WAKE, not a failure. But until you re-arm, you are unreachable."
  echo "   ▶ aimail poll $seat        (run_in_background=true, absolute path)"
  echo "   ⚠ plain \`poll\` is DEPRECATED (2026-09-21): prefer \`aimail poll-persistent $seat\` under a Monitor task, re-armed at its cap."
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

  # ⚠ DEPRECATION (project owner, 2026-09-21, via assistant 20260921T002827): the classic
  #   exit-on-every-delivery mode is being retired fleet-wide in favour of
  #   `poll-persistent` (armed under a Monitor task, re-armed at its 30-min cap).
  #   Behaviour here is UNCHANGED — the warning is one stderr line, printed once:
  #   `_poller_reexec_private` re-runs this very function from the private copy
  #   with AIMAIL_PRIVATE_COPY set, so the guard keeps it from printing twice.
  #   AIMAIL_POLL_DEPRECATION_QUIET=1 silences it (tests that compare output).
  if [[ -z "${AIMAIL_PRIVATE_COPY:-}" && "${AIMAIL_POLL_DEPRECATION_QUIET:-}" != "1" ]]; then
    printf '⚠ DEPRECATED: `aimail poll %s` (exits on every delivery) is being retired -- arm `aimail poll-persistent %s` under a Monitor task instead (project owner, 2026-09-21). This run continues unchanged.\n' "$seat" "$seat" >&2
  fi

  _poller_reexec_private "$seat"
  _poller_loop "$seat" 0
}

# ═══ THE SHARED WAKE LOOP — one definition, a PERSISTENT flag decides exit-vs-continue ═══════
# ⛔⛔ WHY THIS IS ONE FUNCTION NOW, NOT TWO (fable, 2026-09-10, poll-persistent ramp-exit
#    finding): the persistent variant was first built as a deliberate, near-total duplicate of
#    this loop body (see the ISSUES item 1 note this replaces) specifically so the classic
#    `aimail poll` path could not regress while the persistent one was prototyped. That
#    protected `poll`, but it meant every wake branch existed in TWO places, and the persistent
#    copy's own header comment said only the mail branch had been adapted -- "every OTHER exit
#    ... is UNCHANGED and still exits". That was true and it was the bug: a `poll-persistent`
#    session hit `WAKE=ramp`, printed "THIS POLLER HAS NOW EXITED", and DID exit -- the exact
#    classic-poll behavior the fleet-wide switch was supposed to have left behind, live on the
#    assistant seat within the hour of the switch. Two copies of the same wake logic had
#    already drifted; this merge is the named follow-up the original comment asked for.
# ⇒ CONTRACT: under `persistent=1`, this loop exits ONLY on a trapped signal (INT/TERM) or the
#    harness stopping the Monitor that runs it -- mail, ramp (both arms), unpark, and heartbeat
#    all print their WAKE= line and loop. Under `persistent=0` every wake still exits exactly
#    as `poller_run` always has, byte-for-byte -- every `if (( persistent ))` branch below has an
#    `else` that is the ORIGINAL classic-poll line, unedited in substance.
_poller_loop() {
  local seat="$1" persistent="${2:-0}"
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
  # ⛔⛔ 2026-09-20: THROTTLE_FLAG()/RAMP_AT_FILE() (per-account park/ramp state)
  #   live in budget.sh, and the throttle check just below is now a call to
  #   one of them, not a bare path test — it needs budget.sh sourced BEFORE
  #   that check runs, not lazily inside the `-f` branch the way the old bare
  #   `$STATE_DIR/throttled` test could get away with. Sourcing it here, once,
  #   for the whole loop; the two later `source "$AIMAIL_LIB/budget.sh"` calls
  #   further down are now redundant but harmless (budget.sh's own top-of-file
  #   comment: idempotent, safe to re-source).
  source "$AIMAIL_LIB/budget.sh"
  # ⭐ M1 gap (2026-09-20): a poller that outlived its own Claude session
  #   (`claude stop <id>` kills the session, not this backgrounded job) keeps
  #   beating and reading real mail with no AI behind it. Arming is the one
  #   moment a seat is provably being resumed, so the sweep runs HERE, once,
  #   BEFORE hb_start/instance_register: a killed orphan's TERM trap writes
  #   its exit record into the OLD heartbeat file, which hb_start then
  #   replaces wholesale. Kills only a sid that `claude agents --json` lists
  #   for NO account; an unknown reading kills nothing (lib/fleet.sh).
  instance_sweep_orphans "$seat"
  hb_start "$seat"
  # ⭐⭐ Slice 2 (WEDGED-SYNC, fleet.sh) needs to tell a persistent poller from a classic one
  #    FROM THE HEARTBEAT RECORD ALONE -- `poller_state()` has no other way to know which mode
  #    a given pid was started in, and applying the max-age/etimes check to a classic `poll`
  #    (which legitimately sits alive for a long time in its own plain mail-wait loop, no bug
  #    there) would be a real false positive. One extra key, written once at loop start,
  #    alongside the existing per-seat heartbeat -- additive, nothing else reads or changes.
  hb_write "$seat" persistent "$persistent"
  # ⭐ M1 instance registry (twin-seat coordination, increment 0,
  #   docs/twin_seat_coordination_design_2026-09-18.md) — additive, keyed by
  #   session id, alongside the existing per-seat heartbeat above. The EXIT
  #   trap (not a per-branch call) is deliberate: it fires on every exit path
  #   below (mail/ramp/heartbeat/return, and after the INT/TERM trap's own
  #   `exit 143`) without needing to touch each individual hb_exit call site.
  # ⛔⛔ MEASURED LIVE, 2026-09-20: a trap string is expanded at FIRE time, not
  #   at `trap` time, even single-quoted — and by the time this process
  #   actually exits (after `_poller_loop` and `poller_run` have both
  #   RETURNED, at top-of-script EOF), their own `local seat` is long gone.
  #   The first version of this fix referenced "$seat" directly in the trap
  #   and errored `seat: unbound variable` on every single exit, silently
  #   never running `instance_deregister` at all — the exact "removed on
  #   clean exit" contract this increment exists to satisfy, quietly false
  #   from the start. A plain (non-local) global survives past both
  #   functions returning; the trap reads THAT, not the function-local copy.
  AIMAIL_POLLER_SEAT="$seat"
  instance_register "$seat"
  trap 'instance_deregister "$AIMAIL_POLLER_SEAT"' EXIT
  # Covers the paths a trap can see. SIGKILL is deliberately NOT trappable, and
  # that is exactly the case the missing-exit-record rule is designed to catch.
  trap 'hb_exit "$seat" signal; exit 143' INT TERM

  # ⭐⭐⭐ THE HEARTBEAT WAKE — a bounded dead-man's switch on the ARMED branch
  #    itself, independent of mail, park, ramp, or any cron job existing at all.
  #    MEASURED, 2026-08-26: the whole fleet went quiet at once at a real budget
  #    checkpoint (~01:20) — no `throttled` flag was ever set (autopilot's own
  #    park never fired; its `ramp_at` sat stale from the PREVIOUS afternoon,
  #    meaning the checkpoint→park→ramp cron pipeline this file's park branch
  #    depends on had not actually run in this environment). Every poller sat
  #    correctly ARMED, in the plain mail-wait branch below, which has NO
  #    timeout — an infinite `while true` bound only by "did new mail arrive."
  #    assistant did not resume for ~8 hours; nothing was down, nothing crashed,
  #    there was simply no path back to being invoked once mail traffic itself
  #    stopped. The project owner: "this will happen again unless we program in a
  #    solution... that doesn't require you to remember something."
  # ⇒ FIX, at the layer that cannot be forgotten: every armed poller now exits
  #    on its own after AIMAIL_POLL_HEARTBEAT_SEC of total silence (default
  #    1800s/30min — the same idle-tick cadence this fleet already uses for
  #    ScheduleWakeup), regardless of whether mail arrived, a throttle exists,
  #    or any cron job ran. The exit prints WAKE=heartbeat and re-arms exactly
  #    like every other wake; a session that finds nothing real to do can ack
  #    (nothing to ack) and re-arm immediately, cheaply. This does NOT fire
  #    inside the `throttled`/park branch below — a deliberate park must still
  #    stay quiet and cost nothing, per that branch's own AR-09 design; this is
  #    strictly for the "armed but nobody is sending mail" gap, which is the
  #    exact gap that actually stalled this fleet. Set to 0 to disable.
  # ⭐⭐ NIGHT-MODE ONLY (project owner, 2026-08-26, same morning): during the day the owner
  #    is directly present and would notice a quiet fleet without help — a periodic
  #    self-wake then just spends tokens nobody needs spent, the same daytime
  #    token-discipline rule already governing proactive status mail. Reuses
  #    the SAME flag `aimail budget night`/`day` already toggles
  #    ($STATE_DIR/night_mode) rather than inventing a second mode switch —
  #    checked by direct path, not by sourcing budget.sh, matching how
  #    `throttled`/`ramp_at` are already read below in this same file. An
  #    explicit AIMAIL_POLL_HEARTBEAT_SEC always wins regardless of mode, for
  #    deliberate testing/override.
  local heartbeat_sec="${AIMAIL_POLL_HEARTBEAT_SEC:-}"
  if [[ -z "$heartbeat_sec" ]]; then
    if [[ -f "$STATE_DIR/night_mode" ]]; then heartbeat_sec=1800; else heartbeat_sec=0; fi
  fi
  local hb_deadline=$(( $(now_epoch) + heartbeat_sec ))

  # ⭐⭐⭐ THE MAX-AGE SELF-LIMIT — poll-persistent's own bounded escape hatch for exactly one
  #    misuse: a plain Bash call (foreground, or naively backgrounded with `&`) instead of a
  #    Monitor task. Fable's design (poll-persistent wedge finding, 2 seats hung one night --
  #    one for 12.5 hours): a Monitor kills its own child at its 30-minute (1800s) cap; this
  #    loop's own header says persistent mode "does not exit on any wake", so a copy NOT running
  #    under a Monitor has no exit path at all once armed. AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC
  #    (default 1900s/~32min -- the smallest margin past the 1800s Monitor cap that still gives
  #    correct usage room to clear normal scheduling jitter before its own tick fires) bounds
  #    TOTAL WALL TIME since this persistent loop started, checked every tick, independent of
  #    mail/heartbeat/park state -- the same "fix at the layer that cannot be forgotten"
  #    principle the heartbeat fix above already uses. Set to 0 to disable.
  #    ⛔ 2026-09-25: lowered from 2400s -- a fable-sat-idle-16min incident showed a Bash-armed
  #    poller can go unnoticed by its own seat until the fleet sweep's stall alert catches it
  #    (~15-20min); checked whether the two arm paths can be told apart from outside (process
  #    ancestry and full environment, both compared live: byte-identical either way -- they
  #    cannot) before landing on this instead: an env marker required at arm time was
  #    considered and rejected (every existing arm instruction across the fleet omits it, so
  #    it would refuse every un-updated seat's very next re-arm; and it doesn't prove Monitor
  #    either, since a Bash arm can set the same marker). Tightening this existing, harder-to-
  #    forget bound to the smallest correct margin needs no new convention and cannot regress a
  #    correctly-Monitor-armed poller, which is always well under 1800s by definition.
  local persist_max_age_sec="${AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC:-1900}"
  local persist_start_epoch; (( persistent )) && persist_start_epoch=$(now_epoch)

  if (( persistent )); then
    echo "$(instrument_id) — polling '$seat' every ${interval}s (PERSISTENT -- run this as a Monitor; it does not exit on any wake)"
  else
    echo "$(instrument_id) — polling '$seat' every ${interval}s"
  fi
  echo "state: $AIMAIL_ROOT"

  # Item 5 (per-seat unpark) — dedupe the WAKE=unpark line to once per grant
  # (keyed on the grant's own captured `ramp_at`), not once per poll tick. The
  # exemption does not exit the loop (unlike WAKE=mail/WAKE=ramp below), so
  # without this it would otherwise print every `$interval` seconds for as
  # long as the exemption stays valid.
  local _unpark_logged_rat=""
  local _hardstop_logged=""

  while true; do
    # ─── SUPERSEDED — this session's id is on the seat record's retired list (R6(e)/(g), the owner's
    #    2026-09-23 handover design): the seat moved on to another session; this one leaves aimail. No
    #    delivery, no heartbeat, exit. The record's retired list is the ONLY trigger: a freshly booted
    #    session whose record still names its predecessor is NOT superseded (it has not confirmed yet).
    if poller_superseded "$seat"; then
      echo "WAKE=superseded: this session ($(_poller_own_sid | cut -c1-8)) is RETIRED on the '$seat' record -- the seat moved on (aimail seat sessions $seat). Leaving aimail: no more delivery from this poller. Do NOT re-arm; do not stop this session either (kept for the owner's questions)."
      hb_exit "$seat" superseded
      return 0
    fi
    # ─── Max-age self-limit — checked FIRST, unconditionally, every tick ─────
    # ⛔⛔ Deliberately ahead of unpark/throttle/mail/heartbeat: this is a bound on the PROCESS
    #    itself (was this ever a Monitor-managed run at all?), not on any of the states those
    #    branches reason about. A `poll-persistent` invoked as a plain Bash call never sees a
    #    Monitor's own 30-min kill, so nothing else in this loop would ever end it.
    if (( persistent )) && (( persist_max_age_sec > 0 )) \
       && (( $(now_epoch) - persist_start_epoch >= persist_max_age_sec )); then
      local _age_disp
      if (( persist_max_age_sec >= 60 )); then
        _age_disp="$(( persist_max_age_sec / 60 )) min"
      else
        _age_disp="${persist_max_age_sec}s"
      fi
      echo "WAKE=max_age: this poll-persistent ran ${_age_disp} -- longer than any Monitor allows (30 min cap). It was NOT running under a Monitor. Re-arm it as a Monitor task, not a Bash call."
      hb_exit "$seat" max_age
      return 0
    fi

    # ─── Per-seat unpark exemption — checked BEFORE the shared throttle ──────
    # AR-13 (item 5): `aimail budget unpark <seat>` grants ONE seat an
    # exemption from the CURRENT park, without touching the shared `throttled`
    # flag and without claiming anything about that seat's own usage (same
    # non-assertion discipline AR-12's account-mismatch fix already uses — it
    # un-blocks, it doesn't vouch for correctness). The exemption expires by
    # comparing its own captured `throttled`-file mtime (the park EPISODE's own
    # stable identity, per `budget_unpark`'s own header) against `throttled`'s
    # CURRENT mtime — not `ramp_at`'s own value, which a legitimate mid-park
    # boundary re-measurement can rewrite without any new park actually
    # beginning (code-review's gate finding on 2f9e4f0).
    local _unpark_file="$STATE_DIR/seat_unpark_$seat"
    local _seat_exempt=0
    if [[ -f "$_unpark_file" ]]; then
      local _exempt_park _cur_park
      _exempt_park="$(awk -F'\t' '$1=="park_started_at"{print $2}' "$_unpark_file" 2>/dev/null)"
      _cur_park="$(stat -c %Y "$(THROTTLE_FLAG)" 2>/dev/null || echo '')"
      if [[ -n "$_exempt_park" && "$_exempt_park" == "$_cur_park" ]]; then
        _seat_exempt=1
        if [[ "$_unpark_logged_rat" != "$_exempt_park" ]]; then
          local _exempt_reason
          _exempt_reason="$(awk -F'\t' '$1=="reason"{print $2}' "$_unpark_file" 2>/dev/null)"
          echo "WAKE=unpark: running under a manual exemption granted ${_exempt_reason:-(no reason given)}"
          _unpark_logged_rat="$_exempt_park"
        fi
      else
        # Stale — a newer park has since begun (or none is active at all). Safe to delete: this
        # file is scoped to one seat and this is that seat's own poller.
        rm -f "$_unpark_file"
        _unpark_logged_rat=""
      fi
    fi

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
    # ⛔⛔ AR-05a — the ramp check used to live AFTER this branch, which
    #    `continue`d unconditionally while throttled — making it UNREACHABLE for
    #    the entire duration of a park. A stale `ramp_at` could never be noticed
    #    by the poller itself; only a separate `autopilot` cron could lift the
    #    throttle, and AR-05b found THAT path dead in the common case (see
    #    `block_end_effective` in budget.sh). Nesting the ramp check INSIDE the
    #    park branch, evaluated before the `continue`, makes it reachable exactly
    #    when it matters (while parked) — NOT unconditionally on every loop tick,
    #    which would misfire: `ramp_at` persists as a recurring 20-minute
    #    safety-net checkpoint long after any given park has ended (see
    #    `budget_ramp`), so checking it outside the `throttled` guard would wake
    #    every armed, perfectly healthy poller every ~20 minutes forever.
    if [[ -f "$(THROTTLE_FLAG)" ]]; then
      # ⛔⛔ AR-12 — a park is a SNAPSHOT of the account active when it was set (the
      #    `ACCOUNT <name> (cap <pct>%)` line `budget_park` writes into this same file), never
      #    re-validated afterward. `account_id()` reads the CURRENT `~/.claude` symlink target
      #    every time it's called, so if the account changes mid-park — a human switches
      #    profiles, which does not itself touch this flag — every poller keeps sleeping on a
      #    cap that no longer describes anyone. MEASURED, 2026-08-20: a park set under account
      #    `r2` outlived a switch to `work` and idled 5 of 6 seats for the better part of an
      #    hour; the project owner caught it live, audit caught it independently by a different method
      #    (comparing the park time against the block schedule) minutes later, and neither
      #    signal was wired to anything — a human had to notice and run `budget ramp` by hand.
      # ▶ FIX: on EVERY loop tick spent parked, compare the flag's own ACCOUNT field against
      #    account_id() right now. A mismatch means the premise the park was made under no
      #    longer holds — treat it exactly like a ramp_at that has passed, via the SAME
      #    self-healing path (`budget_ramp`), rather than inventing a second way to un-park.
      #    This does NOT assert the new account is under its cap — it has no evidence either
      #    way — it only removes a stale throttle so the normal probe/callout cycle can measure
      #    the account that is actually running.
      source "$AIMAIL_LIB/budget.sh"
      local parked_acct; parked_acct="$(awk '$1=="ACCOUNT"{print $2; exit}' "$(THROTTLE_FLAG)" 2>/dev/null)"
      if [[ -n "$parked_acct" ]] && [[ "$parked_acct" != "$(account_id)" ]]; then
        echo "WAKE=ramp: parked under account '$parked_acct', now running as '$(account_id)' — stale."
        echo "  ⚠ This clears the throttle; it does not claim the new account is under its cap."
        budget_ramp >/dev/null 2>&1
        if (( persistent )); then
          hb_beat "$seat"; instance_beat "$seat"; _persistent_still_armed "$seat"; sleep "$interval"; continue
        else
          hb_exit "$seat" ramp; _rearm_notice "$seat"; return 0
        fi
      fi
      if [[ -f "$(RAMP_AT_FILE)" ]]; then
        local rat; rat="$(awk -F'\t' '$1=="at"{print $2}' "$(RAMP_AT_FILE)" 2>/dev/null)"
        if [[ "$rat" =~ ^[0-9]+$ ]] && (( $(now_epoch) >= rat )); then
          source "$AIMAIL_LIB/budget.sh"
          # ⛔⛔ AR-14 (project owner, 2026-09-11) — a SESSION-block boundary rolling must not lift a
          #    WEEKLY park. `budget_weekly_still_blocking` (lib/budget.sh) is the one place that
          #    decides this; see its own header for why an uncertain reading stays blocking rather
          #    than being read as safe. Checked BEFORE `budget_ramp`, never after — once
          #    `budget_ramp` runs, the throttle is already gone.
          if budget_weekly_still_blocking; then
            echo "WAKE=weekly-hold: the block boundary passed at $(date -d "@$rat" '+%F %H:%M'), but weekly usage is still at/over its cap -- staying parked, not ramping."
            echo "  ⚠ A session-block boundary rolling does not lift a WEEKLY park; only a fresh"
            echo "    weekly reading back under cap (or a human 'aimail budget ramp') does."
            # Push the recheck forward with a REAL future epoch, not empty — an empty argument to
            # `_write_ramp_at` reads as "boundary unmeasurable" and prints a misleading warning;
            # the boundary WAS measurable, we are deliberately deferring past it.
            _write_ramp_at "$(( $(now_epoch) + BUDGET_RAMP_FALLBACK_SEC ))" \
              || warn "weekly-hold: failed to push ramp_at forward — the next tick will just re-check immediately, not silently stall"
            # Deliberately no exit/return here: fall through to the ordinary
            # still-throttled park branch below (hb_park + sleep + continue),
            # exactly as if ramp_at had not yet passed.
          else
            echo "WAKE=ramp: the parked window ended at $(date -d "@$rat" '+%F %H:%M')."
            echo "  ⚠ This is a CONDITION, not a permission. It reports that a window rolled;"
            echo "    it cannot see a weekly cap or a human-imposed hold, and it does not lift one."
            # ⭐ AR-06a — lift the throttle and push ramp_at forward BEFORE exiting,
            #    by calling budget_ramp() itself — the SAME function a human or
            #    autopilot calls — rather than re-deriving "clear + advance" a
            #    second, possibly-diverging way. Without this, a poller restarted
            #    right after firing sees the SAME already-past ramp_at and fires
            #    again instantly: an infinite loop of full session turns, not a
            #    park. Any seat's poller noticing this independently also makes
            #    the un-park self-healing rather than dependent on one cron.
            budget_ramp >/dev/null 2>&1
            if (( persistent )); then
              hb_beat "$seat"; instance_beat "$seat"; _persistent_still_armed "$seat"; sleep "$interval"; continue
            else
              hb_exit "$seat" ramp; _rearm_notice "$seat"; return 0
            fi
          fi
        fi
      fi
      # Item 5 — the ramp self-heal check above always runs regardless of this
      # seat's own exemption (it benefits every OTHER seat's poller too, not
      # just this one); only the actual park-and-stop-here is skipped for an
      # exempt seat, which is what "skip the park entirely" means.
      # ─── M1 HARD STOP (the owner 2026-09-22): an exemption is honoured only BELOW the seat's own
      #   cap. `AIMAIL_SEAT_CAP_<seat>` (assistant: 95) existed for weeks with no enforcement on an
      #   unparked seat -- `budget_seat_check` was its only reader and runs from `budget watch`,
      #   which nothing schedules. The catastrophic case this closes: the unparked supervisor burns
      #   from the 90% park to the account's hard limit and dies with nothing left to wake it.
      #   The reading is the account's latest callout/probe (autopilot refreshes it every 5 min);
      #   the cap is `seat_cap` -- one definition, no second knob.
      if [[ "$_seat_exempt" -eq 1 ]]; then
        local _hs_lc _hs_pct _hs_cap
        _hs_lc="$(_last_callout 2>/dev/null || true)"; _hs_pct="$(cut -f2 <<<"$_hs_lc")"
        _hs_cap="$(seat_cap "$seat" 2>/dev/null || echo '')"
        if [[ "$_hs_pct" =~ ^[0-9]+$ && "$_hs_cap" =~ ^[0-9]+$ ]] && (( _hs_pct >= _hs_cap )); then
          _seat_exempt=0
          if [[ "$_hardstop_logged" != "$_hs_pct:$_hs_cap" ]]; then
            local _hs_rat _hs_when="the next ramp"; _hs_rat="$(awk -F'\t' '$1=="at"{print $2}' "$(RAMP_AT_FILE)" 2>/dev/null)"
            [[ "$_hs_rat" =~ ^[0-9]+$ ]] && _hs_when="$(date -d "@$_hs_rat" '+%F %H:%M')"
            echo "WAKE=hardstop: account at ${_hs_pct}% >= seat cap ${_hs_cap}% for '$seat' -- the unpark exemption is SUSPENDED; parked, waking at $_hs_when"
            echo "  ⚠ This is the hard stop below the account limit. A fresh reading under ${_hs_cap}% (or a ramp) lifts it; nothing else does."
            _hardstop_logged="$_hs_pct:$_hs_cap"
          fi
        else
          _hardstop_logged=""
        fi
      fi
      if [[ "$_seat_exempt" -eq 0 ]]; then
        hb_park "$seat"
        sleep "$interval"; continue
      fi
    fi

    # ─── Mail: the primary wake ──────────────────────────────────────────────
    # ⛔ AR-06b — count the INBOX only, never `unacked/`. Counting unacked mail
    #    here meant a seat that re-armed without acking woke instantly on the
    #    exact message it had just finished reading — an unbounded loop keyed on
    #    the seat's own unfinished bookkeeping rather than on anything new having
    #    arrived. Unacked backlog is not lost: `mail_deliver` re-surfaces it
    #    alongside the next genuine inbox wake (or `aimail deliver` on demand) —
    #    it is simply no longer, by itself, a reason to wake.
    # ⛔⛔ AR-07 / R-2 — `-type f`, matching what delivery actually treats as a
    #    message (`mail_deliver` skips non-regular entries via `[[ -f "$f" ]]`).
    #    Without this, a directory named `notes.md`, a broken symlink, or any
    #    other non-regular `*.md` entry is counted as "pending" here forever,
    #    while delivery silently skips it and removes nothing — a permanent,
    #    unclearable wake loop with no verb that can fix it, because the two
    #    predicates disagreed about what a message IS.
    local pending
    # A `--no-wake` notice is in the inbox but is not a reason to wake (it prints on the next real wake).
    pending="$(mail_pending_wake_count "$seat")"
    if (( pending > 0 )); then
      echo "WAKE=mail: $pending message(s) for '$seat'."
      mail_deliver "$seat" "$maxb"
      if (( persistent )); then
        # ⭐ THE ONE BRANCH THIS MERGE DID NOT HAVE TO CHANGE — persistent mode's own reason for
        # existing. Beats the heartbeat (same as the park branch already does while parked) and
        # loops instead of exiting; `_persistent_notice` prints the mode-aware "still armed"
        # footer instead of `_rearm_notice`'s "THIS POLLER HAS NOW EXITED".
        hb_beat "$seat"; instance_beat "$seat"
        _persistent_notice "$seat" "$pending"
        sleep "$interval"; continue
      else
        # ⇒ `reason=mail` is what turns this exit from "the poller is gone" into
        #   "the poller fired and the seat is now reading". `aimail fleet` reads it
        #   and reports RE-ARMING rather than DOWN for the whole grace window.
        hb_exit "$seat" mail
        _rearm_notice "$seat"
        return 0
      fi
    fi

    # ─── A parked seat (aimail seat park) stays armed but is not woken by anything else: the heartbeat
    #    below is skipped too. Only mail sent with --wake got past the count above. `hb_park` keeps the
    #    heartbeat honest, so the dashboard reads a deliberate park as PARKED rather than hung.
    if seat_park_active "$seat"; then
      hb_park "$seat"; instance_beat "$seat"
      sleep "$interval"; continue
    fi

    # ─── Heartbeat: the fleet-quiet safety net (see the comment above the loop) ─
    if (( heartbeat_sec > 0 )) && (( $(now_epoch) >= hb_deadline )); then
      echo "WAKE=heartbeat: no mail for ${heartbeat_sec}s — checking in anyway (fleet-quiet safety net, not a mail delivery)."
      # Held no-wake notices ride this wake: shown in full, once, like any delivery.
      if mail_has_held "$seat"; then mail_deliver "$seat" "$maxb"; fi
      echo "⛔ THIS IS NOT A NO-OP. The project owner's own words, direct: 'if you ignore it, I will fuck you up.' A quiet"
      echo "   inbox does not mean nothing to do. Before re-arming, actually check: gateclaim.sh --list"
      echo "   (any claim held far longer than the work it names should take?), whether anything you're"
      echo "   waiting on has actually landed, and whether you are genuinely working or just sitting."
      echo "   'Standing by, no new mail' as your only action on a heartbeat is exactly the failure mode"
      echo "   this message exists to stop -- re-arming without checking is not compliance, it's the bug."
      # ⭐⭐ SELF-SERVE BACKLOG (fable, 2026-09-20; design note
      #   docs/self_serve_backlog_design_2026-09-20.md; TOP PRIORITY 2, same night as the
      #   warning above): fleet throughput tonight visibly depended on assistant actively
      #   watching and dispatching -- a seat that genuinely finished its own work just sat
      #   idle on the next heartbeat instead of checking for real, unowned backlog. This is
      #   the complementary next layer on the SAME wake, not a separate mechanism: the
      #   warning above asks "are you honestly checking your own state"; this asks "if you
      #   genuinely have nothing, did you actually look for something real before standing by."
      # ⛔ SUPPRESSED WHEN THIS SEAT ALREADY HOLDS A CLAIM -- a seat mid-claim on something
      #   should keep going on THAT, not be nudged to grab a second thing at the same time.
      #   Cheap and mechanical (one grep against gateclaim's own --list), checked BEFORE any
      #   reasoning about backlog content, exactly the "cheap mechanical gate first" pattern
      #   the design note's own §2 asks for. Park-suppression needs no separate check here:
      #   this whole heartbeat branch is already unreachable while genuinely parked (see the
      #   `throttled` check earlier in this same loop) -- true by construction, not by an
      #   added guard.
      if ! "$AIMAIL_HOME/bin/gateclaim.sh" --list 2>/dev/null | awk -v s="$seat" '$2==s{f=1} END{exit !f}'; then
        echo "   ⭐ YOU HOLD NO CLAIM RIGHT NOW. If you genuinely have nothing queued, do not just"
        echo "      stand by: read TODO.md's most recent entries for a real item that is (a) actually"
        echo "      unowned as of its OWN latest ruling (not a stale earlier line — TODO.md is"
        echo "      append-only, a later dated ruling can supersede an earlier one in the same entry),"
        echo "      (b) not explicitly marked as waiting on the project owner's own word, and (c) genuinely in"
        echo "      your own established lane. If one exists: gateclaim.sh <key> $seat --desc \"why\","
        echo "      then start working. If the claim is refused (someone else got there first), fall"
        echo "      back to standing by -- do not grab something else impulsively instead. Either way,"
        echo "      mail assistant a brief note of what you did (self-claimed X, or found nothing real"
        echo "      to self-claim) so this stays visible, not silent."
      fi
      if (( persistent )); then
        # ⚠ THE DEADLINE MUST ADVANCE HERE. Classic poll never needed this: exiting and being
        # re-invoked naturally resets `hb_deadline` from a fresh process. A persistent loop that
        # only `continue`d would recompute the SAME true condition on the very next tick, 5s
        # later, and fire WAKE=heartbeat forever instead of once per `heartbeat_sec`.
        hb_deadline=$(( $(now_epoch) + heartbeat_sec ))
        hb_beat "$seat"; instance_beat "$seat"
        _persistent_still_armed "$seat"
        sleep "$interval"; continue
      else
        hb_exit "$seat" heartbeat
        _rearm_notice "$seat"
        return 0
      fi
    fi

    hb_beat "$seat"; instance_beat "$seat"
    sleep "$interval"
  done
}

# ⛔⛔ RESTORED 2026-09-11 (fable's finding): this definition was LOST during the ramp-exit
# merge -- `_poller_loop`'s mail branch calls `_persistent_notice` (unchanged from before the
# merge), but the merge's own file surgery deleted the function itself along with the old
# `poller_run_persistent` block it used to sit beside, and no test caught the gap because
# nothing in this file's own test coverage asserts stderr is clean on a real mail delivery.
# `bash` has no `set -e` here, so the loop survived and kept looping -- it just printed
# "_persistent_notice: command not found" to stderr on every single mail wake instead of the
# mode-aware footer below.
_persistent_notice() {
  local seat="$1" n="$2"
  echo "▶ still armed (persistent) -- delivered $n message(s) for '$seat', no re-arm needed;"
  echo "   this Monitor keeps watching. (If this line is missing and nothing fires again,"
  echo "   the watch itself may have died -- check its own completion status, not this seat's"
  echo "   mail queue, to tell 'quiet' from 'dead'.)"
  # ⛔⛔ MEASURED, fable's 15:32 finding: a Monitor notification can TRUNCATE a body for display
  # even though the underlying delivery (and the Monitor's own output file) holds it in full --
  # a one-shot poller's reader looks at the task's OUTPUT FILE and never hits this, but a
  # persistent-poller reader looking only at the notification text can act on a body that
  # differs from the one actually sent. Every message header already prints its own real byte
  # count ("(NNNNB, written ...)"); the instruction below is what was missing, not the data.
  echo "   ⚠ If any body above looks cut short, compare it against the (NNNNB) size in its own"
  echo "   header -- on a mismatch, read the real one with \`aimail show $seat <id>\` (or this"
  echo "   Monitor's own task output file) before acting on it."
}

# ⭐ THE RAMP/HEARTBEAT COUNTERPART TO `_persistent_notice` — same "still armed, no action
# needed" reassurance, worded for a wake that carried no mail to summarize. Kept separate rather
# than overloading `_persistent_notice` with an optional/empty count: a reader searching this
# file for "what does a ramp wake print in persistent mode" should not have to parse a mail-
# shaped message to find out it does not apply here.
_persistent_still_armed() {
  local seat="$1"
  echo "▶ still armed (persistent) -- noted, no action needed; this Monitor keeps watching."
  echo "   (If this line is missing and nothing fires again, the watch itself may have died --"
  echo "   check its own completion status, not this seat's mail queue, to tell 'quiet' from"
  echo "   'dead'.)"
}

# ═══ PERSISTENT VARIANT — docs/ISSUES_2026-08-20.md item 1 (owner-approved, 2026-09-10);
# merged into the shared `_poller_loop` above 2026-09-10 (fable's ramp-exit finding) ═══════════
# `poller_run_persistent` is now a thin wrapper, matching `poller_run`'s own shape exactly --
# see `_poller_loop`'s own header comment for why the two loop bodies are one function now.
poller_run_persistent() {
  local seat_arg="${1:-}"
  [[ -n "$seat_arg" ]] || refused "usage: aimail poll-persistent <seat>"
  local seat; seat="$(seat_resolve "$seat_arg")" || exit $?

  # Read by `mail_deliver`'s own footer (lib/mail.sh) so it prints a mode-aware step 2 instead
  # of the false "re-arm" instruction -- exported BEFORE the reexec below so it survives the
  # `exec` into the private copy (bash `exec` into another script keeps exported vars).
  export AIMAIL_POLL_PERSISTENT=1

  _poller_reexec_private_persistent "$seat"
  _poller_loop "$seat" 1
}


# _poller_own_sid / poller_superseded <seat> — the session this poller runs inside (from the env the
#   harness sets) and whether the seat record lists it as retired (`retired_sessions <state>:<sid>@<time>`).
_poller_own_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; }
poller_superseded() {
  local seat="$1" sid; sid="$(_poller_own_sid)"; [[ -n "$sid" ]] || return 1
  local f="$STATE_DIR/seat_account/$seat"; [[ -f "$f" ]] || return 1
  awk -F'\t' -v s="$sid" '$1=="retired_sessions" { v=$2; sub(/^[a-z]+:/, "", v); sub(/@.*$/, "", v); if (v==s) found=1 } END{exit !found}' "$f"
}
