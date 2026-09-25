# shellcheck shell=bash
# budget.sh — the 5-hour block, the throttle, and the checkpoint.
#
# ⛔⛔ ANY FUNCTION DEFINED HERE (THROTTLE_FLAG, RAMP_AT_FILE, FABLE_WEEKLY_FILE,
#   account_id, WEEKLY_FILE, ...) IS UNDEFINED UNTIL THIS FILE IS SOURCED — bash
#   does not autoload. Calling one before `source lib/budget.sh` has run in that
#   shell silently returns an empty string (command-not-found on stderr, nothing
#   on stdout), which then reads as "path is empty" -> `[[ -f "" ]]` -> false,
#   never an error a caller notices. Bit twice in one afternoon (2026-09-20): once
#   in lib/poller.sh (the throttle check ran before budget.sh's own lazy
#   in-branch source), once in a NEW TEST in tests/run.sh (called the real
#   FABLE_WEEKLY_FILE() before this file was sourced into that script's own
#   shell, which only happens later, for the AR-14 section) — same root cause,
#   different files. Before adding a caller of anything defined here, or a
#   caller of a caller, check what has actually been sourced by that point,
#   don't assume it from a nearby comment or a function's own header saying
#   "already scoped correctly" (which is a different, unrelated concern — that
#   claim is about WHICH account's state a function reads, not about whether
#   the function exists in the caller's shell at all).
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
# WHY THE PERCENTAGE CANNOT BE MEASURED FROM HERE — WAS THE FULL STORY, ISN'T ANYMORE:
#   `/usage` shows the official session %, weekly %, and reset time, and there is
#   NO OFFICIAL, DOCUMENTED way to read it — not via statusLine, hooks, files, or
#   a published API. The request to expose it (anthropics/claude-code issue
#   #20636) was closed unimplemented. `budget callout` exists because of that,
#   and stays first-class: it is the only source that is a HUMAN CLAIM, not an
#   inference, which matters when a probe's own honesty is in question.
#   ⚠ BUT: `budget probe` (below) hits an UNOFFICIAL, UNDOCUMENTED endpoint the
#   CLI's own `/status` command calls internally, using the OAuth token Claude
#   Code already stores locally. Confirmed live and working 2026-08-20. It is
#   not published, could change shape or vanish in any release with zero notice,
#   and is not the same CLAIM as a human reading /usage — so its ledger rows are
#   tagged "probe", not "callout", and every reader of this file that says
#   "callout" is describing the human path specifically, not this one.
#
# ⭐⭐ UPDATE 2026-08-21 (the project owner): now that `budget probe` is confirmed live,
#   PARK no longer needs to guess from the boundary — it checks the real
#   number (see budget_autopilot). CHECKPOINT and RAMP stay boundary-keyed on
#   purpose: the account switch happens on schedule regardless of usage, and
#   the handover has to be written before it, not "whenever tokens run low."
#   Park was the one action this file used to fire blind, and it no longer
#   has to: if there is plenty of budget left, the block just resets at the
#   ramp on its own, with no quiet period forced beforehand.
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

# ⭐ 2026-09-17: keyed by account_id(), not a single fixed filename. Added
#   alongside per-account autopilot -- two account groups processed in the
#   same tick (or even the same 60s TTL window) would otherwise share ONE
#   cached ccusage blob, so the second group's read could silently return the
#   FIRST group's own block data mislabeled as its own. account_id() already
#   respects CLAUDE_CONFIG_DIR, which budget_autopilot's per-group loop sets
#   before calling into this, so this naturally reads/writes the right file
#   for whichever account is currently in scope. Filename changes on upgrade
#   (old `block.json` is simply orphaned, not migrated) -- a one-time cold
#   cache on the first tick after deploying, harmless.
BUDGET_CACHE() { echo "$STATE_DIR/block.$(account_id).json"; }
BUDGET_CACHE_TTL="${AIMAIL_BLOCK_TTL:-60}"
CHECKPOINT_MIN="${AIMAIL_CHECKPOINT_MIN:-45}"   # write ROLE.md this many minutes before block end
# CALLOUT_FRESH_MIN — how recently a callout/probe must have been TAKEN (its
# own record epoch, never the boundary it reports) to be trusted outright over
# ccusage's coarser estimate. 20 min tolerates ~3 missed 5-min autopilot
# probe ticks, matching the same order of magnitude as AUTOPILOT_UNMEASURABLE_N
# below. See block_end_effective's own header comment for the defect this
# closes (2026-09-01: a fresh, authoritative reading lost to ccusage's cruder
# guess purely because the guess said something numerically earlier).
CALLOUT_FRESH_MIN="${AIMAIL_CALLOUT_FRESH_MIN:-20}"
# PARK_MIN removed 2026-08-21 (the project owner): park no longer fires on a fixed
# time-before-boundary window. See budget_autopilot -- it now probes real
# usage and only parks when the account is actually at/over its cap.

# fleet.sh owns hb_read/HB_FILE (seat_account_dir below needs them) but is not
# always sourced alongside this file -- bin/aimail's `budget)` dispatch sources
# ONLY budget.sh, which is exactly the code path cron's `budget autopilot`
# runs. Source it defensively so this file is self-sufficient standalone.
# Idempotent: fleet.sh's top level is pure function/constant definitions, safe
# to re-source if something upstream already did.
source "${BASH_SOURCE[0]%/*}/fleet.sh" 2>/dev/null || true

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

# ─── Per-seat account detection ────────────────────────────────────────────────
# ⛔⛔ 2026-09-17 INCIDENT THIS SECTION CLOSES: account_id() above resolves via
#   the AMBIENT `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` of WHATEVER SHELL HAPPENS
#   TO BE RUNNING IT. Cron (which runs `budget autopilot` every 5 min) has no
#   CLAUDE_CONFIG_DIR set at all, so it fell through to the shared, mutable
#   `~/.claude` symlink -- which pointed at `.claude-work` from ~09:40 to
#   ~14:20 that day, while every LIVE fleet seat's own session ran explicitly
#   under CLAUDE_CONFIG_DIR=~/.claude-r2. Autopilot's park-at-cap safety net
#   spent 4+ hours watching a completely different account's usage while the
#   real one (r2) climbed unmonitored toward its own cap, then got hard
#   rate-limited, killing every session at once. the project owner's fix, via assistant:
#   make account detection AUTOMATIC and PER-SEAT, so nothing this unattended
#   ever again silently tracks the wrong account for a live seat.
#
# ⭐ THE MECHANISM: a live seat's poller is a child of the real Claude Code
#   session that armed it (`aimail poll <seat>`, launched as a background
#   shell call), so it inherited that session's REAL CLAUDE_CONFIG_DIR in its
#   own process environment -- ground truth, not configuration, and nothing
#   this file's own bookkeeping could silently drift out of sync with.
#   `/proc/<pid>/environ` (NUL-separated) reads it directly. It cannot go
#   stale independent of the process it describes: when the pid dies, this
#   signal disappears with it, and the SAME liveness test poller_state()
#   already uses below (numeric pid + `kill -0`) tells the caller not to
#   trust a dead one -- reused verbatim, not reinvented.
#
# seat_account_dir <seat> — the RAW, readlink-resolved CLAUDE_CONFIG_DIR of a
# seat's own live poller process, or EMPTY if no live per-seat signal exists
# (no heartbeat ever written, a dead pid, or a live pid whose environ has no
# CLAUDE_CONFIG_DIR at all). Returns the directory, not the short label, so a
# caller that needs to actually SET CLAUDE_CONFIG_DIR for a subprocess (e.g.
# ccusage, or the OAuth-token read in budget_probe) has the real path, not
# just something to print.
seat_account_dir() {
  local seat="${1:?usage: seat_account_dir <seat>}"
  local pid; pid="$(hb_read "$seat" pid 2>/dev/null || echo '')"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  local cfg_dir
  cfg_dir="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -n1)"
  [[ -n "$cfg_dir" ]] || return 0
  readlink -f "$cfg_dir" 2>/dev/null || true
}

# seat_account <seat> — like account_id(), but resolves the account a
# SPECIFIC LIVE SEAT is actually running under, via seat_account_dir() above.
# Falls back to the current global account_id() (crontab-pinned
# CLAUDE_CONFIG_DIR, else the shared symlink) whenever the per-seat signal
# isn't available -- NEVER crash, NEVER silently guess something new. That
# fallback is still exactly correct for "no live PID to inspect at all" (e.g.
# immediately after a crash, before anything has re-armed).
seat_account() {
  local seat="${1:?usage: seat_account <seat>}"
  local dir; dir="$(seat_account_dir "$seat")"
  if [[ -n "$dir" ]]; then
    basename "$dir" | sed 's/^\.//; s/^claude-//; s/^claude$/default/'
    return 0
  fi
  account_id
}

NIGHT_MODE_FILE() { echo "$STATE_DIR/night_mode"; }

account_cap() {
  # ⭐ 2026-09-20: optional [account] arg, defaulting to account_id() — needed
  #   for `aimail budget pool` to read a DIFFERENT account's own cap, not just
  #   the ambient one. Night/day mode still applies globally either way (it is
  #   not itself per-account), same as every existing bare call already saw.
  local acct="${1:-$(account_id)}"
  local var="AIMAIL_CAP_${acct//[^a-zA-Z0-9_]/_}"
  local v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  # Day/night is a MODE (see NIGHT_MODE_FILE below), checked only after an
  # explicit per-account override — an account genuinely singled out for its
  # own reason still wins outright, same precedence as before this existed.
  [[ -f "$(NIGHT_MODE_FILE)" ]] && { echo "${AIMAIL_CAP_NIGHT:-80}"; return 0; }
  echo "${AIMAIL_CAP_DEFAULT:-90}"
}

# budget_night / budget_day — the mode toggle itself. A flag file, same shape
# as `throttled` above, not a config edit: the swing happens every evening.
# ⚠ Per-seat overrides (AIMAIL_SEAT_CAP_<seat>, e.g. assistant's 95%) are
#   checked in seat_cap() BEFORE this ever runs and are UNAFFECTED by mode —
#   a seat given more headroom for a stated reason (staying reachable while
#   the rest of the fleet parks) keeps it regardless of day or night.
budget_night() {
  _dash_arg_guard "usage: aimail budget night" "$@"
  ensure_dirs
  printf 'NIGHT %s\n' "$(now_iso)" > "$(NIGHT_MODE_FILE)"
  ok "night mode ON — unoverridden seats now cap at ${AIMAIL_CAP_NIGHT:-80}% (day default ${AIMAIL_CAP_DEFAULT:-90}%). Per-seat overrides unaffected."
}
budget_day() {
  _dash_arg_guard "usage: aimail budget day" "$@"
  rm -f "$(NIGHT_MODE_FILE)"
  ok "day mode ON — unoverridden seats back to ${AIMAIL_CAP_DEFAULT:-90}%."
}

# seat_cap <seat> — like account_cap, but keyed on the SEAT NAME, not the
# account directory. A seat is a mail address, not necessarily a 1:1 account —
# two seats can share one account directory, so "give assistant more headroom
# than the rest" cannot be expressed as an account cap alone. Falls back to
# account_cap() when no seat-specific override is set, so an unconfigured seat
# behaves exactly as it did before this existed.
seat_cap() {
  local seat="${1:?usage: seat_cap <seat>}"
  local var="AIMAIL_SEAT_CAP_${seat//[^a-zA-Z0-9_]/_}"
  local v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  account_cap
}

