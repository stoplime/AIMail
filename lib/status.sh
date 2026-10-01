# shellcheck shell=bash
# status.sh — what is queued, what is un-acked, and whether this install is sane.
#
# ⚠ EVERY COUNT HERE PRINTS ITS DENOMINATOR AND ITS SOURCE. "0 of 0 because
#   nothing ran" and "0 of 19 affected" look almost identical in a report, and
#   the previous system published the first as an all-clear more than once.

status_report() {
  local only="${1:-}"
  local -a seats=()
  if [[ -n "$only" ]]; then seats=("$(seat_resolve "$only")") || exit $?
  else while IFS= read -r s; do [[ -n "$s" ]] && seats+=("$s"); done < <(seat_names); fi

  if (( ${#seats[@]} == 0 )); then
    unmeasurable "no seats are registered, so there is nothing to report on" \
      "This is not an empty queue — it is an empty address space." \
      "  aimail seat add <name>"
  fi

  printf '%-22s %8s %8s %10s  %s\n' SEAT QUEUED UN-ACKED ARCHIVED STATUS
  printf '%.0s─' {1..76}; echo
  local s q u a st tq=0 tu=0
  for s in "${seats[@]}"; do
    q=$(find "$MAIL_DIR/$s"         -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
    u=$(find "$MAIL_DIR/$s/unacked" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
    a=$(find "$MAIL_DIR/$s/archive" -name '*.md' 2>/dev/null | wc -l)
    st="$(seat_field "$s" 2)"
    tq=$((tq+q)); tu=$((tu+u))
    printf '%-22s %8s %8s %10s  %s\n' "$s" "$q" "$u" "$a" "$st"
  done
  echo
  info "$tq queued and $tu un-acked across ${#seats[@]} registered seat(s)"
  if (( tu > 0 )); then
    warn "$tu message(s) delivered but NOT acknowledged."
    info "  Un-acked mail is re-printed on every poll until acked. It is not lost,"
    info "  but it is also not done: 'delivered' has never meant 'read'."
  fi
  return 0
}

doctor() {
  local problems=0
  supervisor_alert_banner || true
  info "$(instrument_id)"
  info "root: $AIMAIL_ROOT"
  echo

  # ─── Version control (root cause RC-1) ──────────────────────────────────────
  # The single highest-leverage property this repo has over its predecessor. In
  # the old system every instrument was gitignored, so a grep result was valid
  # for exactly one (inode, mtime) and nothing recorded which one you measured.
  # Two seats measuring the same file hours apart both got true answers that
  # contradicted each other, with no way to reconcile them afterwards.
  if git -C "$AIMAIL_HOME" rev-parse --git-dir >/dev/null 2>&1; then
    ok "code is under version control ($(git -C "$AIMAIL_HOME" rev-parse --short HEAD 2>/dev/null || echo 'no commits yet'))"
    git -C "$AIMAIL_HOME" diff --quiet 2>/dev/null || warn "working tree is dirty — a claim about this code needs a sha AND 'dirty'"
  else
    warn "code is NOT under version control — no claim about it can be dated"; problems=$((problems+1))
  fi

  # ─── Data is not code ───────────────────────────────────────────────────────
  case "$AIMAIL_ROOT" in
    "$AIMAIL_HOME"|"$AIMAIL_HOME"/*)
      warn "AIMAIL_ROOT is inside the repo ($AIMAIL_ROOT) — mail would be committable"; problems=$((problems+1)) ;;
    *) ok "data root is outside the repo" ;;
  esac

  # ─── Registry ───────────────────────────────────────────────────────────────
  local n; n="$(seat_names | grep -c . || true)"
  if (( n == 0 )); then warn "0 seats registered — every send will refuse"; problems=$((problems+1))
  else ok "$n seat(s) registered"; fi

  # A directory in MAIL_DIR with no registry row is the black-hole shape: mail
  # written there is never read and never bounces.
  local d base stray=0
  for d in "$MAIL_DIR"/*/; do
    [[ -d "$d" ]] || continue
    base="$(basename "$d")"
    seat_exists "$base" || { warn "UNREGISTERED mail directory: $base — mail sent there would vanish"; stray=$((stray+1)); }
  done
  (( stray == 0 )) && ok "no unregistered mail directories"
  problems=$((problems+stray))

  # ─── Stale markers (FI-08) ──────────────────────────────────────────────────
  # Markers were written on a transition and never cleaned up, so a historical
  # `_nopoller_<seat>` read as current state. Every marker here carries content
  # and an expiry; anything past it is reported rather than silently trusted.
  local m expired=0 now; now="$(now_epoch)"
  for m in "$STATE_DIR"/marker.*; do
    [[ -f "$m" ]] || continue
    local exp; exp="$(awk -F'\t' '$1=="expires"{print $2}' "$m" 2>/dev/null)"
    if [[ "$exp" =~ ^[0-9]+$ ]] && (( now > exp )); then
      warn "EXPIRED marker still present: $(basename "$m") (expired $(( (now-exp)/60 ))m ago)"
      expired=$((expired+1))
    fi
  done
  (( expired == 0 )) && ok "no expired state markers"
  problems=$((problems+expired))

  # ─── Landing guard resolvability ─────────────────────────────────────
  # A symlinked reference-transaction hook whose target is gone, or a core.hooksPath
  # into a directory that no longer exists, makes git run NO hooks — silently. Say so.
  source "$AIMAIL_LIB/landingguard.sh" 2>/dev/null || true
  if command -v landing_guard_report >/dev/null 2>&1; then
    landing_guard_report; local lg_problems=$?
    problems=$((problems+lg_problems))
  else
    warn "landingguard.sh not loadable — landing-guard check skipped"; problems=$((problems+1))
  fi

  # ─── Pre-push sterility guard resolvability ──────────────────────────────────
  # Same silent-gap shape as the landing guard above: a real, tracked, falsified
  # hook script is not the same claim as it being live in .git/hooks/pre-push.
  source "$AIMAIL_LIB/pushguard.sh" 2>/dev/null || true
  if command -v push_guard_report >/dev/null 2>&1; then
    push_guard_report; local pg_problems=$?
    problems=$((problems+pg_problems))
  else
    warn "pushguard.sh not loadable — push-guard check skipped"; problems=$((problems+1))
  fi

  # ─── Commit-msg sterility guard resolvability ────────────────────────────────
  # Same shape as the pre-push check above, for hooks/sterility_commit_msg_guard.sh
  # (2026-09-24: shipped once already without its executable bit -- reachable but
  # never actually fires once installed, until this check exists to catch it).
  if command -v commit_msg_guard_report >/dev/null 2>&1; then
    commit_msg_guard_report; local cmg_problems=$?
    problems=$((problems+cmg_problems))
  else
    warn "pushguard.sh not loadable — commit-msg-guard check skipped"; problems=$((problems+1))
  fi

  # ─── Sterility (this fleet's own operator/company/project terms never leaking
  # into the shared source) ───────────────────────────────────────────────────
  if command -v sterility_report >/dev/null 2>&1; then
    local ster_out; ster_out="$(sterility_report)"; local ster_rc=$?
    if [[ -n "$ster_out" ]]; then
      printf '%s\n' "$ster_out"
      problems=$((problems+ster_rc))
    elif [[ -n "${AIMAIL_STERILITY_TERMS:-}" ]]; then
      ok "sterility: tracked tree is clean against its configured terms"
    else
      ok "sterility: no terms configured (AIMAIL_STERILITY_TERMS unset) — nothing checked"
    fi
  else
    warn "sterility.sh not loadable — sterility check skipped"; problems=$((problems+1))
  fi

  # ─── Sterility: commit identity, existing history (informational only) ─────
  # NEVER counted into `problems` -- a hit here is about ALREADY-PUBLISHED commits, which
  # only the owner can rewrite (force-push), never a seat. This is visibility, not a gate;
  # see lib/sterility.sh's own header on sterility_scan_history.
  if command -v sterility_scan_history >/dev/null 2>&1; then
    local hist_out; hist_out="$(sterility_scan_history)"; local hist_rc=$?
    if [[ "$hist_rc" -gt 0 ]]; then
      warn "sterility: $hist_rc commit(s) in history carry a configured term in their author/committer identity (not a gate -- rewriting published history is the owner's call alone):"
      printf '%s\n' "$hist_out" | sed 's/^/   /'
    fi
  fi

  # ─── Dependencies ───────────────────────────────────────────────────────────
  local dep
  for dep in awk sed find sha256sum stat date; do
    command -v "$dep" >/dev/null || { warn "missing required tool: $dep"; problems=$((problems+1)); }
  done
  ok "core dependencies present"

  echo
  if (( problems == 0 )); then ok "doctor: 0 problems found (checks run: version-control, data-root, registry, stray-dirs, markers, landing-guard, sterility, deps)"
  else warn "doctor: $problems problem(s) found across 8 check groups"; return 1; fi
}
