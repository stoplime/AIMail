# shellcheck shell=bash
# sterility.sh — does any tracked file in this repo contain an operator/company/project
# name it should not (this tool ships to other fleets; deployment detail does not belong
# in the shared source)?
#
# The term list is deliberately NOT hardcoded here: this file ships to every fleet that
# uses this tool, and a fleet's own operator/company/project names are exactly the thing
# this check exists to keep OUT of the shared source. Each fleet configures its own list
# in its own etc/aimail.conf (gitignored, never shared) as AIMAIL_STERILITY_TERMS -- a
# single string of terms separated by `|`, matched as an extended regex, case-insensitive.
# Unset or empty: the scan is a deliberate no-op, since a fresh install has no terms of its
# own registered yet and nothing to check against.
#
# LICENSE is exempt by design, not by regex luck: a real copyright notice legitimately
# names the real copyright holder, and that is not a leak -- it is required. Every other
# tracked file is in scope.

# sterility_scan -- prints one "path:line:matched-text" per hit, returns the hit count
# (capped at 255 by the shell's own exit-status convention; that ceiling is a reporting
# detail, never treated as "clean").
sterility_scan() {
  local terms="${AIMAIL_STERILITY_TERMS:-}"
  [[ -z "$terms" ]] && return 0
  local root; root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
  local hits=0 f matched
  while IFS= read -r f; do
    [[ "$f" == "LICENSE" ]] && continue
    matched="$(grep -inE "$terms" -- "$root/$f" 2>/dev/null)" || true
    [[ -z "$matched" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '%s:%s\n' "$f" "$line"
      hits=$((hits + 1))
    done <<< "$matched"
  done < <(cd "$root" && git ls-files)
  return "$hits"
}

# sterility_report -- human-readable summary for `aimail doctor`/`aimail session`; prints
# nothing and returns 0 when clean or unconfigured.
sterility_report() {
  local out; out="$(sterility_scan)"; local rc=$?
  [[ "$rc" -eq 0 ]] && return 0
  printf '⛔ STERILITY: %d tracked hit(s) for a configured operator/company/project term:\n' "$rc"
  printf '%s\n' "$out" | sed 's/^/   /'
  printf '   Configure AIMAIL_STERILITY_TERMS in etc/aimail.conf if this is a false positive\n'
  printf '   (a term that is not actually operator/company/project-identifying).\n'
  return "$rc"
}

# sterility_scan_identity -- content scanning (above) never sees commit AUTHOR/COMMITTER
# metadata; a name can be scrubbed from every tracked file and still sit in plain sight in
# `git log`. This checks the identity THIS commit is ABOUT TO USE -- resolved by `git var`,
# the same precedence git itself applies (GIT_AUTHOR_*/GIT_COMMITTER_* env override, else
# config, else ident.useConfigOnly), never re-implemented here. Meant to run pre-commit,
# so a leaking identity is refused before the commit exists, not found after.
sterility_scan_identity() {
  local terms="${AIMAIL_STERILITY_TERMS:-}"
  [[ -z "$terms" ]] && return 0
  local hits=0 kind ident
  for kind in AUTHOR COMMITTER; do
    ident="$(git var "GIT_${kind}_IDENT" 2>/dev/null)" || continue
    [[ -z "$ident" ]] && continue
    if grep -qiE "$terms" <<<"$ident"; then
      printf '%s: %s\n' "${kind,,}" "$ident"
      hits=$((hits + 1))
    fi
  done
  return "$hits"
}

# sterility_scan_history -- audit-facing, NEVER a gate: existing history cannot be rewritten
# by a seat (published commits, force-push is the owner's call alone). This only REPORTS
# which reachable commits already carry a configured term in their author/committer
# identity, so a human has the facts to decide whether/when to rewrite -- it must never be
# wired into anything that blocks on its own result.
sterility_scan_history() {
  local terms="${AIMAIL_STERILITY_TERMS:-}"
  [[ -z "$terms" ]] && return 0
  local hits=0 line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line"
    hits=$((hits + 1))
  done < <(git log --format='%H %an <%ae> / %cn <%ce>' 2>/dev/null | grep -iE "$terms")
  # ⛔ COMMIT MESSAGES are a third category (2026-09-23 02:01): a message can name what the file
  #   scan just removed. Scanned over the UNPUSHED range when an upstream exists (origin/main..HEAD,
  #   what a rewrite could still reach), else the whole history; one line per hit, "message:<sha> <text>".
  local range="" upstream
  upstream="$(git rev-parse --verify -q origin/main 2>/dev/null || git rev-parse --verify -q '@{upstream}' 2>/dev/null || true)"
  [[ -n "$upstream" ]] && range="$upstream..HEAD"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf 'message:%s\n' "$line"
    hits=$((hits + 1))
  done < <(git log ${range:+"$range"} --format='%H %s%n%H %b' 2>/dev/null | grep -iE "$terms" | grep -vE '^[0-9a-f]{40} $')
  return "$hits"
}