# weekly_cap — the SEPARATE, ACCOUNT-WIDE weekly ceiling. the project owner's own rule:
# if the weekly number is the tighter constraint, it wins outright, regardless
# of what the session (5-hour) percentage says — a fresh session block does not
# create weekly headroom that was not already there.
# ⭐⭐ PER-ACCOUNT OVERRIDE, same shape as account_cap() above (the project owner,
#   2026-08-21): a temporary weekly bump on one account (e.g. an all-Sonnet
#   fleet burning slow tonight) must NOT silently follow a later switch to a
#   different account (e.g. one running Opus, which burns much faster) — that
#   account falls straight through to the global default below, no override
#   to remove. Checked BEFORE the global default, same precedence as
#   account_cap()'s per-account check.
weekly_cap() {
  # ⭐ 2026-09-20: optional [account] arg, same reason as account_cap() above.
  local acct="${1:-$(account_id)}"
  local var="AIMAIL_WEEKLY_CAP_${acct//[^a-zA-Z0-9_]/_}"
  local v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  echo "${AIMAIL_WEEKLY_CAP:-95}"
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
  # one resolver for the CLI (core.sh ccusage_cmd): the global install when present, npx only as
  # the fallback -- see its comment for the 2026-09-22 load measurement that made this a rule
  local -a cc=(); read -r -a cc <<<"$(ccusage_cmd 2>/dev/null || true)"; (( ${#cc[@]} )) || return 1
  local tmp; tmp="$(mktemp "$STATE_DIR/.block.XXXXXX")"
  # ⚠ The exit status is captured directly, not through a pipe. A pipeline's
  #   status is its LAST command's, so `ccusage | jq` would report jq's success
  #   even when ccusage failed — and a well-formed empty result is exactly the
  #   shape that reads as "nothing to worry about".
  if timeout "${AIMAIL_CCUSAGE_TIMEOUT:-120}" "${cc[@]}" blocks --json > "$tmp" 2>/dev/null; then
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
  case "${1:-}" in
    -h|--help)
      info "usage: aimail budget callout <0-100> [--resets HH:MM | --left <minutes>]"
      info "  Records a percentage READ FROM /usage. Nothing was changed."
      exit 0 ;;
  esac
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

  _record_reading "$pct" "${reset_epoch:-}" "callout"
  budget_refresh_ramp
}

# _record_reading <pct> <reset_epoch|empty> <source> — the ledger write both
# budget_callout and budget_probe share. Kept as one place so the TSV shape and
# the "no reset time given" warning cannot drift between the two callers.
_record_reading() {
  local pct="$1" reset_epoch="$2" source="$3"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(account_id)" "$pct" "$source" "$reset_epoch" >> "$LEDGER"
  ok "recorded ${pct}% for account '$(account_id)' (cap $(account_cap)%) [source: $source]"
  if [[ -n "$reset_epoch" ]]; then
    info "  authoritative reset: $(date -d "@$reset_epoch" '+%F %H:%M') — this now governs the schedule"
  else
    warn "  no reset time given. The schedule will fall back to ccusage, which floors"
    warn "  the block start to the hour and therefore reads LATE."
  fi
}

# ─── The probe — an unofficial API, not a human's word ────────────────────────
# Hits the SAME endpoint Claude Code's own `/status` command calls internally,
# using the OAuth token Claude Code already stores locally. Confirmed live and
# working 2026-08-20 (five_hour.utilization / seven_day.utilization / resets_at,
# all present). NOT documented by Anthropic, NOT the thing issue #20636 declined
# to build — it is unpublished and could change shape or vanish with zero notice.
#
# ⛔⛔ THE ONE RULE THIS FUNCTION MUST NOT BREAK: "IT DOES NOT FIND A FIELD, IT
#    SAYS SO." unmeasurable (exit 4) on every failure mode below — missing config
#    dir, missing/unreadable credentials, missing token, network failure, or a
#    response shape where NEITHER five_hour.utilization NOR seven_day.utilization is numeric.
#    NEVER fall through to 0 or to a stale ledger row; a caller (e.g. cron) that wants a
#    fallback reading should catch the failure and decide, not have this function decide
#    silently on its behalf. One deliberate, narrow exception (2026-09-25, NOT a violation of
#    the rule above): a NULL five_hour.utilization alongside a NUMERIC seven_day.utilization is
#    read as 0%, since that specific shape means the endpoint answered for real and no block has
#    started yet in the current window — a real, checked distinction (seven_day proves
#    reachability), never a guess offered in place of a failure.
budget_probe() {
  # ⛔⛔ HERMETIC BY CONSTRUCTION, SAME CONTRACT AS block_json (see its own
  #   comment above) — but this check was MISSING here until now. Found via a
  #   flaky test (AR-10's own suite entry): a machine with real, working
  #   Claude Code credentials makes this curl call succeed for real inside
  #   `budget_autopilot`'s park-gate, so a test that seeds a synthetic
  #   callout gets silently outrun by a genuine, unrelated, real-time usage
  #   reading — not a hang (the failure mode block_json's own guard was built
  #   for), but the same underlying non-determinism: a test suite that sets
  #   AIMAIL_NO_NETWORK=1 specifically to be hermetic was not, in fact, free
  #   of network calls, on any machine where this probe's own preconditions
  #   happen to be satisfied. Gate it the same way, first, before any other
  #   precondition check.
  [[ "${AIMAIL_NO_NETWORK:-0}" == "1" ]] && unmeasurable "network disabled (AIMAIL_NO_NETWORK=1)"
  command -v jq   >/dev/null 2>&1 || unmeasurable "jq is required for 'budget probe' and is not on PATH"
  command -v curl >/dev/null 2>&1 || unmeasurable "curl is required for 'budget probe' and is not on PATH"

  local cfg_dir cred_file token resp curl_rc pct resets_at resets_local
  cfg_dir="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null)"
  [[ -n "$cfg_dir" ]] || unmeasurable "no Claude config dir to read a token from" \
    "Checked \${CLAUDE_CONFIG_DIR:-\$HOME/.claude} — it does not resolve to anything."
  cred_file="$cfg_dir/.credentials.json"
  [[ -r "$cred_file" ]] || unmeasurable "no readable credentials file at $cred_file" \
    "This probe only works from a machine where Claude Code is already logged in."

  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$cred_file" 2>/dev/null)"
  [[ -n "$token" ]] || unmeasurable "credentials file has no claudeAiOauth.accessToken" \
    "The file exists but the shape is not what this probe expects — it may have changed."

  resp="$(curl -sS --max-time 10 https://api.anthropic.com/api/oauth/usage \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" 2>&1)"
  curl_rc=$?
  token=""   # do not let it linger in the shell's memory longer than it must
  (( curl_rc == 0 )) || unmeasurable "usage endpoint unreachable (curl exit $curl_rc)"

  pct="$(jq -r '.five_hour.utilization // empty' <<<"$resp" 2>/dev/null)"
  local five_hour_was_null=0
  if [[ ! "$pct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # ⛔⛔ 2026-09-25, REVISED after assistant's HOLD on 09edd7ad: the previous cut gated this
    #   exception on `jq -r '.five_hour.utilization | type'` == "null", which is true for BOTH an
    #   explicit null AND a missing key/object (jq's `type` cannot tell those apart) -- so a
    #   schema change that drops or renames `five_hour` entirely, with `seven_day` still numeric,
    #   was ALSO silently read as 0%. That is not the shape we have observed for "no block
    #   started" (an explicit null, seen from r2 on 2026-09-25) -- it is indistinguishable from
    #   the endpoint's own shape changing under us, on the exact code path that exists to prevent
    #   autopilot from parking a genuinely-full account at a false 0%. Require the key to be
    #   PRESENT with an EXPLICIT null instead of inferring it from `type` alone: `.five_hour` must
    #   itself be an object, that object must `has("utilization")`, and that field must be
    #   literally null. A missing `five_hour` object or a missing `utilization` field inside it
    #   now falls through to the unmeasurable refusal below, same as any other malformed shape.
    local five_hour_explicit_null=0
    jq -e '(.five_hour | type == "object") and (.five_hour | has("utilization")) and (.five_hour.utilization == null)' \
      <<<"$resp" >/dev/null 2>&1 && five_hour_explicit_null=1
    local weekly_probe; weekly_probe="$(jq -r '.seven_day.utilization // empty' <<<"$resp" 2>/dev/null)"
    if [[ "$five_hour_explicit_null" == "1" && "$weekly_probe" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      pct="0"; five_hour_was_null=1
    else
      unmeasurable "response had no numeric five_hour.utilization" \
        "This endpoint is unofficial and undocumented — it may have changed shape." \
        "Fall back to reading /usage yourself: aimail budget callout <pct> --resets HH:MM"
    fi
  fi
  pct="${pct%%.*}"   # floor to a whole percent, the same granularity /usage prints
  (( five_hour_was_null )) && info "note: five_hour.utilization was null/missing (no block has started in the current window) -- read as 0%, not guessed: seven_day was numeric, confirming the account answered for real."

  resets_at="$(jq -r '.five_hour.resets_at // empty' <<<"$resp" 2>/dev/null)"
  resets_local=""
  [[ -n "$resets_at" ]] && resets_local="$(date -d "$resets_at" '+%s' 2>/dev/null || true)"

  _record_reading "$pct" "${resets_local:-}" "probe"

  # ⭐ ALSO capture the weekly figure, same response, no second network call.
  # Kept ALSO in its own small overwrite file (unchanged below) for the fast
  # "latest reading" lookup _last_weekly()'s existing callers use — that path
  # and its tests are untouched.
  # ⭐⭐ UPDATE 2026-09-04 (the project owner, direct instruction after asking for a
  #   weekly-budget history and finding none existed): "make it record
  #   everything every time we do the budget poll... if we are already
  #   recording the session budget why do I have to ask you to build the
  #   weekly budget infrastructure too." The overwrite-only design above
  #   (comment retained below for why it was ORIGINALLY built that way) is
  #   corrected here: every weekly reading is now ALSO appended to the same
  #   TSV ledger the session reading already uses, tagged source="weekly" (a
  #   value `_last_callout`'s own filter, `$4=="callout" || $4=="probe"`,
  #   already ignores by construction — zero risk of session/weekly cross-
  #   contamination in that reader). This gives the same durable, queryable
  #   history for weekly that the session ledger already had, with no change
  #   to any existing read path, test, or the single-value cache below.
  # ORIGINAL reasoning, superseded by the above: weekly only ever needs "the
  # latest reading", never a history (the project owner was explicit on 2026-08-25:
  # no burn-rate/trend tracking yet, it would be too bursty to page on), so
  # a small overwrite file was the right amount of machinery at the time —
  # extending the TSV schema for a value nothing read as a series yet would
  # have been exactly the premature-abstraction this fleet keeps flagging in
  # others. That trade-off is exactly what changed: something (a human) now
  # DOES want the series.
  # THREE fields, not two (the project owner, 2026-08-25 night): pct alone left the
  # weekly reset time invisible everywhere except seat_check's own gating —
  # `seven_day.resets_at` is right there in the same response, same shape as
  # the session reset above, so it costs nothing extra to carry it alongside.
  # ⛔⛔ PER-ACCOUNT, NOT ONE SHARED FILE (the project owner, 2026-08-21): the weekly (7-day)
  #   window is Anthropic's own per-account ledger, exactly like the session
  #   window — switching accounts changes which budget is being read, the same
  #   reason the session ledger above is already keyed by account_id(). A single
  #   flat weekly.tsv silently mixed accounts: whichever account last ran `budget
  #   probe` overwrote the file, so a DIFFERENT account's seat_check would read
  #   a stale number that was never about its own account at all. The ledger
  #   append below stays per-account too, via the same account_id() column
  #   every session row already carries.
  local wpct wresets_at wresets_local
  wpct="$(jq -r '.seven_day.utilization // empty' <<<"$resp" 2>/dev/null)"
  if [[ "$wpct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ensure_dirs
    wresets_at="$(jq -r '.seven_day.resets_at // empty' <<<"$resp" 2>/dev/null)"
    wresets_local=""
    [[ -n "$wresets_at" ]] && wresets_local="$(date -d "$wresets_at" '+%s' 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$(now_epoch)" "${wpct%%.*}" "${wresets_local:-}" > "$(WEEKLY_FILE)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(account_id)" "${wpct%%.*}" "weekly" "${wresets_local:-}" >> "$LEDGER"
    if [[ -n "$wresets_local" ]]; then
      info "  weekly: ${wpct%%.*}% (cap $(weekly_cap)%), resets $(date -d "@$wresets_local" '+%F %H:%M')"
    else
      info "  weekly: ${wpct%%.*}% (cap $(weekly_cap)%), no reset time in response"
    fi
  else
    warn "  response had no numeric seven_day.utilization — weekly reading NOT updated"
  fi

  # ⭐⭐ 2026-09-20 (the project owner, via assistant, hybrid multi-account design item 2):
  #   the SAME response already carries the Fable model's own separate weekly
  #   quota — a DISTINCT ceiling from the account's general session/weekly
  #   caps above, confirmed live by reading the raw response directly rather
  #   than guessing: `.limits[]` has an entry `{"kind":"weekly_scoped",
  #   "scope":{"model":{"display_name":"Fable"}}, "percent":N,
  #   "resets_at":...}`. Same non-guessing discipline as the rest of this
  #   file: if that entry is missing or reshaped (this is the same unofficial,
  #   undocumented endpoint budget_probe already depends on — it could change
  #   shape with zero notice), this reads as UNMEASURED, not zero.
  local fpct fresets_at fresets_local
  fpct="$(jq -r '(.limits // [])[]? | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable") | .percent // empty' <<<"$resp" 2>/dev/null | head -1)"
  if [[ "$fpct" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    ensure_dirs
    fresets_at="$(jq -r '(.limits // [])[]? | select(.kind=="weekly_scoped" and .scope.model.display_name=="Fable") | .resets_at // empty' <<<"$resp" 2>/dev/null | head -1)"
    fresets_local=""
    [[ -n "$fresets_at" ]] && fresets_local="$(date -d "$fresets_at" '+%s' 2>/dev/null || true)"
    printf '%s\t%s\t%s\n' "$(now_epoch)" "${fpct%%.*}" "${fresets_local:-}" > "$(FABLE_WEEKLY_FILE)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$(account_id)" "${fpct%%.*}" "fable_weekly" "${fresets_local:-}" >> "$LEDGER"
    info "  fable model weekly: ${fpct%%.*}%$( [[ -n "$fresets_local" ]] && printf ', resets %s' "$(date -d "@$fresets_local" '+%F %H:%M')" )"
  else
    info "  fable model weekly: not present in this response (no separate Fable quota entry, or the endpoint reshaped) — leaving any prior reading as-is"
  fi

  budget_refresh_ramp
}

# WEEKLY_FILE [account] — one file per account, same sanitization as account_cap's
# env-var lookup so an account name can never escape STATE_DIR. Defaults to the
# CURRENT account if none given.
WEEKLY_FILE() {
  local acct="${1:-$(account_id)}"
  echo "$STATE_DIR/weekly_${acct//[^a-zA-Z0-9_]/_}.tsv"
}

# _last_weekly [account] — prints: epoch<TAB>pct<TAB>reset_epoch for that
# account (current account if omitted), reset_epoch empty if the response
# didn't carry one; nothing at all if never probed for it. A file written
# before the reset_epoch column existed just reads as an empty 3rd field —
# same "empty means missing" convention as the session ledger's own reset
# column, no migration needed. Deliberately separate from _last_callout: a
# stale weekly reading is a lot less dangerous than a stale session reading
# (the weekly window is 7 days wide, not 5 hours), so callers should show its
# age rather than silently trust or discard it.
_last_weekly() {
  local f; f="$(WEEKLY_FILE "${1:-}")"
  [[ -s "$f" ]] || return 1
  cat "$f"
}

# FABLE_WEEKLY_FILE / _last_fable_weekly — same shape as WEEKLY_FILE /
# _last_weekly, for the Fable model's own separate weekly quota (see
# budget_probe's own extraction comment). Kept as its own file/ledger source
# ("fable_weekly"), not folded into the account's general weekly reading —
# they are two different ceilings from the same response, and conflating them
# would make it impossible to tell which one a given row describes.
FABLE_WEEKLY_FILE() {
  local acct="${1:-$(account_id)}"
  echo "$STATE_DIR/fable_weekly_${acct//[^a-zA-Z0-9_]/_}.tsv"
}
_last_fable_weekly() {
  local f; f="$(FABLE_WEEKLY_FILE "${1:-}")"
  [[ -s "$f" ]] || return 1
  cat "$f"
}

# A HALT also writes a flag file, so a hook can check cheaply without
# recomputing, and so budget_ramp (below) knows WHY a seat halted before
# deciding whether to clear it: a session-block roll clears a SESSION halt but
# must NOT clear a WEEKLY one — the weekly window did not just reset.
SEAT_HALT_FILE() { echo "$STATE_DIR/seat_halt_$1"; }

# ─── Per-account park/ramp state (2026-09-20, hybrid multi-account design) ────
# ⛔⛔ THE GAP THIS CLOSES: `throttled`/`ramp_at` used to be ONE shared file for
#   every account, unlike the block cache, the weekly file, and the checkpoint
#   marker, which were already made per-account on 2026-09-17. In the fleet's
#   historical operating shape (one account live at a time, switched together)
#   this never mattered. It matters now that native `claude --bg` sessions let
#   genuinely different seats run under genuinely different live accounts at
#   once: with ONE shared file, account A hitting its own cap and parking would
#   also read as "parked" to every seat on account B, C, ... — one account's
#   cap silently stalling every other account's fleet. Worse, poller.sh's own
#   AR-12 self-heal (a park's recorded ACCOUNT field not matching the reader's
#   OWN account_id() is treated as STALE and ramped away) was built for the
#   single-live-account-at-a-time case (a human switched profiles out from
#   under an old park) — under genuine multi-account concurrency that same
#   check would delete a DIFFERENT account's legitimate, still-active park the
#   instant any seat on a third account happened to poll and read it.
# ⭐ THE FIX: same pattern WEEKLY_FILE already uses (below in this same file) —
#   the account is part of the filename, defaulting to account_id() so every
#   existing call site (direct CLI `aimail budget park`, poller.sh's own
#   check, `_budget_autopilot_tick`) keeps working with ZERO signature changes.
#   `_budget_autopilot_tick` already runs its whole body with CLAUDE_CONFIG_DIR
#   overridden to the resolved group's own real directory (see
#   `budget_autopilot`'s own header comment) — account_id() inside that call
#   already resolves correctly, so THROTTLE_FLAG()/RAMP_AT_FILE() with no
#   argument are already correctly scoped everywhere they are called from,
#   exactly like account_cap()/weekly_cap()/WEEKLY_FILE() already are. A live
#   seat's own poller.sh loop needs no change in this respect either — it runs
#   under its own account's real CLAUDE_CONFIG_DIR already, so account_id()
#   inside it already names that seat's own account.
# ⚠ AR-12's mismatch self-heal (lib/poller.sh) is left in place, not removed:
#   once each account reads only its OWN file, `parked_acct` (read from that
#   file) and account_id() should always agree by construction, so the branch
#   becomes inert under normal operation — cheap defense-in-depth against a
#   residual bug, not load-bearing any more.
THROTTLE_FLAG() {
  local acct="${1:-$(account_id)}"
  echo "$STATE_DIR/throttled_${acct//[^a-zA-Z0-9_]/_}"
}
RAMP_AT_FILE() {
  local acct="${1:-$(account_id)}"
  echo "$STATE_DIR/ramp_at_${acct//[^a-zA-Z0-9_]/_}"
}

# ─── The autopilot-blind alarm (2026-09-01, the 5h21m UNMEASURABLE incident) ──
# ⛔⛔ THE LAW THIS INCIDENT MINTS: A FALLBACK GATED ON ITS PRIMARY'S SUCCESS IS
#    NOT A FALLBACK — it is decoration on the success path. `budget_autopilot`
#    used to reach `budget_probe` (its one ccusage-independent reading) only
#    AFTER `block_end_effective` had already succeeded, so once ccusage went
#    blind (confirmed cause: it reads TOP-LEVEL transcript activity only, and
#    real work that stretch was entirely inside subagents), there was no way
#    back — 64 straight 5-min ticks, zero escalation, real usage climbing
#    unmonitored until it hit the account's actual hard limit.
#
# AIMAIL_AUTOPILOT_UNMEASURABLE_STREAK — consecutive ticks before escalating.
# Fable's ruling: 3 (15 real minutes) — long enough that one transient curl
# failure never pages anyone, short enough that this never again runs blind
# for hours.
AUTOPILOT_UNMEASURABLE_N="${AIMAIL_AUTOPILOT_UNMEASURABLE_STREAK:-3}"
AUTOPILOT_STREAK_FILE() { echo "$STATE_DIR/autopilot_unmeasurable_streak"; }
# ⭐⭐ THE PASSIVE FLAG — "an alarm must not require the resource whose
#   exhaustion it reports" (fable). A mail send during a real budget crisis can
#   itself be blocked, exactly like tonight — so this file is the channel that
#   cannot be silenced by the crisis it reports: pure local disk, no network,
#   no credentials, surfaced by `aimail fleet` and `aimail budget status` on
#   their own without anyone having to have received or read a mail first.
AUTOPILOT_BLIND_FLAG() { echo "$STATE_DIR/autopilot_blind"; }

# _autopilot_measured_ok — call the moment block_end_effective succeeds.
# Clears the streak and, if an incident was live, the flag too — silently, no
# "recovered" mail, matching fleet_sweep's own one-directional dedup (alert
# once per incident, no separate all-clear message).
_autopilot_measured_ok() {
  rm -f "$(AUTOPILOT_STREAK_FILE)" "$(AUTOPILOT_BLIND_FLAG)"
}

# _autopilot_measured_fail — call the moment block_end_effective still fails
# (i.e. AFTER the unconditional probe attempt already had its chance). Bumps
# the streak; at AUTOPILOT_UNMEASURABLE_N, writes the passive flag once (never
# re-written mid-incident, so its own timestamp stays the INCIDENT's start,
# same "stable identity" idiom `throttled` already uses for unpark) and makes
# one best-effort attempt to mail a supervisor — reusing fleet_sweep's exact
# pattern (mail_send, AIMAIL_SUPERVISOR, seat_exists guard). The flag write
# happens regardless of whether the mail succeeds or a supervisor exists at
# all: the flag is the channel of record, mail is a courtesy on top of it.
_autopilot_measured_fail() {
  local n; n=$(( $(cat "$(AUTOPILOT_STREAK_FILE)" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$(AUTOPILOT_STREAK_FILE)"
  (( n < AUTOPILOT_UNMEASURABLE_N )) && return 0
  local flag; flag="$(AUTOPILOT_BLIND_FLAG)"
  [[ -f "$flag" ]] && return 0   # already escalated for this ongoing incident
  { printf 'AUTOPILOT BLIND since %s\n' "$(now_iso)"
    printf 'REASON %s consecutive UNMEASURABLE ticks (%s min) -- neither budget_probe\n' \
      "$n" "$(( n * 5 ))"
    printf '       nor ccusage can read a boundary for account %s.\n' "$(account_id)"
    printf 'RISK   the checkpoint/park safety net cannot fire while this stands --\n'
    printf '       real usage may be climbing unmonitored, exactly like the\n'
    printf '       2026-08-31 20:19 -> 2026-09-01 01:40 incident that minted this alarm.\n'
    # ⭐⭐ 2026-09-03 (foundation, root-caused after this fired 3rd time in one day, always
    #   right at a block-boundary rollover -- ~15+ occurrences since the 09-01 fix, every one
    #   1-3 ticks then self-clearing): a MANUAL `aimail budget probe` DOES NOT clear this flag,
    #   however clean it reads -- only THIS function's own next successful tick does
    #   (_autopilot_measured_ok, called from budget_autopilot, never from budget_probe). The
    #   "CHECK" line below used to suggest a manual probe as the remedy, which is misleading:
    #   it updates the reading `block_end_effective` will use, but the flag itself only clears
    #   once the AUTOPILOT'S OWN next tick (every 5 min, in cron) sees that reading succeed.
    printf 'NORMALLY SELF-CLEARS within one more autopilot tick (~5 min) once the new\n'
    printf '       block boundary becomes measurable -- this is the expected shape of an ordinary\n'
    printf '       block-boundary rollover gap, not usually a new emergency by itself. If it\n'
    printf '       has been standing for MORE than ~10-15 min past this timestamp, or recurs\n'
    printf '       immediately at the NEXT boundary too, treat that as the real signal.\n'
    printf 'CHECK  aimail budget status  (probe helps the readings; it will not clear this flag)\n'
  } > "$flag"
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  if seat_exists "$supervisor"; then
    local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/autopilot_blind.XXXXXX")"
    cat "$flag" > "$body"
    mail_send --to "$supervisor" --from "$supervisor" \
      --subject "AUTOPILOT BLIND: $n consecutive UNMEASURABLE ticks, account $(account_id)" \
      --body-file "$body" >/dev/null 2>&1 \
      || warn "autopilot: could not mail '$supervisor' about the blind spot -- the flag file is written regardless, see $flag"
    rm -f "$body"
  else
    warn "autopilot: blind for $n ticks but supervisor '$supervisor' is not registered -- no mail sent, flag file still written"
  fi
}

# budget_seat_check <seat> — the per-seat halt decision. Prints diagnostic
# lines to STDERR (via warn/info's stderr forms below) and exactly ONE word —
# `HALT` or `OK` — on STDOUT, so a hook can consume it as
# `result=$(budget_seat_check "$seat" 2>/dev/null)` without parsing prose.
# ⛔ UNMEASURABLE (exit 4), never a guessed OK, when there is no session
# reading yet — "we don't know" and "we're fine" must never look the same.
budget_seat_check() {
  local seat="${1:?usage: budget_seat_check <seat>}"
  local scap wcap
  scap="$(seat_cap "$seat")"; wcap="$(weekly_cap)"

  local lc lc_e lc_p lc_s age
  lc="$(_last_callout || true)"
  [[ -n "$lc" ]] || unmeasurable "no session usage reading yet for account '$(account_id)'" \
    "Run 'aimail budget probe' (or 'callout <pct>' after reading /usage) first."
  lc_e="$(cut -f1 <<<"$lc")"; lc_p="$(cut -f2 <<<"$lc")"; lc_s="$(cut -f4 <<<"$lc")"
  age="$(age_min "$lc_e")"

  local wl wl_p wl_age wl_r
  wl="$(_last_weekly || true)"
  if [[ -n "$wl" ]]; then
    wl_p="$(cut -f2 <<<"$wl")"; wl_age="$(age_min "$(cut -f1 <<<"$wl")")"; wl_r="$(cut -f3 <<<"$wl")"
  fi

  {
    printf 'seat '"'"'%s'"'"'  session cap %s%%  weekly cap %s%%\n' "$seat" "$scap" "$wcap"
    printf '  session: %s%% (source: %s, %s min ago)\n' "$lc_p" "$lc_s" "$age"
    if [[ -n "${wl_p:-}" ]]; then
      if [[ "${wl_r:-}" =~ ^[0-9]+$ ]]; then
        printf '  weekly:  %s%% (%s min ago, resets %s)\n' "$wl_p" "$wl_age" "$(date -d "@$wl_r" '+%F %H:%M')"
      else
        printf '  weekly:  %s%% (%s min ago, reset time unknown)\n' "$wl_p" "$wl_age"
      fi
    else printf '  weekly:  UNMEASURED — run '"'"'aimail budget probe'"'"' at least once\n'; fi
  } >&2

  ensure_dirs
  # Weekly wins outright when tighter -- a fresh session block does not create
  # weekly headroom that was not already there.
  if [[ -n "${wl_p:-}" ]] && (( wl_p >= wcap )); then
    echo "  ⛔ weekly usage is at or over its cap -- HALT regardless of session%" >&2
    printf 'weekly\t%s\t%s%%\n' "$(now_epoch)" "$wl_p" > "$(SEAT_HALT_FILE "$seat")"
    echo "HALT"; return 0
  fi
  if (( lc_p >= scap )); then
    echo "  ⛔ session usage is at or over this seat's cap -- HALT" >&2
    printf 'session\t%s\t%s%%\n' "$(now_epoch)" "$lc_p" > "$(SEAT_HALT_FILE "$seat")"
    echo "HALT"; return 0
  fi
  rm -f "$(SEAT_HALT_FILE "$seat")"
  echo "  ✔ under both caps" >&2
  echo "OK"
}

_last_callout() { # [account] — prints: epoch<TAB>pct<TAB>reset_epoch<TAB>source
  # Matches BOTH "callout" (a human read /usage) and "probe" (the unofficial API,
  # below) and returns whichever is more RECENT, tagged with which it was. This
  # is deliberate: freshness is what protects the schedule (a late boundary is
  # the dangerous direction, see block_end_effective below), and a probe can run
  # every few minutes while a human callout is occasional — so in practice the
  # freshest reading is usually the probe, and callers must still LABEL it
  # correctly rather than call every row "the /usage callout".
  # ⭐ 2026-09-20: optional [account] arg, defaulting to account_id() same as
  #   WEEKLY_FILE — needed so a caller (aimail budget pool) can read a
  #   DIFFERENT account's own last reading, not just the ambient one. Every
  #   existing bare call keeps its exact old behavior.
  local acct="${1:-$(account_id)}"
  [[ -s "$LEDGER" ]] || return 1
  awk -F'\t' -v a="$acct" \
    '$2==a && ($4=="callout" || $4=="probe"){e=$1; p=$3; r=$5; s=$4} END{if(e) printf "%s\t%s\t%s\t%s", e, p, r, s}' "$LEDGER"
}

# ⭐⭐ THE EFFECTIVE BOUNDARY — prints: epoch<TAB>source
#
# Two candidates, and they are NOT equally trustworthy:
#   callout / probe  the reset time from /usage — a human's read (callout) or the
#            unofficial API (probe). Either is authoritative about the boundary;
#            "callout" vs "probe" only distinguishes WHO claimed it, for display.
#   ccusage  derived from local transcripts, and LATE BY CONSTRUCTION because it
#            floors the block start to the hour (measured 20 min late).
#
# ⛔ WHEN THEY DISAGREE, TAKE THE EARLIER ONE, and say so. The asymmetry is the
#    whole argument: being EARLY costs one checkpoint mail nobody needed, while
#    being LATE means the park fires after the boundary and the fleet never parks
#    — it just hits the cap mid-work with no handover written. A cheap false
#    positive beats an expensive false negative every time here.
block_end_effective() {
  local cc lc lc_e lc_r lc_s
  cc="$(block_field end 2>/dev/null || echo '')"
  lc="$(_last_callout 2>/dev/null || true)"
  lc_e="$(cut -f1 <<<"${lc:-}")"; lc_r="$(cut -f3 <<<"${lc:-}")"; lc_s="$(cut -f4 <<<"${lc:-}")"

  # A callout's reset only describes the block it was taken in. Once that reset
  # has passed, it describes a DEAD window and must not govern anything.
  if [[ "$lc_r" =~ ^[0-9]+$ ]] && (( lc_r > $(now_epoch) )); then
    # ⭐⭐ A FRESH authoritative reading wins OUTRIGHT — Part 3 of the
    #   2026-09-01 autopilot design (fable, approved 12:04). "Earlier wins"
    #   below is a reasonable default when neither source's reliability is
    #   known, but it stops making sense once a genuinely recent callout/probe
    #   exists: comparing it against ccusage's coarser floor-to-hour estimate
    #   and letting the estimate override it on a bare numeric comparison
    #   discards the more trustworthy source for no reason. MEASURED,
    #   2026-09-01: the project owner's real 86%/11:30 callout lost to ccusage's 11:00
    #   this way — worse than not having the callout at all.
    # ⚠ Freshness is measured on `lc_e` (when the reading was TAKEN), never
    #   `lc_r` (the boundary it reports) — the claim's age, not its content.
    if [[ "$lc_e" =~ ^[0-9]+$ ]] && (( $(age_min "$lc_e") <= CALLOUT_FRESH_MIN )); then
      # Condition from review (fable, 2026-09-01): precedence changes here,
      # observability must not. ccusage persistently disagreeing with the
      # live probe is exactly how the next ccusage drift gets noticed early
      # — log it (the fresh reading still wins unconditionally; this is
      # visibility, not a second vote) so this doesn't go silently blind in
      # what is now the common case.
      # ⛔⛔ MUST GO TO STDERR, NEVER `info` (which prints to STDOUT): every
      #    caller of this function captures its stdout via `$(block_end_effective)`
      #    to parse the one `epoch<TAB>source` line it returns — an info line
      #    mixed into that stream would corrupt every single caller's `cut -f1`.
      if [[ "$cc" =~ ^[0-9]+$ ]]; then
        local d=$(( cc > lc_r ? cc - lc_r : lc_r - cc ))
        (( d > 300 )) && \
          printf 'boundary disagreement: using the fresh %s (%s) outright; ccusage says %s (%s min apart, not compared)\n' \
            "$lc_s" "$(date -d "@$lc_r" '+%H:%M')" "$(date -d "@$cc" '+%H:%M')" "$(( d/60 ))" >&2
      fi
      printf '%s\t%s\n' "$lc_r" "$lc_s"; return 0
    fi
    # The callout/probe reading is stale (its reset hasn't technically passed,
    # but it wasn't taken recently) — neither source is freshly known-good, so
    # fall back to the original conservative default: compare against ccusage
    # and take whichever is EARLIER, since being early costs one unneeded
    # checkpoint while being late means the park fires after the boundary.
    if [[ "$cc" =~ ^[0-9]+$ ]]; then
      local d=$(( cc > lc_r ? cc - lc_r : lc_r - cc ))
      if (( d > 300 )); then
        warn "boundary disagreement: /usage says $(date -d "@$lc_r" '+%H:%M'), ccusage says $(date -d "@$cc" '+%H:%M') ($(( d/60 )) min apart)"
        warn "  using the EARLIER. ccusage floors the block start to the hour, so it reads late."
      fi
      (( lc_r < cc )) && { printf '%s\t%s\n' "$lc_r" "$lc_s"; return 0; }
      printf '%s\tccusage\n' "$cc"; return 0
    fi
    printf '%s\t%s\n' "$lc_r" "$lc_s"; return 0
  fi
  [[ "$cc" =~ ^[0-9]+$ ]] && { printf '%s\tccusage\n' "$cc"; return 0; }
  return 1
}

# ─── Pool — the multi-account dashboard (2026-09-20, item 2) ─────────────────
# ⭐⭐ Built entirely from data this file already computes for OTHER reasons —
#   no new ledger, no new cron job. `_autopilot_seat_groups()` (below) already
#   figures out, every 5 minutes, which live seats resolve to which real
#   account; this just prints that same grouping alongside each account's own
#   session%/weekly%/fable-model-weekly% and throttle state, using the
#   now-parameterized account_cap()/weekly_cap()/_last_callout()/_last_weekly()
#   /_last_fable_weekly()/THROTTLE_FLAG() to read a DIFFERENT account than the
#   ambient one without ever setting CLAUDE_CONFIG_DIR — these are all pure
#   reads of this account's own state files, not calls that need the real
#   account's credentials the way budget_probe() does.
# AIMAIL_FLEET_ACCOUNTS — an explicit, space-separated pool ("work research
#   r2"), overrides everything below. Falls back to _configured_account_pool()
#   (AIMAIL_ACCOUNT_POOL / AIMAIL_FLEET_ACCOUNTS if set there instead, else the
#   live-seat grouping -- see that function's own header for the full 2026-09-25
#   history: it never globs the filesystem), then to the ambient account_id() so
#   a deployment that never sets anything still gets a one-row report instead of
#   nothing.
budget_pool() {
  local -a accts=()
  if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
    read -r -a accts <<< "$AIMAIL_FLEET_ACCOUNTS"
  else
    # The configured pool (_configured_account_pool -- explicit config, or the live-seat
    # fallback; never a filesystem glob) -- NOT the seat-based grouping below, which is only
    # for the SEATS column's own annotation.
    local a
    while IFS= read -r a; do
      [[ -n "$a" ]] && accts+=("$a")
    done < <(_configured_account_pool 2>/dev/null || true)
    (( ${#accts[@]} == 0 )) && accts=("$(account_id)")
  fi

  # seats-by-account, from the SAME live grouping — a plain associative
  # lookup, not a second traversal with its own chance to disagree with the
  # account list above.
  local -A seats_by_acct=()
  local line a2 s2
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    a2="$(cut -f2 <<<"$line")"; s2="$(cut -f3 <<<"$line")"
    [[ -n "$a2" ]] && seats_by_acct["$a2"]="$s2"
  done < <(_autopilot_seat_groups 2>/dev/null || true)

  info "budget pool — ${#accts[@]} account(s)"
  echo
  source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
  if command -v placement_report >/dev/null 2>&1; then placement_report || true; echo; fi
  printf '%-10s  %-8s  %-16s  %-16s  %-16s  %-10s  %s\n' \
    "ACCOUNT" "PARKED" "SESSION%/CAP" "WEEKLY%/CAP" "FABLE-WKLY%" "RESETS" "SEATS"
  local acct sc lc lc_p wc wl wl_p fw fw_p parked resets seats
  for acct in "${accts[@]}"; do
    sc="$(account_cap "$acct")"; wc="$(weekly_cap "$acct")"
    lc="$(_last_callout "$acct" 2>/dev/null || true)"
    lc_p="$( [[ -n "$lc" ]] && cut -f2 <<<"$lc" || echo '?' )"
    wl="$(_last_weekly "$acct" 2>/dev/null || true)"
    wl_p="$( [[ -n "$wl" ]] && cut -f2 <<<"$wl" || echo '?' )"
    resets="-"
    if [[ -n "$wl" ]]; then
      local wr; wr="$(cut -f3 <<<"$wl")"
      [[ "$wr" =~ ^[0-9]+$ ]] && resets="$(date -d "@$wr" '+%m-%d %H:%M')"
    fi
    fw="$(_last_fable_weekly "$acct" 2>/dev/null || true)"
    fw_p="$( [[ -n "$fw" ]] && cut -f2 <<<"$fw" || echo '?' )"
    if [[ -f "$(THROTTLE_FLAG "$acct")" ]]; then parked="yes"; else parked="no"; fi
    seats="${seats_by_acct[$acct]:-(none live)}"
    printf '%-10s  %-8s  %-16s  %-16s  %-16s  %-10s  %s\n' \
      "$acct" "$parked" "${lc_p}%/${sc}%" "${wl_p}%/${wc}%" "${fw_p}%" "$resets" "$seats"
  done
  echo
  info "'?' means UNMEASURED for that account (no reading yet, or the account has never been probed"
  info "from this machine) — never read as 0%. FABLE-WKLY is a separate ceiling from the account's"
  info "own weekly cap (see budget_probe's own extraction note); '?' there can also mean the live"
  info "response simply had no Fable-scoped entry, which is a real, distinct case from unmeasured."
}

# ─── Pick — the allocation policy (2026-09-20, item 3) ────────────────────────
# budget_pick_account [account ...] — prints ONE account name (the pick) on
# stdout and exits 0, or prints nothing and exits 1 when no candidate
# qualifies. Candidates default to AIMAIL_FLEET_ACCOUNTS (space-separated),
# falling back to just the current account_id() if that is unset (so a
# single-account deployment still gets a deterministic, if trivial, answer).
#
# ⭐ THE POLICY, DELIBERATELY SIMPLE (design doc §4c): among candidates that
#   are (a) not currently parked and (b) have a REAL, existing weekly reading
#   with positive headroom (weekly_cap - weekly% > 0), pick the one with the
#   MOST remaining headroom; ties broken toward whichever resets soonest (use
#   up the account closer to running out of relevance first). Greedy over
#   ALREADY-MEASURED state, never a burn-rate forecast — matches this file's
#   own stated preference for measurable state over prediction everywhere
#   else (see the header's "THE BLOCK BOUNDARY IS MEASURABLE" idea).
# ⛔ AN ACCOUNT WITH NO WEEKLY READING AT ALL IS NOT ELIGIBLE, not "assumed
#   empty." Same "unmeasured never reads as safe/zero" discipline as every
#   other decision in this file (budget_seat_check, budget_weekly_still_
#   blocking, ...) — inventing headroom for an unprobed account (e.g. one
#   just after its own reset, before anyone has run `budget probe` against
#   it) is exactly the kind of guess this file exists to refuse. The caller
#   (item 4's migration mailer, or a human) is expected to probe a candidate
#   first if it matters that a freshly-reset account gets picked promptly —
#   this function reports what IS known, it does not go get a fresh reading
#   itself (it has no CLAUDE_CONFIG_DIR override machinery of its own, and
#   silently reaching into another account's credentials from inside a pure
#   decision function is not a boundary this function should own).
budget_pick_account() {
  local -a candidates=("$@")
  if (( ${#candidates[@]} == 0 )); then
    if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
      read -r -a candidates <<< "$AIMAIL_FLEET_ACCOUNTS"
    else
      candidates=("$(account_id)")
    fi
  fi

  local acct wl wl_p wc headroom wl_r
  local best="" best_headroom=-1 best_reset=""
  for acct in "${candidates[@]}"; do
    [[ -n "$acct" ]] || continue
    [[ -f "$(THROTTLE_FLAG "$acct")" ]] && continue   # parked -> not eligible
    wl="$(_last_weekly "$acct" 2>/dev/null || true)"
    [[ -n "$wl" ]] || continue                        # never measured -> not eligible
    wl_p="$(cut -f2 <<<"$wl")"; wl_r="$(cut -f3 <<<"$wl")"
    [[ "$wl_p" =~ ^[0-9]+$ ]] || continue
    wc="$(weekly_cap "$acct")"
    headroom=$(( wc - wl_p ))
    (( headroom > 0 )) || continue                    # at/over its own cap -> not eligible
    if (( headroom > best_headroom )); then
      best="$acct"; best_headroom="$headroom"; best_reset="$wl_r"
    elif (( headroom == best_headroom )); then
      # Tie-break: soonest reset wins (a smaller epoch = sooner), only when
      # BOTH sides actually have a reset epoch to compare — an unresolvable
      # tie keeps whichever was found first rather than guessing an order.
      if [[ "$wl_r" =~ ^[0-9]+$ && "$best_reset" =~ ^[0-9]+$ ]] && (( wl_r < best_reset )); then
        best="$acct"; best_headroom="$headroom"; best_reset="$wl_r"
      fi
    fi
  done

  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# ACCOUNT_CONFIG_DIR <account> — the real CLAUDE_CONFIG_DIR for a named
# account, the exact inverse of account_id()'s own `basename | sed` mapping
# (`~/.claude-<name>`, or bare `~/.claude` for the literal name "default").
# Used only to point a probe at a DIFFERENT account's own credentials -- never
# assumed to exist; callers check the resulting dir/credentials file before
# trusting it, same as budget_probe() already does for the ambient account.
# ⛔⛔ THE INVARIANT THIS FUNCTION DEPENDS ON, NAMED EXPLICITLY: whatever
#   directory this returns, account_id() will later name that SAME account
#   from THAT DIRECTORY'S OWN BASENAME when a caller sets CLAUDE_CONFIG_DIR
#   to it (e.g. budget_pick_account_live's probe call) — never from the
#   logical account string passed in here. For every real account on this
#   machine the two already agree by construction (`~/.claude-work` IS named
#   "work"), so this is invisible in production. It is NOT invisible for an
#   AIMAIL_ACCOUNT_DIR_<acct> override pointed at an arbitrarily-named
#   directory (exactly the shape a test needs): the resulting probe files
#   its reading under THAT DIRECTORY'S basename, not under `<acct>`, and
#   _last_weekly("<acct>") never sees it — silently wrong, not an error.
#   Found writing this file's own test (2026-09-20): a fake creds dir named
#   $AIMAIL_ROOT/fake_creds recorded its reading as account "fake_creds",
#   invisible to a test asking about account "liveAcctH". Any override must
#   point at a directory whose OWN basename decodes to the same account name.
ACCOUNT_CONFIG_DIR() {
  local acct="${1:?usage: ACCOUNT_CONFIG_DIR <account>}"
  # ⭐ AIMAIL_ACCOUNT_DIR_<acct> — same override idiom as AIMAIL_CAP_<acct>/
  #   AIMAIL_WEEKLY_CAP_<acct>. Lets a test point a synthetic account name at
  #   an isolated fake-credentials dir under $AIMAIL_ROOT instead of the real
  #   $HOME (this function otherwise has no $AIMAIL_ROOT-relative form at
  #   all, unlike everything else in this file), and lets production cover
  #   an account whose config dir genuinely doesn't follow the
  #   `~/.claude-<name>` convention.
  local var="AIMAIL_ACCOUNT_DIR_${acct//[^a-zA-Z0-9_]/_}"
  local v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  [[ "$acct" == "default" ]] && { echo "$HOME/.claude"; return 0; }
  echo "$HOME/.claude-$acct"
}

# _configured_account_pool — every account this MACHINE is configured for, regardless of
# whether a seat currently lives there. AIMAIL_ACCOUNT_POOL_OVERRIDE (whitespace-separated
# names) stands in for the real filesystem under test, same override idiom as
# AIMAIL_LIVE_SIDS_OVERRIDE (fleet.sh).
# ⛔⛔ WHY THIS EXISTS (2026-09-25): budget_pool(), _pl_accounts() (placement.sh), and
#   _instance_account_dirs() (fleet.sh) each independently fell back to "whichever accounts
#   currently have a live, resolved seat" when AIMAIL_FLEET_ACCOUNTS was unset -- three separate
#   copies of the same gap, not one. r2's block rolled at 01:19 with zero seats on it: it went
#   PARKED and invisible to `budget pool`, and `placement_pick` kept recommending the near-cap
#   work account since the genuinely-idle one was never even a candidate. One canonical
#   enumeration here, called from all three, so a fourth copy of this exact bug can't recur.
# ⛔⛔ REVISED (2026-09-25, assistant's HIGH mail, found live): the FIRST cut of this function
#   globbed $HOME/.claude-* (plus bare $HOME/.claude for "default"). Two real defects: (1) on
#   this machine $HOME/.claude is a SYMLINK ALIAS to one of the $HOME/.claude-<name> dirs, so
#   that account was listed under two different names for the same real directory --
#   `seat locate` then read every seat on it as a TWIN (same sid/pid reported twice) and
#   REFUSED, breaking `seat migrate` for every seat on that account. (2) the glob has no way to
#   tell a genuine fleet account from any OTHER Claude account dir that happens to exist on the
#   same machine -- two non-fleet dirs were silently admitted as real candidates, and placement
#   returned OK (with only a warning) to move a seat onto one of them.
#   Fixed by REMOVING the glob entirely. The pool is now built ONLY from an explicit configured
#   list -- AIMAIL_FLEET_ACCOUNTS (existing) or AIMAIL_ACCOUNT_POOL (new, same shape, documented
#   in etc/aimail.conf.example) -- or, if NEITHER is configured, the pre-2026-09-25 fallback
#   (whichever accounts currently have a live, resolved seat, via _autopilot_seat_groups), with a
#   ONE-TIME warning: this reintroduces the "seatless account invisible" gap this function was
#   originally built to close, but only for a deployment that never configures its own pool --
#   the real fleet's own etc/aimail.conf already sets AIMAIL_FLEET_ACCOUNTS, so this fallback
#   never fires there. Whatever the source, every name is resolved to its real directory
#   (readlink -f) and deduped by THAT — not by name -- keeping the first name seen for each real
#   dir, so two configured/live names that alias to the same account can never appear twice
#   (the exact shape that broke `seat migrate` above; _autopilot_seat_groups's own output can
#   carry the same aliasing, since it keys its rows by account NAME, not by real directory).
# Returns 1 (never an empty success) when nothing is found at all — every caller below already
# falls back further (to account_id()) rather than trusting an empty "success" as "zero accounts."
_configured_account_pool() {
  if [[ -n "${AIMAIL_ACCOUNT_POOL_OVERRIDE:-}" ]]; then
    printf '%s\n' $AIMAIL_ACCOUNT_POOL_OVERRIDE | sort -u
    return 0
  fi
  local -a raw=()
  if [[ -n "${AIMAIL_ACCOUNT_POOL:-}" ]]; then
    read -r -a raw <<< "$AIMAIL_ACCOUNT_POOL"
  elif [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
    read -r -a raw <<< "$AIMAIL_FLEET_ACCOUNTS"
  else
    if [[ -z "${_AIMAIL_ACCOUNT_POOL_WARNED:-}" ]]; then
      warn "_configured_account_pool: no AIMAIL_FLEET_ACCOUNTS or AIMAIL_ACCOUNT_POOL configured" \
        "-- falling back to live-seat accounts only. A genuinely idle, seatless-but-configured" \
        "account (e.g. parked at its own block boundary with nobody on it) will be invisible to" \
        "budget pool/placement until it gets a seat again. Set AIMAIL_ACCOUNT_POOL in" \
        "etc/aimail.conf to close this gap."
      export _AIMAIL_ACCOUNT_POOL_WARNED=1
    fi
    local line a
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      a="$(cut -f2 <<<"$line")"
      [[ -n "$a" ]] && raw+=("$a")
    done < <(_autopilot_seat_groups 2>/dev/null || true)
  fi
  (( ${#raw[@]} )) || return 1
  local -A seen_real=()
  local -a names=()
  local acct dir real
  for acct in "${raw[@]}"; do
    [[ -n "$acct" ]] || continue
    dir="$(ACCOUNT_CONFIG_DIR "$acct")"
    real="$(readlink -f "$dir" 2>/dev/null || echo "$dir")"
    [[ -n "${seen_real[$real]:-}" ]] && continue
    seen_real["$real"]=1
    names+=("$acct")
  done
  (( ${#names[@]} )) || return 1
  printf '%s\n' "${names[@]}" | sort -u
}

# budget_stale_candidates [account ...] — prints one account per line (of the
# given candidates) that is currently ineligible for budget_pick_account
# ONLY because its reading is missing or describes an already-closed window —
# i.e. exactly the set where a FRESH probe could change the answer. Excludes:
# a PARKED account (no probe fixes that), and an account with a REAL, CURRENT
# reading that is simply at/over its own cap (also not something a probe
# changes — the number is already known and already bad). This is the
# distinction the project owner's 2026-09-20 ruling drew: probe on demand for a stale
# reading, never for a genuinely-over-cap one.
budget_stale_candidates() {
  local -a candidates=("$@")
  local acct wl wl_r now
  now="$(now_epoch)"
  for acct in "${candidates[@]}"; do
    [[ -n "$acct" ]] || continue
    [[ -f "$(THROTTLE_FLAG "$acct")" ]] && continue   # parked -> a probe doesn't help
    wl="$(_last_weekly "$acct" 2>/dev/null || true)"
    if [[ -z "$wl" ]]; then
      printf '%s\n' "$acct"                            # never measured -> worth a probe
      continue
    fi
    wl_r="$(cut -f3 <<<"$wl")"
    # A reading's own recorded reset time already in the past means the
    # window it described has closed -- the percentage no longer describes
    # anything real, stale exactly the same way block_end_effective already
    # treats a callout whose reset has passed as describing a dead window.
    if [[ "$wl_r" =~ ^[0-9]+$ ]] && (( wl_r <= now )); then
      printf '%s\n' "$acct"
    fi
  done
}

# budget_pick_account_live [account ...] — the operational entry point
# (`aimail budget pick` uses this). Tries the pure, network-free
# budget_pick_account() first; if and ONLY IF that finds nothing, probes each
# STALE-OR-UNMEASURED candidate fresh (never a candidate that's parked or
# genuinely over cap — probing those cannot change the outcome) and retries
# once. Never probes when the static pick already succeeds, and never probes
# an account with zero live seats on a recurring schedule — this is
# on-demand, at the moment a pick is actually needed, not background
# forecasting (the project owner's own distinction, 20260920T154934).
budget_pick_account_live() {
  local -a candidates=("$@")
  if (( ${#candidates[@]} == 0 )); then
    if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
      read -r -a candidates <<< "$AIMAIL_FLEET_ACCOUNTS"
    else
      candidates=("$(account_id)")
    fi
  fi

  local pick; pick="$(budget_pick_account "${candidates[@]}" 2>/dev/null || true)"
  [[ -n "$pick" ]] && { printf '%s\n' "$pick"; return 0; }

  local stale acct dir
  stale="$(budget_stale_candidates "${candidates[@]}")"
  [[ -n "$stale" ]] || return 1   # nothing worth probing -> the static answer stands
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    dir="$(ACCOUNT_CONFIG_DIR "$acct")"
    [[ -r "$dir/.credentials.json" ]] || { warn "budget_pick_account_live: no credentials at $dir for account '$acct' -- skipping its probe"; continue; }
    # ⛔ budget_probe() calls unmeasurable()/die() on failure, a hard exit —
    #   MUST run in a subshell, same containment idiom _budget_autopilot_tick
    #   and budget_weekly_still_blocking already use for exactly this reason.
    ( CLAUDE_CONFIG_DIR="$dir" budget_probe >/dev/null 2>&1 ) \
      || warn "budget_pick_account_live: fresh probe of account '$acct' failed -- leaving its prior reading as-is"
  done <<< "$stale"

  budget_pick_account "${candidates[@]}"
}

# ─── Migration recommendation — item 4d: decide + report, never act ──────────
# SEAT_REASSIGN_FILE <seat> — one marker per seat, same shape/identity
# discipline as seat_unpark_<seat>: keyed to the CURRENT park episode via that
# park's own throttle-file mtime (not a separate TTL to compute or drift out
# of sync with), so a superseded park naturally invalidates a stale
# recommendation without anything having to notice and delete it.
SEAT_REASSIGN_FILE() { echo "$STATE_DIR/seat_reassign_$1"; }

# budget_recommend_migration <seat> — if <seat>'s OWN resolved account is
# currently parked, picks a live target account (budget_pick_account_live,
# excluding the seat's own current account) and mails a SUPERVISOR (never the
# seat itself, which may be about to be killed) the exact, pre-filled
# kill+relaunch command from docs/cli_account_migration.md. Idempotent per
# park episode: re-running this while the SAME park is still in force does
# not re-mail.
# ⛔⛔ THIS FUNCTION NEVER KILLS OR RELAUNCHES ANYTHING ITSELF. Moving a live
#   seat means killing a real process and starting another one under a
#   different account's credentials — a destructive-adjacent action this
#   fleet's own standing rules already reserve for a human/supervisor with an
#   explicit liveness check first, not something unattended automation does.
#   The automatic half stops at deciding the target and writing the exact
#   commands down; a human (or assistant, acting with an explicit go) runs
#   them. See design doc §4d for why this boundary is deliberate, not a
#   missing feature.
budget_recommend_migration() {
  local seat="${1:?usage: budget_recommend_migration <seat>}"
  seat_exists "$seat" || refused "budget_recommend_migration: '$seat' is not a registered seat."

  local cur_acct; cur_acct="$(seat_account "$seat")"
  local tflag; tflag="$(THROTTLE_FLAG "$cur_acct")"
  if [[ ! -f "$tflag" ]]; then
    info "seat '$seat' resolves to account '$cur_acct', which is not parked -- nothing to recommend"
    return 1
  fi
  local park_mtime; park_mtime="$(stat -c %Y "$tflag" 2>/dev/null || echo '')"

  local rfile; rfile="$(SEAT_REASSIGN_FILE "$seat")"
  if [[ -f "$rfile" ]]; then
    local recorded; recorded="$(awk -F'\t' '$1=="park_started_at"{print $2}' "$rfile" 2>/dev/null)"
    if [[ -n "$recorded" && -n "$park_mtime" && "$recorded" == "$park_mtime" ]]; then
      info "seat '$seat' already has a live migration recommendation for this exact park episode -- not re-mailing"
      return 0
    fi
  fi

  local -a candidates=()
  [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]] && read -r -a candidates <<< "$AIMAIL_FLEET_ACCOUNTS"
  local -a filtered=() a
  for a in "${candidates[@]}"; do [[ -n "$a" && "$a" != "$cur_acct" ]] && filtered+=("$a"); done
  if (( ${#filtered[@]} == 0 )); then
    warn "budget_recommend_migration: AIMAIL_FLEET_ACCOUNTS has no OTHER account besides '$cur_acct' -- nothing to recommend"
    return 1
  fi

  local target=""
  source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
  if command -v placement_pick >/dev/null 2>&1; then
    if _pl_is_pinned "$seat"; then info "seat '$seat' is PINNED (AIMAIL_PINNED_SEATS) -- never recommended for a move; only the owner moves it"; return 1; fi
    budget_pick_account_live "${filtered[@]}" >/dev/null 2>&1 || true   # refresh stale readings the same way as before
    target="$(placement_pick "$seat" "${filtered[@]}" 2>/dev/null || true)"
  else
    target="$(budget_pick_account_live "${filtered[@]}" 2>/dev/null || true)"
  fi
  if [[ -z "$target" ]]; then
    info "seat '$seat' is parked on '$cur_acct' but placement finds no eligible account (precious/spread/headroom rules, or nothing measured) -- nothing to recommend right now"
    return 1
  fi

  # Best-effort session-id resolution, the exact grep heuristic
  # docs/cli_account_migration.md documents ("Finding a seat's session id on
  # a given account") — NEVER asserted with certainty, only offered alongside
  # its own occurrence count so a human can sanity-check it before using it.
  local cfgdir; cfgdir="$(ACCOUNT_CONFIG_DIR "$target")"
  local sid="" best_count=0 f c
  if [[ -d "$cfgdir/projects" ]]; then
    for f in "$cfgdir"/projects/*/*.jsonl; do
      [[ -f "$f" ]] || continue
      c="$(grep -oc "poll $seat" "$f" 2>/dev/null || echo 0)"
      if [[ "$c" =~ ^[0-9]+$ ]] && (( c > 100 && c > best_count )); then
        best_count="$c"; sid="$(basename "$f" .jsonl)"
      fi
    done
  fi

  ensure_dirs
  { printf 'park_started_at\t%s\n' "${park_mtime:-}"
    printf 'target_account\t%s\n' "$target"
    printf 'recommended_at\t%s\n' "$(now_iso)"
    printf 'candidate_session_id\t%s\n' "$sid"
  } | atomic_write "$rfile" \
    || { warn "budget_recommend_migration: failed to write the reassign marker for '$seat' -- not mailing"; return 1; }

  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  if ! seat_exists "$supervisor"; then
    warn "budget_recommend_migration: supervisor '$supervisor' is not registered -- marker written ($rfile), no mail sent"
    return 0
  fi

  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/migrate_reco.XXXXXX")"
  {
    printf '# Migration recommendation: seat %s, %s -> %s\n\n' "$seat" "$cur_acct" "$target"
    printf 'Seat %s resolves to account %s, which is currently parked (aimail budget pool). Account\n' "$seat" "$cur_acct"
    printf '%s currently has the most weekly headroom among the configured pool and is eligible now.\n\n' "$target"
    printf 'This is a RECOMMENDATION, not an automated action. Moving a live seat means stopping its\n'
    printf 'session and relaunching it under a different account'"'"'s credentials -- not something this\n'
    printf 'automation does unattended. To act on it (full context: docs/cli_account_migration.md):\n\n'
    printf '  Move it with the scripted procedure (each step verified before the next):\n\n'
    printf '     aimail seat migrate %s %s --from <supervisor-seat> [--dry-run]\n\n' "$seat" "$target"
    printf '  It locates the session by id across the account pool (claude agents --json), asks the\n'
    printf '  seat for a fresh role handover, stops it with `claude stop` (a killed session is\n'
    printf '  RESPAWNED by the CLI scheduler from its original account/model spec -- never kill it),\n'
    printf '  relaunches it under %s with an explicit model, waits, re-verifies it is present\n' "$target"
    printf '  there and absent everywhere else, then writes the seat record.\n'
    if [[ -n "$sid" ]]; then
      printf '  Session id %s is the BEST-EFFORT transcript heuristic (%s occurrences of "poll %s"),\n' "$sid" "$best_count" "$seat"
      printf '  never asserted with certainty -- offered only as a cross-check; the tool resolves the real one itself.\n'
    else
      printf '  No transcript heuristic hit for %s under %s -- the tool resolves the session itself from\n' "$seat" "$target"
      printf '  claude agents --json and the seat record; a session id is never asserted with certainty here.\n'
    fi
  } > "$body"
  mail_send --to "$supervisor" --from "$supervisor" \
    --subject "Migration recommendation: $seat ($cur_acct -> $target, at/over cap)" \
    --body-file "$body" >/dev/null 2>&1 \
    || warn "budget_recommend_migration: could not mail '$supervisor' -- the marker is written regardless, see $rfile"
  rm -f "$body"
  ok "migration recommendation written + mailed for seat '$seat': $cur_acct -> $target"
}

# ─── Status ───────────────────────────────────────────────────────────────────
budget_status() {
  local acct cap; acct="$(account_id)"; cap="$(account_cap)"
  info "account: $acct    cap: ${cap}%    $(instrument_id)"
  echo

  if [[ -f "$(AUTOPILOT_BLIND_FLAG)" ]]; then
    echo "🔴 AUTOPILOT BLIND — the checkpoint/park safety net cannot fire right now:"
    local bf_age; bf_age="$(stat -c %Y "$(AUTOPILOT_BLIND_FLAG)" 2>/dev/null || echo 0)"
    (( bf_age > 0 )) && echo "   (flag age: $(age_min "$bf_age") min -- see NORMALLY SELF-CLEARS below for what that means)"
    sed 's/^/   /' "$(AUTOPILOT_BLIND_FLAG)"
    echo
  fi

  local bs be be_src rem tok burn eff
  bs="$(block_field start)"
  rem="$(block_field remaining_min)"; tok="$(block_field tokens)"; burn="$(block_field burn_per_min)"
  eff="$(block_end_effective || true)"
  be="$(cut -f1 <<<"${eff:-}")"; be_src="$(cut -f2 <<<"${eff:-}")"

  if [[ -z "$be" ]]; then
    # ⛔ Not "0 minutes remaining". That would read as "the block just ended".
    unmeasurable "the active 5-hour block could not be read" \
      "Tried: $(ccusage_cmd 2>/dev/null || echo 'ccusage (none on PATH, no npx)') blocks --json" \
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

  local lc lc_e lc_p lc_s
  lc="$(_last_callout || true)"
  if [[ -n "$lc" ]]; then
    lc_e="$(cut -f1 <<<"$lc")"; lc_p="$(cut -f2 <<<"$lc")"; lc_s="$(cut -f4 <<<"$lc")"
    local age; age="$(age_min "$lc_e")"
    if [[ "$lc_s" == "probe" ]]; then
      echo "MEASURED — the last automated probe (unofficial API, not a human's /usage read):"
    else
      echo "MEASURED — the last /usage callout (a human read this):"
    fi
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

  local wcap wl wl_p wl_age wl_r
  wcap="$(weekly_cap)"
  wl="$(_last_weekly || true)"
  echo "WEEKLY — the separate, account-wide 7-day ceiling (cap ${wcap}%):"
  if [[ -n "$wl" ]]; then
    wl_p="$(cut -f2 <<<"$wl")"; wl_age="$(age_min "$(cut -f1 <<<"$wl")")"; wl_r="$(cut -f3 <<<"$wl")"
    printf '  %s%%  taken %s min ago' "$wl_p" "$wl_age"
    if [[ "$wl_r" =~ ^[0-9]+$ ]]; then
      printf ', resets %s\n' "$(date -d "@$wl_r" '+%F %H:%M')"
    else
      printf ' (no reset time in that reading)\n'
    fi
    (( wl_p >= wcap )) && printf '  ⛔ at or over the %s%% weekly cap -- this wins over session%%, regardless\n' "$wcap"
  else
    echo "  UNMEASURED — run 'aimail budget probe' at least once (same call also measures"
    echo "  the session%% above; the API returns both in one response)."
  fi
  echo
  # ⛔⛔ Real incident, 2026-09-03: assistant read 85%/95% as "close to
  #   the reset, act differently" and told the whole fleet to wind down for
  #   the night to conserve it. This block exists so this report itself says
  #   the opposite, every time, instead of relying on anyone remembering it.
  echo "⛔ STANDING RULE — a percentage on this screen is not a decision point:"
  echo "   The cap IS the safety margin. It was set where it is on purpose. Seeing"
  echo "   usage approach it is not authorization to change pace either way — not"
  echo "   an early stand-down to 'conserve' what's left, and not a rush to spend"
  echo "   it before a reset. Usage does not bank across a reset in either"
  echo "   direction, so both moves are imaginary savings. The ONLY thing licensed"
  echo "   to change fleet behavior off this number is the automated park below,"
  echo "   which fires exactly at/over cap. If this screen is making you want to"
  echo "   slow down or speed up, that's the bug this note exists to catch —"
  echo "   keep doing what you were already doing."
  echo
  echo "SCHEDULE — checkpoint/ramp keyed on the boundary, park keyed on real usage:"
  printf '  checkpoint at  %s   (block end − %s min)\n' \
    "$(date -d "@$(( be - CHECKPOINT_MIN*60 ))" '+%H:%M')" "$CHECKPOINT_MIN"
  if [[ -n "${lc_p:-}" ]]; then
    printf '  park           last probed %s%%%s (cap %s%%), %s min ago -- autopilot parks the moment\n                 a probe reads at/over cap, any time, not just near the boundary\n' \
      "$lc_p" "$([[ -n "${lc_e:-}" && -n "$bs" && "$lc_e" -lt "$bs" ]] && echo ' (STALE)' || echo '')" "$cap" "${age:-?}"
  else
    printf '  park           no usage reading yet this block -- autopilot cannot evaluate it yet\n'
  fi
  printf '  ramp at        %s   (the block rolls)\n' "$(date -d "@$be" '+%H:%M')"
  echo
  local th="$(THROTTLE_FLAG)"
  [[ -f "$th" ]] && { warn "THROTTLE IS IN FORCE:"; sed 's/^/    /' "$th"; }

  # ⭐ Item 5 (per-seat unpark) — surfaced here, not just as a silent file, per
  #    its own design: a grant nobody can see is a grant nobody trusts. Lists
  #    EVERY seat_unpark_* file found, ACTIVE or STALE — a stale one left on
  #    disk (poller.sh deletes it lazily, only when that seat's own poller next
  #    checks it) is not an error, just not yet swept.
  source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
  if command -v placement_report >/dev/null 2>&1; then
    info "PLACEMENT (T-917 rules: pinned / precious / fable headroom / spread / projected):"
    placement_report 2>&1 | sed 's/^/  /' || true
    echo
  fi
  local unpark_files=("$STATE_DIR"/seat_unpark_*)
  if [[ -e "${unpark_files[0]}" ]]; then
    local cur_park; cur_park="$(stat -c %Y "$(THROTTLE_FLAG)" 2>/dev/null || echo '')"
    echo
    info "PER-SEAT EXEMPTIONS (aimail budget unpark):"
    local f
    for f in "${unpark_files[@]}"; do
      [[ -f "$f" ]] || continue
      local s r_park r_reason
      s="${f##*/seat_unpark_}"
      r_park="$(awk -F'\t' '$1=="park_started_at"{print $2}' "$f" 2>/dev/null)"
      r_reason="$(awk -F'\t' '$1=="reason"{print $2}' "$f" 2>/dev/null)"
      if [[ -n "$r_park" && -n "$cur_park" && "$r_park" == "$cur_park" ]]; then
        printf '  %-20s ACTIVE — %s\n' "$s" "${r_reason:-no reason given}"
      else
        printf '  %-20s STALE (superseded by a newer park) — %s\n' "$s" "${r_reason:-no reason given}"
      fi
    done
  fi
  return 0
}

# ─── History ──────────────────────────────────────────────────────────────────
# budget_history [--all] — every recorded reading (session AND weekly) for the
# current account, in order, from the same ledger both feed. Added 2026-09-04
# (the project owner, direct instruction): the session side of this ledger has always
# been append-only; the weekly side used to overwrite a single-value cache and
# had no history at all until budget_probe's own append (added the same day)
# started feeding this file too. This is the reader for that data — recording
# it and never being able to look at it again would be the same half-measure
# under a different name.
# ⛔ `--all` shows every account's rows, unlabelled-by-default readers would
#   otherwise silently mix accounts together exactly like the bug WEEKLY_FILE's
#   own per-account naming was built to prevent — so cross-account output is
#   opt-in and each row still carries its own account column.
budget_history() {
  local want_all=0
  [[ "${1:-}" == "--all" ]] && want_all=1
  [[ -s "$LEDGER" ]] || { info "no ledger rows recorded yet — run 'aimail budget probe' at least once."; return 0; }
  local acct; acct="$(account_id)"
  info "budget history$( (( want_all )) && echo ' (all accounts)' || echo " — account '$acct'" ):"
  echo
  printf '%-19s  %-10s  %-8s  %-5s  %s\n' "WHEN" "ACCOUNT" "SOURCE" "PCT%" "RESET/BOUNDARY"
  awk -F'\t' -v acct="$acct" -v all="$want_all" '
    all=="1" || $2==acct {
      when=$1; a=$2; p=$3; s=$4; r=$5
      cmd="date -d @" when " \"+%Y-%m-%d %H:%M\""; cmd | getline wd; close(cmd)
      if (r != "") { rcmd="date -d @" r " \"+%Y-%m-%d %H:%M\""; rcmd | getline rd; close(rcmd) } else { rd="-" }
      printf "%-19s  %-10s  %-8s  %-5s  %s\n", wd, a, s, p, rd
    }
  ' "$LEDGER"
  echo
  info "session rows: source=callout (a human read /usage) or probe (the unofficial API)."
  info "weekly rows:  source=weekly (the 7-day figure, same probe response as the session one)."
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
# ⭐⭐ WHEN THIS FIRES, per the project owner (2026-08-21): budget_autopilot no longer
#   parks on a fixed offset before the boundary. If there is plenty of budget
#   left, the block just rolls on its own at the ramp — no reason to go quiet
#   early. It parks ONLY when a fresh probe reads the account's session usage
#   at or over its cap, checked every autopilot tick (every 5 min via cron),
#   independent of how close the boundary is.
# ⭐ AR-11 fallback interval — when the block boundary cannot be measured, a
#   park must still re-check soon rather than never. Matches budget_ramp's own
#   recurring safety-net interval below.
BUDGET_RAMP_FALLBACK_SEC="${AIMAIL_RAMP_FALLBACK_SEC:-1200}"

# _write_ramp_at <block_end_epoch|empty> — the write-with-fallback logic
# budget_park and budget_refresh_ramp both need, kept in one place so the
# "never leave zero wake path" invariant (AR-11) cannot drift between the two
# call sites. Prints nothing on success; the caller decides what to log.
_write_ramp_at() {
  local be="${1:-}"
  local rat; rat="${be:-$(( $(now_epoch) + BUDGET_RAMP_FALLBACK_SEC ))}"
  printf 'at\t%s\n' "$rat" | atomic_write "$(RAMP_AT_FILE)" || return 1
  [[ -z "$be" ]] && warn "block boundary unmeasurable — ramp_at set to a $(( BUDGET_RAMP_FALLBACK_SEC / 60 ))-min recheck instead of the real boundary"
  return 0
}

# ⚠⚠ KNOWN LIMITATION, NAMED RATHER THAN SILENTLY CARRIED (2026-09-17): the
#   `$STATE_DIR/throttled` flag below (and `ramp_at`, and the checkpoint-streak
#   files this section shares the pattern with) is GLOBAL, not per-account --
#   this was already true before per-account autopilot existed and is NOT a
#   new regression introduced by it. Per-account grouping (see
#   _autopilot_seat_groups / budget_autopilot above) makes ACCOUNT RESOLUTION
#   and the PROBE/CAP-CHECK/CHECKPOINT logic correctly per-seat -- it does NOT
#   make the park/ramp STATE MACHINE itself per-account. In the fleet's actual
#   operating shape (one account at a time, switched together at a checkpoint/
#   ramp boundary, never two seats deliberately split across two live accounts
#   as standing practice) this has never mattered. If the fleet ever DOES run
#   two genuinely simultaneous accounts, one account parking at its own cap
#   would (as today, unchanged) also freeze the OTHER account's park/ramp
#   bookkeeping fleet-wide, since there is only one `throttled` file to check.
#   Making park/ramp/checkpoint-streak state genuinely per-account is a
#   real, separate, larger piece of work (it reaches into poller.sh's own
#   throttle-check too) -- out of scope here, and not silently assumed solved.
budget_park() {
  # ⛔⛔ 2026-09-25 (assistant, HIGH, mail 20260925T082038): `local reason="${*}"` used to take
  #   ANY argument as the literal park reason, including `-h`/`--help` -- `aimail budget park
  #   --help` parked the WHOLE account with reason "--help" (the librarian hit this live at
  #   08:19, ~40s of accidental park before `budget ramp` cleared it). Only the FIRST token is
  #   checked: a free-text reason may legitimately contain a hyphenated word later on ("disk
  #   -5% under floor"), so this is not a blanket "no dash anywhere" scan -- it exists to catch
  #   a mistyped/misremembered FLAG in the one position a flag would actually be typed.
  case "${1:-}" in
    -h|--help)
      info "usage: aimail budget park [reason text]"
      info "  Parks the fleet: sets the throttle flag with a REASON. Pollers stay armed and"
      info "  self-wake at the ramp (aimail budget ramp, usually automatic at the block roll)."
      info "  Nothing was changed."
      exit 0 ;;
    -*) refused "budget park: '$1' looks like a flag, not a reason -- refusing rather than" \
          "silently parking the whole account with that as the literal reason." \
          "  aimail budget park -h              — show usage" \
          "  aimail budget park <reason text>   — park with a plain-text reason (first word" \
          "                                        must not start with '-')" \
          "Nothing was changed." ;;
  esac
  local reason="${*:-manual park (no reason given)}"
  ensure_dirs
  local be; be="$(block_end_effective 2>/dev/null | cut -f1 || echo '')"
  if [[ -f "$(THROTTLE_FLAG)" ]]; then
    info "already parked — leaving the original reason in place:"; sed 's/^/  /' "$(THROTTLE_FLAG)"; return 0
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
  } | atomic_write "$(THROTTLE_FLAG)" \
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
  _write_ramp_at "$be" \
    || die "budget park: failed to write ramp_at — the fleet would park with NO wake path. Not proceeding."
  ok "fleet PARKED. Pollers stay armed and will wake at $( [[ -n "$be" ]] && date -d "@$be" '+%H:%M' || echo "a recheck in $(( BUDGET_RAMP_FALLBACK_SEC / 60 ))min" )."
}

# budget_refresh_ramp — called from the TAIL of budget_callout/budget_probe,
# never from budget_park itself. The gap this closes: a corrected reset time
# recorded via `callout --resets` while already parked never reached the live
# `ramp_at` file, because budget_park returns early ("already parked") before
# it would otherwise rewrite it — so a human's own correction, read straight
# off /usage, was silently discarded exactly when it mattered most (mid-park,
# the one time nobody is about to re-run `budget park` to pick it up).
# ⛔ ONLY touches ramp_at, never the `throttled` flag's own REASON/ACCOUNT
#   fields — those describe why/who parked, which a later reading does not
#   change. Re-derives block_end_effective fresh, same function budget_park
#   itself uses, so a later, better reading naturally produces a better
#   boundary without a second way to compute one.
# A no-op (not even a log line) when nothing is parked — there is no ramp_at
# to correct, and the next real budget_park will compute one fresh anyway.
#
# ⛔⛔ CODE-REVIEW'S GATE FINDING, FIXED HERE — the first version called
#   `_write_ramp_at "$be"` unconditionally, even when `$be` was empty
#   (boundary persistently unmeasurable). `_write_ramp_at`'s own fallback is
#   `now_epoch + BUDGET_RAMP_FALLBACK_SEC`, computed AT CALL TIME — so every
#   repeated call (this function runs at the tail of `budget_probe`, and
#   `budget_watch`'s loop calls `budget_probe` every ~30s by default) pushed
#   the recheck horizon another ~20 minutes into the future, forever. AR-11's
#   own invariant ("ramp_at always holds a real future value") was technically
#   satisfied at every instant, but the actual guarantee it exists for — the
#   fleet eventually self-wakes even when the boundary can't be measured — was
#   defeated, because the promised recheck kept receding as fast as it was
#   approached. Measured directly: two calls with `be` forced empty, 2s apart,
#   moved `ramp_at` forward by exactly 2s each time.
# FIX: when `$be` is empty, there is nothing NEW to correct with — leave
#   whatever `ramp_at` already holds (a real boundary, or an existing
#   fallback recheck) untouched, UNLESS there is no `ramp_at` at all yet, in
#   which case still write the fallback once (recovers AR-11's own invariant
#   for a seat that somehow got parked with none). This only ever refreshes
#   the fallback horizon on a genuine transition into "no ramp_at at all," not
#   on every tick spent still-unmeasurable.
budget_refresh_ramp() {
  [[ -f "$(THROTTLE_FLAG)" ]] || return 0
  local be; be="$(block_end_effective 2>/dev/null | cut -f1 || echo '')"
  local old=""
  [[ -f "$(RAMP_AT_FILE)" ]] && old="$(awk -F'\t' '$1=="at"{print $2}' "$(RAMP_AT_FILE)" 2>/dev/null)"
  [[ -z "$be" && -n "$old" ]] && return 0
  [[ -n "$be" && "$be" == "$old" ]] && return 0
  _write_ramp_at "$be" || { warn "budget_refresh_ramp: failed to update ramp_at — the previous value is still in force"; return 1; }
  [[ -n "$be" ]] && info "ramp_at refreshed: now $(date -d "@$be" '+%F %H:%M') (was $( [[ -n "$old" ]] && date -d "@$old" '+%F %H:%M' || echo 'unset' ))"
}

# ⛔⛔ AR-14 (the project owner, 2026-09-11, direct) — "the aimail should park when it reaches the weekly
#   limit. it also shouldn't ramp back up if the weekly limit is still past the cap." The first
#   half already worked (see the weekly-cap autopilot park above, AR-1367). The second half never
#   did: `budget_ramp`'s own header has always disclaimed "it cannot see a weekly cap ... and it
#   lifts neither", but nothing upstream of it ever ACTED on that disclaimer — the poller's own
#   ramp-check (lib/poller.sh) called `budget_ramp` unconditionally the instant a SESSION-block
#   boundary passed, regardless of WHY the fleet was parked. A park set for "weekly usage 97% is
#   at or over the 95% weekly cap" would therefore ramp right back to full fleet activity at the
#   very next 5-hour block boundary even though the 7-day weekly window had not moved at all —
#   the weekly halt file this same section of the code already writes (`SEAT_HALT_FILE`, tagged
#   `reason=weekly`, deliberately protected from a session-only ramp's cleanup a few lines below)
#   turned out to be informational only: nothing in the live poller loop ever consulted it before
#   deciding to wake.
#
# budget_weekly_still_blocking — true (exit 0) iff the CURRENT park's own recorded REASON names
# the weekly cap AND a weekly reading, fresh enough to trust, still reads at or over that cap.
# False (exit 1) for every other case: nothing parked, a session-only park, or a weekly park
# whose most recent reading has since dropped back under cap. Meant to be checked from the
# poller's own ramp-check, BEFORE calling `budget_ramp` — never after, and never as a substitute
# for it (a session-only park must still ramp normally on the boundary, unaffected by this).
#
# ⛔⛔ MUST NEVER CALL budget_probe() UNGUARDED. `unmeasurable()` (core.sh) is `exit 4` — a hard
#   process exit, not a `return 1` — because a probe failure and a genuine zero reading must never
#   look alike. Called inline from inside a poller's own long-running process, that exit would
#   kill the POLLER ITSELF, silently, with no WAKE= line and no re-arm notice: the exact "zero
#   wake path" failure this entire file exists to prevent, self-inflicted by the very guard meant
#   to protect the weekly cap. Always run it in a subshell, the same containment idiom
#   `budget_autopilot` already uses for `( budget_checkpoint ... )`.
#
# ⭐ WHY AN UNCERTAIN READING STAYS BLOCKING, NOT SAFE: this function and `budget_autopilot`'s own
#   park decision (above) are asymmetric on purpose. There, a missing/stale reading is treated as
#   "unmeasurable, do not park defensively" — a false negative just means the fleet keeps working
#   a little past a cap that may or may not have been breached yet. Here the false negative runs
#   the other way: wrongly concluding "safe to ramp" resumes full, unattended fleet activity past
#   a cap the project owner set on purpose, for up to another full session block before anything checks
#   again. So a reading this function cannot confirm — even after a fresh probe attempt — is
#   treated as STILL BLOCKING: stay parked, recheck again shortly, never guess safe.
budget_weekly_still_blocking() {
  [[ -f "$(THROTTLE_FLAG)" ]] || return 1
  grep -qE '^REASON .*weekly usage' "$(THROTTLE_FLAG)" 2>/dev/null || return 1

  local stale_sec="${AIMAIL_WEEKLY_HOLD_STALE_SEC:-900}"
  local wl wl_e wl_p wcap
  wl="$(_last_weekly 2>/dev/null || true)"
  if [[ -z "$wl" ]]; then
    ( budget_probe >/dev/null 2>&1 ) || true
    wl="$(_last_weekly 2>/dev/null || true)"
  else
    wl_e="$(cut -f1 <<<"$wl")"
    if [[ "$wl_e" =~ ^[0-9]+$ ]] && (( $(now_epoch) - wl_e > stale_sec )); then
      ( budget_probe >/dev/null 2>&1 ) || true
      wl="$(_last_weekly 2>/dev/null || true)"
    fi
  fi
  # Still nothing (or the refresh attempt above didn't produce a reading) —
  # cannot confirm recovery, so stay parked rather than guess safe.
  [[ -n "$wl" ]] || return 0

  wl_p="$(cut -f2 <<<"$wl")"
  wcap="$(weekly_cap)"
  [[ "$wl_p" =~ ^[0-9]+$ ]] || return 0
  (( wl_p >= wcap ))
}

budget_ramp() {
  _dash_arg_guard "usage: aimail budget ramp" "$@"
  rm -f "$(THROTTLE_FLAG)"
  # Clear per-seat halts caused by the SESSION cap only — a session-block roll
  # gives every seat a fresh 5-hour window, but does not reset the 7-day
  # weekly window, so a WEEKLY halt must survive a ramp untouched.
  local f reason
  for f in "$STATE_DIR"/seat_halt_*; do
    [[ -f "$f" ]] || continue
    reason="$(cut -f1 "$f" 2>/dev/null)"
    [[ "$reason" == "session" ]] && rm -f "$f"
  done
  printf '%s\n' "$(now_epoch)" > "$STATE_DIR/fleet_resumed_at"
  # Re-arm the gate 20 minutes out rather than deleting it: if this ramp does not
  # actually result in the seats being woken, it must fire AGAIN. Deleting the
  # trigger is how a ramp silently no-ops.
  # AR-03 — same pipe-sink propagation as budget_park above.
  printf 'at\t%s\n' "$(( $(now_epoch) + BUDGET_RAMP_FALLBACK_SEC ))" | atomic_write "$(RAMP_AT_FILE)" \
    || die "budget ramp: failed to write the new ramp_at — the throttle was cleared but the safety-net recheck was NOT scheduled."
  ok "throttle CLEARED at $(now_iso)"
  info "  ⚠ This is a CONDITION, not a permission. It reports that a block rolled."
  info "    It cannot see a WEEKLY cap or a human-imposed hold, and it lifts neither."
  info "  ▶ Get a fresh /usage callout before trusting any level: every pre-ramp"
  info "    reading describes a window that no longer exists."
}

# budget_unpark <seat> [--reason "..."] — exempt ONE seat from the CURRENT park,
# without touching the shared `throttled` flag and without lifting it for
# anyone else.
#
# ⛔⛔ THIS DOES NOT VOUCH FOR THE SEAT'S OWN USAGE. Same non-assertion
#    discipline AR-12's account-mismatch fix already uses: it un-blocks one
#    seat's poller, it does not claim that seat is under-cap, over-cap, or
#    anything else about its real consumption. A human or coordinator grants
#    this because THEY know something this instrument cannot measure (a seat on
#    a separate account, a seat that must finish a priority item from the project owner) — the
#    tool's only job is to record that grant and expire it correctly.
# ⭐ THE EXPIRY MECHANISM IS A COPY, NOT A TTL. The grant captures `throttled`'s OWN mtime — the
#    stable identity of the CURRENT park episode — verbatim. `budget_park()` is a no-op whenever
#    `throttled` already exists ("already parked — leaving the original reason in place"), so
#    that file's own mtime never changes for the DURATION of one park; only a genuinely NEW
#    `budget_park()` call (after a `budget_ramp()` deleted the old `throttled`) writes a fresh
#    one, with a fresh mtime. So the captured copy silently goes stale the moment a park it was
#    never granted under begins — no clock to compute, no separate expiry job to run, and no way
#    for one grant to outlive the specific park episode it was made for.
# ⛔⛔ NOT `ramp_at`'s OWN VALUE (an earlier version of this function used that). code-review's own
#    gate (2f9e4f0) found the real interaction this avoids: a LEGITIMATE re-measurement of the
#    block boundary mid-park (e.g. item 2's own `budget_refresh_ramp`) can rewrite `ramp_at`'s
#    value without ANY new park actually beginning — exact-value equality on `ramp_at` would then
#    misread that refresh as "a new park superseded this grant" and delete an still-valid
#    exemption. `throttled`'s own mtime is immune to that: nothing but a genuinely new park ever
#    changes it.
budget_unpark() {
  case "${1:-}" in
    -h|--help)
      info "usage: aimail budget unpark <seat> [--reason \"...\"]"
      info "  Exempts ONE seat from the current park. Nothing was changed."
      exit 0 ;;
  esac
  local seat="${1:-}"; shift || true
  local reason="manual unpark, no reason given"
  while (( $# )); do
    case "$1" in
      -h|--help)
        info "usage: aimail budget unpark <seat> [--reason \"...\"]"
        info "  Nothing was changed."
        exit 0 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) refused "unknown unpark argument: '$1'" "Try: aimail budget unpark <seat> [--reason \"...\"]" ;;
    esac
  done
  [[ -n "$seat" ]] && seat_exists "$seat" || refused "usage: aimail budget unpark <seat> [--reason \"...\"]" \
    "'$seat' is not a registered seat." \
    "  aimail seat list     — see who is registered"
  ensure_dirs
  local park_started_at
  park_started_at="$(stat -c %Y "$(THROTTLE_FLAG)" 2>/dev/null || echo '')"
  # KEY\tVALUE, one field per line — `park_started_at` first and on its own line so a reason
  # containing arbitrary text (spaces, punctuation) can never shift a later field; only
  # `park_started_at` is ever read back by machine logic (poller.sh's own exemption check).
  { printf 'park_started_at\t%s\n' "${park_started_at:-}"
    printf 'at\t%s\n' "$(now_epoch)"
    printf 'reason\t%s\n' "$reason"
  } | atomic_write "$STATE_DIR/seat_unpark_$seat" \
    || die "budget unpark: failed to write the exemption for '$seat' — it is NOT unparked."
  [[ -z "$park_started_at" ]] && warn "the fleet is not currently parked — this exemption has no park episode to attach to, so it does NOTHING right now. It also will NOT retroactively apply to a later park: re-run this command once that park has actually begun."
  ok "seat '$seat' exempted from the current park (reason: $reason)."
  info "  ⚠ This does not lift the fleet-wide throttle, and makes no claim about"
  info "    '$seat''s own usage — it un-blocks that seat's poller, nothing else."
  info "  Expires automatically the moment a NEW park supersedes this one."
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
  case "${1:-}" in
    -h|--help)
      info "usage: aimail budget checkpoint [--now]"
      info "  Asks every seat to write its ROLE.md handover, if due (or unconditionally"
      info "  with --now). Nothing was changed."
      exit 0 ;;
    --now|"") ;;
    -*) refused "budget checkpoint: '$1' is not a recognized flag (only --now is)." \
          "  aimail budget checkpoint -h" "Nothing was changed." ;;
  esac
  local force="${1:-}"
  # ─ acct/seat_list — added for per-account autopilot (see budget_autopilot).
  #   Both OPTIONAL and both empty by default, which is the exact CLI/manual
  #   shape this always had: one shared marker, every registered seat. Passed
  #   only by budget_autopilot's own per-account-group loop, never by a human.
  local acct="${2:-}"
  local seat_list="${3:-}"
  local be; be="$(block_end_effective 2>/dev/null | cut -f1)" || true
  [[ -n "$be" ]] || unmeasurable "cannot read the block end, so the checkpoint cannot be scheduled" \
    "A checkpoint fired at the wrong time is worse than none: it spends budget" \
    "writing a handover nobody needed yet."
  local left=$(( (be - $(now_epoch)) / 60 ))
  if [[ "$force" != "--now" ]] && (( left > CHECKPOINT_MIN )); then
    info "not due: ${left} min left, checkpoint at ${CHECKPOINT_MIN} min before the end"
    return 0
  fi
  # ⭐ ONE MARKER PER ACCOUNT, not one global file. Two account groups in the
  #   same tick can have genuinely different block-end times (different
  #   session histories) — sharing one marker would let the second group's
  #   write clobber the first's, making the first re-fire needlessly next
  #   tick. Suffix-less when acct is unset (the ordinary single-account/CLI
  #   case), so nothing changes there.
  local marker="$STATE_DIR/checkpoint_done${acct:+.$acct}"
  # ⛔⛔ 2026-09-04 (foundation, fable's diagnosis + assistant's low-priority
  #   assignment): `$be` is `block_end_effective`'s raw epoch reading, which
  #   JITTERS by up to a minute or more tick-to-tick (it alternates between the
  #   probe and ccusage sources, and even the same source's own reading can
  #   shift slightly between polls) — an exact `==` comparison against it is
  #   the dedup-key-embeds-a-fluctuating-value defect (AI_ONBOARDING already
  #   names this class): the marker almost never matches, so the checkpoint
  #   RE-FIRES every 5-min tick until the block finally rolls (measured live,
  #   2026-09-04: 4 re-fires in 30 min, alternating "0239"/"0240"). First fixed
  #   by bucketing to 15 minutes (blocks are 5 HOURS apart, so no genuinely new
  #   block could ever land in the same bucket as the previous one's end).
  # ⛔⛔ 2026-09-05 (fable's cadence-check flag, assistant's diagnosis): bucketing
  #   still re-fires every 5 min on whichever tick lands unluckily ON the
  #   bucket's own edge — confirmed live 22:45-23:25 on 2026-09-05, 8 re-fires
  #   in 40 min, because that night's true block end jittered between :29 and
  #   :30 and 900s-since-epoch happens to tick over at exactly :30:00. ANY
  #   bucket width has this failure mode for a value that straddles its edge;
  #   quantizing at all is the defect. Compare the raw epoch distance to the
  #   FIRST `be` recorded instead — no edge to straddle. Observed jitter is
  #   ~1-2 minutes; a real new block is ~5h (18000s) later; 300s (5 min) sits
  #   comfortably above the former and far below the latter.
  local -r CHECKPOINT_JITTER_TOLERANCE_SEC=300
  local stored; stored="$(cat "$marker" 2>/dev/null)"
  if [[ "$stored" =~ ^-?[0-9]+$ ]]; then
    local diff=$(( be - stored )); (( diff < 0 )) && diff=$(( -diff ))
    if (( diff <= CHECKPOINT_JITTER_TOLERANCE_SEC )); then
      # ⛔ Key the marker on the BLOCK END, not a boolean. `now >= X` stays true
      #    forever once true, so a boolean turns this into a wake loop firing
      #    every poll — the most expensive possible bug in a supervision path.
      #    A genuinely NEW block has a new end and must still fire — the
      #    tolerance window is far too narrow to reach a real block gap.
      #    Do NOT rewrite the marker here: it stays anchored at the first `be`
      #    seen so the tolerance window can't walk forward tick by tick.
      info "already checkpointed for the block ending $(date -d "@$be" '+%H:%M')"
      return 0
    fi
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
  if [[ -n "$seat_list" ]]; then
    # Per-account-group call from budget_autopilot: mail exactly this group's
    # own seats, never the whole registry — the other groups' own passes
    # cover everyone else this same tick.
    for seat in $seat_list; do
      [[ -n "$seat" ]] || continue
      mail_send --to "$seat" --from "$from" \
        --subject "CHECKPOINT write ROLE.md block ends $(date -d "@$be" '+%H%M')" \
        --body-file "$body" >/dev/null 2>&1 && n=$((n+1))
    done
  else
    while IFS= read -r seat; do
      [[ -n "$seat" ]] || continue
      [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
      mail_send --to "$seat" --from "$from" \
        --subject "CHECKPOINT write ROLE.md block ends $(date -d "@$be" '+%H%M')" \
        --body-file "$body" >/dev/null 2>&1 && n=$((n+1))
    done < <(seat_names)
  fi
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
    ok "checkpoint sent to $n seat(s)${acct:+ (account $acct)} — block ends $(date -d "@$be" '+%H:%M')"
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
#
# ⭐⭐ 2026-09-17 (the project owner, via assistant): PER-ACCOUNT, not a single ambient
#   guess for the whole fleet -- see the "Per-seat account detection" section
#   above for the incident this closes. budget_autopilot() below is now a thin
#   wrapper: it groups currently-live, registered seats by their OWN resolved
#   account (seat_account_dir(), grounded in each seat's real poller process,
#   never a symlink), then runs the ACTUAL tick logic -- unchanged from before,
#   see _budget_autopilot_tick() -- once per distinct resolved account, with
#   CLAUDE_CONFIG_DIR set to that account's own real directory for the
#   duration of that one call. Bash's ordinary `VAR=val cmd` scoping means the
#   override applies to that call and everything it spawns (ccusage,
#   budget_probe's OAuth-token read, mail_send) and reverts on return -- no
#   manual save/restore needed, and nothing here mutates this process's own
#   ambient environment permanently.
# ⇒ COLLAPSES TO TODAY'S EXACT BEHAVIOR in the common case: one distinct
#   account among all live seats means one loop iteration, with
#   CLAUDE_CONFIG_DIR set to the same real directory the ambient environment
#   already pointed at (or, if it didn't -- exactly today's incident -- now
#   CORRECTLY pointed at the real one instead).
# ⇒ NEVER CRASHES, NEVER GUESSES: seats with no live per-seat signal (no
#   heartbeat, a dead pid, no CLAUDE_CONFIG_DIR in their environ) fall into a
#   catch-all group tagged with the CURRENT ambient account_id() and run with
#   NO override -- i.e. today's exact fallback path -- so they still get
#   checkpointed rather than silently dropped. If NO seat anywhere resolves
#   (a totally cold registry, or a box with no /proc), the grouping step
#   returns nothing and this falls all the way back to a single bare
#   _budget_autopilot_tick() call, byte-identical to the pre-2026-09-17 code.
budget_autopilot() {
  local groups; groups="$(_autopilot_seat_groups 2>/dev/null || true)"
  if [[ -z "$groups" ]]; then
    _budget_autopilot_tick
    return $?
  fi
  local rc=0 dir acct seats line
  # ⛔ NEVER `IFS=$'\t' read` here -- tab is an IFS "whitespace" character to
  #   the read builtin regardless of what IFS is explicitly set to, so a
  #   LEADING tab (dir="" -- exactly the fallback-group case, the common one
  #   on any tick where an unresolved seat exists) collapses and shifts every
  #   field left: acct silently became "$dir$TAB$acct" as one string and
  #   $seats came out empty. This is the EXACT class fleet.sh's own hb_read
  #   docstring warns about -- measured live here, not theoretical: it set
  #   CLAUDE_CONFIG_DIR to a literal bogus string (part of a seat-name list)
  #   instead of leaving it unset, silently breaking budget_probe's own
  #   OAuth-token lookup. `cut -f`, never `read` with a tab IFS.
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    dir="$(cut -f1 <<<"$line")"; acct="$(cut -f2 <<<"$line")"; seats="$(cut -f3 <<<"$line")"
    [[ -n "$acct" ]] || continue
    if [[ -n "$dir" ]]; then
      CLAUDE_CONFIG_DIR="$dir" _budget_autopilot_tick "$acct" "$seats" || rc=$?
    else
      _budget_autopilot_tick "$acct" "$seats" || rc=$?
    fi
  done <<< "$groups"
  # ⭐ load balancer, decision layer (design §3.2–§3.4), ONCE per autopilot run after every
  #   account's own tick: pressures, streak, would-recommend. Read-only in this cut — it
  #   writes only state/balance/streak. Never affects $rc.
  if [[ "${AIMAIL_BALANCE_ENABLED:-1}" == "1" ]]; then
    source "${BASH_SOURCE[0]%/*}/fleet.sh" 2>/dev/null || true
    source "${BASH_SOURCE[0]%/*}/balance.sh" 2>/dev/null || true
    if command -v balance_evaluate >/dev/null 2>&1; then
      ( balance_evaluate ) || warn "autopilot: balance evaluation did not complete (see above)"
    fi
  fi
  # T-917 item 3 (2026-09-22): after the accounts' own ticks have refreshed the ledgers, emit the
  # 50/80 crossing warnings (block / weekly / fable-model, plus the projected cap-hit) ONCE per tick.
  # Reads only; one mail per (account, gauge, level, window). Never fails the tick.
  if [[ "${AIMAIL_WARNINGS:-1}" == "1" ]]; then
    source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
    source "${BASH_SOURCE[0]%/*}/warnings.sh" 2>/dev/null && budget_warnings >/dev/null 2>&1 || true
  fi
  # T-917 item 4 (2026-09-22): the balancer ACTS -- announce-then-do, one seat per tick, never
  # mid-turn, behind AIMAIL_BALANCE_ACT=1 (lib/act.sh). Runs after the warnings so a fresh
  # crossing and the move it triggers land in the same tick's mail.
  if [[ "${AIMAIL_BALANCE_ACT:-0}" == "1" ]]; then
    source "${BASH_SOURCE[0]%/*}/fleet.sh" 2>/dev/null || true
    source "${BASH_SOURCE[0]%/*}/balance.sh" 2>/dev/null || true
    source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
    source "${BASH_SOURCE[0]%/*}/act.sh" 2>/dev/null && balance_act || true
  fi
  # ⭐ ASK LEDGER SWEEP, once per autopilot run (cron runs autopilot every 10
  # min, the ledger's own designed cadence). Read/write only against its own
  # TSV, never the accounts/seats above -- a sweep failure must never block
  # park/ramp, so it runs in its own subshell and never touches $rc.
  source "${BASH_SOURCE[0]%/*}/ask.sh" 2>/dev/null || true
  if command -v ask_sweep >/dev/null 2>&1; then
    ( ask_sweep ) || warn "autopilot: ask sweep did not complete (see above)"
  fi
  return $rc
}

# _autopilot_seat_groups — one line per DISTINCT resolved account among
# currently-live, non-retired registered seats: "<dir>\t<acct>\t<seats>".
# `<dir>` is the real, readlink-resolved CLAUDE_CONFIG_DIR for that account
# (EMPTY for the catch-all fallback group below -- the caller must NOT
# override CLAUDE_CONFIG_DIR in that case, there is nothing more specific to
# set it to). `<seats>` is a space-separated list. Prints nothing at all if
# no seat resolves and there is nothing to fall back to gather (an empty
# registry) -- budget_autopilot's own caller treats that as "run once, plain".
_autopilot_seat_groups() {
  local seat dir acct
  local -A _grp_seats=() _grp_dir=()
  local unresolved=""
  while IFS= read -r seat; do
    [[ -n "$seat" ]] || continue
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    # ⛔ THE SEAT REGISTRY FIRST (2026-09-23 04:05 incident): `seat_account_dir` reads the account off the
    #   seat's LIVE poller process, so when every poller of a budget-parked account had died (their
    #   Monitors expired while the sessions were blocked) that account had no group at all -- no probe,
    #   no ramp, ramp_at passed unseen, five seats idle for an hour after the reset. A seat's confirmed
    #   record (state/seat_account/<seat>, `aimail seat confirm`) names its account whether or not a
    #   process is alive; the live pid is the fallback, the ambient account the last resort.
    dir=""; acct=""
    local _rec="$STATE_DIR/seat_account/$seat" _racct
    if [[ -f "$_rec" ]]; then
      _racct="$(awk -F'\t' '$1=="account"{print $2; exit}' "$_rec")"
      [[ -n "$_racct" ]] && dir="$(readlink -f "$(ACCOUNT_CONFIG_DIR "$_racct")" 2>/dev/null || true)"
      # The recorded WORD is the group's key (not the dir's basename): an AIMAIL_ACCOUNT_DIR_<acct>
      # override may point anywhere, and the label must still match the account's own name.
      if [[ -n "$dir" && -d "$dir" ]]; then acct="$_racct"; else dir=""; fi
    fi
    [[ -n "$dir" ]] || dir="$(seat_account_dir "$seat")"
    if [[ -n "$dir" ]]; then
      [[ -n "$acct" ]] || acct="$(basename "$dir" | sed 's/^\.//; s/^claude-//; s/^claude$/default/')"
      _grp_dir["$acct"]="$dir"
      _grp_seats["$acct"]="${_grp_seats[$acct]:+${_grp_seats[$acct]} }$seat"
    else
      unresolved="${unresolved:+$unresolved }$seat"
    fi
  done < <(seat_names)

  # Seats with no live per-seat signal still need SOME group, or they are
  # silently dropped from the checkpoint mailing entirely (a real regression
  # vs. today, where every non-retired seat gets mailed regardless of
  # liveness). Fold them into whichever account the ambient environment
  # resolves to right now -- today's exact fallback -- UNLESS that same
  # account already has its own resolved group from a genuinely live seat,
  # in which case fold in there instead of creating a second row that would
  # probe/park-check the same account twice in one tick.
  if [[ -n "$unresolved" ]]; then
    local ambient_acct; ambient_acct="$(account_id)"
    if [[ -n "${_grp_dir[$ambient_acct]:-}" ]]; then
      _grp_seats["$ambient_acct"]="${_grp_seats[$ambient_acct]} $unresolved"
    else
      _grp_dir["$ambient_acct"]=""
      _grp_seats["$ambient_acct"]="${_grp_seats[$ambient_acct]:+${_grp_seats[$ambient_acct]} }$unresolved"
    fi
  fi

  local a
  for a in "${!_grp_seats[@]}"; do
    printf '%s\t%s\t%s\n' "${_grp_dir[$a]}" "$a" "${_grp_seats[$a]}"
  done
}

_budget_autopilot_tick() {
  local acct="${1:-}" seat_list="${2:-}"
  local be now; now="$(now_epoch)"

  # ⭐⭐ PROBE FIRST, UNCONDITIONALLY, EVERY TICK (fable's ruling, 2026-09-01,
  #   Part 3: "flip precedence — authoritative-first, one curl per 5-min tick
  #   is trivial"). This used to run only AFTER block_end_effective already
  #   succeeded (see the law this incident minted, above AUTOPILOT_STREAK_FILE)
  #   — which meant ccusage was the load-bearing PRIMARY in practice, and the
  #   live, transcript-independent probe was reachable only once it was no
  #   longer needed. Probing here instead makes `_last_callout` fresh BEFORE
  #   `block_end_effective` ever consults it, so ccusage becomes what it was
  #   always supposed to be: a real fallback for the boundary specifically
  #   (block_end_effective's own per-field EARLIER-wins comparison below is
  #   unchanged), not the single point of failure a subagent-only stretch of
  #   activity can silently blind.
  ( budget_probe >/dev/null 2>&1 ) \
    || warn "autopilot: probe failed this cycle — falling back to ccusage for the boundary"

  be="$(block_end_effective 2>/dev/null | cut -f1)"
  if [[ -z "$be" ]]; then
    # ⚠ Refuse loudly rather than doing nothing quietly. A silent no-op here is
    #   indistinguishable from a healthy tick, and the failure would only surface
    #   as a fleet that never checkpointed. Streak-and-escalate (Part 2): a
    #   human/seat gets paged after AUTOPILOT_UNMEASURABLE_N ticks instead of
    #   this warning running silently into a log nobody watches for hours.
    _autopilot_measured_fail
    warn "autopilot: block end UNMEASURABLE — no checkpoint, park or ramp performed"
    return 4
  fi
  _autopilot_measured_ok
  local left=$(( (be - now) / 60 ))
  info "autopilot $(now_iso): block ends $(date -d "@$be" '+%H:%M'), ${left} min left, account $(account_id) cap $(account_cap)%${acct:+ [seat-resolved group: $acct]}"

  # Ramp first: a block that has already rolled invalidates everything below it.
  if [[ -f "$(THROTTLE_FLAG)" ]] && (( now >= be )); then
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
    ( budget_checkpoint "" "$acct" "$seat_list" ) \
      || warn "autopilot: the checkpoint step failed or refused (see above) — continuing to the park check regardless; a missed checkpoint must never prevent a park"
  fi
  # ⭐⭐ PARK IS USAGE-GATED, NOT TIME-GATED (the project owner, 2026-08-21). It used to
  #   fire unconditionally at PARK_MIN before every boundary, whether or not
  #   there was any real reason to go quiet. Now it checks the actual number:
  #   park only if the freshest reading for THIS block is at or over the
  #   account's cap. A stale or missing reading reads as "unmeasurable", never
  #   as "must park defensively" — the project owner's own framing: if there is plenty
  #   left, the block just resets at the ramp on its own, with no forced quiet
  #   period. ⚠ The probe itself already ran, unconditionally, at the top of
  #   this function (Part 3 above) — re-probing here would just be a second
  #   curl call for a reading `_last_callout` already has fresh.
  if [[ ! -f "$(THROTTLE_FLAG)" ]]; then
    local lc lc_e lc_p bs cap
    lc="$(_last_callout 2>/dev/null || true)"
    if [[ -n "$lc" ]]; then
      lc_e="$(cut -f1 <<<"$lc")"; lc_p="$(cut -f2 <<<"$lc")"
      bs="$(block_field start 2>/dev/null || echo '')"
      if [[ -n "$bs" ]] && (( lc_e < bs )); then
        info "autopilot: last usage reading predates the current block — not parking on a stale number"
      else
        cap="$(account_cap)"
        if (( lc_p >= cap )); then
          # ⭐⭐ FORCE THE CHECKPOINT HERE, UNCONDITIONALLY (the project owner, 2026-09-01):
          #   an early, usage-triggered park IS the account-switch signal --
          #   unlike a natural block-end rollover, which needs no handover
          #   because the SAME account's quota just refills, this is the one
          #   case where continuing to work actually means switching accounts,
          #   possibly with hours still left on the clock. The time-gated
          #   checkpoint above answers the wrong question for this path; this
          #   call is the one that's actually load-bearing. Same subshell
          #   contract as the time-gated call above: checkpoint is advisory,
          #   park is not -- a failed/refused checkpoint must never block park.
          ( budget_checkpoint --now "$acct" "$seat_list" ) \
            || warn "autopilot: the pre-park checkpoint failed or refused (see above) — parking anyway, a missed checkpoint must never prevent a park"
          budget_park "automatic: real usage ${lc_p}% is at or over the ${cap}% cap for account $(account_id)"
          _budget_recommend_migration_for_seats "$seat_list"
        fi
      fi
    else
      info "autopilot: no usage reading yet this block — cannot park on usage alone"
    fi
  fi

  # ⛔⛔ WEEKLY CAP, CHECKED SEPARATELY (the project owner, 2026-09-03 real incident): the
  #   block above only ever compares against account_cap() (the SESSION/block
  #   ceiling, e.g. 80%). `budget status` has always DISPLAYED the weekly
  #   reading with a "wins over session%, regardless" annotation, but nothing
  #   in this function ever ACTED on it -- weekly hit 97%, well past its own
  #   95% cap, with zero automatic park, because there was no code path here
  #   that read weekly_cap()/_last_weekly at all. `budget_watch` checks weekly,
  #   but it is explicitly NOT a cron job (see its own header) -- it only runs
  #   if some session manually starts and holds it open. This is the durable,
  #   unattended path, so it needs its own check, independent of the block-cap
  #   branch above (either one parking must not block the other from firing).
  if [[ ! -f "$(THROTTLE_FLAG)" ]]; then
    local wl wl_e wl_p wcap
    wl="$(_last_weekly 2>/dev/null || true)"
    if [[ -n "$wl" ]]; then
      wl_e="$(cut -f1 <<<"$wl")"; wl_p="$(cut -f2 <<<"$wl")"
      wcap="$(weekly_cap)"
      # No block-boundary staleness check here, deliberately: the weekly
      # window (7 days) and the block window (5 hours) are different clocks,
      # so "predates the current block" is the wrong staleness test for this
      # reading. _last_weekly's own age is surfaced in `budget status`
      # separately; a fresh probe already ran at the top of this tick.
      if (( wl_p >= wcap )); then
        ( budget_checkpoint --now "$acct" "$seat_list" ) \
          || warn "autopilot: the pre-park checkpoint failed or refused (see above) — parking anyway, a missed checkpoint must never prevent a park"
        budget_park "automatic: weekly usage ${wl_p}% is at or over the ${wcap}% weekly cap for account $(account_id)"
        _budget_recommend_migration_for_seats "$seat_list"
      fi
    fi
  fi
  # ⭐ load balancer, measurement layer (lib/balance.sh, design §3.1): per-seat usage rows
  #   for THIS account dir, reconciled against its block. Read-only; a failure here never
  #   affects the park/ramp logic above (own subshell, own exit swallowed with a warning).
  if [[ "${AIMAIL_BALANCE_ENABLED:-1}" == "1" ]]; then
    source "${BASH_SOURCE[0]%/*}/balance.sh" 2>/dev/null || true
    if command -v seat_usage_tick >/dev/null 2>&1; then
      ( seat_usage_tick "$(account_id)" ) || warn "autopilot: seat usage tick did not complete for $(account_id) (see above) — balancer reads UNMEASURED for it"
    fi
  fi
  return 0
}

# _budget_recommend_migration_for_seats <space-separated seat list> — called
# right after an automatic park, once per affected seat. ⛔ MUST run each
# seat's recommendation in its OWN subshell: budget_recommend_migration calls
# seat_exists/refused (a hard exit on a bad seat name) and, deeper inside,
# budget_pick_account_live's own probe path, neither of which may be allowed
# to kill the WHOLE autopilot tick over one seat's own failure — the same
# containment contract every other autopilot-tick call already follows
# (budget_checkpoint, budget_probe). One seat's failure here must never
# suppress another seat's recommendation, or the park itself.
_budget_recommend_migration_for_seats() {
  local seat_list="${1:-}"
  local seat
  for seat in $seat_list; do
    [[ -n "$seat" ]] || continue
    ( budget_recommend_migration "$seat" >/dev/null 2>&1 ) \
      || true   # no eligible target / already recommended / not registered — all non-fatal, nothing to escalate on
  done
}

# ─── watch — sub-minute per-seat cap notification ────────────────────────────
# ⛔⛔ NOT A CRON JOB. Cron's floor is one minute; this is for cadences tighter
#   than that. It is a LOOP that must itself stay alive, so — mirror image of
#   the autopilot warning above — starting it from a session ties its life to
#   that session's. Fine for a supervised daytime run someone will notice die;
#   for an unattended run, autopilot (cron, park/ramp on the block boundary)
#   is still the durable mechanism. This does not replace it, it adds a much
#   faster per-seat signal on top.
#
# Edge-triggered, not level-triggered: a marker file per seat records ONLY
# "already notified for the current halt episode", so a seat pinned at 96%
# for an hour gets exactly one mail, not one every interval. The marker is
# removed the moment that seat reads OK again, so the NEXT halt — even later
# in the same block — notifies fresh.
BUDGET_WATCH_ALERT_DIR() { echo "$STATE_DIR/budget_watch_alerted"; }
budget_watch() {
  local interval="${1:-30}"
  local supervisor="${AIMAIL_BUDGET_SUPERVISOR:-assistant}"
  mkdir -p "$(BUDGET_WATCH_ALERT_DIR)"
  info "budget watch: probing every ${interval}s, notifying '$supervisor' on each OK→HALT crossing (ctrl-c or kill to stop)"
  while true; do
    # ⛔ budget_probe calls unmeasurable()/die() on failure, which is a hard
    #   `exit`, not a `return` — called bare like this, ANY transient probe
    #   failure (one curl timeout) would `exit` this whole loop, not just
    #   this cycle. MUST run inside an explicit subshell so that exit only
    #   ends the subshell; the loop reads its status normally from `if`.
    #   (This killed the first run of this loop, exit 4, first cycle.)
    if ! ( budget_probe >/dev/null 2>&1 ); then
      warn "budget watch: probe failed this cycle (endpoint down or token missing?) — retrying in ${interval}s"
    else
      local seat marker verdict
      while IFS= read -r seat; do
        [[ -n "$seat" ]] || continue
        [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
        marker="$(BUDGET_WATCH_ALERT_DIR)/$seat"
        verdict="$(budget_seat_check "$seat" 2>/dev/null || true)"
        if [[ "$verdict" == "HALT" ]]; then
          [[ -f "$marker" ]] && continue   # already notified this episode
          local reason pct scap wcap body
          IFS=$'\t' read -r reason _ pct < "$(SEAT_HALT_FILE "$seat")" 2>/dev/null || true
          scap="$(seat_cap "$seat")"; wcap="$(weekly_cap)"
          body="$(mktemp "${AIMAIL_ROOT}/tmp/budgetwatch.XXXXXX")"
          { printf '# 🟡 BUDGET: %s crossed its cap (%s, %s)\n\n' "$seat" "${reason:-session}" "${pct:-?}"
            printf 'seat cap %s%%   weekly cap %s%%\n\n' "$scap" "$wcap"
            printf 'No human asked for this reading specifically — budget watch found it, polling every %ss.\n' "$interval"
            printf 'Run `aimail budget seat-check %s` to confirm current state before acting.\n' "$seat"
          } > "$body"
          if seat_exists "$supervisor" && mail_send --to "$supervisor" --from "$supervisor" \
               --subject "BUDGET: $seat crossed its cap (${reason:-session} ${pct:-?}%)" --body-file "$body" >/dev/null 2>&1; then
            touch "$marker"
          else
            warn "budget watch: '$seat' is HALT but notifying '$supervisor' failed — will retry next cycle"
          fi
          rm -f "$body"
        else
          rm -f "$marker"   # back to OK (or unmeasurable) — next HALT notifies fresh
        fi
      done < <(seat_names)
    fi
    sleep "$interval"
  done
}
