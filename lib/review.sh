#!/usr/bin/env bash
# lib/review.sh — `aimail review`: "approved" is a recorded state, not a mail.
#
#   aimail review start <repo> <branch> --by <seat> [--base <ref>] [--author <seat>]...
#   aimail review check <sha>
#   aimail review approve <sha> --by <seat>
#   aimail review reject <sha> --by <seat> --reason "..."
#   aimail review status [<repo> <branch>] [--sha <sha>] [--quiet]
#   aimail review list
#   aimail review handoff <repo> <branch>
#
# ⛔ WHY IT EXISTS (the owner, 2026-10-01): a branch was about to become a pull request before anyone had
#   looked at its tests, and "GREEN" in a mail was the only thing saying it had been reviewed. A mail is
#   text; nobody can ask it "which commit?". Here an approval is a row naming the exact commit, the
#   reviewer, the checker version and the time, and `status` always answers for the branch's CURRENT tip,
#   so a new commit makes an old approval stale without anybody remembering to say so.
#
# GENERIC BY CONSTRUCTION. No project names live in this file. Repos are declared in aimail.conf:
#
#   AIMAIL_REVIEW_REPOS="alpha beta"           the names `review start` accepts
#   AIMAIL_REVIEW_PATH_alpha=/path/to/clone    where the repo is checked out
#   AIMAIL_REVIEW_RECORDS_alpha=/path/records  where <full-sha>.md records live
#   AIMAIL_REVIEW_CHECK_alpha="python3 /path/checker.py"   the checker command (a prefix)
#   AIMAIL_REVIEW_BASE_alpha=origin/main       the default base (--base overrides)
#   AIMAIL_REVIEW_CHECKER_FILE_alpha=/path/checker.py      hashed AT CHECK TIME into the approval row (optional)
#   AIMAIL_REVIEW_URL_alpha=<ERE>              remote URLs the push gate applies to
#   AIMAIL_REVIEW_PUSH_EXEMPT_alpha=<ERE>      merge-target branches the push gate does not ask about (optional)
#   AIMAIL_REVIEW_REMOTE_alpha=origin          the remote `handoff` prints in the push command (default origin)
#
# --by IS TIED TO THE SESSION: start, approve and reject refuse when the session is registered (stop_guard.sh)
# to a different seat; approve and reject also refuse an unregistered session. Without this, an author could
# type --by <someone else>.
#
# The checker is called as `<CHECK> <sha> --repo <path> --records <dir> --base <ref>` and must exit 0
# when the record and the diff pass; `<CHECK> <sha> --repo <path> --base <ref> --template` must print a
# record skeleton. A name with a hyphen uses an underscore in the variable names.
#
# WHAT THIS CANNOT KNOW: who wrote a commit when seats commit under a shared git identity. Authors are
# the commit author names in base..sha plus any `--author` given at start plus `Seat: <name>` trailers
# in the commit messages. A reviewer who is not named by any of them passes; the record's own `author:`
# line is the second witness, and `start --author` is how the one who knows fills the gap.

REVIEW_DIR() { echo "$STATE_DIR/reviews"; }
REVIEW_LEDGER() { echo "$STATE_DIR/review_approvals.tsv"; }
REVIEW_OVERRIDES() { echo "$STATE_DIR/review_overrides.log"; }
REVIEW_HANDOFFS() { echo "$STATE_DIR/review_handoffs.log"; }

_rv_var() {   # _rv_var <name-of-setting> <repo>  -> the value of AIMAIL_REVIEW_<SETTING>_<repo>
  local n="AIMAIL_REVIEW_${1}_${2//-/_}"; printf '%s' "${!n:-}"
}

_rv_repo_known() {
  local r="$1" x
  for x in ${AIMAIL_REVIEW_REPOS:-}; do [[ "$x" == "$r" ]] && return 0; done
  return 1
}

_rv_require_repo() {
  local r="$1"
  [[ -n "${AIMAIL_REVIEW_REPOS:-}" ]] || refused "no repos are configured for review" \
    "Set AIMAIL_REVIEW_REPOS (and AIMAIL_REVIEW_PATH_<repo>, _RECORDS_, _CHECK_) in etc/aimail.conf."
  _rv_repo_known "$r" || refused "'$r' is not a configured review repo" "Configured: ${AIMAIL_REVIEW_REPOS}"
  for k in PATH RECORDS CHECK; do
    [[ -n "$(_rv_var "$k" "$r")" ]] || refused "AIMAIL_REVIEW_${k}_${r//-/_} is not set" "etc/aimail.conf declares each configured repo's path, records dir and checker."
  done
}

