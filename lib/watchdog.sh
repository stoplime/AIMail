# shellcheck shell=bash
# watchdog.sh — mechanical, cron-driven checks that need ZERO cooperation or
# memory from any seat's own turn. See docs/mechanical_watchdog_design_2026-09-20.md
# for the full design and the incident that minted this file.
#
# ⛔⛔ WHY THIS EXISTS, NOT AS PART OF fleet_sweep's EXISTING CLASSIFIER: a real
#   incident (2026-09-20) had a seat's live session sit `state: "blocked"` per
#   `claude agents --json` for 2+ hours while its own poller kept firing
#   normal 30-minute heartbeats and a real go-ahead sat unprocessed the whole
#   time. `aimail fleet <seat>` / fleet_sweep's existing session classifier
#   (lib/sessions.sh) is TRANSCRIPT-mtime-based and has no "blocked" concept
#   at all — a session can be internally wedged while its transcript still
#   looks recently-touched. This reads `claude agents --json` DIRECTLY, a
#   fact about the process the harness itself manages, independent of
#   anything any seat's own poller reports.
#
# ⛔⛔ THIS FILE UNDEFINED UNTIL SOURCED — same law as budget.sh's own header.
#   fleet_watchdog_sessions() calls ACCOUNT_CONFIG_DIR/_autopilot_seat_groups/
#   account_id (budget.sh) and seat_exists/mail_send (registry.sh/mail.sh) —
#   the CLI dispatch sources budget.sh before this file for exactly that
#   reason; a caller sourcing this file standalone must do the same.

# WATCHDOG_BLOCKED_STREAK_FILE <seat> — per-seat consecutive-non-working-tick
# counter, same idiom as budget.sh's AUTOPILOT_STREAK_FILE.
WATCHDOG_BLOCKED_STREAK_FILE() { echo "$STATE_DIR/watchdog_blocked_streak_$1"; }
WATCHDOG_ALERT_DIR() { echo "$STATE_DIR/watchdog_alerted"; }

# AIMAIL_WATCHDOG_BLOCKED_STREAK — consecutive ticks (at the cron cadence,
# 5 min) before alerting. Default 3 = 15 minutes, REUSING fable's own already-
# ruled AUTOPILOT_UNMEASURABLE_N number (budget.sh) rather than inventing a
# second threshold for the same "how long before this pages someone" question
# — long enough that one transient `claude agents --json` blip never pages
# anyone, short enough that this never again runs blind for hours the way
# today's incident did (2+ hours undetected).
WATCHDOG_BLOCKED_N="${AIMAIL_WATCHDOG_BLOCKED_STREAK:-3}"

# _watchdog_session_seat <sessionId> — the seat this session id is registered
# to, via stop_guard.sh's own existing registration file
# ($STATE_DIR/stopguard/session.<sid>, written by `stop_guard.sh register
# <seat>` at the start of every session per the aimail skill's own standing
# checklist). Prints nothing if unregistered — a known, by-design pass-
# through (the same convention poller_guard.sh already uses for a stray
# human/subagent session), not a defect this watchdog needs to solve.
_watchdog_session_seat() {
  local sid="${1:?usage: _watchdog_session_seat <sessionId>}"
  local f="$STATE_DIR/stopguard/session.$sid"
  [[ -f "$f" ]] && cat "$f" || true
}

# _watchdog_accounts — the account pool to check, same fallback shape
# budget_pool()/budget_pick_account() already use: AIMAIL_FLEET_ACCOUNTS if
# set, else whatever accounts currently have a live, resolved seat (via
# _autopilot_seat_groups, budget.sh), else just the ambient account_id() so a
# single-account deployment still gets a real check.
_watchdog_accounts() {
  if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
    printf '%s\n' $AIMAIL_FLEET_ACCOUNTS
    return 0
  fi
  local line acct found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    acct="$(cut -f2 <<<"$line")"
    if [[ -n "$acct" ]]; then printf '%s\n' "$acct"; found=1; fi
  done < <(_autopilot_seat_groups 2>/dev/null || true)
  (( found )) || account_id
}

