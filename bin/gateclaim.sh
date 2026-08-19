#!/usr/bin/env bash
# gateclaim.sh — atomic gate claim for the fleet.
#
# WHY THIS EXISTS
#   On 2026-08-16 the mail-based claim protocol failed FIVE times, the worst
#   being four seats claiming the same gate within 19 SECONDS (framing 17:18:47,
#   main 17:18:51, foundation 17:18:58, audit 17:19:06). Every one of them
#   followed the rule correctly. Mail delivery latency is seconds and the
#   decision window is seconds, so every seat reads a queue that was accurate
#   when written and stale when read. No announce-based scheme can arbitrate
#   that — "announce before the first command" was itself the fix adopted after
#   the PREVIOUS collision, and it is what failed 4-way.
#
#   `mkdir` is atomic on POSIX: exactly one caller creates a given directory and
#   everyone else gets EEXIST. That is a real arbiter, already installed.
#
# WHAT IT DOES NOT DO
#   It does not replace the claim MAIL. The mail is how the fleet learns what is
#   happening and carries the reasoning. Send it AFTER winning the lock, so it
#   reports a fact rather than an intention.
#
# ⚠ LIMITATION, stated rather than hidden: this works because every seat runs on
#   ONE box sharing /tmp. If a seat ever runs elsewhere, mkdir stops being an
#   arbiter and this SILENTLY reverts to the old racy behaviour. Re-check this
#   assumption before relying on it in any other topology.
#
# USAGE
#   gateclaim.sh <sha> <seat>            acquire — exit 0 = you own it, 1 = you do not
#   gateclaim.sh --release <sha> <seat>  release after the verdict ships
#   gateclaim.sh --list                  show live claims
#
#   Acquire as the VERY FIRST ACTION, before worktree setup (foundation, 2026-08-16:
#   a losing seat's worktree cleanup cost more than the race itself).
set -u

DIR="${AIMAIL_CLAIMS:-/tmp/aimail-gate-claims}"
# Matched to the slowest suite run measured on 2026-08-16 (730s under 3-way
# contention). Must stay comfortably ABOVE that or a live gate gets stolen.
STALE_SECONDS="${AIMAIL_CLAIM_STALE:-1800}"

usage() { sed -n '28,36p' "$0"; exit 2; }

case "${1:-}" in
  --list)
    [ -d "$DIR" ] || { echo "no claims"; exit 0; }
    found=0
    for d in "$DIR"/*/; do
      [ -d "$d" ] || continue
      found=1
      printf '%s  %s\n' "$(basename "$d")" "$(cat "$d/owner" 2>/dev/null || echo '(no owner file)')"
    done
    [ "$found" = 1 ] || echo "no claims"
    exit 0
    ;;
  --release)
    SHA="${2:-}"; SEAT="${3:-}"
    [ -n "$SHA" ] && [ -n "$SEAT" ] || usage
    OWNER=$(cut -d' ' -f1 "$DIR/$SHA/owner" 2>/dev/null || true)
    if [ -z "$OWNER" ]; then echo "NOT CLAIMED $SHA"; exit 0; fi
    if [ "$OWNER" != "$SEAT" ]; then
      # Refuse rather than steal — releasing someone else's claim is the same
      # class of harm as dropping their stash entry by index.
      echo "REFUSED: $SHA is held by $OWNER, not $SEAT"; exit 1
    fi
    rm -rf "${DIR:?}/${SHA:?}" && echo "RELEASED $SHA by $SEAT"
    exit 0
    ;;
  ''|-h|--help) usage ;;
esac

SHA="$1"; SEAT="${2:-}"
[ -n "$SEAT" ] || usage
mkdir -p "$DIR" 2>/dev/null

if mkdir "$DIR/$SHA" 2>/dev/null; then
  # Write via temp+mv so a loser never reads a half-written owner file.
  printf '%s %s %s\n' "$SEAT" "$(date -Iseconds)" "$(date +%s)" > "$DIR/$SHA/.owner.tmp"
  mv -f "$DIR/$SHA/.owner.tmp" "$DIR/$SHA/owner"
  echo "CLAIMED $SHA by $SEAT"
  exit 0
fi

# Already held. ⚠ THE DIRECTORY EXISTS BEFORE THE OWNER FILE DOES — a loser that
# reads immediately can find it absent. Measured: in a real 4-way race one loser
# printed "ALREADY CLAIMED by  " with an empty owner. The LOCK was still correct
# (exactly one winner); only the diagnostic was blank. Retry briefly so the
# message names the actual holder.
OWNER=""; WHEN=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -s "$DIR/$SHA/owner" ]; then
    OWNER=$(cut -d' ' -f1 "$DIR/$SHA/owner" 2>/dev/null || true)
    WHEN=$(cut -d' ' -f3 "$DIR/$SHA/owner" 2>/dev/null || true)
    [ -n "$OWNER" ] && break
  fi
  sleep 0.05
done
OWNER="${OWNER:-unknown}"; WHEN="${WHEN:-0}"
NOW=$(date +%s)
AGE=$(( NOW - ${WHEN:-0} ))

if [ "${WHEN:-0}" -gt 0 ] && [ "$AGE" -gt "$STALE_SECONDS" ]; then
  printf '%s %s %s\n' "$SEAT" "$(date -Iseconds)" "$NOW" > "$DIR/$SHA/owner"
  echo "RECLAIMED $SHA from $OWNER (stale ${AGE}s > ${STALE_SECONDS}s) by $SEAT"
  exit 0
fi

echo "ALREADY CLAIMED $SHA by $OWNER (${AGE}s ago) — stand down"
exit 1