_rv_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The seat this session is registered to (the stop-guard session map that prompts.sh also reads), or nothing.
_rv_session_seat() {
  local sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" f
  f="$STATE_DIR/stopguard/session.$sid"
  [[ -n "$sid" && -f "$f" ]] && cat "$f"
}

# _rv_bound <by> <allow|require>: --by is tied to the session that typed it. A session registered to a
# DIFFERENT seat is always refused; an unregistered session is refused only where a known seat is required.
_rv_bound() {
  local by="$1" mode="$2" reg a b
  reg="$(_rv_session_seat)"
  if [[ -z "$reg" ]]; then
    [[ "$mode" == "require" ]] && refused "this session is not registered to a seat, so --by $by cannot be tied to it" \
      "Register it first: bash \$AIMAIL_HOME/hooks/stop_guard.sh register <seat>. Approvals are recorded per seat."
    return 0
  fi
  a="$(seat_resolve "$reg" 2>/dev/null)" || true; [[ -n "$a" ]] || a="$reg"      # an alias resolves to its seat;
  b="$(seat_resolve "$by" 2>/dev/null)" || true;  [[ -n "$b" ]] || b="$by"       # a name the registry lacks stays as typed
  [[ "${a,,}" == "${b,,}" ]] || refused "this session is registered to seat '$reg', not '$by'" "--by must name the seat that is typing the command."
}


# state file of one review: key=value lines, keyed by the full sha
_rv_file() { echo "$(REVIEW_DIR)/$1.env"; }
_rv_get() { grep -m1 "^$2=" "$(_rv_file "$1")" 2>/dev/null | cut -d= -f2-; }
_rv_set() {   # _rv_set <sha> <key> <value>  (replaces the key)
  local f; f="$(_rv_file "$1")"; mkdir -p "$(REVIEW_DIR)"
  { grep -v "^$2=" "$f" 2>/dev/null || true; printf '%s=%s\n' "$2" "$3"; } > "$f.tmp" && mv "$f.tmp" "$f"
}