# ⛔⛔ REAL BUG FOUND SMOKE-TESTING THIS AGAINST LIVE STATE (2026-09-20): the
#   first draft alerted on ANY state != "working", which fired on `"done"` --
#   a background session's own NORMAL, EXPECTED terminal state once its turn
#   finishes and the process exits (observed live: code-review's own poller
#   task reading "done" seconds after it genuinely completed). Alerting on
#   the routine, healthy case is exactly the "an alert that fires on the
#   healthy case teaches its reader to ignore it" lesson fleet_sweep's own
#   STALLED-threshold tuning already paid for once (lib/fleet.sh's own
#   comment on that incident) -- not repeating it here. WATCHDOG_OK_STATES
#   is the allowlist of CONFIRMED-benign values; still an allowlist, not a
#   denylist of just "blocked" (the design note's own reasoning holds: an
#   unknown future state should fail toward alerting, not silence) -- it was
#   simply incomplete on the first pass, not wrong in kind.
WATCHDOG_OK_STATES="working done"
_watchdog_state_ok() {
  local state="$1" s
  for s in $WATCHDOG_OK_STATES; do [[ "$state" == "$s" ]] && return 0; done
  return 1
}

# _watchdog_agents_json <account_config_dir> — prints one line per BACKGROUND
# session: "<sessionId>\t<state>". Empty output (not an error) when the
# account has no live sessions, no credentials, or `claude`/python3 aren't
# available — every caller treats "nothing printed" as "nothing to check",
# never as a signal on its own.
_watchdog_agents_json() {
  local dir="${1:?usage: _watchdog_agents_json <account_config_dir>}"
  command -v claude >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  [[ -r "$dir/.credentials.json" ]] || return 0
  local json; json="$(CLAUDE_CONFIG_DIR="$dir" claude agents --json 2>/dev/null)" || return 0
  [[ -n "$json" ]] || return 0
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in data:
    if d.get("kind") != "background":
        continue
    sid = d.get("sessionId", "")
    state = d.get("state", "")
    if sid:
        print(f"{sid}\t{state}")
' 2>/dev/null
}

# ⛔⛔ SECOND REAL BUG FOUND SMOKE-TESTING AGAINST LIVE STATE: `framing`'s own
#   genuinely healthy, idle, ARMED seat (confirmed: `aimail fleet framing`
#   reads ARMED/idle, its transcript's last write is a clean turn_duration
#   completion 7 minutes prior, `aimail status framing` shows 0 queued/0
#   unacked) reads `{"status":"busy","state":"blocked"}` in `claude agents
#   --json` -- IDENTICAL shape to what the actual incident's own wedged
#   session reported. Every OTHER live session checked also read
#   `status: "busy"` regardless of whether it was genuinely working, which
#   confirms `status` never distinguishes anything either. **The state/status
#   fields alone, even combined, do NOT reliably tell a genuine wedge apart
#   from a session simply idle between invocations** -- "blocked" appears to
#   be Claude Code's own ordinary term for "not currently generating," which
#   describes the OVERWHELMING MAJORITY of any healthy seat's own idle time,
#   not a failure signature.
# ⭐⭐ THE FIX: reread the incident report itself for the signature that
#   actually separates the two cases -- "a real go-ahead message sat
#   DELIVERED-BUT-UNPROCESSED... the whole time." That is a mechanically
#   checkable fact this fleet ALREADY surfaces (`aimail fleet`/`aimail
#   status`'s own QUEUED/UN-ACKED columns) and is exactly the state a
#   healthily-idle seat with an empty inbox (framing, confirmed above) does
#   NOT have. Alerting on "non-working state" ALONE would have paged a
#   supervisor about ordinary idle time constantly, in the "an alert that
#   fires on the healthy case teaches its reader to ignore it" shape this
#   fleet has paid for before (fleet_sweep's own STALLED-threshold history).
#   The real check is the CONJUNCTION: session not working/done, AND real
#   pending mail sitting for this seat, sustained over the streak window --
#   reproducing the incident's own signature directly, not a proxy for it.

# _watchdog_seat_has_pending_mail <seat> — true (exit 0) iff the seat has mail
# that is a real reason to be awake: a top-level inbox message that would wake
# it (mail_pending_wake_count: a --no-wake notice, and any mail held for a
# parked seat, are not counted), or anything in its `unacked/` folder
# (delivered, not yet acted on). A held notice is waiting by design, so it must
# never read as "blocked with pending mail".
_watchdog_seat_has_pending_mail() {
  local seat="${1:?usage: _watchdog_seat_has_pending_mail <seat>}"
  local q u
  q="$(mail_pending_wake_count "$seat")"
  u="$(find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)"
  (( q > 0 || u > 0 ))
}

