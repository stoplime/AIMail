# shellcheck shell=bash
# budget.sh — the 5-hour block, the throttle, and the checkpoint.
#
# ═══ THE ONE IDEA THIS FILE IS BUILT AROUND ═══════════════════════════════════
#
#   THE BLOCK BOUNDARY IS MEASURABLE. THE PERCENTAGE IS NOT.
#
# Everything that must work unattended is keyed on the BOUNDARY, and only the
# advisory parts are keyed on the percentage. The predecessor did the opposite,
# and it is why its most important action — "write your ROLE.md before the window
# ends" — was gated on its least reliable input and fired at the worst moment.
#
# WHY THE PERCENTAGE CANNOT BE MEASURED FROM HERE:
#   `/usage` shows the official session %, weekly %, and reset time, and it is
#   NOT programmatically accessible — not via statusLine, hooks, files, an API,
#   or an environment variable. The request to expose it (anthropics/claude-code
#   issue #20636) was closed unimplemented. So a human reading `/usage` aloud is
#   the ONLY source of a true level, and that is a property of the platform, not
#   a gap in this tool. `budget callout` is therefore first-class, not a fallback.
#
# WHY THE BOUNDARY *IS* MEASURABLE:
#   A block starts at your first message and runs exactly 5 hours. `ccusage`
#   reads the same local transcripts and models this as an ANCHORED block, so
#   the end time is known HOURS in advance and needs no percentage at all.
#
# ⛔⛔ THE ONE THING NEVER TO DO HERE — it broke the predecessor twice:
#   DO NOT "FIX" A BOUNDARY OVER-READ BY RESCALING THE BUDGET. A trailing 5h
#   window over-reads right after a reset BY CONSTRUCTION (it still reaches into
#   the dead block — measured 90% against an official 30%). Rescaling to correct
#   that makes it UNDER-report for the rest of the window, which invents
#   headroom. The predecessor's calibration history walked 200M → 189M → 200M,
#   two "corrections" in opposite directions that cancelled out. This file uses
#   anchored blocks instead, so the boundary artefact does not arise.

BUDGET_CACHE() { echo "$STATE_DIR/block.json"; }
BUDGET_CACHE_TTL="${AIMAIL_BLOCK_TTL:-60}"
CHECKPOINT_MIN="${AIMAIL_CHECKPOINT_MIN:-45}"   # write ROLE.md this many minutes before block end
PARK_MIN="${AIMAIL_PARK_MIN:-10}"               # park this many minutes before block end

# ─── Account identity ─────────────────────────────────────────────────────────
# The VS Code profile switcher repoints the ~/.claude SYMLINK at a per-profile
# config directory, so the link target names the active account. That also means
# each account has its own transcripts under its own projects/ tree, so anything
# derived from them is already per-account — no cross-contamination to correct.
#
# ⚠ WHY THIS MATTERS BEYOND BOOKKEEPING: one configured threshold once governed
#   every account, but a SHARED account must park lower than a private one —
#   overrunning there spends someone else's tokens, and they are not in the
#   conversation to object. Nobody should discover which account they are on
#   from a lockout.
account_id() {
  local t
  t="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null)"
  [[ -n "$t" ]] || { echo "unknown"; return 0; }
  basename "$t" | sed 's/^\.//; s/^claude-//; s/^claude$/default/'
}

account_cap() {
  local acct; acct="$(account_id)"
  local var="AIMAIL_CAP_${acct//[^a-zA-Z0-9_]/_}"
  local v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  echo "${AIMAIL_CAP_DEFAULT:-90}"
}

