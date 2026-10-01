#!/usr/bin/env bash
# review_prepush_guard.sh — a `pre-push` hook: the last resort behind `aimail review`. A branch pushed to a
# configured remote needs an approved review of the exact commit; PR_READY_OVERRIDE="<reason>" gets past
# it and is logged. All of the logic and the configuration live in lib/review.sh (`review guard-push`).
# INSTALL: chain it after the owner's ALLOW_PUSH gate in the repo's pre-push hook; this file does not
# install itself.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
exec "$HERE/bin/aimail" review guard-push "$@"
