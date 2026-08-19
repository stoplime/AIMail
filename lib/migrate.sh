# shellcheck shell=bash
# migrate.sh — import an existing file-based mailbox into aimail.
#
# Designed for a SEAMLESS cutover: the fleet keeps its whole archive, so a seat
# can answer "who knew what, when" on day one. The archive is the audit trail and
# it has settled real disputes; a migration that dropped it would be a downgrade
# no matter how good the new code is.
#
# ⚠ IT NEVER DELETES FROM THE SOURCE. The predecessor stays intact and running.
#   This copies. Re-running is safe and resumes.
#
# ⛔ AND IT NEVER WRITES INTO THE REPO. Mail is machine-local coordination, not
#    source. `aimail doctor` refuses an AIMAIL_ROOT inside the repo, and this
#    checks the same thing before it starts — a migration is the single easiest
#    way to accidentally commit 13,000 private messages.

# ROLE.md / BOOTSTRAP_PROMPT.md are NOT mail. The predecessor kept them INSIDE
# the inbox and every consumer had to exclude them by anchored exact name:
#     ls *.md | grep -vxE 'ROLE\.md|BOOTSTRAP_PROMPT\.md'   correct
#     ls *.md | grep -vE  'ROLE|BOOTSTRAP'                  drops real mail
# The second is a substring match, and it produced a false "inbox empty" on a
# message whose own subject mentioned ROLE.
# ⇒ Here they move OUT of the inbox entirely, to $AIMAIL_ROOT/roles/<seat>.md.
#   A document that is not mail should not live where mail is globbed.
_NOT_MAIL='ROLE.md BOOTSTRAP_PROMPT.md'

_is_not_mail() {
  local b="$1" n
  for n in $_NOT_MAIL; do [[ "$b" == "$n" ]] && return 0; done
  [[ "$b" == _* || "$b" == .* ]] && return 0
  return 1
}