# ─── The block, from ccusage ──────────────────────────────────────────────────
# ⛔ IF IT CANNOT MEASURE, IT SAYS SO. It does not return zero, and it does not
#    fall back to a guess. "Unmeasurable" and "zero" are different claims, and
#    zero reads as safe in whichever direction happens to be dangerous — a 0%
#    burn rate was once read as "the fleet is idle, poke it".
block_json() {
  local cache; cache="$(BUDGET_CACHE)"
  if [[ -f "$cache" ]]; then
    local age=$(( $(now_epoch) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))
    (( age < BUDGET_CACHE_TTL )) && { cat "$cache"; return 0; }
  fi
  command -v npx >/dev/null 2>&1 || return 1
  local tmp; tmp="$(mktemp "$STATE_DIR/.block.XXXXXX")"
  # ⚠ The exit status is captured directly, not through a pipe. A pipeline's
  #   status is its LAST command's, so `ccusage | jq` would report jq's success
  #   even when ccusage failed — and a well-formed empty result is exactly the
  #   shape that reads as "nothing to worry about".
  if timeout "${AIMAIL_CCUSAGE_TIMEOUT:-120}" npx --yes ccusage@latest blocks --json > "$tmp" 2>/dev/null; then
    [[ -s "$tmp" ]] && { mv -f "$tmp" "$cache"; cat "$cache"; return 0; }
  fi
  rm -f "$tmp"; return 1
}

# block_field <key> — start|end|remaining_min|tokens|cost|burn_per_min
block_field() {
  block_json 2>/dev/null | python3 -c "
import json,sys,datetime
try: d=json.load(sys.stdin)
except Exception: sys.exit(4)
blocks = d['blocks'] if isinstance(d,dict) else d
act=[b for b in blocks if b.get('isActive')]
if not act: sys.exit(4)
b=act[0]
k='$1'
def iso(s): return datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
if   k=='start':         print(int(iso(b['startTime']).timestamp()))
elif k=='end':           print(int(iso(b['endTime']).timestamp()))
elif k=='remaining_min': print(int(b.get('projection',{}).get('remainingMinutes', -1)))
elif k=='tokens':        print(b.get('totalTokens',0))
elif k=='cost':          print(round(b.get('costUSD',0),2))
elif k=='burn_per_min':  print(int(b.get('burnRate',{}).get('tokensPerMinuteForIndicator',0)))
else: sys.exit(4)
" 2>/dev/null
}

# ─── The callout ledger — the ONLY authoritative level ────────────────────────
# TSV: epoch <TAB> account <TAB> pct <TAB> source <TAB> block_end
#
# ⛔⛔ READ IT WITH awk -F'\t', NEVER `IFS=$'\t' read`. Tab is IFS whitespace, so
#    CONSECUTIVE TABS COLLAPSE: a row with an empty middle field yields fewer
#    fields than it has columns and every later field shifts left. In the
#    predecessor this silently blinded a cold-start guard, and the fleet would
#    have been re-throttled ~23 minutes after resuming on a fabricated
#    183%/hour rate. The first fix patched two of three call sites, and leaving
#    the third — the throttle path — live read exactly like a whole fix.
budget_callout() {
  local pct="${1:-}"
  [[ "$pct" =~ ^[0-9]+$ ]] && (( pct <= 100 )) || refused "usage: aimail budget callout <0-100>" \
    "This records a percentage READ FROM /usage — the only authoritative level." \
    "It is not an estimate and must not be one."
  ensure_dirs
  local be; be="$(block_field end 2>/dev/null || echo '')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(account_id)" "$pct" "callout" "${be:-}" >> "$LEDGER"
  ok "recorded ${pct}% for account '$(account_id)' (cap $(account_cap)%)"
}

_last_callout() { # prints: epoch<TAB>pct  for THIS account, or nothing
  [[ -s "$LEDGER" ]] || return 1
  awk -F'\t' -v a="$(account_id)" '$2==a && $4=="callout"{e=$1; p=$3} END{if(e) printf "%s\t%s", e, p}' "$LEDGER"
}

