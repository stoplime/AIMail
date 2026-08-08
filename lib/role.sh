# shellcheck shell=bash
# role.sh — the handover document, and the resume path that reads it.
#
# ═══ WHAT A ROLE FILE IS FOR ═══════════════════════════════════════════════════
# When the account is switched, every session's context switches with it. The
# sessions do not survive: the profile switcher repoints the ~/.claude symlink and
# reloads the editor, so each seat comes back as a NEW session with no memory of
# what it was doing. The role file is the ONLY thing that crosses that boundary.
#
# ⇒ A seat that has not written one resumes blind and re-derives work already done.
#   That is the entire reason `budget checkpoint` exists.
#
# ═══ WHY IT DOES NOT LIVE IN THE INBOX ═════════════════════════════════════════
# In the predecessor it sat at `mailbox/<seat>/ROLE.md` — inside the directory
# where mail is globbed. Every consumer therefore had to exclude it by ANCHORED
# exact name:
#     ls *.md | grep -vxE 'ROLE\.md|BOOTSTRAP_PROMPT\.md'   correct
#     ls *.md | grep -vE  'ROLE|BOOTSTRAP'                  drops real mail
# The second is a substring match, and it produced a false "inbox empty" on a
# message whose own subject line mentioned ROLE.
# ⇒ Here the file lives at $AIMAIL_ROOT/roles/<seat>.md. A document that is not
#   mail should not live where mail is globbed. The exclusion problem cannot
#   recur, because there is nothing to exclude.

ROLES_DIR() { echo "$AIMAIL_ROOT/roles"; }
ROLE_FILE() { echo "$(ROLES_DIR)/$1.md"; }

# ⚠ A handover that costs a fresh session most of its context is not a handover.
#   Measured on the migrated set: the largest role file was 1.3 MB and two others
#   were over 400 KB — they had been APPENDED to for weeks rather than rewritten,
#   so they are archives wearing a handover's name. Reading one would consume the
#   context the resume exists to preserve.
ROLE_WARN_BYTES="${AIMAIL_ROLE_WARN_BYTES:-32768}"

role_show() {
  local seat="$1" f; f="$(ROLE_FILE "$seat")"
  [[ -f "$f" ]] || unmeasurable "seat '$seat' has no role file" \
    "Expected: $f" \
    "This is NOT the same as 'the seat has nothing to hand over' — it means" \
    "nothing was ever written. A seat with no role file resumes blind." \
    "  aimail role write $seat < handover.md"
  local sz age; sz="$(stat -c %s "$f")"; age="$(age_min "$(stat -c %Y "$f")")"
  info "role: $seat    ${sz}B    written ${age} min ago"
  if (( sz > ROLE_WARN_BYTES )); then
    warn "this role file is ${sz}B — over the ${ROLE_WARN_BYTES}B guideline."
    warn "A handover that costs a fresh session most of its context defeats its own"
    warn "purpose. Rewrite it as current state, not an append-only log."
  fi
  echo
  cat -- "$f"
}

role_write() {
  local seat="$1" src="${2:-}"
  mkdir -p "$(ROLES_DIR)"
  local f; f="$(ROLE_FILE "$seat")"
  # Keep the previous version. A handover overwritten by a worse one is a loss
  # that only shows up when someone tries to resume from it.
  [[ -f "$f" ]] && cp -p "$f" "$(ROLES_DIR)/.$seat.prev.md"
  if [[ -n "$src" ]]; then
    [[ -f "$src" ]] || refused "no such file: '$src'"
    atomic_write "$f" < "$src"
  else
    [[ -t 0 ]] && refused "no content given." \
      "  aimail role write $seat handover.md" \
      "  aimail role write $seat < handover.md"
    atomic_write "$f"
  fi
  ok "wrote role for '$seat' ($(stat -c %s "$f")B) → $f"
  # ⛔⛔ `[[ test ]] && cmd` AS A FUNCTION'S LAST STATEMENT LEAKS THE FALSE TEST AS
  #    THE FUNCTION'S EXIT CODE. Written that way, this returned 1 on the FIRST
  #    write of a handover — no previous version existed, so the test was false —
  #    while the file had been written correctly and the success line had already
  #    printed. A caller keying on $? would conclude the handover was not saved.
  # ⚠ Caught by the test suite, not by reading: the output said ✔ and the exit
  #   code said failure, and only one of those is machine-checkable.
  if [[ -f "$(ROLES_DIR)/.$seat.prev.md" ]]; then
    info "  previous version kept at .$seat.prev.md"
  fi
  return 0
}

