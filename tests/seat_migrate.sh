#!/usr/bin/env bash
# tests/seat_migrate.sh — the persisted seat record, cross-account session lookup,
# and `aimail seat migrate` (lib/seatmigrate.sh), 2026-09-21.
#
# WHY: a seat was moved between accounts by `kill <pid>` + relaunch. The CLI's
# background-job scheduler respawned the killed job from its ORIGINAL launch spec
# (account, model), so the seat ran twice under one session id on two accounts,
# one of them on the wrong model. This file proves the tool: locates by the
# scheduler's own listing, refuses on twins/UNKNOWN, stops with `claude stop`
# and refuses to relaunch until the id is verifiably gone, relaunches with an
# explicit model and the same session id, and CATCHES a respawn during the
# settle window instead of confirming from the first sighting.
#
# EVIDENCE RULES (tests/run.sh ①-⑤): every refusal arm has an accepting control
# of the same shape; the arm is shown firing first; exit codes are captured out
# of pipes; the denominator is printed. The CLI is a stand-in script behind
# AIMAIL_CLAUDE_BIN — no real `claude`, no real session, no network. AIMAIL_ROOT
# is a temp dir; the fake account dirs live inside it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
AIMAIL="$REPO/bin/aimail"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-seatmig-test.XXXXXX")"
export AIMAIL_CONFIG=/dev/null AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
# the operator's shell is not part of the fixture -- scrub inherited AIMAIL_* BEFORE this suite's own exports below (tests/lib_env.sh)
# shellcheck source=./lib_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_env.sh"; test_env_sanitize
export AIMAIL_MIGRATE_POLL_S=0 AIMAIL_MIGRATE_SETTLE=0 AIMAIL_MIGRATE_HANDOVER_WAIT=0
export AIMAIL_MIGRATE_STOP_TIMEOUT=0 AIMAIL_MIGRATE_LAUNCH_TIMEOUT=0
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR

# two fake accounts, resolved through budget.sh's own override idiom
ACCT_A="$AIMAIL_ROOT/acct-a"; ACCT_B="$AIMAIL_ROOT/acct-b"
mkdir -p "$ACCT_A" "$ACCT_B"
export AIMAIL_ACCOUNT_DIR_alpha="$ACCT_A" AIMAIL_ACCOUNT_DIR_beta="$ACCT_B"
export AIMAIL_FLEET_ACCOUNTS="alpha beta"

# ── the stand-in `claude` ────────────────────────────────────────────────────
# agents --json  → cat $CLAUDE_CONFIG_DIR/agents.json (or fail if .no_answer exists)
# stop <id>      → log; unless .stop_fails exists, drop that row from agents.json
# --bg …         → log argv + cwd + config dir; add a row for the --resume sid to
#                  agents.json; if .respawn_into names another dir, add it there too
#                  (the scheduler respawn signature)
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
rows = [r for r in rows if r.get("sessionId") != sid]
rows.append({"sessionId": sid, "id": sid[:8], "pid": (None if state == "failed" else 4242), "state": state,
             "status": ("failed" if state == "failed" else "busy"),
             "cwd": os.getcwd(), "name": "fake", "kind": "background"})
