#!/usr/bin/env bash
# tests/push_guard.sh — drives the real hooks/sterility_push_guard.sh as a pre-push hook.
# The owner's push variable is ALLOW_PUSH=1, the same one the other repos' push locks use;
# the retired AIMAIL_OWNER_PUSH must no longer open the gate on its own.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$REPO/hooks/sterility_push_guard.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1 (expected rc $3, got $2)"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
git -C "$T" init -q
# No etc/aimail.conf in the fixture repo, so no sterility terms: only the owner gate is tested.
run() { ( cd "$T" && env -u ALLOW_PUSH -u AIMAIL_OWNER_PUSH "$@" bash "$HOOK" origin git@example.invalid:x.git </dev/null >/dev/null 2>&1 ); echo $?; }

check "no variable set: refused"                     "$(run)" 1
check "ALLOW_PUSH=1: allowed"                        "$(run ALLOW_PUSH=1)" 0
check "ALLOW_PUSH=0: refused"                        "$(run ALLOW_PUSH=0)" 1
check "retired AIMAIL_OWNER_PUSH=1 alone: refused"   "$(run AIMAIL_OWNER_PUSH=1)" 1
out="$( cd "$T" && env -u ALLOW_PUSH bash "$HOOK" origin x </dev/null 2>&1 )"
case "$out" in *"ALLOW_PUSH=1 git push"*) r=0 ;; *) r=1 ;; esac
check "refusal message names ALLOW_PUSH=1"           "$r" 0

echo "push_guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
