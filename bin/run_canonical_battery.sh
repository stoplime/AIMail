#!/usr/bin/env bash
# Fleet tooling only -- NEVER referenced from inside the target project's own repo (run_unit_tests.py
# stays exactly what CI runs; gateclaim.sh has no meaning outside this fleet's own machine).
#
# RULING (fable, 2026-09-07, corpus collision incident): "a lock catches only what passes through
# it; a battery started without the claim never touched the lock, so the lock could not refuse
# it." This wrapper is the fix -- it IS the thing every seat is told to run instead of
# `python run_unit_tests.py` directly, so acquiring sharedcorpus is no longer a step a seat can
# forget.
#
# Design-read fixes (fable, 2026-09-07, second pass, then addendum): (1) a dirty-after diff now
# RESTORES src/outputs from the tarball before anything is deleted -- the backup is never
# destroyed while it might still be needed to recover a poisoned corpus. (2) clean-before/after is
# `git status --porcelain -- src/outputs` (POC's src/outputs is git-tracked, 329 files, confirmed
# clean) -- one line, no manifest needed; the tarball stays only as the restore source for item 1.
# (3) the target project's ROOT checkout is refused outright -- nothing runs there except the
# sanctioned deploy restart. (4) full output goes to a named log file, and the script prints
# exactly the lines a gate request needs to quote (log path, "Ran N", failures/expected-failures,
# BATTERY_EXIT, CORPUS_EXIT) -- never terminal scrollback, which a `| tail` can silently truncate.
#
# ⛔⛔ CORRECTION (fable, 2026-09-08 12:05, ruling on foundation's env sweep + main's pivot report):
# the paragraph immediately below, from 2026-09-07, is WRONG and kept struck rather than deleted,
# per this repo's own convention (_platform_env.py) for a corrected claim.
#   "foundation, 2026-09-07 (architect's finding, T-719): a fresh worktree has no `.env`, so
#   `config/environment_config.py`'s own `get_env_var('SENTRY_DSN')` raises at import time UNLESS
#   the calling shell already happens to have `SENTRY_DSN=''` exported ... Now exported explicitly
#   on the one line that invokes `run_unit_tests.py`, so this is foolproof regardless of the
#   caller's own shell."
# MEASURED, not assumed: `config/environment_config.py`'s own `load_environment_variables(
# override=True)` reloads `<worktree>/.env` and `<worktree>/zignore/.env` and OVERRIDES the
# process environment at IMPORT TIME -- so in any worktree carrying either file, the `SENTRY_DSN=''`
# export below is silently replaced by whatever real value that file holds before
# `EnvironmentConfig.__init__` ever reads it. `SENTRY_DSN='' python -c 'import
# config.environment_config'` in such a worktree leaves `SENTRY_DSN` NON-EMPTY after import --
# confirmed live. Every canonical battery run to date happened to run in a worktree carrying one of
# these files (61/130 worktrees on this machine do, by census), so the export has been inert in
# every one of them. What actually kept Sentry unarmed was a SEPARATE guard,
# `_running_under_the_sanctioned_test_suite()` in `utils/sentry_utils.py` (`"unittest" in
# sys.modules`), which `init_sentry()` checks BEFORE the DSN and which a `.env` reload cannot
# touch -- the unit tier has been protected by that one guard alone, not by this wrapper.
#
# THE REAL FIX (fable's ruling, same date): the WRAPPER supplies the environment; the WORKTREE
# supplies nothing.
#   1. Refuse outright any worktree carrying its own `.env` or `zignore/.env` -- the wrapper never
#      deletes another seat's file, it only refuses to run somewhere that would defeat its own
#      export. `load_environment_variables`'s override-on-reload behavior is exactly what makes a
#      worktree-local `.env` unsafe for this lane specifically; other uses of such a worktree are
#      unaffected.
#   2. Every required (non-optional) name `config/environment_config.py` reads is exported BY NAME
#      from ONE source, this repo's hub checkout's `zignore/.env` -- an allowlisted `^NAME=` line
#      lookup per name, never `source`/`set -a` on the file itself, and this script never echoes a
#      value, only names. Any required name absent from the source is a named refusal, not a
#      silent gap. `SENTRY_DSN` is the one deliberate exception: exported as `''` directly by this
#      script, never read from the source file -- with the worktree-.env refusal above now also in
#      force, that export is finally the thing that makes it effective, closing the gap the struck
#      paragraph above wrongly believed was already closed.
#   3. `TAKEOFF_POC_ROOT` is exported explicitly (fable's T-719 ruling; previously absent here).
#   4. The log header names the worktree, its HEAD sha, how the child process itself resolves
#      `poc_root()`, the env source path and the exported NAMES (never values), the conda python
#      path, and the collected test count -- a count that differs from the recorded baseline run's
#      own count is a REFUSAL, named, not a warning, exactly like the FAIL/ERROR name-set diff
#      already is.
#
# ⛔ CORRECTION (fable, 2026-09-08 13:00, ruling on main's path check): items 5/6 below were
# missing until this pass -- the count check (item 4) compared against `/tmp/baseline_test_
# count.txt`, and NOTHING anywhere compared the FAIL/ERROR name-set against a committed file at
# all (every "name-set diff" this session was a person running `comm` by hand against whichever
# path they picked -- exactly the "two seats, two files" gap the 12:46 one-canonical-file ruling
# addressed in principle but nothing enforced).
#   5. `BASELINE_COUNT_FILE` now reads the COMMITTED `$PLATFORM_ROOT/baseline_test_count.txt`,
#      never `/tmp`. The `/tmp` path becomes this wrapper's own WRITTEN run record (so a report
#      always has a same-run copy to cite), never the compare target -- a `/tmp`-only compare
#      target resets to nothing on a reboot, the same non-durability T-719 already fixed for
#      baseline_norm.txt's own sibling.
#   6. The wrapper now computes the FAIL/ERROR name-set diff ITSELF: sorted `FAIL: `/`ERROR: `
#      lines out of its own log, `comm -23`/`comm -13` against the COMMITTED
#      `$PLATFORM_ROOT/baseline_norm.txt`, both sides printed and named, non-empty on either side
#      is a REFUSAL -- never a count. A matching count can still hide a genuinely new failure
#      behind a fixed one (the 2026-09-06 incident this check exists to catch), and this closes
#      the gap where nothing but a person's memory enforced that rule.
#
# ⛔ HARDENING (fable, 2026-09-08 13:14, riding the gate on item 6 above): `comm` requires
# identical collation on both inputs. A synthetic test fixture during this build was sorted
# under a different order than the real baseline and produced a false mismatch -- caught before
# trusting the check, but the general risk is real: a different `LC_ALL`, a re-baseline written
# by a seat with another locale, or a name with a non-ASCII character can silently move a line
# and produce a false refusal or a false pass. Both the extraction (`sort`) and both `comm`
# invocations below are pinned `LC_ALL=C`, and `baseline_norm.txt` itself is committed re-sorted
# under `LC_ALL=C` in the same change (a pure reorder -- confirmed identical content, diffed as
# sets, before committing). Every future re-baseline write of baseline_norm.txt must also use
# `LC_ALL=C sort`, stated here so the next one doesn't drift back.
#
# T-762 (fable's section 8 ruling, 2026-09-08): two gate tiers.
#   --gate fast = `testing/` only (`run_unit_tests.py --tier unit`), mocked, NO sharedcorpus
#     claim (nothing in it reads the real corpus), real-tier modules skipped (they need a DB),
#     its own baseline pair (`baseline_norm_unit.txt`/`baseline_test_count_unit.txt`) -- sealed
#     target for the unit failure baseline is EMPTY; a mocked tier with a standing failure is a
#     misfiled test, not a baseline entry. Every ROUTINE code-review gate uses this tier.
#   --gate full = `testing/` + `testing_system/takeoff_tests` + REAL_TIER_MODULES (unchanged from
#     this script's own prior behavior), under `sharedcorpus`, against the EXISTING baselines.
#     Required at batch checkpoints, and for any change to testing_system/, to this script's or
#     run_unit_tests.py's discovery/count/normalize/compare logic, or to detection or billing
#     behaviour (project owner's ruling, 2026-09-21; T-762 §8 amended the same day). A baseline VALUE
#     bump is verified by the FAST run at its own tip.
# NO DEFAULT: an invocation without `--gate` refuses outright, so nobody mistakes a silent full
# for fast or the reverse. Every gate run before this flag existed (tonight's own T-741/T-746/
# T-751/T-765/T-766/T-767/T-768) ran what is now called `full`, a strict superset of `fast` --
# no retroactive re-gating, per the same ruling.
#
# Usage: run_canonical_battery.sh --gate fast|full [--wait <minutes>] <target-project-worktree-path> <seat-name> ["<claim-desc>"]
#
# --wait <minutes> (T-762 §3.4, 2026-09-21): instead of REFUSING an over-budget or lock-held
# launch, take a FIFO ticket in bin/battery_queue.sh's queue and launch when this ticket is at the
# head AND the budget checks pass AND (full) sharedcorpus is actually acquired; FULL tickets go
# ahead of FAST tickets; `WAIT TIMED OUT` (exit 5) after <minutes>. While ANY ticket is live, a
# launch WITHOUT --wait is refused, so nobody jumps the line by retrying fastest.
set -u