# ─── Status ───────────────────────────────────────────────────────────────────
budget_status() {
  local acct cap; acct="$(account_id)"; cap="$(account_cap)"
  info "account: $acct    cap: ${cap}%    $(instrument_id)"
  echo

  local bs be rem tok burn
  bs="$(block_field start)"; be="$(block_field end)"
  rem="$(block_field remaining_min)"; tok="$(block_field tokens)"; burn="$(block_field burn_per_min)"

  if [[ -z "$be" ]]; then
    # ⛔ Not "0 minutes remaining". That would read as "the block just ended".
    unmeasurable "the active 5-hour block could not be read" \
      "Tried: npx ccusage@latest blocks --json" \
      "Without a block boundary, the checkpoint and ramp cannot be scheduled." \
      "Everything below depends on it, so nothing is reported rather than guessed."
  fi

  echo "MEASURED — the anchored 5-hour block (from local transcripts):"
  printf '  started        %s\n' "$(date -d "@$bs" '+%F %H:%M')"
  printf '  ends           %s   (in %s min)\n' "$(date -d "@$be" '+%F %H:%M')" "$(( (be - $(now_epoch)) / 60 ))"
  printf '  tokens so far  %s\n' "$tok"
  printf '  burn/min       %s\n' "$burn"
  echo

  local lc lc_e lc_p
  lc="$(_last_callout || true)"
  if [[ -n "$lc" ]]; then
    lc_e="${lc%%$'\t'*}"; lc_p="${lc##*$'\t'}"
    local age; age="$(age_min "$lc_e")"
    echo "MEASURED — the last /usage callout (the only true level):"
    # ⚠ ALWAYS PRINT THE ANCHOR'S AGE. A watchdog once advised a fleet-wide
    #   stop from "last callout 77%" where the 77% was FROM THE PREVIOUS DAY.
    #   Position in a report reads as authority; age is what makes it checkable.
    printf '  %s%%  taken %s min ago\n' "$lc_p" "$age"
    if (( lc_e < bs )); then
      # ⛔ A window CLOSING is a RESET, not a budget being spent. Treating a
      #    close as exhaustion once fenced four seats for ~50 minutes.
      printf '  ⛔ STALE: this callout predates the current block. It describes a DEAD window.\n'
      printf '     Ask for a fresh reading before acting on any level.\n'
    elif (( lc_p >= cap )); then
      printf '  ⚠ at or over the %s%% cap for this account\n' "$cap"
    fi
  else
    echo "UNMEASURED — no /usage callout recorded for this account."
    echo "  The level is unknown. Only the BLOCK BOUNDARY above is known, and that"
    echo "  is enough to schedule the checkpoint and the ramp."
    echo "  ▶ aimail budget callout <pct>   after reading /usage"
  fi
  echo
  echo "SCHEDULE — keyed on the boundary, not on a percentage:"
  printf '  checkpoint at  %s   (block end − %s min)\n' \
    "$(date -d "@$(( be - CHECKPOINT_MIN*60 ))" '+%H:%M')" "$CHECKPOINT_MIN"
  printf '  park at        %s   (block end − %s min)\n' \
    "$(date -d "@$(( be - PARK_MIN*60 ))" '+%H:%M')" "$PARK_MIN"
  printf '  ramp at        %s   (the block rolls)\n' "$(date -d "@$be" '+%H:%M')"
  echo
  local th="$STATE_DIR/throttled"
  [[ -f "$th" ]] && { warn "THROTTLE IS IN FORCE:"; sed 's/^/    /' "$th"; }
  return 0
}

# ─── Park / ramp ──────────────────────────────────────────────────────────────
# ⛔⛔ PARK MEANS PARK, NOT DISARM. Every seat's poller detects the throttle flag
#    and SLEEPS on it. A parked poller is a sleeping shell costing zero tokens
#    and it WAKES ITSELF at the ramp. A disarmed poller also costs zero and NEVER
#    WAKES — only a human can restart it. The two are identical on a token bill
#    and opposite in recoverability.
# ⭐ MEASURED COST OF CONFUSING THEM: a coordinator once told every seat to
#    disarm at the cap. The window reopened at 06:24 with nothing left to wake;
#    three seats never woke at all and it took a human 3h24m later to end it.
#    ⇒ Never tell a seat to disarm. Set the flag; the pollers park themselves.
budget_park() {
  local reason="${*:-scheduled park before the block boundary}"
  ensure_dirs
  local be; be="$(block_field end 2>/dev/null || echo '')"
  if [[ -f "$STATE_DIR/throttled" ]]; then
    info "already parked — leaving the original reason in place:"; sed 's/^/  /' "$STATE_DIR/throttled"; return 0
  fi
  { printf 'PARKED %s\n' "$(now_iso)"
    printf 'ACCOUNT %s (cap %s%%)\n' "$(account_id)" "$(account_cap)"
    printf 'REASON %s\n' "$reason"
    [[ -n "$be" ]] && printf 'RAMP %s\n' "$(date -d "@$be" '+%F %H:%M')"
    printf 'SEATS park themselves via this flag. NO mail was sent, deliberately —\n'
    printf '      a broadcast at the cap spends the last tokens of the window.\n'
    printf 'STAY ARMED. Your poller sleeps on this flag and wakes you at the ramp.\n'
  } | atomic_write "$STATE_DIR/throttled"
  # ⛔ WRITE THE RAMP BEFORE ANYTHING ELSE IS PARKED. Three individually-correct
  #    disarms once removed every path back. Never remove the last wake path.
  [[ -n "$be" ]] && printf 'at\t%s\n' "$be" | atomic_write "$STATE_DIR/ramp_at"
  ok "fleet PARKED. Pollers stay armed and will wake at $( [[ -n "$be" ]] && date -d "@$be" '+%H:%M' || echo 'the ramp' )."
}

