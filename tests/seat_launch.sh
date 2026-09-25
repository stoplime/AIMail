#!/usr/bin/env bash
# tests/seat_launch.sh — `aimail seat launch <seat> <account>` (lib/seatmigrate.sh:seat_launch),
# 2026-09-24.
#
# WHY: a fresh seat launch was hand-typed every time (cd, CLAUDE_CONFIG_DIR, claude --bg
# --model ... --allow-dangerously-skip-permissions --permission-mode bypassPermissions,
# --remote-control for the supervisor, a boot prompt), and the boot steps depended on the
# seat remembering them. This proves the wrapper: shares its flag-builder with seat migrate's
# own (no second copy), refuses rather than guesses on a missing model/cwd, refuses a target
# account with no autoCompactWindow configured, refuses a FRESH launch while the seat is live
# ANYWHERE already (idle counts as live -- 2026-09-24's twin incident), canonicalizes a model
# alias to its full id rather than carrying two spellings, supports --dry-run for the
# dispatcher's advisory mode, and records the new session.
#
# EVIDENCE RULES (tests/run.sh ①-⑤): every refusal arm has an accepting control of the same
# shape; exit codes are captured out of pipes; the denominator is printed. The CLI is a
# stand-in script behind AIMAIL_CLAUDE_BIN — no real `claude`, no network.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
AIMAIL="$REPO/bin/aimail"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-seatlaunch-test.XXXXXX")"
export AIMAIL_CONFIG=/dev/null AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
# shellcheck source=./lib_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_env.sh"; test_env_sanitize
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR

ACCT_A="$AIMAIL_ROOT/acct-a"
ACCT_B="$AIMAIL_ROOT/acct-b"
mkdir -p "$ACCT_A" "$ACCT_B"
export AIMAIL_ACCOUNT_DIR_alpha="$ACCT_A"
export AIMAIL_ACCOUNT_DIR_beta="$ACCT_B"
export AIMAIL_FLEET_ACCOUNTS="alpha beta"

# ── the stand-in `claude` — --bg with no --resume always mints a fresh sid ──────────────────
FAKE="$AIMAIL_ROOT/fakebin"; mkdir -p "$FAKE"
CALLS="$AIMAIL_ROOT/claude_calls.log"; : > "$CALLS"
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
set -u
DIR="${CLAUDE_CONFIG_DIR:?}"
LOG="${FAKE_CALLS:?}"
printf 'cwd=%s cfg=%s argv=%s\n' "$PWD" "$DIR" "$*" >> "$LOG"
add_row() { # <dir> <sid> [state]
  python3 - "$1/agents.json" "$2" "${3:-working}" <<'PY'
import json, sys, os
p, sid, state = sys.argv[1], sys.argv[2], sys.argv[3]
rows = json.load(open(p)) if os.path.exists(p) else []
rows.append({"sessionId": sid, "id": sid[:8], "pid": 4242, "state": state, "status": "busy",
             "cwd": os.getcwd(), "name": "fake", "kind": "background"})
json.dump(rows, open(p, "w"))
PY
}
write_job() { mkdir -p "$1/jobs/${2:0:8}"; printf '{"state":"%s","detail":"%s"}' "$3" "$4" > "$1/jobs/${2:0:8}/state.json"; }
case "${1:-}" in
  agents) [[ -f "$DIR/agents.json" ]] && cat "$DIR/agents.json" || echo '[]' ;;
  --bg)
    [[ -f "$DIR/.launch_fails" ]] && { echo "launch refused: quota" >&2; exit 1; }
    sid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
    if [[ -f "$DIR/.job_failed" ]]; then
      write_job "$DIR" "$sid" failed "quota exceeded"; add_row "$DIR" "$sid" failed
    else
      add_row "$DIR" "$sid" working; write_job "$DIR" "$sid" working "fresh"
    fi
    echo "started background session ${sid:0:8}" ;;
  *) echo "fake claude: unknown verb $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE/claude"
export AIMAIL_CLAUDE_BIN="$FAKE/claude" FAKE_CALLS="$CALLS"
export AIMAIL_LAUNCH_POLL_S=0 AIMAIL_LAUNCH_TIMEOUT=2

source "$REPO/lib/core.sh"
source "$REPO/lib/registry.sh"
source "$REPO/lib/fleet.sh"
source "$REPO/lib/budget.sh"
source "$REPO/lib/mail.sh"
source "$REPO/lib/seatmigrate.sh"
ensure_dirs
"$AIMAIL" seat add seat-a "test seat" >/dev/null 2>&1
"$AIMAIL" seat add super "test supervisor" >/dev/null 2>&1

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
chk_contains(){ case "$2" in *"$3"*) chk "$1" 1 1 ;; *) chk "$1" "MISSING[$3]" 1 ;; esac; }
cleanup(){ rm -rf "$AIMAIL_ROOT"; }
trap cleanup EXIT

