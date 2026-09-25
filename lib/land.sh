# lib/land.sh — `aimail land <repo> <ref> <sha> --from <seat>`: the one way to move a shared ref.
#
# ⛔ WHY (2026-09-23 13:54 and 13:55, ninety seconds apart): two landers cut from the same parent;
#    the second `git update-ref` (2-arg) replaced the first's tip and a landed commit left the
#    branch silently. Then a cherry-pick built on a stale detached HEAD passed the 3-arg
#    compare-and-swap (the CAS protects the REF, never the lineage of the commit written into it)
#    and dropped two more. Every step a careful lander does by hand has a race window or a
#    blind spot; this command does all of them in one place, inside a lock, in the right order:
#
#      1. take the per-(repo,ref) lock (flock, the gateclaim family, under $STATE_DIR);
#      2. re-read the LIVE tip inside the lock;
#      3. refuse unless the live tip is an ancestor of <sha> (a real fast-forward);
#      4. move with `git update-ref <ref> <sha> <tip>` — the 3-arg form, expected-old = the tip
#         just read, so even a writer outside this lock cannot be overwritten;
#      5. verify after the move: the ref reads <sha> AND the previous tip is its ancestor;
#      6. print `git log --oneline <tip>..<sha>` and `--stat` for the landing mail.
#
# The reference-transaction landing guard (hooks/main_only_landing_guard.sh) is the layer that
# cannot be forgotten: it refuses any non-fast-forward on a protected ref for every writer. This
# command is the convenience that makes doing it right shorter than doing it wrong, and it never
# materializes a working tree: a landing is a ref move; `git checkout <sha> -- <paths>` in the
# shared checkout is a separate, path-scoped step (never a hard reset).
#
# Generic: the repo is a path, the ref a full name, the seat comes from the registry.
#
# ⛔ WHY THE GATE-SUMMARY REQUIREMENT (2026-09-25): this command's own six-step lock/CAS/verify
#    sequence above proves a landing is a SAFE ref move. It never proved the commit being moved
#    into place was actually a GREEN one — `aimail land` had zero mechanical connection to
#    `bin/check_battery_summary.sh`'s own acceptance check, so a landing to a protected,
#    must-prove ref could carry no battery evidence at all, or evidence for the wrong tree, and
#    this command would move it anyway. AIMAIL_LAND_REQUIRE_GATE lists the (repo,ref) pairs that
#    must cite a real, tree-matched, BATTERY_EXIT=0 summary (via --gate-summary <path>) before the
#    lock is even taken — checked here, not left to whoever writes the landing mail by hand.
#    Scope note: this increment covers ONLY the always-required citation path. A docs-only/
#    tools-only exemption (a lighter, still-mechanical citation for the cheap import-side-effect
#    and parity-registration checks) is deliberately NOT built here — flagged as a fast-follow so
#    this doesn't ship an invented, unreviewed "light gate" format alongside it. Until that
#    exists, every landing to a listed pair needs the same full battery citation, including a
#    docs-only one; that is a stricter default than existed before this change, never a weaker one.

LAND_LOCK_DIR() { echo "$STATE_DIR/land_locks"; }

_land_lock_name() {  # <repo-abs> <ref> -> a filesystem-safe lock name
  printf '%s|%s' "$1" "$2" | sha256sum | cut -c1-16
}

# The default must-prove set: the target project's own configured production landing ref, built
# off the SAME PLATFORM_ROOT / PLATFORM_PRODUCTION_REF already resolved by etc/aimail.conf --
# never a hardcoded repo name or ref name in this tracked file (this repo stays generic; the real
# path and ref name are machine-local config, exactly like PLATFORM_ROOT itself already is).
# AIMAIL_LAND_REQUIRE_GATE overrides the whole set: one "repo|ref" pair per line/word.
_land_require_gate_pairs() {
  if [[ -n "${AIMAIL_LAND_REQUIRE_GATE:-}" ]]; then
    printf '%s\n' $AIMAIL_LAND_REQUIRE_GATE
  elif [[ -n "${PLATFORM_ROOT:-}" && -n "${PLATFORM_PRODUCTION_REF:-}" ]]; then
    printf '%s|%s\n' "$PLATFORM_ROOT" "$PLATFORM_PRODUCTION_REF"
  fi
}

