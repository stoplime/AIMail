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

# ⛔⛔ AND THE SECOND HALF, WHICH TOOK UNTIL 2026-09-06 TO NAME: EVERY STATE
#    ABOVE IS A PROPERTY OF A SEAT NAME, NOT OF A SESSION. There is ONE
#    `<seat>.hb` per seat, so a seat with four concurrent sessions gets one
#    heartbeat, one row and one verdict — and a seat whose only session has
#    exited is indistinguishable from one whose session is forty minutes into a
#    build. STALLED means, precisely, "a poller exited with a reason and nothing
#    re-armed it". That is EXACTLY what a healthy session heads-down on a long
#    task produces, every time, and it is also what a session that died
#    produces. The heartbeat cannot separate them because nothing in it is keyed
#    to a session.
#
#    MEASURED 2026-09-06: this file reported four seats STALLED with mail piling
#    up while all four were working normally, at the same moment the project's
#    Stop-hook fork reported 19 concurrent sessions that did not exist. A human
#    was told the fleet was half dead. It was not.
#
# ⭐ THE THIRD EVENT SOURCE, added for exactly this: `lib/sessions.sh` /
#    `session_liveness.py` measure liveness PER SESSION ID — the session's own
#    claude process, its own transcript, and the pollers that actually descend
#    from it. This file now asks that question before it renders a verdict, so
#    "the poller is down" and "nobody is home" stop being the same sentence.
# ⚠ IT IS AN ENRICHMENT, NEVER A DEPENDENCY. If the classifier cannot run (no
#   python3, an older checkout, an unreadable /proc), every verdict below falls
#   back verbatim to the heartbeat-only wording it has always had. A dashboard
#   that goes blank because its newest signal is unavailable is worse than one
#   that keeps its old answer and says which signal it lacked.

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

# ─── M1 instance registry (twin-seat coordination, increment 0) ──────────────
# docs/twin_seat_coordination_design_2026-09-18.md: one seat NAME is one
# address; a "twin" is a second LIVE INSTANCE of that seat (e.g. two accounts
# both running `assistant` at once, the real 2026-09-20 case this pays for
# immediately). Every hb_* file/reader above is per-SEAT and UNCHANGED by this
# block — this is purely additive: a new registry, keyed by session id, that
# makes an already-possible situation VISIBLE. N=1 (the common case, no twin)
# writes one extra small file nobody reads by default; nothing about delivery,
# ack, or poller_state's own verdict changes.
INSTANCE_DIR() { echo "$STATE_DIR/instances/$1"; }
# A legacy poller with no session id in its environment registers as its own
# stable pseudo-sid "solo" (design doc §3, M1) rather than colliding on a
# blank filename or refusing to register at all.
_instance_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-solo}}"; }
INSTANCE_FILE() { echo "$(INSTANCE_DIR "$1")/$(_instance_sid)"; }

instance_read() {
  local f="$1" key="$2"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v k="$key" '$1==k{print $2; found=1} END{exit !found}' "$f"
}

# Written at poll/poll-persistent arm time. `account_id` (budget.sh) is called
# defensively — this file must never fail to register just because budget.sh
# happens not to be sourced yet in some caller.
instance_register() {
  local seat="$1" now f tmp; f="$(INSTANCE_FILE "$seat")"; now="$(now_epoch)"
  mkdir -p "$(INSTANCE_DIR "$seat")"
  tmp="$(mktemp "$(INSTANCE_DIR "$seat")/.inst.XXXXXX")"
  { printf 'sid\t%s\n' "$(_instance_sid)"
    printf 'account\t%s\n' "$(command -v account_id >/dev/null 2>&1 && account_id 2>/dev/null || echo unknown)"
    printf 'host\t%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'pid\t%s\n' "$$"
    printf 'armed_at\t%s\n' "$now"
    printf 'last_beat\t%s\n' "$now"
  } > "$tmp"
  mv -f "$tmp" "$f"
}
# Refreshed on each poller beat. Self-heals if the file was pruned as stale
# out from under a still-live poller (instances_list below removes files past
# the same staleness window poller_state uses) rather than beating a file that
# no longer exists.
instance_beat() {
  local seat="$1" f; f="$(INSTANCE_FILE "$seat")"
  [[ -f "$f" ]] || { instance_register "$seat"; return 0; }
  local tmp; tmp="$(mktemp "$(INSTANCE_DIR "$seat")/.inst.XXXXXX")"
  { awk -F'\t' '$1!="last_beat"' "$f"; printf 'last_beat\t%s\n' "$(now_epoch)"; } > "$tmp"
  mv -f "$tmp" "$f"
}
# Removed on clean exit (wired via an EXIT trap in poller.sh, so every exit
# path — mail/ramp/heartbeat/signal — clears it the same way, without needing
# to touch each individual hb_exit call site).
instance_deregister() { rm -f "$(INSTANCE_FILE "$1")" 2>/dev/null || true; }

# ─── Orphan pollers (M1 gap, 2026-09-20) ─────────────────────────────────────
# `claude stop <id>` kills a session; the backgrounded `aimail poll <seat>` it
# armed survives, beats, and can deliver/ack real mail with no AI behind it
# (assistant hit it three times migrating seats between accounts). Its instance
# file never goes stale, so `instances`/`fleet` read it as a normal ARMED row.
# ⭐ MEASURED 2026-09-20 (fable, session 79782338): a poller's parent chain is
#   `bash -c` → `claude bg-spare` → `claude bg-pty-host` → the claude node
#   process → systemd --user; the daemon's spare processes are not the session,
#   so "is my PPID alive" is NOT a reliable orphan test. `claude agents --json`
#   (per account CLAUDE_CONFIG_DIR) DOES list every live session — background
#   AND interactive kinds — so the orphan test is: "this instance's sid appears
#   in NO configured account's agents list".
# ⛔ UNKNOWN NEVER LICENSES A KILL: if any account dir in the pool fails to
#   answer, the whole reading is unknown and the sweep touches nothing.

# _instance_account_dirs — the account pool's config dirs. AIMAIL_FLEET_ACCOUNTS
# if set (the same shape _watchdog_accounts / budget_pool use), else every
# configured account on this machine regardless of live seats (2026-09-25,
# _configured_account_pool -- replacing an earlier seat-only fallback that
# shared the same gap budget_pool/_pl_accounts had), else the ambient account.
_instance_account_dirs_raw() {
  # budget.sh owns ACCOUNT_CONFIG_DIR / account_id / _autopilot_seat_groups; it
  # sources this file itself, so the dependency runs lazily here, not at top.
  source "${BASH_SOURCE[0]%/*}/budget.sh" 2>/dev/null || true
  local a
  if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
    for a in $AIMAIL_FLEET_ACCOUNTS; do ACCOUNT_CONFIG_DIR "$a"; done
    return 0
  fi
  local pool_found=0
  if command -v _configured_account_pool >/dev/null 2>&1; then
    while IFS= read -r a; do
      [[ -n "$a" ]] && { ACCOUNT_CONFIG_DIR "$a"; pool_found=1; }
    done < <(_configured_account_pool 2>/dev/null || true)
  fi
  (( pool_found )) && return 0
  local line acct found=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    acct="$(cut -f2 <<<"$line")"
    [[ -n "$acct" ]] && { ACCOUNT_CONFIG_DIR "$acct"; found=1; }
  done < <(_autopilot_seat_groups 2>/dev/null || true)
  (( found )) || ACCOUNT_CONFIG_DIR "$(account_id)"
}

# _dedupe_by_realpath — print each input line once, keyed by its RESOLVED real path (falls back
# to the line itself when realpath can't resolve it, e.g. a not-yet-created dir); first
# occurrence wins, original order preserved. Its own helper, not inlined, so any other
# multi-account enumerator can reuse the same fix.
_dedupe_by_realpath() {
  local line key
  local -A seen=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="$(realpath -m -- "$line" 2>/dev/null || echo "$line")"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen["$key"]=1
    printf '%s\n' "$line"
  done
}

# _instance_account_dirs — _instance_account_dirs_raw, deduped by REAL path.
# ⛔⛔ 2026-09-25 (assistant mail 20260925T083355, "2 SESSIONS" false-alarm wave on freshly
#   migrated r2 seats): `~/.claude` is a SYMLINK (to `~/.claude-r2` on this machine), and account
#   names are pure labels -- nothing before this fix ever asked whether two different names
#   (e.g. "default" -> $HOME/.claude and "r2" -> $HOME/.claude-r2) resolve to the SAME real
#   directory. Every caller below (n_live/n_work in `_fleet_load_sessions`'s
#   `by_seat_state` counts, via sessions.sh's `_sessions_all_account_projects_dirs`, and the
#   two `_instance_account_dirs` callers in this file) then queried that one real directory
#   TWICE under two different labels and counted its one live session as two -- a real seat
#   with exactly one live session read as "2 SESSIONS answering this seat" fleet-wide. The
#   machine-local mitigation (pinning AIMAIL_FLEET_ACCOUNTS to a name list that happens to avoid
#   the symlink alias) papers over one machine's naming; deduping the RESOLVED path here fixes
#   it structurally, for any account-naming shape, on any machine.
_instance_account_dirs() {
  _instance_account_dirs_raw | _dedupe_by_realpath
}