# resolve a full sha or a unique prefix (8+) to a review's full sha
_rv_resolve() {
  local p="${1,,}" m=() f
  [[ "$p" =~ ^[0-9a-f]{8,40}$ ]] || refused "'$1' is not a sha (8 to 40 hex characters)"
  for f in "$(REVIEW_DIR)"/"$p"*.env; do [[ -f "$f" ]] && m+=("$(basename "$f" .env)"); done
  (( ${#m[@]} == 1 )) || refused "no single review matches '$1'" "Open a review first: aimail review start <repo> <branch> --by <seat>"
  echo "${m[0]}"
}

_rv_ledger_add() {   # time sha repo branch reviewer result checker-version note
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$(REVIEW_LEDGER)"
}

_rv_authors() {   # _rv_authors <repo-path> <base> <sha> -> one lowercase name per line
  {
    git -C "$1" log --format='%an' "$2..$3" 2>/dev/null
    git -C "$1" log --format='%B' "$2..$3" 2>/dev/null | sed -n 's/^[Ss]eat:[[:space:]]*//p'
  } | tr 'A-Z' 'a-z' | sed 's/[[:space:]]*$//' | grep -v '^$' | sort -u
}

_rv_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

review_start() {
  local repo="${1:-}" branch="${2:-}"; shift 2 2>/dev/null || true
  [[ -n "$repo" && -n "$branch" ]] || refused "usage: aimail review start <repo> <branch> --by <seat> [--base <ref>] [--author <seat>]..."
  local by="" base="" extra=()
  while (( $# )); do
    case "$1" in
      --by) by="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --author) extra+=("${2,,}"); shift 2 ;;
      *) refused "unknown option for review start: $1" ;;
    esac
  done
  [[ -n "$by" ]] || refused "--by <seat> is required"
  _rv_bound "$by" allow
  _rv_require_repo "$repo"
  local path records check; path="$(_rv_var PATH "$repo")"; records="$(_rv_var RECORDS "$repo")"; check="$(_rv_var CHECK "$repo")"
  base="${base:-$(_rv_var BASE "$repo")}"
  [[ -n "$base" ]] || refused "no base: pass --base <ref> or set AIMAIL_REVIEW_BASE_${repo//-/_}"
  git -C "$path" rev-parse --verify --quiet "$base^{commit}" >/dev/null || refused "base '$base' does not exist in $path"
  local sha
  sha="$(git -C "$path" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null || git -C "$path" rev-parse --verify --quiet "origin/$branch^{commit}" 2>/dev/null)" \
    || refused "branch '$branch' does not exist in $path"
  local authors; authors="$( { _rv_authors "$path" "$base" "$sha"; printf '%s\n' "${extra[@]:-}"; } | grep -v '^$' | sort -u)"
  local lby="${by,,}"
  if grep -qx -- "$lby" <<<"$authors"; then
    refused "$by wrote part of $branch ($(sed -n 1p <<<"$(git -C "$path" log --format=%h -1 "$sha")")) and cannot review it" \
      "Authors found: $(paste -sd, <<<"$authors"). A second seat reviews."
  fi
  mkdir -p "$records" "$(REVIEW_DIR)"
  local rec="$records/$sha.md"
  if [[ -f "$(_rv_file "$sha")" ]]; then
    local prev; prev="$(_rv_get "$sha" reviewer)"
    [[ "${prev,,}" == "$lby" ]] || refused "a review of $sha is already open for $prev" "Reject or finish it first: aimail review status --sha $sha"
  fi
  if [[ ! -f "$rec" ]]; then
    local skel; skel="$($check "$sha" --repo "$path" --base "$base" --template 2>&1)" || die "the checker could not write a template: $skel"
    printf '%s\n' "$skel" \
      | sed -e "s|^reviewer:.*|reviewer: $by|" -e "s|^author:.*|author: $(paste -sd, <<<"$authors")|" > "$rec"
  fi
  _rv_set "$sha" repo "$repo"; _rv_set "$sha" branch "$branch"; _rv_set "$sha" base "$base"
  _rv_set "$sha" reviewer "$by"; _rv_set "$sha" authors "$(paste -sd, <<<"$authors")"
  _rv_set "$sha" started "$(_rv_now)"; _rv_set "$sha" started_epoch "$(now_epoch)"
  _rv_set "$sha" state "in review"
  ok "review open for $repo $branch at $sha (base $base)"
  info "record: $rec"
  info "authors found: ${authors:-（none）}"
  info "next: fill every section, then: aimail review check ${sha:0:12}"
}

review_check() {
  local sha; sha="$(_rv_resolve "${1:-}")" || exit $?
  local repo path records check base rec; repo="$(_rv_get "$sha" repo)"; _rv_require_repo "$repo"
  path="$(_rv_var PATH "$repo")"; records="$(_rv_var RECORDS "$repo")"; check="$(_rv_var CHECK "$repo")"; base="$(_rv_get "$sha" base)"
  rec="$records/$sha.md"
  local out rc; out="$($check "$sha" --repo "$path" --records "$records" --base "$base" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  local ver="unknown" cf; cf="$(_rv_var CHECKER_FILE "$repo")"; [[ -n "$cf" && -f "$cf" ]] && ver="$(_rv_sha256 "$cf" | cut -c1-12)"
  _rv_set "$sha" checker_version "$ver"
  _rv_set "$sha" checked_at "$(_rv_now)"
  _rv_set "$sha" checked_rc "$rc"
  _rv_set "$sha" checked_record_sha256 "$(_rv_sha256 "$rec")"
  if (( rc == 0 )); then ok "check passed for $sha"; return 0; fi
  warn "check FAILED for $sha (exit $rc)"; return 1
}

review_approve() {
  local sha; sha="$(_rv_resolve "${1:-}")" || exit $?; shift
  local by=""; while (( $# )); do case "$1" in --by) by="${2:-}"; shift 2 ;; *) refused "unknown option for review approve: $1" ;; esac; done
  [[ -n "$by" ]] || refused "--by <seat> is required"
  _rv_bound "$by" require
  local repo reviewer authors records rec; repo="$(_rv_get "$sha" repo)"; _rv_require_repo "$repo"
  reviewer="$(_rv_get "$sha" reviewer)"; authors="$(_rv_get "$sha" authors)"; records="$(_rv_var RECORDS "$repo")"; rec="$records/$sha.md"
  [[ "${by,,}" == "${reviewer,,}" ]] || refused "$by is not the reviewer of $sha (the reviewer is $reviewer)"
  if tr ',' '\n' <<<"${authors,,}" | grep -qx -- "${by,,}"; then refused "$by is an author of $sha and cannot approve it"; fi
  [[ -n "$(_rv_get "$sha" checked_at)" ]] || refused "run the check first: aimail review check ${sha:0:12}" "An approval without a passing check is not recorded."
  [[ "$(_rv_get "$sha" checked_rc)" == "0" ]] || refused "the last check of $sha failed" "Fix the record or the branch, then: aimail review check ${sha:0:12}"
  [[ "$(_rv_sha256 "$rec")" == "$(_rv_get "$sha" checked_record_sha256)" ]] || refused "the record changed after the last check" "Run: aimail review check ${sha:0:12}"
  local ver; ver="$(_rv_get "$sha" checker_version)"     # the hash at CHECK time: the checker that actually ran
  _rv_ledger_add "$(_rv_now)" "$sha" "$repo" "$(_rv_get "$sha" branch)" "$by" approved "$ver" "-"
  _rv_set "$sha" state approved
  ok "$sha approved by $by (checker $ver)"
}

review_reject() {
  local sha; sha="$(_rv_resolve "${1:-}")" || exit $?; shift
  local by="" why=""; while (( $# )); do case "$1" in --by) by="${2:-}"; shift 2 ;; --reason) why="${2:-}"; shift 2 ;; *) refused "unknown option for review reject: $1" ;; esac; done
  [[ -n "$by" && -n "$why" ]] || refused "usage: aimail review reject <sha> --by <seat> --reason \"...\""
  _rv_bound "$by" require
  local reviewer; reviewer="$(_rv_get "$sha" reviewer)"
  [[ "${by,,}" == "${reviewer,,}" ]] || refused "$by is not the reviewer of $sha (the reviewer is $reviewer)"
  _rv_ledger_add "$(_rv_now)" "$sha" "$(_rv_get "$sha" repo)" "$(_rv_get "$sha" branch)" "$by" rejected "-" "${why//$'\t'/ }"
  _rv_set "$sha" state rejected
  ok "$sha rejected by $by: $why"
}

# status word for an exact sha: approved | rejected | in review | none
_rv_sha_state() {
  local sha="$1" l; l="$(awk -F'\t' -v s="$sha" '$2==s {r=$6} END {print r}' "$(REVIEW_LEDGER)" 2>/dev/null)"
  if [[ -n "$l" ]]; then echo "$l"; return; fi
  [[ -f "$(_rv_file "$sha")" ]] && { echo "in review"; return; }
  echo none
}

review_status() {
  local repo="" branch="" sha="" quiet=0 pos=()
  while (( $# )); do
    case "$1" in
      --sha) sha="${2:-}"; shift 2 ;;
      --quiet) quiet=1; shift ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  local word detail=""
  if [[ -n "$sha" ]]; then
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || refused "--sha takes the full 40-character sha"
    word="$(_rv_sha_state "$sha")"
  else
    (( ${#pos[@]} == 2 )) || refused "usage: aimail review status <repo> <branch> | --sha <full-sha> [--quiet]"
    repo="${pos[0]}"; branch="${pos[1]}"; _rv_require_repo "$repo"
    local path; path="$(_rv_var PATH "$repo")"
    sha="$(git -C "$path" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null || git -C "$path" rev-parse --verify --quiet "origin/$branch^{commit}" 2>/dev/null)" \
      || refused "branch '$branch' does not exist in $path"
    word="$(_rv_sha_state "$sha")"
    if [[ "$word" == "none" ]]; then
      local old; old="$(awk -F'\t' -v r="$repo" -v b="$branch" '$3==r && $4==b && $6=="approved" {s=$2} END {print s}' "$(REVIEW_LEDGER)" 2>/dev/null)"
      if [[ -n "$old" ]]; then word="stale"; detail="approved at ${old:0:12}, the branch is now at ${sha:0:12}"
      else
        local f s
        for f in "$(REVIEW_DIR)"/*.env; do [[ -f "$f" ]] || continue; s="$(basename "$f" .env)"
          if [[ "$(_rv_get "$s" repo)" == "$repo" && "$(_rv_get "$s" branch)" == "$branch" ]]; then word="stale"; detail="a review is open at ${s:0:12}, the branch is now at ${sha:0:12}"; fi; done
      fi
    fi
  fi
  if (( quiet )); then echo "$word"; else info "$word${detail:+ ($detail)}  $sha"; fi
  [[ "$word" == "approved" ]]
}

review_list() {
  local f s n=0
  for f in "$(REVIEW_DIR)"/*.env; do [[ -f "$f" ]] || continue; s="$(basename "$f" .env)"
    [[ "$(_rv_get "$s" state)" == "in review" ]] || continue
    n=$((n+1))
    printf '%s  %s  %s  reviewer %s  open %s min\n' "${s:0:12}" "$(_rv_get "$s" repo)" "$(_rv_get "$s" branch)" "$(_rv_get "$s" reviewer)" \
      "$(age_min "$(_rv_get "$s" started_epoch)")"
  done
  (( n )) || info "no open reviews"
}

# ─── enforcement, the one question: does `status` say approved for this exact sha? ──────────────────
#
#   guard-push <remote> <url>   as a pre-push hook (refs on stdin). A push of a branch to a configured URL
#                               needs an approved review of the pushed sha. PR_READY_OVERRIDE="<reason>"
#                               gets past it and is appended to review_overrides.log. An empty reason is
#                               no override. Branches matching AIMAIL_REVIEW_PUSH_EXEMPT_<repo> (merge
#                               targets) are not asked.
review_guard_push() {
  local remote="${1:-}" url="${2:-}" rc=0 lref lsha rref rsha repo pat ex branch st
  local reason="${PR_READY_OVERRIDE:-}"; reason="${reason#"${reason%%[![:space:]]*}"}"
  while read -r lref lsha rref rsha; do
    [[ "$lsha" =~ ^[0-9a-f]{40}$ && "$lsha" != "0000000000000000000000000000000000000000" ]] || continue
    [[ "$rref" == refs/heads/* ]] || continue
    branch="${rref#refs/heads/}"
    for repo in ${AIMAIL_REVIEW_REPOS:-}; do
      pat="$(_rv_var URL "$repo")"; [[ -n "$pat" && "$url" =~ $pat ]] || continue
      ex="$(_rv_var PUSH_EXEMPT "$repo")"; [[ -n "$ex" && "$branch" =~ $ex ]] && continue
      st="$(review_status --sha "$lsha" --quiet)" && continue
      if [[ -n "$reason" ]]; then
        mkdir -p "$STATE_DIR"
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_rv_now)" "$(id -un)" "$repo" "$branch" "$lsha" "${reason//$'\t'/ } [review was: $st]" >> "$(REVIEW_OVERRIDES)"
        warn "review override accepted for $repo $branch ($st), logged: $reason"
      else
        printf '⛔ REFUSED: %s %s at %s has no approved review (status: %s).\n   Run: aimail review start %s %s --by <seat>, then check, then approve.\n   Last resort: PR_READY_OVERRIDE="<reason>" git push ... (logged).\n' \
          "$repo" "$branch" "${lsha:0:12}" "$st" "$repo" "$branch" >&2
        rc=1
      fi
    done
  done
  return $rc
}

# aimail review handoff <repo> <branch>: the ONLY way a seat gives the owner a push. It compares the branch's
# current sha with the ledger and nothing else; no text is read anywhere.
review_handoff() {
  local repo="${1:-}" branch="${2:-}"
  [[ -n "$repo" && -n "$branch" ]] || refused "usage: aimail review handoff <repo> <branch>"
  _rv_require_repo "$repo"
  local path records sha word
  path="$(_rv_var PATH "$repo")"; records="$(_rv_var RECORDS "$repo")"
  sha="$(git -C "$path" rev-parse --verify --quiet "$branch^{commit}" 2>/dev/null || git -C "$path" rev-parse --verify --quiet "origin/$branch^{commit}" 2>/dev/null)" \
    || refused "branch '$branch' does not exist in $path"
  word="$(review_status "$repo" "$branch" --quiet)" || true
  if [[ "$word" != "approved" ]]; then
    refused "$repo $branch at ${sha:0:12} is not approved (status: $word)" \
      "A branch is handed over only after: aimail review start / check / approve for this exact commit."
  fi
  local remote desc reviewer; remote="$(_rv_var REMOTE "$repo")"; remote="${remote:-origin}"
  desc="$(grep -m1 -i '^pr-description:' "$records/$sha.md" 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
  reviewer="$(_rv_get "$sha" reviewer)"
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(_rv_now)" "$(id -un)" "$repo" "$branch" "$sha" "$reviewer" >> "$(REVIEW_HANDOFFS)"
  ok "approved: $repo $branch at $sha (reviewer $reviewer)"
  info "push:           git -C $path push $remote $branch"
  info "PR description: ${desc:-（the record names no pr-description: line）}"
}

review_dispatch() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    start)   review_start "$@" ;;
    check)   review_check "$@" ;;
    approve) review_approve "$@" ;;
    reject)  review_reject "$@" ;;
    status)  review_status "$@" ;;
    list)    review_list ;;
    guard-push)    review_guard_push "$@" ;;
    handoff) review_handoff "$@" ;;
    *) refused "unknown 'review' subcommand: '${sub:-（none）}'" "Try: start | check | approve | reject | status | list | handoff | guard-push" ;;
  esac
}