_land_requires_gate() {  # <repo-abs> <ref> -> 0 if this pair must cite a green battery summary
  local repo="$1" ref="$2" pair p_repo p_ref
  while IFS= read -r pair; do
    [[ -n "$pair" ]] || continue
    p_repo="${pair%%|*}"; p_ref="${pair#*|}"
    [[ -d "$p_repo" ]] || continue
    p_repo="$(cd "$p_repo" && git rev-parse --show-toplevel 2>/dev/null)" || continue
    [[ "$p_repo" == "$repo" && "$p_ref" == "$ref" ]] && return 0
  done < <(_land_require_gate_pairs)
  return 1
}

# ⛔ THE HOLD CHECK (2026-09-25, four landed-over-hold incidents in two days, most recently
#    a5ef6c6d3): a HOLD mail has no floor if the only thing enforcing it is a human/seat reading
#    mail by hand before landing -- the poller delivers every 5s, so a hold written moments
#    before the CAS move can still be sitting QUEUED (not yet in unacked/) at the instant
#    someone's own manual pre-land check runs, and is invisible to a check that only reads
#    unacked/. This scans the LANDER's own queued ($MAIL_DIR/<seat>/*.md, undelivered) and
#    unacked ($MAIL_DIR/<seat>/unacked/*.md, delivered/not-yet-acted-on) mail for the sha being
#    landed named together with the word "hold", called from inside land_run's flock, as late as
#    possible before the actual update-ref. Deliberately excludes archive/ -- an acked/archived
#    hold has already been acted on and is no longer a live block.
_land_hold_matches() {  # <file> <full-sha> -> 0 if this ONE mail names the sha (short or full,
                         #    case-insensitive) AND the word "hold" (case-insensitive) anywhere
  local f="$1" full="$2" short="${2:0:8}"
  [[ -f "$f" ]] || return 1
  grep -qiE "(${full}|${short})" "$f" 2>/dev/null || return 1
  grep -qiE '\bhold\b' "$f" 2>/dev/null || return 1
  return 0
}

_land_hold_check() {  # <seat> <full-sha> -> prints matching message ids, one per line (empty if none)
  local seat="$1" full="$2" f
  while IFS= read -r -d '' f; do
    _land_hold_matches "$f" "$full" && basename "$f" .md
  done < <(
    find "$MAIL_DIR/$seat"         -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null
    find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null
  )
}

