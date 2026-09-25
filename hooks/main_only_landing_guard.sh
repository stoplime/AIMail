#!/usr/bin/env bash
# main_only_landing_guard.sh — a `reference-transaction` hook that refuses a ref update
# on a repo's own designated landing branch(es) from any session that isn't registered
# as seat "main".
#
# ═══ WHY reference-transaction, NOT pre-commit ═══════════════════════════════════
# Four real self-lands happened tonight (foundation, librarian, architect x2), and NONE
# of them were a plain `git commit` on the protected branch -- every one was a direct
# `git update-ref` or `git reset --hard` moving the branch ref to a commit already made
# elsewhere (a worktree, another branch). A `pre-commit` hook never fires for those --
# it only fires on `git commit`. `reference-transaction` fires on EVERY ref update, from
# every git plumbing/porcelain command that moves one, which is the only hook family that
# actually covers the failure mode this guard exists for.
#
# ⚠⚠ FAIL OPEN ON UNKNOWN IDENTITY, same law as stop_guard.sh/poller_guard.sh. This is
#    an internal dev-safety mechanism, not a security boundary against a maliciously
#    bypassing actor -- it exists to catch the ORDINARY case (a seat forgetting the
#    process), not to withstand someone deliberately unsetting an env var. A human
#    running git directly, or any session this fleet has no identity record for, must
#    never be refused: guessing wrong here blocks legitimate work with no recourse.
#
# WHAT IT REFUSES: an update to one of this repo's configured landing-branch refs
# (`git config --get-all main-landing-guard.protected-ref`, e.g. `refs/heads/main`),
# ONLY when this session is POSITIVELY identified (via stop_guard.sh's own session->seat
# mapping) as a seat that is not on that ref's own ALLOW-LIST. Seat "main" is always
# allowed, everywhere, unconditionally -- the allow-list only ever ADDS landers, never
# removes main. Everything else -- an unmapped session, any ref that isn't in the
# protected list -- is allowed.
#
# PER-REPO, PER-REF ALLOW-LIST (2026-09-22, the owner-approved second-lander policy): the
# allow-list itself lives in AIMail's own gitignored etc/aimail.conf
# (AIMAIL_LANDING_GUARD_ALLOW, see etc/aimail.conf.example), not per-repo git config --
# one place to read every repo's rule, same as every other machine-local path in this
# tool. This hook is symlinked (or copied) into OTHER repos, though, so it cannot find
# that file by walking its own path (a symlink target and a plain copy resolve
# differently, and this hook's own header already documents "symlink (or copy)" as
# equally valid). So the ONE thing still set per protected repo, alongside its own
# protected-ref, is a POINTER back to AIMail's own root:
#   git config --add main-landing-guard.aimail-home /path/to/the/AIMail/repo
# read the exact same trivial way protected-ref already is.
#
# INSTALL: symlink (or copy) this file to `.git/hooks/reference-transaction` in each
# protected repo, then set that repo's own protected ref(s) and AIMail's own root:
#   git config --add main-landing-guard.protected-ref refs/heads/main
#   git config --add main-landing-guard.aimail-home /path/to/the/AIMail/repo
# Multiple refs: repeat `--add` for each one. Missing/unreadable aimail-home or
# etc/aimail.conf is NOT a fail-open condition -- it just means no allow-list entries
# are found, so every ref stays "main only", the exact prior behavior.
#
# USAGE (hook, invoked by git itself):
#   main_only_landing_guard.sh <state>     state is "prepared" | "committed" | "aborted"
#   stdin (state=prepared only): one line per ref, "<old-value> <new-value> <ref-name>"
#
# USAGE (CLI, for a human/selftest):
#   main_only_landing_guard.sh selftest

set -uo pipefail
_H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AIMAIL_ROOT="${AIMAIL_ROOT:-$HOME/.aimail}"
_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; }
_seat_for_session() {
  local sid; sid="$(_sid)"
  [[ -n "$sid" ]] || return 0
  local f="$AIMAIL_ROOT/state/stopguard/session.$sid"
  [[ -f "$f" ]] && cat "$f" || true
}

_protected_refs() {
  git config --get-all main-landing-guard.protected-ref 2>/dev/null
}

