# shellcheck shell=bash
# session.sh — ONE command that answers "am I actually set up right, right now?"
#
# ⛔⛔ WHY THIS EXISTS (2026-09-03, live incident). An architect session ran for
#   hours, ended its turn dozens of times, and a project-local Stop hook
#   (`.claude/hooks/poller_guard.sh`) fired EVERY time — but that hook keeps its
#   OWN session->seat registration, separate from this repo's `stop_guard.sh`.
#   The session had registered with `stop_guard.sh` (step 4 of the documented
#   checklist) but never with the project fork (a DIFFERENT script, DIFFERENT
#   state dir, same session id) — so every firing returned
#   `decision=allow-unregistered`, silently, forever. Nothing about that state
#   LOOKED wrong: `aimail fleet` read whatever the poller process table said,
#   `aimail whoami` found the `stop_guard.sh` mapping and reported healthy, and
#   the hook's own JSON output (when it does block) looks identical whether the
#   block is a real enforcement or a permanently-inert unregistered pass-through.
#   AR-26 (role.sh) had already anticipated exactly this shape and built
#   `AIMAIL_EXTERNAL_SEAT_DIR` as the fix — but wiring it is a manual step, and
#   nothing ever prompted anyone to take it. Two correct pieces, never joined.
#
# ⇒ `aimail session [seat]` is the join: one command that walks every place a
#   seat's "am I actually reachable and known-correct" state can silently drift,
#   states EACH one as pass/fail with its own evidence (never a bare label), and
#   prints the exact fix command for anything that failed. It is a REPORT, never
#   an action — it registers nothing and arms nothing itself, matching `resume`'s
#   own philosophy: tell the caller its next commands, do not silently take them,
#   because auto-registering to the wrong seat is worse than asking.
#
# ⚠ FAIL OPEN ON DETECTION, NEVER ON REPORTING. If a check cannot be answered
#   (no jq/python3, a settings file that doesn't parse, an unset seat), say so
#   as UNKNOWN and move to the next check — never let one unreadable file abort
#   the whole report. A diagnostic that can crash itself out of running is the
#   one moment you most need it not to.

_session_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; }

# ─── Walk upward from $PWD for a Claude Code project settings.json ───────────
# WHY UPWARD FROM $PWD AND NOT A FIXED PATH: this library has no notion of
# "the project" — each seat works in a different repo, and a hardcoded path
# would be correct for exactly one deployment. Claude Code itself resolves
# `.claude/settings.json` by walking up from the working directory, so this
# mirrors that resolution rather than inventing a second one that could answer
# differently from the tool actually enforcing the hook.
_session_find_settings() {
  local d="$PWD"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/.claude/settings.json" ]] && { echo "$d/.claude/settings.json"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# ─── Does that settings.json wire a Stop hook to a LOCAL script, and which? ──
# Returns the absolute script path on stdout, or nothing (and a non-zero exit)
# if there is no Stop hook, or it isn't a local `command` hook this hook system
# could plausibly be forked from. A bare `command` string is a shell one-liner,
# usually `bash <path> hook` — extract the path token that ends in `.sh`.
_session_find_stop_hook_script() {
  local settings="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$settings" <<'PY' 2>/dev/null
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(1)
stops = (cfg.get("hooks") or {}).get("Stop") or []
for entry in stops:
    for h in (entry.get("hooks") or []):
        if h.get("type") != "command":
            continue
        cmd = h.get("command") or ""
        m = re.search(r"(\S+\.sh)", cmd)
        if m:
            print(m.group(1))
            sys.exit(0)
sys.exit(1)
PY
}

# ─── Is $sid registered with a given fork script, per THAT script's own view?
# Prefer a CHEAP, targeted verb (`registered <seat> [sid]`) over the fork's
# `status` — measured live: `status` walks EVERY registered session and does a
# full /proc scan per one (30+ seats on this deployment), slow enough to blow
# past a 30s command timeout for a caller that only wants ONE yes/no answer.
# Reading the fork's state file by hand instead was rejected too: a state-dir
# layout is that script's private implementation (AR-21's own warning against
# "two things that can drift" applies here just as much as it did to the
# seat->session mapping itself) — so this only ever ASKS the script.
# Return codes: 0 = registered, 1 = confirmed NOT registered, 2 = could not be
# determined (older/other fork with no `registered` verb — report UNKNOWN,
# never claim "not registered" for a check that was never actually run).
_session_fork_registered() {
  local script="$1" seat="$2" sid="$3"
  [[ -x "$script" || -f "$script" ]] || return 2
  [[ -n "$sid" ]] || return 2
  local out
  out="$(bash "$script" registered "$seat" "$sid" 2>/dev/null)"
  case "$out" in
    yes) return 0 ;;
    no)  return 1 ;;
    *)   return 2 ;;   # unknown verb, or this fork predates it
  esac
}