# role_stale — WHICH SEATS HAVE NOT WRITTEN A HANDOVER THIS BLOCK.
# ⭐ This is the checkpoint's verification arm, and without it the checkpoint is
#   an instruction nobody checks. Sending the mail proves a request was made; it
#   proves nothing about whether a handover exists. Delivery is not compliance.
role_stale() {
  local ref="${1:-}"
  local cutoff
  if [[ "$ref" =~ ^[0-9]+$ ]]; then cutoff="$ref"
  else
    source "$AIMAIL_LIB/budget.sh" 2>/dev/null || true
    local bs; bs="$(block_field start 2>/dev/null || echo '')"
    cutoff="${bs:-$(( $(now_epoch) - 18000 ))}"
  fi

  printf '%-20s %10s %10s  %s\n' SEAT SIZE AGE STATE
  printf '%.0s─' {1..64}; echo
  local seat n_ok=0 n_stale=0 n_none=0 f
  while IFS= read -r seat; do
    [[ -n "$seat" ]] || continue
    [[ "$(seat_field "$seat" 2)" == "retired" ]] && continue
    f="$(ROLE_FILE "$seat")"
    if [[ ! -f "$f" ]]; then
      printf '%-20s %10s %10s  ⛔ NO ROLE FILE — would resume blind\n' "$seat" "—" "—"
      n_none=$((n_none+1)); continue
    fi
    local mt sz age; mt="$(stat -c %Y "$f")"; sz="$(stat -c %s "$f")"; age="$(( ( $(now_epoch) - mt ) / 60 ))"
    if (( mt < cutoff )); then
      printf '%-20s %10s %9sm  ⚠ STALE — predates this block\n' "$seat" "$sz" "$age"
      n_stale=$((n_stale+1))
    else
      printf '%-20s %10s %9sm  ✔ current\n' "$seat" "$sz" "$age"
      n_ok=$((n_ok+1))
    fi
  done < <(seat_names)
  echo
  # ④ PRINT THE DENOMINATOR. "0 stale" and "0 seats checked" look identical.
  info "$n_ok current · $n_stale stale · $n_none missing   (of $(( n_ok + n_stale + n_none )) active seats)"
  info "cutoff: $(date -d "@$cutoff" '+%F %H:%M') — the current block's start"
  (( n_stale + n_none > 0 )) && {
    warn "$(( n_stale + n_none )) seat(s) would resume BLIND after an account switch."
    info "  Do not switch until these are written, or accept losing their in-flight work."
    return 1
  }
  ok "every active seat has a handover from this block. Safe to switch."
  return 0
}