# fleet_watchdog_sessions — the session-state check (design note §3, revised
# per the two live findings above). Loops the account pool, reads `claude
# agents --json` per account, maps each background session to its seat via
# stop_guard's own registration file, and alerts a supervisor when a
# REGISTERED seat's session reads a non-working/done state AND has real
# pending mail, sustained for WATCHDOG_BLOCKED_N consecutive ticks. A
# non-working state with an EMPTY mailbox is ordinary idle time, never
# alerted on. Self-heals: recovery (working/done, or the pending mail clears,
# or the session exits) resets the streak/alert, no separate "recovered"
# mail — same one-directional dedup philosophy fleet_sweep's own
# CRASHED/WEDGED/STALLED alerts already use.
fleet_watchdog_sessions() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  ensure_dirs
  mkdir -p "$(WATCHDOG_ALERT_DIR)"

  local -a accounts=()
  local a
  while IFS= read -r a; do [[ -n "$a" ]] && accounts+=("$a"); done < <(_watchdog_accounts)

  local n_checked=0 n_alerts=0
  local acct dir sid state seat
  for acct in "${accounts[@]}"; do
    dir="$(ACCOUNT_CONFIG_DIR "$acct" 2>/dev/null || true)"
    [[ -n "$dir" ]] || continue
    while IFS=$'\t' read -r sid state; do
      [[ -n "$sid" ]] || continue
      seat="$(_watchdog_session_seat "$sid")"
      [[ -n "$seat" ]] || continue
      n_checked=$((n_checked+1))

      local streak_file; streak_file="$(WATCHDOG_BLOCKED_STREAK_FILE "$seat")"
      local state_bad=0 has_mail=0
      [[ -n "$state" ]] && ! _watchdog_state_ok "$state" && state_bad=1
      _watchdog_seat_has_pending_mail "$seat" && has_mail=1
      if (( state_bad )) && (( has_mail )); then
        local n; n=$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" > "$streak_file"
        info "watchdog: seat '$seat' session $sid state='$state' WITH pending mail (tick $n of $WATCHDOG_BLOCKED_N before alert)"
        if (( n >= WATCHDOG_BLOCKED_N )); then
          local marker="$(WATCHDOG_ALERT_DIR)/$seat" key="$sid:$state"
          if [[ "$(cat "$marker" 2>/dev/null)" != "$key" ]]; then
            if seat_exists "$supervisor"; then
              local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/watchdog.XXXXXX")"
              { printf '# \xf0\x9f\x94\xb4 WATCHDOG: seat %s session state is "%s" WITH real pending mail, sustained %s consecutive 5-min ticks (%s min)\n\n' \
                  "$seat" "$state" "$n" "$(( n * 5 ))"
                printf 'account: %s   session id: %s\n\n' "$acct" "$sid"
                printf 'This reading is from `claude agents --json` directly -- INDEPENDENT of this\n'
                printf 'seat'"'"'s own poller heartbeat, which can read fine while the underlying session\n'
                printf 'is wedged (the 2026-09-20 incident this check exists to catch: a session sat\n'
                printf 'blocked for 2+ hours while its poller kept cycling normal heartbeats and a real\n'
                printf 'go-ahead sat delivered-but-unprocessed the whole time).\n\n'
                printf 'NOT alerted on session state alone: a non-"working" state with an EMPTY mailbox\n'
                printf 'is ordinary idle time between invocations (confirmed live, 2026-09-20 -- a\n'
                printf 'genuinely healthy, ARMED, idle seat also reads "blocked" the entire time it\n'
                printf 'waits for its next wake). This alert fired because real mail is ALSO sitting\n'
                printf 'unprocessed for this seat right now -- check: aimail status %s\n\n' "$seat"
                printf 'No human asked for this -- the watchdog found it unprompted.\n'
                printf 'Check directly: CLAUDE_CONFIG_DIR=%s claude agents --json | python3 -m json.tool\n' "$dir"
                printf 'This does not kill or restart anything -- that needs a human/supervisor decision.\n'
              } > "$body"
              if mail_send --to "$supervisor" --from "$supervisor" \
                   --subject "WATCHDOG: $seat session is $state WITH pending mail (${n}x5=$(( n * 5 ))min)" \
                   --body-file "$body" >/dev/null 2>&1; then
                printf '%s' "$key" > "$marker"; n_alerts=$((n_alerts+1))
              fi
              rm -f "$body"
            else
              warn "watchdog: seat '$seat' session is $state but supervisor '$supervisor' is not registered -- no alert sent"
            fi
          fi
        fi
      else
        rm -f "$streak_file" "$(WATCHDOG_ALERT_DIR)/$seat"
      fi
    done < <(_watchdog_agents_json "$dir")
  done

  info "watchdog: checked $n_checked registered session(s) across ${#accounts[@]} account(s), $n_alerts new alert(s)"
}