_is_protected() {
  local refname="$1" ref
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    [[ "$refname" == "$ref" ]] && return 0
  done < <(_protected_refs)
  return 1
}

# Load AIMAIL_LANDING_GUARD_ALLOW from AIMail's own centralized etc/aimail.conf, found via
# this repo's own git config pointer (see header) -- never by walking this script's own
# path, which resolves differently for a symlink vs. a copy. Missing/unreadable is not an
# error: AIMAIL_LANDING_GUARD_ALLOW simply stays unset, and every ref falls back to
# "main only", the exact prior behavior.
AIMAIL_LANDING_GUARD_ALLOW=()
_aimail_home="$(git config --get main-landing-guard.aimail-home 2>/dev/null || true)"
if [[ -n "$_aimail_home" && -r "$_aimail_home/etc/aimail.conf" ]]; then
  # shellcheck disable=SC1090
  source "$_aimail_home/etc/aimail.conf" 2>/dev/null || true
fi

# _allowed_seats <refname> -- space-separated EXTRA seats (beyond "main", always allowed)
# permitted to land <refname> in the CURRENT repo, per AIMAIL_LANDING_GUARD_ALLOW. Empty
# when no matching "<repo-root>|<ref>|<seats>" entry exists.
# ⛔ THE REPO KEY IS THE SHARED REPO, NOT THE CURRENT WORKTREE (2026-09-23 11:39 incident): a
#   landing run from a LINKED WORKTREE reports the worktree's own path as --show-toplevel, which
#   never equals the main-checkout path an allow entry names, so every listed non-main seat was
#   refused from a worktree while main (landing from the main checkout) never saw it. The
#   shared repo is the parent of `--git-common-dir` (for the main checkout, itself). Both the
#   common root and the toplevel are accepted, so an entry written either way still matches.
_repo_roots() {
  local top common
  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null \
         || git rev-parse --git-common-dir 2>/dev/null || true)"
  [[ -n "$common" ]] && common="$(readlink -f -- "$common" 2>/dev/null || printf '%s' "$common")"
  [[ -n "$common" ]] && printf '%s\n' "$(dirname -- "$common")"
  [[ -n "$top" ]] && printf '%s\n' "$top"
}
_allowed_seats() {
  local refname="$1" root entry repo ref seats
  local -a roots=()
  mapfile -t roots < <(_repo_roots)
  (( ${#roots[@]} )) || return 0
  for entry in "${AIMAIL_LANDING_GUARD_ALLOW[@]:-}"; do
    [[ -z "$entry" ]] && continue
    IFS='|' read -r repo ref seats <<<"$entry"
    [[ "$ref" == "$refname" ]] || continue
    local hit=0; for root in "${roots[@]}"; do [[ "$repo" == "$root" ]] && hit=1; done
    if (( hit )); then
      printf '%s' "$seats"
      return 0
    fi
  done
  return 0
}

# _seat_allowed <seat> <refname> -- "main" is always allowed, unconditionally, everywhere;
# the allow-list only ever adds landers on top of that, never removes main.
_seat_allowed() {
  local seat="$1" refname="$2" allowed s
  [[ "$seat" == "main" ]] && return 0
  allowed="$(_allowed_seats "$refname")"
  for s in $allowed; do
    [[ "$s" == "$seat" ]] && return 0
  done
  return 1
}

# ─── R6(k) — a protected ref only ever moves FORWARD (2026-09-23) ──────────────────────
# Two landers cut from one parent; the second `git update-ref` (2-arg form) replaced the
# first's tip and a landed commit left the branch silently (13:54). Ninety seconds later a
# cherry-pick built on a stale detached HEAD passed the 3-arg compare-and-swap (the CAS
# protects the REF's identity, never the lineage of the commit written into it) and dropped
# two more (13:55). Both incidents share one shape the hook can see and a habit cannot:
# the OLD tip is not an ancestor of the NEW tip. Refuse that on every protected ref, for
# every writer -- seat-mapped or not -- so the discipline no longer depends on which
# update-ref form a lander typed or where a worktree's HEAD happened to sit.
#   allowed: creation (old = zeros), a no-op (old == new), any move where old is an
#            ancestor of new (a real fast-forward, however many commits).
#   refused: old not an ancestor of new (a sibling, a stale base, a rewind), and deletion
#            of a protected ref (new = zeros) -- a landing branch is never removed by a hook
#            caller.
#   AIMAIL_LANDING_GUARD_REQUIRE_FF=0 in the caller's environment disables the check for ONE
#   deliberate rewrite (the owner's own, say). Default 1. A bound, not a dark flag.
_zeros() { [[ -z "$1" || "$1" =~ ^0+$ ]]; }
# ⚠ git hands this hook ALL ZEROS as <old> for any UNCONDITIONAL update (the 2-arg
#   `update-ref`, `branch -f`, `reset --hard`, `update-ref -d`) -- not the current value. So
#   "old is zeros" does NOT mean creation. The hook resolves the ref's LIVE value itself
#   (`rev-parse`, read under the transaction's own ref lock): absent -> creation; present ->
#   that is the tip the move must fast-forward from. This is exactly the read the 13:54 lander
#   never did, made unskippable.
_ff_ok() {  # _ff_ok <old> <new> <refname>  -> 0 when the move is allowed by the fast-forward rule
  local old="$1" new="$2" refname="$3" live
  _zeros "$new" && return 1                       # deletion of a protected ref: never through here
  if _zeros "$old"; then
    live="$(git rev-parse -q --verify "$refname" 2>/dev/null || true)"
    [[ -n "$live" ]] || return 0                  # the ref does not exist yet: creation
    old="$live"
  fi
  [[ "$old" == "$new" ]] && return 0              # no-op
  git merge-base --is-ancestor "$old" "$new" 2>/dev/null
}
_refuse_nonff_message() {
  local refname="$1" old="$2" new="$3"
  _zeros "$old" && old="$(git rev-parse -q --verify "$refname" 2>/dev/null || echo "$2")"
  if _zeros "$new"; then
    echo "⛔ REFUSED: deleting '$refname' -- a landing branch is never deleted through this hook." >&2
    echo "   Deliberate rewrite? AIMAIL_LANDING_GUARD_REQUIRE_FF=0 for that one command." >&2
    return
  fi
  echo "⛔ REFUSED: non-fast-forward on '$refname': ${old:0:8} is not an ancestor of ${new:0:8}." >&2
  echo "   The tip moved under this landing, or the commit was cut on a stale base (a detached" >&2
  echo "   worktree HEAD does not follow the ref). Re-read the live tip, rebase or cherry-pick" >&2
  echo "   onto it, then land with 'git update-ref $refname <new> <tip>' (3-arg) or 'aimail land'." >&2
  echo "   Deliberate rewrite? AIMAIL_LANDING_GUARD_REQUIRE_FF=0 for that one command." >&2
}

_refuse_message() {
  local seat="$1" refname="$2" allowed
  allowed="$(_allowed_seats "$refname")"
  echo "⛔ REFUSED: '$refname' is a landing branch; seat '$seat' is not on its allow-list." >&2
  if [[ -n "$allowed" ]]; then
    echo "   Allowed here: main, $allowed." >&2
  else
    echo "   Allowed here: main only (no AIMAIL_LANDING_GUARD_ALLOW entry for this repo/ref)." >&2
  fi
  echo "   Process: commit in a worktree, get a non-author gate, then send an allowed" >&2
  echo "   lander a landing request with the sha -- never update this ref directly." >&2
}

case "${1:-}" in
  selftest)
    # ⛔⛔ Same discipline as stop_guard.sh's own selftest: assert the DECISION the run
    #    actually took (via the git command's own real exit code against a real repo),
    #    never just "did the wrapper return 0" -- a guard that never fires would pass
    #    every "allow" arm for free and still look green.
    tmp="$(mktemp -d)"
    repo="$tmp/repo"; mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    old="$(git -C "$repo" rev-parse main)"
    git -C "$repo" branch other-branch
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
    new="$(git -C "$repo" rev-parse HEAD)"
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"   # main back to its original tip for the arms below

    git -C "$repo" config --add main-landing-guard.protected-ref refs/heads/main
    mkdir -p "$repo/.git/hooks"
    cp "$_H/main_only_landing_guard.sh" "$repo/.git/hooks/reference-transaction"
    chmod +x "$repo/.git/hooks/reference-transaction"
    export AIMAIL_ROOT="$tmp/aimailstate"
    mkdir -p "$AIMAIL_ROOT/state/stopguard"

    # Per-repo, per-ref allow-list: a fake "AIMail home" carrying its own etc/aimail.conf,
    # pointed at by this repo's own git config, exactly the real install's own two-step
    # (never resolved by walking this script's own path -- see the header).
    aimailhome="$tmp/aimailhome"; mkdir -p "$aimailhome/etc"
    printf 'AIMAIL_LANDING_GUARD_ALLOW=(\n  "%s|refs/heads/main|audit"\n)\n' "$repo" > "$aimailhome/etc/aimail.conf"
    git -C "$repo" config --add main-landing-guard.aimail-home "$aimailhome"

    PASS=0; FAIL=0
    _arm() { # _arm <name> <want-rc-class: pass|refuse> <sid-or-empty> <mapped-seat-or-empty>
      local name="$1" want="$2" sid="$3" seat="$4" rc
      rm -f "$AIMAIL_ROOT/state/stopguard/session."*
      [[ -n "$sid" && -n "$seat" ]] && printf '%s' "$seat" > "$AIMAIL_ROOT/state/stopguard/session.$sid"
      (
        export CLAUDE_CODE_SESSION_ID="$sid"
        git -C "${ARM_DIR:-$repo}" update-ref refs/heads/main "$new" "$old"
      ) >/dev/null 2>/tmp/main_landing_guard_selftest_stderr; rc=$?
      AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"   # restore for the next arm regardless of outcome
      local ok=0
      if [[ "$want" == "refuse" && "$rc" != 0 ]]; then ok=1; fi
      if [[ "$want" == "pass" && "$rc" == 0 ]]; then ok=1; fi
      if [[ "$ok" == 1 ]]; then PASS=$((PASS+1)); printf '  ✔ %s (rc=%s)\n' "$name" "$rc"
      else FAIL=$((FAIL+1)); printf '  ✖ %s FAILED (rc=%s, wanted %s)\n' "$name" "$rc" "$want"; fi
    }

    _arm "ARM 1: a non-main seat is REFUSED on the protected ref"    refuse selftest-a notmain
    _arm "ARM 2: seat 'main' is ALLOWED on the protected ref"        pass   selftest-b main
    _arm "ARM 3: an UNMAPPED session id is ALLOWED (fail-open)"      pass   selftest-c ""
    _arm "ARM 4: NO session id at all is ALLOWED (fail-open)"        pass   "" ""
    _arm "ARM 4b: a seat on this ref's own allow-list is ALLOWED"    pass   selftest-h audit
    _arm "ARM 4c: a seat NOT on the allow-list is still REFUSED"     refuse selftest-i librarian
    # ⭐ ARMS 4d-4e (2026-09-23 11:39): the landing runs from a LINKED WORKTREE of the same repo.
    #   Its --show-toplevel is the worktree path, never the allow entry's; the shared repo
    #   (parent of --git-common-dir) is what the entry names.
    git -C "$repo" worktree add -q "$tmp/wt" other-branch
    ARM_DIR="$tmp/wt"
    _arm "ARM 4d: an allow-listed seat landing from a LINKED WORKTREE is ALLOWED" pass   selftest-j audit
    _arm "ARM 4e: a seat NOT on the allow-list is still REFUSED from a worktree"   refuse selftest-k librarian
    unset ARM_DIR
    git -C "$repo" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true   # ARMS 5-7 expect other-branch free

    # ARM 5: same non-main identity, but on a ref that is NOT protected -- must be allowed.
    rm -f "$AIMAIL_ROOT/state/stopguard/session."*
    printf 'notmain' > "$AIMAIL_ROOT/state/stopguard/session.selftest-e"
    (
      export CLAUDE_CODE_SESSION_ID=selftest-e
      git -C "$repo" update-ref refs/heads/other-branch "$new"
    ) >/dev/null 2>&1; rc=$?
    if [[ "$rc" == 0 ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 5: a non-protected ref is ALLOWED for a non-main seat (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 5 FAILED (rc=%s, wanted 0)\n' "$rc"; fi

    # ⭐ ARMS 6-7 (code-review's gate finding, 2026-09-22): the actual mechanism BOTH real
    #   incident classes used tonight was never `update-ref` directly -- it was `git reset
    #   --hard` on the checked-out branch and `git branch -f`. reference-transaction fires
    #   for either regardless, but nothing here PROVED that until code-review's own
    #   independent falsification did. Closing that gap in the shipped selftest itself,
    #   not just trusting an outside review to have checked it once.
    git -C "$repo" checkout -q main
    (
      export CLAUDE_CODE_SESSION_ID=selftest-f
      printf 'notmain' > "$AIMAIL_ROOT/state/stopguard/session.selftest-f"
      git -C "$repo" reset --hard -q "$new"
    ) >/dev/null 2>&1; rc=$?
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"
    if [[ "$rc" != 0 ]]; then PASS=$((PASS+1)); printf "  ✔ ARM 6: 'git reset --hard' by a non-main seat is REFUSED (rc=%s)\n" "$rc"
    else FAIL=$((FAIL+1)); printf "  ✖ ARM 6 FAILED (rc=%s, wanted nonzero)\n" "$rc"; fi

    git -C "$repo" checkout -q other-branch
    (
      export CLAUDE_CODE_SESSION_ID=selftest-g
      printf 'notmain' > "$AIMAIL_ROOT/state/stopguard/session.selftest-g"
      git -C "$repo" branch -f main "$new"
    ) >/dev/null 2>&1; rc=$?
    git -C "$repo" checkout -q main
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"
    if [[ "$rc" != 0 ]]; then PASS=$((PASS+1)); printf "  ✔ ARM 7: 'git branch -f main' by a non-main seat is REFUSED (rc=%s)\n" "$rc"
    else FAIL=$((FAIL+1)); printf "  ✖ ARM 7 FAILED (rc=%s, wanted nonzero)\n" "$rc"; fi


    # ── R6(k) arms: a protected ref only moves forward (2026-09-23) ──
    rm -f "$AIMAIL_ROOT/state/stopguard/session."*
    printf 'main' > "$AIMAIL_ROOT/state/stopguard/session.selftest-ff"
    export CLAUDE_CODE_SESSION_ID=selftest-ff
    git -C "$repo" checkout -q main
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"
    # a SIBLING of $new: same parent $old, different commit -- the 13:54 second lander's shape
    git -C "$repo" checkout -q -b sibling "$old"
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m sibling
    sibling="$(git -C "$repo" rev-parse HEAD)"
    git -C "$repo" checkout -q main

    # ARM 8: main at $new (a real landing); a 2-arg move to the sibling is REFUSED and main stays put
    git -C "$repo" update-ref refs/heads/main "$new" "$old" >/dev/null 2>&1
    ( git -C "$repo" update-ref refs/heads/main "$sibling" ) >/dev/null 2>&1; rc=$?
    now="$(git -C "$repo" rev-parse refs/heads/main)"
    if [[ "$rc" != 0 && "$now" == "$new" ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 8: a NON-fast-forward 2-arg move on the protected ref is REFUSED and the tip is unchanged (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 8 FAILED (rc=%s, tip moved=%s)\n' "$rc" "$([[ "$now" == "$new" ]] && echo no || echo YES)"; fi
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"

    # ARM 9: creating a protected ref (old = zeros) is ALLOWED
    git -C "$repo" config --add main-landing-guard.protected-ref refs/heads/prot2
    ( git -C "$repo" update-ref refs/heads/prot2 "$new" ) >/dev/null 2>&1; rc=$?
    if [[ "$rc" == 0 ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 9: CREATING a protected ref (old = zeros) is ALLOWED (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 9 FAILED (rc=%s, wanted 0)\n' "$rc"; fi

    # ARM 10: the 13:54 two-lander replay -- both cut from $old; A lands $new; B's move to the
    # sibling is REFUSED whichever update-ref form B typed; A's commit is never lost.
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"
    ( git -C "$repo" update-ref refs/heads/main "$new" "$old" ) >/dev/null 2>&1; rcA=$?
    ( git -C "$repo" update-ref refs/heads/main "$sibling" "$old" ) >/dev/null 2>&1; rcB3=$?
    ( git -C "$repo" update-ref refs/heads/main "$sibling" ) >/dev/null 2>&1; rcB2=$?
    now="$(git -C "$repo" rev-parse refs/heads/main)"
    if [[ "$rcA" == 0 && "$rcB3" != 0 && "$rcB2" != 0 && "$now" == "$new" ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 10: two-lander replay -- A lands, B is REFUSED in both update-ref forms, the landed commit stays on the ref\n'
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 10 FAILED (A=%s B3=%s B2=%s tip==A: %s)\n' "$rcA" "$rcB3" "$rcB2" "$([[ "$now" == "$new" ]] && echo yes || echo NO)"; fi
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"

    # ARM 11: deleting a protected ref is REFUSED
    ( git -C "$repo" update-ref -d refs/heads/prot2 ) >/dev/null 2>&1; rc=$?
    if [[ "$rc" != 0 ]] && git -C "$repo" rev-parse -q --verify refs/heads/prot2 >/dev/null; then PASS=$((PASS+1)); printf '  ✔ ARM 11: DELETING a protected ref is REFUSED and the ref survives (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 11 FAILED (rc=%s)\n' "$rc"; fi

    # ARM 12: the knob at its NON-default value (0) lets the same non-FF move through -- proves the
    # check reads the knob, not a hardcoded rule (fixture value != code default, per #276)
    git -C "$repo" update-ref refs/heads/main "$new" "$old" >/dev/null 2>&1
    ( export AIMAIL_LANDING_GUARD_REQUIRE_FF=0; git -C "$repo" update-ref refs/heads/main "$sibling" ) >/dev/null 2>&1; rc=$?
    now="$(git -C "$repo" rev-parse refs/heads/main)"
    if [[ "$rc" == 0 && "$now" == "$sibling" ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 12: AIMAIL_LANDING_GUARD_REQUIRE_FF=0 allows the deliberate non-FF rewrite (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 12 FAILED (rc=%s, tip==sibling: %s)\n' "$rc" "$([[ "$now" == "$sibling" ]] && echo yes || echo NO)"; fi
    AIMAIL_LANDING_GUARD_REQUIRE_FF=0 git -C "$repo" reset -q --hard "$old"

    # ARM 13: a no-op move (old == new) is ALLOWED
    ( git -C "$repo" update-ref refs/heads/main "$old" "$old" ) >/dev/null 2>&1; rc=$?
    if [[ "$rc" == 0 ]]; then PASS=$((PASS+1)); printf '  ✔ ARM 13: a NO-OP move (old == new) on the protected ref is ALLOWED (rc=%s)\n' "$rc"
    else FAIL=$((FAIL+1)); printf '  ✖ ARM 13 FAILED (rc=%s, wanted 0)\n' "$rc"; fi
    unset CLAUDE_CODE_SESSION_ID
    echo
    echo "── SUMMARY: $PASS passed, $FAIL failed ──"
    rm -rf "$tmp"
    [[ "$FAIL" == 0 ]] && exit 0 || exit 1
    ;;

  prepared)
    seat="$(_seat_for_session)"
    require_ff="${AIMAIL_LANDING_GUARD_REQUIRE_FF:-1}"

    refused=0
    while IFS=' ' read -r old_val new_val refname; do
      [[ -n "$refname" ]] || continue
      _is_protected "$refname" || continue
      # R6(k): the fast-forward rule binds EVERY writer of a protected ref, mapped seat or not.
      if [[ "$require_ff" == 1 ]] && ! _ff_ok "$old_val" "$new_val" "$refname"; then
        _refuse_nonff_message "$refname" "$old_val" "$new_val"
        refused=1
      fi
      # The seat allow-list stays fail-open for an unmapped session (ARMS 3/4): guessing wrong
      # there blocks legitimate human work with no recourse.
      if [[ -n "$seat" ]] && ! _seat_allowed "$seat" "$refname"; then
        _refuse_message "$seat" "$refname"
        refused=1
      fi
    done
    [[ "$refused" == 1 ]] && exit 1
    exit 0
    ;;

  committed|aborted)
    cat >/dev/null 2>&1 || true
    exit 0
    ;;

  *)
    echo "usage: main_only_landing_guard.sh <prepared|committed|aborted|selftest>" >&2
    exit 2
    ;;
esac