session_check() {
  local seat="${1:-}"
  local sid; sid="$(_session_sid)"
  local problems=0

  supervisor_alert_banner || true
  info "═══ SESSION CHECK ══════════════════════════════════════════════════"
  echo

  # ── 0. Identity ──────────────────────────────────────────────────────────
  if [[ -z "$sid" ]]; then
    warn "no session id in this environment (CLAUDE_CODE_SESSION_ID unset)"
    warn "every check below that keys off the session id will read UNKNOWN"
    problems=$((problems+1))
  else
    info "session id: $sid"
  fi

  if [[ -z "$seat" ]]; then
    # Reuse the SAME lookup role_whoami already does (stop_guard.sh's own
    # mapping, then AIMAIL_EXTERNAL_SEAT_DIR) rather than a second one.
    if [[ -n "$sid" && -f "$STATE_DIR/stopguard/session.$sid" ]]; then
      seat="$(cat "$STATE_DIR/stopguard/session.$sid")"
      ok "seat: $seat (via stop_guard.sh's own registration)"
    elif [[ -n "${AIMAIL_EXTERNAL_SEAT_DIR:-}" && -n "$sid" && -f "$AIMAIL_EXTERNAL_SEAT_DIR/seat_$sid" ]]; then
      seat="$(cat "$AIMAIL_EXTERNAL_SEAT_DIR/seat_$sid")"
      ok "seat: $seat (via AIMAIL_EXTERNAL_SEAT_DIR)"
    else
      warn "no seat given and no registration found under either mapping"
      warn "  pass one explicitly:  aimail session <seat>"
      warn "  or register first:    bash $AIMAIL_HOME/hooks/stop_guard.sh register <seat>"
      problems=$((problems+1))
    fi
  else
    info "seat: $seat (given explicitly)"
  fi
  echo

  # ── 1. Account / budget mode ─────────────────────────────────────────────
  info "── BUDGET ──"
  if command -v account_id >/dev/null 2>&1; then
    info "  account: $(account_id 2>/dev/null || echo unknown)    cap: $(account_cap 2>/dev/null || echo unknown)%"
    if [[ -f "$MAIL_DIR/_budget_throttled" || -f "${AIMAIL_ROOT}/state/_budget_throttled" ]]; then
      warn "  fleet is currently PARKED under a budget throttle — a dark poller here can be correct"
    fi
  else
    warn "  budget.sh not loaded — sourcing it now to check"
  fi
  echo

  if [[ -n "$seat" ]]; then
    # ── 2. Role handover freshness ─────────────────────────────────────────
    info "── ROLE HANDOVER ($seat) ──"
    local rf; rf="$(ROLE_FILE "$seat" 2>/dev/null)"
    if [[ -n "$rf" && -f "$rf" ]]; then
      local age; age="$(age_min "$(stat -c %Y "$rf")" 2>/dev/null)"
      ok "  handover exists, ${age:-?} min old ($rf)"
    else
      warn "  NO handover on file for '$seat' — a fresh resume of this seat would start blind"
      problems=$((problems+1))
    fi
    echo

    # ── 3. Poller state ─────────────────────────────────────────────────────
    info "── POLLER ($seat) ──"
    if command -v poller_state >/dev/null 2>&1; then
      local state detail; IFS=$'\t' read -r state detail < <(poller_state "$seat" 2>/dev/null)
      case "$state" in
        ARMED)   ok   "  ARMED — $detail" ;;
        PARKED)  ok   "  PARKED — $detail (correctly idle, do not nudge)" ;;
        STALLED) warn "  STALLED — $detail"; problems=$((problems+1)) ;;
        *)       warn "  $state${state:+ — }${detail:-no reading}"; problems=$((problems+1)) ;;
      esac
    else
      warn "  fleet.sh not loaded — cannot read poller state"
      problems=$((problems+1))
    fi
    echo

    # ── 4. stop_guard.sh registration (this repo's own) ─────────────────────
    info "── stop_guard.sh REGISTRATION ──"
    if [[ -n "$sid" && -f "$STATE_DIR/stopguard/session.$sid" ]]; then
      ok "  this session IS registered ($STATE_DIR/stopguard/session.$sid)"
    else
      warn "  this session is NOT registered with stop_guard.sh"
      warn "    fix: bash $AIMAIL_HOME/hooks/stop_guard.sh register $seat"
      problems=$((problems+1))
    fi
    echo

    # ── 5. Project-local Stop hook fork — the exact gap this command exists for ──
    info "── PROJECT-LOCAL STOP HOOK (poller_guard.sh or similar) ──"
    local settings script
    if settings="$(_session_find_settings)"; then
      if script="$(_session_find_stop_hook_script "$settings")"; then
        info "  found: $script  (wired in $settings)"
        if [[ -n "$sid" ]]; then
          _session_fork_registered "$script" "$seat" "$sid"
          case $? in
            0) ok "  this session IS registered with the fork" ;;
            1) warn "  this session is NOT registered with the fork — every Stop it fires"
               warn "  for THIS session is silently allowed through regardless of poller"
               warn "  state (this is the exact gap found live 2026-09-03)."
               warn "    fix: bash $script register $seat"
               problems=$((problems+1)) ;;
            *) warn "  could not determine registration (fork predates the 'registered'"
               warn "  verb, or errored) — register defensively, it is harmless if already done:"
               warn "    bash $script register $seat" ;;
          esac
        else
          warn "  cannot check registration without a session id"
        fi
      else
        info "  a Stop hook is wired in $settings but its command isn't a recognizable"
        info "  local script (nothing to register against beyond stop_guard.sh above)"
      fi
    else
      info "  no project .claude/settings.json found above \$PWD — nothing to check"
    fi
    echo

    # ── 6. Claims held ───────────────────────────────────────────────────────
    # ── 5b. Seat record — the persisted account/session/model confirmation ──
    #   (lib/seatmigrate.sh). A seat that never confirms cannot be relaunched
    #   onto the right account once it is fully dead; a record whose session id
    #   is not THIS session means either a stale boot or a twin — say which.
    info "── SEAT RECORD (aimail seat confirm) ──"
    source "$AIMAIL_LIB/seatmigrate.sh" 2>/dev/null || true
    if command -v seat_record_read >/dev/null 2>&1; then
      local rec_sid rec_acct rec_model cur_acct
      rec_sid="$(seat_record_read "$seat" session_id 2>/dev/null || echo '')"
      rec_acct="$(seat_record_read "$seat" account 2>/dev/null || echo '')"
      rec_model="$(seat_record_read "$seat" model 2>/dev/null || echo '')"
      cur_acct="$(account_id 2>/dev/null || echo unknown)"
      if [[ -z "$rec_sid" ]]; then
        warn "  no seat record for '$seat' — this account/model has never been confirmed"
        warn "    fix: aimail seat confirm $seat --model <the model id in this session's own system prompt>"
        problems=$((problems+1))
      elif [[ -n "$sid" && "$rec_sid" != "$sid" ]]; then
        warn "  record names session ${rec_sid:0:8} on '$rec_acct' (model $rec_model); THIS session is ${sid:0:8} on '$cur_acct'"
        warn "    either a stale boot record or a TWIN of this seat — check: aimail seat locate $seat"
        warn "    then, if this session is the right one: aimail seat confirm $seat --model <id>"
        problems=$((problems+1))
      elif [[ "$rec_acct" != "$cur_acct" ]]; then
        warn "  record says account '$rec_acct' but this shell resolves to '$cur_acct' — re-confirm: aimail seat confirm $seat --model <id>"
        problems=$((problems+1))
      else
        ok "  record matches: session ${sid:0:8} on '$rec_acct', model ${rec_model:-unknown}"
        [[ "$rec_model" == "unknown" || -z "$rec_model" ]] && warn "    model is unknown — aimail seat confirm $seat --model <id> to record it"
      fi
    fi
    echo

    info "── GATECLAIM ──"
    local gc="$AIMAIL_HOME/bin/gateclaim.sh" held
    if [[ -x "$gc" ]]; then
      held="$(bash "$gc" --list 2>/dev/null | awk -v s="$seat" '$2==s')"
      if [[ -n "$held" ]]; then
        info "  held by $seat:"
        printf '%s\n' "$held" | sed 's/^/    /'
      else
        info "  nothing held by $seat"
      fi
    else
      warn "  gateclaim.sh not found at $gc — cannot check"
    fi
    echo
  fi

  # ── ASKS ($seat) ── the ask ledger's own open rows, stale ones flagged
  #   (lib/ask.sh: a task the owner asked for is never silently dropped).
  info "── ASKS ($seat) ──"
  if command -v ask_list >/dev/null 2>&1; then
    local ask_out; ask_out="$(ask_list --owner "$seat" 2>/dev/null)"
    printf '%s\n' "$ask_out" | sed 's/^/  /'
    local ask_stale_n; ask_stale_n="$(printf '%s\n' "$ask_out" | grep -c ' STALE ' || true)"
    (( ask_stale_n > 0 )) && problems=$((problems+ask_stale_n))
  else
    warn "  lib/ask.sh not loadable — cannot check"
  fi
  echo

  # ── 7. Landing guard — installed AND resolvable in every repo it protects? ──
  #   (lib/landingguard.sh; t908, 2026-09-22: a hooksPath into a vanished location ran
  #   no hooks for 26 h with zero signal. Seat-independent — checked for every session.)
  info "── LANDING GUARD (reference-transaction, per configured repo) ──"
  source "$AIMAIL_LIB/landingguard.sh" 2>/dev/null || true
  if command -v landing_guard_report >/dev/null 2>&1; then
    landing_guard_report; local lg_problems=$?
    problems=$((problems+lg_problems))
  else
    warn "  landingguard.sh not loadable — cannot check"
  fi
  echo

  # ── 7b. Pre-push sterility guard — installed AND resolvable? ──
  #   (lib/pushguard.sh; 2026-09-24: the guard itself can be a real, tracked, falsified
  #   file and still not be live in the checkout that actually pushes — same silent-gap
  #   shape as the landing guard above, one line down here for the same reason.)
  info "── PRE-PUSH STERILITY GUARD (per configured repo) ──"
  source "$AIMAIL_LIB/pushguard.sh" 2>/dev/null || true
  if command -v push_guard_report >/dev/null 2>&1; then
    push_guard_report; local pg_problems=$?
    problems=$((problems+pg_problems))
  else
    warn "  pushguard.sh not loadable — cannot check"
  fi
  echo

  # ── 7c. Commit-msg sterility guard — installed AND resolvable? ──
  #   (2026-09-24: a2fa1dc's first cut shipped this hook without its executable bit,
  #   so git silently skipped it once installed — reachable but never actually fires,
  #   the exact gap 7b already exists to catch for pre-push.)
  info "── COMMIT-MSG STERILITY GUARD (per configured repo) ──"
  if command -v commit_msg_guard_report >/dev/null 2>&1; then
    commit_msg_guard_report; local cmg_problems=$?
    problems=$((problems+cmg_problems))
  else
    warn "  pushguard.sh not loadable — cannot check"
  fi
  echo

  # ── Summary ────────────────────────────────────────────────────────────
  info "── SUMMARY ──"
  if (( problems == 0 )); then
    ok "0 problems found — this session is registered, armed, and known-current"
  else
    warn "$problems problem(s) found above — each has its own fix command printed inline"
    warn "run this again after fixing them; do not assume one fix cleared the rest"
  fi
  return $(( problems > 0 ? 1 : 0 ))
}