# Defined early (before the concurrency-budget check below, which delegates to a python
# invocation against PLATFORM_ROOT -- PROP-fable-40, T-804) rather than down near the rest of
# the path constants -- everything else that uses them still runs after argument parsing either
# way, so moving them costs nothing and lets the very first check use them.
#
# This whole battery wrapper only makes sense pointed at ONE specific downstream project's
# checkouts and interpreter -- there is no generic default that would actually run anywhere else,
# so these are read from this machine's own gitignored etc/aimail.conf (see etc/aimail.conf.example)
# rather than hardcoded, the same split every other machine-local path in this repo already uses.
AIMAIL_BATTERY_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_battery_cfg="${AIMAIL_CONFIG:-$AIMAIL_BATTERY_SELF/etc/aimail.conf}"
# shellcheck source=/dev/null
[ -f "$_battery_cfg" ] && . "$_battery_cfg"
: "${PLATFORM_ROOT:?PLATFORM_ROOT not set -- copy etc/aimail.conf.example to etc/aimail.conf and fill it in}"
: "${CONDA_PY:?CONDA_PY not set -- copy etc/aimail.conf.example to etc/aimail.conf and fill it in}"

GATE=""
WAIT_MIN=""
ARGS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --gate)
            GATE="${2:-}"
            shift 2
            ;;
        --gate=*)
            GATE="${1#--gate=}"
            shift
            ;;
        --wait)
            WAIT_MIN="${2:-}"
            shift 2
            ;;
        --wait=*)
            WAIT_MIN="${1#--wait=}"
            shift
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${ARGS[@]:-}"
if [ "$#" -eq 1 ] && [ -z "${1:-}" ]; then
    set --
fi

if [ "$GATE" != "fast" ] && [ "$GATE" != "full" ]; then
    echo "⛔ REFUSED: --gate fast|full is required, no default (T-762, fable's section 8 ruling)." >&2
    echo "   fast = testing/ only, mocked, no sharedcorpus claim, own empty-target unit baselines." >&2
    echo "   full = testing/ + testing_system/takeoff_tests + REAL_TIER_MODULES, under sharedcorpus." >&2
    echo "   Usage: run_canonical_battery.sh --gate fast|full [--wait <minutes>] <worktree-path> <seat-name> [claim-desc]" >&2
    exit 2
fi
if [ -n "$WAIT_MIN" ] && ! [ "$WAIT_MIN" -ge 1 ] 2>/dev/null; then
    echo "⛔ REFUSED: --wait takes a whole number of minutes >= 1 (got '${WAIT_MIN}')." >&2
    exit 2
fi
# Slots this launch requests (the #134 rule below explains the two numbers); needed before the
# budget verdict runs because a --wait ticket records it.
if [ "$GATE" = "full" ]; then REQUESTED=1; else REQUESTED=4; fi

# T-804 follow-up (fable's 2026-09-09 22:56 ruling): WORKTREE/SEAT/DESC and the two worktree
# guard checks are parsed HERE, right after argument parsing, rather than down near the rest of
# the path constants (their own original position, still marked below) -- the occupancy
# delegation call just below needs a real, validated $WORKTREE path BEFORE it can safely
# reference it. Args are cheap to parse; nothing else here does any real work yet.
WORKTREE="${1:?usage: run_canonical_battery.sh --gate fast|full <target-project-worktree-path> <seat-name> [claim-desc]}"
SEAT="${2:?usage: run_canonical_battery.sh --gate fast|full <target-project-worktree-path> <seat-name> [claim-desc]}"
DESC="${3:-canonical battery via run_canonical_battery.sh}"

# realpath so a trailing slash or a relative path can't dodge this check
WORKTREE_REAL="$(realpath "$WORKTREE" 2>/dev/null || echo "$WORKTREE")"
PLATFORM_ROOT_REAL="$(realpath "$PLATFORM_ROOT" 2>/dev/null || echo "$PLATFORM_ROOT")"
if [ "$WORKTREE_REAL" = "$PLATFORM_ROOT_REAL" ]; then
    echo "⛔ REFUSED: worktree resolves to the target project's ROOT checkout ($PLATFORM_ROOT_REAL)." >&2
    echo "   Nothing runs there except the sanctioned deploy restart -- use a detached worktree." >&2
    exit 2
fi
if [ ! -d "$WORKTREE" ]; then
    echo "⛔ REFUSED: worktree path does not exist: $WORKTREE" >&2
    exit 2
fi

# AUTO-SUMMARY (PROP-73, assigned by assistant 2026-09-18T10:02, per code-review's own gate on
# the manual version of this three times tonight): every gate report before this point had to
# quote the wrapper's own terminal stdout, which lives at a session-private harness path a
# gater cannot find by search unless the reporting seat remembers to `tee` it to a durable
# location by hand (T-788's own 04:57 retraction, T-888(b)'s 06:09 duplicate-run, and this same
# T-888 4th-site gate's own 10:04 hold, all this same night). `SUMMARY` is computed here --
# right after the worktree existence check, before the sharedcorpus claim below -- so the
# CLAIMED/RELEASED lines land in it too, not only the post-battery block. `summ()` writes each
# line to stdout (unchanged behavior for any caller already redirecting stdout to its own log)
# AND appends it to this one, fixed, always-written file -- no seat has to remember to tee.
TS="$(date +%Y%m%dT%H%M%S)"
SUMMARY="/tmp/canonical_battery_${SEAT}_${TS}.summary"
: > "$SUMMARY"
summ() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }

# T-775 follow-on (fable's ruling, 2026-09-09 03:32): a machine CONCURRENCY BUDGET, checked and
# printed FIRST, before any worktree/env work -- a refusal must cost nothing. Tonight's incident:
# three FULL/unit batteries plus a 16-worker COMPARE run stacked on one box with no memory-aware
# limit, exhausting swap (11Gi/11Gi used) and silently killing main's own FULL-battery process
# mid-run. `sharedcorpus` only serialises the CORPUS phase; it never protected memory, which is
# why FAST/COMPARE runs stacked freely beside FULL batteries. Budget: WORKER SLOTS, not
# invocations (#134, fable, 2026-09-09 13:36) -- a serial runner occupies 1 slot, a pooled one
# occupies 1 (itself) + its own live worker-child count, refusing when `occupancy + requested >
# budget`.
# ⛔⛔ ONE DEFINITION, NOT TWO HAND-COPIES (PROP-fable-40, T-804, 2026-09-09 22:40): this block
# used to re-implement its own bash/awk copy of "is this argv a test process", separately from
# `testing_runner_workers.py`'s own `_occupancy_from_ps_lines` (the #134 driver's Python-side
# twin). Two copies of the same predicate drift together when written together and apart when
# only one is patched later -- MEASURED, live incident: both copies were blind to a bare
# `python -m unittest <module>` invocation (framing's own PROP-fable-39 work) at the exact same
# moment, reading occupancy=0/14 while it genuinely contended with a pooled `--workers auto` FAST
# run; one of that run's own pool workers was subsequently killed (`BrokenProcessPool`). Fixed by
# DELETING the bash-side copy: this wrapper now DELEGATES the occupancy question to the Python
# driver itself (`--occupancy`, a cheap CLI entry point -- MEASURED ~0.14s, its own heavy imports
# are lazy specifically so this stays true to "a refusal must cost nothing"). If the predicate
# ever needs to change again, it changes in exactly one place.
# ⛔⛔ READ FROM $WORKTREE, NEVER $PLATFORM_ROOT (fable's 2026-09-09 22:56 correction on the
# first pass of this same fix): the first version of this delegation executed the ROOT checkout
# on every battery start, which is exactly the standing rule this whole wrapper exists to
# enforce against ("nothing runs there except the sanctioned deploy restart" -- see the
# WORKTREE-vs-PLATFORM_ROOT refusal above, now parsed BEFORE this point specifically so
# $WORKTREE is real and validated here). Delegating to the WORKTREE UNDER GATE also means the
# bootstrapping gap closes by itself the moment any chain rebases onto a landing that carries
# `--occupancy` -- no separate "wait for it to sync to the root" step ever needed.
# ⛔ A worktree that PREDATES this CLI (rebased onto an older tip) gets its own distinct reason,
# `occupancy_cli_absent`, decided from the SAME ONE subprocess call every other case uses --
# never a pre-flight grep of the target file's own source text (fable's 2026-09-09 23:08
# correction on this block's first pass: a grep is a claim about prose, not behavior -- a stray
# comment naming `--occupancy` in an older file would read as "present" and then fail confusingly
# as `delegation_unreachable` instead of the true, more specific reason).
# ⛔⛔ VERIFIED EMPIRICALLY, NOT ASSUMED FROM fable's OWN DESCRIPTION: an argparse-style "exit 2,
# unrecognized arguments" was the FIRST guess for what an old worktree does, but this script has
# no argparse and (before T-804) no `__main__` guard at all -- checked out ddd3842e0 (this
# module's own tip immediately before T-804) into a real detached worktree and ran `python3
# testing_runner_workers.py --occupancy` there directly: exit 0, ZERO lines of output. An old
# worktree does not refuse the flag, it silently ignores it (nothing in the pre-T-804 module's
# own top level acts on argv at all). The real, load-bearing signal is therefore "did the
# subprocess's OWN stdout contain an `occupancy=` line", not its exit code -- checked below.
# T-762 §3.4: the queue library lives beside this script (a worktree's wrapper sources its own
# worktree's copy, so a gate on this file never reads main's version by accident).
AIMAIL_BIN_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$AIMAIL_BIN_SELF/battery_queue.sh"
EARLY_CLAIMED=0
RELEASED=1

