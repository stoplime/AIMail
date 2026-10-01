#!/usr/bin/env bash
# safe_sync.sh — refuse-loudly guard for the shared-checkout single-path sync step.
#
# WHY: the standing land procedure (a seat's own pre-commit hook prints it, e.g.
# one of this fleet's own tracked repos' .git/hooks/pre-commit) lands a commit in a fresh DETACHED
# worktree, fast-forwards the target branch with `git update-ref refs/heads/<b>
# <newsha> <oldsha>`, then the shared checkout has to catch its own working tree up
# to the new tip for the file(s) that changed — historically done with a bare
# `git checkout <newsha> -- <path>`. That command gives ZERO protection: for a
# single-path checkout (unlike a branch switch) git does not refuse or warn when the
# working copy already has uncommitted changes to that path — it silently
# overwrites them.
#
# INCIDENT (2026-08-31): a seat (foundation) edited TODO.md directly in the
# shared checkout, uncommitted, without holding the `todoedit` gateclaim (out of
# protocol — confirmed by foundation's own account). code-review then finished an
# unrelated, protocol-compliant `todoedit`-held landing and ran the bare single-path
# checkout to sync, which silently destroyed foundation's uncommitted block. Nothing
# detected the loss until a later grep for an unrelated anchor happened to fail.
# Recovered from foundation's own sent mail; no data lost from the record, but it
# could have been.
#
# RULED SHAPE (fable, 2026-08-31): REFUSE LOUDLY, never auto-stash. A stash nobody
# knows to pop is the identical silent-burial failure one level down — the fleet's
# own never-silence-a-state-change law applies to the guard itself. The cost of a
# refusal (one manual investigation) is what this incident showed is worth paying.
#
# WHY COMPARE AGAINST <old-ref>, NOT HEAD: `git update-ref` moves the branch
# pointer without touching the index or working tree, so immediately after landing,
# HEAD already points at the NEW commit while the working tree (correctly, still)
# holds the OLD content — that is the ordinary, safe, expected state mid-sync, not
# a foreign edit. Comparing the working tree against HEAD (or using plain `git
# status`/`git diff`, which both key off the index-vs-HEAD and worktree-vs-index
# split) produces a FALSE POSITIVE on every ordinary sync for exactly this reason —
# caught by this script's own test suite (tests/safe_sync.sh) before this became
# the shipped design. The only question that actually matters is "does the
# on-disk content match what it held at <old-ref>, i.e., has anything touched it
# since the last known-safe point" — so that is what this script checks, directly,
# byte for byte, independent of where HEAD or the index currently sit. <old-ref> is
# the same `oldsha` the land procedure already captures right before its own
# `git update-ref` call — no new bookkeeping for the caller.
#
# USE THIS instead of a bare `git checkout <new-ref> -- <path>` for the
# shared-checkout sync step. Nothing else about the land procedure changes.
#
# ⛔⛔ NEW-FILE BYPASS IS LEGITIMATE; EXISTING-FILE BYPASS IS NOT — fable, 2026-09-02,
#   from the 5th destroyed-uncommitted-work incident. This script REFUSES outright
#   (exit 3) on a path that does not exist on disk at all — it has no baseline blob
#   to compare against, so there is nothing for it to protect, and a caller who then
#   does a manual `git checkout <new-ref> -- <path>` for that brand-new path (after
#   independently verifying, e.g. a direct byte diff, that nothing on-disk would be
#   lost) is doing the ONLY thing possible, correctly. An EXISTING path is different
#   IN KIND, not degree: it has real content this script CAN and DOES compare, so a
#   manual `git checkout <new-ref> -- <path>` for an existing path is never a
#   substitute for calling this script — it is the exact bare-checkout behavior this
#   whole tool exists to replace, just invoked by hand instead of by the old
#   land-procedure step. If a landing's sync step is touching a path that already
#   exists in the working tree, that path goes through safe_sync.sh, full stop;
#   there is no manual-bypass case for it the way there legitimately is for a new one.
#
# ANCESTRY GUARD + POST-SYNC ASSERTION (fable, 2026-09-03): a shared-checkout doc in
# one of this fleet's own tracked repos was found reverted behind its own HEAD (working tree at
# pre-fold content, index staged to undo the fold) despite `git log` correctly
# showing the right HEAD — the update-ref CAS lesson (equality of a ref is not the
# same claim as ancestry) applies to a sync tool's own <old-ref>/<new-ref> pair the
# same way it applies to update-ref itself: a reversed argument order (new/old
# swapped) is a plausible mechanism, and nothing here caught it, because the
# pre-sync check above only asks "does disk match <old-ref>", which a swapped pair
# can pass by construction. So: (1) refuse unless <new-ref> actually descends from
# <old-ref> — this fails loudly on exactly a swapped-argument invocation; (2) after
# the checkout, verify each path's on-disk bytes now match <new-ref> exactly and
# `git status --short` is clean for it — a sync that silently leaves the tree
# different from what it just claimed to sync to must say so, not exit 0 anyway.
#
# REPO DERIVED FROM THE PATH, NEVER AMBIENT CWD (fable, 2026-09-03): a real incident
# on this deployment had a session's default shell cwd sitting under a permanently
# frozen tree after a checkout move, so a caller relying on "run from inside the
# repo" resolved refs against the WRONG repo by default, not as an edge case —
# confirmed live when a call from that dead cwd failed with "does not resolve to a
# commit here" instead of finding the intended repo. Fix: the repo root is derived
# from the first <path> argument's own location on disk (or an explicit --repo),
# never from `git rev-parse --show-toplevel` off cwd. A resolved repo root under
# one of this machine's own configured frozen-tree prefixes is refused by name (see
# AIMAIL_FROZEN_REPO_PREFIXES below) — deliberately NOT a blanket parent-directory
# refusal, since that would incorrectly block this tool from ever syncing its own
# repo if the two happen to share a parent.
#
# EVERY INVOCATION IS LOGGED (fable, 2026-09-03): timestamp, caller seat
# ($AIMAIL_SEAT, "unknown" if unset), raw args, and exit code, appended to
# $AIMAIL_ROOT/state/safe_sync_invocations.log — so the next "who ran this and
# with what arguments" question is answered by a file, not by asking every seat to
# recall its own command history.
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: safe_sync.sh [--repo <path>] <old-ref> <new-ref> <path> [<path> ...]