# ─── resume — the other half of the checkpoint ────────────────────────────────
# ⭐⭐ THIS IS WHAT A SEAT RUNS FIRST ON A NEW ACCOUNT. The checkpoint writes the
#    handover; this reads it. Without both halves the mechanism is one-sided: the
#    predecessor had the "write your ROLE.md" instruction and no defined way to
#    consume it, so each new session improvised its own catch-up and some simply
#    started over.
role_resume() {
  local seat="$1"
  info "═══ RESUME: $seat ═══"
  source "$AIMAIL_LIB/budget.sh" 2>/dev/null || true
  info "account: $(account_id 2>/dev/null || echo unknown)    $(instrument_id)"
  echo

  # 1. The handover.
  local f; f="$(ROLE_FILE "$seat")"
  if [[ -f "$f" ]]; then
    local sz; sz="$(stat -c %s "$f")"
    info "── HANDOVER (${sz}B, written $(age_min "$(stat -c %Y "$f")") min ago) ──"
    if (( sz > ROLE_WARN_BYTES )); then
      warn "role file is ${sz}B — printing the first ${ROLE_WARN_BYTES}B only."
      warn "The rest is at $f. A handover this large is an append-only log, not a"
      warn "handover; rewrite it as current state when you next checkpoint."
      head -c "$ROLE_WARN_BYTES" -- "$f"; echo; echo "[… truncated, see $f]"
    else
      cat -- "$f"
    fi
  else
    warn "── NO HANDOVER for '$seat' ──"
    warn "Nothing was written before the switch, so the previous session's progress"
    warn "is not recorded here. Do NOT assume the work was not done — check the"
    warn "branch, the archive, and this seat's un-acked mail before redoing anything."
  fi

  # 2. What is waiting.
  echo; info "── MAIL WAITING ──"
  local q u
  q=$(find "$MAIL_DIR/$seat"         -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  u=$(find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  info "  $q queued, $u delivered-but-un-acked"
  (( u > 0 )) && info "  ⚠ un-acked mail is re-printed on the next poll — you have not missed it."

  # 3. What to do, in order.
  echo; info "── YOUR NEXT THREE COMMANDS ──"
  info "  1. bash $AIMAIL_HOME/hooks/stop_guard.sh register $seat"
  info "  2. aimail poll $seat        (run_in_background=true — this is your only wake path)"
  info "  3. aimail budget status     (confirm the block and the cap on THIS account)"
  echo
  info "⚠ The account changed, so every pre-switch budget reading describes a window"
  info "  that no longer exists. Get a fresh /usage callout before trusting a level."
}

# ─── whoami — AR-21: nothing told a fresh session which seat it IS ────────────
# ⛔⛔ THE DEFECT: `resume <seat>` already existed, but it requires the caller to
#   ALREADY KNOW its own seat name — which is precisely what a genuinely fresh
#   session does not have. A session -> seat mapping already exists: the
#   stop-hook guard's own `register` verb writes one, to decide whose stop to
#   block. Nothing exposed THAT mapping as an identity lookup, so a fresh
#   session had no way to ask "who am I" even though the answer was already on
#   disk. Reuse it rather than inventing a second, competing mapping — two
#   session->seat records that can drift is worse than one.
_whoami_sid() { echo "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; }
role_whoami() {
  local sid; sid="$(_whoami_sid)"
  [[ -n "$sid" ]] || unmeasurable "no session id in this environment" \
    "Checked CLAUDE_CODE_SESSION_ID and CLAUDE_SESSION_ID — both unset." \
    "Cannot look up a seat without a session id to look it up BY." \
    "If your principal has already told you which seat you are, skip this:" \
    "  aimail resume <seat>"

  local f="$STATE_DIR/stopguard/session.$sid"
  if [[ -f "$f" ]]; then
    local seat; seat="$(cat "$f")"
    ok "this session ($sid) is registered as seat '$seat'"
    role_resume "$seat"
    return 0
  fi

  # AR-26 — the AR-21 comment above warned against "two session->seat records
  # that can drift" and it happened anyway: a deployment can copy/rename
  # hooks/stop_guard.sh into its own hook (different filename, wired into its
  # OWN settings.json) rather than invoking this one, and that fork keeps its
  # session registrations in its own state dir under its own naming
  # convention. When that happens EVERY seat reads as unregistered here even
  # though a hook has tracked every session all along — measured on this
  # deployment: `$STATE_DIR/stopguard/` had zero files ever written into it,
  # while the deployment's actual Stop hook had dozens of live seat_<sid>
  # mappings. Check an opt-in external mapping before giving up, so a forked
  # hook's registrations are not invisible to `whoami`.
  if [[ -n "${AIMAIL_EXTERNAL_SEAT_DIR:-}" ]]; then
    local ext="$AIMAIL_EXTERNAL_SEAT_DIR/seat_$sid"
    if [[ -f "$ext" ]]; then
      local seat; seat="$(cat "$ext")"
      ok "this session ($sid) is registered as seat '$seat' (via AIMAIL_EXTERNAL_SEAT_DIR)"
      role_resume "$seat"
      return 0
    fi
  fi

  local -a detail=(
    "'No mapping' is not the same claim as 'you are seat X' — do not guess."
    "Ask your principal which seat you are, then register AND look up in one step:"
    "  bash $AIMAIL_HOME/hooks/stop_guard.sh register <seat>"
    "  aimail whoami"
  )
  [[ -n "${AIMAIL_EXTERNAL_SEAT_DIR:-}" ]] && detail+=(
    "(also checked AIMAIL_EXTERNAL_SEAT_DIR: $AIMAIL_EXTERNAL_SEAT_DIR/seat_$sid — not found there either)"
  )
  unmeasurable "this session ($sid) is not registered to any seat yet" "${detail[@]}"
}