# measure_budget: every reading the budget verdict needs, re-runnable (the --wait loop re-measures
# on each poll while at the head). No `local`: the names below are read by the rest of the script.
measure_budget() {
OCC_TARGET="$WORKTREE/testing_runner_workers.py"
OCC_OUT="$("$CONDA_PY" "$OCC_TARGET" --occupancy 2>/dev/null)"
if printf '%s\n' "$OCC_OUT" | grep -q '^occupancy='; then
    OCCUPANCY="$(printf '%s\n' "$OCC_OUT" | awk -F= '/^occupancy=/{print $2; exit}')"
    OCC_REASON="$(printf '%s\n' "$OCC_OUT" | awk -F= '/^reason=/{print $2; exit}')"
    OCC_DETAIL="$(printf '%s\n' "$OCC_OUT" | awk -F= '/^detail=/{printf "%s ", $2}')"
    # Unmeasurable (python/module missing, ps unreadable inside the driver) fails OPEN -- same
    # contract the driver's own `_worker_slot_occupancy` already documents: an unmeasurable count
    # is not evidence the machine is busy. Never silent: the reason is named in the header line.
    if ! [ "${OCCUPANCY:-}" -ge 0 ] 2>/dev/null; then
        OCCUPANCY=0
        OCC_REASON="${OCC_REASON:-delegation_unreachable}"
    fi
elif [ ! -f "$OCC_TARGET" ]; then
    OCCUPANCY=0
    OCC_REASON="occupancy_cli_absent"
    OCC_DETAIL=""
else
    # The file exists (an old worktree still carries testing_runner_workers.py) but the ONE real
    # invocation produced no occupancy= line -- either it predates --occupancy entirely (the
    # verified ddd3842e0 shape: exit 0, empty stdout) or it exists but is broken in some other
    # way. Either way this is "the CLI this wrapper expects is not there", never a subprocess
    # failure to reach the module at all -- occupancy_cli_absent, not delegation_unreachable.
    OCCUPANCY=0
    OCC_REASON="occupancy_cli_absent"
    OCC_DETAIL=""
fi
NPROC="$(nproc 2>/dev/null || echo 16)"
# RESERVE = 2 (the machine owner's own direct correction, relayed by assistant, 2026-09-09,
# superseding a provisional 4): "RESERVE should be 1-2, not 4" -- headroom for the owner's own
# interactive use (editor, browser, shells) on this live machine. 2 (not 1) matches the
# Platform-side driver fix's own RESERVE_CORES (testing_runner_workers.py), so the two budgets
# agree with each other as well as with the owner's own stated preference -- main's flagged
# discrepancy (2026-09-09 13:56), confirmed no ruling supersedes this, one-line follow-up to c988306.
RESERVE=2
BUDGET=$((NPROC - RESERVE))
FREE_GIB="$(free -g 2>/dev/null | awk '/^Mem:/ {print $7}')"
[ -z "${FREE_GIB:-}" ] && FREE_GIB="(unmeasured)"
# ⛔ HISTORY, NOT PRESSURE -- printed only, never gates (fable's correction #124, 2026-09-09
# 03:38): once pages are swapped out, Linux leaves them there until swapoff/swapon or a reboot,
# neither of which the fleet does on this live workstation. `swap free` staying near zero
# for the rest of the night says nothing about whether THIS run would add new pressure.
SWAP_USED_GIB="$(free -g 2>/dev/null | awk '/^Swap:/ {print $3}')"
[ -z "${SWAP_USED_GIB:-}" ] && SWAP_USED_GIB="(unmeasured)"
# The real pressure signal (fable's correction #124, units/since-boot fix #125, 2026-09-09
# 06:06, mail 20260909T060646): ACTIVE swapping, si+so (KiB/s -- `man vmstat`'s own `-S` unit,
# default K=1024, a kilobyte rate, never a page-count rate) summed across THREE LIVE 1-second
# samples.
# ⛔⛔ `-y` (procps' own `--no-first`), NOT a bare `vmstat 1 3` -- `man vmstat`: "The first
# report produced gives averages since the last reboot." A bare `vmstat 1 3 | tail -n +3` keeps
# that since-boot line as if it were a live sample, baking a CONSTANT (measured ~171 on this
# 17-day-uptime box) into every reading -- harmless today, but after a reboot followed by one
# heavy swap episode that constant alone (e.g. ~3200 on a fresh reboot) would refuse every
# battery for hours on an otherwise-idle machine, the same permanently-closed-door shape #124
# withdrew, just slower to close. `vmstat -y 1 3 | tail -n +3` gives exactly three LIVE samples,
# verified directly against this box's own output (`cat -n`'d, confirmed 3 data lines, none
# matching the inflated since-boot row). This costs ~3 real seconds per invocation -- accepted,
# since a false GO on a genuinely thrashing box is what killed a FULL battery mid-run tonight.
SWAP_ACTIVITY="$(vmstat -y 1 3 2>/dev/null | tail -n +3 | awk '{s+=$7+$8} END {print s+0}')"
[ -z "${SWAP_ACTIVITY:-}" ] && SWAP_ACTIVITY=0
# T-762 §3.4: slots reserved by runs admitted from the queue moments ago, whose worker children
# the occupancy reader cannot see yet (bin/battery_queue.sh, expires on its own).
RESERVED_SLOTS="$(bq_reserved_slots)"
OCCUPANCY_EFF=$((OCCUPANCY + RESERVED_SLOTS))
}
budget_header() {
echo "▶ concurrency budget: occupancy=${OCCUPANCY}/${BUDGET} worker slots (+${RESERVED_SLOTS} reserved by just-admitted queue heads; reason=${OCC_REASON:-ok}, detail: ${OCC_DETAIL:-none}; nproc=${NPROC}, RESERVE=${RESERVE}), ${FREE_GIB}Gi available memory, ${SWAP_USED_GIB}Gi swap used (history), swap activity ${SWAP_ACTIVITY} KiB/s over 3 live samples (pressure)"
}