budget_ramp() {
  rm -f "$STATE_DIR/throttled"
  printf '%s\n' "$(now_epoch)" > "$STATE_DIR/fleet_resumed_at"
  # Re-arm the gate 20 minutes out rather than deleting it: if this ramp does not
  # actually result in the seats being woken, it must fire AGAIN. Deleting the
  # trigger is how a ramp silently no-ops.
  printf 'at\t%s\n' "$(( $(now_epoch) + 1200 ))" | atomic_write "$STATE_DIR/ramp_at"
  ok "throttle CLEARED at $(now_iso)"
  info "  ⚠ This is a CONDITION, not a permission. It reports that a block rolled."
  info "    It cannot see a WEEKLY cap or a human-imposed hold, and it lifts neither."
  info "  ▶ Get a fresh /usage callout before trusting any level: every pre-ramp"
  info "    reading describes a window that no longer exists."
}

# ─── Checkpoint — the reason this file exists ─────────────────────────────────
# ⭐⭐ Ask every seat to write its ROLE.md while there is still budget to do it.
#    When the account is switched, each session's context goes with it, so the
#    ROLE.md files ARE the handover — a seat that did not write one resumes blind.
# ⇒ THIS FIRES ON THE CLOCK, NOT ON A PERCENTAGE. The block end is known hours
#   ahead; the percentage is not knowable from here at all. Gating the single
#   most important action on the least reliable input is what made this fragile
#   before.
budget_checkpoint() {
  local force="${1:-}"
  local be; be="$(block_field end)" || true
  [[ -n "$be" ]] || unmeasurable "cannot read the block end, so the checkpoint cannot be scheduled" \
    "A checkpoint fired at the wrong time is worse than none: it spends budget" \
    "writing a handover nobody needed yet."
  local left=$(( (be - $(now_epoch)) / 60 ))
  if [[ "$force" != "--now" ]] && (( left > CHECKPOINT_MIN )); then
    info "not due: ${left} min left, checkpoint at ${CHECKPOINT_MIN} min before the end"
    return 0
  fi
  local marker="$STATE_DIR/checkpoint_done"
  if [[ "$(cat "$marker" 2>/dev/null)" == "$be" ]]; then
    # ⛔ Key the marker on the BLOCK END, not a boolean. `now >= X` stays true
    #    forever once true, so a boolean turns this into a wake loop that fires
    #    every poll — the most expensive possible bug in a supervision path.
    #    A genuinely NEW block has a new end and must still fire.
    info "already checkpointed for the block ending $(date -d "@$be" '+%H:%M')"
    return 0
  fi

  # ⛔⛔ VALIDATE THE SENDER *BEFORE* DOING ANYTHING ELSE. An unregistered
  #    supervisor makes every send refuse, and this runs from cron where the
  #    refusal is seen by nobody — the fleet would simply never be asked to write
  #    its handover, and the first symptom would be seats resuming blind after an
  #    account switch.
  local from="${AIMAIL_SUPERVISOR:-assistant}"
  seat_exists "$from" || refused "the checkpoint sender '$from' is not a registered seat." \
    "The checkpoint mails every seat, so it needs a registered 'from'." \
    "  aimail seat add $from     — or set AIMAIL_SUPERVISOR to an existing seat" \
    "Nothing was sent and NO checkpoint marker was written, so this will retry."

  local body; body="$(mktemp "$AIMAIL_ROOT/tmp/ckpt.XXXXXX")"
  cat > "$body" <<EOF
# ⏱ CHECKPOINT — the 5-hour block ends at $(date -d "@$be" '+%H:%M') (${left} min)

Write **ROLE.md** now, while there is still budget to write it.

When the account is switched, every session's context switches with it. The
ROLE.md files are the entire handover: a seat that has not written one resumes
blind and re-derives work that was already done.

Put in it, concretely:
- what is DONE, with the evidence (a sha, a path, a command and its output)
- what is IN FLIGHT, and the exact next step
- what it is BLOCKED on, and who owes the answer

Then **stay armed**. The poller parks itself on the throttle flag and wakes at
the ramp. Do not disarm it — a parked poller wakes itself, a disarmed one never
does, and only a human can restart a seat that has gone dark.

⚠ This is scheduled from the BLOCK BOUNDARY, which is measured. It is not a
statement about how much budget is left, which is not measurable from here.
EOF

  local seat n=0
  while IFS= read -r seat; do
    [[ -n "$seat" ]] || continue
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    mail_send --to "$seat" --from "$from" \
      --subject "CHECKPOINT write ROLE.md block ends $(date -d "@$be" '+%H%M')" \
      --body-file "$body" >/dev/null 2>&1 && n=$((n+1))
  done < <(seat_names)
  rm -f "$body"

  # ⛔⛔ THE MARKER IS WRITTEN ONLY AFTER A SEND ACTUALLY SUCCEEDED. Writing it
  #    first — which this did — means a checkpoint that failed to send still
  #    records itself as done, so it NEVER RETRIES for that block. The fleet
  #    would skip its handover silently, and the only symptom would appear hours
  #    later as seats resuming with no ROLE.md after an account switch.
  # ⚠ A guard that suppresses a RETRY is far more dangerous than one that allows
  #   a duplicate: a second checkpoint mail costs a few tokens, a missed one
  #   costs the handover.
  if (( n > 0 )); then
    printf '%s' "$be" > "$marker"
    ok "checkpoint sent to $n seat(s) — block ends $(date -d "@$be" '+%H:%M')"
  else
    unmeasurable "the checkpoint reached 0 seats — no marker written, it will retry" \
      "Every send failed. Check the registry: aimail seat list"
  fi
}

