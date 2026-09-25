#!/usr/bin/env bash
# sterility_commit_msg_guard.sh — a `commit-msg` hook that refuses a commit whose OWN
# MESSAGE contains a configured operator/company/project term.
#
# WHY A SEPARATE HOOK FROM sterility_guard.sh (pre-commit): that hook scans the staged
# DIFF, never the message being written -- a commit whose content is perfectly clean can
# still describe itself in prose that names the very thing being protected (2026-09-24:
# a message read "sterility grep (<configured term list>): clean", and quoting the
# pattern's own terms to describe it is exactly what those terms are). sterility_push_guard.sh
# (pre-push) DOES already scan outgoing commit messages too -- but only AI seats never
# push this repo, so that guard never runs during the ordinary local commit/land workflow
# every seat actually uses. This hook is what catches it at the point the message is
# first written, not eventually at a push that, for an AI seat, never happens.
#
# FAIL OPEN when AIMAIL_STERILITY_TERMS is unset/empty, same law as every other guard in
# this family: a fresh install with no terms configured yet has nothing to check, by
# design, not by oversight.
#
# INSTALL: same caveat as the pre-commit/pre-push siblings — must be REACHABLE from
# whichever checkout is committing (a symlink or copy into that checkout's own
# .git/hooks/commit-msg). Existing in one checkout only protects that one checkout.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$root" ]] && exit 0
conf="$root/etc/aimail.conf"
# shellcheck disable=SC1090
[[ -r "$conf" ]] && source "$conf" 2>/dev/null || true
terms="${AIMAIL_STERILITY_TERMS:-}"
[[ -z "$terms" ]] && exit 0

msg_file="${1:-}"
[[ -n "$msg_file" && -r "$msg_file" ]] || exit 0

hits="$(grep -inE "$terms" -- "$msg_file" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  echo "⛔ REFUSED (sterility_commit_msg_guard): this commit's own MESSAGE contains a" >&2
  echo "   configured operator/company/project term (AIMAIL_STERILITY_TERMS):" >&2
  echo "$hits" | sed 's/^/   /' >&2
  echo "   Refer to it as \"the configured term list\" — never spell the terms out to" >&2
  echo "   describe the check that is looking for them. Reword before committing." >&2
  exit 1
fi