# fable's follow-up ruling (2026-09-09 03:37, corrected 03:38 -- #124): the incident was memory
# PRESSURE, not process count alone -- two keys, applying regardless of gate mode (low memory
# threatens any new heavy process, not only a --gate full one). Floors are a FIRST SETTING
# measured against tonight's own readings -- re-set from data if they ever refuse a run that
# would genuinely have been fine.
# budget_verdict: 0 = go; 1 = refuse, with the full refusal text in BUDGET_REFUSAL. The caller
# decides whether that text is a hard exit (no --wait) or one more poll (--wait). The three
# rules below are unchanged from their inline form; only the echo/exit became text/return.
_refuse_line() { BUDGET_REFUSAL+="$1"$'\n'; }
budget_verdict() {
BUDGET_REFUSAL=""
if [ "$FREE_GIB" != "(unmeasured)" ] && [ "$FREE_GIB" -lt 6 ]; then
    _refuse_line "⛔ REFUSED: available memory below the budget floor (6 GiB) -- ${FREE_GIB}Gi available"
    _refuse_line "   (fable's ruling, 2026-09-09 03:37, after memory pressure killed a FULL battery"
    _refuse_line "   mid-run tonight). Wait for memory to free up, or retry later."
    return 1
fi
if [ "$SWAP_ACTIVITY" -gt 1000 ]; then
    _refuse_line "⛔ REFUSED: active swapping detected -- si+so summed over 3 LIVE vmstat samples ="
    _refuse_line "   ${SWAP_ACTIVITY} KiB/s (fable's ruling #124/#125, 2026-09-09 03:38/06:06: swap USED"
    _refuse_line "   is a high-water mark that never clears on its own; ACTIVE swapping, in KiB/s, is the"
    _refuse_line "   real pressure signal). Wait for it to settle, or retry later."
    return 1
fi

# ⛔⛔ RE-BASED 2026-09-09 (fable's #134 ruling): the old rule refused by INVOCATION count
# ("full needs zero others; fast allows at most one other") -- both readings are now WRONG under
# a pooled default, since one compliant "other" can itself be up to `nproc-2` worker processes.
# The rule is now WORKER-SLOT budget, one formula for both gate modes: refuse when
# `occupancy + requested > budget`. `--gate full` requests 1 (always serial). `--gate fast`
# requests 4 -- not its own eventual worker count (only `testing_runner_workers.py` itself,
# foundation's own side of this same ruling, knows that: it shrinks `--workers auto` to
# `min(nproc-2, budget-occupancy)` and refuses THERE if that would leave fewer than 4 workers) --
# 4 is the WRAPPER's own pre-flight floor, refusing cheaply, before any launch, in the clearly-
# hopeless case where even a minimal pool has no room; a launch that clears this check but still
# cannot fit a real pool is caught by the driver's own refusal instead, never silently downgraded
# to a near-serial "parallel" run.
if [ "$GATE" = "full" ]; then
    REQUESTED=1
else
    REQUESTED=4
fi
if [ $((OCCUPANCY_EFF + REQUESTED)) -gt "$BUDGET" ]; then
    _refuse_line "⛔ REFUSED: worker-slot budget exceeded -- occupancy=${OCCUPANCY}+${RESERVED_SLOTS} reserved (${OCC_DETAIL:-none}),"
    _refuse_line "   this launch requests ${REQUESTED} more, budget=${BUDGET} (nproc=${NPROC} -"
    _refuse_line "   RESERVE=${RESERVE}). fable's ruling #134, 2026-09-09 13:36, after --workers auto"
    _refuse_line "   saturated every core beside a serial FULL run and the machine owner had to"
    _refuse_line "   manually drain swap on his own live workstation. Wait for a slot to free up, or retry later --"
    _refuse_line "   do not bypass this check by hand."
    return 1
fi
return 0
}