# ─── session_selftest — the helper functions in isolation, against fixtures ──
# WHY THESE ARMS: the two functions with real logic to get wrong are the
# upward directory walk (wrong direction or wrong stop condition silently
# finds nothing, or finds the wrong file) and the JSON extraction (a Stop hook
# wired to something other than a local script must NOT be reported as one).
# `_session_fork_registered`'s three-way return (yes/no/unknown) is the exact
# distinction that matters for not false-alarming on a fork that predates the
# `registered` verb — tested against a fixture script that stands in for one.
session_selftest() {
  local t; t="$(mktemp -d)"
  local pass=0 fail=0
  _t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }

  echo "session.sh selftest (fixtures under $t)"

  # ── _session_find_settings: upward walk ──────────────────────────────────
  mkdir -p "$t/proj/.claude"
  echo '{}' > "$t/proj/.claude/settings.json"
  mkdir -p "$t/proj/deep/nested/dir"
  local got
  got="$(cd "$t/proj/deep/nested/dir" && _session_find_settings)"
  _t "find_settings: found from 3 levels down" "$got" "$t/proj/.claude/settings.json"

  got="$(cd "$t" && _session_find_settings)"
  _t "find_settings: none above a dir with no .claude -> empty" "$got" ""

  # ── _session_find_stop_hook_script: JSON extraction ──────────────────────
  cat > "$t/proj/.claude/settings.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /some/path/poller_guard.sh hook"}]}]}}