Syncs the CURRENT working tree's copy of each <path> to its content at <new-ref>
— the same effect as `git checkout <new-ref> -- <path> ...`, except it refuses
loudly and touches NOTHING if any <path>'s on-disk bytes right now differ from
its content at <old-ref> (i.e., something touched it since the last known-safe
point, staged or not).

  --repo     explicit repo root. Without it, the repo is derived from the
             first <path> argument's own on-disk location — NEVER from the
             ambient shell cwd, which is not reliable for this project (see
             the file header). Pass an absolute <path> (or --repo) so the
             right repo is found regardless of cwd.
  <old-ref>  the ref the target branch pointed to immediately BEFORE this
             landing's own `git update-ref` — the same `oldsha` the standing
             land procedure already captures right before that call.
  <new-ref>  the ref to sync TO (the just-landed commit). Must descend from
             <old-ref> (ancestry guard).
  <path>     one or more paths (absolute, or relative to the repo root) to
             sync.

Exit 0  — every path was clean (matched <old-ref> exactly); all are now synced
          to <new-ref>, verified byte-identical afterward.
Exit 1  — usage error, an unresolvable --repo/path-derived repo, a path
          outside the resolved repo, or a resolved repo under one of this
          machine's own configured frozen-tree prefixes (see
          AIMAIL_FROZEN_REPO_PREFIXES in etc/aimail.conf.example).