land_run() {
  case "${1:-}" in
    -h|--help)
      info "usage: aimail land <repo-path> <ref> <sha> --from <seat> [--gate-summary <path>] [--override-hold <id>[,<id>...] --reason <reason>]"
      info "  Nothing was changed."
      exit 0 ;;
  esac
  local repo="${1:-}" ref="${2:-}" sha="${3:-}"; shift 3 2>/dev/null || true
  local from="" gate_summary="" override_hold_given=0 override_hold_ids_raw="" override_hold_reason="" reason_given=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        info "usage: aimail land <repo-path> <ref> <sha> --from <seat> [--gate-summary <path>] [--override-hold <id>[,<id>...] --reason <reason>]"
        info "  Nothing was changed."
        exit 0 ;;
      --from) from="${2:-}"; shift 2 ;;
      --gate-summary) gate_summary="${2:-}"; shift 2 ;;
      --override-hold)
        override_hold_given=1; override_hold_ids_raw="${2:-}"; shift 2
        ;;
      --reason)
        reason_given=1; override_hold_reason="${2:-}"; shift 2
        # ⛔ 2026-09-25 (code-review, 1817b55's gate): trim leading/trailing whitespace BEFORE
        #    the emptiness check below -- a bare `[[ -z ]]` treats " " or a tab as non-empty,
        #    silently accepting a whitespace-only "reason" and defeating the accountability
        #    this flag exists for (still logged, but with nothing a reader could act on).
        override_hold_reason="${override_hold_reason#"${override_hold_reason%%[![:space:]]*}"}"
        override_hold_reason="${override_hold_reason%"${override_hold_reason##*[![:space:]]}"}"
        ;;
      *) refused "land: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$repo" && -n "$ref" && -n "$sha" && -n "$from" ]] || refused \
    "usage: aimail land <repo-path> <ref> <sha> --from <seat> [--gate-summary <path>] [--override-hold <id>[,<id>...] --reason <reason>]" \
    "  e.g. aimail land /path/to/repo refs/heads/main 0123abcd --from main" \
    "  Locks (repo,ref), re-reads the live tip, refuses a non-fast-forward, moves with the 3-arg" \
    "  update-ref, verifies, and prints the log/stat for the landing mail." \
    "  --gate-summary <path>: required for any (repo,ref) in AIMAIL_LAND_REQUIRE_GATE (default:" \
    "  PLATFORM_ROOT's own configured PLATFORM_PRODUCTION_REF) -- a summary file accepted by" \
    "  bin/check_battery_summary.sh against the sha being landed." \
    "  --override-hold <id>[,<id>...] --reason <reason>: the hold check below still RUNS -- it" \
    "  clears ONLY the exact message id(s) named, never a blanket skip. Any active hold match not" \
    "  named refuses the landing; any named id that matches nothing refuses too (typo guard)." \
    "  Without --override-hold, a queued-or-unacked mail to <seat> naming this sha together with" \
    "  the word 'hold' refuses the landing."
  if (( override_hold_given )); then
    # ⛔ 2026-09-25 (assistant, after 09edd7ad's landed-over-a-real-hold race): the old
    #   --override-hold <reason> form SKIPPED the hold scan entirely rather than running it and
    #   clearing only what it named -- one override cleared EVERY active hold, including one the
    #   caller never saw (written after their pre-land check, before this attempt). Named ids
    #   force the override to describe reality: the scan always runs now; see below the lock.
    [[ -n "$override_hold_ids_raw" ]] || refused \
      "land: --override-hold requires at least one message id, e.g. --override-hold <id>[,<id>...] --reason \"...\"" \
      "  Run the land without --override-hold first -- its refusal lists the exact id(s) to name."
    [[ -n "$override_hold_reason" ]] || refused \
      "land: --override-hold requires --reason \"<reason>\", e.g. --reason \"hold withdrawn, mail <id>\""
  elif (( reason_given )); then
    # ⛔ 2026-09-25 (code-review, e98b4f9's gate, fast-follow): --reason ONLY does anything
    #   paired with --override-hold -- given alone it used to fall straight through as a silent
    #   no-op (nothing bypassed, since the ordinary hold scan still ran, but a caller who
    #   fat-fingered --override-hold got no diagnostic that the flag they typed did nothing).
    refused "land: --reason has no effect without --override-hold <id>[,<id>...] -- did you mean to pass both?"
  fi
  from="$(seat_resolve "$from")" || exit $?
  [[ -d "$repo" ]] || refused "land: no such directory '$repo'"
  repo="$(cd "$repo" && git rev-parse --show-toplevel 2>/dev/null)" || refused "land: '$1' is not a git repository"
  [[ "$ref" == refs/* ]] || refused "land: <ref> must be a full ref name (refs/heads/<branch>), got '$ref'"
  local full; full="$(git -C "$repo" rev-parse -q --verify "${sha}^{commit}" 2>/dev/null)" || refused "land: '$sha' is not a commit in $repo"

  if _land_requires_gate "$repo" "$ref"; then
    [[ -n "$gate_summary" ]] || refused \
      "land: $ref in $repo requires a --gate-summary <path> citation -- this pair is in" \
      "  AIMAIL_LAND_REQUIRE_GATE (or the default must-prove set) and this command" \
      "  will not move it on a bare sha alone. Nothing was moved."
    local checker="$AIMAIL_HOME/bin/check_battery_summary.sh" gate_out gate_rc
    [[ -x "$checker" ]] || checker="bash $AIMAIL_HOME/bin/check_battery_summary.sh"
    # ⛔ gate_rc MUST be captured on its own line, immediately after the command substitution,
    #    before any `if`/`!` test runs -- `$?` inside `if ! cmd; then` reflects the NEGATED
    #    if-test's own result (always 0 in the then-branch), never $checker's real exit code
    #    (code-review, 2026-09-25, verified with a minimal repro before the earlier af6202d gate).
    gate_out="$($checker "$gate_summary" "$full" 2>&1)"; gate_rc=$?
    if [[ $gate_rc -ne 0 ]]; then
      refused "land: --gate-summary $gate_summary did not pass check_battery_summary.sh (exit $gate_rc) for ${full:0:8}:" \
        "$gate_out" \
        "  Nothing was moved."
    fi
    info "land: gate summary $gate_summary accepted for ${full:0:8} (BATTERY_EXIT=0, tree-matched)."
  fi

  ensure_dirs; mkdir -p "$(LAND_LOCK_DIR)"
  local lockf; lockf="$(LAND_LOCK_DIR)/$(_land_lock_name "$repo" "$ref").lock"
  (
    flock -w "${AIMAIL_LAND_LOCK_WAIT:-30}" 9 || refused "land: another landing holds the lock for $ref in $repo (waited ${AIMAIL_LAND_LOCK_WAIT:-30}s) — retry; never bypass"

    # 2. the live tip, read INSIDE the lock
    local tip; tip="$(git -C "$repo" rev-parse -q --verify "$ref" 2>/dev/null || true)"
    if [[ -z "$tip" ]]; then
      refused "land: '$ref' does not exist in $repo — this command moves an existing landing ref; create the branch deliberately first"
    fi
    if [[ "$tip" == "$full" ]]; then
      info "land: $ref is already at ${full:0:8} — nothing to do"; exit 0
    fi
    # 3. fast-forward or refuse
    if ! git -C "$repo" merge-base --is-ancestor "$tip" "$full"; then
      refused "land: NON-FAST-FORWARD — the live tip ${tip:0:8} is not an ancestor of ${full:0:8}." \
        "  The tip moved since this commit was cut, or the commit sits on a stale base (a detached" \
        "  worktree HEAD does not follow the ref). Rebase or cherry-pick onto ${tip:0:8}, then land the new sha." \
        "  Nothing was moved."
    fi
    # ─── Hold check — INSIDE the lock, as late as possible before the CAS move (see this
    #    function's own header comment for why: a hold written moments before the move can
    #    still be QUEUED, not yet in unacked/, at the instant a human/seat's own manual check
    #    runs by hand; this re-reads both directories right here instead).
    local hold_ids; hold_ids="$(_land_hold_check "$from" "$full")"
    if (( override_hold_given )); then
      # The scan ALWAYS runs, even under --override-hold — see the arg-parse comment above for
      # why a blanket skip was the actual bug. An override clears only the ids it names.
      local -a matched_arr=() named_arr=() bad_named=() unnamed_matches=()
      while IFS= read -r _hl; do [[ -n "$_hl" ]] && matched_arr+=("$_hl"); done <<<"$hold_ids"
      IFS=',' read -ra named_arr <<<"$override_hold_ids_raw"
      local _i
      for _i in "${!named_arr[@]}"; do
        named_arr[$_i]="${named_arr[$_i]#"${named_arr[$_i]%%[![:space:]]*}"}"
        named_arr[$_i]="${named_arr[$_i]%"${named_arr[$_i]##*[![:space:]]}"}"
      done
      local _nid _mid _found
      for _nid in "${named_arr[@]}"; do
        [[ -n "$_nid" ]] || continue
        _found=0
        for _mid in "${matched_arr[@]}"; do [[ "$_mid" == "$_nid" ]] && { _found=1; break; }; done
        (( _found )) || bad_named+=("$_nid")
      done
      if (( ${#bad_named[@]} > 0 )); then
        refused "land: --override-hold named id(s) that do not match any active hold on ${full:0:8} (typo, or already resolved):" \
          "$(printf '  %s\n' "${bad_named[@]}")" \
          "  Re-run the land without --override-hold to see the current, real match list. Nothing was moved."
      fi
      for _mid in "${matched_arr[@]}"; do
        _found=0
        for _nid in "${named_arr[@]}"; do [[ "$_nid" == "$_mid" ]] && { _found=1; break; }; done
        (( _found )) || unnamed_matches+=("$_mid")
      done
      if (( ${#unnamed_matches[@]} > 0 )); then
        refused "land: --override-hold did not name every active hold on ${full:0:8} -- an override clears only" \
          "  what it explicitly names, never a blanket skip. Unnamed match(es):" \
          "$(printf '  %s\n' "${unnamed_matches[@]}")" \
          "  Add them to --override-hold <id>[,<id>...], after reading and deliberately overriding" \
          "  each one. Nothing was moved."
      fi
      info "land: --override-hold named and cleared ${#matched_arr[@]} hold(s) on ${full:0:8} (\"$override_hold_reason\")."
    else
      if [[ -n "$hold_ids" ]]; then
        refused "land: a queued-or-unacked mail to '$from' names ${full:0:8} together with HOLD --" \
          "  refusing to land over it. Message id(s):" \
          "$hold_ids" \
          "  Read it, resolve the hold, then either land again or pass" \
          "  --override-hold <id>[,<id>...] --reason \"<reason>\" (naming exactly these ids) if" \
          "  landing anyway is deliberate. Nothing was moved."
      fi
    fi
    # 4. the move: 3-arg compare-and-swap against the tip just read
    if ! git -C "$repo" update-ref "$ref" "$full" "$tip" 2>"$AIMAIL_ROOT/tmp/land.err.$$"; then
      local err; err="$(cat "$AIMAIL_ROOT/tmp/land.err.$$" 2>/dev/null)"; rm -f "$AIMAIL_ROOT/tmp/land.err.$$"
      refused "land: update-ref refused the move (the tip changed under the lock, or a hook refused):" "  $err" "  Nothing was moved."
    fi
    rm -f "$AIMAIL_ROOT/tmp/land.err.$$"
    # 5. verify
    local now_tip; now_tip="$(git -C "$repo" rev-parse -q --verify "$ref")"
    [[ "$now_tip" == "$full" ]] || die "land: VERIFY FAILED — $ref reads ${now_tip:0:8}, expected ${full:0:8}. Investigate before any further move."
    git -C "$repo" merge-base --is-ancestor "$tip" "$now_tip" || die "land: VERIFY FAILED — the previous tip ${tip:0:8} is not an ancestor of the new tip. Investigate before any further move."
    # 6. the landing mail's evidence
    ok "LANDED $ref in $repo: ${tip:0:8} -> ${full:0:8} (by $from, $(date -Iseconds))"
    info "git log --oneline ${tip:0:8}..${full:0:8}:"
    git -C "$repo" log --oneline "$tip..$full" | sed 's/^/  /'
    info "git diff --stat ${tip:0:8}..${full:0:8}:"
    git -C "$repo" diff --stat "$tip" "$full" | sed 's/^/  /'
    info "The working tree is NOT materialized by a landing: in the shared checkout run a path-scoped 'git checkout $full -- <paths>' (never a hard reset)."
  ) 9>"$lockf"
}