json.dump(rows, open(p, "w"))
PY
}
write_job() { # <dir> <sid> <state> <detail>
  mkdir -p "$1/jobs/${2:0:8}"
  printf '{"state":"%s","detail":"%s","sessionId":"%s","template":"bg"}' "$3" "$4" "$2" > "$1/jobs/${2:0:8}/state.json"
}
has_transcript() { # <dir> <sid> — a transcript with a real turn under any projects/<slug>/
  local f; for f in "$1"/projects/*/"$2.jsonl"; do [[ -f "$f" ]] && grep -q '"type":"user"' "$f" && return 0; done; return 1
}
case "${1:-}" in
  agents)
    [[ -f "$DIR/.no_answer" ]] && exit 1
    [[ -f "$DIR/agents.json" ]] && cat "$DIR/agents.json" || echo '[]' ;;
  stop)
    [[ -f "$DIR/.stop_fails" ]] && exit 0
    python3 - "$DIR/agents.json" "$2" <<'PY'
import json, sys, os
p, short = sys.argv[1], sys.argv[2]
rows = json.load(open(p)) if os.path.exists(p) else []
json.dump([r for r in rows if r.get("id") != short and not r.get("sessionId","").startswith(short)], open(p, "w"))
PY
    echo "stopped $2" ;;
  --bg)
    sid=""; flagged=0; shift
    while (( $# )); do [[ "$1" == "--resume" ]] && sid="$2"; [[ "$1" == "--model" ]] && flagged=1; shift; done
    if [[ -z "$sid" ]]; then
      # a FRESH launch: the real CLI mints a new session id and prints its short form
      sid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
      add_row "$DIR" "$sid"; write_job "$DIR" "$sid" working "fresh"
      echo "started background session ${sid:0:8}"; exit 0
    fi
    # the real CLI (2026-09-23 00:25): a session can be alive and copying while `agents` does NOT list
    # it at all -- .copy_unlisted models that shape
    if [[ -f "$DIR/.copy_unlisted" ]]; then
      copy="c1c1c1c1-${sid:9}"; add_row "$DIR" "$copy"
      echo "note: session $sid is already running in the background, so this started a copy as $copy. \`claude attach ${sid:0:8}\` opens the original."; exit 0
    fi
    # the real CLI (2026-09-22 18:28): a session RUNNING here (blocked/working) copies -- "already
    # running in the background"; `stop` removes the row and the next resume continues it
    if python3 - "$DIR/agents.json" "$sid" <<'PY'
import json, sys, os
p, sid = sys.argv[1], sys.argv[2]
rows = json.load(open(p)) if os.path.exists(p) else []
sys.exit(0 if any(r.get("sessionId")==sid and r.get("state") in ("blocked","working") for r in rows) else 1)
PY
    then
      copy="c1c1c1c1-${sid:9}"; add_row "$DIR" "$copy"
      echo "note: session $sid is already running in the background, so this started a copy as $copy. \`claude attach ${sid:0:8}\` opens the original."; exit 0
    fi
    # the real CLI (2026-09-22): --resume needs the TRANSCRIPT under THIS config dir's projects/;
    # without one the job is recorded `failed: source session <sid> not found` and a failed row shows
    if [[ -f "$DIR/.fail_resume" ]] || ! has_transcript "$DIR" "$sid"; then
      write_job "$DIR" "$sid" failed "source session $sid not found"; add_row "$DIR" "$sid" failed
      echo "${sid:0:8}"; exit 0
    fi
    # the real CLI: saved launch options + flags => a COPY under a new id, warned in stdout only
    if (( flagged )) && [[ -f "$DIR/jobs/${sid:0:8}/state.json" ]]; then
      copy="c0c0c0c0-${sid:9}"; add_row "$DIR" "$copy"
      echo "background session $sid keeps its own saved options, so the flags you passed started a copy as $copy. Without flags, the same command continues $sid itself."
      exit 0
    fi
    [[ -f "$DIR/.launch_noop" ]] || { add_row "$DIR" "$sid"; write_job "$DIR" "$sid" working "resumed"; }
    if [[ -f "$DIR/.respawn_into" ]]; then add_row "$(cat "$DIR/.respawn_into")" "$sid"; fi
    if [[ -f "$DIR/.blackout_other" ]]; then touch "$(cat "$DIR/.blackout_other")/.no_answer"; fi   # another account goes silent AFTER the launch (during settle)
    echo "${sid:0:8}" ;;
  *) echo "fake claude: unknown verb $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE/claude"
export AIMAIL_CLAUDE_BIN="$FAKE/claude" FAKE_CALLS="$CALLS"

# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/registry.sh
source "$REPO/lib/registry.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"
# shellcheck source=../lib/budget.sh
source "$REPO/lib/budget.sh"
# shellcheck source=../lib/mail.sh
source "$REPO/lib/mail.sh"
# shellcheck source=../lib/seatmigrate.sh
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

SID="aaaaaaaa-1111-2222-3333-444444444444"
SHORT="${SID:0:8}"
write_agents() { # <dir> [sid …]
  local d="$1"; shift; python3 - "$d/agents.json" "$@" <<'PY'
import json, sys, os
p = sys.argv[1]; rows = []
for sid in sys.argv[2:]:
    rows.append({"sessionId": sid, "id": sid[:8], "pid": 4242, "state": "working", "status": "busy",
                 "cwd": os.environ.get("TEST_CWD", "/tmp"), "name": "fake", "kind": "background"})
json.dump(rows, open(p, "w"))
PY
}
write_instance() { # <seat> <sid> <account> [pid]
  local d; d="$(INSTANCE_DIR "$1")"; mkdir -p "$d"
  { printf 'sid\t%s\naccount\t%s\nhost\ttest\npid\t%s\narmed_at\t%s\nlast_beat\t%s\n' "$2" "$3" "${4:-1}" "$(now_epoch)" "$(now_epoch)"; } > "$d/$2"
}
SLUG="$(printf '%s' "$AIMAIL_ROOT" | sed 's#[/.]#-#g')"   # the CLI's projects/<cwd-slug>, TEST_CWD = $AIMAIL_ROOT
seed_transcript() { # <dir> <sid> [slug] — a transcript with one real turn, plus its sidecar dir
  local d="$1/projects/${3:-$SLUG}"; mkdir -p "$d/$2"
  printf '{"type":"custom-title","customTitle":"t","sessionId":"%s"}\n{"type":"user","message":"hi","sessionId":"%s"}\n{"type":"assistant","message":"ok","sessionId":"%s"}\n' "$2" "$2" "$2" > "$d/$2.jsonl"
  printf 'sub\n' > "$d/$2/agent-1.jsonl"
}
seed_stub() { # <dir> <sid> — what a FAILED resume leaves behind: titles, no conversation
  local d="$1/projects/$SLUG"; mkdir -p "$d"
  printf '{"type":"last-prompt","lastPrompt":"x","sessionId":"%s"}\n{"type":"custom-title","customTitle":"t","sessionId":"%s"}\n' "$2" "$2" > "$d/$2.jsonl"
}
reset_state() {
  rm -rf "$(INSTANCE_DIR seat-a)" "$(SEAT_RECORD_DIR)" "$(SEAT_SESSIONS_DIR)" "$ACCT_A"/.stop_fails "$ACCT_A"/.no_answer "$ACCT_B"/.no_answer \
         "$ACCT_B"/.launch_noop "$ACCT_B"/.respawn_into "$ACCT_B"/.blackout_other "$ACCT_B"/.fail_resume \
         "$ACCT_A"/jobs "$ACCT_A"/projects "$ACCT_B"/jobs "$ACCT_B"/projects
  write_agents "$ACCT_A"; write_agents "$ACCT_B"; : > "$CALLS"
  seed_transcript "$ACCT_A" "$SID"    # the session's real history lives on the SOURCE account
}
export TEST_CWD="$AIMAIL_ROOT"

# ═══ 1. seat confirm — the record from inside a session ══════════════════════
printf '\n═══ 1. seat confirm ═══\n'
reset_state
out="$(CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a --model model-x 2>&1)"; rc=$?
chk "confirm without a session id REFUSES (exit 3)" "$rc" 3
chk_contains "…and says why" "$out" "CLAUDE_CODE_SESSION_ID is not set"
out="$(CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a --model model-x 2>&1)"; rc=$?
chk "confirm with sid+config dir+model succeeds" "$rc" 0
chk "record: account = alpha (from the config dir)" "$(seat_record_read seat-a account)" "acct-a"
chk "record: session_id" "$(seat_record_read seat-a session_id)" "$SID"
chk "record: model as given" "$(seat_record_read seat-a model)" "model-x"
chk "record: confirmed_by boot" "$(seat_record_read seat-a confirmed_by)" "boot"
# model detection from the launch spec when --model is omitted
mkdir -p "$ACCT_A/jobs/$SHORT"
printf '{"respawnFlags":["--permission-mode","bypassPermissions","--model","model-from-spec"],"template":"bg"}' > "$ACCT_A/jobs/$SHORT/state.json"
CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a >/dev/null 2>&1
chk "confirm without --model reads the launch spec's --model" "$(seat_record_read seat-a model)" "model-from-spec"
rm -rf "$ACCT_A/jobs"; mkdir -p "$ACCT_A/projects/proj"
printf '{"model":"old"}\n{"x":1,"model":"model-from-transcript"}\n' > "$ACCT_A/projects/proj/$SID.jsonl"
CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a >/dev/null 2>&1
chk "…else the transcript's LAST model field" "$(seat_record_read seat-a model)" "model-from-transcript"
rm -rf "$ACCT_A/projects"
out="$(CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a 2>&1)"
chk "…else 'unknown', with a warning (never a default)" "$(seat_record_read seat-a model)" "unknown"
chk_contains "…the warning names the fix" "$out" "--model"
out="$("$AIMAIL" seat record seat-a 2>&1)"; rc=$?
chk "seat record prints the file" "$rc" 0
chk_contains "…with the session id" "$out" "$SID"
out="$("$AIMAIL" seat records 2>&1)"
chk_contains "seat records lists the seat" "$out" "seat-a"
out="$("$AIMAIL" seat record nobody-here 2>&1)"; rc=$?
chk "seat record for an unconfirmed seat exits 1" "$rc" 1

# ═══ 2. seat locate — by the scheduler's listing ═════════════════════════════
printf '\n═══ 2. seat locate ═══\n'
reset_state
out="$("$AIMAIL" seat locate seat-a 2>&1)"; rc=$?
chk "nothing anywhere → REFUSED (exit 3 via refused)" "$rc" 3
write_instance seat-a "$SID" acct-a
write_agents "$ACCT_A" "$SID"
out="$(seat_session_locate seat-a)"; rc=$?
chk "instance + live listing on A → located (exit 0)" "$rc" 0
chk "…liveness live" "$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$out")" "live"
chk "…account from the listing's config dir" "$(awk -F'\t' '$1=="account"{print $2}' <<<"$out")" "acct-a"
chk "…source agents" "$(awk -F'\t' '$1=="source"{print $2}' <<<"$out")" "agents"
write_agents "$ACCT_A"
out="$(seat_session_locate seat-a)"; rc=$?
chk "instance but NOT listed anywhere, no record → exit 1" "$rc" 1
seat_record_write seat-a acct-a "$ACCT_A" "$SID" model-x boot "" "" "$TEST_CWD"
out="$(seat_session_locate seat-a)"; rc=$?
chk "…with a record → dead-with-record (exit 0)" "$rc" 0
chk "…liveness dead" "$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$out")" "dead"
chk "…source record" "$(awk -F'\t' '$1=="source"{print $2}' <<<"$out")" "record"
touch "$ACCT_B/.no_answer"
out="$(seat_session_locate seat-a)"; rc=$?
chk "an account that does not answer → UNKNOWN (exit 2), never 'dead'" "$rc" 2
rm -f "$ACCT_B/.no_answer"
write_agents "$ACCT_A" "$SID"; write_agents "$ACCT_B" "$SID"
out="$(seat_session_locate seat-a)"; rc=$?
chk "same sid live on A and B → TWINS (exit 3)" "$rc" 3
chk "…two twin lines" "$(grep -c '^twin' <<<"$out")" 2
out="$("$AIMAIL" seat locate seat-a 2>&1)"; rc=$?
chk "CLI: twins REFUSED" "$rc" 3
chk_contains "…naming twins" "$out" "twins"

# ═══ 3. seat migrate — refusals first (the arm firing) ═══════════════════════
printf '\n═══ 3. seat migrate — refusals ═══\n'
reset_state
out="$("$AIMAIL" seat migrate seat-a gamma --from super 2>&1)"; rc=$?
chk "unknown target account REFUSED" "$rc" 3
chk_contains "…names the pool" "$out" "alpha beta"
out="$("$AIMAIL" seat migrate seat-a beta --from super 2>&1)"; rc=$?
chk "no session anywhere REFUSED" "$rc" 3
chk_contains "…suggests --sid" "$out" "--sid"
write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; write_agents "$ACCT_B" "$SID"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "twins REFUSED before anything runs" "$rc" 3
chk "…and claude stop was NOT called" "$(grep -c 'argv=stop' "$CALLS")" 0
write_agents "$ACCT_B"
out="$("$AIMAIL" seat migrate seat-a alpha --from super --model m 2>&1)"; rc=$?
chk "already live on the target REFUSED" "$rc" 3
out="$("$AIMAIL" seat migrate seat-a beta --from super 2>&1)"; rc=$?
chk "no model known anywhere REFUSED (never defaulted)" "$rc" 3
chk_contains "…says to pass --model" "$out" "--model"
touch "$ACCT_B/.no_answer"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "listing UNKNOWN REFUSED" "$rc" 3
rm -f "$ACCT_B/.no_answer"
# stop that does not take → no relaunch
touch "$ACCT_A/.stop_fails"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "stop issued but id still listed → REFUSED" "$rc" 3
chk "…claude stop WAS called (the arm ran)" "$(grep -c 'argv=stop' "$CALLS")" 1
chk "…and no relaunch happened" "$(grep -c 'argv=--bg' "$CALLS")" 0
rm -f "$ACCT_A/.stop_fails"
# relaunch that never registers on the target
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; touch "$ACCT_B/.launch_noop"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "relaunched but never listed on the target → REFUSED" "$rc" 3
chk_contains "…says not listed" "$out" "NOT listed"
chk "…no record written on failure" "$([[ -f "$(SEAT_RECORD_FILE seat-a)" ]] && echo yes || echo no)" "no"
# the respawn signature during settle
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; printf '%s' "$ACCT_A" > "$ACCT_B/.respawn_into"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "RESPAWN on the old account during settle → REFUSED (twins), not confirmed" "$rc" 3
chk_contains "…names the respawn" "$out" "respawn"
chk_contains "…prints the stop for the wrong one" "$out" "claude stop $SHORT"
chk "…no record written" "$([[ -f "$(SEAT_RECORD_FILE seat-a)" ]] && echo yes || echo no)" "no"

# an account that goes SILENT during the settle window (code-review's finding on 7d81a09)
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; printf '%s' "$ACCT_A" > "$ACCT_B/.blackout_other"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "an account that stops answering DURING settle → REFUSED (absence unverified), not confirmed" "$rc" 3
chk_contains "…names the silent account" "$out" "did not answer"
chk_contains "…says the session is live on the target (nothing to undo)" "$out" "live on 'beta'"
chk "…no record written" "$([[ -f "$(SEAT_RECORD_FILE seat-a)" ]] && echo yes || echo no)" "no"
chk "…the relaunch itself did happen (the refusal is about verification, not the launch)" "$(grep -c 'argv=--bg' "$CALLS")" 1

# ═══ 4. seat migrate — the accepting control, end to end ═════════════════════
printf '\n═══ 4. seat migrate — success path ═══\n'
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
mkdir -p "$ACCT_A/jobs/$SHORT"; printf '{"respawnFlags":["--model","model-spec"]}' > "$ACCT_A/jobs/$SHORT/state.json"
out="$("$AIMAIL" seat migrate seat-a beta --from super 2>&1)"; rc=$?
chk "live on A, target B, model from the launch spec → SUCCESS (exit 0)" "$rc" 0
chk "…claude stop called once, under A's config dir" "$(grep -c "cfg=$ACCT_A argv=stop $SHORT" "$CALLS")" 1
chk "…relaunch under B's config dir" "$(grep -c "cfg=$ACCT_B argv=--bg" "$CALLS")" 1
chk "…with --resume <the same sid>" "$(grep -c -- "--resume $SID" "$CALLS")" 1
chk "…with the explicit model" "$(grep -c -- "--model model-spec" "$CALLS")" 1
chk "…with bypass permission flags" "$(grep -c -- "--permission-mode bypassPermissions" "$CALLS")" 1
chk "…from the listing's cwd" "$(grep -c "cwd=$TEST_CWD cfg=$ACCT_B argv=--bg" "$CALLS")" 1
chk "…stop happened BEFORE the relaunch" "$([[ "$(grep -n 'argv=stop' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'argv=--bg' "$CALLS" | cut -d: -f1)" ]] && echo yes)" "yes"
chk "…record written: account beta" "$(seat_record_read seat-a account)" "beta"
chk "…record: session id" "$(seat_record_read seat-a session_id)" "$SID"
chk "…record: model" "$(seat_record_read seat-a model)" "model-spec"
chk "…record: confirmed_by migrate" "$(seat_record_read seat-a confirmed_by)" "migrate"
chk_contains "…output names the settle re-check" "$out" "present on 'beta' only"
chk_contains "…the default prompt tells the seat to confirm" "$(grep 'argv=--bg' "$CALLS")" "aimail seat confirm seat-a"
# dead seat, record only → no stop, straight to relaunch
reset_state; seat_record_write seat-a acct-a "$ACCT_A" "$SID" model-rec boot "" "" "$TEST_CWD"
out="$("$AIMAIL" seat migrate seat-a beta --from super 2>&1)"; rc=$?
chk "DEAD seat with a record (record carries cwd) → relaunched from the record (exit 0)" "$rc" 0
chk "…no stop attempted (nothing live)" "$(grep -c 'argv=stop' "$CALLS")" 0
chk "…model from the record" "$(grep -c -- "--model model-rec" "$CALLS")" 1
chk_contains "…handover skipped with the reason" "$out" "not live"
# --sid override for a first-time seat
reset_state
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --sid "$SID" 2>&1)"; rc=$?
chk "--sid with no live session, no --cwd and no saved spec → REFUSED (never the operator's \$PWD)" "$rc" 3
chk_contains "…says to pass --cwd" "$out" "--cwd"
mkdir -p "$ACCT_A/jobs/$SHORT"; printf '{"cwd":"%s","template":"bg"}' "$TEST_CWD" > "$ACCT_A/jobs/$SHORT/state.json"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --sid "$SID" 2>&1)"; rc=$?
chk "--sid with the cwd in the SOURCE's saved launch spec → relaunch (exit 0)" "$rc" 0
chk_contains "…cwd read from the saved spec" "$out" "from the saved launch spec"
rm -rf "$ACCT_A/jobs"; reset_state
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --sid "$SID" --cwd "$TEST_CWD" 2>&1)"; rc=$?
chk "--sid with nothing else known → relaunch (exit 0)" "$rc" 0
chk "…resumes that sid" "$(grep -c -- "--resume $SID" "$CALLS")" 1
# custom prompt file
reset_state; seat_record_write seat-a acct-a "$ACCT_A" "$SID" m boot "" "" "$TEST_CWD"
printf 'CUSTOM PROMPT TEXT\n' > "$AIMAIL_ROOT/prompt.txt"
"$AIMAIL" seat migrate seat-a beta --from super --prompt-file "$AIMAIL_ROOT/prompt.txt" --cwd "$TEST_CWD" >/dev/null 2>&1
chk "--prompt-file replaces the default prompt" "$(grep -c 'CUSTOM PROMPT TEXT' "$CALLS")" 1

# saved launch options on the target (2026-09-21 live finding): flagless resume, or a stopped copy + refusal
reset_state; seat_record_write seat-a acct-a "$ACCT_A" "$SID" model-x boot "" "" "$TEST_CWD"
mkdir -p "$ACCT_B/jobs/$SHORT"; printf '{"respawnFlags":["--model","model-x"],"template":"bg"}' > "$ACCT_B/jobs/$SHORT/state.json"
out="$("$AIMAIL" seat migrate seat-a beta --from super --cwd "$TEST_CWD" 2>&1)"; rc=$?
chk "target holds the saved spec (same model) → relaunch FLAGLESS, success" "$rc" 0
chk "…the --bg call carried no --model / permission flags (argv before the prompt)" "$(grep -c "argv=--bg --resume $SID --model" "$CALLS")" 0
chk "…and continued the SAME session id" "$(grep -c "\"sessionId\": \"$SID\"" "$ACCT_B/agents.json")" 1
chk_contains "…says why" "$out" "WITHOUT flags"
reset_state; seat_record_write seat-a acct-a "$ACCT_A" "$SID" model-x boot "" "" "$TEST_CWD"
mkdir -p "$ACCT_B/jobs/$SHORT"; printf '{"respawnFlags":["--model","model-other"],"template":"bg"}' > "$ACCT_B/jobs/$SHORT/state.json"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model model-x 2>&1)"; rc=$?
chk "saved spec pins a DIFFERENT model than requested → REFUSED before launching" "$rc" 3
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk_contains "…names both models" "$out" "model-other"
# the guard itself: a flagged launch that the CLI turned into a copy (spec appears after the check)
reset_state; seat_record_write seat-a acct-a "$ACCT_A" "$SID" model-x boot "" "" "$TEST_CWD"
_orig_claude="$(cat "$FAKE/claude")"
python3 - "$FAKE/claude" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
# make the saved-spec check invisible to the tool (different path) but still trigger the copy in the fake
s=s.replace('[[ -f "$DIR/jobs/${sid:0:8}/state.json" ]]','[[ -f "$DIR/.force_copy" ]]'); open(p,'w').write(s)
PY
touch "$ACCT_B/.force_copy"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model model-x 2>&1)"; rc=$?
chk "CLI reports 'started a copy as <new-sid>' → REFUSED, not treated as a resume" "$rc" 3
chk_contains "…names the copy" "$out" "COPY as c0c0c0c0"
chk "…the copy was stopped" "$(grep -c 'argv=stop c0c0c0c0' "$CALLS")" 1
chk "…no migrate record written (the seeded boot record stands)" "$(seat_record_read seat-a confirmed_by)" "boot"
printf '%s' "$_orig_claude" > "$FAKE/claude"; rm -f "$ACCT_B/.force_copy"

# ═══ 5. --dry-run runs nothing ═══════════════════════════════════════════════
printf '\n═══ 5. --dry-run ═══\n'
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --dry-run 2>&1)"; rc=$?
chk "dry-run exits 0" "$rc" 0
chk "…only the read-only listing was called (no stop, no --bg)" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
chk_contains "…prints the stop command" "$out" "claude stop $SHORT"
chk_contains "…prints the relaunch command with the sid" "$out" "--resume $SID"
chk "…writes no record" "$([[ -f "$(SEAT_RECORD_FILE seat-a)" ]] && echo yes || echo no)" "no"
chk "…the original is still listed on A" "$(grep -c "$SID" "$ACCT_A/agents.json")" 1

# ═══ 6. handover wait ════════════════════════════════════════════════════════
printf '\n═══ 6. handover ═══\n'
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
export AIMAIL_MIGRATE_HANDOVER_WAIT=1 AIMAIL_MIGRATE_POLL_S=1
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "live seat, no role write within the wait → REFUSED" "$rc" 3
chk_contains "…says handover" "$out" "handover"
chk "…mail asking for it was sent to the seat" "$(ls "$MAIL_DIR/seat-a"/*.md 2>/dev/null | grep -c 'migration\|MIGRATION')" 1
chk "…nothing stopped" "$(grep -c 'argv=stop' "$CALLS")" 0
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --force-no-handover 2>&1)"; rc=$?
chk "…--force-no-handover proceeds (exit 0)" "$rc" 0
chk_contains "…and says so loudly" "$out" "force-no-handover"
# a role write during the wait lets it proceed
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
mkdir -p "$AIMAIL_ROOT/roles"; printf 'old\n' > "$AIMAIL_ROOT/roles/seat-a.md"; touch -d '2000-01-01' "$AIMAIL_ROOT/roles/seat-a.md"
# ⚠ DETERMINISTIC, NOT A RACE (assistant 2026-09-22 20:14; code-review and fable both saw this arm
#   fail under load 12-20 and pass solo). The old shape slept 0.5s then wrote; the CLI compares the
#   role file's mtime AFTER its own startup (`before=`) with the mtime during the wait, so when
#   startup took longer than 0.5s the write landed BEFORE `before=` was read and nothing "changed".
#   The CLI mails the seat "MIGRATION in Ns" immediately before its wait loop: the writer waits for
#   THAT mail to appear (a new file in the seat's inbox), then writes -- inside the window by
#   construction, however slow the box. Bounded: gives up after 20s so a broken CLI cannot hang the suite.
_n_before="$(ls "$MAIL_DIR/seat-a"/*.md 2>/dev/null | wc -l)"
( for _i in $(seq 1 200); do (( $(ls "$MAIL_DIR/seat-a"/*.md 2>/dev/null | wc -l) > _n_before )) && break; sleep 0.1; done
  printf 'fresh handover\n' > "$AIMAIL_ROOT/roles/seat-a.md" ) &
export AIMAIL_MIGRATE_HANDOVER_WAIT=20
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "role file written during the wait → proceeds (exit 0)" "$rc" 0
chk_contains "…reports the handover" "$out" "handover written"
wait

printf '\n═══ 6b. --from default resolves the ACTUAL invoking seat, never a hardcoded name ═══\n'
# The handover-request mail's own "from" used to be `${AIMAIL_MIGRATE_FROM:-assistant}`
# unconditionally -- correct only when assistant itself runs the migrate. Any other
# operator (librarian ran the real one this bug was reported from) got a mail claiming
# to be FROM assistant when it was not, and if that operator's own session were ever
# registered under a stricter sender check, the wrong "from" would misattribute it.
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
rm -rf "$MAIL_DIR/seat-a"; mkdir -p "$MAIL_DIR/seat-a"   # reset_state does not clear mail (section 6 left files behind)
export AIMAIL_MIGRATE_HANDOVER_WAIT=1 AIMAIL_MIGRATE_POLL_S=1
CALLER_SID="dddddddd-1111-2222-3333-444444444444"
rm -f "$STATE_DIR/stopguard/session.$CALLER_SID" 2>/dev/null
# 6b.1 no caller session id, no stopguard mapping → falls back to "assistant" (old default preserved)
"$AIMAIL" seat add assistant "test assistant (fallback default)" >/dev/null 2>&1
out="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "$AIMAIL" seat migrate seat-a beta --model m 2>&1)"; rc=$?
chk "…handover mail was sent" "$(ls "$MAIL_DIR/seat-a"/*.md 2>/dev/null | wc -l)" 1
chk_contains "…from: assistant (fallback preserved when no mapping exists)" "$(cat "$MAIL_DIR/seat-a"/*.md 2>/dev/null)" "from: assistant"
# 6b.2 the caller's OWN session IS registered to a seat → that seat sends it, not "assistant"
rm -rf "$MAIL_DIR/seat-a"; mkdir -p "$MAIL_DIR/seat-a"
mkdir -p "$STATE_DIR/stopguard"; printf 'super' > "$STATE_DIR/stopguard/session.$CALLER_SID"
out="$(CLAUDE_CODE_SESSION_ID="$CALLER_SID" "$AIMAIL" seat migrate seat-a beta --model m 2>&1)"; rc=$?
chk_contains "…from: super (the registered caller), not assistant" "$(cat "$MAIL_DIR/seat-a"/*.md 2>/dev/null)" "from: super"
chk "…never falls back to assistant when a real mapping exists" "$(grep -l '^from: assistant' "$MAIL_DIR/seat-a"/*.md 2>/dev/null | wc -l)" 0
rm -f "$STATE_DIR/stopguard/session.$CALLER_SID"

printf '\n═══ 6c. a mail_send failure during handover surfaces its REAL reason, never swallowed ═══\n'
# The handover-request send used to redirect mail_send's stdout+stderr to /dev/null and,
# on failure, print only a generic "mail_send failed" — a real refusal (mail_send's own
# `refused`, exit 3) inside it was invisible, and the caller waited out the full
# handover-wait blind before eventually refusing for an unrelated-looking reason.
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
rm -rf "$MAIL_DIR/seat-a"; mkdir -p "$MAIL_DIR/seat-a"   # reset_state does not clear mail
export AIMAIL_MIGRATE_HANDOVER_WAIT=1 AIMAIL_MIGRATE_POLL_S=1
OTHER_SID="eeeeeeee-1111-2222-3333-444444444444"
seat_record_write super acct-a "$ACCT_A" "$OTHER_SID" model-x tester
out="$(CLAUDE_CODE_SESSION_ID="$SID" "$AIMAIL" seat migrate seat-a beta --from super --model m 2>&1)"; rc=$?
chk "…still refuses overall (no handover ever arrived)" "$rc" 3
chk_contains "…surfaces mail_send's REAL refusal text, not swallowed" "$out" "is NOT the registered"
chk "…mail_send genuinely never delivered (the refusal was real)" "$(ls "$MAIL_DIR/seat-a"/*.md 2>/dev/null | grep -c 'migration\|MIGRATION')" 0
rm -f "$(SEAT_RECORD_FILE super)"

printf '\n═══ 7. session registry + resume-by-default + --fresh (the owner 2026-09-22) ═══\n'
PRIOR="bbbbbbbb-1111-2222-3333-444444444444"
# 7.1 the registry follows `seat confirm` automatically
reset_state
CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_CONFIG_DIR="$ACCT_A" "$AIMAIL" seat confirm seat-a --model model-x >/dev/null 2>&1
chk "confirm writes the per-account registry row (seat-a @ acct-a)" "$(seat_sessions_get seat-a acct-a)" "$SID"
chk "…with the model" "$(seat_sessions_get seat-a acct-a model)" "model-x"
chk "…and one log line naming who" "$(grep -c $'\tset\tacct-a\t' "$(SEAT_SESSIONS_LOG seat-a)")" 1
# 7.2 set-session / reset-session
out="$("$AIMAIL" seat set-session seat-a acct-b "$PRIOR" 2>&1)"; rc=$?
chk "set-session without --why REFUSES (exit 3)" "$rc" 3
out="$("$AIMAIL" seat set-session seat-a acct-b "$PRIOR" --model model-y --why "prior stint on beta" --by tester 2>&1)"; rc=$?
chk "set-session with --why succeeds" "$rc" 0
chk "…registry row for acct-b" "$(seat_sessions_get seat-a acct-b)" "$PRIOR"
chk "…the acct-a row is untouched" "$(seat_sessions_get seat-a acct-a)" "$SID"
chk "…log records the reason" "$(grep -c 'prior stint on beta' "$(SEAT_SESSIONS_LOG seat-a)")" 1
out="$("$AIMAIL" seat sessions seat-a 2>&1)"
chk_contains "seat sessions lists both accounts (acct-b row)" "$out" "acct-b"
chk_contains "…and the history" "$out" "prior stint on beta"
out="$("$AIMAIL" seat reset-session seat-a acct-b 2>&1)"; rc=$?
chk "reset-session without --why REFUSES" "$rc" 3
"$AIMAIL" seat reset-session seat-a acct-b --why "stale after relaunch" --by tester >/dev/null 2>&1
chk "reset-session clears the acct-b row" "$(seat_sessions_get seat-a acct-b 2>/dev/null || echo cleared)" "cleared"
chk "…and logs a clear line with the old sid" "$(grep -c $'\tclear\tacct-b\t'"$PRIOR" "$(SEAT_SESSIONS_LOG seat-a)")" 1
# 7.3 DEFAULT = resume; the transcript is CARRIED to the target (the source-session-not-found fix)
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; seed_stub "$ACCT_B" "$SID"
chk "precondition: target holds only a stub (no conversation)" "$(grep -c '"type":"user"' "$ACCT_B/projects/$SLUG/$SID.jsonl")" 0
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "migrate (default) succeeds" "$rc" 0
chk_contains "…says it carried the transcript" "$out" "transcript carried to the target"
chk "…the target now has the real transcript" "$(grep -c '"type":"user"' "$ACCT_B/projects/$SLUG/$SID.jsonl")" 1
chk "…and the sidecar dir" "$([[ -f "$ACCT_B/projects/$SLUG/$SID/agent-1.jsonl" ]] && echo yes || echo no)" "yes"
chk "…the relaunch was a --resume of the SAME sid" "$(grep -c -- "--resume $SID" "$CALLS")" 1
chk "…record: launch_path=resume" "$(seat_record_read seat-a launch_path)" "resume"
chk "…registry row for the target = the sid" "$(seat_sessions_get seat-a acct-b)" "$SID"
chk "…registry path resume" "$(seat_sessions_get seat-a acct-b launch_path)" "resume"
# 7.4 no transcript anywhere → REFUSED, names --fresh, no launch (fresh is never automatic)
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; rm -rf "$ACCT_A/projects"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "no transcript on source or target → REFUSED" "$rc" 3
chk_contains "…names the explicit --fresh --why escape" "$out" "--fresh --why"
chk "…and nothing was launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk "…and the old session was NOT stopped (refusal came before step c)" "$(grep -c 'argv=stop' "$CALLS")" 0
# 7.5 the scheduler says failed → the refusal names the real reason at once, never DISAPPEARED
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; touch "$ACCT_B/.fail_resume"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 --settle 0 2>&1)"; rc=$?
chk "resume that FAILS in the scheduler → REFUSED" "$rc" 3
chk_contains "…quoting the scheduler's own detail" "$out" "source session $SID not found"
chk "…never described as DISAPPEARED" "$(grep -c DISAPPEARED <<<"$out")" 0
chk "…no record written" "$([[ -f "$(SEAT_RECORD_FILE seat-a)" ]] && echo yes || echo no)" "no"
# 7.6 _sid_listed: a failed row is not "listed"
write_agents "$ACCT_B"; add_row() { :; }   # (shadow-safe: use the fake's own writer via python below)
python3 - "$ACCT_B/agents.json" "$SID" <<'PY'
import json, sys
p, sid = sys.argv[1], sys.argv[2]
json.dump([{"sessionId": sid, "id": sid[:8], "pid": None, "state": "failed", "status": "failed", "cwd": "/tmp", "name": "fake"}], open(p, "w"))
PY
_sid_listed "$ACCT_B" "$SID"; rc=$?
chk "_sid_listed: a state=failed row reads NOT listed (rc 1)" "$rc" 1
unset -f add_row
# 7.7 --fresh: explicit only, needs --why, follows the NEW sid, records the path and reason
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 --fresh 2>&1)"; rc=$?
chk "--fresh without --why REFUSES" "$rc" 3
chk "…before anything ran" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 --fresh --why "seat ignoring the orchestrator" 2>&1)"; rc=$?
chk "--fresh --why succeeds" "$rc" 0
chk "…the launch carried NO --resume" "$(grep -c -- '--resume' "$CALLS")" 0
NEWSID="$(seat_record_read seat-a session_id)"
chk "…the record names a NEW sid, not the old one" "$([[ -n "$NEWSID" && "$NEWSID" != "$SID" ]] && echo new || echo same)" "new"
chk "…record: launch_path=fresh" "$(seat_record_read seat-a launch_path)" "fresh"
chk "…the new sid is what the target lists" "$(python3 -c "import json,sys; print(any(r['sessionId']=='$NEWSID' for r in json.load(open('$ACCT_B/agents.json'))))")" "True"
chk "…registry row for acct-b = the new sid" "$(seat_sessions_get seat-a acct-b)" "$NEWSID"
chk "…log carries the --why" "$(grep -c 'seat ignoring the orchestrator' "$(SEAT_SESSIONS_LOG seat-a)")" 1
# 7.8 the seat's PREVIOUS session on the target wins when its transcript is there
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
seat_sessions_set seat-a acct-b "$PRIOR" model-y tester "earlier stint" resume
seed_transcript "$ACCT_B" "$PRIOR"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "migrate resumes the seat's PRIOR session on the target" "$rc" 0
chk "…--resume <prior sid> was called" "$(grep -c -- "--resume $PRIOR" "$CALLS")" 1
chk "…not the current one" "$(grep -c -- "--resume $SID" "$CALLS")" 0
chk "…record sid = prior" "$(seat_record_read seat-a session_id)" "$PRIOR"
chk "…record: launch_path=resume-prior" "$(seat_record_read seat-a launch_path)" "resume-prior"
# 7.9 dry-run prints the carry, copies nothing, launches nothing
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --dry-run 2>&1)"; rc=$?
chk "dry-run exits 0" "$rc" 0
chk_contains "…prints the transcript cp command" "$out" "cp -p $ACCT_A/projects/$SLUG/$SID.jsonl"
chk "…but copied nothing" "$([[ -f "$ACCT_B/projects/$SLUG/$SID.jsonl" ]] && echo yes || echo no)" "no"

printf '\n═══ 8. supervisor liveness guard + pinned supervisor (the owner 2026-09-22) ═══\n'
# shellcheck source=../lib/watchdog.sh
source "$REPO/lib/watchdog.sh"
"$AIMAIL" seat add vice "vice orchestrator (test)" >/dev/null 2>&1
export AIMAIL_SUPERVISOR=super AIMAIL_VICE_SUPERVISOR=vice AIMAIL_SUPERVISOR_WAKE_RETRIES=2
SUPSID="cccccccc-1111-2222-3333-444444444444"
sup_reset() { reset_state; rm -rf "$(SUPERVISOR_WAKE_DIR)" "$(SUPERVISOR_ALERT_FILE)" "$(INSTANCE_DIR super)" "$AIMAIL_ROOT/state/hb" \
  "$(THROTTLE_FLAG acct-b)" "$(RAMP_AT_FILE acct-b)" "$AIMAIL_ROOT/mail/vice"/*.md "$AIMAIL_ROOT/mail/vice/unacked"/* 2>/dev/null
  seat_record_write super acct-b "$ACCT_B" "$SUPSID" model-s boot "" "" "$TEST_CWD" >/dev/null 2>&1; seed_transcript "$ACCT_B" "$SUPSID"
  touch -d '-2 hours' "$ACCT_B"/projects/*/"$SUPSID".jsonl 2>/dev/null   # a DEAD seat's transcript is stale; 8.11 refreshes it on purpose
  rm -f "$ACCT_B/.copy_unlisted" "$ACCT_B/.stop_fails" "$AIMAIL_ROOT"/state/poller/super.hb; : > "$CALLS"; }   # 8.6's live heartbeat must not outlive its arm
