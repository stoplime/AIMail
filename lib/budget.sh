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
  # ⛔ HERMETIC BY CONSTRUCTION, NOT BY TIMING LUCK. With AIMAIL_NO_NETWORK=1 this
  #    never shells out — it uses the cache or fails. The suite sets it, because a
  #    test that reaches the network hangs on a slow day and then gets "fixed" by
  #    raising a timeout until it stops proving anything. Measured: a stubbed block
  #    whose 60s cache expired mid-run turned a unit test into a live ccusage call
  #    and the suite produced NO OUTPUT for two minutes.
  [[ "${AIMAIL_NO_NETWORK:-0}" == "1" ]] && return 1
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
  local pct="${1:-}"; shift || true
  local resets="" left=""
  while (( $# )); do
    case "$1" in
      --resets) resets="$2"; shift 2 ;;   # HH:MM, exactly as /usage prints it
      --left)   left="$2";   shift 2 ;;   # minutes remaining, if that is easier
      *) refused "unknown callout argument: '$1'" "Try: --resets HH:MM | --left <minutes>" ;;
    esac
  done
  [[ "$pct" =~ ^[0-9]+$ ]] && (( pct <= 100 )) || refused "usage: aimail budget callout <0-100> [--resets HH:MM | --left <min>]" \
    "This records a percentage READ FROM /usage — the only authoritative level." \
    "It is not an estimate and must not be one."
  ensure_dirs

  # ⭐⭐ RECORD THE RESET TIME TOO, BECAUSE /usage PRINTS IT RIGHT NEXT TO THE
  #    PERCENTAGE and it is the only authoritative boundary that exists.
  # ⛔ MEASURED 2026-08-04, and this is why the argument exists: ccusage FLOORS a
  #    block's start to the hour (startTime came back 18:00:00 exactly), so its
  #    end is LATE by however far into the hour the block really began. Against a
  #    /usage reading of "1h40m left" at 20:59 — a real reset of 22:40 — ccusage
  #    claimed 23:00. **Twenty minutes late, in the dangerous direction:** a park
  #    scheduled at end−10 would have fired at 22:50, i.e. AFTER the boundary it
  #    exists to get ahead of, so the fleet would never have parked at all.
  local reset_epoch=""
  if [[ -n "$left" ]]; then
    [[ "$left" =~ ^[0-9]+$ ]] || refused "--left takes minutes as a number."
    reset_epoch=$(( $(now_epoch) + left * 60 ))
  elif [[ -n "$resets" ]]; then
    reset_epoch="$(date -d "today $resets" +%s 2>/dev/null)" \
      || refused "--resets could not be parsed: '$resets'" "Give it as HH:MM, e.g. --resets 22:40"
    # A reset that has already passed today means tomorrow.
    (( reset_epoch <= $(now_epoch) )) && reset_epoch="$(date -d "tomorrow $resets" +%s)"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(account_id)" "$pct" "callout" "${reset_epoch:-}" >> "$LEDGER"
  ok "recorded ${pct}% for account '$(account_id)' (cap $(account_cap)%)"
  if [[ -n "$reset_epoch" ]]; then
    info "  authoritative reset: $(date -d "@$reset_epoch" '+%F %H:%M') — this now governs the schedule"
  else
    warn "  no reset time given. The schedule will fall back to ccusage, which floors"
    warn "  the block start to the hour and therefore reads LATE. Prefer:"
    warn "    aimail budget callout $pct --resets HH:MM   (as /usage prints it)"
  fi
}

_last_callout() { # prints: epoch<TAB>pct<TAB>reset_epoch  for THIS account
  [[ -s "$LEDGER" ]] || return 1
  awk -F'\t' -v a="$(account_id)" \
    '$2==a && $4=="callout"{e=$1; p=$3; r=$5} END{if(e) printf "%s\t%s\t%s", e, p, r}' "$LEDGER"
}