# T-762 §3.4: the queue. See bin/battery_queue.sh for the ticket protocol.
_sharedcorpus_holder() {
    local d="${AIMAIL_CLAIMS:-/tmp/aimail-gate-claims}/sharedcorpus"
    [ -d "$d" ] || return 1
    cat "$d"/* 2>/dev/null | head -n 1 | cut -d'|' -f1
}
_early_release() {
    bq_unreserve "$SEAT" "$$"
    [ -n "${WAIT_TICKET:-}" ] && bq_drop "$WAIT_TICKET"
    if [ "$EARLY_CLAIMED" -eq 1 ] && [ "$RELEASED" -eq 0 ]; then
        RELEASED=1
        bash "$AIMAIL_BIN_SELF/gateclaim.sh" --release sharedcorpus "$SEAT" 2>&1 | tee -a "$SUMMARY"
    fi
}
wait_for_admission() {
    local start now deadline k n reason state last_state="" head poll
    poll="${BATTERY_WAIT_POLL_S:-30}"
    WAIT_TICKET="$(bq_take "$GATE" "$SEAT" "$$" "$REQUESTED")" || {
        echo "⛔ REFUSED: could not create a queue ticket in $(bq_dir)" >&2; exit 2; }
    trap _early_release EXIT
    start="$(date +%s)"
    deadline=$((start + WAIT_MIN * ${BATTERY_WAIT_MINUTE_S:-60}))
    read -r k n <<<"$(bq_position "$WAIT_TICKET")"
    summ "▶ WAIT: queued as $(bq_describe "$WAIT_TICKET"), ticket $WAIT_TICKET, position $k of $n (--wait ${WAIT_MIN} min, poll ${poll}s; queue: $(bq_dir))"
    while :; do
        read -r k n <<<"$(bq_position "$WAIT_TICKET")"
        if [ "$k" -eq 0 ]; then
            # our ticket vanished (queue dir wiped, or a sweeper misjudged us) -- re-take, keep waiting
            WAIT_TICKET="$(bq_take "$GATE" "$SEAT" "$$" "$REQUESTED")" || { echo "⛔ REFUSED: lost the queue ticket and could not re-take it" >&2; exit 2; }
            read -r k n <<<"$(bq_position "$WAIT_TICKET")"
        fi
        reason=""
        if [ "$k" -ne 1 ]; then
            head="$(bq_head)"
            reason="position $k of $n, behind $(bq_describe "$head")"
        else
            measure_budget
            if ! budget_verdict; then
                reason="at the head; $(printf '%s' "$BUDGET_REFUSAL" | head -n 1 | sed 's/^⛔ REFUSED: //')"
            elif [ "$GATE" = "full" ]; then
                if _sharedcorpus_holder >/dev/null; then
                    reason="at the head; sharedcorpus held by $(_sharedcorpus_holder)"
                else
                    CLAIM_OUT="$(bash "$AIMAIL_BIN_SELF/gateclaim.sh" sharedcorpus "$SEAT" --desc "$DESC" 2>&1)"
                    if [ $? -eq 0 ]; then
                        EARLY_CLAIMED=1; RELEASED=0
                        printf '%s\n' "$CLAIM_OUT" | tee -a "$SUMMARY"
                    else
                        reason="at the head; sharedcorpus claim lost a race: $(printf '%s' "$CLAIM_OUT" | head -n 1)"
                    fi
                fi
            fi
        fi
        if [ -z "$reason" ]; then break; fi
        state="$reason"
        if [ "$state" != "$last_state" ]; then summ "▶ WAIT: $state"; last_state="$state"; fi
        now="$(date +%s)"
        if [ "$now" -ge "$deadline" ]; then
            summ "⛔ WAIT TIMED OUT after ${WAIT_MIN} min ($(( (now - start) ))s): last state: $state"
            exit 5
        fi
        sleep "$poll"
    done
    now="$(date +%s)"
    bq_reserve "$SEAT" "$$" "$REQUESTED" >/dev/null
    bq_drop "$WAIT_TICKET"; WAIT_TICKET=""
    summ "▶ WAIT: admitted after $((now - start))s (reserved ${REQUESTED} starting slot(s) for ${BATTERY_QUEUE_START_GRACE_S}s)"
    if [ "${BATTERY_QUEUE_EXIT_AFTER_ADMIT:-0}" = "1" ]; then
        summ "▶ WAIT: BATTERY_QUEUE_EXIT_AFTER_ADMIT=1 (test knob) -- exiting before any launch"
        exit 0
    fi
}

measure_budget
budget_header
if [ -n "$WAIT_MIN" ]; then
    wait_for_admission
else
    LIVE_QUEUE="$(bq_live_tickets)"
    if [ -n "$LIVE_QUEUE" ]; then
        echo "⛔ REFUSED: $(printf '%s\n' "$LIVE_QUEUE" | grep -c .) launch(es) are queued for a slot (head: $(bq_describe "$(bq_head)")) --" >&2
        echo "   pass --wait <minutes> to join the queue rather than jump it (T-762 §3.4)." >&2
        echo "   \`$AIMAIL_BIN_SELF/battery_queue.sh --list\` shows the queue." >&2
        exit 2
    fi
    if ! budget_verdict; then
        printf '%s' "$BUDGET_REFUSAL" >&2
        echo "   Pass --wait <minutes> to queue for a slot instead of retrying by hand (T-762 §3.4)." >&2
        exit 2
    fi
fi

AIMAIL_BIN="$AIMAIL_BATTERY_SELF/bin"
: "${POC_ROOT:?POC_ROOT not set -- copy etc/aimail.conf.example to etc/aimail.conf and fill it in}"
ENV_SOURCE="$PLATFORM_ROOT/zignore/.env"
# c7 (fable, 2026-09-08 13:00 ruling on main's path check): BOTH baseline files are compared
# against their COMMITTED target-project copies, never a /tmp file -- a /tmp-only compare
# target resets to nothing on a reboot and is exactly the non-durability T-719 already fixed for
# baseline_norm.txt's own sibling. The /tmp paths below are now OUTPUT the wrapper writes for its
# own run record (so a report always has a same-run copy to point at), never what it reads to
# decide pass/fail.
# T-762: the FAST gate's own pair, separate files, separate population (testing/ only, sealed
# empty for failures) -- never compared against the FULL gate's own pair below, and vice versa.
# ⛔⛔ baseline_test_count.txt (FULL, all-tier) is GONE (fable's ruling, 2026-09-09 06:26/06:28,
# item 3) -- it was a hand-maintained shadow of unit + system that every FAST-gated,
# unit-only-touching landing silently broke (and vice versa for a system-only landing), which is
# exactly what stranded main's own T-751 landing 30 tests off for one gate cycle tonight. The
# FULL count is now DERIVED at check time as unit + system, every run, from the two Ran-
# denominated tier files below -- one source, no shadow copy, nothing to remember to bump twice.
# Both `baseline_test_count_unit.txt` and `baseline_test_count_system.txt` are RAN-denominated by
# construction (the number printed by a real `Ran N tests` line, never `countTestCases()`'s own
# COLLECTED number -- those differ by the class-collapse gap, a repeat mistake caught twice
# tonight, #126). The comment lives here so the next bump does not have to relearn the history.
# ⛔⛔ THESE FIVE PATHS ARE BUILT LATER IN THIS FILE, FROM `$WORKTREE`, NOT HERE FROM
# `$PLATFORM_ROOT` (fable's ruling, 2026-09-09 07:18) -- moved below the `$WORKTREE` existence
# check (search "baseline paths read from the gated WORKTREE"). The root checkout is a
# DIFFERENT tree from the one under gate, is the tree the recipe says nobody edits, and can sit
# unmaterialized for weeks after an update-ref-only landing -- the least reliable copy of a
# committed file on the machine. A chain that bumps a baseline can never pass COUNT/NAME_SET
# against the root before landing (measured tonight: this pair's own COUNT_EXIT read a SKIP
# against the stale root, not a real comparison); the reverse also breaks (a FULL gate on an
# older tip reading the root's NEWER baselines refuses for a landing that is not its own). The
# committed baseline IS part of the tip under gate -- a bump is a visible commit in the chain.

# Every non-optional name the target project's own environment-config module reads
# (`get_env_var(...)` with no `is_optional=True`), minus SENTRY_DSN -- that one is handled
# separately, below, as a literal `''`, never read from ENV_SOURCE. This list is entirely
# project-specific (real product schema, not generic to this tool), so it lives in this
# machine's own gitignored etc/aimail.conf (see etc/aimail.conf.example) rather than here.
# Re-derive it by re-grepping that project's own environment-config module if its required set
# ever changes; it is not auto-derived here because auto-deriving it would mean this script
# executes untrusted code from the very file it exists to work around the absence of.
REQUIRED_ENV_NAMES=("${REQUIRED_ENV_NAMES[@]:-}")
if [ "${#REQUIRED_ENV_NAMES[@]}" -eq 0 ] || [ -z "${REQUIRED_ENV_NAMES[0]}" ]; then
    echo "⛔ REFUSED: REQUIRED_ENV_NAMES not set -- copy etc/aimail.conf.example to etc/aimail.conf and fill it in." >&2
    exit 1
fi

# REAL-TIER MODULES (fable, 2026-09-08 22:03 ruling, T-765 stopgap): `run_unit_tests.py`'s own
# `_filter_suite` correctly excludes any `BaseTestClass` subclass from the plain battery, but
# nothing in this fleet's standing practice then RUNS what got excluded -- `run_system_tests.py`
# discovers ONLY `testing_system/`, never `testing/`, so a file tiered this way goes silently
# inert (the same shape T-627b/T-649's own acceptance tests were already found in). This table is
# the stopgap until a real, durable real-tier entry point exists (main's own ticket, per the
# ruling): one `python -m unittest <module>` per entry, under this wrapper's own env-by-name
# supply, reported in the summary block as its own named line -- never folded into
# BATTERY_EXIT/COUNT_EXIT/NAME_SET_EXIT, and never silently passing. Add the next tiered file as
# one more line here, not a new mechanism.
REAL_TIER_MODULES=(
    testing.test_dependencies
)

# WORKTREE/SEAT/DESC and the two worktree guard checks (root-checkout refusal, existence check)
# were moved up to right after argument parsing (T-804 follow-up, fable's 2026-09-09 22:56
# ruling) -- the occupancy delegation needs a validated $WORKTREE before it can safely reference
# it. Nothing else changes here; this comment is a pointer for whoever next greps for them.

# baseline paths read from the gated WORKTREE -- see the comment near BASELINE_NORM_FILE_FULL's
# own prior declaration site, above, for why $PLATFORM_ROOT (the root checkout, a different tree
# than the one under gate) was the wrong source. A baseline bump is a committed file in THIS
# tip's own chain; the gate reads it as part of that diff, the same way it reads everything else
# about the tip.
BASELINE_NORM_FILE_FULL="$WORKTREE/baseline_norm.txt"
BASELINE_COUNT_FILE_FAST="$WORKTREE/baseline_test_count_unit.txt"
BASELINE_NORM_FILE_FAST="$WORKTREE/baseline_norm_unit.txt"
BASELINE_COUNT_FILE_SYSTEM="$WORKTREE/baseline_test_count_system.txt"
if [ "$GATE" = "fast" ]; then
    BASELINE_COUNT_FILE="$BASELINE_COUNT_FILE_FAST"
    BASELINE_NORM_FILE="$BASELINE_NORM_FILE_FAST"
    RUN_COUNT_LOG_FILE="/tmp/baseline_test_count_unit.txt"
    RUN_NORM_LOG_FILE="/tmp/baseline_norm_unit.txt"
else
    BASELINE_NORM_FILE="$BASELINE_NORM_FILE_FULL"
    RUN_COUNT_LOG_FILE="/tmp/baseline_test_count.txt"
    RUN_NORM_LOG_FILE="/tmp/baseline_norm.txt"
fi
if [ "$GATE" = "full" ] && [ ! -d "$POC_ROOT/src/outputs" ]; then
    echo "⛔ REFUSED: POC src/outputs not found at $POC_ROOT/src/outputs -- check POC_ROOT in this script" >&2
    exit 2
fi

# The worktree-local-.env refusal (fable, 2026-09-08 12:05, item c1): this lane's safety property
# is "no .env reachable from the worktree", because `load_environment_variables(override=True)`
# reloads and overrides the process env at import time from EXACTLY these two paths. This script
# never deletes another seat's file -- it only refuses to run somewhere that would silently defeat
# every export it is about to make.
if [ -e "$WORKTREE/.env" ] || [ -e "$WORKTREE/zignore/.env" ]; then
    echo "⛔ REFUSED: worktree carries its own .env or zignore/.env." >&2
    echo "   config/environment_config.py's load_environment_variables(override=True) reloads and" >&2
    echo "   OVERRIDES the process env from these exact paths at import time, which silently" >&2
    echo "   defeats every export this wrapper makes (measured, fable's 2026-09-08 12:05 ruling)." >&2
    echo "   This script never deletes another seat's file -- remove it from THIS worktree if it" >&2
    echo "   is yours to remove, or use a worktree that never had one." >&2
    [ -e "$WORKTREE/.env" ] && echo "   found: $WORKTREE/.env" >&2
    [ -e "$WORKTREE/zignore/.env" ] && echo "   found: $WORKTREE/zignore/.env" >&2
    exit 2
fi

if [ ! -f "$ENV_SOURCE" ]; then
    echo "⛔ REFUSED: env source file not found: $ENV_SOURCE" >&2
    exit 2
fi

# Allowlisted `^NAME=` lookup, one name at a time -- never `source`/`set -a` on ENV_SOURCE (that
# would import every name it defines, including ones this list deliberately excludes), and this
# script never echoes a value, only names, in any log line.
ENV_ASSIGNMENTS=()
MISSING_NAMES=()
for name in "${REQUIRED_ENV_NAMES[@]}"; do
    line="$(grep -m1 -E "^${name}=" "$ENV_SOURCE")"
    if [ -z "$line" ]; then
        MISSING_NAMES+=("$name")
        continue
    fi
    value="${line#*=}"
    # Strip one layer of surrounding double quotes, matching python-dotenv's own convention.
    value="${value%\"}"
    value="${value#\"}"
    ENV_ASSIGNMENTS+=("${name}=${value}")
done

if [ "${#MISSING_NAMES[@]}" -gt 0 ]; then
    echo "⛔ REFUSED: env source is missing ${#MISSING_NAMES[@]} required name(s): ${MISSING_NAMES[*]}" >&2
    echo "   source: $ENV_SOURCE" >&2
    exit 2
fi

if [ "$GATE" = "full" ]; then
    CLEAN_BEFORE="$(git -C "$POC_ROOT" status --porcelain -- src/outputs)"
    if [ -n "$CLEAN_BEFORE" ]; then
        echo "⛔ REFUSED: POC src/outputs is already dirty -- a battery here would read poisoned" >&2
        echo "   inputs, and any result would be void by the same ruling that voided 2026-09-07's" >&2
        echo "   collision. git status --porcelain -- src/outputs:" >&2
        echo "$CLEAN_BEFORE" >&2
        exit 4
    fi

    if [ "$EARLY_CLAIMED" -eq 1 ]; then
        summ "▶ sharedcorpus already claimed at queue admission (--wait), not re-claimed"
    else
    CLAIM_OUT="$(bash "$AIMAIL_BIN/gateclaim.sh" sharedcorpus "$SEAT" --desc "$DESC" 2>&1)"
    CLAIM_EXIT=$?
    printf '%s\n' "$CLAIM_OUT" | tee -a "$SUMMARY"
    if [ "$CLAIM_EXIT" -ne 0 ]; then
        echo "⛔ REFUSED: sharedcorpus is already held -- see the message above for the holder." >&2
        echo "   A battery run here would collide with theirs (2026-09-07 incident: both runs voided)." >&2
        echo "   Pass --wait <minutes> to queue for it instead of retrying by hand (T-762 §3.4)." >&2
        exit 3
    fi
    fi
fi
# T-762: fast never claims sharedcorpus -- nothing under testing/ reads the real corpus, so
# there is nothing this claim would protect, and claiming it anyway would make every fast gate
# queue behind full gates for no reason.

RELEASED=1
if [ "$GATE" = "full" ]; then
    RELEASED=0
fi

# T-762 §3.5 (fable's throughput design, 2026-09-21): a kill mid-run used to leave nothing
# behind -- no summary line, no released claim, the occupancy reader (and any seat checking
# later) sees an ambiguous state indistinguishable from "still running". TESTS_STARTED/
# TESTS_COMPLETED bracket the one long-running call below so the SAME combined handler can
# tell "we were interrupted mid-test-run" (write KILLED) from "the script is exiting normally
# after finishing" (say nothing kill-related) -- both cases still release sharedcorpus on a
# FULL gate, exactly as release_once already did; this is that function, widened.
TESTS_STARTED=0
TESTS_COMPLETED=0
KILL_SUMMARY_WRITTEN=0
LOG="/tmp/canonical_battery_${SEAT}_${TS}.log"
on_exit_or_signal() {
    local sig="${1:-EXIT}"
    bq_unreserve "$SEAT" "$$"
    if [ "$KILL_SUMMARY_WRITTEN" -eq 0 ] && [ "$sig" != "EXIT" ] \
       && [ "$TESTS_STARTED" -eq 1 ] && [ "$TESTS_COMPLETED" -eq 0 ]; then
        KILL_SUMMARY_WRITTEN=1
        local n_tests=0
        if [ -n "${LOG:-}" ] && [ -f "$LOG" ]; then
            n_tests="$(grep -cE '\.\.\. (ok|FAIL|ERROR)\s*$' "$LOG" 2>/dev/null)"
            [ -z "$n_tests" ] && n_tests=0
        fi
        summ "KILLED $sig at $(date -u +%Y-%m-%dT%H:%M:%SZ), ${n_tests} tests run so far"
    fi
    if [ "$GATE" = "full" ] && [ "$RELEASED" -eq 0 ]; then
        RELEASED=1
        bash "$AIMAIL_BIN/gateclaim.sh" --release sharedcorpus "$SEAT" 2>&1 | tee -a "$SUMMARY"
    fi
}
trap on_exit_or_signal EXIT
trap 'on_exit_or_signal TERM; exit 143' TERM
trap 'on_exit_or_signal INT; exit 130' INT
trap 'on_exit_or_signal HUP; exit 129' HUP

if [ "$GATE" = "full" ]; then
    BACKUP_DIR="$(mktemp -d)"
    BACKUP="$BACKUP_DIR/src_outputs_backup.tar.gz"
    tar -czf "$BACKUP" -C "$POC_ROOT/src" outputs
    echo "▶ src/outputs backed up to $BACKUP"
fi

WORKTREE_HEAD="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || echo "unknown")"
POC_ROOT_RESOLVED="$(cd "$WORKTREE" && TAKEOFF_POC_ROOT="$POC_ROOT" "$CONDA_PY" -c \
    "from testing.takeoff_tests._platform_env import poc_root; print(poc_root())" 2>/dev/null)"
[ -z "$POC_ROOT_RESOLVED" ] && POC_ROOT_RESOLVED="(unresolved -- see log for the child's own stderr)"

TIER_FLAG=()
# T-775 adoption (fable's ruling, 2026-09-09 07:41, after T-782/T-783 closed the sealed
# blockers): FAST gates run --workers auto. The machine concurrency budget above (process
# count, memory pressure, live-swap check) is the guard that made this safe to turn on --
# nothing new here. FULL stays serial control (the reference every parallel FAST result is
# compared against); a --timing run stays serial too (per-module elapsed under a pool
# measures contention, not wall time) -- this wrapper never passes --timing alongside
# --workers, so no conflict is possible here, but the exclusion is named per fable's item 4
# regardless, since a future edit to this file must not casually add one.
[ "$GATE" = "fast" ] && TIER_FLAG=(--tier unit --workers auto)

summ "▶ gate mode:       $GATE"
summ "▶ worktree:        $WORKTREE"
summ "▶ worktree HEAD:   $WORKTREE_HEAD"
echo "▶ poc_root() (child resolves it): $POC_ROOT_RESOLVED"
echo "▶ env source:       $ENV_SOURCE"
echo "▶ exported names:  ${REQUIRED_ENV_NAMES[*]} SENTRY_DSN TAKEOFF_POC_ROOT"
echo "▶ conda python:    $CONDA_PY"
echo "▶ running canonical battery ($GATE) ... (log: $LOG)"

TESTS_STARTED=1
( cd "$WORKTREE" && env "${ENV_ASSIGNMENTS[@]}" SENTRY_DSN='' TAKEOFF_POC_ROOT="$POC_ROOT" \
    "$CONDA_PY" run_unit_tests.py "${TIER_FLAG[@]}" ) > "$LOG" 2>&1
BATTERY_EXIT=$?
TESTS_COMPLETED=1

# REAL-TIER MODULES run (fable, 2026-09-08 22:03 ruling): each entry in REAL_TIER_MODULES is run
# separately, under the SAME env-by-name supply, and reported by name -- never silently, never
# folded into the unit result above.
# ⛔ T-774 (2026-09-08): the module-scoped T-592 exemption this block used to carry (a note
# sparing testing.test_dependencies' own raw exit from the aggregate, for its then-known
# "unexpected success" quirk under python -m unittest) is REMOVED here, paired with the same-day
# commit that resolved T-592 on its own terms (the stale @expectedFailure decorator came out of
# the test itself) -- an exemption that outlives the reason it was named for is exactly the
# disabled-not-fixed shape fable's own ruling warned against. If a future real-tier module needs
# a genuinely known, still-live quirk named here, name it the same way this one was (module-
# scoped, dated, tied to a real ticket) rather than reintroducing a general allowance.
REAL_TIER_EXIT=0
REAL_TIER_SUMMARY=()
if [ "$GATE" = "full" ]; then
    for module in "${REAL_TIER_MODULES[@]}"; do
        RT_LOG="/tmp/canonical_battery_realtier_${SEAT}_${TS}_${module}.log"
        ( cd "$WORKTREE" && env "${ENV_ASSIGNMENTS[@]}" SENTRY_DSN='' TAKEOFF_POC_ROOT="$POC_ROOT" \
            "$CONDA_PY" -m unittest "$module" ) > "$RT_LOG" 2>&1
        rt_exit=$?
        rt_ran_line="$(grep -E '^Ran [0-9]+ tests? in' "$RT_LOG" | tail -1)"
        rt_ran_count="$(echo "$rt_ran_line" | grep -oE '^Ran [0-9]+' | grep -oE '[0-9]+')"
        if [ "$rt_exit" -ne 0 ]; then
            REAL_TIER_EXIT=1
        fi
        REAL_TIER_SUMMARY+=("REAL_TIER_EXIT[$module]=$rt_exit (${rt_ran_count:-0} tests, log: $RT_LOG)")
    done
fi
# T-762: fast skips REAL_TIER_MODULES entirely -- they need a DB, which fast's own definition
# (mocked, no sharedcorpus) does not supply.

# FLEET TESTS (2026-09-29): the guard-style tests that police our own tooling live in the
# zignore repo (zignore/fleet_tests), not in Platform, so coworkers' CI never runs them -- but the
# fleet still needs them or they protect nothing. Run here, in BOTH gates, against this worktree:
# run_fleet_tests.py builds a throwaway tree around $WORKTREE (nothing is written into it) and
# `--fast` leaves out the ~450 s probe-compile module (a probe edit, not a Platform edit, is what
# that one checks; run it without --fast after touching a probe). Measured 122 s to 202 s (under load), and it is
# added to EVERY gate, fast and full. Skipped, said so, when the hub has no fleet_tests directory.
FLEET_TESTS_EXIT=0
FLEET_TESTS_DESC="not run (no $PLATFORM_ROOT/zignore/fleet_tests/run_fleet_tests.py)"
FLEET_RUNNER="$PLATFORM_ROOT/zignore/fleet_tests/run_fleet_tests.py"
if [ -f "$FLEET_RUNNER" ]; then
    FLEET_LOG="/tmp/canonical_battery_fleet_${SEAT}_${TS}.log"
    ( cd "$WORKTREE" && env "${ENV_ASSIGNMENTS[@]}" SENTRY_DSN='' TAKEOFF_POC_ROOT="$POC_ROOT" \
        "$CONDA_PY" "$FLEET_RUNNER" --checkout "$WORKTREE" --fast ) > "$FLEET_LOG" 2>&1
    FLEET_TESTS_EXIT=$?
    fleet_ran_line="$(grep -E '^Ran [0-9]+ tests? in' "$FLEET_LOG" | tail -1)"
    FLEET_TESTS_DESC="${fleet_ran_line:-no Ran line} (log: $FLEET_LOG)"
    # No Ran line, or "Ran 0 tests", means the runner never reached the tests: a refusal, not a pass.
    fleet_ran_count="$(echo "$fleet_ran_line" | grep -oE '^Ran [0-9]+' | grep -oE '[0-9]+')"
    [ "${fleet_ran_count:-0}" -eq 0 ] && FLEET_TESTS_EXIT=1
fi

RAN_LINE="$(grep -E '^Ran [0-9]+ tests? in' "$LOG" | tail -1)"
RESULT_LINE="$(grep -E '^(OK|FAILED) ?(\(.*\))?$' "$LOG" | tail -1)"
RAN_COUNT="$(echo "$RAN_LINE" | grep -oE '^Ran [0-9]+' | grep -oE '[0-9]+')"

# The collected-count check (fable, 2026-09-08 12:05, item c4): a second never-silent check
# alongside the FAIL/ERROR name-set diff. A count that differs from the recorded baseline run's
# own count is a refusal, named, not a warning -- a reduced collection (e.g. an env-guard that
# skips more than the baseline run did) must never pass silently as a full run.
COUNT_EXIT=0
if [ -n "$RAN_COUNT" ]; then
    echo "$RAN_COUNT" > "$RUN_COUNT_LOG_FILE"
fi
# ⛔⛔ A MISSING baseline file REFUSES, it does not warn-and-pass (fable's ruling, 2026-09-09
# 06:54): "collected-count check skipped this run" is a count check that passes without
# checking. Tolerable when one hand-maintained file could only go missing by accident; with two
# tier files feeding the FULL check, that state is exactly what a half-landed cross-repo
# transition produces (this wrapper commit landing before, or after, the Platform commit that
# creates/deletes these files) -- a FULL gate started in that window must not report
# COUNT_EXIT=0 on nothing. Applied to BOTH branches for the same reason: neither
# baseline_test_count_unit.txt nor baseline_test_count_system.txt has a live bootstrap case any
# more (both are already committed, permanent files at this point in the project) -- a missing
# one now means something broke, not that a baseline has yet to be established.
if [ "$GATE" = "fast" ]; then
    BASELINE_COUNT_DESC="$BASELINE_COUNT_FILE"
    if [ -f "$BASELINE_COUNT_FILE" ]; then
        BASELINE_COUNT="$(cat "$BASELINE_COUNT_FILE")"
        if [ -n "$RAN_COUNT" ] && [ "$RAN_COUNT" != "$BASELINE_COUNT" ]; then
            echo "⛔ REFUSED: collected test count ($RAN_COUNT) differs from the baseline run's own count ($BASELINE_COUNT, from $BASELINE_COUNT_FILE)." >&2
            echo "   A reduced (or enlarged) collection is not battery-comparable -- see \"$RAN_LINE\"." >&2
            COUNT_EXIT=1
        fi
    else
        echo "⛔ REFUSED: no baseline test count on record at $BASELINE_COUNT_FILE." >&2
        echo "   A missing baseline file is not a warning -- see fable's ruling, 2026-09-09 06:54." >&2
        COUNT_EXIT=1
    fi
else
    # FULL: DERIVED as unit + system (fable's ruling, 2026-09-09 06:26, item 3) -- no single
    # hand-maintained file to fall out of sync with either tier's own bump.
    BASELINE_COUNT_DESC="$BASELINE_COUNT_FILE_FAST + $BASELINE_COUNT_FILE_SYSTEM (derived sum)"
    if [ -f "$BASELINE_COUNT_FILE_FAST" ] && [ -f "$BASELINE_COUNT_FILE_SYSTEM" ]; then
        BASELINE_COUNT_UNIT_VAL="$(cat "$BASELINE_COUNT_FILE_FAST")"
        BASELINE_COUNT_SYSTEM_VAL="$(cat "$BASELINE_COUNT_FILE_SYSTEM")"
        BASELINE_COUNT="$((BASELINE_COUNT_UNIT_VAL + BASELINE_COUNT_SYSTEM_VAL))"
        if [ -n "$RAN_COUNT" ] && [ "$RAN_COUNT" != "$BASELINE_COUNT" ]; then
            echo "⛔ REFUSED: collected test count ($RAN_COUNT) differs from the derived FULL baseline" >&2
            echo "   ($BASELINE_COUNT = unit $BASELINE_COUNT_UNIT_VAL + system $BASELINE_COUNT_SYSTEM_VAL," >&2
            echo "   from $BASELINE_COUNT_FILE_FAST + $BASELINE_COUNT_FILE_SYSTEM)." >&2
            echo "   A reduced (or enlarged) collection is not battery-comparable -- see \"$RAN_LINE\"." >&2
            COUNT_EXIT=1
        fi
    else
        echo "⛔ REFUSED: no baseline test count on record -- need both $BASELINE_COUNT_FILE_FAST" >&2
        echo "   and $BASELINE_COUNT_FILE_SYSTEM (fable's ruling, 2026-09-09 06:54: a missing" >&2
        echo "   tier file is not a warning -- likely a half-landed cross-repo transition." >&2
        echo "   Re-run once both files are present, on the landed tip -- a COUNT line from" >&2
        echo "   inside this window is not evidence." >&2
        COUNT_EXIT=1
    fi
fi

# c6 (fable, 2026-09-08 13:00 ruling): the wrapper computes the FAIL/ERROR name-set diff itself,
# against the COMMITTED baseline_norm.txt -- never a per-seat ad-hoc `comm` invocation against
# whichever path that seat happened to pick (the exact "two seats, two files" gap the 12:46
# one-canonical-file rule exists to close). A count matching but a name differing is exactly the
# 09-06 incident this check exists to catch (a swapped failure hiding behind a fixed one).
NAME_SET_EXIT=0
grep -E '^(FAIL|ERROR): ' "$LOG" | LC_ALL=C sort > "$RUN_NORM_LOG_FILE"
# ⛔⛔ A MISSING baseline_norm file REFUSES, it does not warn-and-pass (fable's ruling,
# 2026-09-09 06:57, the same hole as 68703d8's count-file fix, ruled the same way): "name-set
# check skipped this run" is a check that passes without checking. Both baseline_norm.txt
# (FULL) and baseline_norm_unit.txt (FAST) are already committed, permanent files with no live
# bootstrap case left -- a missing one now means something broke, not that a baseline has yet
# to be established.
if [ -f "$BASELINE_NORM_FILE" ]; then
    ONLY_IN_RUN="$(LC_ALL=C comm -23 "$RUN_NORM_LOG_FILE" "$BASELINE_NORM_FILE")"
    ONLY_IN_BASELINE="$(LC_ALL=C comm -13 "$RUN_NORM_LOG_FILE" "$BASELINE_NORM_FILE")"
    if [ -n "$ONLY_IN_RUN" ] || [ -n "$ONLY_IN_BASELINE" ]; then
        echo "⛔ REFUSED: FAIL/ERROR name-set differs from the committed baseline_norm.txt ($BASELINE_NORM_FILE)." >&2
        echo "   A name-set diff is the comparison, never a count -- a matching count can still hide" >&2
        echo "   a genuinely new failure behind a fixed one (the 2026-09-06 incident this check" >&2
        echo "   exists to catch)." >&2
        if [ -n "$ONLY_IN_RUN" ]; then
            echo "   only in THIS run (comm -23), not in the baseline:" >&2
            echo "$ONLY_IN_RUN" >&2
        fi
        if [ -n "$ONLY_IN_BASELINE" ]; then
            echo "   only in the BASELINE (comm -13), not in this run:" >&2
            echo "$ONLY_IN_BASELINE" >&2
        fi
        NAME_SET_EXIT=1
    fi
else
    echo "⛔ REFUSED: no committed baseline_norm file on record at $BASELINE_NORM_FILE." >&2
    echo "   A missing baseline file is not a warning -- see fable's ruling, 2026-09-09 06:57," >&2
    echo "   the same hole as the count-file fix (68703d8), ruled the same way." >&2
    NAME_SET_EXIT=1
fi

# T-762 follow-on (fable's ruling, 2026-09-09 03:04, the T-775 co-location-skip finding):
# per-test skip NAMES carried into the battery log beside the FAIL/ERROR set. NEVER a gate
# refusal -- a skip reason legitimately varies by environment -- purely informational, so a
# name that appears in one execution mode and not another (e.g. serial vs a parallel worker
# split) is SEEN by whoever reads the log, not silently absorbed into a bare `skipped=N` count.
# Matches testing/collected_accounting.py's own SKIP: prefix convention exactly.
SKIP_NAMES="$(grep -E '^SKIP: ' "$LOG" | LC_ALL=C sort)"
SKIPPED_COUNT="$(echo "$RESULT_LINE" | grep -oE 'skipped=[0-9]+' | grep -oE '[0-9]+')"
SKIP_NAMES_EXIT=0
if [ -n "$SKIP_NAMES" ]; then
    echo "skip_names (informational, never a gate refusal):"
    echo "$SKIP_NAMES"
else
    echo "skip_names (informational, never a gate refusal): 0 SKIP: line(s) found"
fi
# ⛔⛔ "informational never means silent when empty" (fable's own standing rule from tonight's
# three instances -- count file, norm file, skip names) -- and a step further: a check that
# CANNOT SEE its input is the missing-baseline-file hole in another coat (fable's ruling #130
# item c, 2026-09-09 11:12). This section's own SKIP_NAMES was inert on every run tonight,
# serial and parallel alike, until the SKIP: printer actually landed on both paths (T-746 chunk
# B follow-on) -- an inert check and a genuinely clean 0-skip run printed the SAME nothing, and
# nobody could tell them apart. If the runner's own summary reports skipped>0 but this section
# found ZERO `^SKIP: ` lines, REFUSE (distinct exit 2, not the generic 1 the other checks use)
# rather than silently reporting nothing.
if [ -n "$SKIPPED_COUNT" ] && [ "$SKIPPED_COUNT" -gt 0 ] && [ -z "$SKIP_NAMES" ]; then
    echo "⛔ REFUSED: the runner's own summary reports skipped=$SKIPPED_COUNT but this section" >&2
    echo "   found ZERO '^SKIP: ' lines in the log -- the skip-name instrument cannot see its" >&2
    echo "   own input (a format mismatch, a missing printer call, or similar), not a clean" >&2
    echo "   0-skip run. See fable's ruling, 2026-09-09 11:12, item c." >&2
    SKIP_NAMES_EXIT=2
fi

CORPUS_EXIT=0
if [ "$GATE" = "full" ]; then
    CLEAN_AFTER="$(git -C "$POC_ROOT" status --porcelain -- src/outputs)"
    if [ -z "$CLEAN_AFTER" ]; then
        echo "✔ src/outputs clean after the run (git status --porcelain -- src/outputs is empty)"
        CORPUS_EXIT=0
    else
        echo "⛔ src/outputs CHANGED during the run -- restoring from the pre-run backup now" >&2
        echo "$CLEAN_AFTER" >&2
        # RESTORE FIRST, delete nothing until the corpus is back to a known-good state --
        # a backup of a corpus known to be wrong must never be destroyed before it's used.
        rm -rf "$POC_ROOT/src/outputs"
        tar -xzf "$BACKUP" -C "$POC_ROOT/src"
        RESTORE_DIFF="$(git -C "$POC_ROOT" status --porcelain -- src/outputs)"
        if [ -z "$RESTORE_DIFF" ]; then
            echo "✔ src/outputs restored from the pre-run backup" >&2
        else
            echo "⛔⛔ RESTORE FAILED -- the backup is kept at $BACKUP, do not delete it by hand" >&2
            echo "log=$LOG"
            echo "$RAN_LINE"
            echo "$RESULT_LINE"
            echo "BATTERY_EXIT=$BATTERY_EXIT"
            echo "CORPUS_EXIT=1"
            exit 1
        fi
        CORPUS_EXIT=1
    fi
    rm -rf "$BACKUP_DIR" 2>/dev/null
fi
# T-762: fast never touched src/outputs (no backup was taken), so there is nothing to check or
# restore -- CORPUS_EXIT stays 0 by construction, not by a vacuous check.

summ "gate=$GATE"
summ "log=$LOG"
summ "$RAN_LINE"
summ "$RESULT_LINE"
summ "BATTERY_EXIT=$BATTERY_EXIT"
summ "CORPUS_EXIT=$CORPUS_EXIT"
summ "COUNT_EXIT=$COUNT_EXIT (compared against $BASELINE_COUNT_DESC; this run's count logged to $RUN_COUNT_LOG_FILE)"
summ "NAME_SET_EXIT=$NAME_SET_EXIT (compared against $BASELINE_NORM_FILE; this run's name-set logged to $RUN_NORM_LOG_FILE)"
if [ "${#REAL_TIER_SUMMARY[@]}" -gt 0 ]; then
    for line in "${REAL_TIER_SUMMARY[@]}"; do
        summ "$line"
    done
fi
summ "REAL_TIER_EXIT=$REAL_TIER_EXIT (0 unless a real-tier module failed for a reason other than a named, pre-existing quirk -- see the per-module lines above)"
summ "SKIP_NAMES_EXIT=$SKIP_NAMES_EXIT (0 unless the runner's own summary reports skipped>0 but zero '^SKIP: ' lines were found -- an instrument that cannot see its input, never a refusal on the skip names' own content)"
summ "FLEET_TESTS_EXIT=$FLEET_TESTS_EXIT ($FLEET_TESTS_DESC)"
echo "▶ summary:         $SUMMARY"

if [ "$BATTERY_EXIT" -ne 0 ]; then
    exit "$BATTERY_EXIT"
fi
if [ "$COUNT_EXIT" -ne 0 ]; then
    exit "$COUNT_EXIT"
fi
if [ "$NAME_SET_EXIT" -ne 0 ]; then
    exit "$NAME_SET_EXIT"
fi
if [ "$REAL_TIER_EXIT" -ne 0 ]; then
    exit "$REAL_TIER_EXIT"
fi
if [ "$SKIP_NAMES_EXIT" -ne 0 ]; then
    exit "$SKIP_NAMES_EXIT"
fi
if [ "$FLEET_TESTS_EXIT" -ne 0 ]; then
    exit "$FLEET_TESTS_EXIT"
fi
exit "$CORPUS_EXIT"