export AIMAIL_SUPERVISOR_STOP_POLL_S=0
# 8.1 dead supervisor, not parked -> ONE flagless resume, a row appears, attempts=1; second tick: still not live (fake row is 'working' -> mid-turn) -> no second launch
sup_reset; mkdir -p "$AIMAIL_ROOT/elsewhere"
( cd "$AIMAIL_ROOT/elsewhere" && fleet_watchdog_supervisor ) > "$AIMAIL_ROOT/sup81.log" 2>&1 || { echo "  (fleet_watchdog_supervisor rc=$?)"; sed 's/^/      /' "$AIMAIL_ROOT/sup81.log" | tail -5; }
chk "dead supervisor -> exactly one --bg --resume was issued" "$(grep -c -- "--bg --resume $SUPSID" "$CALLS")" 1
chk "…flagless (no --model in the argv)" "$(grep -c -- "--resume $SUPSID --model" "$CALLS")" 0
chk "…resumed FROM the record's cwd, not the cron's own \$PWD" "$(grep -c -- "cwd=$TEST_CWD cfg=$ACCT_B argv=--bg --resume $SUPSID" "$CALLS")" 1
chk "…the resumed session is now listed on its account" "$(python3 -c "import json; print(any(r['sessionId']=='$SUPSID' for r in json.load(open('$ACCT_B/agents.json'))))")" "True"
chk "…attempts file reads 1 for the unparked episode" "$(cut -f2 "$(_sw_attempts_file)")" 1
fleet_watchdog_supervisor >/dev/null 2>&1
chk "second tick with the session live+working -> no second launch" "$(grep -c -- 'argv=--bg' "$CALLS")" 1
chk "…and no alert" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
# 8.2 parked with the ramp ahead -> nothing at all
sup_reset; printf 'ACCOUNT\tacct-b\n' > "$(THROTTLE_FLAG acct-b)"; printf 'at\t%s\n' "$(( $(now_epoch) + 3600 ))" > "$(RAMP_AT_FILE acct-b)"
out="$(fleet_watchdog_supervisor 2>&1)"
chk "parked, ramp ahead -> no launch" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk_contains "…says it is waiting for the ramp" "$out" "nothing to wake into"
# 8.3 parked, ramp PASSED, dead -> resume (the ramp episode)
sup_reset; printf 'ACCOUNT\tacct-b\n' > "$(THROTTLE_FLAG acct-b)"; printf 'at\t%s\n' "$(( $(now_epoch) - 60 ))" > "$(RAMP_AT_FILE acct-b)"
fleet_watchdog_supervisor >/dev/null 2>&1
chk "parked but ramp passed, dead -> resumed" "$(grep -c -- "--bg --resume $SUPSID" "$CALLS")" 1
chk "…episode keyed on the ramp" "$(cut -f1 "$(_sw_attempts_file)" | cut -d: -f1)" "ramp"
# 8.4 resume FAILS in the scheduler -> escalation to vice + ALERT marker, once
sup_reset; touch "$ACCT_B/.fail_resume"
fleet_watchdog_supervisor >/dev/null 2>&1
chk "failed resume -> ALERT marker written" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "yes"
chk_contains "…naming the scheduler detail" "$(cat "$(SUPERVISOR_ALERT_FILE)")" "source session $SUPSID not found"
chk "…vice got the escalation mail" "$(ls "$AIMAIL_ROOT"/mail/vice/*.md "$AIMAIL_ROOT"/mail/vice/unacked/*.md 2>/dev/null | grep -ci 'supervisor-unreachable')" 1
out="$("$AIMAIL" session vice 2>&1 || true)"
chk_contains "aimail session prints the alert banner FIRST" "$(head -3 <<<"$out")" "SUPERVISOR UNREACHABLE"
"$AIMAIL" fleet supervisor-ack >/dev/null 2>&1
chk "supervisor-ack clears the marker" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
# 8.5 retries: dead and the launch is a no-op (never lists) -> 2 attempts then escalate, then no more launches
sup_reset; touch "$ACCT_B/.launch_noop"
fleet_watchdog_supervisor >/dev/null 2>&1; fleet_watchdog_supervisor >/dev/null 2>&1; fleet_watchdog_supervisor >/dev/null 2>&1; fleet_watchdog_supervisor >/dev/null 2>&1
chk "attempts stop at AIMAIL_SUPERVISOR_WAKE_RETRIES=2" "$(grep -c 'argv=--bg' "$CALLS")" 2
chk "…then escalates once" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "yes"
chk "…exactly one escalation mail to vice" "$(ls "$AIMAIL_ROOT"/mail/vice/*.md "$AIMAIL_ROOT"/mail/vice/unacked/*.md 2>/dev/null | grep -ci 'supervisor-unreachable')" 1
# 8.5b dead supervisor, record WITHOUT a cwd, no saved spec -> NO launch, escalation (never the cron's $PWD)
sup_reset; seat_record_write super acct-b "$ACCT_B" "$SUPSID" model-s boot >/dev/null 2>&1
( cd "$AIMAIL_ROOT/elsewhere" && fleet_watchdog_supervisor ) >/dev/null 2>&1
chk "no cwd known -> nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk "…ALERT marker written" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "yes"
chk_contains "…naming the missing directory" "$(cat "$(SUPERVISOR_ALERT_FILE)")" "no working directory known"
chk "…attempts NOT burnt on an unlaunchable tick" "$([[ -f "$(_sw_attempts_file)" ]] && cut -f2 "$(_sw_attempts_file)" || echo 0)" 0
( cd "$AIMAIL_ROOT/elsewhere" && fleet_watchdog_supervisor ) >/dev/null 2>&1
chk "…second tick: still nothing launched, alert not re-sent" "$(ls "$AIMAIL_ROOT"/mail/vice/*.md "$AIMAIL_ROOT"/mail/vice/unacked/*.md 2>/dev/null | grep -ci 'supervisor-unreachable')" 1
"$AIMAIL" fleet supervisor-ack >/dev/null 2>&1
# 8.5c dead supervisor, record without a cwd but the account's saved launch spec has one -> resume FROM the spec's cwd
sup_reset; seat_record_write super acct-b "$ACCT_B" "$SUPSID" model-s boot >/dev/null 2>&1
mkdir -p "$ACCT_B/jobs/${SUPSID:0:8}"; printf '{"cwd":"%s","template":"bg"}' "$TEST_CWD" > "$ACCT_B/jobs/${SUPSID:0:8}/state.json"
( cd "$AIMAIL_ROOT/elsewhere" && fleet_watchdog_supervisor ) >/dev/null 2>&1
chk "spec carries the cwd -> resumed from it" "$(grep -c -- "cwd=$TEST_CWD cfg=$ACCT_B argv=--bg --resume $SUPSID" "$CALLS")" 1
chk "…and no alert" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
chk_contains "…the log names the spec as the source" "$(cat "$(_sw_log)" 2>/dev/null)" "from spec:"
rm -rf "$ACCT_B/jobs/${SUPSID:0:8}"
# 8.6 live and ARMED -> nothing (a fresh heartbeat + instance)
sup_reset; write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b "$$"; hb_beat super; hb_write super pid "$$"   # a LIVE pid: this shell
out="$(fleet_watchdog_supervisor 2>&1)"
chk "live + ARMED -> no launch" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk_contains "…reports healthy" "$out" "healthy" || true
[[ "$out" == *healthy* ]] || printf '      (poller_state: %s | out: %s)\n' "$(poller_state super 2>&1 | head -1)" "$(head -1 <<<"$out")"
# 8.7 the supervisor is PINNED
sup_reset; write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b
out="$("$AIMAIL" seat migrate super alpha --from vice --model m --handover-wait 0 2>&1)"; rc=$?
chk "seat migrate <supervisor> without --owner-approved REFUSES" "$rc" 3
chk_contains "…says PINNED" "$out" "PINNED"
chk "…nothing stopped or launched" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
seed_transcript "$ACCT_B" "$SUPSID"
out="$("$AIMAIL" seat migrate super alpha --from vice --model m --handover-wait 0 --owner-approved "the owner 16:45: move it" 2>&1)"; rc=$?
chk "…with --owner-approved but NO prior session on the target: REFUSED (the supervisor keeps its old session alive, so the same id cannot move)" "$rc" 3
chk_contains "…naming --resume-sid" "$out" "--resume-sid"
chk "…nothing stopped or launched" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
SUP_PRIOR="cccccccc-9999-8888-7777-666666666666"; mkdir -p "$ACCT_A/projects/$(_cwd_slug "$TEST_CWD")"
printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$(_cwd_slug "$TEST_CWD")/$SUP_PRIOR.jsonl"
out="$("$AIMAIL" seat migrate super alpha --from vice --model m --handover-wait 0 --owner-approved "the owner 16:45: move it" 2>&1)"; rc=$?
chk "…with --owner-approved AND a prior session on the target it proceeds (exit 0)" "$rc" 0
chk "…the registry log carries the approval" "$(grep -c 'owner-approved: the owner 16:45' "$(SEAT_SESSIONS_LOG super)")" 1
chk "…the OLD session was NOT stopped (keep-old implied for the supervisor)" "$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 0
chk "…the PRIOR session was resumed on the target" "$(grep -c -- "--bg --resume $SUP_PRIOR" "$CALLS")" 1
chk "…and the record follows it" "$(seat_record_read super session_id)" "$SUP_PRIOR"
# 8.8 the pinned SET (the owner 17:28): the vice (main) is locked too; a seat outside the set is not
write_instance vice "$PRIOR" acct-b; write_agents "$ACCT_B" "$PRIOR"; seat_record_write vice acct-b "$ACCT_B" "$PRIOR" model-v boot >/dev/null 2>&1
out="$("$AIMAIL" seat migrate vice alpha --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "seat migrate <vice> without the override REFUSES (pinned set)" "$rc" 3
chk_contains "…names the set" "$out" "AIMAIL_PINNED_SEATS"
seed_transcript "$ACCT_B" "$PRIOR"   # so the only possible refusal left is the pinned one
out="$(AIMAIL_PINNED_SEATS="super" "$AIMAIL" seat migrate vice alpha --from super --model m --handover-wait 0 --dry-run 2>&1)"; rc=$?
chk "…a seat NOT in AIMAIL_PINNED_SEATS is not refused on that ground (dry-run exit 0)" "$rc" 0
# 8.9 placement rule at the migrate level (T-917): alpha is the supervisor's (precious) account, beta has headroom -> a move of seat-a onto alpha is refused before the handover
sup_reset; write_instance seat-a "$SID" acct-b; write_agents "$ACCT_B" "$SID"; seed_transcript "$ACCT_B" "$SID"
# ⚠ ONE WORD PER ACCOUNT: this suite calls the accounts alpha/beta (AIMAIL_FLEET_ACCOUNTS, the migrate
#   target), so its readings, roster and precious marker use the SAME words -- WEEKLY_FILE alpha, ledger
#   column alpha, "alpha:super". The first cut mixed alpha (target) with acct-a (readings), so the target
#   read UNMEASURED and the arm passed on the old unmeasured->refuse, not on the precious rule it names
#   (caught when ab56dce made an unmeasured target a WARNING; a second cut mapped alias->dir label inside
#   placement.sh and broke tests/balance.sh instead -- the word is the key, everywhere).
printf '%s\t30\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"; printf '%s\t30\t\n' "$(now_epoch)" > "$(WEEKLY_FILE beta)"
printf '%s\talpha\t40\tprobe\t\n%s\tbeta\t40\tprobe\t\n' "$(now_epoch)" "$(now_epoch)" >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
out="$(AIMAIL_PRECIOUS_ACCOUNT=alpha AIMAIL_PLACEMENT_SEATS="alpha:super beta:seat-a" "$AIMAIL" seat migrate seat-a alpha --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "migrate onto the precious account while another has headroom -> REFUSED (placement rule)" "$rc" 3
chk_contains "…names the rule" "$out" "placement rule"
chk "…before the handover/stop (no stop issued)" "$(grep -c 'argv=stop' "$CALLS")" 0
out="$(AIMAIL_PRECIOUS_ACCOUNT=alpha AIMAIL_PLACEMENT_SEATS="alpha:super beta:seat-a" "$AIMAIL" seat migrate seat-a alpha --from super --model m --handover-wait 0 --owner-approved "the owner: put it there" 2>&1)"; rc=$?
chk "…--owner-approved overrides the placement rule too (exit 0)" "$rc" 0
# 8.10 the target already RUNS the session: a WORKING twin is a refusal, a limit-BLOCKED leftover is stopped and the move goes on
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"
put_row() { python3 - "$1" "$2" "$3" <<'PY'
import json, sys
p, sid, st = sys.argv[1:4]
json.dump([{"sessionId": sid, "id": sid[:8], "pid": 777, "state": st, "status": "idle", "cwd": "/tmp", "name": "leftover"}], open(p, "w"))
PY
}
put_row "$ACCT_B/agents.json" "$SID" working
seed_transcript "$ACCT_B" "$SID"; mkdir -p "$ACCT_B/jobs/$SHORT"; printf '{"respawnFlags":["--model","m"],"template":"bg"}' > "$ACCT_B/jobs/$SHORT/state.json"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 2>&1)"; rc=$?
chk "locate with --all: a WORKING twin on the target -> TWINS refusal at step a (exit 3), nothing stopped" "$rc" 3
chk_contains "…says twins" "$out" "twins"
chk "…no stop, no launch" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
# the same leftover, limit-BLOCKED (the 2026-09-22 18:28 shape): the tool stops it and completes the move
put_row "$ACCT_B/agents.json" "$SID" blocked; : > "$CALLS"
out="$("$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 2>&1)"; rc=$?
(( rc == 0 )) || printf '   [8.10 output]\n%s\n' "$out" | sed 's/^/   | /'
chk "a limit-BLOCKED leftover on the target -> stopped, then the move completes (exit 0)" "$rc" 0
chk_contains "…says leftover" "$out" "leftover"
chk "…exactly two stops (the leftover on the target, then the source)" "$(grep -c 'argv=stop' "$CALLS")" 2
chk "…record: account=beta" "$(seat_record_read seat-a account)" "beta"
chk_contains "…the relaunch was flagless (the target kept a saved spec)" "$(seat_record_read seat-a launch_path)" "resume"
unset AIMAIL_SUPERVISOR AIMAIL_VICE_SUPERVISOR AIMAIL_SUPERVISOR_WAKE_RETRIES