# ⭐⭐ THE EFFECTIVE BOUNDARY — prints: epoch<TAB>source
#
# Two candidates, and they are NOT equally trustworthy:
#   callout  the reset time a human read from /usage. AUTHORITATIVE.
#   ccusage  derived from local transcripts, and LATE BY CONSTRUCTION because it
#            floors the block start to the hour (measured 20 min late).
#
# ⛔ WHEN THEY DISAGREE, TAKE THE EARLIER ONE, and say so. The asymmetry is the
#    whole argument: being EARLY costs one checkpoint mail nobody needed, while
#    being LATE means the park fires after the boundary and the fleet never parks
#    — it just hits the cap mid-work with no handover written. A cheap false
#    positive beats an expensive false negative every time here.
block_end_effective() {
  local cc lc lc_e lc_r
  cc="$(block_field end 2>/dev/null || echo '')"
  lc="$(_last_callout 2>/dev/null || true)"
  lc_e="$(cut -f1 <<<"${lc:-}")"; lc_r="$(cut -f3 <<<"${lc:-}")"

  # A callout's reset only describes the block it was taken in. Once that reset
  # has passed, it describes a DEAD window and must not govern anything.
  if [[ "$lc_r" =~ ^[0-9]+$ ]] && (( lc_r > $(now_epoch) )); then
    if [[ "$cc" =~ ^[0-9]+$ ]]; then
      local d=$(( cc > lc_r ? cc - lc_r : lc_r - cc ))
      if (( d > 300 )); then
        warn "boundary disagreement: /usage says $(date -d "@$lc_r" '+%H:%M'), ccusage says $(date -d "@$cc" '+%H:%M') ($(( d/60 )) min apart)"
        warn "  using the EARLIER. ccusage floors the block start to the hour, so it reads late."
      fi
      (( lc_r < cc )) && { printf '%s\tcallout\n' "$lc_r"; return 0; }
      printf '%s\tccusage\n' "$cc"; return 0
    fi
    printf '%s\tcallout\n' "$lc_r"; return 0
  fi
  [[ "$cc" =~ ^[0-9]+$ ]] && { printf '%s\tccusage\n' "$cc"; return 0; }
  return 1
}