# ═══ SUPERVISOR LIVENESS + WAKE (the owner 2026-09-22, top budget item) ═════════════════════════
# ⛔ THE CATASTROPHIC CASE: the supervisor keeps burning, its account hits the hard limit, the
#   session dies or blocks, and after the reset NOTHING wakes it -- its poller is a harness
#   Monitor the supervisor re-arms itself, so a dead supervisor has no poller left. Only a wake
#   that does not depend on the supervisor's own session can close that: this runs from cron
#   (`aimail fleet watchdog`, every 5 min) and uses the session registry (lib/seatmigrate.sh)
#   for WHERE the supervisor's session is and WHAT to resume.
# DECISION TABLE (one line each, in this order):
#   parked, ramp not reached          -> nothing (a wake into a park just sleeps)
#   live + poller ARMED/PARKED/RE-ARM -> nothing
#   live + session mid-turn (working) -> nothing (never interrupt a turn)
#   live + poller down                -> WAKE: flagless `claude --bg --resume <sid> "<wake prompt>"`
#                                        in its own account dir (the CLI's "continues <sid> itself"
#                                        path; ⚠ needs one live drill before it is trusted)
#   dead / failed / unlisted          -> RESUME: the same command with the boot prompt
#   attempt limit reached, or resume  -> ESCALATE once per episode: mail the vice orchestrator
#   recorded `failed`                    (AIMAIL_VICE_SUPERVISOR, default main) with the exact
#                                        command, mail AIMAIL_HUMAN_ALERT_SEAT if set, write the
#                                        ALERT marker every dashboard prints first.
# EPISODE = the account's current ramp_at (or "unparked"); attempts reset when it changes.
SUPERVISOR_WAKE_DIR()   { echo "$STATE_DIR/supervisor_wake"; }
_sw_attempts_file()     { echo "$(SUPERVISOR_WAKE_DIR)/attempts"; }
_sw_log()               { echo "$(SUPERVISOR_WAKE_DIR)/log"; }
_sw_note() { mkdir -p "$(SUPERVISOR_WAKE_DIR)"; printf '%s\t%s\n' "$(now_iso)" "$*" >> "$(_sw_log)"; info "watchdog/supervisor: $*"; }

_sw_wake_prompt() { # <seat> <mode: wake|boot>
  if [[ "$2" == "boot" ]]; then
    printf 'Hi %s, this is the fleet watchdog (cron). Your session was found dead or failed after a budget ramp and has been RESUMED by `aimail fleet watchdog` from the session registry. Run `aimail session %s`, fix what it flags, arm your poller as a Monitor, read your mail, then continue your role handover'"'"'s live work.\n' "$1" "$1"
  else
    printf 'Hi %s, this is the fleet watchdog (cron). Your poller was found DOWN after a ramp while your session was idle. Re-arm it now as a Monitor (`aimail poll-persistent %s`), run `aimail session %s`, read your mail, then continue.\n' "$1" "$1" "$1"
  fi
}