JSON
  got="$(_session_find_stop_hook_script "$t/proj/.claude/settings.json")"
  _t "find_stop_hook_script: extracts the .sh path" "$got" "/some/path/poller_guard.sh"

  echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo not a script"}]}]}}' \
    > "$t/proj/.claude/settings.json"
  got="$(_session_find_stop_hook_script "$t/proj/.claude/settings.json" 2>/dev/null)"
  _t "find_stop_hook_script: no .sh token -> empty, not a guess" "$got" ""

  echo '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash x.sh"}]}]}}' \
    > "$t/proj/.claude/settings.json"
  got="$(_session_find_stop_hook_script "$t/proj/.claude/settings.json" 2>/dev/null)"
  _t "find_stop_hook_script: hook on a DIFFERENT event -> not reported as Stop" "$got" ""

  echo 'not json at all' > "$t/proj/.claude/settings.json"
  got="$(_session_find_stop_hook_script "$t/proj/.claude/settings.json" 2>/dev/null)"
  _t "find_stop_hook_script: malformed json -> empty, not a crash" "$got" ""

  # ── _session_fork_registered: the three-way return ───────────────────────
  cat > "$t/fake_fork.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  registered)
    [ "$2" = "realseat" ] && [ "$3" = "realsid" ] && { echo yes; exit 0; }
    [ -n "$3" ] && { echo no; exit 1; }
    echo "unknown"; exit 2 ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$t/fake_fork.sh"

  _session_fork_registered "$t/fake_fork.sh" realseat realsid
  _t "fork_registered: matching seat+sid -> rc 0" "$?" "0"

  _session_fork_registered "$t/fake_fork.sh" wrongseat realsid
  _t "fork_registered: known sid, wrong seat -> rc 1" "$?" "1"

  _session_fork_registered "$t/fake_fork.sh" realseat ""
  _t "fork_registered: no sid given -> rc 2 (unknown, not a false 'no')" "$?" "2"

  cat > "$t/no_registered_verb.sh" <<'SH'
#!/usr/bin/env bash
echo "usage: ..." >&2; exit 64
SH
  chmod +x "$t/no_registered_verb.sh"
  _session_fork_registered "$t/no_registered_verb.sh" realseat realsid
  _t "fork_registered: fork predates the verb -> rc 2, not rc 1" "$?" "2"

  _session_fork_registered "$t/does-not-exist.sh" realseat realsid
  _t "fork_registered: script missing entirely -> rc 2" "$?" "2"

  rm -rf "$t"
  echo "  ---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
