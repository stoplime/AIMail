# shellcheck shell=bash
# pushguard.sh — is the generic pre-push sterility guard (hooks/sterility_push_guard.sh,
# a `pre-push` hook) actually INSTALLED AND RESOLVABLE right now, in each repo it is
# supposed to protect?
#
# ⛔ WHY (2026-09-24, same incident class as t908/landingguard.sh): a real, working
#   pre-push check existing SOMEWHERE is not the same claim as it being LIVE in the
#   checkout that actually pushes. The first version of this guard (93b1f78) was a
#   real, tracked, falsified file that sat unreferenced by any .git/hooks/pre-push
#   for several minutes after landing -- "exists but isn't wired" is a silent gap,
#   exactly like a dangling landing-guard symlink is: git treats a missing/dangling
#   pre-push hook as "no hook", not an error, so a push sails through with zero
#   resistance and nothing about the push itself looks different.
#
# STATES (one TSV line per repo: <state>\t<detail>):
#   INSTALLED           hook present, target exists + executable, and its body still
#                        carries BOTH the owner-only gate marker and the sterility-scan
#                        marker (so a symlink pointed at some OTHER, unrelated script
#                        cannot false-positive as "installed")
#   WRONG_SCRIPT         hook resolves to a real, executable file that is missing one
#                        or both markers -- reachable, but not actually this guard
#   DANGLING             hook entry exists but its target is missing / not executable
#   MISSING              no pre-push hook in the EFFECTIVE hooks dir
#   HOOKSPATH_DANGLING   core.hooksPath names a directory that does not exist (t908
#                        shape) -- git runs NO hooks at all, whatever sits in .git/hooks
#   NOT_A_REPO           the configured path is not a git repository
#
# ⚠ Honours each repo's own core.hooksPath (absolute, or relative to the worktree
#   top-level, as git resolves it), same as landingguard.sh -- the EFFECTIVE hooks
#   dir is what git would use, never a guess at .git/hooks.
#
# CONFIG: AIMAIL_PUSH_GUARD_REPOS -- space-separated repo paths. Default: $AIMAIL_HOME
#   itself (the only repo this guard exists for -- POC/Platform push to a local
#   trunk, never a public origin).

_pg_repos() {
  if [[ -n "${AIMAIL_PUSH_GUARD_REPOS:-}" ]]; then
    printf '%s\n' $AIMAIL_PUSH_GUARD_REPOS
    return 0
  fi
  [[ -n "${AIMAIL_HOME:-}" ]] && { printf '%s\n' "$AIMAIL_HOME"; return 0; }
  git rev-parse --show-toplevel 2>/dev/null
}