write_settings() { # <dir> [autoCompactWindow value, omit for none]
  if [[ $# -ge 2 ]]; then printf '{"autoCompactWindow": %s}\n' "$2" > "$1/settings.json"
  else rm -f "$1/settings.json"; fi
}
add_live_row() { # <dir> <sid> [state]
  python3 - "$1/agents.json" "$2" "${3:-working}" <<'PY'
import json, sys, os
p, sid, state = sys.argv[1], sys.argv[2], sys.argv[3]
rows = json.load(open(p)) if os.path.exists(p) else []
rows.append({"sessionId": sid, "id": sid[:8], "pid": 9999, "state": state, "status": "busy",
             "cwd": "/tmp", "name": "fake", "kind": "background"})
json.dump(rows, open(p, "w"))
PY
}
reset_state() {
  rm -rf "$(SEAT_RECORD_DIR)" "$ACCT_A/agents.json" "$ACCT_A/jobs" "$ACCT_A/.launch_fails" "$ACCT_A/.job_failed" \
         "$ACCT_B/agents.json" "$ACCT_B/jobs" "$ACCT_B/.launch_fails" "$ACCT_B/.job_failed"
  : > "$CALLS"
}

printf '\n═══ 1. usage + missing model/cwd, never guessed ═══\n'
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch 2>&1)"; rc=$?
chk "no args → REFUSED" "$rc" 3
out="$("$AIMAIL" seat launch seat-a 2>&1)"; rc=$?
chk "missing target account → REFUSED" "$rc" 3
out="$("$AIMAIL" seat launch seat-a alpha 2>&1)"; rc=$?
chk "no --model, no record → REFUSED (never guessed)" "$rc" 3
chk_contains "…names the fix" "$out" "--model"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet 2>&1)"; rc=$?
chk "--model given but no --cwd, no record → REFUSED" "$rc" 3
chk_contains "…names the fix" "$out" "--cwd"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0

printf '\n═══ 2. autoCompactWindow gate — a per-account setting, checked here ═══\n'
reset_state; write_settings "$ACCT_A"   # no autoCompactWindow
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "no autoCompactWindow on the target → REFUSED" "$rc" 3
chk_contains "…names autoCompactWindow" "$out" "autoCompactWindow"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
out="$(AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT=0 "$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "…AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT=0 downgrades to a warn and launches" "$rc" 0
chk_contains "…says so loudly" "$out" "launching anyway"
chk "…did launch" "$(grep -c 'argv=--bg' "$CALLS")" 1

printf '\n═══ 3. a real launch: flags, boot prompt, record written ═══\n'
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "succeeds" "$rc" 0
chk "…exactly one launch" "$(grep -c 'argv=--bg' "$CALLS")" 1
chk_contains "…the standard boot sequence in the prompt" "$(cat "$CALLS")" "aimail session"
chk_contains "…and the poller step" "$(cat "$CALLS")" "arm your poller"
chk "…record: account" "$(seat_record_read seat-a account)" "alpha"
chk "…record: model" "$(seat_record_read seat-a model)" "claude-sonnet-5"
chk "…record: cwd" "$(seat_record_read seat-a cwd)" "$AIMAIL_ROOT"
chk "…record: launch_path" "$(seat_record_read seat-a launch_path)" "launch"
chk "…an ordinary seat gets no --remote-control" "$(grep -c -- '--remote-control' "$CALLS")" 0

printf '\n═══ 4. the supervisor gets --remote-control; a non-supervisor never does ═══\n'
reset_state; write_settings "$ACCT_A" 500000
export AIMAIL_SUPERVISOR=super
out="$("$AIMAIL" seat launch super alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "supervisor launch succeeds" "$rc" 0
chk_contains "…carries --remote-control named after the seat" "$(cat "$CALLS")" "--remote-control super"
unset AIMAIL_SUPERVISOR

printf '\n═══ 5. defaults come from the seat'"'"'s own record when the flags are omitted ═══\n'
reset_state; write_settings "$ACCT_A" 500000
seat_record_write seat-a alpha "$ACCT_A" "aaaaaaaa-0000-0000-0000-000000000000" sonnet tester "" "" "$AIMAIL_ROOT/priordir"
mkdir -p "$AIMAIL_ROOT/priordir"
out="$("$AIMAIL" seat launch seat-a alpha 2>&1)"; rc=$?
chk "no --model/--cwd, but the record has both → succeeds" "$rc" 0
chk_contains "…used the record's model, canonicalized" "$(cat "$CALLS")" "--model claude-sonnet-5"
chk "…used the record's cwd" "$(grep -c "cwd=$AIMAIL_ROOT/priordir" "$CALLS")" 1

