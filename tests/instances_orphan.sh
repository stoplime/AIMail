#!/usr/bin/env bash
# tests/instances_orphan.sh — the M1 orphan-poller sweep (2026-09-20, fable).
#
# WHY: `claude stop <id>` kills a Claude session, but the backgrounded
# `aimail poll <seat>` it armed survives — still beating, still able to
# deliver/ack real mail with no AI behind it (assistant, three times in one
# migration night). Its instance file never goes stale, so it read ARMED.
# The fix: at arm time, kill an instance whose sid is in NO account's
# `claude agents --json` list; mark such rows ORPHAN? in `aimail instances`.
#
# EVIDENCE RULES (tests/run.sh ①-⑤): every rejection arm has a positive control
# in the same shape; the arm is shown firing (a real pid dies) before the
# controls (real pids survive); the denominator is printed. The live-session
# list is stubbed through AIMAIL_LIVE_SIDS_OVERRIDE — no real `claude` binary
# is ever consulted, no real poller can be touched (AIMAIL_ROOT is a temp dir).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-orphan-test.XXXXXX")"
export AIMAIL_NO_NETWORK=1
export CLAUDE_CODE_SESSION_ID="mysid-0000-1111"

# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/registry.sh
source "$REPO/lib/registry.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"
ensure_dirs

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  \xe2\x9c\x85 %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  \xe2\x9b\x94 %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
chk_contains(){ case "$2" in *"$3"*) chk "$1" 1 1 ;; *) chk "$1" "MISSING[$3]" "$2" ;; esac; }

declare -a SPAWNED_PIDS=()
cleanup() {
  local p; for p in "${SPAWNED_PIDS[@]:-}"; do
    [[ -n "$p" ]] || continue
    pkill -9 -P "$p" 2>/dev/null || true
    kill -9 "$p" 2>/dev/null || true
  done
  rm -rf "$AIMAIL_ROOT"
}
trap cleanup EXIT

SEAT=orphanseat
# write_instance <sid> <pid> [account] — the exact file instance_register writes
write_instance() {
  local sid="$1" pid="$2" acct="${3:-testacct}" d; d="$(INSTANCE_DIR "$SEAT")"; mkdir -p "$d"
  { printf 'sid\t%s\n' "$sid"; printf 'account\t%s\n' "$acct"; printf 'host\t%s\n' testhost
    printf 'pid\t%s\n' "$pid"; printf 'armed_at\t%s\n' "$(now_epoch)"; printf 'last_beat\t%s\n' "$(now_epoch)"; } > "$d/$sid"
}
# ⚠ spawn runs in the MAIN shell, never inside `$(...)`: a background child started
#   inside a command substitution keeps the substitution waiting (measured: the first
#   two drafts of this file hung there even with the child's fds detached), and the
#   SPAWNED_PIDS bookkeeping done in that subshell is lost to the EXIT trap.
#   Usage: spawn; P=$LAST_PID
LAST_PID=""
# The spawned fixture carries a POLLER-SHAPED command line (`exec -a`), because the
# sweep now fingerprints /proc/<pid>/cmdline for `aimail … poll` before any kill
# (pid-reuse guard, code-review 2026-09-21). spawn_plain is the "pid reused by
# something else" control: a bare sleep under the same instance file's pid.
spawn() { bash -c 'exec -a "bash /tmp/aimail-poll.test/bin/aimail poll orphanseat" sleep 300' >/dev/null 2>&1 & LAST_PID=$!; SPAWNED_PIDS+=("$LAST_PID"); }
spawn_plain() { sleep 300 >/dev/null 2>&1 & LAST_PID=$!; SPAWNED_PIDS+=("$LAST_PID"); }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }

echo "── ARM ①: the sweep FIRES — a live pid whose sid is in no account's list is killed and its file removed ──"
spawn; P_ORPHAN=$LAST_PID; spawn; P_TWIN=$LAST_PID; spawn; P_SOLO=$LAST_PID; spawn; P_MINE=$LAST_PID
write_instance orphan-sid-aaaa "$P_ORPHAN" research
write_instance twin-sid-bbbb "$P_TWIN" work
write_instance solo "$P_SOLO" legacy
write_instance "$CLAUDE_CODE_SESSION_ID" "$P_MINE" work
write_instance deadpid-sid-cccc 4194303 work        # a pid nothing runs under
out="$(AIMAIL_LIVE_SIDS_OVERRIDE="twin-sid-bbbb some-other-live-sid" instance_sweep_orphans "$SEAT" 2>&1)"
chk "orphan pid is DEAD after the sweep" "$(alive "$P_ORPHAN")" dead
chk "orphan's instance file removed" "$([[ -f "$(INSTANCE_DIR "$SEAT")/orphan-sid-aaaa" ]] && echo present || echo gone)" gone
chk_contains "sweep printed the ORPHAN KILLED line naming sid@account and pid" "$out" "ORPHAN KILLED: '$SEAT' instance orphan-s@research pid $P_ORPHAN"
echo "── CONTROLS ②③: the nearest valid inputs are NOT touched ──"
chk "live TWIN (sid listed) pid still alive" "$(alive "$P_TWIN")" alive
chk "live TWIN file kept" "$([[ -f "$(INSTANCE_DIR "$SEAT")/twin-sid-bbbb" ]] && echo present || echo gone)" present
chk "legacy 'solo' pid still alive (never judged)" "$(alive "$P_SOLO")" alive
chk "legacy 'solo' file kept" "$([[ -f "$(INSTANCE_DIR "$SEAT")/solo" ]] && echo present || echo gone)" present
chk "my OWN sid's pid still alive (skipped)" "$(alive "$P_MINE")" alive
chk "dead-pid file pruned without a kill attempt" "$([[ -f "$(INSTANCE_DIR "$SEAT")/deadpid-sid-cccc" ]] && echo present || echo gone)" gone
chk_contains "prune line printed for the dead pid" "$out" "pruned '$SEAT' instance deadpid-"

