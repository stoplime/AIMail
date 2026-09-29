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

# ── the doctor's view: is the guard LIVE in a repo that pushes? (lib/pushguard.sh) ──
# A hook may be the guard itself or a two-gate wrapper that hands on to it. A wrapper counts only if
# every script it names is really there and executable, and the two markers are found in them.
status_of() {  # $1 = repo dir -> first word of push_guard_status
  ( export AIMAIL_PUSH_GUARD_REPOS="$1"; source "$REPO/lib/pushguard.sh"; push_guard_status "$1" | cut -f1 ) 2>/dev/null; }
mkrepo() {  # $1 = name; prints the hooks dir
  git init -q "$T/$1"; mkdir -p "$T/$1/.git/hooks"; echo "$T/$1/.git/hooks"; }
GATE="$T/allow_gate.sh"; printf '#!/usr/bin/env bash\n# machine-wide ALLOW_PUSH gate\n[ "${ALLOW_PUSH:-}" = 1 ]\n' > "$GATE"; chmod +x "$GATE"
wrapper() {  # $1 = hooks dir, $2 = gate script, $3 = guard script
  printf '#!/usr/bin/env bash\n"%s" "$@" </dev/null || exit $?\nexec %s "$@"\n' "$2" "$3" > "$1/pre-push"; chmod +x "$1/pre-push"; }

h="$(mkrepo direct)"; ln -s "$HOOK" "$h/pre-push"
check "doctor view: the guard symlinked directly reads INSTALLED"            "$(status_of "$T/direct")" INSTALLED
h="$(mkrepo wrap_ok)"; wrapper "$h" "$GATE" "$HOOK"
check "doctor view: a two-gate wrapper naming both real scripts reads INSTALLED" "$(status_of "$T/wrap_ok")" INSTALLED
h="$(mkrepo wrap_gone)"; wrapper "$h" "$GATE" "$T/moved_away/sterility_push_guard.sh"
check "doctor view: a wrapper whose guard script is gone reads WRONG_SCRIPT"  "$(status_of "$T/wrap_gone")" WRONG_SCRIPT
h="$(mkrepo wrap_noexec)"; cp "$HOOK" "$T/guard_noexec.sh"; chmod -x "$T/guard_noexec.sh"; wrapper "$h" "$GATE" "$T/guard_noexec.sh"
check "doctor view: a wrapper whose guard lost its exec bit reads WRONG_SCRIPT" "$(status_of "$T/wrap_noexec")" WRONG_SCRIPT
h="$(mkrepo wrap_other)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/other.sh"; chmod +x "$T/other.sh"; wrapper "$h" "$GATE" "$T/other.sh"
check "doctor view: a wrapper naming an unrelated script reads WRONG_SCRIPT"  "$(status_of "$T/wrap_other")" WRONG_SCRIPT
h="$(mkrepo wrap_nogate)"; wrapper "$h" "$T/other.sh" "$HOOK"
# The guard script carries both markers itself (it has its own owner gate), so a first gate that is
# something else does not change what this check can see: the check asks whether the guard is
# reachable, not how many gates come before it.
check "doctor view: a wrapper ending in the real guard reads INSTALLED whatever its first gate is" "$(status_of "$T/wrap_nogate")" INSTALLED

echo "push_guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