# ─── Status ───────────────────────────────────────────────────────────────────
budget_status() {
  local acct cap; acct="$(account_id)"; cap="$(account_cap)"
  info "account: $acct    cap: ${cap}%    $(instrument_id)"
  echo

  local bs be be_src rem tok burn eff
  bs="$(block_field start)"
  rem="$(block_field remaining_min)"; tok="$(block_field tokens)"; burn="$(block_field burn_per_min)"
  eff="$(block_end_effective || true)"
  be="$(cut -f1 <<<"${eff:-}")"; be_src="$(cut -f2 <<<"${eff:-}")"

  if [[ -z "$be" ]]; then
    # ⛔ Not "0 minutes remaining". That would read as "the block just ended".
    unmeasurable "the active 5-hour block could not be read" \
      "Tried: npx ccusage@latest blocks --json" \
      "Without a block boundary, the checkpoint and ramp cannot be scheduled." \
      "Everything below depends on it, so nothing is reported rather than guessed."
  fi

  echo "DERIVED — the block as ccusage reads it (local transcripts):"
  printf '  started        %s   ⚠ floored to the hour, so the end reads LATE\n' "$(date -d "@$bs" '+%F %H:%M')"
  printf '  tokens so far  %s\n' "$tok"
  printf '  burn/min       %s\n' "$burn"
  echo
  echo "EFFECTIVE BOUNDARY — source: $be_src"
  printf '  ends           %s   (in %s min)\n' "$(date -d "@$be" '+%F %H:%M')" "$(( (be - $(now_epoch)) / 60 ))"
  [[ "$be_src" == "ccusage" ]] && \
    printf '  ⚠ no fresh /usage reset time — this may be up to an hour LATE.\n     aimail budget callout <pct> --resets HH:MM\n'
  echo

  local lc lc_e lc_p
  lc="$(_last_callout || true)"
  if [[ -n "$lc" ]]; then
    lc_e="$(cut -f1 <<<"$lc")"; lc_p="$(cut -f2 <<<"$lc")"
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
# ⭐ AR-11 fallback interval — when the block boundary cannot be measured, a
#   park must still re-check soon rather than never. Matches budget_ramp's own
#   recurring safety-net interval below.
BUDGET_RAMP_FALLBACK_SEC="${AIMAIL_RAMP_FALLBACK_SEC:-1200}"

budget_park() {
  local reason="${*:-scheduled park before the block boundary}"
  ensure_dirs
  local be; be="$(block_end_effective 2>/dev/null | cut -f1 || echo '')"
  if [[ -f "$STATE_DIR/throttled" ]]; then
    info "already parked — leaving the original reason in place:"; sed 's/^/  /' "$STATE_DIR/throttled"; return 0
  fi
  # ⭐ AR-03 — `atomic_write` used as a pipe sink runs its `die` in a SUBSHELL
  #   (bash forks the receiving end of a pipe). `set -uo pipefail` means the
  #   PIPELINE's own exit status correctly reflects that failure, but nothing
  #   here was reading it — so a failed write was followed, unconditionally,
  #   by `ok "fleet PARKED"`. At the cap on a shared account that prints
  #   success while spending the NEXT session's tokens on work that was never
  #   actually parked. Check the pipeline's exit status explicitly; `pipefail`
  #   only computes the number, it does not act on it for you.
  { printf 'PARKED %s\n' "$(now_iso)"
    printf 'ACCOUNT %s (cap %s%%)\n' "$(account_id)" "$(account_cap)"
    printf 'REASON %s\n' "$reason"
    [[ -n "$be" ]] && printf 'RAMP %s\n' "$(date -d "@$be" '+%F %H:%M')"
    printf 'SEATS park themselves via this flag. NO mail was sent, deliberately —\n'
    printf '      a broadcast at the cap spends the last tokens of the window.\n'
    printf 'STAY ARMED. Your poller sleeps on this flag and wakes you at the ramp.\n'
  } | atomic_write "$STATE_DIR/throttled" \
    || die "budget park: failed to write the throttle flag — the fleet is NOT parked. Nothing else was written."
  # ⛔ WRITE THE RAMP BEFORE ANYTHING ELSE IS PARKED. Three individually-correct
  #    disarms once removed every path back. Never remove the last wake path.
  # ⭐ AR-11 — this used to be `[[ -n "$be" ]] && printf ... | atomic_write`,
  #   which wrote NOTHING when the block boundary was unmeasurable: a park with
  #   `throttled` set and no `ramp_at` at all has NO self-wake path, ever — the
  #   exact "never remove the last wake path" invariant this comment already
  #   names, violated by the code directly beneath it. Fall back to a recurring
  #   recheck instead of skipping the write: if the boundary is unmeasurable
  #   NOW, ask again soon rather than parking forever on that account.
  local rat; rat="${be:-$(( $(now_epoch) + BUDGET_RAMP_FALLBACK_SEC ))}"
  printf 'at\t%s\n' "$rat" | atomic_write "$STATE_DIR/ramp_at" \
    || die "budget park: failed to write ramp_at — the fleet would park with NO wake path. Not proceeding."
  [[ -z "$be" ]] && warn "block boundary unmeasurable — ramp_at set to a $(( BUDGET_RAMP_FALLBACK_SEC / 60 ))-min recheck instead of the real boundary"
  ok "fleet PARKED. Pollers stay armed and will wake at $( [[ -n "$be" ]] && date -d "@$be" '+%H:%M' || echo "a recheck in $(( BUDGET_RAMP_FALLBACK_SEC / 60 ))min" )."
}

budget_ramp() {
  rm -f "$STATE_DIR/throttled"
  printf '%s\n' "$(now_epoch)" > "$STATE_DIR/fleet_resumed_at"
  # Re-arm the gate 20 minutes out rather than deleting it: if this ramp does not
  # actually result in the seats being woken, it must fire AGAIN. Deleting the
  # trigger is how a ramp silently no-ops.
  # AR-03 — same pipe-sink propagation as budget_park above.
  printf 'at\t%s\n' "$(( $(now_epoch) + BUDGET_RAMP_FALLBACK_SEC ))" | atomic_write "$STATE_DIR/ramp_at" \
    || die "budget ramp: failed to write the new ramp_at — the throttle was cleared but the safety-net recheck was NOT scheduled."
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
  local be; be="$(block_end_effective 2>/dev/null | cut -f1)" || true
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

Write your handover now, while there is still budget to write it.

    aimail role write <your-seat> handover.md
    aimail role write <your-seat> < handover.md      # or pipe it

⚠ Use that command, not a file path you remember. The handover does NOT live in
your inbox any more — it lives outside it, precisely so it can never be delivered
to you as mail. \`aimail role path <your-seat>\` prints the location if you want it.

When the account is switched, every session's context switches with it. Your
handover is the ONLY thing that crosses that boundary: a seat that has not written
one resumes blind and re-derives work that was already done.

Put in it, concretely:
- what is DONE, with the evidence (a sha, a path, a command and its output)
- what is IN FLIGHT, and the exact next step
- what it is BLOCKED on, and who owes the answer

Keep it CURRENT STATE, not an append-only log. A handover large enough to consume
a fresh session's context defeats the purpose it exists for.

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
  be="$(block_end_effective 2>/dev/null | cut -f1)"; [[ -n "$be" ]] || {
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
  # ⭐⭐ AR-10 — run the checkpoint in a SUBSHELL. `budget_checkpoint` uses this
  #   codebase's own refused/exit idiom (exit 3 on an unregistered sender, exit
  #   4 if the boundary can't be re-read) — correct for a direct CLI call, but
  #   FATAL here: called bare, that `exit` terminates the WHOLE autopilot
  #   invocation, and the PARK below — a SAFETY action — never runs. A single
  #   missing registry row would then silently let the fleet blow through its
  #   cap with no handover, invisible from cron (nobody reads the log unless
  #   something already looks wrong). The checkpoint is advisory; the park is
  #   not; they must not share a fatal path. `( ... )` contains the exit to the
  #   checkpoint step alone — file writes it makes still land, only its exit
  #   stops propagating past this line.
  if (( left <= CHECKPOINT_MIN )); then
    ( budget_checkpoint ) \
      || warn "autopilot: the checkpoint step failed or refused (see above) — continuing to the park check regardless; a missed checkpoint must never prevent a park"
  fi
  if (( left <= PARK_MIN )) && [[ ! -f "$STATE_DIR/throttled" ]]; then
    budget_park "automatic: ${PARK_MIN} min before the block boundary at $(date -d "@$be" '+%H:%M')"
  fi
  return 0
}