Exit 2  — at least one path's on-disk content differs from <old-ref>. NOTHING
          was touched. The foreign diff is printed above this message.
Exit 3  — <old-ref>/<new-ref> does not resolve, a path does not exist at
          <new-ref>, or <new-ref> does not descend from <old-ref> (ancestry
          guard — catches a reversed old/new argument order).
Exit 4  — INTERNAL FAILURE: the checkout ran but a path's on-disk content or
          'git status --short' does not match <new-ref> afterward. This should
          never happen; treat it as a tool bug, not a normal refusal.
EOF
}

# ── invocation log (req 4) — set up before anything can exit, captures raw args ──
AIMAIL_ROOT="${AIMAIL_ROOT:-$HOME/.aimail}"
SAFE_SYNC_LOG="$AIMAIL_ROOT/state/safe_sync_invocations.log"
_inv_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_inv_seat="${AIMAIL_SEAT:-unknown}"
_inv_args="$*"
log_invocation() {
    local rc="$1"
    mkdir -p "$(dirname "$SAFE_SYNC_LOG")" 2>/dev/null || true
    printf '%s\tseat=%s\targs=[%s]\texit=%s\n' "$_inv_ts" "$_inv_seat" "$_inv_args" "$rc" \
        >> "$SAFE_SYNC_LOG" 2>/dev/null || true
}
trap 'log_invocation "$?"' EXIT

repo_override=""
if [ "${1:-}" = "--repo" ]; then
    repo_override="${2:-}"
    shift 2 2>/dev/null || { usage; exit 1; }
fi

if [ "$#" -lt 3 ]; then
    usage
    exit 1
fi

old_ref="$1"
new_ref="$2"
shift 2
paths=("$@")

# ── repo derivation (req 3) — from --repo or the first path's own location, never cwd ──
if [ -n "$repo_override" ]; then
    repo_root="$(git -C "$repo_override" rev-parse --show-toplevel 2>/dev/null)" || {
        echo "safe_sync.sh: --repo '$repo_override' is not a git working tree." >&2
        exit 1
    }
else
    first_abs="$(realpath -m -- "${paths[0]}" 2>/dev/null)" || {
        echo "safe_sync.sh: cannot resolve '${paths[0]}' to a real path." >&2
        exit 1
    }
    repo_root="$(git -C "$(dirname -- "$first_abs")" rev-parse --show-toplevel 2>/dev/null)" || {
        echo "safe_sync.sh: cannot determine the git repo for '${paths[0]}' from its own location (not from ambient cwd — see usage). Pass --repo explicitly." >&2
        exit 1
    }
fi

# Frozen-tree prefixes are entirely deployment-specific (a machine's own history of
# moved/retired checkouts), so they come from this machine's own gitignored
# etc/aimail.conf (AIMAIL_FROZEN_REPO_PREFIXES, see etc/aimail.conf.example) --
# empty by default, so a fresh install refuses nothing until it says so itself.
_frozen_cfg="${AIMAIL_CONFIG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etc/aimail.conf}"
# shellcheck source=/dev/null
[ -f "$_frozen_cfg" ] && . "$_frozen_cfg"
for _frozen_prefix in "${AIMAIL_FROZEN_REPO_PREFIXES[@]:-}"; do
    [ -z "$_frozen_prefix" ] && continue
    case "$repo_root" in
        "$_frozen_prefix"*)
            echo "safe_sync.sh: refusing — '$repo_root' is under '$_frozen_prefix', a frozen backup tree per this machine's own etc/aimail.conf, never a legitimate sync target." >&2
            exit 1
            ;;
    esac
done