# _archive_files <seat-dir> — every archived *.md under a seat, at depth >= 2
# (i.e. inside a subdirectory — `archive/`, `_archive/`, anything else — never
# a file sitting directly in the seat root, which is a live inbox message and
# belongs to the SEPARATE inbox loop).
#
# ⛔⛔ AR-16 — this used to be `find "$dir" -mindepth 2 -name '*.md' -not -path
#   '*/.*'`. `-path` matches the WHOLE path string find was given, including
#   the CALLER's own `$src` prefix — so migrating FROM a dot-path (a real
#   predecessor mailbox commonly lives under `~/.claude/...`) matched `*/.*`
#   on every single file and excluded the entire archive. The remedy the tool
#   printed on failure — "re-run, it resumes" — could never work either: an
#   empty result looks identical to "already imported", so nothing about a
#   re-run would change.
# ⇒ Prune dot-DIRECTORIES by NAME (`-type d -name '.*' -prune`), never by
#   PATH — a name test only ever looks at the current entry's basename, so it
#   cannot be defeated by anything above it in the path, dot or not.
# ⚠ NOT `-mindepth 2` in the same find call: GNU find suppresses evaluation
#   of EVERY test — including `-prune` — for entries shallower than mindepth,
#   so `-prune` never gets to fire on a depth-1 dot-directory and find walks
#   straight into it anyway (measured: a `.pytest_cache/` at depth 1 survived
#   `-mindepth 2 … -prune` intact, and a file inside it at depth 2 leaked
#   through). The depth-2 requirement is therefore enforced separately, on the
#   caller's side, against the path RELATIVE TO THIS SEAT — never against the
#   source root, for the same reason `-path` itself was unsafe above.
_archive_files() {
  local dir="$1" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    local rel="${f#"$dir"/}"
    [[ "$rel" == */* ]] || continue   # depth 1 = live inbox, not archive
    printf '%s\n' "$f"
  done < <(find "$dir" -type d -name '.*' -prune -o -type f -name '*.md' -print 2>/dev/null)
}

# _all_seat_files <seat-dir> — every *.md this seat has, any depth, dot-pruned.
# The reconciliation's SOURCE count (AR-15, below): what the archive loop AND
# the live-inbox loop TOGETHER are responsible for accounting for.
_all_seat_files() {
  find "$1" -type d -name '.*' -prune -o -type f -name '*.md' -print 2>/dev/null
}

# _shard_for <file> — month directory from the file's MTIME.
# ⚠ `mv`/`cp -p` preserve mtime, so an archived message's mtime remains its
#   WRITE time. That is the correct key: sharding by import date would file five
#   weeks of history under one month and destroy the chronology.
_shard_for() { date -r "$1" '+%Y-%m' 2>/dev/null || echo 'unknown'; }

migrate_run() {
  local src="" dry=0 register_only=0
  while (( $# )); do
    case "$1" in
      --dry-run)       dry=1; shift ;;
      --register-only) register_only=1; shift ;;
      -*) refused "unknown migrate flag: '$1'" "Try: --dry-run | --register-only" ;;
      *)  src="$1"; shift ;;
    esac
  done
  [[ -n "$src" ]] || refused "usage: aimail migrate <old-mailbox-dir> [--dry-run]"
  [[ -d "$src" ]] || refused "'$src' is not a directory."

  case "$AIMAIL_ROOT" in
    "$AIMAIL_HOME"|"$AIMAIL_HOME"/*)
      refused "AIMAIL_ROOT ($AIMAIL_ROOT) is inside the repo." \
        "Migrating there would stage every private message for commit." \
        "Point AIMAIL_ROOT outside the repository first." ;;
  esac
  ensure_dirs; mkdir -p "$AIMAIL_ROOT/roles"

  (( dry )) && warn "DRY RUN — nothing will be written."
  info "source: $src"
  info "target: $AIMAIL_ROOT"
  echo

  # ─── Discover seats ────────────────────────────────────────────────────────
  # A directory is a candidate seat if it holds mail or an archive. Underscore
  # and dot directories are state, not seats.
  local -a found=()
  local d b
  for d in "$src"/*/; do
    [[ -d "$d" ]] || continue
    b="$(basename "$d")"
    [[ "$b" == _* || "$b" == .* ]] && continue
    _valid_seat_name "$b" || { warn "skipping '$b' — not a valid seat name"; continue; }
    local n; n=$(find "$d" -name '*.md' 2>/dev/null | head -1)
    [[ -n "$n" ]] && found+=("$b")
  done

  (( ${#found[@]} == 0 )) && unmeasurable "no seat directories with mail found under '$src'" \
    "Looked for <src>/<name>/**/*.md, skipping _* and .* directories."

  info "discovered ${#found[@]} seat(s): ${found[*]}"

  # ⚠ ANNOUNCE WHAT IS BEING SKIPPED. A migrator that silently ignores a
  #   directory is how 12 archived messages went missing under a name nobody
  #   expected. Anything not traversed gets named here, so a human can judge it.
  local sd skipped_dirs=""
  for seat in "${found[@]}"; do
    while IFS= read -r sd; do
      [[ -n "$sd" ]] && skipped_dirs+="  $seat/$(basename "$sd")"$'\n'
    done < <(find "$src/$seat" -mindepth 1 -maxdepth 1 -type d -name '.*' 2>/dev/null)
  done
  [[ -n "$skipped_dirs" ]] && { warn "skipping dot-directories (tooling, not mail):"; printf '%s' "$skipped_dirs" >&2; }
  echo

  # ─── Register ──────────────────────────────────────────────────────────────
  local seat
  for seat in "${found[@]}"; do
    if seat_exists "$seat"; then
      info "  already registered: $seat"
    elif (( dry )); then
      info "  would register: $seat"
    else
      seat_add "$seat" "migrated from $src" "-" >/dev/null && info "  registered: $seat"
    fi
  done
  (( register_only )) && { echo; ok "registration complete (--register-only)"; return 0; }

  # ─── Import ────────────────────────────────────────────────────────────────
  echo
  printf '%-20s %9s %9s %9s %9s %9s\n' SEAT ARCHIVED INBOX ROLES SKIPPED FAILED
  printf '%.0s─' {1..72}; echo

  local t_arch=0 t_inbox=0 t_roles=0 t_skip=0 t_fail=0
  declare -A _ACCT=()   # AR-15 — per-seat "files this run successfully accounted for"
  for seat in "${found[@]}"; do
    # ⭐ AR-15 — `fail` is its OWN counter, never folded into `s`. A file that
    #   is correctly recognised as not-mail, or already imported (same name +
    #   size), is "skipped" in the sense that nothing more needs to happen to
    #   it — it IS accounted for. A file whose `cp` genuinely failed is NOT:
    #   it is neither in the target nor correctly excluded, so it must NOT
    #   count toward "accounted for" below, or the reconciliation could never
    #   detect a real copy failure — exactly the falsifiability the review
    #   asked for, proven by forcing one (see the test for this arm).
    local a=0 i=0 r=0 s=0 fail=0 f base dest

    # Archive → month shards, keyed on mtime.
    # ⛔⛔ TRAVERSE EVERY SUBDIRECTORY, NOT JUST `archive/`. The first version read
    #    `$src/$seat/archive` only, and a real mailbox turned out to have a
    #    SECOND archive directory — `<seat>/_archive/` — holding 12 genuine
    #    messages that were silently skipped. The migration reported success.
    # ⭐ THAT IS THIS PROJECT'S OWN DEFECT CLASS, committed by its own migrator:
    #    a directory whose name nobody standardised becomes a black hole, and the
    #    tool that walks only the expected name cannot see what it missed.
    #    A per-seat count reconciled against the source is what caught it — the
    #    tool's own summary said "complete".
    # ⇒ Anything below the seat directory is archive. Dot-directories are skipped
    #   because they are tooling (`.pytest_cache`), not mail — and skipping them
    #   is ANNOUNCED below rather than silent.
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      base="$(basename "$f")"
      _is_not_mail "$base" && { s=$((s+1)); continue; }
      dest="$MAIL_DIR/$seat/archive/$(_shard_for "$f")/$base"
      # Idempotent: same name AND same size ⇒ already imported.
      if [[ -f "$dest" ]] && [[ "$(stat -c %s "$dest")" == "$(stat -c %s "$f")" ]]; then
        s=$((s+1)); continue
      fi
      if (( dry )); then a=$((a+1)); continue; fi
      mkdir -p "$(dirname "$dest")"
      cp -p -- "$f" "$dest" && a=$((a+1)) || fail=$((fail+1))
    done < <(_archive_files "$src/$seat")

    # Live inbox → inbox (still undelivered).
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      base="$(basename "$f")"
      if _is_not_mail "$base"; then
        # ROLE.md and friends move out of the inbox, not into it.
        if [[ "$base" == "ROLE.md" ]]; then
          (( dry )) || cp -p -- "$f" "$AIMAIL_ROOT/roles/$seat.md"
          r=$((r+1))
        else s=$((s+1)); fi
        continue
      fi
      dest="$MAIL_DIR/$seat/$base"
      [[ -f "$dest" ]] && { s=$((s+1)); continue; }
      if (( dry )); then i=$((i+1)); continue; fi
      cp -p -- "$f" "$dest" && i=$((i+1)) || fail=$((fail+1))
    done < <(find "$src/$seat" -maxdepth 1 -name '*.md' 2>/dev/null)

    printf '%-20s %9s %9s %9s %9s %9s\n' "$seat" "$a" "$i" "$r" "$s" "$fail"
    t_arch=$((t_arch+a)); t_inbox=$((t_inbox+i)); t_roles=$((t_roles+r)); t_skip=$((t_skip+s)); t_fail=$((t_fail+fail))
    _ACCT[$seat]=$(( a + i + r + s ))   # NOT +fail — a failed cp is not accounted for
  done

  printf '%.0s─' {1..72}; echo
  printf '%-20s %9s %9s %9s %9s %9s\n' TOTAL "$t_arch" "$t_inbox" "$t_roles" "$t_skip" "$t_fail"
  echo

  # ─── Verify against the source, PER SEAT, falsifiably (AR-15) ──────────────
  # ⛔⛔ THE OLD CHECK COMPARED TWO MISMATCHED NUMBERS. The numerator counted the
  #   WHOLE TARGET TREE (`find "$MAIL_DIR" -name '*.md'`) — every seat ever
  #   registered in aimail, not just the ones THIS run discovered — so any
  #   pre-existing mail (a prior migration, ordinary live use) inflated it for
  #   free. The denominator counted only DISCOVERED seats and excluded
  #   `*/_*` — the exact directory class the archive-traversal fix a few lines
  #   above exists to include, so a file that really was imported from an
  #   `_archive/`-style directory was invisible to its own denominator. Two
  #   independently wrong numbers can still agree by accident, which is worse
  #   than either being wrong alone: the review's own example was
  #   "✔ complete: 12 of 5" having copied 3 of 5 — a target that already held
  #   other mail made a real 3-of-5 shortfall read as 240% complete.
  # ⇒ Compare PER SEAT, using the SAME traversal rule as the import loops
  #   themselves (`_all_seat_files` — the identical dot-pruning `_archive_files`
  #   uses, just without the depth restriction), against the count those SAME
  #   loops already tracked as "looked at" (`_ACCT`). Two numbers computed by
  #   the same rule cannot disagree by construction; if they still don't match,
  #   that is a REAL file this run never touched, not an artifact of counting
  #   two different things.
  echo
  local all_reconciled=1 seat_n seat_src_n seat_acct_n
  for seat_n in "${found[@]}"; do
    seat_src_n=$(_all_seat_files "$src/$seat_n" | wc -l)
    seat_acct_n="${_ACCT[$seat_n]:-0}"
    if (( seat_acct_n < seat_src_n )); then
      all_reconciled=0
      warn "RECONCILIATION FAILED for '$seat_n': accounted for $seat_acct_n of $seat_src_n source message(s) — $(( seat_src_n - seat_acct_n )) UNEXPLAINED"
    fi
  done
  if (( dry )); then
    warn "DRY RUN — nothing was written. Re-run without --dry-run to import."
  elif (( all_reconciled )); then
    ok "migration reconciled: every discovered seat accounts for 100% of its source message(s)"
  else
    # ⚠ A LIVE SOURCE RACES WITH THE COPY, and that is the normal case, not a
    #   fault: a mailbox being migrated is usually still receiving. Mail that
    #   lands after the loop has passed its seat is in the source and not yet
    #   accounted for. Re-running picks it up — migrate once now, then again
    #   at the moment of the actual cutover.
    warn "One or more seats above did not reconcile (see the FAILED line(s))."
    warn "If the source is LIVE this can be expected — re-run; the import is idempotent."
    warn "If it persists after a re-run against a QUIESCENT source, investigate that seat."
  fi
  info ""
  info "The source mailbox is UNCHANGED and still running. Nothing was moved."
}
