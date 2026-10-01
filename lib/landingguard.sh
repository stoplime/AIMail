# shellcheck shell=bash
# landingguard.sh — is the main-only landing guard (hooks/main_only_landing_guard.sh,
# a `reference-transaction` hook) actually INSTALLED AND RESOLVABLE in each repo it is
# supposed to protect, right now?
#
# ⛔ WHY (2026-09-22): a project repo's `core.hooksPath` pointed at an
#   absolute path under a checkout that had been moved away. Git treats a hooksPath
#   that names a nonexistent directory as "no hooks" — not an error — so the
#   pre-commit guard silently stopped firing for ~26 h (09-21 12:30:47 → 09-22 14:40:49)
#   and nothing in any session looked different. The landing guard is installed the
#   same fragile way: a SYMLINK whose target is an absolute path on a FUSE mount. If
#   that mount is down or the file moves, git sees a non-executable hook and runs
#   nothing, fail-open, with no signal. This check turns that silent state into a
#   visible line in `aimail session` and `aimail doctor`.
#
# STATES (one TSV line per repo: <state>\t<detail>):
#   INSTALLED           hook present, target exists and is executable, protected refs set
#   DANGLING            hook entry exists but its target is missing / not executable
#   MISSING             no reference-transaction hook in the EFFECTIVE hooks dir
#   NO_PROTECTED_REF    hook resolves but `main-landing-guard.protected-ref` is unset → inert
#   HOOKSPATH_DANGLING  core.hooksPath names a directory that does not exist (dangling hooksPath) —
#                       git runs NO hooks at all, whatever sits in .git/hooks
#   NOT_A_REPO          the configured path is not a git repository
#
# ⚠ Honours each repo's own core.hooksPath (absolute, or relative to the worktree
#   top-level, as git resolves it). The EFFECTIVE hooks dir is what git would use,
#   never a guess at .git/hooks.
#
# CONFIG: AIMAIL_LANDING_GUARD_REPOS — space-separated repo paths. Default: the
#   POC_ROOT and PLATFORM_ROOT already in etc/aimail.conf; failing both, the repo
#   containing $PWD (so a bare checkout still gets one honest line).

_lg_repos() {
  if [[ -n "${AIMAIL_LANDING_GUARD_REPOS:-}" ]]; then
    printf '%s\n' $AIMAIL_LANDING_GUARD_REPOS
    return 0
  fi
  local any=0
  [[ -n "${POC_ROOT:-}" ]]      && { printf '%s\n' "$POC_ROOT"; any=1; }
  [[ -n "${PLATFORM_ROOT:-}" ]] && { printf '%s\n' "$PLATFORM_ROOT"; any=1; }
  (( any )) && return 0
  git rev-parse --show-toplevel 2>/dev/null
}