# _instance_live_sids — prints every session id `claude agents --json` lists,
# ALL kinds, across every account dir. Exit 0 only when EVERY dir answered;
# otherwise exit 1 = UNKNOWN. AIMAIL_LIVE_SIDS_OVERRIDE (whitespace-separated
# sids, or the literal UNKNOWN) stands in for the CLI under test and under
# AIMAIL_NO_NETWORK — the tests never touch a real `claude` binary.
_instance_live_sids() {
  if [[ -n "${AIMAIL_LIVE_SIDS_OVERRIDE:-}" ]]; then
    [[ "$AIMAIL_LIVE_SIDS_OVERRIDE" == "UNKNOWN" ]] && return 1
    printf '%s\n' $AIMAIL_LIVE_SIDS_OVERRIDE; return 0
  fi
  [[ "${AIMAIL_NO_NETWORK:-}" == "1" ]] && return 1
  command -v claude >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local dir json n_dirs=0 n_ok=0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    n_dirs=$((n_dirs+1))
    [[ -d "$dir" ]] || continue
    json="$(CLAUDE_CONFIG_DIR="$dir" timeout "${AIMAIL_AGENTS_TIMEOUT_SEC:-30}" claude agents --json 2>/dev/null)" || continue
    [[ -n "$json" ]] || continue
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for d in data:
    sid = d.get("sessionId", "") if isinstance(d, dict) else ""
    if sid:
        print(sid)
' || continue
    n_ok=$((n_ok+1))
  done < <(_instance_account_dirs)
  (( n_dirs > 0 && n_ok == n_dirs ))
}

# _instance_pid_is_poller <pid> — true iff the process's OWN command line is an
# `aimail … poll` / `poll-persistent` invocation (read from /proc, NUL-joined).
# The fingerprint the sweep requires before it kills anything: a pid recorded in
# an instance file proves nothing about what runs under that number today.
_instance_pid_is_poller() {
  local pid="$1" cmd
  [[ -r "/proc/$pid/cmdline" ]] || return 1
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  [[ "$cmd" == *aimail*poll* ]]
}