echo "── PID REUSE: a recorded pid that no longer runs an aimail poller is pruned, never killed ──"
spawn_plain; P_REUSED=$LAST_PID; write_instance reused-sid-ffff "$P_REUSED" research
out="$(AIMAIL_LIVE_SIDS_OVERRIDE="twin-sid-bbbb" instance_sweep_orphans "$SEAT" 2>&1)"
chk "the non-poller process under the stale file's pid is still ALIVE" "$(alive "$P_REUSED")" alive
chk "its stale instance file was pruned" "$([[ -f "$(INSTANCE_DIR "$SEAT")/reused-sid-ffff" ]] && echo present || echo gone)" gone
chk_contains "the sweep names the reuse and says nothing was killed" "$out" "reused by another process; nothing killed"
chk "positive control: the fingerprint accepts a real poller-shaped cmdline" "$(_instance_pid_is_poller "$P_TWIN" && echo yes || echo no)" yes
chk "…and rejects a plain sleep" "$(_instance_pid_is_poller "$P_REUSED" && echo yes || echo no)" no

echo "── UNKNOWN never licenses a kill ──"
spawn; P_ORPHAN2=$LAST_PID; write_instance orphan-sid-dddd "$P_ORPHAN2" research
out="$(AIMAIL_LIVE_SIDS_OVERRIDE=UNKNOWN instance_sweep_orphans "$SEAT" 2>&1)"
chk "with an UNKNOWN live list the would-be orphan pid survives" "$(alive "$P_ORPHAN2")" alive
chk "its file is kept" "$([[ -f "$(INSTANCE_DIR "$SEAT")/orphan-sid-dddd" ]] && echo present || echo gone)" present
chk_contains "the sweep says so, out loud" "$out" "live-session list is UNKNOWN"
out="$(AIMAIL_LIVE_SIDS_OVERRIDE= instance_sweep_orphans "$SEAT" 2>&1)"   # NO_NETWORK=1 and no override → unknown
chk "AIMAIL_NO_NETWORK=1 with no override is also UNKNOWN: pid survives" "$(alive "$P_ORPHAN2")" alive
echo "── positive control for UNKNOWN: the same candidate DOES die once the list is known ──"
out="$(AIMAIL_LIVE_SIDS_OVERRIDE="twin-sid-bbbb" instance_sweep_orphans "$SEAT" 2>&1)"
chk "known list → the candidate is killed" "$(alive "$P_ORPHAN2")" dead

echo "── instances_list marks ORPHAN? (flag only, no kill) ──"
spawn; P_ORPHAN3=$LAST_PID; write_instance orphan-sid-eeee "$P_ORPHAN3" research
out="$(AIMAIL_LIVE_SIDS_OVERRIDE="twin-sid-bbbb" instances_list "$SEAT" 2>&1)"
chk_contains "orphan row reads ORPHAN?" "$out" "$SEAT@orphan-s/research	ORPHAN?"
chk_contains "twin row reads ARMED" "$out" "$SEAT@twin-sid/work	ARMED"
chk_contains "solo row reads ARMED (never judged)" "$out" "$SEAT@solo/legacy	ARMED"
chk "listing did NOT kill the orphan (flag only)" "$(alive "$P_ORPHAN3")" alive
out="$(AIMAIL_INSTANCES_LIVE_CHECK=0 AIMAIL_LIVE_SIDS_OVERRIDE="twin-sid-bbbb" instances_list "$SEAT" 2>&1)"
chk_contains "with the live check OFF (fleet_report's fast path) the same row reads plain ARMED" "$out" "$SEAT@orphan-s/research	ARMED"
out="$(AIMAIL_LIVE_SIDS_OVERRIDE=UNKNOWN instances_list "$SEAT" 2>&1)"
chk_contains "UNKNOWN live list → no ORPHAN? mark is invented" "$out" "$SEAT@orphan-s/research	ARMED"

echo "── the arm path calls the sweep, before hb_start (static read of lib/poller.sh — the loop itself is not run here) ──"
n_sweep="$(grep -n 'instance_sweep_orphans "\$seat"' "$REPO/lib/poller.sh" | head -1 | cut -d: -f1)"
n_hb="$(grep -n '^  hb_start "\$seat"' "$REPO/lib/poller.sh" | head -1 | cut -d: -f1)"
chk "poller.sh calls instance_sweep_orphans exactly once" "$(grep -c 'instance_sweep_orphans "\$seat"' "$REPO/lib/poller.sh")" 1
chk "…and BEFORE hb_start" "$([[ -n "$n_sweep" && -n "$n_hb" && "$n_sweep" -lt "$n_hb" ]] && echo yes || echo no)" yes
chk "fleet_report's per-instance block runs the fast path (AIMAIL_INSTANCES_LIVE_CHECK=0)" "$(grep -c 'AIMAIL_INSTANCES_LIVE_CHECK=0 instances_list "\$seat"' "$REPO/lib/fleet.sh")" 1

TOTAL=$((PASS+FAIL))
printf '\n%s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TOTAL"
if (( FAIL )); then printf '\nFAILURES:\n'; printf '  • %s\n' "${FAILURES[@]}"; exit 1; fi
