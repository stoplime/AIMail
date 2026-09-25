#!/usr/bin/env bash
# sterility_guard.sh — a `pre-commit` hook that refuses a commit whose staged diff adds a
# configured operator/company/project term to a tracked file.
#
# WHY pre-commit, not reference-transaction (contrast main_only_landing_guard.sh's own
# header): this check is about CONTENT, not which ref moved, and content enters a repo at
# the commit step -- catching it there, before the commit exists at all, is strictly
# earlier than catching it once it is already sitting in history waiting to be squashed
# out again. Scans only the staged ADDITIONS (`git diff --cached`, `+` lines), not the
# whole tree, so it stays fast on every commit; `aimail doctor`/the tests/run.sh arm
# separately scan the whole tree for anything that entered before this hook existed.
#
# FAIL OPEN when AIMAIL_STERILITY_TERMS is unset/empty (see lib/sterility.sh's own
# header) -- a fresh install with no terms configured yet has nothing to check, by design,
# not by oversight.
set -euo pipefail

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -z "$root" ]] && exit 0
conf="$root/etc/aimail.conf"
# shellcheck disable=SC1090
[[ -r "$conf" ]] && source "$conf" 2>/dev/null || true
terms="${AIMAIL_STERILITY_TERMS:-}"
[[ -z "$terms" ]] && exit 0

hits="$(git diff --cached -U0 --diff-filter=ACM -- . ':(exclude)LICENSE' 2>/dev/null \
  | grep -E '^\+[^+]' \
  | grep -inE "$terms" || true)"

if [[ -n "$hits" ]]; then
  echo "⛔ REFUSED (sterility_guard): this commit's own staged diff adds a configured" >&2
  echo "   operator/company/project term (AIMAIL_STERILITY_TERMS):" >&2
  echo "$hits" | sed 's/^/   /' >&2
  echo "   If this term is not actually identifying, narrow AIMAIL_STERILITY_TERMS in" >&2
  echo "   etc/aimail.conf; do not remove the check to get past it." >&2
  exit 1
fi

# Content can be scrubbed everywhere and a name still land in plain sight as commit
# metadata (found live, 2026-09-22: 7 commits carrying a configured term in the author
# email, invisible to the content check above since it never reads author/committer
# identity). Checked here, not just audited after the fact, so a leaking identity is
# refused before the commit exists.
# shellcheck source=/dev/null
source "$root/lib/sterility.sh" 2>/dev/null || true
if command -v sterility_scan_identity >/dev/null 2>&1; then
  id_rc=0
  if id_hits="$(sterility_scan_identity)"; then id_rc=0; else id_rc=$?; fi
  if [[ "$id_rc" -gt 0 ]]; then
    echo "⛔ REFUSED (sterility_guard): this commit's own author/committer identity matches a" >&2
    echo "   configured operator/company/project term (AIMAIL_STERILITY_TERMS):" >&2
    echo "$id_hits" | sed 's/^/   /' >&2
    echo "   Fix git config user.name/user.email (or GIT_AUTHOR_*/GIT_COMMITTER_* env vars)" >&2
    echo "   before committing; do not remove the check to get past it." >&2
    exit 1
  fi
fi
exit 0