# instance_sweep_orphans <seat> — run ONCE at arm time, BEFORE hb_start and
# instance_register (so a killed orphan's own TERM trap writes its exit record
# into the OLD heartbeat file, which hb_start then replaces wholesale). For each
# other instance of this seat: skip my own sid and the legacy `solo`; prune a
# file whose pid is gone; otherwise, if the live-session list is KNOWN and does
# not contain the sid, TERM the pid (KILL after ~3 s), remove the file, print
# one line. A sid that IS listed is a live twin and is never touched.
instance_sweep_orphans() {
  local seat="$1" mysid; mysid="$(_instance_sid)"
  local dir; dir="$(INSTANCE_DIR "$seat")"
  [[ -d "$dir" ]] || return 0
  local f sid pid account
  local -a cand=()
  for f in "$dir"/*; do
    [[ -f "$f" ]] || continue
    case "$(basename "$f")" in .inst.*) continue ;; esac
    sid="$(basename "$f")"
    [[ "$sid" == "$mysid" || "$sid" == "solo" ]] && continue
    pid="$(instance_read "$f" pid || echo '')"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
      echo "instance sweep: pruned '$seat' instance ${sid:0:8} (pid ${pid:-?} is not running)"
      continue
    fi
    # ⛔ PID REUSE (code-review's residual risk on the first gate, 2026-09-21):
    #   the orphan may have died on its own and left its file; by now that pid
    #   can belong to anything. Kill only a process whose own command line is
    #   an `aimail … poll` invocation; anything else is "already gone" — prune.
    if ! _instance_pid_is_poller "$pid"; then
      rm -f "$f"
      echo "instance sweep: pruned '$seat' instance ${sid:0:8} (pid $pid is not an aimail poller any more — reused by another process; nothing killed)"
      continue
    fi
    account="$(instance_read "$f" account || echo unknown)"
    cand+=("$sid"$'\t'"$pid"$'\t'"$account"$'\t'"$f")
  done
  (( ${#cand[@]} )) || return 0
  local live
  if ! live="$(_instance_live_sids)"; then
    echo "⚠ instance sweep: ${#cand[@]} other live instance(s) of '$seat', but the live-session list is UNKNOWN (an account did not answer) — nothing killed; see \`aimail instances $seat\`"
    return 0
  fi
  local c i
  for c in "${cand[@]}"; do
    IFS=$'\t' read -r sid pid account f <<<"$c"
    if grep -qxF -- "$sid" <<<"$live"; then continue; fi
    kill -TERM "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
    rm -f "$f"
    echo "⚠ ORPHAN KILLED: '$seat' instance ${sid:0:8}@$account pid $pid — its session is in no account's \`claude agents\` list (the poller outlived its own Claude session)"
  done
}

# `aimail instances <seat>` — M1's own discovery primitive (design doc §3/§6):
# without this, no instance knows a twin exists at all. "Live" uses the same
# staleness window poller_state() already judges ARMED/STALLED by
# (interval*6+30); a stale file is PRUNED, not merely hidden, so a dead twin's
# registration does not linger forever and this stays an honest live-set, not
# a historical log — the same "a dead twin never blocks a live one" principle
# the design doc names for M3, applied here to visibility instead of acking.
instances_list() {
  local seat="$1" dir; dir="$(INSTANCE_DIR "$seat")"
  local interval="${AIMAIL_POLL_INTERVAL:-5}" limit now found=0
  limit=$(( interval * 6 + 30 ))
  now="$(now_epoch)"
  local -a rows=()
  local need_live=0
  if [[ -d "$dir" ]]; then
    local f sid account pid last_beat armed_at
    for f in "$dir"/*; do
      [[ -f "$f" ]] || continue
      case "$(basename "$f")" in .inst.*) continue ;; esac
      sid="$(basename "$f")"
      account="$(instance_read "$f" account || echo unknown)"
      pid="$(instance_read "$f" pid || echo '')"
      last_beat="$(instance_read "$f" last_beat || echo 0)"
      armed_at="$(instance_read "$f" armed_at || echo 0)"
      if (( now - last_beat > limit )); then
        rm -f "$f"
        continue
      fi
      found=1
      [[ "$sid" != "solo" ]] && need_live=1
      rows+=("$sid"$'\t'"$account"$'\t'"$pid"$'\t'"$last_beat"$'\t'"$armed_at")
    done
  fi
  # ⭐ ORPHAN? mark (M1 gap, 2026-09-20): a row whose sid is in no account's
  #   `claude agents` list is a poller that outlived its session. Flag only —
  #   the kill lives in instance_sweep_orphans, at the next arm. The live
  #   check is one CLI call per account dir, so callers that must stay fast
  #   (fleet_report, every seat) pass AIMAIL_INSTANCES_LIVE_CHECK=0 and get
  #   the plain ARMED rows they always had.
  local live="" live_known=0
  if (( found && need_live )) && [[ "${AIMAIL_INSTANCES_LIVE_CHECK:-1}" != "0" ]]; then
    if live="$(_instance_live_sids)"; then live_known=1; fi
  fi
  local r state
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r sid account pid last_beat armed_at <<<"$r"
    state=ARMED
    if (( live_known )) && [[ "$sid" != "solo" ]] && ! grep -qxF -- "$sid" <<<"$live"; then
      state='ORPHAN?'
    fi
    printf '%s@%s/%s\t%s\tpid %s, last beat %ss ago, armed %sm ago%s\n' \
      "$seat" "${sid:0:8}" "$account" "$state" "$pid" "$(( now - last_beat ))" "$(( (now - armed_at) / 60 ))" \
      "$([[ "$state" == 'ORPHAN?' ]] && printf ' — session %s is in no account'"'"'s `claude agents` list; the next `aimail poll %s` kills it' "${sid:0:8}" "$seat")"
  done
  (( found )) || echo "no live instances recorded for '$seat' (N=1/legacy pollers are invisible here until their next beat writes state/instances/$seat/solo)"
}

# ─── poller_state <seat> — ONE implementation, seven distinct states ──────────
# Prints: STATE<TAB>detail
#
# ⭐ Seven states, where a process count had two. Every extra state is one the
#    predecessor could not see and therefore misreported:
#      ARMED       heartbeat fresh, process alive            → reachable (OR a stale exit
#                                                               record has since been superseded by
#                                                               a fresh beat — see below, `alive` is
#                                                               not required to agree in that case)
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

  local limit=$(( interval * 6 + 30 ))

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

  # ⛔⛔ SUPERSEDED EXIT — an exit record OLDER than the last beat means the exit was
  #   SUPERSEDED: something has beaten since it was written. `alive`'s `kill -0`
  #   cannot be trusted as the tiebreaker here, because the `pid` this heartbeat
  #   file recorded may not belong to whatever is now doing the beating (a stale
  #   field from an earlier `hb_start`, never rewritten by a later `hb_beat`,
  #   which only ever touches the `beat` key). MEASURED, the exact case that
  #   broke this: `exit_at=1787500677 beat=1787500884` (beat 207s LATER)
  #   alongside a CONFIRMED-LIVE poller process — `alive` read 0 on the recorded
  #   pid, and the old code fell straight through to CRASHED while the seat was
  #   working, re-firing the sweep alarm on every subsequent check.
  # ⇒ Scoped narrowly to "an exit_at exists AND is older than beat" — NOT a
  #   blanket "trust any fresh beat over `alive`" — so a seat with no exit
  #   record at all (a real crash: it never wrote one) still falls through to
  #   the plain alive-based check below exactly as before.
  if [[ "$exit_at" =~ ^[0-9]+$ ]] && (( now - beat <= limit )); then
    printf 'ARMED\tpid %s, last beat %ss ago (a stale exit_at was superseded)\n' "$pid" "$(( now - beat ))"
    return 0
  fi

  # PARKED takes priority over the beat-staleness check below: while parked,
  # `beat` is EXPECTED to go stale (that is the whole design), so judging
  # health by `beat` here would always read a healthy park as WEDGED. Judge it
  # by the channel that is actually still advancing instead.
  if (( alive == 1 )) && (( now - park_beat <= limit )); then
    printf 'PARKED\tpid %s, park heartbeat %ss ago — correctly idle under a throttle\n' \
      "$pid" "$(( now - park_beat ))"
    return 0
  fi

  # No exit record (or the exit was superseded but beat has ALSO gone stale
  # since — see the superseded-exit branch above). Not parked. Is it beating?
  local stale=$(( now - beat ))
  if (( alive == 1 && stale <= limit )); then
    # ⭐⭐⭐ WEDGED-SYNC (slice 2, fable's poll-persistent wedge design, 2026-09-22) — a
    #    persistent poller beats its heartbeat perfectly well even while running as a plain
    #    Bash call OUTSIDE any Monitor: the loop's own tick keeps firing `hb_beat` on schedule
    #    regardless of how it was invoked, so `beat` alone can never distinguish "healthy,
    #    Monitor-managed" from "healthy, but the calling SESSION has been synchronously
    #    blocked on this exact call for hours" — the real 2026-09-22 incident (2 seats, one
    #    for 12.5h) that this state exists to name. The one signal that CAN see it: the
    #    process's own real elapsed time (`ps -o etimes=`, not this file's own `started` key
    #    — a reused/restarted pid must never inherit a stale age), read against the SAME knob
    #    slice 1's own self-limit uses. A real Monitor kills its child well before that age is
    #    ever reached, so a persistent poller that old was never running under one.
    # ⛔ Gated on the `persistent` marker poller.sh now writes at loop start — a classic
    #    `poll` legitimately sits alive for a long time in its own plain mail-wait loop (no
    #    bug there); applying this check unconditionally would misread that as a wedge.
    #    Absent marker (an older heartbeat file, pre-dating this slice) reads as "not known to
    #    be persistent" and skips the check entirely — the safe direction for a brand-new
    #    detector is never flagging on data it cannot yet interpret.
    local persistent_mode; persistent_mode="$(hb_read "$seat" persistent 2>/dev/null || echo 0)"
    if [[ "$persistent_mode" == "1" ]]; then
      local sync_limit="${AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC:-2400}"
      if (( sync_limit > 0 )); then
        local etimes; etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
        # Grace beyond the knob itself: slice 1's own check runs once per tick, so a process
        # can legitimately sit a few seconds past the knob between the deadline passing and
        # the next tick's own exit -- worst case is roughly one full tick (the check can just
        # barely miss the threshold, then wait a whole `sleep interval` before the NEXT tick
        # catches it). Two ticks' worth of margin absorbs that without this verdict racing the
        # poller's own self-limit, and scales with the SAME interval the poller itself uses
        # rather than a fixed constant that would make a fast test slow for no reason.
        local sync_grace=$(( interval * 2 ))
        if [[ "$etimes" =~ ^[0-9]+$ ]] && (( etimes >= sync_limit + sync_grace )); then
          printf 'WEDGED-SYNC\tpid %s has run %ss -- longer than any Monitor allows (%ss cap + %ss grace); it is NOT running under a Monitor -- the calling session is hung on it. Kill the poller pid, leave the session.\n' \
            "$pid" "$etimes" "$sync_limit" "$sync_grace"
          return 0
        fi
      fi
    fi
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

# ─── seat -> per-session evidence, read ONCE per report ───────────────────────
#
# ⚠ ONE SNAPSHOT FOR THE WHOLE REPORT. Calling the classifier per seat would
#   walk /proc once per row and let two rows disagree about a poller that exited
#   between them — the same internally-inconsistent-reading class as AR-12's
#   partial heartbeat. Loaded lazily so a `fleet` run on a box without python3
#   pays nothing and still prints.
#
# Populates two maps, keyed by seat:
#   FLEET_SESS_LIVE[seat]    total sessions in ARMED|WORKING|UNARMED
#   FLEET_SESS_WORKING[seat] sessions in ARMED|WORKING only — i.e. sessions
#                            whose own transcript proves they are moving, which
#                            is the only population that EXPLAINS a down poller
# FLEET_SESS_OK is 1 only when the reading actually happened. Anything else
# leaves it 0 and every caller below keeps its heartbeat-only wording.
FLEET_SESS_OK=0
declare -A FLEET_SESS_LIVE=() FLEET_SESS_WORKING=()
_fleet_load_sessions() {
  (( FLEET_SESS_OK )) && return 0
  [[ "${AIMAIL_FLEET_NO_SESSIONS:-}" == "1" ]] && return 1   # escape hatch + test seam
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f "$AIMAIL_LIB/sessions.sh" ]] || return 1
  # shellcheck source=./sessions.sh
  source "$AIMAIL_LIB/sessions.sh"
  local json; json="$(_sessions_json)" || return 1
  [[ -n "$json" ]] || return 1
  local line seat live working
  while IFS=$'\t' read -r seat live working; do
    [[ -n "$seat" ]] || continue
    FLEET_SESS_LIVE["$seat"]="$live"
    FLEET_SESS_WORKING["$seat"]="$working"
  done < <(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for seat, states in sorted(d.get("by_seat_state", {}).items()):
    live = sum(states.get(k, 0) for k in ("ARMED", "WORKING", "UNARMED"))
    work = sum(states.get(k, 0) for k in ("ARMED", "WORKING"))
    print("%s\t%d\t%d" % (seat, live, work))
' 2>/dev/null)
  FLEET_SESS_OK=1
  return 0
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
  # ⛔ Same reasoning as ask_dispatch's own trap (lib/ask.sh): a reader that
  # stops early (`grep -q "ASKS"` on the header line, `head`) closes the pipe
  # before this multi-row report finishes, and the default SIGPIPE would kill
  # this whole invocation mid-table rather than just truncating cleanly.
  trap '' PIPE
  supervisor_alert_banner || true
  { source "${BASH_SOURCE[0]%/*}/budget.sh"; source "${BASH_SOURCE[0]%/*}/placement.sh"; } 2>/dev/null || true
  command -v placement_report >/dev/null 2>&1 && { placement_report >/dev/null 2>/tmp/.aimail_pl_$$ || cat /tmp/.aimail_pl_$$ >&2; rm -f /tmp/.aimail_pl_$$; }
  # ⚠ `--context` IS OPT-IN, DELIBERATELY: it is the one flag on this report
  #   that reads TRANSCRIPT CONTENT (context_readout.py's own tail read) on
  #   top of the mtime-only stat every other row here already pays for. Cheap
  #   per seat, but paid on every plain `aimail fleet` call would tax the
  #   routine, no-flags dashboard read for a number most callers never asked
  #   for -- so it stays off by default and on only when named.
  local want_context=0
  local -a args=()
  local a
  for a in "$@"; do
    if [[ "$a" == "--context" ]]; then want_context=1; else args+=("$a"); fi
  done
  set -- "${args[@]}"
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

  # ⭐⭐ Surfaced here on its own, no mail required to have been read first (see
  #   budget.sh's AUTOPILOT_BLIND_FLAG — the 2026-09-01 5h21m UNMEASURABLE
  #   incident's alarm). A plain path check, not a sourced budget.sh helper:
  #   `aimail fleet` does not otherwise load budget.sh, and this file must not
  #   start requiring it just to print one line.
  if [[ -f "$STATE_DIR/autopilot_blind" ]]; then
    echo "🔴 AUTOPILOT BLIND — the checkpoint/park safety net cannot fire right now:"
    local bf_age; bf_age="$(stat -c %Y "$STATE_DIR/autopilot_blind" 2>/dev/null || echo 0)"
    (( bf_age > 0 )) && echo "   (flag age: $(age_min "$bf_age") min -- see NORMALLY SELF-CLEARS below for what that means)"
    sed 's/^/   /' "$STATE_DIR/autopilot_blind"
    echo
  fi

  _fleet_load_sessions || true

  # ⚠ LOADED ONLY WHEN ASKED (see --context's own note above). One shared
  #   read for the whole table, not one context_readout.py invocation per
  #   seat -- `context_report --json` already batches every live session in
  #   a single _sessions_json() + one context_readout.py stdin pass.
  local -A FLEET_CONTEXT_TOKENS=()
  if (( want_context )); then
    command -v context_report >/dev/null 2>&1 || source "${BASH_SOURCE[0]%/*}/sessions.sh" 2>/dev/null
    local ctx_json; ctx_json="$(context_report --json 2>/dev/null)"
    if [[ -n "$ctx_json" ]]; then
      local seat_k tok_v
      while IFS=$'\t' read -r seat_k tok_v; do
        [[ -n "$seat_k" ]] || continue
        FLEET_CONTEXT_TOKENS["$seat_k"]="$tok_v"
      done < <(printf '%s' "$ctx_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
best = {}
for r in d.values():
    seat = r.get("seat")
    ct = r.get("context_tokens")
    if not seat or ct is None:
        continue
    if seat not in best or ct > best[seat]:
        best[seat] = ct
for seat, ct in best.items():
    print("%s\t%d" % (seat, ct))
' 2>/dev/null)
    fi
  fi

  local now; now="$(now_epoch)"
  if (( want_context )); then
    printf '%-16s %-11s %5s %-10s %6s %6s %6s %8s  %s\n' \
      SEAT POLLER SESS LAST-STOP QUEUED UNACK ASKS CONTEXT VERDICT
  else
    printf '%-16s %-11s %5s %-10s %6s %6s %6s  %s\n' \
      SEAT POLLER SESS LAST-STOP QUEUED UNACK ASKS VERDICT
  fi
  printf '%.0s─' {1..103}; echo

  local seat st detail stop_e stop_d q u verdict ago n_live n_work sess_col ctx_col
  for seat in "${seats[@]}"; do
    IFS=$'\t' read -r st detail < <(poller_state "$seat")
    IFS=$'\t' read -r stop_e stop_d < <(last_stop "$seat")
    q=$(find "$MAIL_DIR/$seat"         -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
    u=$(find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)

    if [[ "$stop_e" =~ ^[0-9]+$ ]]; then ago="$(( (now - stop_e) / 60 ))m"; else ago="never"; fi

    if (( FLEET_SESS_OK )); then
      n_live="${FLEET_SESS_LIVE[$seat]:-0}"; n_work="${FLEET_SESS_WORKING[$seat]:-0}"
      sess_col="$n_live"
    else
      # ⛔ NOT "0". An unmeasured count printed as 0 reads as "nobody is here",
      #    which is the dangerous direction — it is the very reading that would
      #    make a human restart a working seat.
      n_live=-1; n_work=-1; sess_col="?"
    fi

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
        # ⛔⛔ THE 2026-09-06 FALSE ALARM LIVED IN THIS ONE LINE. "woke but never
        #   re-armed; may be mid-task or stuck" named both worlds and chose
        #   neither, so a reader in a hurry chose "stuck" four times in a row
        #   about four working seats. The per-session evidence answers it
        #   outright: a session whose OWN TRANSCRIPT is still moving is mid-task,
        #   full stop, and a seat with no session at all is not "may be" anything.
        if (( n_work > 0 )); then
          verdict="WORKING — $n_work live session(s) mid-task; poller down between cycles. ⛔ DO NOT NUDGE"
        elif (( n_live > 0 )); then
          verdict="⚠ DEAF — $n_live session(s) alive but none armed; mail cannot reach this seat"
        elif (( n_live == 0 )); then
          verdict="⛔ NOBODY HOME — no live session at this seat. Only a human can restart it"
        else
          verdict="CHECK — woke but never re-armed; may be mid-task or stuck (no session reading)"
        fi ;;
      WEDGED)
        verdict="⛔ HUNG — process alive, loop not running. Needs a kill + restart" ;;
      WEDGED-SYNC)
        verdict="⛔ HUNG (SYNC) — poll-persistent running longer than any Monitor allows; the calling session is hung on it. Kill the poller pid, leave the session" ;;
      CRASHED)
        # A killed poller and a departed session are different repairs: one is
        # "ask the seat to re-arm", the other is "start a seat". Same heartbeat.
        if (( n_work > 0 )); then
          verdict="⚠ POLLER KILLED but $n_work session(s) still working — ask it to re-arm, do not restart"
        elif (( n_live == 0 )); then
          verdict="⛔ UNREACHABLE — killed, not finished, and NO live session. Only a human can restart it"
        else
          verdict="⛔ UNREACHABLE — killed, not finished. Only a human can restart it"
        fi ;;
      NEVER)
        if (( n_work > 0 )); then
          verdict="⚠ $n_work live session(s) here but NO poller has ever run — it has never been reachable"
        else
          verdict="NOT STARTED — no poller has ever run for this seat"
        fi ;;
    esac
    # ⚠ MORE THAN ONE SESSION ANSWERING ONE SEAT is invisible in every other
    #   column here (one heartbeat, one row) and it is not benign: the seat's
    #   mail is drained by whichever poller wins the race, so work can be
    #   delivered to a session that is not the one doing it.
    (( n_live > 1 )) && verdict="$verdict  ⚠ $n_live SESSIONS answering this seat"
    [[ "$stop_d" == BLOCK* ]] && verdict="$verdict  ⚠ last stop was BLOCKED"
    # FI-58: retirement-aware. A retired seat has no reader, so its inbox count is
    # ORPHANED (unreadable), never live QUEUED, and it is not "startable". Without
    # this it falls to the NEVER case -> "NOT STARTED", which reads as a new seat you
    # can start. Mirror of the retired guard `sweep` already uses below.
    if [[ "$(seat_field "$seat" 2)" == "retired" ]]; then
      verdict="RETIRED — no reader; ${q} file(s) ORPHANED (unreadable), not live QUEUED"
    fi
    local asks_col; asks_col="$(command -v ask_counts >/dev/null 2>&1 && ask_counts "$seat" 2>/dev/null || echo "?")"
    if (( want_context )); then
      ctx_col="${FLEET_CONTEXT_TOKENS[$seat]:-}"
      if [[ -n "$ctx_col" ]]; then ctx_col="$(( ctx_col / 1000 ))k"; else ctx_col="—"; fi
      printf '%-16s %-11s %5s %-10s %6s %6s %6s %8s  %s\n' \
        "$seat" "$st" "$sess_col" "$ago" "$q" "$u" "$asks_col" "$ctx_col" "$verdict"
    else
      printf '%-16s %-11s %5s %-10s %6s %6s %6s  %s\n' \
        "$seat" "$st" "$sess_col" "$ago" "$q" "$u" "$asks_col" "$verdict"
    fi

    # ⭐ M4 (twin-seat coordination, increment 0): one extra indented row per
    #   LIVE instance, shown ONLY when 2+ are registered for this seat name —
    #   the real twin case (docs/twin_seat_coordination_design_2026-09-18.md).
    #   N=1/no-registry-yet seats print nothing extra here, so this table's
    #   existing single-seat row stays byte-identical to before this change.
    local _inst_lines _inst_n
    _inst_lines="$(AIMAIL_INSTANCES_LIVE_CHECK=0 instances_list "$seat" 2>/dev/null)"
    _inst_n=$(printf '%s\n' "$_inst_lines" | grep -c $'\t')
    if (( _inst_n >= 2 )); then
      echo "  ⚠ $_inst_n LIVE INSTANCES of '$seat' — see \`aimail instances $seat\`:"
      printf '%s\n' "$_inst_lines" | while IFS=$'\t' read -r inst_id inst_state inst_detail; do
        printf '      %-24s %-6s %s\n' "$inst_id" "$inst_state" "$inst_detail"
      done
    fi
  done

  echo
  if [[ "${AIMAIL_FLEET_VERBOSE:-}" == "1" ]]; then
    cat <<EOF
HOW TO READ THIS — the distinction that matters most:
  RE-ARMING is NOT down. The poller fired, the seat is reading its mail, and it
  will re-arm on its own. Nudging it queues behind work already in flight. The
  grace window is ${REARM_GRACE}s (AIMAIL_REARM_GRACE).

  CRASHED is different from every other row: there is NO exit record, so it did
  not stop on purpose. That is the only state a human has to fix.

  SESS is how many SESSIONS are alive at that seat, measured per session id —
  each one's own claude process, its own transcript, and the pollers that
  actually descend from it. Every other column on this row is a property of the
  SEAT NAME and cannot tell one session from four, or from none.
EOF
    if (( FLEET_SESS_OK )); then
      cat <<'EOF'
  ⇒ POLLER and SESS answer different questions, and the pair is what makes a
    verdict: poller down + SESS>0 is a seat mid-task; poller down + SESS 0 is a
    seat nobody is sitting at. Run `aimail sessions` for the row-by-row detail.
EOF
    fi
    cat <<'EOF'

⚠ "Stopped" is never "finished". A seat can end a turn mid-task waiting on a
  decision. Cross-check what it is actually working on before concluding it is done.
EOF
  else
    echo "(legend: RE-ARMING = fine, self-recovers; CRASHED = needs a human restart; \"stopped\" ≠ \"finished\" — AIMAIL_FLEET_VERBOSE=1 for the full explanation)"
  fi
  # ⛔ A MISSING READING IS NOT HELP TEXT. This warning used to live inside the VERBOSE block above,
  #   so the default report printed "?" in the SESS column and never said why -- the exact "an
  #   unmeasured count rendered like a measured one" the column's own comment forbids. It prints
  #   whenever the reading is missing, verbose or not (run.sh's "degrade honestly" arm was red for
  #   this since the squash 471da9b).
  if ! (( FLEET_SESS_OK )); then
    cat <<'EOF'
  ⚠ SESS reads "?" — per-session liveness could NOT be measured on this box, so
    every verdict above is heartbeat-only and cannot distinguish "mid-task" from
    "nobody home". That is a missing reading, not a clean one.
EOF
  fi
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
# shellcheck source=pressure.sh
source "$(dirname "${BASH_SOURCE[0]}")/pressure.sh"
SWEEP_ALERT_DIR() { echo "$STATE_DIR/sweep_alerted"; }

# ─── disk/worktree watchdog (added after a disk-full incident, 2026-09-09) ──────
# ⛔⛔ THE INCIDENT: root disk hit 96% full (18GB free of 457GB) this evening, found only
#   because the project owner checked by hand -- nothing in this file's own sweep noticed,
#   because nothing in this file WATCHED disk at all. Root cause: ~99GB in /tmp, almost all
#   stale Claude Code session scratch (one dead session alone held 40GB) plus git worktrees
#   weeks old and never cleaned up. Same cron slot as fleet_sweep's own seat-health check
#   (called from there, below), same alert channel -- not a new watchdog, an extension of the
#   one that already runs every 5 minutes.
DISK_ALERT_GB="${AIMAIL_DISK_ALERT_GB:-80}"           # this deployment's own number, both checks below
DISK_STALE_WORKTREE_DAYS="${AIMAIL_STALE_WORKTREE_DAYS:-3}"  # tonight's finds were 4-11+ days old
# The checkouts this bloat can actually hide in -- entirely deployment-specific, so this reads
# a space-separated list from this machine's own gitignored etc/aimail.conf
# (AIMAIL_DISK_KNOWN_REPOS, see etc/aimail.conf.example) rather than hardcoding any repo names.
DISK_KNOWN_REPOS=()
for _fleet_disk_repo in ${AIMAIL_DISK_KNOWN_REPOS:-}; do
  DISK_KNOWN_REPOS+=("$_fleet_disk_repo")
done

_root_free_gb() {
  df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9'
}
_tmp_used_gb() {
  # `du` walks every file under /tmp -- MEASURED on this box (2026-09-09, ~42GB in /tmp): 26
  # real seconds, almost all in `sys` time (filesystem metadata, not CPU) -- /tmp is NOT a
  # separate mount here (confirmed: `df /tmp` and `df /` report the same device), so there is
  # no `df`-only shortcut; a full walk is the only way to isolate /tmp's own footprint from the
  # rest of root. Bounded by `timeout` well above the measured cost (not tuned to the minimum
  # that happened to pass once) so one slow reading never blocks the rest of a 5-minute sweep
  # tick; a missed reading (timeout, permission) is reported as unmeasured, never as "0GB, all
  # clear" -- an unmeasurable /tmp is not evidence /tmp is small, same fail-open contract
  # `_worker_slot_occupancy` already uses for an unreadable `ps`.
  timeout 90 du -sBG /tmp 2>/dev/null | awk '{print $1}' | tr -dc '0-9'
}

# One finding per stale/abandoned worktree, across every known repo. Two independent signals:
#   (a) git's OWN staleness flag (`git worktree list --porcelain`'s own `prunable` line) --
#       no guessing needed, git already knows this one is gone from disk or otherwise dead.
#   (b) age: the worktree's newest file (shallow scan, maxdepth 3 -- "cheap enough for a 5-
#       minute cron tick", not a full recursive stat of every file) is older than
#       DISK_STALE_WORKTREE_DAYS. This is an AGE heuristic only, same as tonight's real
#       cleanup used ("4-11+ days old with zero open-ticket references") -- it names a
#       CANDIDATE for a human to look at, it does not delete anything itself.
# The repo's own primary working tree (`git worktree list`'s first line, no `worktree` marker
# needed to identify it -- it IS $repo) is never flagged; only ADDITIONAL worktrees can be stale.
_stale_worktrees() {
  local repo path prunable now cutoff mtime line findings=()
  now="$(now_epoch)"
  cutoff=$(( DISK_STALE_WORKTREE_DAYS * 86400 ))
  for repo in "${DISK_KNOWN_REPOS[@]}"; do
    [[ -d "$repo/.git" || -f "$repo/.git" ]] || continue
    path=""; prunable=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path="${line#worktree }"; prunable="" ;;
        "prunable "*) prunable="${line#prunable }" ;;
        "")
          if [[ -n "$path" && "$path" != "$repo" ]]; then
            if [[ -n "$prunable" ]]; then
              findings+=("$path -- prunable ($prunable)")
            elif [[ -d "$path" ]]; then
              mtime="$(find "$path" -maxdepth 3 -type f -printf '%T@\n' 2>/dev/null \
                       | sort -rn | head -1)"
              mtime="${mtime%%.*}"
              if [[ -n "$mtime" ]] && (( now - mtime > cutoff )); then
                findings+=("$path -- newest file $(( (now - mtime) / 86400 ))d old, detached"\
"(age check only -- verify against open tickets before removing)")
              fi
            fi
          fi
          path=""; prunable=""
          ;;
      esac
    done < <(git -C "$repo" worktree list --porcelain 2>/dev/null; printf '\n')
  done
  printf '%s\n' "${findings[@]}"
}

disk_worktree_sweep() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  mkdir -p "$(SWEEP_ALERT_DIR)"
  local root_free tmp_used reason=""
  root_free="$(_root_free_gb)"
  tmp_used="$(_tmp_used_gb)"
  if [[ -n "$root_free" ]] && (( root_free < DISK_ALERT_GB )); then
    reason+="root filesystem: only ${root_free}GB free (floor ${DISK_ALERT_GB}GB). "
  fi
  if [[ -n "$tmp_used" ]] && (( tmp_used > DISK_ALERT_GB )); then
    reason+="/tmp: ${tmp_used}GB used (ceiling ${DISK_ALERT_GB}GB). "
  fi
  local -a stale=()
  while IFS= read -r line; do [[ -n "$line" ]] && stale+=("$line"); done < <(_stale_worktrees)

  if [[ -z "$reason" ]]; then
    info "sweep: disk/worktree check clean (root free=${root_free:-unmeasured}GB, /tmp=${tmp_used:-unmeasured}GB, ${#stale[@]} stale worktree(s) -- informational only, no real disk pressure, not alerted)"
    return 0
  fi

  # ⭐ DEDUP ON THE REAL READING (root/tmp GB), NOT ON THE STALE-WORKTREE COUNT -- an active
  # fleet creates scratch worktrees continuously, so that count crosses the age cutoff every
  # few minutes almost by construction (confirmed directly: 80->81->82->83, each a distinct
  # worktree aging past 3 days) and can never hold still long enough to dedup on, independent
  # of whether disk is ever actually a problem (mail 20260910T095113). The stale-worktree list
  # is informational payload riding along on a REAL alert, never itself the alert trigger --
  # this function returns above before ever reaching here unless `reason` (an actual GB
  # threshold breach) is non-empty, so the key only needs to track that.
  local marker="$(SWEEP_ALERT_DIR)/disk_worktree"
  local key="reason=${reason}"
  if [[ "$(cat "$marker" 2>/dev/null)" == "$key" ]]; then
    info "sweep: disk/worktree finding unchanged since last alert, not re-sent"
    return 0
  fi
  if seat_exists "$supervisor"; then
    local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/sweep.XXXXXX")"
    {
      printf '# 🔴 SWEEP: disk/worktree threshold crossed\n\n'
      [[ -n "$reason" ]] && printf '%s\n\n' "$reason"
      if (( ${#stale[@]} > 0 )); then
        printf '%d stale/prunable worktree(s) found (age check, %sd+ threshold):\n' \
          "${#stale[@]}" "$DISK_STALE_WORKTREE_DAYS"
        printf '  %s\n' "${stale[@]}"
        printf '\n'
      fi
      printf 'No human asked for this -- the sweep found it unprompted.\n'
      printf 'Threshold: %sGB (this deployment'"'"'s own number, root-free floor and /tmp-used ceiling both).\n' "$DISK_ALERT_GB"
    } > "$body"
    if mail_send --to "$supervisor" --no-wake --from "$supervisor" \
         --subject "SWEEP: disk/worktree threshold crossed" --body-file "$body" >/dev/null 2>&1; then
      printf '%s' "$key" > "$marker"
    fi
    rm -f "$body"
  else
    warn "sweep: disk/worktree threshold crossed but supervisor '$supervisor' is not registered -- no alert sent"
  fi
}

# ─── idle-capacity / unowned-backlog watchdog — 2026-09-21, the owner's own ask via assistant ──
# ⛔⛔ THE INCIDENT THIS EXISTS FOR: not a crash, not a dead poller -- a WORKING fleet that
#   defaults to reactive, single-thread focus. Real, lower-priority-but-real work (an idle
#   seat, a stale ticket nobody built) sits unassigned until it compounds into its own crisis
#   or the owner notices and names it without help, repeatedly, the same day. Prose reminders about
#   this exact shape ("don't wait for check-in, self-select when idle") failed to prevent
#   recurrence three times before tonight -- the fix that actually worked elsewhere in this
#   file (poller_guard.sh's Stop hook) was never a better-worded reminder, it was a check that
#   fires on its own. This is that check, for THIS failure mode: correlate genuine idle
#   capacity against a real, aged, unclaimed backlog item -- neither signal alone is alarming
#   (an idle seat with nothing real to do is fine; one stale ticket while everyone's
#   legitimately busy elsewhere is fine), the COMBINATION is the actual signal, same AND-not-OR
#   principle code-review's own budget-check refinement uses for the sibling mechanism.
IDLE_BACKLOG_ALERT_MIN="${AIMAIL_IDLE_BACKLOG_ALERT_MIN:-20}"   # how long ARMED-idle before it counts
BACKLOG_ITEM_AGE_MIN="${AIMAIL_BACKLOG_ITEM_AGE_MIN:-120}"      # 2 hours (code-review's refinement)
# ⚠ NO LIVE "MAIL THE OWNER DIRECTLY" CHANNEL EXISTS IN THIS CODEBASE -- checked before building:
#   no SMS/email/Slack bridge anywhere in lib/, and the owner's own seat is RETIRED ("use
#   assistant instead", seats.tsv) with no live reader, so mailing it would only accumulate
#   unread mail, not notify anyone. This hook is a no-op by default; set
#   AIMAIL_SECONDARY_ALERT_SEAT to a real, live-read seat/bridge if one is ever stood up, and
#   this alert (like disk_worktree_sweep's) will mail it too without another code change.
#   Reported honestly rather than silently mailing a seat nobody reads.

# _todo_backlog_path — where TODO.md actually lives on this deployment. Reuses
# AIMAIL_GUARDED_RELEASE_TODOEDIT (etc/aimail.conf) rather than a new config key -- that
# variable already names the real, gitignored path to this exact file for the todoedit
# gateclaim guard; this is the same file, read here for a different purpose.
_todo_backlog_path() { echo "${AIMAIL_GUARDED_RELEASE_TODOEDIT:-}"; }

# _parse_todo_header_epoch <header-line> — this repo's own dated section-header convention is
# "### 🔸 YYYY-MM-DD HH:MM — title" but the MINUTE is frequently written fuzzy ("17:3x",
# "15:1x") since these headers are written from real mail timestamps rounded for readability,
# not invented (FI-07's own rule against invented timestamps applies to entries, not to this
# reader). A fuzzy minute is floored to its decade ("3x" -> "30") rather than rejected --
# conservative in the safe direction: age is never OVER-estimated by more than ~9 minutes,
# which cannot itself cause a false alert against a 120-minute threshold.
_parse_todo_header_epoch() {
  local line="$1" datepart
  datepart="$(printf '%s\n' "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9Nn][0-9xX]' | head -1)"
  [[ -n "$datepart" ]] || return 1
  datepart="${datepart//[xXnN]/0}"
  date -d "$datepart" +%s 2>/dev/null
}

# _referenced_in_any_handover <token> — true if ANY REGISTERED seat's current role handover
# mentions the token (code-review's own refinement: an "unowned" TODO item someone is actively
# tracking in their own handover is not actually forgotten, even if the register text hasn't
# caught up).
# ⚠ Reads $AIMAIL_ROOT/roles directly rather than calling role.sh's own ROLES_DIR() -- that
#   file is NOT unconditionally sourced ahead of fleet_sweep() in bin/aimail's real dispatch
#   (confirmed: the `fleet`/`sweep` command paths source fleet.sh alone), so depending on it
#   here would make this check silently no-op (a bare `command not found`, swallowed by `||
#   continue` patterns elsewhere in this file) in exactly the real invocation this runs under.
# ⚠ Iterates `seat_names` -> `roles/<seat>.md`, NOT a bare `roles/*.md` glob (fable's peer
#   review of f3df8f4, 2026-09-21): that directory also holds non-current-handover files
#   (dated archives like `code-review.archive-2026-08-18.md`, one-off notes like
#   `aimail-port.md`/`audit-topics.md`) whose stale/unrelated prose can match a token and
#   silently suppress a live, genuinely-unowned finding.
_referenced_in_any_handover() {
  local token="$1" seat f
  [[ -n "$token" ]] || return 1
  while IFS= read -r seat; do
    [[ -n "$seat" ]] || continue
    f="${AIMAIL_ROOT}/roles/${seat}.md"
    [[ -f "$f" ]] || continue
    grep -qiF "$token" "$f" 2>/dev/null && return 0
  done < <(seat_names)
  return 1
}

# One finding per backlog ### BLOCK that has at least one line literally marked unowned (this
# repo's own exact convention, code-review's refinement), old enough to rule out "just written,
# not yet claimed", and not referenced in any seat's own current handover.
# ⚠ DEDUPES BY HEADER, not by line (fable's real finding, live run against 670d0ac,
#   2026-09-21): a single ### block can carry several "Status: OPEN, unowned" sub-bullets (the
#   real corpus has one -- code-review's 2026-08-28 WEEK-AUDIT, six sub-items under one
#   header). Emitting one finding per LINE reported that single item as "6 real backlog
#   item(s)" in the sweep's own alert body -- true in raw line count, misleading as a count of
#   distinct backlog ITEMS. One finding per header, with the unowned-line count in its own
#   detail, keeps the finding text honest about what it's counting.
# ⚠ OUTPUT IS "<header_token>\t<display text>", not bare display text (main's real incident,
#   2026-09-22: the same real backlog item re-alerted every ~5min tick for hours -- assistant
#   traced it to `idle_backlog_sweep`'s dedup key embedding this function's own display text,
#   which bakes in `header_age_min` -- a value that increases every tick by definition, so an
#   UNCHANGED item never produces the same key twice). `header_token` is a stable identity
#   (the header title, truncated, with no age/count baked in) computed once per header
#   regardless of how many ticks pass; the sweep now keys dedup on the tab-delimited FIRST
#   field and reserves the second field (the human-readable age/count detail) for the alert
#   mail body only. A caller that ignores the tab (e.g. a stub in a test that returns bare
#   text) still works: with no tab present, the whole line is field 1, which is exactly the
#   pre-existing behavior for callers that never had a live-changing suffix to begin with.
# _backlog_para_disposition <paragraph> — "resolved" | "open" | "" for ONE logical paragraph of a
# TODO.md entry (wrapped physical lines already re-joined by the caller). ⛔ A MIRROR, NOT A FORK:
# the forms and the negation guard are the backlog file's own classifier tool's rules (RESOLVED_CAPS_RE,
# RESOLVED_STATUS_LINE_RE, RESOLVED_LANDED_AS_RE, NEGATION_RE at PARAGRAPH scope,
# NARRATIVE_STILL_OPEN_RE), transcribed so the fleet has one definition of "resolved". The tool
# has no classify-only CLI yet (it archives whole tickets by --cutoff); the day it grows one, this
# function becomes a call into it. Until then any change to either side is a change to both.
#   - resolved forms: an ALL-CAPS LANDED/CLOSED/DONE/SUPERSEDED/WITHDRAWN/COMPLETE token (case-
#     sensitive), a "Status: LANDED|CLOSED|WITHDRAWN" line (any case), or "landed as|on <sha>".
#   - a resolved form is VOID when the same paragraph carries a negation word (not, no, nothing,
#     never, until, unless, before, awaiting, question, owed, pending) or a still-open phrase (GATE
#     REQUEST(ED), NOT YET, STILL OPEN, WAITING ON, PENDING, BLOCKED, TBD, OWED, TO BE DECIDED,
#     UNDECIDED, IN PROGRESS) -- "not CLOSED yet, waiting on the gate" is open, whatever it shouts.
#   - "Status: OPEN, unowned" (the sweep's own trigger) reads open.
# The CALLER applies the last-disposition rule: the last paragraph with a disposition decides the
# entry. That is the fix for the 2026-09-22 false positive (a real specimen): the
# entry carried an early "Status: OPEN, unowned -- owner architect" and a final "**Status: CLOSED.**
# Fix landed cd8a07fc9 ... gate GREEN", and the sweep counted the first line and never read the last.
_backlog_para_disposition() {
  local para="$1" lp; lp="${para,,}"
  local resolved=0
  if [[ "$para" =~ (^|[^A-Za-z])(LANDED|CLOSED|DONE|SUPERSEDED|WITHDRAWN|COMPLETE)([^A-Za-z]|$) ]]; then resolved=1; fi
  if [[ "$lp" =~ (^|[^a-z])status:[[:space:]]*\**[[:space:]]*(landed|closed|withdrawn)([^a-z]|$) ]]; then resolved=1; fi
  if [[ "$lp" =~ (^|[^a-z])landed[[:space:]]+(as|on)([^a-z]|$) ]]; then resolved=1; fi
  if (( resolved )); then
    if [[ "$lp" =~ (^|[^a-z])(not|no|nothing|never|until|unless|before|awaiting|question|owed|pending)([^a-z]|$) ]]; then resolved=0; fi
    if [[ "$lp" =~ (^|[^a-z])(gate[[:space:]]+request(ed)?|not[[:space:]]+yet|still[[:space:]]+open|waiting[[:space:]]+on|pending|blocked|tbd|owed|to[[:space:]]+be[[:space:]]+decided|undecided|in[[:space:]-]+progress)([^a-z]|$) ]]; then resolved=0; fi
  fi
  if (( resolved )); then printf 'resolved\n'; return 0; fi
  if [[ "$para" == *"Status: OPEN, unowned"* ]]; then printf 'open\n'; return 0; fi
  printf '\n'
}

# _backlog_entry_id <heading line, no newline> — the SAME id the backlog file's own classifier tool
# assigns a narrative block (its --classify output, first column): the first `T-\d+` in the raw
# heading line if any, else "NARR-" + sha1(raw line bytes INCLUDING the trailing newline)[:10].
# ⛔ Never a line number (standing rule: every archive batch shifts them). The `printf '%s\n'`
# restores the newline `read -r` stripped, so the hashed bytes are the file's own.
_backlog_entry_id() {
  local line="$1"
  if [[ "$line" =~ T-[0-9]+ ]]; then printf '%s\n' "${BASH_REMATCH[0]}"; return 0; fi
  printf 'NARR-%s\n' "$(printf '%s\n' "$line" | sha1sum | cut -c1-10)"
}
# _backlog_heading_ids <todo> — one id per "### " heading, in file order, in ONE python pass (the
# same formula as _backlog_entry_id; python is already a precondition of the tool path). ~2000 headings
# x (printf|sha1sum|cut) cost 58s under load on a real backlog file -- a 5-minute cron cannot spend that.
_backlog_heading_ids() {
  python3 - "$1" <<'PYIDS'
import hashlib, re, sys
rx = re.compile(rb"T-\d+")
with open(sys.argv[1], "rb") as fh:
    for line in fh:
        if not line.startswith(b"### "):
            continue
        m = rx.search(line)
        print(m.group(0).decode("ascii") if m else "NARR-" + hashlib.sha1(line).hexdigest()[:10])
PYIDS
}
# _backlog_tool_dispositions <todo> — "<id>\t<open|resolved>" per entry from an external classifier's
# read-only mode: `python3 $AIMAIL_TODO_ARCHIVE_TOOL --classify <todo>`, the fleet's ONE definition of
# "is this entry's own last word open or resolved". ⛔ CONFIG-ONLY, DEFAULT UNSET:
# AIMail is generic and knows no project's tool path (sterility rule); unset -> the
# built-in mirror decides and the caller says so. Returns 1, printing nothing, when the variable is
# unset, the tool or python3 is absent, or the call fails.
# ⭐ CACHED on the TODO's (mtime, size, tool path): the sweep runs from cron every 5 minutes and the
#   classifier costs seconds on a 77K-line file, while the file changes a few times an hour at most.
#   The cache lives in $STATE_DIR/backlog_classify.cache: line 1 is the key, the rest the verdicts.
_BACKLOG_CLASSIFY_CACHE() { echo "$STATE_DIR/backlog_classify.cache"; }
_backlog_tool_dispositions() {
  local todo="$1"
  local tool="${AIMAIL_TODO_ARCHIVE_TOOL:-}"
  [[ -n "$tool" && -f "$tool" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local key; key="$(stat -c '%Y %s' "$todo" 2>/dev/null) $tool"
  local cache; cache="$(_BACKLOG_CLASSIFY_CACHE)"
  if [[ -s "$cache" && "$(head -n1 "$cache")" == "KEY $key" ]]; then
    tail -n +2 "$cache"; return 0
  fi
  local out; out="$(timeout "${AIMAIL_TODO_CLASSIFY_TIMEOUT_SEC:-30}" python3 "$tool" --classify "$todo" 2>/dev/null)" || return 1
  [[ -n "$out" ]] || return 1
  out="$(printf '%s\n' "$out" | cut -f1,2)"
  mkdir -p "$STATE_DIR" 2>/dev/null
  { printf 'KEY %s\n' "$key"; printf '%s\n' "$out"; } | atomic_write "$cache" 2>/dev/null || true
  printf '%s\n' "$out"
}

_unowned_backlog_items() {
  local todo; todo="$(_todo_backlog_path)"
  [[ -n "$todo" && -f "$todo" ]] || return 0
  local now; now="$(now_epoch)"
  local line header="" header_epoch="" header_title="" header_token=""
  local unowned_count=0 header_age_min=0 findings=()
  # last-disposition state for the CURRENT entry: paragraphs are joined (wrapped lines are one
  # unit, the v5 scope), and the last paragraph that says anything decides.
  local para="" last_disp="" d
  # the tool's verdicts, keyed by entry id; empty map -> mirror only (and one stderr line saying so)
  local -A tool_disp=(); local _tid _td tool_used=0
  # ⚠ ONE ID, SEVERAL BLOCKS: on a real backlog file 113 ids headed more than one "### " block (for
  #   example the same task id appearing twice), and 70 of those have both open and resolved blocks. The tool's own per-id rule
  #   (the classifier's own sibling rule): an id is OPEN if ANY of its entries reads
  #   open. So "open" sticks; a later "resolved" line never overwrites it.
  if while IFS=$'\t' read -r _tid _td; do
       [[ -n "$_tid" ]] || continue
       if [[ "${tool_disp[$_tid]:-}" != "open" ]]; then tool_disp["$_tid"]="$_td"; fi
     done < <(_backlog_tool_dispositions "$todo"); (( ${#tool_disp[@]} > 0 )); then
    tool_used=1
  else
    info "backlog sweep: no external classifier (AIMAIL_TODO_ARCHIVE_TOOL unset, missing, or failed) -- dispositions from the built-in mirror of its rules" >&2
  fi
  # heading ids, file order, one pass -- consumed one per "### " line below (only needed with the tool)
  local -a heading_ids=(); local hid_i=0
  (( tool_used )) && mapfile -t heading_ids < <(_backlog_heading_ids "$todo" 2>/dev/null)
  local entry_id=""
  _flush_para() {
    [[ -n "$para" ]] || return 0
    # the mirror's regexes are the expensive half of this sweep (52s on the real 77K-line TODO.md
    # under load 20); with the tool's verdicts in hand they are not consulted at all
    if (( tool_used == 0 )); then d="$(_backlog_para_disposition "$para")"; [[ -n "$d" ]] && last_disp="$d"; fi
    para=""
  }
  _flush_entry() {
    _flush_para
    # ⚠ A short/generic token ("follow-up", "cleanup") matches almost any handover's own prose
    #   and would silently suppress a real finding (fable's peer review of f3df8f4, 2026-09-21)
    #   -- only trust the handover cross-check once the token is specific enough to mean
    #   something. Under the floor: skip the check entirely (never suppress).
    # ⛔ An entry whose LAST disposition is resolved is finished work, however many "OPEN,
    #   unowned" lines its history carries -- sending an idle seat after it is the false positive.
    # the tool's verdict for this entry id wins when it has one; the mirror decides otherwise
    local disp="$last_disp"
    if (( tool_used )) && [[ -n "$entry_id" && -n "${tool_disp[$entry_id]:-}" ]]; then disp="${tool_disp[$entry_id]}"; fi
    if (( unowned_count > 0 )) && [[ "$disp" != "resolved" ]] \
       && ! { (( ${#header_token} >= 12 )) && _referenced_in_any_handover "$header_token"; }; then
      findings+=("$header_token"$'\t'"$header_title (${header_age_min}m old, ${unowned_count} unowned line(s), unreferenced in any handover)")
    fi
    unowned_count=0; last_disp=""; entry_id=""
  }
  while IFS= read -r line; do
    case "$line" in
      "### "*)
        _flush_entry
        header="$line"
        header_epoch="$(_parse_todo_header_epoch "$header" || echo '')"
        header_title="${header#*— }"; [[ "$header_title" == "$header" ]] && header_title="${header#*-- }"
        header_token="$(printf '%s' "$header_title" | cut -c1-40)"
        entry_id=""
        if (( tool_used )); then entry_id="${heading_ids[$hid_i]:-}"; hid_i=$((hid_i+1)); fi
        continue
        ;;
      "")
        _flush_para; continue
        ;;
      *"Status: OPEN, unowned"*)
        if [[ -n "$header_epoch" ]]; then
          header_age_min=$(( (now - header_epoch) / 60 ))
          (( header_age_min >= BACKLOG_ITEM_AGE_MIN )) && unowned_count=$(( unowned_count + 1 ))
        fi
        ;;
    esac
    para="${para:+$para }$line"
  done < "$todo"
  _flush_entry
  unset -f _flush_para _flush_entry
  printf '%s\n' "${findings[@]}"
}

# _idle_seat_has_live_working_session <seat> — true iff `claude agents --json`, checked
# RIGHT NOW across every account dir, shows a session mapped to this seat (via stop_guard's
# own session->seat registration file, $STATE_DIR/stopguard/session.<sid>) reporting
# state=="working". Exists because `last_stop` (the ONLY signal _idle_seats used to have) only
# updates when a TURN ENDS -- a seat continuously mid-turn for the whole window reads
# identical to a genuinely idle one on that signal alone. Real incident, fable's peer review of
# f3df8f4 (2026-09-21): code-review's own session read `state: "working"` while actively
# writing a peer review, and `_idle_seats` called it "idle 22m" anyway, off a stale last_stop.
# "working" is checked (and ONLY "working") because it is the one value CONFIRMED live as a
# reliable positive busy signal (that same code-review measurement) -- other raw states
# ("blocked"/"busy") do NOT reliably mean idle OR busy either way (watchdog.sh's own two
# hard-won findings above this file), so this stays narrow rather than guessing at those;
# last_stop's existing age check is still the fallback for everything that isn't a confirmed
# "working" reading.
_idle_seat_has_live_working_session() {
  local seat="${1:?usage: _idle_seat_has_live_working_session <seat>}"
  command -v claude >/dev/null 2>&1 || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  [[ "${AIMAIL_NO_NETWORK:-}" == "1" ]] && return 1
  local dir json sid state mapped_f mapped
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    json="$(CLAUDE_CONFIG_DIR="$dir" timeout "${AIMAIL_AGENTS_TIMEOUT_SEC:-30}" claude agents --json 2>/dev/null)" || continue
    [[ -n "$json" ]] || continue
    while IFS=$'\t' read -r sid state; do
      [[ -n "$sid" ]] || continue
      mapped_f="$STATE_DIR/stopguard/session.$sid"
      [[ -f "$mapped_f" ]] || continue
      mapped="$(cat "$mapped_f" 2>/dev/null)"
      [[ "$mapped" == "$seat" && "$state" == "working" ]] && return 0
    done < <(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for d in data:
    if not isinstance(d, dict):
        continue
    sid = d.get("sessionId", "")
    state = d.get("state", "")
    if sid:
        print(f"{sid}\t{state}")
' 2>/dev/null)
  done < <(_instance_account_dirs)
  return 1
}

# One finding per seat that has been ARMED-and-idle (poller healthy, turn ended, nothing
# queued) past IDLE_BACKLOG_ALERT_MIN, AND is not CURRENTLY mid-turn per a live "working"
# reading (_idle_seat_has_live_working_session above) -- reuses poller_state()/last_stop()
# exactly as the dashboard's own IDLE & REACHABLE verdict does, so a disagreement with a human
# reading `aimail fleet` is limited to the one gap that verdict itself has (ARMED = a heartbeat
# is alive, not that the seat is idle -- AGENTS.md's own standing trap), which this function now
# closes rather than inherits.
_idle_seats() {
  local -a seats=(); local s
  while IFS= read -r s; do [[ -n "$s" ]] && seats+=("$s"); done < <(seat_names)
  local now; now="$(now_epoch)"
  local seat st detail stop_e stop_d ago_min findings=()
  for seat in "${seats[@]}"; do
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    IFS=$'\t' read -r st detail < <(poller_state "$seat")
    [[ "$st" == "ARMED" ]] || continue
    IFS=$'\t' read -r stop_e stop_d < <(last_stop "$seat")
    [[ "$stop_e" =~ ^[0-9]+$ ]] || continue
    ago_min=$(( (now - stop_e) / 60 ))
    (( ago_min >= IDLE_BACKLOG_ALERT_MIN )) || continue
    _idle_seat_has_live_working_session "$seat" && continue
    # "<seat>\t<display text>" -- same identity/display split as _unowned_backlog_items,
    # same reason: "${ago_min}m" increases every tick, so it cannot be part of a stable
    # dedup key (main's real incident, 2026-09-22 -- see that function's own comment).
    findings+=("$seat"$'\t'"$seat (idle ${ago_min}m)")
  done
  printf '%s\n' "${findings[@]}"
}

idle_backlog_sweep() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  mkdir -p "$(SWEEP_ALERT_DIR)"
  local -a idle=() backlog=()
  while IFS= read -r line; do [[ -n "$line" ]] && idle+=("$line"); done < <(_idle_seats)
  while IFS= read -r line; do [[ -n "$line" ]] && backlog+=("$line"); done < <(_unowned_backlog_items)

  if (( ${#idle[@]} == 0 )) || (( ${#backlog[@]} == 0 )); then
    info "sweep: idle/backlog check clean (${#idle[@]} idle seat(s), ${#backlog[@]} real unowned/aged backlog item(s) -- both required, not alerting on either alone)"
    return 0
  fi

  # Split each "<identity>\t<display>" line (_idle_seats/_unowned_backlog_items' own comments)
  # into a stable identity (dedup key material, backlog side only -- see below) and a
  # human-readable display line (mail body, both sides). A line with no tab -- e.g. a test
  # stub -- degrades to identity==display==the whole line, i.e. exactly the old behavior for a
  # caller that never had a live-changing suffix.
  local -a idle_display=() backlog_ids=() backlog_display=()
  local line
  for line in "${idle[@]}"; do
    idle_display+=("${line#*$'\t'}")
  done
  for line in "${backlog[@]}"; do
    backlog_ids+=("${line%%$'\t'*}"); backlog_display+=("${line#*$'\t'}")
  done

  # Dedup on the SET of BACKLOG-ITEM identities ONLY -- not the idle-seat set. A NEW backlog
  # item (even with the same seats idle as before) gets its own alert, same principle as
  # fleet_sweep's own (state, pid, beat) dedup key above.
  # ⚠ Real incident #1, main, 2026-09-22: this key used to be built from the DISPLAY text,
  #   which bakes in "${ago_min}m"/"${header_age_min}m" -- a value that increases every tick by
  #   definition, so an otherwise-unchanged finding never produced the same key twice and
  #   re-alerted on ~every 5-minute tick for hours (assistant caught it: the same TODO.md line
  #   fired at 23:40, 00:00, 00:05). Keying on identity (seat name / header token, with no age
  #   or count baked in) instead of display text is what makes "unchanged" mean unchanged.
  # ⚠ Real incident #2, assistant, 2026-09-22, ~25 min after #1 landed: the key ALSO included
  #   the idle-seat SET, which rotates naturally in a working fleet (foundation idle at 23:40,
  #   main at 00:00/00:05/00:30, librarian at 00:15) -- so even though the SAME backlog item
  #   sat unowned the whole time, the idle= half of the key kept changing and dedup never
  #   held. The backlog item is the durable finding; which seat happens to be idle right now
  #   is not part of its identity -- a supervisor already told about item X doesn't need to be
  #   told again just because a different seat crossed the idle floor. Idle seats still gate
  #   whether this fires at all (both empty-checks above are unchanged) and are still named in
  #   the alert body (idle_display); they are just no longer part of WHICH alert this is.
  local marker="$(SWEEP_ALERT_DIR)/idle_backlog"
  local key; key="backlog=$(printf '%s|' "${backlog_ids[@]}")"
  if [[ "$(cat "$marker" 2>/dev/null)" == "$key" ]]; then
    info "sweep: idle/backlog finding unchanged since last alert, not re-sent"
    return 0
  fi
  if seat_exists "$supervisor"; then
    local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/sweep.XXXXXX")"
    {
      printf '# 🔴 SWEEP: idle capacity + real unowned backlog, both present\n\n'
      printf '%d seat(s) idle past %sm:\n' "${#idle[@]}" "$IDLE_BACKLOG_ALERT_MIN"
      printf '  %s\n' "${idle_display[@]}"
      printf '\n%d real backlog item(s), OPEN+unowned, aged past %sm, unreferenced in any handover:\n' \
        "${#backlog[@]}" "$BACKLOG_ITEM_AGE_MIN"
      printf '  %s\n' "${backlog_display[@]}"
      printf '\nNo human asked for this -- the sweep found the correlation unprompted.\n'
      printf 'Neither signal alone triggers this: an idle seat with nothing real queued is fine,\n'
      printf 'one aged ticket while everyone is legitimately busy elsewhere is fine. Both at once\n'
      printf 'is the thing worth a look.\n'
    } > "$body"
    local -a mail_to=(--to "$supervisor")
    [[ -n "${AIMAIL_SECONDARY_ALERT_SEAT:-}" ]] && seat_exists "$AIMAIL_SECONDARY_ALERT_SEAT" \
      && mail_to+=(--to "$AIMAIL_SECONDARY_ALERT_SEAT")
    if mail_send "${mail_to[@]}" --no-wake --from "$supervisor" \
         --subject "SWEEP: idle capacity + unowned backlog both present" --body-file "$body" >/dev/null 2>&1; then
      printf '%s' "$key" > "$marker"
    fi
    rm -f "$body"
  else
    warn "sweep: idle/backlog threshold crossed but supervisor '$supervisor' is not registered -- no alert sent"
  fi
}

fleet_sweep() {
  local supervisor="${AIMAIL_SUPERVISOR:-assistant}"
  mkdir -p "$(SWEEP_ALERT_DIR)"
  local -a seats=()
  while IFS= read -r s; do [[ -n "$s" ]] && seats+=("$s"); done < <(seat_names)
  (( ${#seats[@]} == 0 )) && unmeasurable "no seats registered — there is nothing to sweep" \
    "This is an empty address space, not a healthy fleet."

  _fleet_load_sessions || true

  local seat st detail marker key n_alerts=0 n_checked=0 n_suppressed=0
  for seat in "${seats[@]}"; do
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    n_checked=$((n_checked+1))
    IFS=$'\t' read -r st detail < <(poller_state "$seat")
    case "$st" in
      CRASHED|WEDGED|WEDGED-SYNC) : ;;   # the states `aimail fleet` itself marks ⛔ — needs a human
      STALLED)
        # Past the dashboard's grace already (poller_state only returns STALLED
        # there); gate the ALERT on a second, much longer threshold so a seat
        # genuinely mid-task for ten minutes never pages anyone.
        local exit_at; exit_at="$(hb_read "$seat" exit_at 2>/dev/null || echo 0)"
        (( $(now_epoch) - exit_at < STALL_ALERT )) && continue
        # ⛔⛔ AND THE THRESHOLD WAS NEVER ENOUGH, because it is a clock and the
        #   thing it is standing in for is not. AIMAIL_STALL_ALERT's own comment
        #   picks 20 minutes as "generous enough that a real turn never trips
        #   it" — but a real turn here routinely runs a full test battery for
        #   well over an hour, and every one of those trips it. MEASURED
        #   2026-09-06: four seats paged as STALLED, all four working normally.
        #   An alert that fires on the healthy case teaches its reader to ignore
        #   it, which costs more than the alert was ever worth.
        # ⇒ Suppress ONLY on POSITIVE evidence: a session at this seat whose own
        #   transcript is still moving (ARMED or WORKING). Not on the absence of
        #   evidence — if the classifier could not run, FLEET_SESS_OK is 0 and
        #   this alerts exactly as it did before. A suppressed alert is logged
        #   and counted, never silent, because "the sweep found nothing" and
        #   "the sweep decided not to tell you" must not read the same.
        if (( FLEET_SESS_OK )) && (( ${FLEET_SESS_WORKING[$seat]:-0} > 0 )); then
          info "sweep: $seat is STALLED but ${FLEET_SESS_WORKING[$seat]} session(s) are working (transcript moving) — mid-task, not stalled; no alert"
          n_suppressed=$((n_suppressed+1))
          continue
        fi
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
    # M4 (the owner 2026-09-22): when the seat that crashed IS the supervisor, mailing "the supervisor"
    # mails a dead seat. Route that one alert to the vice orchestrator instead, and hand it the
    # wake command (lib/watchdog.sh's supervisor step does the same and escalates the same way).
    local recipient="$supervisor"
    if [[ "$seat" == "$supervisor" ]]; then recipient="${AIMAIL_VICE_SUPERVISOR:-main}"; fi
    if seat_exists "$recipient"; then
      local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/sweep.XXXXXX")"
      { printf '# 🔴 SWEEP: %s is %s\n\n%s\n\n' "$seat" "$st" "$detail"
        # ⭐ THE SESSION EVIDENCE TRAVELS WITH THE ALERT. Without it the reader's
        #   first act is to go and re-derive it by hand — which is what three
        #   separate seats each did independently on 2026-09-06.
        if (( FLEET_SESS_OK )); then
          printf 'PER-SESSION EVIDENCE: %s live session(s) at this seat, %s of them working.\n' \
            "${FLEET_SESS_LIVE[$seat]:-0}" "${FLEET_SESS_WORKING[$seat]:-0}"
          if (( ${FLEET_SESS_LIVE[$seat]:-0} == 0 )); then
            printf '⇒ NOBODY IS AT THIS SEAT. This needs a human to start one.\n\n'
          else
            printf '⇒ A session IS alive here — it needs to RE-ARM, not be restarted.\n\n'
          fi
        else
          printf 'PER-SESSION EVIDENCE: UNAVAILABLE (classifier could not run).\n'
          printf '⇒ This alert cannot tell "mid-task" from "nobody home". Check by hand:\n'
          printf '   aimail sessions %s\n\n' "$seat"
        fi
        printf 'No human asked for this — the sweep found it unprompted.\n'
        printf 'Run `aimail fleet %s` to confirm current state before acting.\n' "$seat"
      } > "$body"
      if mail_send --to "$recipient" --from "$supervisor" \
           --subject "SWEEP: $seat is $st" --body-file "$body" >/dev/null 2>&1; then
        printf '%s' "$key" > "$marker"; n_alerts=$((n_alerts+1))
      fi
      rm -f "$body"
    else
      warn "sweep: '$seat' is $st but supervisor '$supervisor' is not registered — no alert sent"
    fi
  done
  # ④ PRINT THE DENOMINATOR — and the suppressions, so "0 alerts" can never be
  #   read as "0 findings" when it actually means "N findings, all explained".
  info "sweep: checked $n_checked seat(s), $n_alerts new alert(s), $n_suppressed suppressed by live-session evidence"

  # Disk/worktree watchdog: same cron tick, same alert channel, a different population (disk/worktree bloat
  # instead of seat health) -- a failure here must never abort the seat-health sweep above it.
  disk_worktree_sweep || warn "sweep: disk_worktree_sweep failed (non-fatal, seat sweep above already ran)"

  # 2026-09-21: same cron tick, same alert channel, a different population again (idle
  # capacity crossed with real unowned backlog, instead of disk/worktree bloat) -- a failure
  # here must never abort the checks above it either.
  idle_backlog_sweep || warn "sweep: idle_backlog_sweep failed (non-fatal, checks above already ran)"

  # RAM/CPU pressure + orphan reaper: same tick, same alert channel. Also runs on its own
  # every minute via `aimail fleet pressure`; a failure here must never abort the checks above.
  fleet_pressure || warn "sweep: fleet_pressure failed (non-fatal, checks above already ran)"
  return 0
}