# ⛔ 8.11-8.14: the 2026-09-23 00:25 incident -- the listing did not show the supervisor's LIVE session, the watchdog
#   booted, the resume answered "started a copy", the code read that as a blocked leftover and bounced with an
#   unverified stop, made a SECOND copy and left it running to self-confirm as the seat.
export AIMAIL_SUPERVISOR=super AIMAIL_VICE_SUPERVISOR=vice AIMAIL_SUPERVISOR_WAKE_RETRIES=2   # 8.10 left the section's exports behind
# 8.11 the transcript is the liveness oracle: dead per listing but the transcript changed minutes ago -> NO launch
sup_reset; touch "$ACCT_B"/projects/*/"$SUPSID".jsonl
fleet_watchdog_supervisor >/dev/null 2>&1
chk "fresh transcript (unlisted session) -> nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk "…the log says ALIVE, unlisted" "$(grep -c 'ALIVE, unlisted' "$(_sw_log)")" 1
chk "…no alert" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
chk "…no retry burnt" "$([[ -f "$(_sw_attempts_file)" ]] && cut -f2 "$(_sw_attempts_file)" || echo 0)" 0
# 8.12 stale transcript, unlisted, but the resume answers "started a copy" -> the copy is stopped, the ORIGINAL is left alone, no bounce, no alert
sup_reset; touch "$ACCT_B/.copy_unlisted"
fleet_watchdog_supervisor >/dev/null 2>&1
chk "copy answer -> exactly ONE resume was issued (no bounce resume)" "$(grep -c -- "--bg --resume $SUPSID" "$CALLS")" 1
chk "…the copy was stopped" "$(grep -c 'argv=stop c1c1c1c1' "$CALLS")" 1
chk "…the ORIGINAL was NOT stopped" "$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 0
chk "…no alert (a live seat is not an incident)" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
chk "…the log says NOT bouncing" "$(grep -c 'NOT bouncing' "$(_sw_log)")" 1
chk "…no retry burnt" "$(cut -f2 "$(_sw_attempts_file)")" 0
# ⛔ 8.13-8.17: the owner rule of 2026-09-23 08:50 -- "never kill the assistant again; resume the SAME one; a new
#   one only with Remote Control ON". The bounce that 8.14 used to prove is GONE: a limit-blocked original is
#   never stopped, the same id is retried, and the retries running out is a human's decision.
# 8.13 the original IS listed limit-BLOCKED and the resume copies -> copy stopped, ORIGINAL NOT stopped, ONE resume, retry burnt, record untouched
sup_reset; put_row "$ACCT_B/agents.json" "$SUPSID" blocked
fleet_watchdog_supervisor >/dev/null 2>&1
chk "blocked original + copy -> exactly ONE resume (no bounce resume)" "$(grep -c -- "--bg --resume $SUPSID" "$CALLS")" 1
chk "…the copy was stopped" "$(grep -c 'argv=stop c1c1c1c1' "$CALLS")" 1
chk "…the ORIGINAL was NOT stopped (the supervisor is never bounced)" "$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 0
chk "…the log says NEVER bounced" "$(grep -c 'NEVER bounced' "$(_sw_log)")" 1
chk "…the retry IS burnt (a blocked seat that copies is not progress)" "$(cut -f2 "$(_sw_attempts_file)")" 1
chk "…no alert yet (retries left)" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "no"
chk "…the seat record still names the ORIGINAL session (no copy adopted)" "$(seat_record_read super session_id)" "$SUPSID"
chk "…the original is still listed" "$(python3 -c "import json; print(any(r['sessionId']=='$SUPSID' for r in json.load(open('$ACCT_B/agents.json'))))")" "True"
# 8.14 …and when the retries run out: ALERT + mail to the vice that says NEVER stop it and names the remote-control launch for a NEW one
fleet_watchdog_supervisor >/dev/null 2>&1   # attempt 2/2
chk "second tick: one more same-session resume, still no stop of the original" "$(grep -c -- "--bg --resume $SUPSID" "$CALLS")$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 20
chk "…ALERT written" "$([[ -f "$(SUPERVISOR_ALERT_FILE)" ]] && echo yes || echo no)" "yes"
chk_contains "…the alert says a human decides, never a stop" "$(cat "$(SUPERVISOR_ALERT_FILE)")" "never stop"
chk_contains "…the alert names the remote-control launch for a NEW supervisor" "$(cat "$(SUPERVISOR_ALERT_FILE)")" "claude --remote-control super --bg"
chk_contains "…the vice's mail carries the same launch line" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null)" "--remote-control super"
chk_contains "…and the same-session resume FIRST" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null)" "--resume $SUPSID"
"$AIMAIL" fleet supervisor-ack >/dev/null 2>&1
# 8.15 _sw_stop_verified refuses the supervisor's own id outright (any caller), and never calls the CLI
sup_reset; : > "$CALLS"
_SW_PROTECT_SID=""; _sw_stop_verified "$ACCT_B" "$SUPSID" >/dev/null 2>&1; rc=$?
chk "stop of the supervisor's registered session -> REFUSED (rc 2)" "$rc" 2
chk "…no claude stop was issued" "$(grep -c 'argv=stop' "$CALLS")" 0
chk_contains "…the log says why" "$(cat "$(_sw_log)")" "never stopped, killed or bounced"
_sw_stop_verified "$ACCT_B" "${SUPSID:0:8}" >/dev/null 2>&1; rc=$?
chk "…the short id is refused too" "$rc" 2
put_row "$ACCT_B/agents.json" "dddddddd-1111-2222-3333-444444444444" working
_sw_stop_verified "$ACCT_B" "dddddddd-1111-2222-3333-444444444444" >/dev/null 2>&1; rc=$?
chk "…a DIFFERENT session (a copy) still stops normally" "$rc" 0
# 8.16 twins: two live sessions for the supervisor seat -> stop nothing, ONE mail to the vice naming both ids, once
sup_reset; write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b
write_agents "$ACCT_A" "$SUPSID"   # the same id live on a second account = twins per seat_session_locate
fleet_watchdog_supervisor >/dev/null 2>&1
chk "twins -> nothing stopped, nothing launched" "$(grep -c 'argv=stop\|argv=--bg' "$CALLS")" 0
chk "…ONE mail to the vice" "$(grep -l 'TWO live' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
chk_contains "…saying stop nothing" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null)" "stop nothing"
chk_contains "…and naming the short id" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null)" "${SUPSID:0:8}"
fleet_watchdog_supervisor >/dev/null 2>&1
chk "…a second tick with the same twins does NOT mail again" "$(grep -l 'TWO live' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
# 8.17 seat migrate --fresh of the SUPERVISOR seat launches WITH --remote-control <seat>; an ordinary seat does not
sup_reset; write_instance super "$SUPSID" acct-b; write_agents "$ACCT_B" "$SUPSID"
out="$("$AIMAIL" seat migrate super alpha --from vice --model m --handover-wait 0 --fresh --why "owner decided" --owner-approved "the owner, 2026-09-23 09:00: new supervisor on the pool account" 2>&1)"; rc=$?
chk "supervisor --fresh migrate succeeds" "$rc" 0
chk "…the fresh launch carried --remote-control super" "$(grep 'argv=--bg' "$CALLS" | grep -c -- '--remote-control super')" 1
chk "…the printed command shows it too" "$(grep -c -- '--remote-control super' <<<"$out")" 1
reset_state; write_instance seat-a "$SID" acct-a; write_agents "$ACCT_A" "$SID"; : > "$CALLS"
"$AIMAIL" seat migrate seat-a beta --from super --model m --handover-wait 0 --fresh --why "x" >/dev/null 2>&1
chk "an ordinary seat's fresh launch carries NO --remote-control" "$(grep 'argv=--bg' "$CALLS" | grep -c -- '--remote-control')" 0

# ═══ 9. the WEEKLY-CAP MOVE / supervisor budget handover (lib/handover.sh; the owner 2026-09-23 09:00, 09:04, 09:10) ═══
source "$REPO/lib/placement.sh" 2>/dev/null || true
source "$REPO/lib/handover.sh"
export AIMAIL_FLEET_ACCOUNTS="alpha beta"
# 9.1 model pins: the fable seat, the supervisor, everyone else; an explicit pin wins
chk "pin: fable -> the fable model" "$(seat_model_pin fable)" "claude-fable-5-1"
chk "pin: the supervisor -> opus" "$(seat_model_pin super)" "claude-opus-5-5"
chk "pin: an ordinary seat -> sonnet" "$(seat_model_pin seat-a)" "claude-sonnet-5-5"
chk "pin: AIMAIL_MODEL_PIN_<seat> overrides" "$(AIMAIL_MODEL_PIN_seat_a=model-z seat_model_pin seat-a)" "model-z"
# 9.2 a project slug walks back to its directory even when a path segment contains '-'
mkdir -p "$AIMAIL_ROOT/pj/x-y/z"
chk "slug -> dir (greedy join over '-')" "$(_slug_to_dir "$(printf '%s' "$AIMAIL_ROOT/pj/x-y/z" | tr '/' '-')")" "$AIMAIL_ROOT/pj/x-y/z"
chk "slug of a missing path -> fails" "$(_slug_to_dir "-no-such-dir-here-at-all" >/dev/null 2>&1 && echo ok || echo fail)" "fail"
# 9.3 the seat's PRIOR session on an account: registry first; else the transcript fingerprinted by the seat's own poller command, newest wins, the current sid excluded
sup_reset; rm -rf "$ACCT_A/projects"; SLUGA="$(printf '%s' "$TEST_CWD" | tr '/' '-')"; mkdir -p "$ACCT_A/projects/$SLUGA"
P_OLD="aaaaaaa1-0000-0000-0000-000000000001"; P_NEW="aaaaaaa2-0000-0000-0000-000000000002"; P_OTHER="aaaaaaa3-0000-0000-0000-000000000003"
printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_OLD.jsonl"; touch -d '-3 days' "$ACCT_A/projects/$SLUGA/$P_OLD.jsonl"
printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_NEW.jsonl"; touch -d '-1 day' "$ACCT_A/projects/$SLUGA/$P_NEW.jsonl"
printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent seat-a"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_OTHER.jsonl"
P_QUOTE="aaaaaaa4-0000-0000-0000-000000000004"; printf '{"type":"user","message":{"content":"mail said: run aimail poll-persistent super as a Monitor; quoted \\"command\\":\\"bash bin/aimail poll-persistent super\\" too"}}\n' > "$ACCT_A/projects/$SLUGA/$P_QUOTE.jsonl"   # newest, but only QUOTES the command -- never a candidate
P_THEIRS="aaaaaaa5-0000-0000-0000-000000000005"; printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_THEIRS.jsonl"; seat_record_write seat-a acct-a "$ACCT_A" "$P_THEIRS" m boot >/dev/null 2>&1   # a real call, newest, but REGISTERED to seat-a -- never a candidate
printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$SUPSID.jsonl"   # the CURRENT sid, newest -- must be excluded
out="$(seat_prior_session super alpha "$SUPSID")"
chk "prior on alpha = the NEWEST transcript with this seat's poller TOOL CALL: not another seat's, not one that only quotes it, not one registered to another seat, not the current sid" "$(cut -f1 <<<"$out")" "$P_NEW"
chk_contains "…source says transcript" "$(cut -f2 <<<"$out")" "transcript"
chk "…and its cwd is the transcript's own project dir" "$(cut -f3 <<<"$out")" "$TEST_CWD"
seat_sessions_set super alpha "$P_OLD" model-r test "registry row" >/dev/null 2>&1 || true
out="$(seat_prior_session super alpha "$SUPSID")"
chk "…a registry row for that account wins over the scan" "$(cut -f1 <<<"$out")$(cut -f2 <<<"$out")" "${P_OLD}registry"
rm -f "$ACCT_A/projects/$SLUGA/$SUPSID.jsonl"
chk "no prior anywhere -> fails" "$(seat_prior_session seat-a beta >/dev/null 2>&1 && echo found || echo none)" "none"
# 9.4 DRY RUN: the supervisor on beta at 96% weekly, alpha has headroom and a prior -> the plan, nothing executed
sup_reset; rm -f "$(SEAT_SESSIONS_FILE super)"; : > "$CALLS"
mkdir -p "$ACCT_A/projects/$SLUGA"; printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_NEW.jsonl"
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; printf '%s\t40\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"
write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b
out="$(supervisor_handover 2>&1)"; rc=$?
chk "dry run exits 0" "$rc" 0
chk_contains "…TRIGGER: DUE" "$out" "TRIGGER: DUE"
chk_contains "…target alpha (the account with headroom AND a prior)" "$out" "TARGET: alpha"
chk_contains "…the prior session it will resume" "$out" "PRIOR SESSION: $P_NEW"
chk_contains "…model pin on the command" "$out" "--model claude-opus-5-5"
chk_contains "…--keep-old for the supervisor" "$out" "--keep-old"
chk_contains "…--resume-sid, never --sid" "$out" "--resume-sid $P_NEW"
chk_contains "…remote control named after the seat" "$out" "--remote-control super"
chk_contains "…says DRY RUN" "$out" "DRY RUN"
chk "…nothing executed" "$(grep -c 'argv=' "$CALLS")" 0
# 9.5 not due -> --act refuses (plan still prints); --force overrides the trigger only
printf '%s\t80\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"
out="$(supervisor_handover --act 2>&1)"; rc=$?
chk "--act below the threshold -> REFUSED" "$rc" 3
chk_contains "…saying not due" "$out" "not due"
chk "…nothing executed" "$(grep -c 'argv=' "$CALLS")" 0
# 9.6 ACT: the prior resumes on alpha with the pin + remote control; the OLD session is NOT stopped; the record retires it as kept; the vice is mailed; the old poller reads superseded
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; : > "$CALLS"
out="$(supervisor_handover --act --handover-wait 0 2>&1)"; rc=$?
chk "--act succeeds" "$rc" 0
chk "…the OLD session was NOT stopped" "$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 0
chk "…exactly one resume, of the PRIOR session" "$(grep -c -- "--bg --resume $P_NEW" "$CALLS")" 1
chk_contains "…with the pinned model" "$(grep -- "--resume $P_NEW" "$CALLS")" "--model claude-opus-5-5"
chk_contains "…and remote control under the seat name" "$(grep -- "--resume $P_NEW" "$CALLS")" "--remote-control super"
chk_contains "…launched from the prior transcript's own directory" "$(grep -- "--resume $P_NEW" "$CALLS")" "cwd=$TEST_CWD"
chk "…the record now names the prior session on alpha" "$(seat_record_read super session_id)/$(seat_record_read super account)" "$P_NEW/alpha"
chk_contains "…the old id is retired as KEPT" "$(cat "$(SEAT_RECORD_FILE super)")" "retired_sessions	kept:$SUPSID@"
chk "…seat_session_retired sees it" "$(seat_session_retired super "$SUPSID" && echo yes || echo no)" "yes"
chk "…the new id is not retired" "$(seat_session_retired super "$P_NEW" && echo yes || echo no)" "no"
chk "…the vice got the DONE mail" "$(grep -l 'WEEKLY-CAP MOVE DONE' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
chk_contains "…which says the old one is kept alive off aimail" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md)" "kept alive off aimail"
source "$REPO/lib/poller.sh" 2>/dev/null || true
chk "the OLD session's poller reads SUPERSEDED" "$(CLAUDE_CODE_SESSION_ID=$SUPSID poller_superseded super && echo yes || echo no)" "yes"
chk "…the NEW session's poller does not" "$(CLAUDE_CODE_SESSION_ID=$P_NEW poller_superseded super && echo yes || echo no)" "no"
chk "…a poller with no session id in its env is never superseded" "$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID bash -c 'source "'"$REPO"'/lib/core.sh"; source "'"$REPO"'/lib/poller.sh"; poller_superseded super && echo yes || echo no' 2>/dev/null)" "no"
# 9.7 an ORDINARY seat's weekly-cap move: the old session IS stopped, no keep-old, no remote control, pin = sonnet
sup_reset; : > "$CALLS"; rm -f "$(SEAT_SESSIONS_FILE vice)"
seat_record_write vice acct-b "$ACCT_B" "$PRIOR" model-v boot "" "" "$TEST_CWD" >/dev/null 2>&1
write_agents "$ACCT_B" "$PRIOR"; write_instance vice "$PRIOR" acct-b
V_PRIOR="bbbbbbb1-0000-0000-0000-000000000001"; mkdir -p "$ACCT_A/projects/$SLUGA"; printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"cd /x && bash bin/aimail poll-persistent vice"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$V_PRIOR.jsonl"
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; printf '%s\t40\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"
out="$(seat_budget_move --seat vice 2>&1)"; rc=$?
chk "ordinary seat: plan prints" "$rc" 0
chk_contains "…pin sonnet" "$out" "--model claude-sonnet-5"
chk "…no --keep-old" "$(grep -c -- '--keep-old' <<<"$out")" 0
chk "…no remote control" "$(grep -c -- '--remote-control' <<<"$out")" 0
chk_contains "…old session stopped by seat migrate" "$out" "stopped by seat migrate"
# 9.8 the announce: the capped account's seats, supervisor first, ONE mail per episode; clears when the reading drops. Kill switch AIMAIL_HANDOVER_ACT=0 honoured: nothing executed
export AIMAIL_HANDOVER_ACT=0
sup_reset; rm -f "$AIMAIL_ROOT/state/handover_announced_"* "$(SEAT_SESSIONS_FILE super)"
seat_record_write vice acct-b "$ACCT_B" "$PRIOR" model-v boot "" "" "$TEST_CWD" >/dev/null 2>&1
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; printf '%s\t40\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"
supervisor_handover_due_announce >/dev/null 2>&1
chk "announce: ONE mail to the vice" "$(grep -l 'WEEKLY CAP on acct-b' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
chk_contains "…listing the supervisor first, then the vice" "$(grep -h '^# WEEKLY CAP' "$AIMAIL_ROOT/mail/vice"/*.md)" "(super vice)"
chk_contains "…with a plan section per seat" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md)" "## vice"
supervisor_handover_due_announce >/dev/null 2>&1
chk "…a second tick does not mail again" "$(grep -l 'WEEKLY CAP on acct-b' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
chk "…nothing executed by the announce (kill switch AIMAIL_HANDOVER_ACT=0)" "$(grep -c 'argv=--bg' "$CALLS")" 0
chk_contains "…and the mail says the vice runs it" "$(cat "$AIMAIL_ROOT/mail/vice"/*.md)" "AIMAIL_HANDOVER_ACT=0: the supervisor move is NOT executed"
printf '%s\t50\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; supervisor_handover_due_announce >/dev/null 2>&1
chk "…the marker clears once the reading drops" "$(ls "$AIMAIL_ROOT/state/handover_announced_acct-b" 2>/dev/null | wc -l)" 0
# 9.9 a SAVED launch spec on the target pins another model: refused by default; --repin-saved-model rewrites it (backup kept), names the supervisor's remote control, then resumes FLAGLESS
sup_reset; : > "$CALLS"; rm -f "$(SEAT_SESSIONS_FILE super)"
mkdir -p "$ACCT_A/projects/$SLUGA" "$ACCT_A/jobs/${P_NEW:0:8}"; printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_NEW.jsonl"
printf '{"respawnFlags":["--remote-control","--allow-dangerously-skip-permissions","--permission-mode","bypassPermissions","--model","m-old"],"template":"bg","state":"stopped"}' > "$ACCT_A/jobs/${P_NEW:0:8}/state.json"
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; printf '%s\t40\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"
write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b
out="$("$AIMAIL" seat migrate super alpha --resume-sid "$P_NEW" --model claude-opus-5-5 --cwd "$TEST_CWD" --from vice --handover-wait 0 --owner-approved "the owner 09:00" 2>&1)"; rc=$?
chk "saved spec pins m-old, run wants opus, no repin flag -> REFUSED" "$rc" 3
chk_contains "…naming --repin-saved-model" "$out" "--repin-saved-model"
chk "…nothing launched" "$(grep -c 'argv=--bg' "$CALLS")" 0
out="$(supervisor_handover --act --handover-wait 0 2>&1)"; rc=$?
chk "the handover (--repin-saved-model) succeeds" "$rc" 0
chk "…exactly one resume, FLAGLESS (no --model on the command line)" "$(grep -- "--bg --resume $P_NEW" "$CALLS" | grep -vc -- '--model')" 1
# (the fake CLI rewrites jobs/<short>/state.json on every resume, as the real scheduler does, so the repin is read from the run's own log line, and the backup proves the order: repin, then resume)
chk_contains "…the saved spec was repinned m-old -> opus with the remote control named after the seat" "$out" "saved spec repinned: model m-old -> claude-opus-5-5, --remote-control super"
chk "…the backup holds the OLD model" "$(python3 -c "import json,glob; f=json.load(open(glob.glob('$ACCT_A/jobs/${P_NEW:0:8}/state.json.bak-*')[0]))['respawnFlags']; print(f[f.index('--model')+1])")" "m-old"
chk "…a backup of the spec was kept" "$(ls "$ACCT_A/jobs/${P_NEW:0:8}/"state.json.bak-* 2>/dev/null | wc -l)" 1
chk "…the record follows the prior session with the pinned model" "$(seat_record_read super session_id)/$(seat_record_read super model)" "$P_NEW/claude-opus-5-5"
# 9.10 DEFAULT (no switch set): the announce tick EXECUTES the supervisor's keep-old handover right away (the owner 09:35: no dark switches)
unset AIMAIL_HANDOVER_ACT
sup_reset; rm -f "$AIMAIL_ROOT/state/handover_announced_"* "$(SEAT_SESSIONS_FILE super)"; : > "$CALLS"
mkdir -p "$ACCT_A/projects/$SLUGA"; printf '{"type":"user","message":{"content":"x"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","input":{"command":"bash bin/aimail poll-persistent super"}}]}}\n' > "$ACCT_A/projects/$SLUGA/$P_NEW.jsonl"
printf '%s\t96\t\n' "$(now_epoch)" > "$(WEEKLY_FILE acct-b)"; printf '%s\t40\t\n' "$(now_epoch)" > "$(WEEKLY_FILE alpha)"
write_agents "$ACCT_B" "$SUPSID"; write_instance super "$SUPSID" acct-b
AIMAIL_HANDOVER_WAIT_S=0 supervisor_handover_due_announce >/dev/null 2>&1
chk "default: the announce mail went out" "$(grep -l 'WEEKLY CAP on acct-b' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
chk_contains "…and says the move is EXECUTED by this tick" "$(grep -h 'EXECUTED by this tick' "$AIMAIL_ROOT/mail/vice"/*.md | head -1)" "kill switch: AIMAIL_HANDOVER_ACT=0"
chk "…the prior session WAS resumed (the act ran)" "$(grep -c -- "--bg --resume $P_NEW" "$CALLS")" 1
chk "…the OLD supervisor session was NOT stopped" "$(grep -c "argv=stop ${SUPSID:0:8}" "$CALLS")" 0
chk "…the record follows the prior session" "$(seat_record_read super session_id)" "$P_NEW"
chk "…the DONE mail reached the vice" "$(grep -l 'WEEKLY-CAP MOVE DONE' "$AIMAIL_ROOT/mail/vice"/*.md 2>/dev/null | wc -l)" 1
printf '\n═══ %d/%d passed ═══\n' "$PASS" $((PASS+FAIL))
if (( FAIL )); then printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