# ─── Autopilot — the single cron entry point ──────────────────────────────────
# ⛔⛔ THIS BELONGS IN CRON, NOT IN A SESSION. A background task started by a
#    session is a CHILD of that session, so it dies when the session dies —
#    which is exactly the scenario night mode exists to survive. Being late for
#    a status check costs nothing; being late for a ramp costs the night.
#
#   */5 * * * * /path/to/bin/aimail budget autopilot >> ~/.aimail/state/autopilot.log 2>&1
budget_autopilot() {
  local be now; now="$(now_epoch)"
  be="$(block_field end)" || {
    # ⚠ Refuse loudly rather than doing nothing quietly. A silent no-op here is
    #   indistinguishable from a healthy tick, and the failure would only surface
    #   as a fleet that never checkpointed.
    warn "autopilot: block end UNMEASURABLE — no checkpoint, park or ramp performed"
    return 4
  }
  local left=$(( (be - now) / 60 ))
  info "autopilot $(now_iso): block ends $(date -d "@$be" '+%H:%M'), ${left} min left, account $(account_id) cap $(account_cap)%"

  # Ramp first: a block that has already rolled invalidates everything below it.
  if [[ -f "$STATE_DIR/throttled" ]] && (( now >= be )); then
    budget_ramp; return 0
  fi
  (( left <= CHECKPOINT_MIN )) && budget_checkpoint
  if (( left <= PARK_MIN )) && [[ ! -f "$STATE_DIR/throttled" ]]; then
    budget_park "automatic: ${PARK_MIN} min before the block boundary at $(date -d "@$be" '+%H:%M')"
  fi
  return 0
}
