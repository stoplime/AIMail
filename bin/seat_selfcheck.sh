#!/usr/bin/env bash
# seat_selfcheck.sh — a boot-time liveness check that names its instrument and
# refuses to return an unfalsifiable green.
#
# ⛔⛔ WHY THIS EXISTS: on one night, three DIFFERENT liveness checks each
#    returned a confident answer that was wrong, and none of them overlapped:
#      ① a rigorous PID-chain check pointed at a RETIRED instrument (poller.sh,
#        after the fleet cut over to aimail) — the METHOD was right, the
#        OPERAND was stale. A seat read "poller ARMED correctly" while
#        unreachable by mail for 6h41m.
#      ② a channel nothing had exercised in ~5h read ARMED, which is true and
#        contains zero information about whether the channel still works —
#        nothing had tried to use it since the last real delivery.
#      ③ a `ps … | grep "aimail poll <seat>"` matched ITS OWN COMMAND LINE,
#        because the checker's own argv contained the string it was
#        searching for. A presence check that can match its own asker cannot
#        return zero.
#    ⇒ This script exists to make those three mistakes structurally hard to
#      repeat: it names the exact instrument being checked, excludes its own
#      process ancestry before counting anything, and reports real traffic
#      recency instead of a static status field.
#
# ⛔ READ-ONLY. This script does not kill, restart, arm, park, or write to any
#    state file the fleet reads. It only prints.
# ⛔ NOT WIRED INTO `bin/aimail`'s dispatcher and does not modify poller.sh,
#    gate.sh, gate_slot.sh, or fleet.sh — those run live with no build step,
#    so editing them is shipping. This is a new, separate, standalone file.
#
# USAGE:  bash bin/seat_selfcheck.sh <seat> [<seat> ...]
#         bash bin/seat_selfcheck.sh --all
#
# OUTPUT VOCABULARY, matching core.sh's own convention so this reads like the
# rest of the tool rather than a one-off script:
#   MEASURED      a real reading, with the command that produced it
#   UNMEASURABLE  could not measure — NOT the same claim as "measured zero"

set -uo pipefail

_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SELF/../lib/core.sh"
source "$_SELF/../lib/registry.sh"
source "$_SELF/../lib/fleet.sh"

# ─── Ancestry, so this script can never match its own asking ──────────────────
# WHY: `ps` output includes the `ps`/`pgrep`/awk process running THIS check, and
# on the harness this script itself runs inside a `/bin/bash -c … eval 'bash
# .../seat_selfcheck.sh <seat>'` wrapper whose own command line contains the
# seat name being checked. An unanchored or self-inclusive scan would count
# itself as evidence the seat has a live poller — exactly failure mode ③.
_my_ancestry() {
  python3 - "$$" <<'PY'
import sys
pid = int(sys.argv[1])
seen = []
while pid and pid != 1 and len(seen) < 40:
    seen.append(pid)
    try:
        with open(f"/proc/{pid}/status") as f:
            pid = next(int(l.split()[1]) for l in f if l.startswith("PPid:"))
    except (OSError, StopIteration, ValueError):
        break
print(" ".join(str(p) for p in seen))
PY
}

# ─── ① THE NAMED INSTRUMENT: is there a REAL, harness-tracked `aimail poll
#     <seat>` process, excluding this checker's own ancestry? ─────────────────
# Mirrors `.claude/hooks/poller_guard.sh`'s `_has_poller` deliberately — that
# function already solves the wrapper-vs-detached distinction correctly and
# there is no reason to re-derive it worse. The one change: this checks ONLY
# `aimail poll <seat>`, never the retired `poller.sh <seat>` shape, and SAYS
# SO explicitly, so a retired-instrument match can never read as evidence.
_aimail_poll_evidence() {
  local seat="$1" mine; mine="$(_my_ancestry)"
  python3 - "$seat" "$mine" <<'PY'
import os, re, sys
seat, mine = sys.argv[1], set(int(p) for p in sys.argv[2].split())
s = re.escape(seat)

# THE NAMED INSTRUMENT, anchored, never a substring match on the whole line.
invoke = re.compile(r"^(?:/bin/)?bash\s+\S*aimail\s+poll\s+%s(?:\s|$)" % s)
invocation = re.compile(r"bash\s+\S*aimail\s+poll\s+%s(?:\s|'|\"|$)" % s)
def is_wrapper(cmd):
    return cmd.startswith("/bin/bash -c") and bool(invocation.search(cmd))

# Also record whether a RETIRED-instrument process exists, for the report —
# informational only, never counted as evidence this seat is reachable.
retired_invoke = re.compile(r"^bash\s+\S*poller(?:\.sh\s+%s|_%s\.sh)(?:\s|$)" % (s, s))

procs = {}
retired_hit = False
for pid_s in filter(str.isdigit, os.listdir("/proc")):
    pid = int(pid_s)
    if pid in mine:
        continue
    try:
        cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
        if retired_invoke.match(cmd):
            retired_hit = True
        if not (invoke.match(cmd) or is_wrapper(cmd)):
            continue
        ppid = next(int(l.split()[1]) for l in open(f"/proc/{pid}/status")
                    if l.startswith("PPid:"))
        procs[pid] = (ppid, cmd)
    except (OSError, StopIteration, ValueError):
        continue

# Top processes = those whose parent is NOT itself one of the matched set.
# ⛔ THE MISTAKE THIS AVOIDS: checking the wrapper's OWN parent (e.g. the
#   VSCode extension process) instead of the wrapper itself. The wrapper IS
#   the harness-tracked process; its parent is a different, untracked layer
#   and asking about it answers a different question.
tops = [c for p, (pp, c) in procs.items() if pp not in procs]
tracked = any(is_wrapper(t) for t in tops)
detached = bool(tops) and not tracked
print("TRACKED" if tracked else ("DETACHED" if detached else "ABSENT"))
print("1" if retired_hit else "0")
for pid, (ppid, cmd) in procs.items():
    print(f"  pid={pid} ppid={ppid} :: {cmd[:100]}")
PY
}