# The hooks directory git itself would consult for this repo, or the string
# "DANGLING:<path>" when core.hooksPath names a directory that does not exist.
# Identical logic to landingguard.sh's _lg_effective_hooks_dir -- kept as its own
# copy (not shared) so this file has no load-order dependency on that one.
_pg_effective_hooks_dir() {
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

# _pg_hook_body <hookfile> — the hook's own text followed by the text of each executable
# .sh script it names (absolute path, or one starting "$HOME/"). One level only: a delegate's
# own delegates are not followed.
_pg_hook_body() {
  local hook="$1" ref path
  cat "$hook" 2>/dev/null
  while IFS= read -r ref; do
    path="${ref/#\$HOME/$HOME}"
    [[ "$path" == /* && -f "$path" && -x "$path" ]] && cat "$path" 2>/dev/null
  done < <(grep -oE '(/|\$HOME/)[A-Za-z0-9_./+-]*\.sh' "$hook" 2>/dev/null | sort -u)
  return 0
}

# _pg_hook_status <repo> <hookfile e.g. pre-push|commit-msg> <marker> [marker2...] —
# the shared core both push_guard_status (pre-push) and commit_msg_guard_status
# (commit-msg) are thin wrappers around (2026-09-24): same states, same resolution
# logic (_pg_effective_hooks_dir), the only difference is which hook file and which
# marker string(s) identify "this is really our guard, not just something reachable".
_pg_hook_status() {
  local repo="$1" hookfile="$2"; shift 2
  local -a markers=("$@")
  if [[ ! -d "$repo" ]] || ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'NOT_A_REPO\t%s is not a git repository\n' "$repo"; return 0
  fi
  local hooksdir; hooksdir="$(_pg_effective_hooks_dir "$repo")"
  if [[ "$hooksdir" == DANGLING:* ]]; then
    printf 'HOOKSPATH_DANGLING\tcore.hooksPath=%s does not exist -- git runs NO hooks in this repo (t908 shape)\n' "${hooksdir#DANGLING:}"
    return 0
  fi
  local hook="$hooksdir/$hookfile"
  if [[ ! -e "$hook" && ! -L "$hook" ]]; then
    printf 'MISSING\tno %s hook in %s\n' "$hookfile" "$hooksdir"; return 0
  fi
  local target; target="$(readlink -f "$hook" 2>/dev/null || true)"
  if [[ -z "$target" || ! -f "$target" ]]; then
    printf 'DANGLING\t%s -> %s (target missing)\n' "$hook" "$(readlink "$hook" 2>/dev/null || echo '?')"; return 0
  fi
  if [[ ! -x "$target" ]]; then
    printf 'DANGLING\t%s -> %s is not executable -- git skips it silently\n' "$hook" "$target"; return 0
  fi
  # A wrapper hook is legitimate: it may hand the ref list on to the real guard scripts
  # (the machine-wide ALLOW_PUSH gate, then hooks/sterility_push_guard.sh), so the markers are
  # looked for in the hook AND in every executable .sh file it names by absolute or $HOME path.
  # A delegate that is missing or not executable contributes nothing, so a wrapper whose guard
  # was moved away or lost its executable bit still reads WRONG_SCRIPT.
  local body; body="$(_pg_hook_body "$target")"
  local m
  for m in "${markers[@]}"; do
    grep -q "$m" <<<"$body" 2>/dev/null || {
      printf 'WRONG_SCRIPT\t%s -> %s is reachable but missing a required marker -- not this guard\n' "$hook" "$target"
      return 0
    }
  done
  printf 'INSTALLED\t%s -> %s\n' "$hook" "$target"
}

push_guard_status() {
  _pg_hook_status "$1" pre-push ALLOW_PUSH AIMAIL_STERILITY_TERMS
}

# commit_msg_guard_status <repo> — same states as push_guard_status, for the
# commit-msg hook (hooks/sterility_commit_msg_guard.sh): a commit whose own MESSAGE
# leaks a configured term (2026-09-24 incident: a2fa1dc's first cut had this hook
# committed WITHOUT its executable bit, so git silently skipped it once installed --
# exactly the "reachable but never actually fires" gap push_guard_status already
# exists to catch for pre-push. Marker is the hook's own error-string identifier,
# not an env var name, since commit-msg guards don't share the owner-push marker.
commit_msg_guard_status() {
  _pg_hook_status "$1" commit-msg sterility_commit_msg_guard
}

# _pg_report <statusfn> <label> <hookfile> <installtarget> — the shared core both
# push_guard_report and commit_msg_guard_report are thin wrappers around: prints one
# ok/warn line per configured repo, returns the problem count as exit status.
_pg_report() {
  local statusfn="$1" label="$2" hookfile="$3" installtarget="$4"
  local problems=0 repo state detail
  local repos; repos="$(_pg_repos)"
  if [[ -z "$repos" ]]; then
    info "  no repos configured (AIMAIL_PUSH_GUARD_REPOS / AIMAIL_HOME unset, \$PWD not in a repo)"
    return 0
  fi
  while IFS= read -r repo; do
    [[ -n "$repo" ]] || continue
    IFS=$'\t' read -r state detail < <("$statusfn" "$repo")
    case "$state" in
      INSTALLED) ok "  $repo: $label INSTALLED + resolvable ($detail)" ;;
      WRONG_SCRIPT)
        warn "  $repo: $state — $detail"
        warn "    fix: ln -sf $installtarget <effective-hooks-dir>/$hookfile"
        problems=$((problems+1)) ;;
      HOOKSPATH_DANGLING)
        warn "  $repo: $state — $detail"
        warn "    fix: git -C $repo config --unset core.hooksPath   (or point it at a directory that exists), then reinstall the guard"
        problems=$((problems+1)) ;;
      DANGLING|MISSING)
        warn "  $repo: $state — $detail"
        warn "    fix: ln -sf $installtarget <effective-hooks-dir>/$hookfile"
        problems=$((problems+1)) ;;
      *)
        warn "  $repo: $state — $detail"; problems=$((problems+1)) ;;
    esac
  done <<< "$repos"
  return $problems
}

# Same shape as landing_guard_report: prints one ok/warn line per configured repo,
# returns the problem count as exit status. Wired into `aimail session`/`doctor`
# alongside landing_guard_report so a dangled/missing/wrong push guard shows up in
# the same place a dangled landing guard already does.
push_guard_report() {
  _pg_report push_guard_status "pre-push sterility guard" pre-push "$AIMAIL_HOME/hooks/sterility_push_guard.sh"
}

# commit_msg_guard_report — same shape, for the commit-msg hook (see
# commit_msg_guard_status). Wired alongside push_guard_report (2026-09-24, per the
# a2fa1dc missing-+x incident: "exists but never fires once installed" is a silent
# gap for a commit-msg hook exactly the way it already is for pre-push).
commit_msg_guard_report() {
  _pg_report commit_msg_guard_status "commit-msg sterility guard" commit-msg "$AIMAIL_HOME/hooks/sterility_commit_msg_guard.sh"
}

# ─── selftest — every state, driven through REAL git in scratch repos ──────────
# Same falsification discipline as landing_guard_selftest: prove the SAME repo can
# go from INSTALLED to every failure state and back, not just that a fresh fixture
# happens to read one state once.
push_guard_selftest() {
  local t; t="$(mktemp -d)"
  local pass=0 fail=0
  _t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }
  _state() { push_guard_status "$1" | cut -f1; }

  echo "pushguard.sh selftest (fixtures under $t)"
  mkdir -p "$t/aimail_hooks"
  cp "$AIMAIL_HOME/hooks/sterility_push_guard.sh" "$t/aimail_hooks/sterility_push_guard.sh"
  chmod +x "$t/aimail_hooks/sterility_push_guard.sh"
  # a real, executable, but unrelated script -- must never read INSTALLED
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/aimail_hooks/unrelated.sh"
  chmod +x "$t/aimail_hooks/unrelated.sh"

  local r="$t/repo"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  _t "ARM 1: fresh repo, no hook -> MISSING" "$(_state "$r")" "MISSING"

  ln -s "$t/aimail_hooks/sterility_push_guard.sh" "$r/.git/hooks/pre-push"
  _t "ARM 2: hook resolves + carries both markers -> INSTALLED" "$(_state "$r")" "INSTALLED"

  # ⭐ FALSIFICATION: same repo, dangle the symlink by removing its target
  mv "$t/aimail_hooks/sterility_push_guard.sh" "$t/aimail_hooks/moved_away.sh"
  _t "ARM 3 (falsification): target removed -> the SAME repo now reads DANGLING" "$(_state "$r")" "DANGLING"
  mv "$t/aimail_hooks/moved_away.sh" "$t/aimail_hooks/sterility_push_guard.sh"
  _t "ARM 4: target restored -> INSTALLED again" "$(_state "$r")" "INSTALLED"

  chmod -x "$t/aimail_hooks/sterility_push_guard.sh"
  _t "ARM 5: target present but not executable -> DANGLING (git skips it)" "$(_state "$r")" "DANGLING"
  chmod +x "$t/aimail_hooks/sterility_push_guard.sh"

  # ⭐ the marker check: point pre-push at a real, executable, but WRONG script
  rm "$r/.git/hooks/pre-push"
  ln -s "$t/aimail_hooks/unrelated.sh" "$r/.git/hooks/pre-push"
  _t "ARM 6: hook resolves to a real script missing both markers -> WRONG_SCRIPT (not INSTALLED)" "$(_state "$r")" "WRONG_SCRIPT"
  rm "$r/.git/hooks/pre-push"
  ln -s "$t/aimail_hooks/sterility_push_guard.sh" "$r/.git/hooks/pre-push"
  _t "ARM 7: pointed back at the real guard -> INSTALLED again" "$(_state "$r")" "INSTALLED"

  # t908 shape
  git -C "$r" config core.hooksPath "$t/does-not-exist/hooks"
  _t "ARM 8 (t908): core.hooksPath -> nonexistent dir -> HOOKSPATH_DANGLING (despite a hook in .git/hooks)" "$(_state "$r")" "HOOKSPATH_DANGLING"
  git -C "$r" config --unset core.hooksPath

  _t "ARM 9: a path that is not a repo -> NOT_A_REPO" "$(_state "$t/not_a_repo_at_all")" "NOT_A_REPO"

  local n
  AIMAIL_PUSH_GUARD_REPOS="$r $t/not_a_repo_at_all" push_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 10: push_guard_report returns the number of non-INSTALLED repos (1 of 2)" "$n" "1"
  AIMAIL_PUSH_GUARD_REPOS="$r" push_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 11: push_guard_report returns 0 when every configured repo is INSTALLED" "$n" "0"

  rm -rf "$t"
  echo "  ---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

# ─── commit_msg_guard_selftest — same falsification discipline, for commit-msg ──
commit_msg_guard_selftest() {
  local t; t="$(mktemp -d)"
  local pass=0 fail=0
  _t() { if [ "$2" = "$3" ]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }
  _state() { commit_msg_guard_status "$1" | cut -f1; }

  echo "pushguard.sh commit-msg selftest (fixtures under $t)"
  mkdir -p "$t/aimail_hooks"
  cp "$AIMAIL_HOME/hooks/sterility_commit_msg_guard.sh" "$t/aimail_hooks/sterility_commit_msg_guard.sh"
  chmod +x "$t/aimail_hooks/sterility_commit_msg_guard.sh"
  # a real, executable, but unrelated script -- must never read INSTALLED
  printf '#!/usr/bin/env bash\nexit 0\n' > "$t/aimail_hooks/unrelated.sh"
  chmod +x "$t/aimail_hooks/unrelated.sh"

  local r="$t/repo"; mkdir -p "$r"
  git -C "$r" init -q -b main
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  _t "ARM 1: fresh repo, no hook -> MISSING" "$(_state "$r")" "MISSING"

  ln -s "$t/aimail_hooks/sterility_commit_msg_guard.sh" "$r/.git/hooks/commit-msg"
  _t "ARM 2: hook resolves + carries the marker -> INSTALLED" "$(_state "$r")" "INSTALLED"

  # ⭐ FALSIFICATION: same repo, dangle the symlink by removing its target
  mv "$t/aimail_hooks/sterility_commit_msg_guard.sh" "$t/aimail_hooks/moved_away.sh"
  _t "ARM 3 (falsification): target removed -> the SAME repo now reads DANGLING" "$(_state "$r")" "DANGLING"
  mv "$t/aimail_hooks/moved_away.sh" "$t/aimail_hooks/sterility_commit_msg_guard.sh"
  _t "ARM 4: target restored -> INSTALLED again" "$(_state "$r")" "INSTALLED"

  chmod -x "$t/aimail_hooks/sterility_commit_msg_guard.sh"
  _t "ARM 5 (the a2fa1dc shape): target present but not executable -> DANGLING (git skips it)" "$(_state "$r")" "DANGLING"
  chmod +x "$t/aimail_hooks/sterility_commit_msg_guard.sh"

  # ⭐ the marker check: point commit-msg at a real, executable, but WRONG script
  rm "$r/.git/hooks/commit-msg"
  ln -s "$t/aimail_hooks/unrelated.sh" "$r/.git/hooks/commit-msg"
  _t "ARM 6: hook resolves to a real script missing the marker -> WRONG_SCRIPT (not INSTALLED)" "$(_state "$r")" "WRONG_SCRIPT"
  rm "$r/.git/hooks/commit-msg"
  ln -s "$t/aimail_hooks/sterility_commit_msg_guard.sh" "$r/.git/hooks/commit-msg"
  _t "ARM 7: pointed back at the real guard -> INSTALLED again" "$(_state "$r")" "INSTALLED"

  # t908 shape
  git -C "$r" config core.hooksPath "$t/does-not-exist/hooks"
  _t "ARM 8 (t908): core.hooksPath -> nonexistent dir -> HOOKSPATH_DANGLING (despite a hook in .git/hooks)" "$(_state "$r")" "HOOKSPATH_DANGLING"
  git -C "$r" config --unset core.hooksPath

  _t "ARM 9: a path that is not a repo -> NOT_A_REPO" "$(_state "$t/not_a_repo_at_all")" "NOT_A_REPO"

  local n
  AIMAIL_PUSH_GUARD_REPOS="$r $t/not_a_repo_at_all" commit_msg_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 10: commit_msg_guard_report returns the number of non-INSTALLED repos (1 of 2)" "$n" "1"
  AIMAIL_PUSH_GUARD_REPOS="$r" commit_msg_guard_report >/dev/null 2>&1; n=$?
  _t "ARM 11: commit_msg_guard_report returns 0 when every configured repo is INSTALLED" "$n" "0"

  rm -rf "$t"
  echo "  ---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