printf '\n═══ 6. a bad --cwd, and a scheduler-side launch failure, are both real refusals ═══\n'
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT/does-not-exist" 2>&1)"; rc=$?
chk "nonexistent --cwd → REFUSED" "$rc" 3
touch "$ACCT_A/.job_failed"
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "scheduler reports the job failed → REFUSED, names the reason" "$rc" 3
chk_contains "…quotes the scheduler's own detail" "$out" "quota exceeded"
rm -f "$ACCT_A/.job_failed"

printf '\n═══ 7. twin/liveness guard — a FRESH launch is refused while the seat is live anywhere ═══\n'
# seat_session_locate matches candidates (the seat's OWN record/instance sid) against the live
# listing -- it does not key off the agents.json "name" field. So "already live elsewhere" is
# simulated the way it happens for real: a seat record naming a session, and that same session
# still showing up live in the target's agents.json.
reset_state; write_settings "$ACCT_A" 500000; write_settings "$ACCT_B" 500000
seat_record_write seat-a beta "$ACCT_B" "bbbbbbbb-1111-1111-1111-111111111111" sonnet tester "" "" "$AIMAIL_ROOT/other"
add_live_row "$ACCT_B" "bbbbbbbb-1111-1111-1111-111111111111" working
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "already live on ANOTHER account → REFUSED" "$rc" 3
chk_contains "…names the account it's live on" "$out" "acct-b"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
# accepting control: once that live row is gone (session ended), the identical launch succeeds
rm -f "$ACCT_B/agents.json"
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "…once the live row is gone, the identical launch succeeds" "$rc" 0
chk "…did launch" "$(grep -c 'argv=--bg' "$CALLS")" 1
# an IDLE row counts as live too, not just working/busy
reset_state; write_settings "$ACCT_A" 500000; write_settings "$ACCT_B" 500000
seat_record_write seat-a beta "$ACCT_B" "cccccccc-2222-2222-2222-222222222222" sonnet tester "" "" "$AIMAIL_ROOT/other"
add_live_row "$ACCT_B" "cccccccc-2222-2222-2222-222222222222" idle
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "an IDLE row on another account → REFUSED too (idle counts as live)" "$rc" 3
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0

printf '\n═══ 8. --dry-run prints the resolved command and launches nothing ═══\n'
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" --dry-run 2>&1)"; rc=$?
chk "--dry-run exits 0" "$rc" 0
chk_contains "…says dry-run" "$out" "dry-run"
chk_contains "…names the resolved model" "$out" "claude-sonnet-5"
chk_contains "…names the resolved account" "$out" "alpha"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
# accepting control: the identical command without --dry-run really launches
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "…the identical command without --dry-run really launches" "$rc" 0
chk "…did launch" "$(grep -c 'argv=--bg' "$CALLS")" 1
# a refusal still surfaces under --dry-run (checks run before the dry-run short-circuit)
reset_state; write_settings "$ACCT_A"   # no autoCompactWindow
out="$("$AIMAIL" seat launch seat-a alpha --model sonnet --cwd "$AIMAIL_ROOT" --dry-run 2>&1)"; rc=$?
chk "…a real refusal still fires under --dry-run (it shows what WOULD happen)" "$rc" 3

printf '\n═══ 9. model alias canonicalization — one spelling, never guessed ═══\n'
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model opus --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "a known alias (opus) launches" "$rc" 0
chk_contains "…resolved to its full id" "$(cat "$CALLS")" "--model claude-opus-5-5"
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model claude-fable-5-1 --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "an already-full id (fable) launches unchanged" "$rc" 0
chk_contains "…carries the same full id" "$(cat "$CALLS")" "--model claude-fable-5-1"
reset_state; write_settings "$ACCT_A" 500000
out="$("$AIMAIL" seat launch seat-a alpha --model nonexistent-tier --cwd "$AIMAIL_ROOT" 2>&1)"; rc=$?
chk "an unrecognized model spelling → REFUSED, never guessed" "$rc" 3
chk_contains "…lists the known full ids" "$out" "claude-sonnet-5"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0

printf '\n────────────────────────────────────────────────────────────\n'
printf '═══ %d/%d passed ═══\n' "$PASS" "$((PASS+FAIL))"
if (( FAIL )); then printf 'FAILED:\n'; for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done; exit 1; fi
