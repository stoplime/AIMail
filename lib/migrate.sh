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
  printf '%-20s %9s %9s %9s %9s\n' SEAT ARCHIVED INBOX ROLES SKIPPED
  printf '%.0s─' {1..62}; echo

  local t_arch=0 t_inbox=0 t_roles=0 t_skip=0
  for seat in "${found[@]}"; do
    local a=0 i=0 r=0 s=0 f base dest

    # Archive → month shards, keyed on mtime.
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
      cp -p -- "$f" "$dest" && a=$((a+1)) || s=$((s+1))
    done < <(find "$src/$seat/archive" -name '*.md' 2>/dev/null)

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
      cp -p -- "$f" "$dest" && i=$((i+1)) || s=$((s+1))
    done < <(find "$src/$seat" -maxdepth 1 -name '*.md' 2>/dev/null)

    printf '%-20s %9s %9s %9s %9s\n' "$seat" "$a" "$i" "$r" "$s"
    t_arch=$((t_arch+a)); t_inbox=$((t_inbox+i)); t_roles=$((t_roles+r)); t_skip=$((t_skip+s))
  done

  printf '%.0s─' {1..62}; echo
  printf '%-20s %9s %9s %9s %9s\n' TOTAL "$t_arch" "$t_inbox" "$t_roles" "$t_skip"
  echo

  # ─── Verify against the source, with denominators ──────────────────────────
  # ⚠ A migration that reports only what it wrote cannot detect what it missed.
  #   Count the SOURCE independently and compare — "0 of 0" and "0 of 13,327"
  #   look identical in a summary and mean opposite things.
  # ⛔ THE DENOMINATOR MUST COUNT ONLY WHAT THIS TOOL CLAIMS TO MIGRATE. The first
  #    version counted every `*.md` under the source root, which swept in the
  #    mailbox's own top-level documents (README, the design doc, a cold-start
  #    manual) — files that are NOT mail and are correctly not imported. It then
  #    reported them as unaccounted-for, i.e. **the instrument manufactured its
  #    own shortfall and blamed the migration.** A denominator that includes
  #    things the numerator can never contain always reads as data loss.
  local src_total=0 dst_total seat_n
  for seat_n in "${found[@]}"; do
    src_total=$(( src_total + $(find "$src/$seat_n" -name '*.md' \
      -not -name 'ROLE.md' -not -name 'BOOTSTRAP_PROMPT.md' -not -path '*/_*' 2>/dev/null | wc -l) ))
  done
  dst_total=$(find "$MAIL_DIR" -name '*.md' 2>/dev/null | wc -l)
  info "source messages in the ${#found[@]} discovered seat(s): $src_total"
  info "target messages now present:                            $dst_total"
  if (( dry )); then
    warn "DRY RUN — nothing was written. Re-run without --dry-run to import."
  elif (( dst_total >= src_total )); then
    ok "migration complete: $dst_total of $src_total source message(s) present"
  else
    # ⚠ A LIVE SOURCE RACES WITH THE COPY, and that is the normal case, not a
    #   fault: a mailbox being migrated is usually still receiving. Mail that
    #   lands after the loop has passed its seat is in the source and not yet in
    #   the target. Re-running picks it up, so the correct cutover is: migrate
    #   once now, then migrate again at the moment of the switch.
    warn "target has $dst_total of $src_total — $(( src_total - dst_total )) not yet copied"
    warn "If the source is LIVE this is expected: mail arriving during the copy is"
    warn "missed by one pass. Re-run — the import is idempotent and resumes."
  fi
  info ""
  info "The source mailbox is UNCHANGED and still running. Nothing was moved."
}