_sw_escalate() { # <seat> <reason> <command-hint>
  local seat="$1" reason="$2" hint="$3"
  local vice="${AIMAIL_VICE_SUPERVISOR:-main}" human="${AIMAIL_HUMAN_ALERT_SEAT:-}"
  local f; f="$(SUPERVISOR_ALERT_FILE)"
  { printf '%s -- %s\n' "$(now_iso)" "$reason"
    printf 'supervisor seat: %s\n' "$seat"
    printf 'wake command (run it from any shell): %s\n' "$hint"
    printf 'never stop/kill/bounce the current session; a NEW %s only after every same-session attempt fails, launched WITH: claude --remote-control %s --bg "<boot prompt>"\n' "$seat" "$seat"
    printf 'clear this alert once the supervisor is back and ARMED: aimail fleet supervisor-ack\n'
    printf 'log: %s\n' "$(_sw_log)"
  } | atomic_write "$f"
  _sw_note "ESCALATED: $reason"
  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/supwake.XXXXXX" 2>/dev/null || mktemp)"
  { printf '# ⛔ SUPERVISOR UNREACHABLE: %s\n\n%s\n\n' "$seat" "$reason"
    printf 'The cron watchdog could not bring the supervisor back. Do this now, from any shell:\n\n    %s\n\n' "$hint"
    printf 'NEVER stop, kill or bounce the current %s session (owner rule 2026-09-23): resume the SAME id first, as above.\n' "$seat"
    printf 'Only if every same-session attempt fails, launch a NEW %s WITH Remote Control ON, under the seat name, and tell the owner the new id at once:\n\n    cd <the seat cwd> && CLAUDE_CONFIG_DIR=<dir> claude --remote-control %s --bg "<boot prompt>"\n\n' "$seat" "$seat"
    printf 'Then confirm with `aimail fleet %s` (ARMED) and clear the alert: `aimail fleet supervisor-ack`.\n' "$seat"
    printf 'Attempt log: %s\n' "$(_sw_log)"
  } > "$body"
  local rcpt
  for rcpt in "$vice" "$human"; do
    [[ -n "$rcpt" && "$rcpt" != "$seat" ]] || continue
    seat_exists "$rcpt" || { _sw_note "escalation recipient '$rcpt' is not a registered seat"; continue; }
    mail_send --to "$rcpt" --from "$rcpt" --subject "SUPERVISOR UNREACHABLE: $seat -- $reason" --body-file "$body" >/dev/null 2>&1 \
      && _sw_note "escalation mailed to $rcpt" || _sw_note "escalation mail to $rcpt FAILED"
  done
  rm -f "$body"
}

supervisor_alert_clear() { rm -f "$(SUPERVISOR_ALERT_FILE)"; rm -f "$(_sw_attempts_file)"; _sw_note "alert cleared"; ok "supervisor alert cleared"; }

# fleet_watchdog_supervisor — one tick. Prints what it decided; exit 0 always (a watchdog that
# dies on its own error is the one watchdog you do not have).
# _sw_transcript_age <config-dir> <sid> — seconds since the session's transcript last changed, or
#   nothing when no transcript exists under that account. ⛔ THE CHEAP LIVENESS ORACLE the 00:25
#   incident lacked: `claude agents --json` did not list the supervisor's session at all while it was
#   alive and working, so the locate said DEAD, the watchdog booted a copy, and the copy self-confirmed
#   as the seat. A transcript that changed minutes ago is a live session whatever the listing says.
_sw_transcript_age() {
  local dir="$1" sid="$2" f now m
  f="$(ls -t "$dir"/projects/*/"$sid".jsonl 2>/dev/null | head -1)"; [[ -n "$f" ]] || return 1
  m="$(stat -c %Y "$f" 2>/dev/null)" || return 1; now="$(now_epoch)"; echo $(( now - m ))
}
# _sw_stop_verified <config-dir> <sid> — `claude stop`, then wait (bounded) until the listing no longer
#   shows the session live. 0 = gone; 1 = still listed (a stop that did not take is never followed by
#   a resume: that is how the second copy 04542d5a was made).
# ⛔ THE SUPERVISOR IS NEVER STOPPED (owner rule 2026-09-23 08:50, after the 00:25 replacement and the 08:38
#   ghost): no seat, no watchdog tick and no vice ever runs `claude stop`, a kill or a bounce on the
#   supervisor's own session, and never launches a replacement supervisor on its own. Waking it means
#   resuming the SAME session id with a prompt; a copy answer proves the original is alive -> the COPY is
#   stopped, the original is retried on a later tick, and a human is told when the retries run out. A NEW
#   supervisor is a human's decision, launched WITH Remote Control ON under the seat's own name so the
#   owner can find it (`claude --remote-control <seat> --bg ...`; see _sw_escalate). Two live sessions for
#   the seat: stop nothing, report both ids. `_SW_PROTECT_SID` is the id the current tick guards;
#   the seat record is the fallback so the refusal holds when this helper is called on its own.
_SW_PROTECT_SID=""
_sw_supervisor_sid() {
  [[ -n "$_SW_PROTECT_SID" ]] && { echo "$_SW_PROTECT_SID"; return 0; }
  seat_record_read "${AIMAIL_SUPERVISOR:-assistant}" session_id 2>/dev/null || true
}
_sw_is_supervisor_sid() { # <sid or short id>
  local q="$1" sup; sup="$(_sw_supervisor_sid)"
  [[ -n "$q" && -n "$sup" && ( "$q" == "$sup" || "$sup" == "$q"* ) ]]
}
_sw_stop_verified() {
  local dir="$1" sid="$2" i
  if _sw_is_supervisor_sid "$sid"; then
    _sw_note "REFUSED: stop of the supervisor's own session ${sid:0:8} -- the supervisor is never stopped, killed or bounced (owner rule 2026-09-23); a human decides"
    return 2
  fi
  CLAUDE_CONFIG_DIR="$dir" _claude stop "${sid:0:8}" >/dev/null 2>&1 || true
  for i in 1 2 3 4 5 6 7 8 9 10; do _sid_listed "$dir" "$sid"; (( $? == 1 )) && return 0; sleep "${AIMAIL_SUPERVISOR_STOP_POLL_S:-1}"; done
  _sid_listed "$dir" "$sid"; (( $? == 1 ))
}