# The hooks directory git itself would consult for this repo, or the string
# "DANGLING:<path>" when core.hooksPath names a directory that does not exist.
_lg_effective_hooks_dir() {
  local repo="$1" hp top
  hp="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  if [[ -n "$hp" ]]; then
    if [[ "$hp" != /* ]]; then
      top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)"
      hp="$top/$hp"
    fi
    [[ -d "$hp" ]] && { printf '%s\n' "$hp"; return 0; }
    printf 'DANGLING:%s\n' "$hp"; return 0
  fi
  git -C "$repo" rev-parse --path-format=absolute --git-path hooks 2>/dev/null \
    || { local gp; gp="$(git -C "$repo" rev-parse --git-path hooks 2>/dev/null)"; [[ "$gp" = /* ]] && printf '%s\n' "$gp" || printf '%s/%s\n' "$repo" "$gp"; }
}

landing_guard_status() {
  local repo="$1"
  if [[ ! -d "$repo" ]] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'NOT_A_REPO\t%s is not a git repository\n' "$repo"; return 0
  fi
  local hooksdir; hooksdir="$(_lg_effective_hooks_dir "$repo")"
  if [[ "$hooksdir" == DANGLING:* ]]; then
    printf 'HOOKSPATH_DANGLING\tcore.hooksPath=%s does not exist -- git runs NO hooks in this repo (dangling hooksPath)\n' "${hooksdir#DANGLING:}"
    return 0
  fi
  local hook="$hooksdir/reference-transaction"
  if [[ ! -e "$hook" && ! -L "$hook" ]]; then
    printf 'MISSING\tno reference-transaction hook in %s\n' "$hooksdir"; return 0
  fi
  local target; target="$(readlink -f "$hook" 2>/dev/null || true)"
  if [[ -z "$target" || ! -f "$target" ]]; then
    printf 'DANGLING\t%s -> %s (target missing)\n' "$hook" "$(readlink "$hook" 2>/dev/null || echo '?')"; return 0
  fi
  if [[ ! -x "$target" ]]; then
    printf 'DANGLING\t%s -> %s is not executable -- git skips it silently\n' "$hook" "$target"; return 0
  fi
  local refs; refs="$(git -C "$repo" config --get-all main-landing-guard.protected-ref 2>/dev/null | tr '\n' ' ')"
  refs="${refs% }"
  if [[ -z "$refs" ]]; then
    printf 'NO_PROTECTED_REF\thook resolves (%s) but main-landing-guard.protected-ref is unset -- the guard is inert\n' "$target"; return 0
  fi
  printf 'INSTALLED\t%s -> %s ; protects %s\n' "$hook" "$target" "$refs"
}

# Prints one ok/warn line per configured repo; echoes the problem count on stdout's
# LAST line is avoided — instead returns it as the exit status (0..N) so callers add
# it to their own tally. Used by `aimail session` and `aimail doctor`.
landing_guard_report() {
  local problems=0 repo state detail
  local repos; repos="$(_lg_repos)"
  if [[ -z "$repos" ]]; then
    info "  no repos configured (AIMAIL_LANDING_GUARD_REPOS / POC_ROOT / PLATFORM_ROOT unset, \$PWD not in a repo)"
    return 0
  fi
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    IFS=$'\t' read -r state detail < <(landing_guard_status "$repo")
    case "$state" in
      INSTALLED) ok "  $repo: landing guard INSTALLED + resolvable ($detail)" ;;
      NO_PROTECTED_REF)
        warn "  $repo: $state — $detail"
        warn "    fix: git -C $repo config --add main-landing-guard.protected-ref refs/heads/<landing-branch>"
        problems=$((problems+1)) ;;
      HOOKSPATH_DANGLING)
        warn "  $repo: $state — $detail"
        warn "    fix: git -C $repo config --unset core.hooksPath   (or point it at a directory that exists), then reinstall the guard"
        problems=$((problems+1)) ;;
      DANGLING|MISSING)
        warn "  $repo: $state — $detail"
        warn "    fix: ln -sf $AIMAIL_HOME/hooks/main_only_landing_guard.sh <effective-hooks-dir>/reference-transaction"
        problems=$((problems+1)) ;;
      *)
        warn "  $repo: $state — $detail"; problems=$((problems+1)) ;;
    esac
  done <<< "$repos"
  return $problems
}

# ─── selftest — every state, driven through REAL git in scratch repos ──────────
# The falsification arm is the point: the SAME repo reads INSTALLED, then its
# symlink target is removed and it must read DANGLING. A check that cannot go red
# on a dangled hook is the check this repo had before (none).
landing_guard_selftest() {
  local t; t="$(mktemp -d)"
  local pass=0 fail=0
  _t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }
  _state() { landing_guard_status "$1" | cut -f1; }

  echo "landingguard.sh selftest (fixtures under $t)"
  # a stand-in "AIMail hooks dir" holding a real copy of the real hook
  mkdir -p "$t/aimail_hooks"
  cp "$AIMAIL_HOME/hooks/main_only_landing_guard.sh" "$t/aimail_hooks/main_only_landing_guard.sh"
  chmod +x "$t/aimail_hooks/main_only_landing_guard.sh"

  local r="$t/repo"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  _t "ARM 1: fresh repo, no hook -> MISSING" "$(_state "$r")" "MISSING"

  ln -s "$t/aimail_hooks/main_only_landing_guard.sh" "$r/.git/hooks/reference-transaction"
  _t "ARM 2: hook resolves but no protected ref -> NO_PROTECTED_REF" "$(_state "$r")" "NO_PROTECTED_REF"

  git -C "$r" config --add main-landing-guard.protected-ref refs/heads/main
  _t "ARM 3: hook + protected ref -> INSTALLED" "$(_state "$r")" "INSTALLED"

  # ⭐ FALSIFICATION: same repo, dangle the symlink by removing its target
  mv "$t/aimail_hooks/main_only_landing_guard.sh" "$t/aimail_hooks/moved_away.sh"
  _t "ARM 4 (falsification): target removed -> the SAME repo now reads DANGLING" "$(_state "$r")" "DANGLING"
  mv "$t/aimail_hooks/moved_away.sh" "$t/aimail_hooks/main_only_landing_guard.sh"
  _t "ARM 5: target restored -> INSTALLED again" "$(_state "$r")" "INSTALLED"

  chmod -x "$t/aimail_hooks/main_only_landing_guard.sh"
  _t "ARM 6: target present but not executable -> DANGLING (git skips it)" "$(_state "$r")" "DANGLING"
  chmod +x "$t/aimail_hooks/main_only_landing_guard.sh"

  # Dangling-hooksPath case: core.hooksPath names a directory that does not exist. The hook in
  # .git/hooks is still there and STILL must not count -- git would not consult it.
  git -C "$r" config core.hooksPath "$t/does-not-exist/hooks"
  _t "ARM 7 (dangling hooksPath): core.hooksPath -> nonexistent dir -> HOOKSPATH_DANGLING (despite a hook in .git/hooks)" "$(_state "$r")" "HOOKSPATH_DANGLING"

  # hooksPath honoured when it DOES exist: absolute, then relative to the top-level
  mkdir -p "$t/shared_hooks"
  git -C "$r" config core.hooksPath "$t/shared_hooks"
  _t "ARM 8: absolute hooksPath to an EMPTY existing dir -> MISSING (not .git/hooks' own symlink)" "$(_state "$r")" "MISSING"
  ln -s "$t/aimail_hooks/main_only_landing_guard.sh" "$t/shared_hooks/reference-transaction"
  _t "ARM 9: absolute hooksPath holding the hook -> INSTALLED" "$(_state "$r")" "INSTALLED"

  mkdir -p "$r/hooks-rel"
  ln -s "$t/aimail_hooks/main_only_landing_guard.sh" "$r/hooks-rel/reference-transaction"
  git -C "$r" config core.hooksPath "hooks-rel"
  _t "ARM 10: RELATIVE hooksPath resolves against the top-level -> INSTALLED" "$(_state "$r")" "INSTALLED"
  git -C "$r" config core.hooksPath "hooks-nope"
  _t "ARM 11: RELATIVE hooksPath to a missing dir -> HOOKSPATH_DANGLING" "$(_state "$r")" "HOOKSPATH_DANGLING"
  git -C "$r" config --unset core.hooksPath

  _t "ARM 12: a path that is not a repo -> NOT_A_REPO" "$(_state "$t/not_a_repo_at_all")" "NOT_A_REPO"

  # the report's problem count is its exit status: 1 bad repo among 2 -> 1
  local n
  AIMAIL_LANDING_GUARD_REPOS="$r $t/not_a_repo_at_all" landing_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 13: landing_guard_report returns the number of non-INSTALLED repos (1 of 2)" "$n" "1"
  AIMAIL_LANDING_GUARD_REPOS="$r" landing_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 14: landing_guard_report returns 0 when every configured repo is INSTALLED" "$n" "0"

  rm -rf "$t"
  echo "  ---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
