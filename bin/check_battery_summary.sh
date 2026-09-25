#!/usr/bin/env bash
# check_battery_summary.sh -- refuse-loudly guard: a battery report must cite a REAL,
# on-disk summary file (run_canonical_battery.sh's own auto-written
# /tmp/canonical_battery_<seat>_<ts>.summary), and that file's own "worktree HEAD:" line must
# equal the tip actually being gated.
#
# WHY: this exact acceptance was owed three separate times in one night (T-788's own 04:58:51
# retraction, T-888(b)'s 06:09 duplicate run, this same T-888 4th-site migration's own 10:04
# hold) -- a gate request that quotes only the RAW RUNNER log (no "worktree HEAD:" line, no
# five _EXIT lines) is unprovable from disk: the reader cannot tell which tree the battery
# actually measured. run_canonical_battery.sh now writes that citable file itself (PROP-73,
# assigned by assistant 2026-09-18T10:02); this script is the acceptance check named in that
# same assignment -- "a gate recipe refuses a run with no summary file; refuses a summary whose
# worktree HEAD doesn't match the requested tip" -- made mechanical instead of a gater's own
# by-hand grep, the same shape check_range_code_sha.py already gave the code_sha convention.
#
# USAGE:
#     check_battery_summary.sh <summary-file> <expected-worktree-head>
#
# <expected-worktree-head> may be any length prefix of the real sha (a gater usually has the
# short form from a commit message) -- matched against the full sha the summary file itself
# carries, never the reverse (a short, ambiguous prefix must not falsely match a longer,
# unrelated sha by accident of string containment).
#
# Exit 0 -- the summary file exists, carries exactly one "worktree HEAD:" line whose own sha
#           starts with <expected-worktree-head>, AND all five named exit lines
#           (BATTERY_EXIT/CORPUS_EXIT/COUNT_EXIT/NAME_SET_EXIT/REAL_TIER_EXIT/SKIP_NAMES_EXIT --
#           six names, five distinct EXIT= lines since REAL_TIER_EXIT and SKIP_NAMES_EXIT are
#           the fifth/sixth of the wrapper's own six-line trailer) appear exactly once each.
# Exit 1 -- usage error (wrong argument count).
# Exit 2 -- the summary file does not exist at all -- "no summary file" per the assignment's
#           own first acceptance direction.
# Exit 3 -- the summary file exists but carries no "worktree HEAD:" line, more than one, or one
#           whose sha does not start with <expected-worktree-head> -- "worktree HEAD mismatch"
#           per the assignment's own second acceptance direction.
# Exit 4 -- the worktree HEAD matches, but the summary is INCOMPLETE: at least one of the six
#           named exit lines is missing or appears more than once (fable's additive finding,
#           2026-09-18T10:20 -- proving WHICH tree was measured is not proving the measurement
#           FINISHED; a summary truncated mid-run by a killed battery would otherwise pass
#           exit 0 on the HEAD check alone).
# Exit 5 -- the worktree HEAD matches and the summary is complete, but BATTERY_EXIT's own VALUE
#           is not 0 -- the summary proves WHICH tree was measured and that the measurement
#           finished, but not that it PASSED. Presence of "BATTERY_EXIT=" alone was silently
#           treated as "green" by every caller of this script (a red-but-complete run's summary
#           passed exit 0 identically to a green one) until this check was added.
set -u

# The wrapper's own six named exit lines (run_canonical_battery.sh's trailer block) -- one
# definition here, never six separate greps hand-copied at each call site.
REQUIRED_EXIT_NAMES=(BATTERY_EXIT CORPUS_EXIT COUNT_EXIT NAME_SET_EXIT REAL_TIER_EXIT SKIP_NAMES_EXIT)

if [ "$#" -ne 2 ]; then
    echo "usage: check_battery_summary.sh <summary-file> <expected-worktree-head>" >&2
    exit 1
fi
SUMMARY_FILE="$1"
EXPECTED="$2"

if [ ! -f "$SUMMARY_FILE" ]; then
    echo "⛔ REFUSED: no summary file at $SUMMARY_FILE." >&2
    echo "   A gate report that cites only a raw runner log is unprovable from disk -- the" >&2
    echo "   wrapper's own auto-written summary (worktree HEAD + the five exits) is the" >&2
    echo "   citable artifact; a missing one means the battery either predates this feature" >&2
    echo "   or its summary was never pointed to." >&2
    exit 2
fi

HEAD_LINES="$(grep -c '^▶ worktree HEAD:' "$SUMMARY_FILE")"
if [ "$HEAD_LINES" -ne 1 ]; then
    echo "⛔ REFUSED: $SUMMARY_FILE carries $HEAD_LINES 'worktree HEAD:' line(s), expected exactly 1." >&2
    echo "   A summary with none is not this wrapper's own output; one with more than one is" >&2
    echo "   ambiguous about which run it reports." >&2
    exit 3
fi

ACTUAL="$(grep '^▶ worktree HEAD:' "$SUMMARY_FILE" | awk '{print $NF}')"
case "$ACTUAL" in
    "$EXPECTED"*)
        ;;
    *)
        echo "⛔ REFUSED: $SUMMARY_FILE's own worktree HEAD ($ACTUAL) does not match the" >&2
        echo "   requested tip ($EXPECTED) -- this summary reports a DIFFERENT tree than the" >&2
        echo "   one under gate." >&2
        exit 3
        ;;
esac

INCOMPLETE=0
for name in "${REQUIRED_EXIT_NAMES[@]}"; do
    n="$(grep -c "^${name}=" "$SUMMARY_FILE")"
    if [ "$n" -ne 1 ]; then
        echo "⛔ REFUSED: $SUMMARY_FILE carries $n '${name}=' line(s), expected exactly 1 --" >&2
        echo "   summary is INCOMPLETE (a truncated file from a killed battery reads the" >&2
        echo "   correct worktree HEAD but never reaches its own trailer block)." >&2
        INCOMPLETE=1
    fi
done
if [ "$INCOMPLETE" -ne 0 ]; then
    exit 4
fi

BATTERY_EXIT_VALUE="$(grep '^BATTERY_EXIT=' "$SUMMARY_FILE" | tail -n1 | cut -d= -f2 | tr -d '[:space:]')"
if [ "$BATTERY_EXIT_VALUE" != "0" ]; then
    echo "⛔ REFUSED: $SUMMARY_FILE's own BATTERY_EXIT=$BATTERY_EXIT_VALUE, not 0 -- the summary" >&2
    echo "   proves which tree was measured and that the run finished, but the run was RED." >&2
    echo "   A gate cannot be accepted off a summary whose own battery did not pass." >&2
    exit 5
fi

echo "✔ $SUMMARY_FILE: worktree HEAD $ACTUAL matches the requested tip ($EXPECTED), all six named exit lines present, BATTERY_EXIT=0."
exit 0