fleet_watchdog_supervisor() {
  local seat="${AIMAIL_SUPERVISOR:-assistant}"
  local retries="${AIMAIL_SUPERVISOR_WAKE_RETRIES:-3}"
  seat_exists "$seat" || { info "watchdog/supervisor: '$seat' is not a registered seat -- nothing to guard"; return 0; }
  source "${BASH_SOURCE[0]%/*}/seatmigrate.sh" 2>/dev/null || true
  mkdir -p "$(SUPERVISOR_WAKE_DIR)"

  # where is it, per the registry + the live listing
  local loc rc=0; loc="$(seat_session_locate "$seat" 2>/dev/null)" || rc=$?
  local liveness sid acct dir state
  liveness="$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$loc")"
  sid="$(awk -F'\t' '$1=="sid"{print $2}' <<<"$loc")"
  acct="$(awk -F'\t' '$1=="account"{print $2}' <<<"$loc")"
  dir="$(awk -F'\t' '$1=="config_dir"{print $2}' <<<"$loc")"
  state="$(awk -F'\t' '$1=="state"{print $2}' <<<"$loc")"
  if (( rc == 3 )); then
    # ⛔ two live sessions for the supervisor seat: STOP NOTHING; tell the vice and the human both ids and
    #   ask which one is in use (owner rule 2026-09-23, item 4). Reported once per id set, not every tick.
    local twins; twins="$(awk -F'\t' '$1=="twin"{print $2":"substr($3,1,8)"("$6")"}' <<<"$loc" | sort | paste -sd' ')"
    local tkey; tkey="$(printf '%s' "$twins" | sha1sum | cut -c1-12)"
    if [[ "$(cat "$(SUPERVISOR_WAKE_DIR)/twins_reported" 2>/dev/null)" != "$tkey" ]]; then
      printf '%s' "$tkey" > "$(SUPERVISOR_WAKE_DIR)/twins_reported"
      local vice="${AIMAIL_VICE_SUPERVISOR:-main}" human="${AIMAIL_HUMAN_ALERT_SEAT:-}" rcpt tb
      tb="$(mktemp "${AIMAIL_ROOT}/tmp/suptwin.XXXXXX" 2>/dev/null || mktemp)"
      { printf '# TWO live sessions for the supervisor seat %s\n\n%s\n\n' "$seat" "$twins"
        printf 'Nothing was stopped and nothing will be (owner rule 2026-09-23: never kill or replace the supervisor).\n'
        printf 'The owner says which one is in use; the other is stopped by a human, never by the fleet.\n'
      } > "$tb"
      for rcpt in "$vice" "$human"; do
        [[ -n "$rcpt" && "$rcpt" != "$seat" ]] && seat_exists "$rcpt" || continue
        mail_send --to "$rcpt" --from "$rcpt" --subject "TWO live $seat sessions: $twins -- stop nothing; which one is in use?" --body-file "$tb" >/dev/null 2>&1 || true
      done
      rm -f "$tb"
    fi
    _sw_note "twins found for '$seat' ($twins) -- not touching either; reported (see aimail seat locate $seat)"; return 0
  fi
  if (( rc == 2 )); then _sw_note "live listing UNKNOWN (an account did not answer) -- no action this tick"; return 0; fi
  if [[ -z "$acct" ]]; then acct="$(seat_record_read "$seat" account 2>/dev/null || echo '')"; fi
  if [[ -z "$dir" && -n "$acct" ]]; then dir="$(ACCOUNT_CONFIG_DIR "$acct" 2>/dev/null || echo '')"; fi
  if [[ -z "$sid" && -n "$acct" ]]; then sid="$(seat_sessions_get "$seat" "$acct" 2>/dev/null || seat_record_read "$seat" session_id 2>/dev/null || echo '')"; fi

  _SW_PROTECT_SID="$sid"   # from here on, no path in this tick may stop this id (see _sw_stop_verified)

  # parked and the ramp is still ahead: nothing to wake into
  local episode="unparked"
  if [[ -n "$acct" && -f "$(THROTTLE_FLAG "$acct")" ]]; then
    local rat; rat="$(awk -F'\t' '$1=="at"{print $2}' "$(RAMP_AT_FILE "$acct")" 2>/dev/null)"
    if [[ "$rat" =~ ^[0-9]+$ ]] && (( $(now_epoch) < rat )); then
      info "watchdog/supervisor: '$seat' account '$acct' is parked until $(date -d "@$rat" '+%F %H:%M') -- nothing to wake into"; return 0
    fi
    episode="ramp:${rat:-unknown}"
  fi

  # attempts are per episode
  local ep_prev="" n_prev=""
  if [[ -f "$(_sw_attempts_file)" ]]; then IFS=$'\t' read -r ep_prev n_prev < "$(_sw_attempts_file)" || true; fi
  [[ "$ep_prev" == "$episode" && "$n_prev" =~ ^[0-9]+$ ]] || n_prev=0

  # live and healthy?
  if [[ "$liveness" == "live" ]]; then
    local pstate; pstate="$(poller_state "$seat" 2>/dev/null | cut -f1 || echo '?')"
    case "$pstate" in
      ARMED|PARKED|RE-ARMING) info "watchdog/supervisor: '$seat' live, poller $pstate -- healthy"; rm -f "$(_sw_attempts_file)"; return 0 ;;
    esac
    if [[ "$state" == "working" ]]; then info "watchdog/supervisor: '$seat' live and mid-turn (state working), poller $pstate -- not interrupting"; return 0; fi
  fi

  # something to do: wake (live, poller down) or resume (dead)
  local mode="boot"; [[ "$liveness" == "live" ]] && mode="wake"
  if [[ -z "$sid" || -z "$dir" ]]; then
    _sw_escalate "$seat" "no session id or account known for '$seat' (registry empty) -- cannot resume" "aimail seat sessions $seat   # then: CLAUDE_CONFIG_DIR=<dir> claude --bg --resume <sid> \"<boot prompt>\""
    return 0
  fi
  local hint="cd <the seat's cwd> && CLAUDE_CONFIG_DIR=$dir claude --bg --resume $sid \"<boot prompt>\""
  if (( n_prev >= retries )); then
    [[ -f "$(SUPERVISOR_ALERT_FILE)" ]] || _sw_escalate "$seat" "$n_prev wake/resume attempt(s) this episode ($episode) did not bring '$seat' back (liveness=$liveness)" "$hint"
    return 0
  fi
  # ⛔ WHERE the resume runs from. A dead seat's locate row carries no cwd; the seat record and the
  #   saved launch spec are the only honest sources (`seat_cwd_resolve`, shared with seat migrate).
  #   Never the cron's own $PWD: a supervisor woken in the wrong directory is worse than one left
  #   dead, because nothing else is watching it (code-review gate 32d414f..1d40463, 2026-09-22).
  local cwd; cwd="$(awk -F'\t' '$1=="cwd"{print $2}' <<<"$loc")"
  if [[ -z "$cwd" || ! -d "$cwd" ]]; then
    local _res; _res="$(seat_cwd_resolve "$seat" "$sid" "$dir" 2>/dev/null || true)"
    cwd="${_res%%$'\t'*}"
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
      [[ -f "$(SUPERVISOR_ALERT_FILE)" ]] || _sw_escalate "$seat" "no working directory known for ${sid:0:8} (no live listing, no cwd in the seat record, no saved launch spec${cwd:+, '$cwd' is not a directory here}) -- a resume from the watchdog's own \$PWD would put '$seat' in the WRONG directory, so nothing was launched" \
        "aimail seat migrate $seat $acct --cwd <the supervisor's project dir>   # or: cd <that dir> && CLAUDE_CONFIG_DIR=$dir claude --bg --resume $sid \"<boot prompt>\""
      return 0
    fi
    _sw_note "cwd for '$seat' from ${_res#*$'\t'}: $cwd"
  fi
  if [[ "$mode" == "boot" ]]; then
    local _tage; _tage="$(_sw_transcript_age "$dir" "$sid" 2>/dev/null || true)"
    if [[ "$_tage" =~ ^[0-9]+$ ]] && (( _tage < ${AIMAIL_SUPERVISOR_ALIVE_WINDOW_SEC:-1800} )); then
      _sw_note "'$seat' reads dead in the listing but its transcript changed ${_tage}s ago -- ALIVE, unlisted; not launching (a poller-down live seat is a WAKE condition its own mail satisfies)"
      return 0
    fi
  fi
  local n=$((n_prev+1)); printf '%s\t%s\n' "$episode" "$n" > "$(_sw_attempts_file)"
  local out; out="$(cd "$cwd" && CLAUDE_CONFIG_DIR="$dir" _claude --bg --resume "$sid" "$(_sw_wake_prompt "$seat" "$mode")" 2>&1)" || true
  _sw_note "$mode attempt $n/$retries for '$seat' on '$acct' (sid ${sid:0:8}): ${out:-<no output>}"
  local js; js="$(_job_state "$dir" "$sid" 2>/dev/null || true)"
  if [[ "${js%%$'\t'*}" == "failed" ]]; then
    _sw_escalate "$seat" "resume of ${sid:0:8} on '$acct' FAILED in the scheduler: ${js#*$'\t'}" "$hint"
    return 0
  fi
  if grep -q 'started a copy as' <<<"$out"; then
    # ⛔ "started a copy" PROVES the original is alive. It is a bounce trigger ONLY when the listing
    #   says the original is limit-BLOCKED (idle at a limit, nothing in flight); an unlisted or working
    #   original is left alone. The 00:25 incident: a copy answer read as "blocked leftover", an
    #   unverified stop, a second copy, and the escalation path left that copy running to self-confirm
    #   as the seat. Every copy this function creates is stopped before it can boot.
    local copy; copy="$(grep -oE 'started a copy as [0-9a-fA-F-]+' <<<"$out" | awk '{print $5}' | head -1)"
    [[ -n "$copy" ]] && { _sw_stop_verified "$dir" "$copy" || _sw_note "copy ${copy:0:8} did not stop on request"; }
    local orig_state; orig_state="$(_agents_rows "$dir" --all 2>/dev/null | awk -F'\t' -v s="$sid" '$1==s{print $4; exit}')"
    if [[ "$orig_state" != "blocked" ]]; then
      _sw_note "wake copied (${copy:0:8}, stopped) -- ${sid:0:8} is ALIVE (listing: ${orig_state:-unlisted}); NOT bouncing"
      printf '%s\t%s\n' "$episode" "$n_prev" > "$(_sw_attempts_file)"   # a live seat burns no retry
      return 0
    fi
    # ⛔ limit-BLOCKED original: it used to be bounced here (verified stop + flagless resume). The owner rule of
    #   2026-09-23 ends that: the supervisor is NEVER stopped. The attempt stays burnt, the same id is retried
    #   on a later tick, and when the retries run out a human decides (never a stop, never a silent fresh launch).
    _sw_note "wake copied (${copy:0:8}, stopped) -- ${sid:0:8} is limit-BLOCKED; the supervisor is NEVER bounced (owner rule 2026-09-23): the same session is retried on a later tick ($n/$retries)"
    if (( n >= retries )); then
      [[ -f "$(SUPERVISOR_ALERT_FILE)" ]] || _sw_escalate "$seat" "${sid:0:8} is limit-blocked and answered $n resume(s) with a copy (every copy stopped, the original never touched) -- a human decides; never stop it" "$hint"
    fi
  fi
  return 0
}
