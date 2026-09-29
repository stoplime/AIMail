#!/usr/bin/env bash
# lib/handover.sh — the SUPERVISOR BUDGET HANDOVER (the owner's design, 2026-09-23 09:00, corrected 09:04).
#
# ⛔ THE RULE THIS SERVES (the owner, 2026-09-23 08:50): the supervisor is never killed or replaced. When
#   its account runs out of weekly budget the SEAT moves, the SESSION does not die: the seat's own PRIOR
#   session on the target account is resumed (never a fresh one while any prior exists), the seat's model
#   is pinned on the resume, Remote Control is on under the seat's own name so the owner can find it, and
#   the OLD session is left alive off aimail -- poller gone, hooks releasing it, its budget and its memory
#   kept for the owner's questions. R6 items (e) supersession record, (f) never-stop, (g) this handover.
#
# TRIGGER  the supervisor's account weekly >= AIMAIL_SUPERVISOR_HANDOVER_PCT (default 95; the cap is 98).
# TARGET   --target, else the measured, unparked pool account with the MOST weekly headroom that holds a
#          prior session of this seat. No prior session anywhere usable -> refuse (a fresh launch is the
#          owner's decision, `seat migrate --fresh --why`, with --remote-control added for the supervisor).
# PRIOR    seat_prior_session: the seat-sessions registry for that account first; else the account's
#          transcripts, fingerprinted by the seat's OWN poller command ("aimail poll(-persistent) <seat>"),
#          most recently written wins. The cwd for the resume is the transcript's own project dir.
# ACT      `aimail fleet supervisor-handover --act` = seat migrate with --keep-old (the old session is not
#          stopped), --model <pin>, --sid <prior>, --cwd <its dir>, --owner-approved (the design); then the
#          old id is recorded `retired_sessions kept:<sid>@<time>` on the seat record (the poller of a
#          retired session exits with WAKE=superseded and stop_guard releases it), and the vice + the human
#          alert seat + the owner inbox file (AIMAIL_OWNER_INBOX) get the new id and account.
# DRY      without --act it prints the plan and every command; with the weekly under the threshold it
#          refuses to ACT unless --force (the plan still prints).

# seat_model_pin <seat> — the model every move/relaunch pins for this seat.
#   AIMAIL_MODEL_PIN_<seat> wins; else: fable -> the fable pin, the supervisor -> the supervisor pin,
#   every other seat -> AIMAIL_MODEL_PIN_DEFAULT.
seat_model_pin() {
  local seat="$1" var v; var="AIMAIL_MODEL_PIN_${seat//[^a-zA-Z0-9_]/_}"; v="${!var:-}"
  [[ -n "$v" ]] && { echo "$v"; return 0; }
  if [[ "$seat" == "fable" ]]; then echo "${AIMAIL_MODEL_PIN_FABLE:-claude-fable-5-1}"
  elif [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]]; then echo "${AIMAIL_MODEL_PIN_SUPERVISOR:-claude-opus-5-5}"
  else echo "${AIMAIL_MODEL_PIN_DEFAULT:-claude-sonnet-5-5}"; fi
}