# ─── ③ CHANNEL PROVEN BY TRAFFIC, not by a status field ────────────────────────
# An "ARMED" reading says the instrument is capable. It says nothing about
# whether anything has actually flowed through it recently. The only real
# evidence of that is the last successful delivery.
_last_traffic_age_min() {
  local seat="$1" f; f="$STATE_DIR/last_delivered/$seat"
  [[ -f "$f" ]] || { echo "-1"; return 0; }
  echo "$(( ($(now_epoch) - $(stat -c %Y "$f" 2>/dev/null || echo 0)) / 60 ))"
}

# ─── The check, one seat at a time ─────────────────────────────────────────────
TRAFFIC_STALE_MIN="${SELFCHECK_TRAFFIC_STALE_MIN:-30}"

check_seat() {
  local seat="$1"
  echo "════════════════════════════════════════════════════════════════"
  echo "SEAT: $seat"
  echo "  INSTRUMENT NAMED: aimail poll $seat   (the sole current wake path)"

  # --- ① process evidence, named instrument only ---
  local eout proc_state retired_present
  eout="$(_aimail_poll_evidence "$seat")"
  proc_state="$(sed -n '1p' <<<"$eout")"
  retired_present="$(sed -n '2p' <<<"$eout")"
  echo "  ① PROCESS  : $proc_state"
  sed -n '3,$p' <<<"$eout" | sed '/^$/d' | sed 's/^/      /'
  if [[ "$retired_present" == "1" ]]; then
    echo "      ⚠ a RETIRED-instrument process (poller.sh/poller_<seat>.sh) also exists for this"
    echo "        seat name. NOT counted as evidence — that channel is not the wake path."
  fi

  # --- ② heartbeat age, via poller_state() — never queue depth ---
  local st detail
  IFS=$'\t' read -r st detail < <(poller_state "$seat")
  echo "  ② HEARTBEAT: $st — $detail"
  echo "      (state dir: $STATE_DIR/poller/$seat.hb)"

  # --- ③ real traffic recency ---
  local age
  age="$(_last_traffic_age_min "$seat")"
  if [[ "$age" == "-1" ]]; then
    echo "  ③ TRAFFIC  : UNMEASURABLE — no delivery has ever been recorded for this seat"
  else
    echo "  ③ TRAFFIC  : last real delivery ${age}min ago"
  fi

  # --- Combined verdict, deliberately NOT a single boolean ---
  local verdict=""
  if [[ "$proc_state" == "TRACKED" && "$st" =~ ^(ARMED|PARKED|RE-ARMING)$ ]]; then
    if [[ "$age" != "-1" && "$age" -le "$TRAFFIC_STALE_MIN" ]]; then
      verdict="TRUSTED — process tracked, heartbeat fresh, AND recently exercised by real traffic"
    else
      verdict="REACHABLE-BUT-UNPROVEN — process tracked and heartbeat fresh, but no traffic in >${TRAFFIC_STALE_MIN}min. This is a true green with a gap: nothing has tested the channel recently."
    fi
  elif [[ "$proc_state" == "DETACHED" ]]; then
    verdict="⛔ SUSPECT — a process matches but is NOT harness-tracked (detached). It can exit and nothing re-invokes the seat."
  elif [[ "$proc_state" == "ABSENT" && "$st" == "CRASHED" ]]; then
    verdict="⛔ DOWN — no tracked process AND no exit record. Matches poller_state's own definition of crashed."
  elif [[ "$proc_state" == "ABSENT" && "$st" == "NEVER" ]]; then
    verdict="⛔ DOWN — no poller has ever been armed for this seat."
  elif [[ "$proc_state" == "ABSENT" && "$st" =~ ^(RE-ARMING|STALLED)$ ]]; then
    verdict="CHECK — no live process right now, but a clean exit record exists ($detail). Likely mid-turn, not dead."
  else
    verdict="UNMEASURABLE — process reading ($proc_state) and heartbeat reading ($st) do not resolve to a clean case; do not trust either alone."
  fi
  echo "  VERDICT    : $verdict"
}

# ─── Entry point ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r s; do
    [[ "$(seat_field "$s" 2)" == "retired" ]] && continue
    check_seat "$s"
  done < <(seat_names)
elif [[ $# -ge 1 ]]; then
  for s in "$@"; do
    seat_exists "$s" || { echo "REFUSED: '$s' is not a registered seat" >&2; exit 2; }
    check_seat "$s"
  done
else
  echo "usage: seat_selfcheck.sh <seat> [<seat> ...] | --all" >&2
  exit 64
fi
