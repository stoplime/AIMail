#!/usr/bin/env bash
# sterility_push_guard.sh — a `pre-push` hook that (1) refuses ANY push from a non-owner
# AI seat outright, and (2), even for an owner-authorized push, refuses one whose outgoing
# commits (diff content OR commit messages) carry a configured operator/company/project
# term (AIMAIL_STERILITY_TERMS, etc/aimail.conf — see lib/sterility.sh's own header).
#
# WHY THIS FILE EXISTS (2026-09-24 incident): a real local, UNTRACKED, hand-written
# pre-push script already did roughly this job — but only in the ONE checkout it was
# manually dropped into, with real names hardcoded directly in its own body (which is
# exactly why it could never be tracked/shared as-is: checking in a script that spells
# out the owner's/company's own protected terms in its own source would itself leak
# those names into this repo's own tracked, published source). Foundation's own separate
# worktree never had that file, so 5 branches carrying the owner's name and work email
# reached the public origin with zero local resistance.
# This version reads its term list from etc/aimail.conf (gitignored, machine-local) —
# exactly the pattern sterility_guard.sh (the pre-commit sibling) already uses — so the
# CHECK is generic/trackable/shareable while the actual names it looks for never are.
#
# FAIL OPEN when AIMAIL_STERILITY_TERMS is unset/empty, same law as the pre-commit sibling
# and every other dev-safety mechanism in this family: a fresh install with no terms
# configured yet has nothing to check, by design, not by oversight. The owner-only push
# gate below does NOT fail open — it is a policy line (AI seats never push this repo),
# not a sterility check, and applies regardless of whether any terms are configured.
#
# INSTALL: this file must be REACHABLE from whichever checkout might push, same caveat
# `aimail landing-guard` already documents for main_only_landing_guard.sh — a symlink (or
# copy) into that checkout's own .git/hooks/pre-push. It is not enough for it to exist
# once, in one seat's own working copy.
set -euo pipefail

# The owner's push variable is ALLOW_PUSH=1, the same one every other repo's pre-push lock uses,
# so there is one variable to remember, not one per repo. AI seats cannot set it: the agent-side
# command hook refuses any command that sets ALLOW_PUSH, which is what keeps this gate owner-only.
if [[ "${ALLOW_PUSH:-}" != "1" ]]; then
  echo "⛔ REFUSED (sterility_push_guard): this repo is pushed by its owner only." >&2
  echo "   AI seats never push. Owner: re-run as  ALLOW_PUSH=1 git push ..." >&2
  exit 1
fi

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$root" ]] && exit 0
conf="$root/etc/aimail.conf"
# shellcheck disable=SC1090
[[ -r "$conf" ]] && source "$conf" 2>/dev/null || true
terms="${AIMAIL_STERILITY_TERMS:-}"
[[ -z "$terms" ]] && exit 0

refused=0
while read -r _lref lsha _rref rsha; do
  [[ "$lsha" =~ ^0+$ ]] && continue
  range="$lsha"
  [[ "$rsha" =~ ^0+$ ]] || range="$rsha..$lsha"
  # -p covers diff content; git log's own default header already includes the full commit
  # message (subject + body) ahead of the patch, so one scan covers both surfaces named in
  # the request ("the diff and the commit messages") with no separate pass needed.
  hits="$(git log -p "$range" --diff-filter=ACM -- . ':(exclude)LICENSE' 2>/dev/null \
    | grep -inE "$terms" || true)"
  if [[ -n "$hits" ]]; then
    echo "⛔ REFUSED (sterility_push_guard): outgoing commits in $range carry a configured" >&2
    echo "   operator/company/project term (AIMAIL_STERILITY_TERMS):" >&2
    echo "$hits" | head -20 | sed 's/^/   /' >&2
    echo "   Scrub the content/message first; do not remove the check to get past it." >&2
    refused=1
  fi
done
exit "$refused"