# _slug_to_dir <projects-slug> — the scheduler names a project dir by its path with '/' -> '-'. A path
#   segment may itself contain '-', so the slug is walked greedily against the filesystem: join segments
#   until a directory exists. Prints the directory, or fails.
_slug_to_dir() {
  local slug="${1#-}" cur="" piece i j n; local -a segs
  IFS='-' read -ra segs <<<"$slug"; n=${#segs[@]}; i=0
  while (( i < n )); do
    piece="${segs[i]}"; j=$((i+1))
    while [[ ! -d "$cur/$piece" ]] && (( j < n )); do piece="$piece-${segs[j]}"; j=$((j+1)); done
    [[ -d "$cur/$piece" ]] || return 1
    cur="$cur/$piece"; i=$j
  done
  [[ -n "$cur" ]] && echo "$cur"
}

# seat_prior_session <seat> <account> [<exclude-sid>] [<config-dir>] — "<sid>\t<source>\t<cwd or empty>"; 1 = none.
#   The config dir is resolved from the account label unless given (seat migrate knows the target dir and
#   labels it by basename, which is not always the pool's word for it).
seat_prior_session() {
  local seat="$1" acct="$2" excl="${3:-}" dir="${4:-}" sid t
  [[ -n "$dir" ]] || dir="$(ACCOUNT_CONFIG_DIR "$acct" 2>/dev/null || echo '')"
  sid="$(seat_sessions_get "$seat" "$acct" 2>/dev/null || true)"
  if [[ -n "$sid" && "$sid" != "$excl" ]]; then
    for t in "$dir"/projects/*/"$sid".jsonl; do
      [[ -f "$t" ]] && { printf '%s\tregistry\t%s\n' "$sid" "$(_slug_to_dir "$(basename "$(dirname "$t")")" 2>/dev/null || true)"; return 0; }
    done
    printf '%s\tregistry\t\n' "$sid"; return 0
  fi
  [[ -d "$dir/projects" ]] || return 1
  # ⛔ THE FINGERPRINT IS THE SEAT'S OWN TOOL CALL, not text: `"command":"...aimail poll(-persistent) <seat>"`
  #   as the harness records a Bash/Monitor invocation. Every seat's transcript QUOTES other seats' poller
  #   commands in mail bodies (the 09:5x live dry run picked code-review's and fable's sessions for the
  #   assistant by the loose text match: 5 quotes vs 1864 real calls in the true prior). A session that is
  #   REGISTERED to another seat (record or sessions file) is never a candidate either.
  local best="" best_m=0 f m
  local fp='[^\\]"command":"[^"]*aimail (poll|poll-persistent) '"$seat"'( |"|\\)'
  for f in "$dir"/projects/*/*.jsonl; do
    [[ -f "$f" ]] || continue
    sid="$(basename -- "$f" .jsonl)"; [[ "$sid" == "$excl" ]] && continue
    _ho_sid_registered_elsewhere "$seat" "$sid" && continue
    grep -q -m1 -E -- "$fp" "$f" 2>/dev/null || continue
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    (( m > best_m )) && { best_m=$m; best="$f"; }
  done
  [[ -n "$best" ]] || return 1
  printf '%s\ttranscript:%s\t%s\n' "$(basename "$best" .jsonl)" "$(date -d "@$best_m" '+%F %H:%M')" \
    "$(_slug_to_dir "$(basename "$(dirname "$best")")" 2>/dev/null || true)"
}

# _ho_sid_registered_elsewhere <seat> <sid> — 0 when another seat's record or sessions file names this sid
_ho_sid_registered_elsewhere() {
  local seat="$1" sid="$2" f
  for f in "$(SEAT_RECORD_DIR)"/* "$(SEAT_SESSIONS_DIR)"/*; do
    [[ -f "$f" && "$(basename -- "$f")" != "$seat" ]] || continue
    grep -q -F -- "$sid" "$f" 2>/dev/null && return 0
  done
  return 1
}
_ho_weekly_pct() { local w; w="$(_last_weekly "$1" 2>/dev/null || true)"; [[ -n "$w" ]] && cut -f2 <<<"$w"; }

# seat_record_append <seat> <key> <value> — add a row to the seat record without rewriting it
seat_record_append() { local f; f="$(SEAT_RECORD_FILE "$1")"; [[ -f "$f" ]] || return 1; printf '%s\t%s\n' "$2" "$3" >> "$f"; }

# seat_session_retired <seat> <sid> — 0 when the record lists this sid as retired (kept or not)
seat_session_retired() {
  local f; f="$(SEAT_RECORD_FILE "$1")"; [[ -f "$f" && -n "${2:-}" ]] || return 1
  awk -F'\t' -v s="$2" '$1=="retired_sessions" { v=$2; sub(/^[a-z]+:/, "", v); sub(/@.*$/, "", v); if (v==s) found=1 } END{exit !found}' "$f"
}

_ho_boot_prompt() { # <seat> <from> <cur> <target> <old-sid> <pin> <pct>
  local seat="$1" from="$2" cur="$3" target="$4" old="$5" pin="$6" pct="$7"
  cat <<EOP
Hi $seat, this is $from. BUDGET HANDOVER: the '$cur' account reached ${pct}% of its weekly cap, so the $seat seat moved to '$target' and resumed THIS, its own prior session here. The previous session ${old:0:8} on '$cur' stays alive OFF aimail for the owner's questions -- never stop it. Model pinned: $pin. Do, in order: (1) aimail session $seat -- fix what it flags; (2) aimail role show $seat -- the handover the previous session wrote is the live state; (3) arm the poller as a Monitor (aimail poll-persistent $seat); (4) if Remote Control is not on, turn it on under the name '$seat'; (5) tell the owner the new id and account (push notification + the owner-inbox line via the assistant channel); (6) continue the live work from the handover.
EOP
}

# seat_budget_move [--seat <seat>] [--act] [--target <acct>] [--sid <id>] [--from <seat>] [--force] [--handover-wait <s>]
#   The WEEKLY-CAP MOVE for one seat (the owner, 2026-09-23 09:10: "nobody pauses if there is budget in
#   another account"): resume the seat's own prior session on the account with the most weekly headroom,
#   model pinned. The supervisor keeps its old session alive (keep-old, implied by seat migrate); every
#   other seat's old session is stopped by seat migrate as usual. A short BLOCK park is not a move
#   trigger (R6(a)); only the WEEKLY reading decides here.
seat_budget_move() {
  local seat="${AIMAIL_SUPERVISOR:-assistant}" act=0 force=0 target="" psid="" from=""
  local wait_s="${AIMAIL_HANDOVER_WAIT_S:-300}" thr="${AIMAIL_SUPERVISOR_HANDOVER_PCT:-95}"
  while (( $# )); do
    case "$1" in
      --act) act=1; shift ;; --force) force=1; shift ;;
      --seat) seat="${2:-}"; shift 2 ;;
      --target) target="${2:-}"; shift 2 ;; --sid) psid="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;; --handover-wait) wait_s="${2:-}"; shift 2 ;;
      *) refused "budget-move: unknown argument '$1'" ;;
    esac
  done
  # The handover request is sent by the seat that runs the move when its session maps to a seat, else by
  # the vice supervisor (an unattended run). --from overrides both.
  if [[ -z "$from" ]]; then
    if declare -F whoami_seat_quiet >/dev/null 2>&1 && from="$(whoami_seat_quiet)" && [[ -n "$from" ]]; then :
    else from="${AIMAIL_VICE_SUPERVISOR:-main}"; fi
  fi
  seat_exists "$seat" || refused "budget-move ($seat): '$seat' is not a registered seat"
  local cur old; cur="$(seat_record_read "$seat" account 2>/dev/null || echo '')"; old="$(seat_record_read "$seat" session_id 2>/dev/null || echo '')"
  [[ -n "$cur" && -n "$old" ]] || refused "budget-move ($seat): no seat record for '$seat' (account/session unknown) -- nothing to hand over from"
  local pct; pct="$(_ho_weekly_pct "$cur")"
  local is_sup=0; [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]] && is_sup=1
  printf 'WEEKLY-CAP MOVE -- seat %s%s, session %s on %s, weekly %s%% (threshold %s%%)\n' "$seat" "$( (( is_sup )) && printf ' (the supervisor: keep-old handover)')" "${old:0:8}" "$cur" "${pct:-?}" "$thr"
  local due=0; [[ "$pct" =~ ^[0-9]+$ ]] && (( pct >= thr )) && due=1
  (( due )) && printf 'TRIGGER: DUE\n' || printf 'TRIGGER: not due (weekly %s%% < %s%%)\n' "${pct:-?}" "$thr"

  # target: the measured, unparked account with the most weekly headroom that holds a prior session
  local a wh best="" best_wh=-1 prior=""
  if [[ -n "$target" ]]; then
    prior="$( [[ -n "$psid" ]] && printf '%s\t--sid\t\n' "$psid" || seat_prior_session "$seat" "$target" "$old" )" \
      || refused "budget-move ($seat): no prior '$seat' session on '$target' (registry or transcripts)" "A fresh launch is the owner's decision: aimail seat migrate $seat $target --fresh --why \"...\" --owner-approved \"...\""
  else
    while IFS= read -r a; do
      [[ -n "$a" && "$a" != "$cur" ]] || continue
      _pl_has_headroom "$a" 2>/dev/null || { printf 'candidate %s: no headroom or parked -- skipped\n' "$a"; continue; }
      IFS=$'\t' read -r _ wh < <(_pl_headroom "$a")
      local p; p="$(seat_prior_session "$seat" "$a" "$old" 2>/dev/null || true)"
      [[ -n "$p" ]] || { printf 'candidate %s: weekly headroom %s, NO prior %s session -- skipped (never a fresh launch here)\n' "$a" "$wh" "$seat"; continue; }
      printf 'candidate %s: weekly headroom %s, prior session %s (%s)\n' "$a" "$wh" "${p%%$'\t'*}" "$(cut -f2 <<<"$p")"
      (( wh > best_wh )) && { best_wh=$wh; best="$a"; prior="$p"; }
    done < <(_pl_accounts 2>/dev/null || _watchdog_accounts 2>/dev/null)
    [[ -n "$best" ]] || refused "budget-move ($seat): no target account with weekly headroom AND a prior '$seat' session" "Name one with --target <acct> [--sid <id>], or decide a fresh launch: aimail seat migrate $seat <acct> --fresh --why ... --owner-approved ..."
    target="$best"
  fi
  local sid src cwd; IFS=$'\t' read -r sid src cwd <<<"$prior"
  local pin; pin="$(seat_model_pin "$seat")"
  [[ -n "$cwd" && -d "$cwd" ]] || cwd="$(seat_record_read "$seat" cwd 2>/dev/null || echo '')"
  local tdir; tdir="$(ACCOUNT_CONFIG_DIR "$target")"
  printf 'TARGET: %s (%s)\nPRIOR SESSION: %s (%s)\nCWD: %s\nMODEL PIN: %s\nOLD SESSION: %s on %s -- %s\n' \
    "$target" "$tdir" "$sid" "$src" "${cwd:-<unknown: pass --cwd via seat migrate>}" "$pin" "${old:0:8}" "$cur" \
    "$( (( is_sup )) && printf 'NOT stopped; leaves aimail (retired_sessions kept:)' || printf 'stopped by seat migrate (claude stop, verified), then the prior session resumes on the target')"
  local approve="the owner, 2026-09-23 09:00/09:04/09:10: at a weekly cap every seat moves to an account with headroom, resuming its prior session with its pinned model (weekly ${pct:-?}% >= ${thr}% on '$cur')"
  local pf; pf="$(mktemp "${AIMAIL_ROOT}/tmp/hoprompt.XXXXXX" 2>/dev/null || mktemp)"
  _ho_boot_prompt "$seat" "$from" "$cur" "$target" "$old" "$pin" "${pct:-?}" > "$pf"
  printf 'COMMAND:\n  aimail seat migrate %s %s --resume-sid %s --model %s%s%s --from %s --handover-wait %s --repin-saved-model --prompt-file <boot prompt> --owner-approved "%s"\n' \
    "$seat" "$target" "$sid" "$pin" "${cwd:+ --cwd $cwd}" "$( (( is_sup )) && printf ' --keep-old')" "$from" "$wait_s" "$approve"
  (( is_sup )) && printf '  (the relaunch carries --remote-control %s; a saved launch spec on the target is REPINNED to the model + named remote control, backup kept, then resumed flagless)\n' "$seat"
  printf 'THEN: seat record += retired_sessions %s:%s@<time>; mail %s + %s%s with the new id/account\n' "$( (( is_sup )) && printf kept || printf stopped)" "${old:0:8}" "$from" "${AIMAIL_HUMAN_ALERT_SEAT:-<no human alert seat>}" "${AIMAIL_OWNER_INBOX:+ + $AIMAIL_OWNER_INBOX}"
  if (( ! act )); then rm -f "$pf"; printf 'DRY RUN -- nothing executed (add --act).\n'; return 0; fi
  if (( ! due && ! force )); then rm -f "$pf"; refused "budget-move ($seat): not due (weekly ${pct:-?}% < ${thr}%) -- --force overrides"; fi
  local -a args=("$seat" "$target" --resume-sid "$sid" --model "$pin" --from "$from" --handover-wait "$wait_s" --repin-saved-model --prompt-file "$pf" --owner-approved "$approve")
  (( is_sup )) && args+=(--keep-old)
  [[ -n "$cwd" && -d "$cwd" ]] && args+=(--cwd "$cwd")
  seat_migrate "${args[@]}" || { rm -f "$pf"; refused "budget-move ($seat): seat migrate did not complete -- the old session is untouched, the record unchanged"; }
  rm -f "$pf"
  seat_record_append "$seat" retired_sessions "$( (( is_sup )) && printf kept || printf stopped):${old}@$(now_iso)"
  local new; new="$(seat_record_read "$seat" session_id 2>/dev/null || echo '?')"
  local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/hodone.XXXXXX" 2>/dev/null || mktemp)"
  { printf '# WEEKLY-CAP MOVE DONE: %s is now %s on %s\n\n' "$seat" "${new:0:8}" "$target"
    printf 'new session: %s (account %s, model %s, cwd %s)\nold session: %s on %s -- %s\n' "$new" "$target" "$pin" "${cwd:-?}" "$old" "$cur" \
      "$( (( is_sup )) && printf 'ALIVE, off aimail (retired_sessions kept:), never stop it; the owner may ask it what happened' || printf 'stopped (retired_sessions stopped:)')"
    printf 'trigger: weekly %s%% >= %s%% on %s\n' "${pct:-?}" "$thr" "$cur"
  } > "$body"
  local rcpt; for rcpt in "$from" "${AIMAIL_HUMAN_ALERT_SEAT:-}"; do
    [[ -n "$rcpt" ]] && seat_exists "$rcpt" || continue
    mail_send --to "$rcpt" --from "$rcpt" --subject "WEEKLY-CAP MOVE DONE: $seat -> ${new:0:8} on $target (old ${old:0:8} $( (( is_sup )) && printf 'kept alive off aimail' || printf stopped))" --body-file "$body" >/dev/null 2>&1 || true
  done
  [[ -n "${AIMAIL_OWNER_INBOX:-}" ]] && printf '%s  %s weekly-cap move: new session %s on %s (model %s); old %s on %s %s\n' "$(now_iso)" "$seat" "$new" "$target" "$pin" "${old:0:8}" "$cur" "$( (( is_sup )) && printf 'kept alive off aimail' || printf stopped)" >> "$AIMAIL_OWNER_INBOX" 2>/dev/null || true
  rm -f "$body"
  ok "weekly-cap move done: $seat -> ${new:0:8} on $target; old ${old:0:8} $( (( is_sup )) && printf 'kept alive off aimail' || printf stopped)"
}
# supervisor_handover [...] — the supervisor's keep-old budget handover (the owner's design 2026-09-23 09:00)
supervisor_handover() { seat_budget_move --seat "${AIMAIL_SUPERVISOR:-assistant}" "$@"; }

# supervisor_handover_due_announce — the WEEKLY-CAP trigger for the supervisor's account: when its weekly
#   reading crosses the threshold, ONE mail to the vice per episode with the dry-run plan for EVERY seat
#   on that account (the supervisor first, the vice second, then the rest -- the owner 2026-09-23 09:10:
#   nobody idles on a weekly cap while another account has budget). Runs from the supervisor watchdog
#   tick. Then it ACTS for the supervisor (the keep-old handover) in the same tick -- ON by default, the
#   owner's 09:35 rule: no dark switches, a change ships ON and fails loud; AIMAIL_HANDOVER_ACT=0 is the
#   kill switch. The other seats' moves are executed by the vice (or the new supervisor) by hand.
supervisor_handover_due_announce() {
  local sup="${AIMAIL_SUPERVISOR:-assistant}" thr="${AIMAIL_SUPERVISOR_HANDOVER_PCT:-95}"
  local cur; cur="$(seat_record_read "$sup" account 2>/dev/null || echo '')"; [[ -n "$cur" ]] || return 0
  local pct; pct="$(_ho_weekly_pct "$cur")"; [[ "$pct" =~ ^[0-9]+$ ]] || return 0
  local mark="$STATE_DIR/handover_announced_${cur}"
  if (( pct < thr )); then rm -f "$mark"; return 0; fi
  [[ -f "$mark" ]] && return 0
  : > "$mark"
  local vice="${AIMAIL_VICE_SUPERVISOR:-main}" body; body="$(mktemp "${AIMAIL_ROOT}/tmp/hodue.XXXXXX" 2>/dev/null || mktemp)"
  # every seat recorded on the capped account, supervisor first, vice second
  local -a seats=(); local s
  for s in $( { echo "$sup"; echo "$vice"; awk -F'\t' '$1=="account" && $2==a {print FILENAME}' a="$cur" "$(SEAT_RECORD_DIR)"/* 2>/dev/null | xargs -rn1 basename | sort; } | awk '!seen[$0]++'); do
    [[ "$(seat_record_read "$s" account 2>/dev/null || echo '')" == "$cur" ]] && seats+=("$s")
  done
  { printf '# WEEKLY CAP on %s: %s%% >= %s%% -- every seat here moves (%s)\n\n' "$cur" "$pct" "$thr" "${seats[*]}"
    for s in "${seats[@]}"; do
      printf '## %s\n\n' "$s"; seat_budget_move --seat "$s" 2>&1 | sed 's/^/    /'; printf '\n'
    done
    if [[ "${AIMAIL_HANDOVER_ACT:-1}" == "0" ]]; then printf 'AIMAIL_HANDOVER_ACT=0: the supervisor move is NOT executed by this tick; the vice runs: aimail fleet supervisor-handover --act\n'
    else printf 'The supervisor move is EXECUTED by this tick right after this mail (kill switch: AIMAIL_HANDOVER_ACT=0).\n'; fi
    printf 'Every other seat, in this order, by hand (the vice; main'"'"'s own move by the new supervisor or a human): aimail fleet budget-move <seat> --act\n'
  } > "$body"
  seat_exists "$vice" && mail_send --to "$vice" --from "$vice" --subject "WEEKLY CAP on $cur (${pct}%): every seat moves -- ${seats[*]} -- aimail fleet budget-move <seat> --act" --body-file "$body" >/dev/null 2>&1 || true
  rm -f "$body"
  info "watchdog/supervisor: weekly cap on $cur (${pct}% >= ${thr}%) -- moves announced to $vice for: ${seats[*]}"
  if [[ "${AIMAIL_HANDOVER_ACT:-1}" != "0" ]]; then supervisor_handover --act || warn "watchdog/supervisor: the supervisor handover did not complete -- see the refusal above; the vice runs it by hand"; fi
}