# Normalize every path to repo-relative form and confirm it is actually inside
# the resolved repo. An absolute <path> is used as-is. A relative <path> is
# resolved against --repo when one was given (that is the entire point of
# passing it explicitly — a relative path must not silently fall back to
# ambient cwd just because --repo was also given); otherwise against cwd,
# consistent with how the first path was used to derive the repo above.
rel_paths=()
for p in "${paths[@]}"; do
    case "$p" in
        /*) resolve_base="" ;;
        *)  resolve_base="${repo_override:+$repo_override/}" ;;
    esac
    abs_p="$(realpath -m -- "${resolve_base}${p}" 2>/dev/null)" || {
        echo "safe_sync.sh: cannot resolve '$p' to a real path." >&2
        exit 1
    }
    case "$abs_p" in
        "$repo_root"/*)
            rel_paths+=("${abs_p#"$repo_root"/}")
            ;;
        *)
            echo "safe_sync.sh: '$p' (resolved to '$abs_p') is not inside repo '$repo_root'." >&2
            exit 1
            ;;
    esac
done
paths=("${rel_paths[@]}")
cd "$repo_root"

for r in "$old_ref" "$new_ref"; do
    if ! git rev-parse --verify --quiet "${r}^{commit}" >/dev/null; then
        echo "safe_sync.sh: '$r' does not resolve to a commit here." >&2
        exit 3
    fi
done

if ! git merge-base --is-ancestor "$old_ref" "$new_ref"; then
    echo "safe_sync.sh: '$new_ref' does not descend from '$old_ref' — refusing (ancestry guard). A reversed old/new argument order fails exactly this check; verify the call and re-run." >&2
    exit 3
fi

dirty_found=0
for p in "${paths[@]}"; do
    if ! git cat-file -e "${new_ref}:${p}" 2>/dev/null; then
        echo "safe_sync.sh: '$p' does not exist at $new_ref — refusing to touch it." >&2
        exit 3
    fi
    if [ ! -e "$p" ]; then
        echo "safe_sync.sh: '$p' does not exist on disk — refusing to guess whether that's expected." >&2
        exit 3
    fi
    old_blob="$(git rev-parse "${old_ref}:${p}" 2>/dev/null || echo "MISSING")"
    disk_blob="$(git hash-object -- "$p")"
    if [ "$old_blob" != "$disk_blob" ]; then
        if [ "$dirty_found" -eq 0 ]; then
            cat >&2 <<EOF
⛔ REFUSED: '$p' on disk does not match its content at $old_ref — syncing to
$new_ref would silently discard whatever changed it (the exact 2026-08-31
incident this guard exists to prevent). Nothing has been touched.

Decide explicitly, then re-run:
  - it's YOUR OWN legitimate edit: commit it (in a detached worktree, per the
    standing land procedure) or mail it to whoever needs it, THEN re-sync.
  - it's SOMEONE ELSE'S out-of-protocol edit: mail them before doing anything
    — do not silently keep or silently discard their work.

The foreign diff, for the decision above (old_ref content -> on-disk content):
EOF
        fi
        echo "── $p ──" >&2
        git diff --no-index -- <(git show "${old_ref}:${p}") "$p" >&2 || true
        dirty_found=1
    fi
done

if [ "$dirty_found" -ne 0 ]; then
    exit 2
fi

git checkout "$new_ref" -- "${paths[@]}"
for p in "${paths[@]}"; do
    new_blob="$(git rev-parse "${new_ref}:${p}")"
    disk_blob_after="$(git hash-object -- "$p")"
    status_after="$(git status --short -- "$p")"
    if [ "$new_blob" != "$disk_blob_after" ] || [ -n "$status_after" ]; then
        cat >&2 <<EOF
safe_sync.sh: INTERNAL FAILURE -- '$p' does not match $new_ref after its own
checkout (expected blob $new_blob, got $disk_blob_after; 'git status --short'
for this path: '${status_after:-<empty>}'). The sync did not do what it just
claimed to do. Do not trust this working tree for '$p'; investigate before
any further landing touches it.
EOF
        exit 4
    fi
    echo "safe_sync.sh: synced '$p' to $new_ref (verified byte-identical, git status clean)."
done
