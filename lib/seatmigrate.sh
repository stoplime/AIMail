# shellcheck shell=bash
# seatmigrate.sh — the persisted per-seat account record, session lookup from
# OUTSIDE a session, and `aimail seat migrate`: the one scripted way to move a
# seat's background session between accounts.
#
# ⛔⛔ THE INCIDENT THIS FILE CLOSES (2026-09-21). A seat was moved between two
#   accounts by hand: `kill <pid>` on its background session, then a relaunch
#   under the other account. The CLI's own background-job scheduler tracks each
#   `claude --bg` session against its ORIGINAL launch spec (account directory,
#   model, flags — see `<config-dir>/jobs/<short-id>/state.json`, key
#   `respawnFlags`). A killed process looks like a crash to that scheduler, so
#   it RESPAWNED the session from the original spec — wrong account, wrong
#   model — every time, minutes after each relaunch had been confirmed. For a
#   while the seat existed TWICE, under the same session id, on two accounts,
#   each reading the shared mailbox and writing the shared role handover.
#   `claude stop <id>` deregisters the job cleanly and does not respawn.
#
# ⭐ WHAT THIS FILE PROVIDES
#   1. seat record — `$STATE_DIR/seat_account/<seat>`: the last CONFIRMED
#      account, session id, model and config dir for a seat. Runtime state,
#      never tracked (state/ is gitignored). Written by `aimail seat confirm`
#      (a seat, at boot, from its own environment), and by `seat migrate` on a
#      verified success. It is what lets a FULLY DEAD seat (no live process
#      anywhere) be relaunched onto the right account instead of a guess.
#   2. seat_session_locate — where a seat's session really is, from outside:
#      `claude agents --json` across every account dir in the pool, keyed by
#      session id, cross-checked against the poller instance files and the
#      record. A pid read from INSIDE a session is not a killable handle (every
#      tool call runs in a fresh subshell under a shared worker process); the
#      scheduler's own listing is the only honest source.
#   3. seat migrate — locate → handover → `claude stop` (verified gone) →
#      orphan pollers killed → relaunch on the target → verify present → SETTLE
#      and re-verify (present on target, absent everywhere else) → record.
#      Every step checks its own result before the next runs; a step that
#      cannot verify REFUSES instead of continuing. `--dry-run` prints the
#      exact commands and runs nothing.
#
# TEST SEAMS: AIMAIL_CLAUDE_BIN (a stand-in `claude`), AIMAIL_ACCOUNT_DIR_<acct>
# (budget.sh's own idiom), AIMAIL_FLEET_ACCOUNTS. Nothing here needs a network.

SEAT_RECORD_DIR()  { echo "$STATE_DIR/seat_account"; }
SEAT_RECORD_FILE() { echo "$(SEAT_RECORD_DIR)/$1"; }

seat_record_read() {
  local f; f="$(SEAT_RECORD_FILE "$1")"; local key="$2"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v k="$key" '$1==k{print $2; found=1} END{exit !found}' "$f"
}

# seat_cwd_resolve <seat> <sid> [<config_dir>…] — the seat's working directory when no live listing
# carries one: the seat record first, then the saved launch spec (jobs/<short>/state.json, key
# `cwd`) on the dirs given and on every account of this instance. Prints "<cwd>\t<source>" with
# source = record | spec:<path>; returns 1 when nothing knows it. It NEVER answers with $PWD: the
# caller's shell directory is the operator's (or the cron's), not the seat's -- a resume from it
# hands the seat its conversation back in the WRONG directory (code-review gate, 2026-09-22, twice:
# first seat migrate, then the supervisor watchdog's boot path). One resolver, both callers.
seat_cwd_resolve() {
  local seat="$1" sid="$2"; shift 2; local short="${sid:0:8}" cwd
  cwd="$(seat_record_read "$seat" cwd 2>/dev/null || echo '')"
  [[ -n "$cwd" ]] && { printf '%s\trecord\n' "$cwd"; return 0; }
  local _d
  for _d in "$@" $(_instance_account_dirs 2>/dev/null); do
    [[ -n "$_d" && -f "$_d/jobs/$short/state.json" ]] || continue
    cwd="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("cwd") or "")' "$_d/jobs/$short/state.json" 2>/dev/null)"
    [[ -n "$cwd" ]] && { printf '%s\tspec:%s\n' "$cwd" "$_d/jobs/$short/state.json"; return 0; }
  done
  return 1
}

# seat_record_write <seat> <account> <config_dir> <sid> <model> <confirmed_by>
seat_record_write() {
  local seat="$1" account="$2" cfg="$3" sid="$4" model="$5" by="$6" path="${7:-}" why="${8:-}" cwd="${9:-}"
  mkdir -p "$(SEAT_RECORD_DIR)"
  { printf 'seat\t%s\n'         "$seat"
    printf 'account\t%s\n'      "$account"
    printf 'config_dir\t%s\n'   "$cfg"
    printf 'session_id\t%s\n'   "$sid"
    printf 'short_id\t%s\n'     "${sid:0:8}"
    printf 'model\t%s\n'        "$model"
    printf 'confirmed_at\t%s\n' "$(now_iso)"
    printf 'confirmed_epoch\t%s\n' "$(now_epoch)"
    printf 'confirmed_by\t%s\n' "$by"
    printf 'host\t%s\n'         "$(hostname 2>/dev/null || echo unknown)"
    [[ -n "$path" ]] && printf 'launch_path\t%s\n' "$path"
    # the seat's working directory (its own $PWD at confirm; the cwd a migrate relaunched it in):
    # what a fully-dead seat is resumed INTO -- never the operator's shell directory
    [[ -n "$cwd" ]] && printf 'cwd\t%s\n' "$cwd"
  } | atomic_write "$(SEAT_RECORD_FILE "$seat")"
  # the per-account registry follows every record write automatically (the owner: nobody records an id by hand)
  # keyed by the config dir's LABEL (`_account_label`), the one spelling every reader uses
  seat_sessions_set "$seat" "$(_account_label "$cfg")" "$sid" "$model" "$by" "${why:-record write ($by)}" "$path"
}

seat_record_show() {
  local seat="$1" f; f="$(SEAT_RECORD_FILE "$seat")"
  if [[ ! -f "$f" ]]; then
    info "no seat record for '$seat' — never confirmed (aimail seat confirm $seat --model <id>, from the seat's own session)"
    return 1
  fi
  cat "$f"
}

seat_records_list() {
  local d f seat acct sid model at
  d="$(SEAT_RECORD_DIR)"
  [[ -d "$d" ]] || { info "no seat records yet"; return 0; }
  printf '%-14s %-10s %-10s %-24s %s\n' SEAT ACCOUNT SESSION MODEL CONFIRMED
  for f in "$d"/*; do
    [[ -f "$f" ]] || continue
    seat="$(basename "$f")"
    acct="$(seat_record_read "$seat" account || echo '?')"
    sid="$(seat_record_read "$seat" short_id || echo '?')"
    model="$(seat_record_read "$seat" model || echo '?')"
    at="$(seat_record_read "$seat" confirmed_at || echo '?')"
    printf '%-14s %-10s %-10s %-24s %s\n' "$seat" "$acct" "$sid" "$model" "$at"
  done
}

# ─── per-seat, per-account SESSION REGISTRY (the owner's spec, 2026-09-22 15:43/15:45) ──────────
# ⛔ WHY: five seats were moved between accounts today and every one of them ended up on a FRESH
#   session because the tool's only knowledge of "the seat's session" was ONE record (the last
#   confirmed account). A seat that has run on an account before has a transcript there; the
#   tool must know that sid so `migrate` and a plain restart can RESUME it — nobody types an id.
#   Every boot (`seat confirm`), every verified migrate, and the two explicit verbs below update
#   it; the seat record above stays the "current" pointer, this is the per-account history.
# LAYOUT: $STATE_DIR/seat_sessions/<seat>  (TSV, one row per account:
#   account \t session_id \t model \t confirmed_at \t confirmed_by \t launch_path)
#   and $STATE_DIR/seat_sessions/<seat>.log — append-only: every change with who and why.
SEAT_SESSIONS_DIR()  { echo "$STATE_DIR/seat_sessions"; }
SEAT_SESSIONS_FILE() { echo "$(SEAT_SESSIONS_DIR)/$1"; }
SEAT_SESSIONS_LOG()  { echo "$(SEAT_SESSIONS_DIR)/$1.log"; }

# seat_sessions_get <seat> <account> [field]  — field: session_id (default) | model | confirmed_at | confirmed_by | launch_path
seat_sessions_get() {
  local f; f="$(SEAT_SESSIONS_FILE "$1")"; local acct="$2" field="${3:-session_id}"
  [[ -f "$f" ]] || return 1
  awk -F'\t' -v a="$acct" -v fld="$field" '
    $1==a { if (fld=="session_id") print $2; else if (fld=="model") print $3;
            else if (fld=="confirmed_at") print $4; else if (fld=="confirmed_by") print $5;
            else if (fld=="launch_path") print $6; found=1 }
    END { exit !found }' "$f"
}

_seat_sessions_log() { # <seat> <verb> <account> <sid> <model> <by> <why>
  mkdir -p "$(SEAT_SESSIONS_DIR)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(now_iso)" "$2" "$3" "$4" "$5" "$6" "$7" >> "$(SEAT_SESSIONS_LOG "$1")"
}

# seat_sessions_set <seat> <account> <sid> <model> <by> <why> [launch_path]
seat_sessions_set() {
  local seat="$1" acct="$2" sid="$3" model="$4" by="$5" why="$6" path="${7:-}"
  local f; f="$(SEAT_SESSIONS_FILE "$seat")"; mkdir -p "$(SEAT_SESSIONS_DIR)"
  { [[ -f "$f" ]] && awk -F'\t' -v a="$acct" '$1!=a' "$f"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$acct" "$sid" "$model" "$(now_iso)" "$by" "$path"
  } | sort | atomic_write "$f"
  _seat_sessions_log "$seat" set "$acct" "$sid" "$model" "$by" "$why"
}

# seat_sessions_clear <seat> <account> <by> <why>
seat_sessions_clear() {
  local seat="$1" acct="$2" by="$3" why="$4"
  local f; f="$(SEAT_SESSIONS_FILE "$seat")"
  local old; old="$(seat_sessions_get "$seat" "$acct" 2>/dev/null || echo '')"
  if [[ -f "$f" ]]; then awk -F'\t' -v a="$acct" '$1!=a' "$f" | atomic_write "$f"; fi
  _seat_sessions_log "$seat" clear "$acct" "${old:--}" - "$by" "$why"
}

seat_sessions_show() {
  local seat="${1:-}"
  local d; d="$(SEAT_SESSIONS_DIR)"
  [[ -d "$d" ]] || { info "no session registry yet"; return 0; }
  printf '%-14s %-10s %-10s %-24s %-8s %-26s %s\n' SEAT ACCOUNT SESSION MODEL PATH CONFIRMED BY
  local f
  for f in "$d"/*; do
    [[ -f "$f" && "$f" != *.log ]] || continue
    [[ -z "$seat" || "$(basename "$f")" == "$seat" ]] || continue
    awk -F'\t' -v s="$(basename "$f")" '{ printf "%-14s %-10s %-10s %-24s %-8s %-26s %s\n", s, $1, substr($2,1,8), $3, ($6==""?"-":$6), $4, $5 }' "$f"
  done
  if [[ -n "$seat" && -f "$(SEAT_SESSIONS_LOG "$seat")" ]]; then
    echo; info "history ($(SEAT_SESSIONS_LOG "$seat")):"; tail -n 12 "$(SEAT_SESSIONS_LOG "$seat")" | sed 's/^/  /'
  fi
}

# aimail seat set-session <seat> <account> <sid> [--model <id>] --why "<reason>" [--by <label>]
seat_set_session() {
  local seat="${1:-}" acct="${2:-}" sid="${3:-}"; shift 3 2>/dev/null || true
  local model="" why="" by="${USER:-human}"
  while (( $# )); do
    case "$1" in
      --model) model="${2:-}"; shift 2 ;;
      --why)   why="${2:-}"; shift 2 ;;
      --by)    by="${2:-}"; shift 2 ;;
      *) refused "seat set-session: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$seat" && -n "$acct" && -n "$sid" ]] || refused "usage: aimail seat set-session <seat> <account> <sid> [--model <id>] --why \"<reason>\" [--by <label>]"
  seat_exists "$seat" || refused "seat set-session: '$seat' is not a registered seat"
  [[ -n "$why" ]] || refused "seat set-session: --why is required — every change to the registry is logged with its reason"
  [[ "$sid" =~ ^[0-9a-fA-F-]{8,}$ ]] || refused "seat set-session: '$sid' does not look like a session id"
  [[ -z "$model" ]] && model="$(seat_sessions_get "$seat" "$acct" model 2>/dev/null || echo unknown)"
  seat_sessions_set "$seat" "$acct" "$sid" "${model:-unknown}" "$by" "$why" manual
  ok "seat sessions: $seat @ $acct → ${sid:0:8} (model ${model:-unknown}, by $by): $why"
}

# aimail seat reset-session <seat> <account> --why "<reason>" [--by <label>]
seat_reset_session() {
  local seat="${1:-}" acct="${2:-}"; shift 2 2>/dev/null || true
  local why="" by="${USER:-human}"
  while (( $# )); do
    case "$1" in
      --why) why="${2:-}"; shift 2 ;;
      --by)  by="${2:-}"; shift 2 ;;
      *) refused "seat reset-session: unknown argument '$1'" ;;
    esac
  done
  [[ -n "$seat" && -n "$acct" ]] || refused "usage: aimail seat reset-session <seat> <account> --why \"<reason>\" [--by <label>]"
  seat_exists "$seat" || refused "seat reset-session: '$seat' is not a registered seat"
  [[ -n "$why" ]] || refused "seat reset-session: --why is required — every change to the registry is logged with its reason"
  seat_sessions_clear "$seat" "$acct" "$by" "$why"
  ok "seat sessions: $seat @ $acct cleared (by $by): $why — the next launch on '$acct' records the new session"
}

# ─── transcripts: the thing `--resume` actually needs on the TARGET account ─────────────────────
# ⛔ ROOT CAUSE of every "source session <sid> not found" today (2026-09-22, four seats): the CLI
#   resolves `--resume <sid>` against the TARGET config dir's own
#   `projects/<cwd-slug>/<sid>.jsonl`. The transcript lives under the SOURCE account's config
#   dir; the failed attempt leaves a ~1 KB stub (titles, last prompt, no conversation) on the
#   target, so the next attempt fails the same way. Carrying the transcript (and its `<sid>/`
#   sidecar directory) across BEFORE the relaunch is what makes resume the default path.
_cwd_slug() { printf '%s' "$1" | sed 's#[/.]#-#g'; }
# a transcript with at least one real turn — a stub written by a failed attempt has none
_transcript_has_conversation() { [[ -f "$1" ]] && grep -q '"type":"\(user\|assistant\)"' "$1"; }
# _transcript_prepare <src_dir|-> <dst_dir> <cwd> <sid> <dry 0|1>
#   exit 0 = a real transcript is on the target (already, or copied now); 1 = none available.
_transcript_prepare() {
  local src_dir="$1" dst_dir="$2" cwd="$3" sid="$4" dry="${5:-0}"
  local slug; slug="$(_cwd_slug "$cwd")"
  local dst="$dst_dir/projects/$slug/$sid.jsonl"
  if _transcript_has_conversation "$dst"; then
    info "   transcript already on the target: $dst"; return 0
  fi
  local src="" cand d
  if [[ -n "$src_dir" && "$src_dir" != "-" ]]; then src="$src_dir/projects/$slug/$sid.jsonl"; fi
  if [[ -z "$src" ]] || ! _transcript_has_conversation "$src"; then
    # the slug is derived from cwd; a session may have been launched from another cwd, and with no
    # source dir known (--sid on a dead seat) it may sit under ANY account in the pool — search once
    local -a dirs=()
    if [[ -n "$src_dir" && "$src_dir" != "-" ]]; then dirs=("$src_dir"); else while IFS= read -r d; do [[ -n "$d" && "$(readlink -f "$d")" != "$(readlink -f "$dst_dir")" ]] && dirs+=("$d"); done < <(_instance_account_dirs); fi
    for d in "${dirs[@]:-}"; do
      [[ -n "$d" ]] || continue
      for cand in "$d"/projects/*/"$sid.jsonl"; do
        [[ -f "$cand" ]] && _transcript_has_conversation "$cand" && { src="$cand"; slug="$(basename "$(dirname "$cand")")"; dst="$dst_dir/projects/$slug/$sid.jsonl"; break 2; }
      done
    done
  fi
  _transcript_has_conversation "$src" || return 1
  _mig_cmd "mkdir -p $(dirname "$dst") && cp -p $src $dst"
  [[ -d "${src%.jsonl}" ]] && _mig_cmd "cp -a ${src%.jsonl} $(dirname "$dst")/"
  if (( ! dry )); then
    mkdir -p "$(dirname "$dst")"
    [[ -e "$dst" ]] && info "   replacing the target's stub ($(wc -c <"$dst") bytes, no conversation) with the real transcript"
    cp -p "$src" "$dst" || return 1
    [[ -d "${src%.jsonl}" ]] && cp -a "${src%.jsonl}" "$(dirname "$dst")/" 2>/dev/null
    ok "   transcript carried to the target: $dst ($(du -h "$dst" | cut -f1))"
  fi
  return 0
}

# ─── the CLI, behind one seam ────────────────────────────────────────────────
_claude() { "${AIMAIL_CLAUDE_BIN:-claude}" "$@"; }

_claude_available() {
  if [[ -n "${AIMAIL_CLAUDE_BIN:-}" ]]; then [[ -x "$AIMAIL_CLAUDE_BIN" ]]; return; fi
  [[ "${AIMAIL_NO_NETWORK:-}" == "1" ]] && return 1
  command -v claude >/dev/null 2>&1
}

# _account_label <config-dir> — the short account name budget.sh uses everywhere.
_account_label() { basename "$(readlink -f "$1" 2>/dev/null || echo "$1")" | sed 's/^\.//; s/^claude-//; s/^claude$/default/'; }

# _agents_rows <config-dir> [--all] — TSV rows: sid pid short state status cwd name
# Exit 1 when the CLI did not answer (UNKNOWN, never "empty").
_agents_rows() {
  local dir="$1"; shift
  _claude_available || return 1
  local json
  # `timeout` execs a BINARY, not a shell function — resolve the seam here, not via _claude.
  json="$(CLAUDE_CONFIG_DIR="$dir" timeout "${AIMAIL_AGENTS_TIMEOUT_SEC:-30}" "${AIMAIL_CLAUDE_BIN:-claude}" agents --json "$@" 2>/dev/null)" || return 1
  [[ -n "$json" ]] || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for d in data:
    if not isinstance(d, dict): continue
    sid = d.get("sessionId") or ""
    if not sid: continue
    print("\t".join(str(d.get(k, "") if d.get(k) is not None else "") for k in
          ("sessionId", "pid", "id", "state", "status", "cwd", "name")))
'
}

# seat_model_detect <config-dir> <sid> — the model a session runs, read from OUTSIDE:
#   (a) the scheduler's own launch spec: jobs/<short>/state.json → respawnFlags[--model]
#   (b) the transcript's last "model" field: projects/*/<sid>.jsonl
# Prints the first found; exit 1 when neither exists.
seat_model_detect() {
  local dir="$1" sid="$2" short="${2:0:8}" m=""
  local spec="$dir/jobs/$short/state.json"
  if [[ -f "$spec" ]]; then
    m="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
f = d.get("respawnFlags") or []
for i, x in enumerate(f):
    if x == "--model" and i + 1 < len(f):
        print(f[i + 1]); sys.exit(0)
sys.exit(1)
' "$spec" 2>/dev/null)" && [[ -n "$m" ]] && { echo "$m"; return 0; }
  fi
  local t
  for t in "$dir"/projects/*/"$sid".jsonl; do
    [[ -f "$t" ]] || continue
    m="$(grep -o '"model":"[^"]*"' "$t" 2>/dev/null | tail -1 | sed 's/.*"model":"//; s/"$//')"
    [[ -n "$m" ]] && { echo "$m"; return 0; }
  done
  return 1
}

# seat_session_locate <seat> — key\tvalue lines describing where the seat's session
# is RIGHT NOW. Keys: sid, account, config_dir, pid, short_id, state, cwd, liveness
# (live|dead|unknown), source (agents|record|heuristic), plus `twin` lines when the
# same seat is live under more than one session/account.
# Exit: 0 located (live or dead-with-record), 1 nothing to go on, 2 UNKNOWN (an account
# did not answer), 3 twins.
seat_session_locate() {
  local seat="$1"
  local -a cand_sids=() cand_accts=()
  local f sid acct
  # candidates: instance files (this seat's own pollers, any session)
  local idir; idir="$(INSTANCE_DIR "$seat")"
  if [[ -d "$idir" ]]; then
    for f in "$idir"/*; do
      [[ -f "$f" ]] || continue
      case "$(basename "$f")" in .inst.*|solo) continue ;; esac
      sid="$(basename "$f")"; acct="$(instance_read "$f" account || echo unknown)"
      cand_sids+=("$sid"); cand_accts+=("$acct")
    done
  fi
  # candidates: the persisted record
  local rec_sid rec_acct rec_dir
  rec_sid="$(seat_record_read "$seat" session_id 2>/dev/null || echo '')"
  rec_acct="$(seat_record_read "$seat" account 2>/dev/null || echo '')"
  rec_dir="$(seat_record_read "$seat" config_dir 2>/dev/null || echo '')"
  [[ -n "$rec_sid" ]] && { cand_sids+=("$rec_sid"); cand_accts+=("$rec_acct"); }

  # the live listing, every account dir in the pool
  local -a live_lines=()
  local dir rows n_dirs=0 n_ok=0 unk_labels=""
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    n_dirs=$((n_dirs+1))
    # ⛔ --all (2026-09-22 18:3x): plain `agents --json` HIDES idle/blocked sessions, so three
    #   limit-blocked leftovers on r2 (code-review, foundation, framing) were invisible to this twin
    #   check and a migrate stopped the wrong side. Rows in a terminal state are not live (stopped, failed, or `done`
    #   with nothing in flight -- see _job_in_flight).
    if [[ -d "$dir" ]] && rows="$(_agents_rows "$dir" --all)"; then
      n_ok=$((n_ok+1))
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # `done` is a session IDLE BETWEEN TURNS, not a dead one: while a Monitor (the seat's poller) is in
        # flight, the next mail wakes it. Only stopped/failed, or `done` with nothing in flight, are dead.
        case "$(cut -f4 <<<"$line")" in
          stopped|failed) continue ;;
          "done") _job_in_flight "$dir" "$(cut -f1 <<<"$line")" || continue ;;
        esac
        live_lines+=("$dir"$'\t'"$line")
      done <<<"$rows"
    else
      unk_labels="${unk_labels:+$unk_labels }$(_account_label "$dir")"
    fi
  done < <(_instance_account_dirs)
  local unknown=0; (( n_dirs > 0 && n_ok == n_dirs )) || unknown=1
  # An account that did not answer is printed on EVERY outcome below: a live hit on one
  # account says nothing about a twin on the one that stayed silent. seat migrate refuses
  # to act while this line is non-empty; seat locate shows it as information.
  [[ -n "$unk_labels" ]] && printf 'unknown_accounts\t%s\n' "$unk_labels"

  # which candidates are live, and where
  local -a hits=()
  local l lsid i seen
  for l in "${live_lines[@]:-}"; do
    [[ -n "$l" ]] || continue
    lsid="$(cut -f2 <<<"$l")"
    seen=0
    for i in "${!cand_sids[@]}"; do [[ "${cand_sids[$i]}" == "$lsid" ]] && seen=1; done
    (( seen )) && hits+=("$l")
  done
  # de-duplicate hits by (dir, sid)
  local -a uniq=(); local h key
  for h in "${hits[@]:-}"; do
    [[ -n "$h" ]] || continue
    key="$(cut -f1,2 <<<"$h")"; seen=0
    for l in "${uniq[@]:-}"; do [[ -n "$l" && "$(cut -f1,2 <<<"$l")" == "$key" ]] && seen=1; done
    (( seen )) || uniq+=("$h")
  done

  if (( ${#uniq[@]} > 1 )); then
    printf 'liveness\ttwin\n'
    for h in "${uniq[@]}"; do
      # awk fields, never `IFS=$'\t' read`: an idle (`done`) row has an EMPTY pid and status, and consecutive tabs collapse (lib/core.sh)
      dir="$(_tsv_nth "$h" 1)"; lsid="$(_tsv_nth "$h" 2)"; pid="$(_tsv_nth "$h" 3)"; short="$(_tsv_nth "$h" 4)"; state="$(_tsv_nth "$h" 5)"
      printf 'twin\t%s\t%s\t%s\t%s\t%s\n' "$(_account_label "$dir")" "$lsid" "$pid" "$short" "$state"
    done
    return 3
  fi
  if (( ${#uniq[@]} == 1 )); then
    h="${uniq[0]}"   # (fields by awk, see the twin branch above: an idle row's empty pid / status must not shift cwd and name)
    dir="$(_tsv_nth "$h" 1)"; lsid="$(_tsv_nth "$h" 2)"; pid="$(_tsv_nth "$h" 3)"; short="$(_tsv_nth "$h" 4)"; state="$(_tsv_nth "$h" 5)"
    cwd="$(_tsv_nth "$h" 7)"; name="$(_tsv_nth "$h" 8)"
    printf 'sid\t%s\naccount\t%s\nconfig_dir\t%s\npid\t%s\nshort_id\t%s\nstate\t%s\ncwd\t%s\nname\t%s\nliveness\tlive\nsource\tagents\n' \
      "$lsid" "$(_account_label "$dir")" "$dir" "$pid" "$short" "$state" "$cwd" "$name"
    return 0
  fi
  if (( unknown )); then
    printf 'liveness\tunknown\n'
    return 2
  fi
  if [[ -n "$rec_sid" ]]; then
    printf 'sid\t%s\naccount\t%s\nconfig_dir\t%s\npid\t\nshort_id\t%s\nstate\tabsent\ncwd\t\nname\t\nliveness\tdead\nsource\trecord\n' \
      "$rec_sid" "$rec_acct" "$rec_dir" "${rec_sid:0:8}"
    return 0
  fi
  printf 'liveness\tnone\n'
  return 1
}

# seat_confirm <seat> [--model <id>] [--by <label>] — run FROM the seat's own session.
# Writes the record from the session's own environment: CLAUDE_CODE_SESSION_ID and the
# resolved CLAUDE_CONFIG_DIR are facts here; the model is taken from --model (the seat
# quoting its own system prompt) or detected from the transcript/launch spec, never
# defaulted.
seat_confirm() {
  local seat="${1:?usage: aimail seat confirm <seat> [--model <id>]}"; shift
  local model="" by="boot"
  while (( $# )); do
    case "$1" in
      --model) model="${2:-}"; shift 2 ;;
      --by)    by="${2:-}"; shift 2 ;;
      *) refused "seat confirm: unknown argument '$1'" "usage: aimail seat confirm <seat> [--model <id>] [--by <label>]" ;;
    esac
  done
  seat_exists "$seat" || refused "seat confirm: '$seat' is not a registered seat"
  local sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
  [[ -n "$sid" && "$sid" != "solo" ]] || refused "seat confirm: CLAUDE_CODE_SESSION_ID is not set in this shell" \
    "Run this from inside the seat's own Claude session (every tool call carries the id), not from a plain terminal."
  local cfg; cfg="$(readlink -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" 2>/dev/null || echo '')"
  [[ -n "$cfg" ]] || refused "seat confirm: CLAUDE_CONFIG_DIR does not resolve"
  local acct; acct="$(_account_label "$cfg")"
  if [[ -z "$model" ]]; then
    model="$(seat_model_detect "$cfg" "$sid" 2>/dev/null || echo '')"
    if [[ -z "$model" ]]; then
      model="unknown"
      warn "seat confirm: model could not be read from the launch spec or transcript — recorded as 'unknown'. Pass --model <id> (quote the session's own system prompt) to record it."
    fi
  fi
  seat_record_write "$seat" "$acct" "$cfg" "$sid" "$model" "$by" "" "" "$PWD"
  ok "seat record: $seat → account=$acct session=${sid:0:8} model=$model ($by) cwd=$PWD"
  info "  file: $(SEAT_RECORD_FILE "$seat")"
}

# ─── seat migrate ────────────────────────────────────────────────────────────
_mig_step() { printf '\n── %s ──\n' "$*"; }
_mig_cmd()  { printf '   $ %s\n' "$*"; }

# _sid_listed <config-dir> <sid> [--all] — 0 if the listing names the sid, 1 if not,
# 2 if the listing did not answer.
_sid_listed() {
  # 0 = listed in a LIVE state; 1 = not listed, or listed only as failed/stopped (2026-09-22: a
  # `--resume` that hit "source session not found" leaves a `failed` row that used to count as
  # "present", then dropped out during the settle window and read as DISAPPEARED); 2 = unknown.
  local dir="$1" sid="$2"; shift 2
  # `done` is a session idle between turns: it is LISTED (live) while the scheduler's job file shows something still
  # in flight in it (a Monitor wakes it on the next mail); with nothing in flight it is dead like stopped/failed.
  local rows; rows="$(_agents_rows "$dir" --all "$@")" || return 2
  local st
  while IFS= read -r st; do
    case "$st" in
      failed|stopped) continue ;;
      "done") _job_in_flight "$dir" "$sid" || continue ;;
    esac
    return 0
  done < <(awk -F'\t' -v s="$sid" '$1==s {print $4}' <<<"$rows")
  return 1
}
# _tsv_nth <line> <n> — field N of a tab-separated line, empties kept (never `IFS=$'\t' read`, see lib/core.sh).
_tsv_nth() { awk -F'\t' -v n="$2" '{print $n}' <<<"$1"; }
# _job_in_flight <dir> <sid> — 0 when jobs/<short>/state.json says the session still has work in flight (inFlight.tasks
# or .queued above 0: a Monitor, a background task); 1 when nothing is, or the file is missing or unreadable.
_job_in_flight() {
  local spec="$1/jobs/${2:0:8}/state.json"
  [[ -f "$spec" ]] || return 1
  python3 -c '
import json, sys
try:
    f = json.load(open(sys.argv[1])).get("inFlight") or {}
    sys.exit(0 if (int(f.get("tasks") or 0) + int(f.get("queued") or 0)) > 0 else 1)
except Exception:
    sys.exit(1)
' "$spec" 2>/dev/null
}
# _job_state <dir> <sid> — "<state>\t<detail>" from the scheduler's own jobs/<short>/state.json, or nothing
_job_state() {
  local spec="$1/jobs/${2:0:8}/state.json"
  [[ -f "$spec" ]] || return 1
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(str(d.get("state") or ""), str(d.get("detail") or ""), sep="\t")
' "$spec" 2>/dev/null
}
# _new_sids_on <dir> <before-listing> — sids listed now that were not in <before-listing>
_new_sids_on() {
  local dir="$1" before="$2" rows
  rows="$(_agents_rows "$dir")" || return 2
  comm -13 <(cut -f1 <<<"$before" | sort -u) <(cut -f1 <<<"$rows" | sort -u)
}

# _canonicalize_model_id <input> — resolve a short alias (sonnet, opus, fable, haiku) to its
# full model id; an already-full id is echoed back unchanged. This is the ONE mapping table for
# aliases (no other source for this existed anywhere in the repo before this) so a seat can't end
# up carrying two spellings of the same model across its record and its launch flags (2026-09-24:
# a migrate was refused on 'sonnet' vs 'claude-sonnet-5' not matching). Exit 1, nothing printed,
# for anything that is neither a known alias nor a known full id — refused by the caller, never
# guessed or passed through unchanged.
_canonicalize_model_id() {
  # ⚠ HARDCODED, goes stale at every model release -- update this table (and only this table)
  #   when Anthropic ships a new model tier or renames a full id.
  local in="$1"
  case "$in" in
    sonnet)  echo "claude-sonnet-5-5" ;;
    opus)    echo "claude-opus-5-5" ;;
    fable)   echo "claude-fable-5-1" ;;
    haiku)   echo "claude-haiku-4-5-20251001" ;;
    claude-sonnet-5-5|claude-sonnet-5|claude-opus-5-5|claude-fable-5-1|claude-haiku-4-5-20251001) echo "$in" ;;
    *) return 1 ;;
  esac
}

_seat_launch_flags() {
  # The flags a FRESH `claude --bg` launch always carries. Shared by seat_migrate's own
  # fresh-launch path (below) and seat_launch (aimail seat launch) -- one flag-builder, no
  # second copy, per the standing ask (assistant, 20260924T174044). Prints one flag per line;
  # callers do `mapfile -t flags < <(_seat_launch_flags "$seat" "$model")`.
  local seat="$1" model="$2"
  printf '%s\n' --model "$model" --allow-dangerously-skip-permissions --permission-mode bypassPermissions
  [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]] && printf '%s\n' --remote-control "$seat"
}

# _account_autocompact_window <account> — prints the account's configured autoCompactWindow
# value (settings.json), exit 0; prints nothing and exits 1 if the file is missing, unreadable,
# or the key is absent. The single-account primitive behind `aimail context --settings`'s
# per-account report table (lib/sessions.sh:context_settings_check) -- factored out so a
# caller that only needs to know about ONE account (seat_launch, below) doesn't have to
# enumerate every account or re-parse the JSON itself.
_account_autocompact_window() {
  local acct="$1" dir settings val
  dir="$(ACCOUNT_CONFIG_DIR "$acct")"; settings="$dir/settings.json"
  [[ -f "$settings" ]] || return 1
  val="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    sys.exit(1)
v = d.get("autoCompactWindow")
if v is None: sys.exit(1)
print(v)
' "$settings" 2>/dev/null)" || return 1
  [[ -n "$val" ]] || return 1
  printf '%s\n' "$val"
}

_launch_default_prompt() {
  local seat="$1" account="$2"
  cat <<EOF
Hi $seat, you have just been launched fresh on the '$account' account. Before anything else: 1) run \`aimail session $seat\` and fix what it flags; 2) run \`aimail role show $seat\` and resume from it if one exists; 3) register this session with both stop hooks (stop_guard.sh and any project-local poller_guard.sh); 4) arm your poller as its own standalone background call and verify ARMED with \`aimail fleet $seat\`; 5) run \`aimail seat confirm $seat --model <the model id in your own system prompt>\`.
EOF
}

# seat_launch <seat> <account> [--model <id>] [--cwd <dir>] [--prompt-file <p>] [--dry-run] —
# one command for a FRESH launch (no existing session to resume; use `seat migrate` for that).
# Refuses if `seat` is live ANYWHERE first (idle counts as live) -- a fresh launch is never the
# right move while an existing session for this seat is still around; see 2026-09-24's twin
# incident, where a migrate resumed a stale prior session while the seat's own was idle, not
# dead, producing two live sessions. Defaults for --model/--cwd come from the seat's last
# CONFIRMED record; refuses rather than guessing when neither the flag nor the record has one.
# --model (flag or record) is resolved through _canonicalize_model_id -- an alias or a full id,
# never an unrecognized spelling passed through unchanged. Refuses (or warns,
# AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT=0 to downgrade) if the target account's settings.json has no
# autoCompactWindow -- autocompact is a per-account setting, so the check belongs at launch time,
# not as a flag a caller could omit. --dry-run prints the resolved command (model, cwd, account,
# autocompact, flags, prompt head) and returns 0 WITHOUT launching -- the dispatcher's v1 advisory
# mode calls this to show what it would do; every refusal check above still runs under --dry-run,
# since "what would happen" includes a refusal. Records the new session id in the seat record on
# a real launch, same as migrate.
seat_launch() {
  local seat="${1:-}" account="${2:-}"
  [[ -n "$seat" && -n "$account" ]] || refused "usage: aimail seat launch <seat> <account> [--model <id>] [--cwd <dir>] [--prompt-file <p>] [--dry-run]"
  shift 2
  local model="" cwd_override="" prompt_file="" dry_run=0
  local poll_s="${AIMAIL_LAUNCH_POLL_S:-3}" launch_timeout="${AIMAIL_LAUNCH_TIMEOUT:-120}"
  local tick="$poll_s"; [[ "$tick" =~ ^[0-9]+$ ]] && (( tick >= 1 )) || tick=1
  while (( $# )); do
    case "$1" in
      --model) model="${2:-}"; shift 2 ;;
      --cwd) cwd_override="${2:-}"; shift 2 ;;
      --prompt-file) prompt_file="${2:-}"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      *) refused "seat launch: unknown argument '$1'" ;;
    esac
  done

  # ── twin/liveness guard: a FRESH launch is refused while '$seat' is live anywhere ──────
  local _loc _lrc=0
  _loc="$(seat_session_locate "$seat")" || _lrc=$?
  local _liveness; _liveness="$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$_loc")"
  local _unk; _unk="$(awk -F'\t' '$1=="unknown_accounts"{print $2}' <<<"$_loc")"
  [[ -z "$_unk" ]] || refused "seat launch: account(s) did not answer claude agents --json: $_unk — nothing launched" \
    "A fresh launch needs every account in the pool to answer: it must prove '$seat' isn't live anywhere else first."
  case "$_lrc" in
    3) refused "seat launch: '$seat' is live under MORE THAN ONE session/account already (twins)" \
         "$(printf '%s\n' "$_loc" | awk -F'\t' '$1=="twin"{printf "TWIN: account=%s session=%s short=%s state=%s\n",$2,$3,$5,$6}')" \
         "This wrapper never picks a side; resolve the twin first, then re-run." ;;
    2) refused "seat launch: the live-session listing is UNKNOWN (an account dir did not answer) — nothing launched" ;;
  esac
  if [[ "$_liveness" == "live" ]]; then
    local _live_acct _live_sid; _live_acct="$(awk -F'\t' '$1=="account"{print $2}' <<<"$_loc")"
    _live_sid="$(awk -F'\t' '$1=="sid"{print $2}' <<<"$_loc")"
    refused "seat launch: '$seat' is already LIVE on '$_live_acct' (session ${_live_sid:0:8}) — a FRESH launch is refused while any session for this seat is live anywhere" \
      "Idle counts as live -- see 2026-09-24's twin incident (an idle-but-live source was treated as dead)." \
      "Use 'aimail seat migrate $seat $account' to move the existing session instead, or stop it first: CLAUDE_CONFIG_DIR=<dir> claude stop <short-id>."
  fi

  if [[ -z "$model" ]]; then
    model="$(seat_record_read "$seat" model 2>/dev/null || echo '')"
    [[ -n "$model" && "$model" != "unknown" ]] || refused "seat launch: no --model given, and '$seat' has no model on record" \
      "Pass --model <id> explicitly, or run 'aimail seat confirm $seat --model <id>' from that seat's own live session first." \
      "Never guessed: a wrong model silently launches the wrong tier."
  fi
  local _canon_model
  if ! _canon_model="$(_canonicalize_model_id "$model")"; then
    refused "seat launch: model '$model' is not a known alias or a known full id" \
      "Known aliases: sonnet, opus, fable, haiku." \
      "Known full ids: claude-sonnet-5-5, claude-sonnet-5, claude-opus-5-5, claude-fable-5-1, claude-haiku-4-5-20251001." \
      "Never guessed: an unrecognized spelling must not silently launch, or let a seat carry two spellings of the same model."
  fi
  model="$_canon_model"
  local cwd="$cwd_override"
  if [[ -z "$cwd" ]]; then
    cwd="$(seat_record_read "$seat" cwd 2>/dev/null || echo '')"
    [[ -n "$cwd" ]] || refused "seat launch: no --cwd given, and '$seat' has no cwd on record" \
      "Pass --cwd <dir> explicitly, or run 'aimail seat confirm $seat' from that seat's intended working directory first."
  fi
  [[ -d "$cwd" ]] || refused "seat launch: cwd '$cwd' does not exist"

  local target_dir; target_dir="$(ACCOUNT_CONFIG_DIR "$account")"
  [[ -d "$target_dir" ]] || refused "seat launch: account '$account' has no config dir ($target_dir)" \
    "Check the spelling, or AIMAIL_ACCOUNT_DIR_${account} if this is a test/override account."

  local acw
  if ! acw="$(_account_autocompact_window "$account")"; then
    if [[ "${AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT:-1}" == "0" ]]; then
      warn "   '$account' has no autoCompactWindow set in $target_dir/settings.json — launching anyway (AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT=0)"
    else
      refused "seat launch: '$account' has no autoCompactWindow set in $target_dir/settings.json" \
        "Autocompact is per-account config, checked here rather than left to a launch flag a caller could forget." \
        "Set it in that account's own settings.json, or override with AIMAIL_LAUNCH_REQUIRE_AUTOCOMPACT=0 (a deliberate, nameable exception, never a default)."
    fi
  else
    info "   '$account' autoCompactWindow=$acw"
  fi

  local -a flags; mapfile -t flags < <(_seat_launch_flags "$seat" "$model")

  local prompt
  if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || refused "seat launch: --prompt-file $prompt_file does not exist"
    prompt="$(cat "$prompt_file")"
  else
    prompt="$(_launch_default_prompt "$seat" "$account")"
  fi

  if (( dry_run )); then
    ok "seat launch --dry-run: $seat → account=$account model=$model cwd=$cwd autocompact=${acw:-<unset>}"
    printf '   flags: %s\n' "${flags[*]}"
    printf '   prompt (head): %s\n' "$(printf '%s' "$prompt" | head -1)"
    printf '   nothing launched (--dry-run).\n'
    return 0
  fi

  ensure_dirs
  local before_rows launch_out
  before_rows="$(_agents_rows "$target_dir" 2>/dev/null || true)"
  launch_out="$(cd "$cwd" && CLAUDE_CONFIG_DIR="$target_dir" _claude --bg "${flags[@]}" "$prompt" 2>&1)" \
    || refused "seat launch: launch command failed:" "$launch_out"
  info "   launched: ${launch_out:-<no output>}"

  local waited=0 new_sids=""
  while (( waited <= launch_timeout )); do
    new_sids="$(_new_sids_on "$target_dir" "$before_rows" 2>/dev/null || true)"
    [[ -n "$new_sids" ]] && break
    sleep "$poll_s"; waited=$((waited+tick))
  done
  [[ -n "$new_sids" ]] || refused "seat launch: no NEW session appeared on '$account' within ${launch_timeout}s" \
    "Check: CLAUDE_CONFIG_DIR=$target_dir claude agents --json"
  (( $(wc -l <<<"$new_sids") == 1 )) || refused "seat launch: more than one new session appeared on '$account' during the launch — cannot tell which is $seat's:" "$new_sids"
  local sid="$new_sids" short="${new_sids:0:8}"

  local waited2=0 present=0 js
  while (( waited2 <= launch_timeout )); do
    js="$(_job_state "$target_dir" "$sid" 2>/dev/null || true)"
    if [[ "${js%%$'\t'*}" == "failed" ]]; then
      refused "seat launch: the launch of $short on '$account' FAILED in the scheduler: ${js#*$'\t'}" "(jobs/$short/state.json)"
    fi
    _sid_listed "$target_dir" "$sid"; local r=$?
    if (( r == 0 )); then present=1; break; fi
    sleep "$poll_s"; waited2=$((waited2+tick))
  done
  (( present )) || refused "seat launch: $short is not listed LIVE on '$account' within ${launch_timeout}s" \
    "Check: CLAUDE_CONFIG_DIR=$target_dir claude agents --json --all | grep $short"

  seat_record_write "$seat" "$account" "$target_dir" "$sid" "$model" "launch" "launch" "fresh launch on $account" "$cwd"
  ok "seat launch: $seat → account=$account session=$short model=$model cwd=$cwd"
}

_mig_default_from() {
  # The handover-request mail's own "from" needs the ACTUAL invoking seat, not
  # a hardcoded name -- migrate is run by whichever seat orchestrates a move
  # (assistant, main, librarian, ...), and a wrong "from" misattributes the
  # request. Reuse role.sh's own session->seat lookup (whoami_seat_quiet,
  # sourced softly by the caller) rather than inventing a second mapping; fall
  # back to "assistant" only when that lookup can't determine a seat at all
  # (no session id, unregistered session, role.sh failed to source).
  local seat
  if declare -F whoami_seat_quiet >/dev/null 2>&1 && seat="$(whoami_seat_quiet)" && [[ -n "$seat" ]]; then
    echo "$seat"
  else
    echo "assistant"
  fi
}

# _mig_handover_is_fresh <role-file> — 0 when the file was written within AIMAIL_MIGRATE_HANDOVER_FRESH_S
#   (default 600 s). A seat that runs the move on ITSELF is blocked inside this command while it waits,
#   so it can never write the handover the wait asks for; it writes first, and that write counts.
_mig_handover_is_fresh() {
  local f="$1" window="${AIMAIL_MIGRATE_HANDOVER_FRESH_S:-600}" m now
  [[ "$window" =~ ^[0-9]+$ ]] && (( window > 0 )) && [[ -f "$f" ]] || return 1
  m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"; now="$(date +%s)"
  (( now - m <= window ))
}

_mig_default_prompt() {
  local seat="$1" from="$2" target="$3" prev="$4"
  cat <<EOF
Hi $seat, this is $from. Your session was moved to the '$target' account by \`aimail seat migrate\` (previous account: $prev). Nothing about your task changes; only the account underneath you did. Before anything else: 1) run \`aimail session $seat\` and fix what it flags; 2) run \`aimail role show $seat\` and resume from it; 3) register this session with both stop hooks (stop_guard.sh and any project-local poller_guard.sh); 4) arm your poller as its own standalone background call and verify ARMED with \`aimail fleet $seat\`; 5) run \`aimail seat confirm $seat --model <the model id in your own system prompt>\` and mail $from the account and model it printed. Then continue your handover's live work.
EOF
}

seat_migrate() {
  local seat="${1:-}" target="${2:-}"
  [[ -n "$seat" && -n "$target" ]] || refused "usage: aimail seat migrate <seat> <target-account> [--model <id>] [--from <seat>] [--sid <id>] [--cwd <dir>] [--prompt-file <f>] [--handover-wait <s>] [--settle <s>] [--dry-run] [--force-no-handover] [--fresh --why <reason>] [--owner-approved <reason>]"
  shift 2
  local model="" from="${AIMAIL_MIGRATE_FROM:-$(_mig_default_from)}" sid_override="" cwd_override="" prompt_file=""
  local handover_wait="${AIMAIL_MIGRATE_HANDOVER_WAIT:-300}" settle="${AIMAIL_MIGRATE_SETTLE:-90}"
  local stop_timeout="${AIMAIL_MIGRATE_STOP_TIMEOUT:-60}" launch_timeout="${AIMAIL_MIGRATE_LAUNCH_TIMEOUT:-120}"
  local poll_s="${AIMAIL_MIGRATE_POLL_S:-3}" dry=0 force_no_handover=0 fresh=0 why="" owner_approved="" keep_old=0 resume_sid_override="" repin_saved=0
  local tick="$poll_s"; [[ "$tick" =~ ^[0-9]+$ ]] && (( tick >= 1 )) || tick=1   # the counter always advances, even at --poll 0
  while (( $# )); do
    case "$1" in
      --model) model="${2:-}"; shift 2 ;;
      --from) from="${2:-}"; shift 2 ;;
      --sid) sid_override="${2:-}"; shift 2 ;;
      --cwd) cwd_override="${2:-}"; shift 2 ;;
      --prompt-file) prompt_file="${2:-}"; shift 2 ;;
      --handover-wait) handover_wait="${2:-}"; shift 2 ;;
      --settle) settle="${2:-}"; shift 2 ;;
      --stop-timeout) stop_timeout="${2:-}"; shift 2 ;;
      --launch-timeout) launch_timeout="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force-no-handover) force_no_handover=1; shift ;;
      --fresh) fresh=1; shift ;;
      --why) why="${2:-}"; shift 2 ;;
      --owner-approved) owner_approved="${2:-}"; shift 2 ;;
      --keep-old) keep_old=1; shift ;;
      --resume-sid) resume_sid_override="${2:-}"; shift 2 ;;
      --repin-saved-model) repin_saved=1; shift ;;
      *) refused "seat migrate: unknown argument '$1'" ;;
    esac
  done
  seat_exists "$seat" || refused "seat migrate: '$seat' is not a registered seat"
  # ⛔ THE SUPERVISOR IS NEVER STOPPED (the owner, 2026-09-23 08:50): a move of the supervisor seat keeps the
  #   old session alive, off aimail (--keep-old is implied and cannot be turned off). lib/handover.sh is the
  #   budget-handover wrapper that drives this path.
  if [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" && $keep_old -eq 0 ]]; then
    keep_old=1; info "   '$seat' is the supervisor: --keep-old implied (the old session is never stopped; it leaves aimail instead)"
  fi
  # ⛔ THE SUPERVISOR IS PINNED (the owner, 2026-09-22 16:45): only the owner moves it. The balancer's
  #   16:30 "migrate assistant work->r2" recommendation is exactly what must never be produced or
  #   acted on. An explicit, reasoned override is recorded in the session registry's log.
  # 17:28: the rule extends to main -- both are LOCKED to the work account. `AIMAIL_PINNED_SEATS`
  #   (default: the supervisor and the vice) names the set; one override mechanism for all of it.
  local _pinned="${AIMAIL_PINNED_SEATS:-${AIMAIL_SUPERVISOR:-assistant} ${AIMAIL_VICE_SUPERVISOR:-main}}" _p
  for _p in $_pinned; do
    if [[ "$seat" == "$_p" && -z "$owner_approved" ]]; then
      refused "seat migrate: '$seat' is PINNED to its account (AIMAIL_PINNED_SEATS: $_pinned) -- only the owner moves it" \
        "Re-run with --owner-approved \"<the owner's own words, with the time they said them>\" if they did; the reason is logged."
    fi
  done
  [[ -n "$owner_approved" ]] && why="owner-approved: $owner_approved${why:+; $why}"
  source "${BASH_SOURCE[0]%/*}/budget.sh" 2>/dev/null || true
  # ⛔ PLACEMENT RULES (lib/placement.sh, T-917): the precious account, the spread rule and
  #   fable's own headroom are checked BEFORE the handover is requested, so a refused move
  #   costs nothing. --owner-approved is the one override for all of them, and it is logged.
  source "${BASH_SOURCE[0]%/*}/placement.sh" 2>/dev/null || true
  if [[ -z "$owner_approved" ]] && command -v placement_check_move >/dev/null 2>&1; then
    # (the target word IS the key every reading is filed under -- see placement.sh's _pl_accounts note)
    local _pc; _pc="$(placement_check_move "$seat" "$target" 2>/dev/null || true)"
    if [[ "${_pc%%$'\t'*}" == "REFUSE" ]]; then
      refused "seat migrate: placement rule -- ${_pc#*$'\t'}" \
        "See: aimail budget placement $seat   (eligible accounts, best first). Override only with --owner-approved \"<his words>\"."
    fi
  fi
  local target_dir; target_dir="$(ACCOUNT_CONFIG_DIR "$target")"
  [[ -d "$target_dir" ]] || refused "seat migrate: target account '$target' has no config dir at $target_dir" \
    "Accounts in the pool: ${AIMAIL_FLEET_ACCOUNTS:-<AIMAIL_FLEET_ACCOUNTS unset>}"
  _claude_available || refused "seat migrate: no 'claude' CLI available (AIMAIL_NO_NETWORK=1 or not on PATH)"

  # ── a. locate ──────────────────────────────────────────────────────────────
  _mig_step "a. locate $seat's session (claude agents --json across the account pool)"
  local loc rc=0
  loc="$(seat_session_locate "$seat")" || rc=$?
  local liveness; liveness="$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$loc")"
  local unk; unk="$(awk -F'\t' '$1=="unknown_accounts"{print $2}' <<<"$loc")"
  [[ -z "$unk" ]] || refused "seat migrate: account(s) did not answer claude agents --json: $unk — nothing done" \
    "A migration needs every account in the pool to answer: the settle re-check must prove the session is ABSENT there."
  case "$rc" in
    3) printf '%s\n' "$loc" | awk -F'\t' '$1=="twin"{printf "   TWIN: account=%s session=%s pid=%s short=%s state=%s\n",$2,$3,$4,$5,$6}'
       # ⛔ ONE twin is allowed to be resolved by the tool (2026-09-22 18:28, fable research->r2): the
       #   TARGET holds a limit-BLOCKED leftover of the same session from an earlier stint there. It is
       #   idle at a limit with nothing in flight, and its transcript is older than the live side's.
       #   Rule: exactly one non-blocked twin + every other twin `blocked` AND on the target account
       #   -> stop the leftovers on the target (verified gone) and carry on. Anything else stays a refusal.
       local _tl _tn=0 _tb=0 _tlabel; _tlabel="$(_account_label "$target_dir")"; local -a _tstop=()
       while IFS= read -r _tline; do
         [[ "$(_tsv_nth "$_tline" 1)" == "twin" ]] || continue
         _acct="$(_tsv_nth "$_tline" 2)"; _lshort="$(_tsv_nth "$_tline" 5)"; _lstate="$(_tsv_nth "$_tline" 6)"   # awk, not read: an idle twin's pid is empty
         if [[ "$_lstate" == "blocked" && "$_acct" == "$_tlabel" ]]; then _tb=$((_tb+1)); _tstop+=("$_lshort"); else _tn=$((_tn+1)); fi
       done <<<"$loc"
       if (( _tn == 1 && _tb >= 1 )); then
         for _tl in "${_tstop[@]}"; do
           warn "   the target '$target' holds a limit-BLOCKED leftover of this seat's session ($_tl) -- stopping it (idle at a limit, nothing in flight; the live side's transcript is the newer one)"
           CLAUDE_CONFIG_DIR="$target_dir" _claude stop "$_tl" >/dev/null 2>&1 || true
         done
         sleep 1
         rc=0; loc="$(seat_session_locate "$seat")" || rc=$?
         # re-read what was derived from the OLD listing (a stale "twin" here made step c skip the stop)
         liveness="$(awk -F'\t' '$1=="liveness"{print $2}' <<<"$loc")"
         (( rc == 0 )) || refused "seat migrate: after stopping the blocked leftover(s) on '$target' the seat still does not locate as ONE live session (rc=$rc) — nothing further done" \
           "$(printf '%s\n' "$loc" | awk -F'\t' '$1=="twin"{printf "TWIN: account=%s session=%s short=%s state=%s\n",$2,$3,$5,$6}')"
       else
       refused "seat migrate: '$seat' is live under MORE THAN ONE session/account (twins)" \
         "Stop the wrong one first, from its own account dir: CLAUDE_CONFIG_DIR=<dir> claude stop <short-id>" \
         "then re-run. This tool never chooses which twin survives (except a limit-blocked leftover on the target, which it stops)."
       fi ;;
    2) refused "seat migrate: the live-session listing is UNKNOWN (an account dir did not answer) — nothing done" ;;
    1) if [[ -z "$sid_override" ]]; then
         refused "seat migrate: no session found for '$seat' — no live listing, no poller instance, no seat record" \
           "If you know the session id, pass --sid <id> (find it with the transcript heuristic in docs/cli_account_migration.md)."
       fi ;;
  esac
  local sid cur_acct cur_dir pid short state cwd
  sid="$(awk -F'\t' '$1=="sid"{print $2}' <<<"$loc")"
  cur_acct="$(awk -F'\t' '$1=="account"{print $2}' <<<"$loc")"
  cur_dir="$(awk -F'\t' '$1=="config_dir"{print $2}' <<<"$loc")"
  pid="$(awk -F'\t' '$1=="pid"{print $2}' <<<"$loc")"
  short="$(awk -F'\t' '$1=="short_id"{print $2}' <<<"$loc")"
  state="$(awk -F'\t' '$1=="state"{print $2}' <<<"$loc")"
  cwd="$(awk -F'\t' '$1=="cwd"{print $2}' <<<"$loc")"
  if [[ -n "$sid_override" ]]; then
    [[ -z "$sid" || "$sid" == "$sid_override" ]] || refused "seat migrate: --sid $sid_override disagrees with the located session $sid — resolve that first"
    sid="$sid_override"; short="${sid:0:8}"; liveness="${liveness:-dead}"
  fi
  [[ -n "$cwd_override" ]] && cwd="$cwd_override"
  # ⚠ A DEAD seat has no live listing to read its cwd from. The scheduler's own saved spec on
  #   the source account (jobs/<short>/state.json, key `cwd`) usually still has it; the operator's
  #   $PWD never does (code-review, 2026-09-22: a resumed seat with the right conversation but
  #   the WRONG working directory going forward). Refuse rather than guess.
  if [[ -z "$cwd" ]]; then
    local _res; _res="$(seat_cwd_resolve "$seat" "$sid" "$cur_dir" 2>/dev/null || true)"
    if [[ -n "$_res" ]]; then
      cwd="${_res%%$'\t'*}"; local _src="${_res#*$'\t'}"
      case "$_src" in
        record) info "   cwd       $cwd  (from the seat record)" ;;
        spec:*) info "   cwd       $cwd  (from the saved launch spec ${_src#spec:})" ;;
      esac
    fi
  fi
  [[ -n "$cwd" ]] || refused "seat migrate: no working directory known for $short -- no live listing, no --cwd, and no saved launch spec carries one" \
    "A resume from the operator's own \$PWD would give the seat its conversation back in the WRONG directory. Pass --cwd <the seat's project dir>."
  info "   session   $sid  (short $short)"
  info "   liveness  $liveness${state:+  state=$state}${pid:+  pid=$pid}"
  info "   account   ${cur_acct:-?}  (${cur_dir:-no config dir known})"
  info "   cwd       $cwd"
  if [[ "$liveness" == "live" && -n "$cur_dir" && "$(readlink -f "$cur_dir")" == "$(readlink -f "$target_dir")" ]]; then
    refused "seat migrate: '$seat' is already live on '$target' — nothing to move"
  fi
  # model: explicit, else the record, else detected from the current account's spec/transcript
  if [[ -z "$model" ]]; then
    model="$(seat_record_read "$seat" model 2>/dev/null || echo '')"
    [[ "$model" == "unknown" ]] && model=""
  fi
  if [[ -z "$model" && -n "$cur_dir" ]]; then model="$(seat_model_detect "$cur_dir" "$sid" 2>/dev/null || echo '')"; fi
  [[ -n "$model" ]] || refused "seat migrate: no model known for '$seat' (no --model, no record, nothing in the launch spec or transcript)" \
    "A migration never defaults the model silently — that is how a seat ended up on the wrong model. Pass --model <id>."
  info "   model     $model"

  # ── a2. WHICH session runs on the target (the owner, 2026-09-22 15:43): RESUME by default ──
  #   (i) the seat's own previous session on the TARGET account, when the registry names one and
  #       its transcript is really there — the seat gets that account's own history back;
  #  (ii) else the session located above, whose transcript is CARRIED to the target first (the
  #       "source session not found" fix — see _transcript_prepare);
  # (iii) FRESH only with --fresh --why: an explicit, logged decision, never a fallback.
  local launch_path="" resume_sid="$sid"
  local target_label; target_label="$(_account_label "$target_dir")"
  # the seat's PRIOR session on the target: --resume-sid (explicit), else the registry, else the target's
  # transcripts fingerprinted by the seat's own poller command (seat_prior_session, lib/handover.sh -- the
  # owner 2026-09-23 09:04: "the most recent prior session of this seat on the target account, never fresh")
  local prior_sid="" prior_src="registry" _pp
  if [[ -n "$resume_sid_override" ]]; then prior_sid="$resume_sid_override"; prior_src="--resume-sid"
  else
    prior_sid="$(seat_sessions_get "$seat" "$target_label" 2>/dev/null || echo '')"
    [[ "$prior_sid" == "$sid" ]] && prior_sid=""   # the registry naming the session being moved is not a PRIOR one
    if [[ -z "$prior_sid" ]] && declare -F seat_prior_session >/dev/null 2>&1; then
      _pp="$(seat_prior_session "$seat" "$target_label" "$sid" "$target_dir" 2>/dev/null || true)"
      [[ -n "$_pp" ]] && { prior_sid="${_pp%%$'\t'*}"; prior_src="$(cut -f2 <<<"$_pp")"; }
    fi
  fi
  # where that prior transcript lives on the target: the cwd's slug first, then any project slug
  local prior_tx=""
  if [[ -n "$prior_sid" && "$prior_sid" != "$sid" ]]; then
    local _c; for _c in "$target_dir/projects/$(_cwd_slug "$cwd")/$prior_sid.jsonl" "$target_dir"/projects/*/"$prior_sid.jsonl"; do
      [[ -f "$_c" ]] && _transcript_has_conversation "$_c" && { prior_tx="$_c"; break; }
    done
    [[ -n "$prior_tx" && "$(basename "$(dirname "$prior_tx")")" != "$(_cwd_slug "$cwd")" ]] \
      && warn "   the prior session ${prior_sid:0:8} was recorded under project '$(basename "$(dirname "$prior_tx")")', not this cwd's -- pass --cwd <that directory> so the seat resumes where it worked"
  fi
  [[ -n "$resume_sid_override" && -z "$prior_tx" ]] && refused "seat migrate: --resume-sid ${resume_sid_override:0:8} has no transcript with a conversation under '$target' -- not resuming anything else in its place"
  if (( fresh )); then
    [[ -n "$why" ]] || refused "seat migrate: --fresh needs --why \"<reason>\" — a fresh session drops the seat's conversation history; the reason is logged in the session registry" \
      "the owner's rule: fresh is for a seat that will not follow the orchestrator and is blocking the fleet, nothing else."
    launch_path="fresh"
    info "   launch    FRESH session (--fresh): $why"
  elif [[ -n "$prior_tx" ]]; then
    launch_path="resume-prior"; resume_sid="$prior_sid"
    info "   launch    RESUME the seat's previous session on '$target': ${prior_sid:0:8} ($prior_src) — its transcript is on the target"
  else
    # ⛔ keep-old + the SAME session id on two accounts is impossible (the old one stays alive on the source):
    #   the supervisor's move needs its prior session on the target, or an explicit fresh decision.
    (( keep_old )) && refused "seat migrate: --keep-old ('$seat' stays alive on '${cur_acct:-?}') cannot resume the SAME session $short on '$target' -- name the seat's prior session there with --resume-sid <id> (none found in the registry or the target's transcripts), or decide --fresh --why \"...\""
    launch_path="resume"
    info "   launch    RESUME $short on '$target' (transcript carried from '${cur_acct:-?}' if not already there)"
    if ! _transcript_prepare "${cur_dir:--}" "$target_dir" "$cwd" "$sid" "$dry"; then
      refused "seat migrate: no transcript with any conversation for $short on '${cur_acct:-?}' or '$target' — a --resume there would fail with 'source session not found'" \
        "Looked under <config-dir>/projects/$(_cwd_slug "$cwd")/$sid.jsonl (and every projects/*/ for the source)." \
        "If the session's history is genuinely gone, that is the one case for an explicit fresh launch:" \
        "  aimail seat migrate $seat $target --model $model --fresh --why \"transcript lost: <how>\""
    fi
  fi

  # ── b. handover ────────────────────────────────────────────────────────────
  _mig_step "b. handover (the seat writes its own role file before it is stopped)"
  local role_file; role_file="$(ROLE_FILE "$seat" 2>/dev/null || echo "$AIMAIL_ROOT/roles/$seat.md")"
  if [[ "$liveness" != "live" ]]; then
    info "   session is not live — no handover to ask for (the existing role file stands)"
  elif (( handover_wait == 0 )); then
    info "   --handover-wait 0 — not asking (caller's choice)"
  elif _mig_handover_is_fresh "$role_file"; then
    info "   role handover already current ($role_file written within ${AIMAIL_MIGRATE_HANDOVER_FRESH_S:-600}s) — not asking"
  else
    local before; before="$(stat -c %Y "$role_file" 2>/dev/null || echo 0)"
    local body; body="$(mktemp "${AIMAIL_ROOT}/tmp/migrate_handover.XXXXXX" 2>/dev/null || mktemp)"
    printf 'to: %s\nfrom: %s\n\nMIGRATION in %s s: this session is about to be stopped and relaunched on the "%s" account by `aimail seat migrate`. Write the role handover NOW:\n\n    aimail role write %s <file>\n\nThe migration proceeds when the role file changes, or refuses when the wait runs out.\n' \
      "$seat" "$from" "$handover_wait" "$target" "$seat" > "$body"
    if (( dry )); then
      _mig_cmd "aimail send --to $seat --from $from --subject 'MIGRATION: write your handover now' --body-file $body"
      info "   (dry-run) would wait up to ${handover_wait}s for $role_file to change"
    else
      ensure_dirs
      local mail_out
      if ! mail_out="$(mail_send --to "$seat" --from "$from" --subject "MIGRATION in ${handover_wait}s: write your role handover now" --body-file "$body" 2>&1)"; then
        warn "   could not send the handover request (mail_send failed): ${mail_out:-<no output captured>} — waiting anyway"
      fi
      local waited=0 after
      while (( waited < handover_wait )); do
        after="$(stat -c %Y "$role_file" 2>/dev/null || echo 0)"
        (( after > before )) && break
        sleep "$poll_s"; waited=$((waited+tick))
      done
      after="$(stat -c %Y "$role_file" 2>/dev/null || echo 0)"
      if (( after > before )); then
        ok "   handover written (${waited}s) — $role_file"
      elif (( force_no_handover )); then
        warn "   no handover in ${handover_wait}s — proceeding because --force-no-handover was passed"
      else
        refused "seat migrate: '$seat' did not write its handover within ${handover_wait}s" \
          "A seat resumed without a current handover re-derives work already done. Re-run with a longer --handover-wait," \
          "or --force-no-handover if the session is provably wedged (aimail sessions $seat)."
      fi
    fi
    rm -f "$body"
  fi

  # ── c. stop, verified ──────────────────────────────────────────────────────
  _mig_step "c. stop the session cleanly — claude stop, never kill (the scheduler respawns a killed job)"
  if (( keep_old )); then
    info "   --keep-old: the old session ${short} on '${cur_acct:-?}' is NOT stopped; it stays alive off aimail (its poller exits as superseded once the record retires it)"
    _mig_cmd "# no claude stop: --keep-old"
  elif [[ "$liveness" == "live" ]]; then
    _mig_cmd "CLAUDE_CONFIG_DIR=$cur_dir claude stop $short"
    if (( ! dry )); then
      CLAUDE_CONFIG_DIR="$cur_dir" _claude stop "$short" >/dev/null 2>&1 || warn "   claude stop returned non-zero — verifying the listing anyway"
      local waited=0 gone=0 r
      while (( waited <= stop_timeout )); do
        _sid_listed "$cur_dir" "$sid"; r=$?
        if (( r == 1 )); then gone=1; break; fi
        sleep "$poll_s"; waited=$((waited+tick))
      done
      (( gone )) || refused "seat migrate: session $short is STILL listed on '$cur_acct' ${stop_timeout}s after claude stop — not relaunching" \
        "Check: CLAUDE_CONFIG_DIR=$cur_dir claude agents --json"
      ok "   session $short no longer listed on '$cur_acct'"
    fi
  else
    info "   not live — nothing to stop"
  fi
  # orphan pollers: a stopped session's backgrounded poller survives it
  local idir f isid ipid killed=0
  idir="$(INSTANCE_DIR "$seat")"
  if [[ -d "$idir" ]]; then
    for f in "$idir"/*; do
      [[ -f "$f" ]] || continue
      case "$(basename "$f")" in .inst.*) continue ;; esac
      isid="$(basename "$f")"; [[ "$isid" == "$sid" ]] || continue
      ipid="$(instance_read "$f" pid || echo '')"
      if [[ "$ipid" =~ ^[0-9]+$ ]] && kill -0 "$ipid" 2>/dev/null && _instance_pid_is_poller "$ipid"; then
        if (( dry )); then _mig_cmd "kill -TERM $ipid   # orphan poller of $short"
        else kill -TERM "$ipid" 2>/dev/null || true; sleep 1; kill -0 "$ipid" 2>/dev/null && kill -KILL "$ipid" 2>/dev/null; rm -f "$f"; killed=$((killed+1)); fi
      fi
    done
  fi
  (( dry )) || info "   orphan pollers of $short killed: $killed"

  # ── d. relaunch on the target ──────────────────────────────────────────────
  _mig_step "d. relaunch on '$target' ($launch_path) with an explicit model"
  local prompt
  if [[ -n "$prompt_file" ]]; then
    [[ -f "$prompt_file" ]] || refused "seat migrate: --prompt-file $prompt_file does not exist"
    prompt="$(cat "$prompt_file")"
  else
    prompt="$(_mig_default_prompt "$seat" "$from" "$target" "${cur_acct:-unknown}")"
  fi
  # ⛔⛔ SAVED LAUNCH OPTIONS (found live, 2026-09-21): when the TARGET account already holds
  #   this session's own saved launch spec (jobs/<short>/state.json exists there -- a same-account
  #   relaunch, or a seat that has been on this account before), `--resume <sid>` WITH flags does
  #   not continue <sid>: the CLI keeps the saved options and starts a COPY under a NEW session id,
  #   saying so only in its stdout ("... started a copy as <new-sid>. Without flags, the same
  #   command continues <sid> itself."). Flagless, the same command continues <sid>. So: flags only
  #   when the target has no saved spec for this sid; and the output is always checked for the
  #   copy warning, because the tool must never report a resume that created a different session.
  local -a launch_flags=()
  local saved_spec="$target_dir/jobs/${resume_sid:0:8}/state.json"
  if [[ -f "$saved_spec" ]]; then
    # ⚠ the spec belongs to the session being RESUMED (resume_sid), which under resume-prior is not $sid
    local saved_model; saved_model="$(seat_model_detect "$target_dir" "$resume_sid" 2>/dev/null || echo '')"
    info "   target already holds this session's saved launch options ($saved_spec${saved_model:+, model $saved_model}) — relaunching WITHOUT flags so the CLI continues ${resume_sid:0:8} itself"
    if [[ -n "$saved_model" && "$saved_model" != "$model" ]]; then
      if (( repin_saved )); then
        # ⭐ --repin-saved-model: rewrite the saved spec's --model to this run's pin (and, for the supervisor,
        #   name its --remote-control after the seat), keep a backup, then resume FLAGLESS so the scheduler
        #   respawns with the new options. Never `claude rm` (it deletes the job, and possibly more).
        (( dry )) || cp -p "$saved_spec" "$saved_spec.bak-$(date +%Y%m%dT%H%M%S)"
        _mig_cmd "python3: $saved_spec respawnFlags --model $saved_model -> $model$( [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]] && printf ', --remote-control %s' "$seat")   (backup kept beside it)"
        if (( ! dry )); then
          python3 - "$saved_spec" "$model" "$( [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]] && printf '%s' "$seat")" <<'PY' || refused "seat migrate: could not rewrite the saved launch spec $saved_spec"
import json, sys
p, model, rc_name = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p)); f = list(d.get("respawnFlags") or [])
out = []; i = 0
while i < len(f):
    x = f[i]
    if x == "--model" and i + 1 < len(f): out += ["--model", model]; i += 2; continue
    if x == "--remote-control":
        i += 1
        if i < len(f) and not f[i].startswith("-"): i += 1   # drop the old name
        continue
    out.append(x); i += 1
if "--model" not in out: out += ["--model", model]
if rc_name: out += ["--remote-control", rc_name]
d["respawnFlags"] = out
json.dump(d, open(p, "w"))
PY
          info "   saved spec repinned: model $saved_model -> $model$( [[ "$seat" == "${AIMAIL_SUPERVISOR:-assistant}" ]] && printf ', --remote-control %s' "$seat")"
        fi
      else
        refused "seat migrate: the saved launch spec on '$target' pins model '$saved_model' but this run wants '$model'" \
          "A flagged --resume would start a COPY under a new session id, not change the model. Either accept the saved model" \
          "(re-run with --model $saved_model), or re-run with --repin-saved-model (rewrites the spec's --model to '$model', backup kept, then a flagless resume)."
      fi
    else
      model="${saved_model:-$model}"
    fi
  else
    # the supervisor's relaunch carries Remote Control under the seat's own name (the owner, 2026-09-23);
    # only when flags are allowed at all -- with a saved spec the resume must stay flagless (see above)
    mapfile -t launch_flags < <(_seat_launch_flags "$seat" "$model")
  fi
  if [[ "$launch_path" == "fresh" ]]; then
    # ⛔ a NEW supervisor session is launched WITH Remote Control ON under the seat's own name, so the owner
    #   can find it by name among the fleet's sessions (owner rule 2026-09-23). Fresh launches only: a
    #   flagged --resume would start a copy instead of continuing the session.
    mapfile -t launch_flags < <(_seat_launch_flags "$seat" "$model")
    _mig_cmd "cd $cwd && CLAUDE_CONFIG_DIR=$target_dir claude --bg ${launch_flags[*]} \"<prompt>\"   # no --resume: a NEW session id"
  else
    _mig_cmd "cd $cwd && CLAUDE_CONFIG_DIR=$target_dir claude --bg --resume $resume_sid ${launch_flags[*]:-} \"<prompt>\""
  fi
  if (( dry )); then
    info "   (dry-run) prompt would be:"; printf '%s\n' "$prompt" | sed 's/^/   | /'
    _mig_step "e./f. (dry-run) would verify on '$target', settle ${settle}s, re-verify absent elsewhere, then write the seat record"
    return 0
  fi
  local launch_out before_rows
  before_rows="$(_agents_rows "$target_dir" 2>/dev/null || true)"
  if [[ "$launch_path" == "fresh" ]]; then
    launch_out="$(cd "$cwd" && CLAUDE_CONFIG_DIR="$target_dir" _claude --bg "${launch_flags[@]}" "$prompt" 2>&1)" \
      || refused "seat migrate: fresh launch command failed:" "$launch_out"
  else
    launch_out="$(cd "$cwd" && CLAUDE_CONFIG_DIR="$target_dir" _claude --bg --resume "$resume_sid" "${launch_flags[@]}" "$prompt" 2>&1)" \
      || refused "seat migrate: relaunch command failed:" "$launch_out"
  fi
  info "   launched: ${launch_out:-<no output>}"
  # the sid the rest of this run follows: the resumed one, or the NEW one a fresh launch minted
  # (found by diffing the target's listing, never by parsing the CLI's prose)
  local launch_sid="$resume_sid"
  if [[ "$launch_path" == "fresh" ]]; then
    local waited_new=0 new_sids=""
    while (( waited_new <= launch_timeout )); do
      new_sids="$(_new_sids_on "$target_dir" "$before_rows" 2>/dev/null || true)"
      [[ -n "$new_sids" ]] && break
      sleep "$poll_s"; waited_new=$((waited_new+tick))
    done
    [[ -n "$new_sids" ]] || refused "seat migrate: the fresh launch produced no NEW session in '$target''s listing within ${launch_timeout}s" "Check: CLAUDE_CONFIG_DIR=$target_dir claude agents --json"
    (( $(wc -l <<<"$new_sids") == 1 )) || refused "seat migrate: more than one new session appeared on '$target' during the fresh launch — cannot tell which is $seat's:" "$new_sids"
    launch_sid="$new_sids"
    info "   fresh session id: $launch_sid"
  fi
  sid="$launch_sid"; short="${sid:0:8}"
  local copy_sid
  copy_sid="$(grep -oE 'started a copy as [0-9a-fA-F-]+' <<<"$launch_out" | awk '{print $5}' | head -1)"
  if [[ -n "$copy_sid" ]]; then
    # our own copy, seconds old, nothing in it: stop it so it cannot become a twin
    CLAUDE_CONFIG_DIR="$target_dir" _claude stop "${copy_sid:0:8}" >/dev/null 2>&1 || true
    if grep -q 'already running in the background' <<<"$launch_out" && [[ "$launch_path" != "fresh" ]]; then
      # ⛔ THE ORIGINAL IS ALREADY RUNNING ON THE TARGET (2026-09-22 18:28: a limit-blocked idle
      #   leftover from an earlier stint on that account). A flagless resume of a RUNNING session is
      #   accepted as a wake only when it is healthy ("woke session ... with its saved options");
      #   a blocked one copies. The copy is stopped above; now BOUNCE the original -- stop it
      #   (idle, nothing in flight) and resume it flagless, which continues the same transcript.
      warn "   the target already ran $short (a leftover from an earlier stint) -- bouncing it: stop, then a flagless resume"
      CLAUDE_CONFIG_DIR="$target_dir" _claude stop "$short" >/dev/null 2>&1 || true
      local waited_b=0 rb=0
      while (( waited_b <= stop_timeout )); do
        _sid_listed "$target_dir" "$resume_sid"; rb=$?
        (( rb == 1 )) && break
        sleep "$poll_s"; waited_b=$((waited_b+tick))
      done
      (( rb == 1 )) || refused "seat migrate: the leftover $short on '$target' is STILL listed live ${stop_timeout}s after claude stop — not relaunching" \
        "Check: CLAUDE_CONFIG_DIR=$target_dir claude agents --json --all | grep $short"
      launch_out="$(cd "$cwd" && CLAUDE_CONFIG_DIR="$target_dir" _claude --bg --resume "$resume_sid" "$prompt" 2>&1)" \
        || refused "seat migrate: relaunch after the bounce failed:" "$launch_out"
      info "   relaunched after the bounce: ${launch_out:-<no output>}"
      grep -q 'started a copy as' <<<"$launch_out" && refused "seat migrate: the CLI started a copy AGAIN after the bounce — stopping here, a human decides" "$launch_out"
      launch_path="resume-bounced"
    else
      refused "seat migrate: the CLI did NOT continue $short — it started a COPY as ${copy_sid:0:8} (flags vs the target's saved launch options); the copy has been stopped, nothing is confirmed, no record written" \
        "Re-run: the tool launches flagless when it sees the saved spec; if the spec appeared between the check and the launch, just run again." \
        "Verify nothing else changed: CLAUDE_CONFIG_DIR=$target_dir claude agents --json --all | grep -E '$short|${copy_sid:0:8}'"
    fi
  fi

  # ── e. verify, settle, re-verify ───────────────────────────────────────────
  _mig_step "e. verify it is listed LIVE on '$target' (up to ${launch_timeout}s), settle ${settle}s, re-verify"
  local waited=0 present=0 r js
  while (( waited <= launch_timeout )); do
    # the scheduler's own verdict first: a `failed` job never becomes live, say why NOW
    js="$(_job_state "$target_dir" "$sid" 2>/dev/null || true)"
    if [[ "${js%%$'\t'*}" == "failed" ]]; then
      refused "seat migrate: the relaunch of $short on '$target' FAILED in the scheduler: ${js#*$'\t'}" \
        "(jobs/$short/state.json). A resume fails this way when the target has no transcript for the session —" \
        "this tool now carries it across first; if you see this, check $target_dir/projects/<cwd-slug>/$sid.jsonl by hand." \
        "No seat record was written."
    fi
    _sid_listed "$target_dir" "$sid"; r=$?
    if (( r == 0 )); then present=1; break; fi
    sleep "$poll_s"; waited=$((waited+tick))
  done
  (( present )) || refused "seat migrate: session $short is NOT listed live on '$target' after ${launch_timeout}s — the relaunch did not register" \
    "Check: CLAUDE_CONFIG_DIR=$target_dir claude agents --json ; claude logs $short"
  ok "   listed on '$target' after ${waited}s"
  info "   settling ${settle}s before re-checking (a respawn from the old launch spec appears within a couple of minutes)"
  sleep "$settle"
  _sid_listed "$target_dir" "$sid"; r=$?
  if (( r != 0 )); then
    js="$(_job_state "$target_dir" "$sid" 2>/dev/null || true)"
    refused "seat migrate: session $short is no longer listed LIVE on '$target' after the ${settle}s settle window — not confirming" \
      "scheduler state for it: ${js:-<no jobs/$short/state.json>}"
  fi
  local dir other_hits=0 unanswered=""
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    [[ "$(readlink -f "$dir")" == "$(readlink -f "$target_dir")" ]] && continue
    # the LAUNCHED session is what must be absent elsewhere (under --keep-old the old id legitimately stays live on the source)
    if [[ -d "$dir" ]]; then _sid_listed "$dir" "$launch_sid"; r=$?; else r=2; fi
    if (( r == 0 )); then other_hits=$((other_hits+1)); warn "   session ${launch_sid:0:8} is ALSO listed on '$(_account_label "$dir")' — a respawn from the old launch spec (twin)"; fi
    (( r == 2 )) && unanswered="${unanswered:+$unanswered }$(_account_label "$dir")"
  done < <(_instance_account_dirs)
  (( other_hits == 0 )) || refused "seat migrate: '$seat' is live on '$target' AND on $other_hits other account(s) — twins; stop the wrong one:" \
    "CLAUDE_CONFIG_DIR=<that dir> claude stop $short   then re-run this command (it will find the survivor)."
  # ⛔ An account that did not answer during the settle window is NOT "absent". The whole
  #   point of this step is to prove no respawn landed elsewhere; a silent account is exactly
  #   where one would hide (code-review's peer review of 7d81a09). Same rule as step a: refuse,
  #   write no record. The session IS live on the target -- the operator re-runs the check.
  [[ -z "$unanswered" ]] || refused "seat migrate: account(s) did not answer claude agents --json during the settle re-check: $unanswered — absence there is UNVERIFIED, so this migration is NOT confirmed and no seat record is written" \
    "The session is live on '$target'. Re-check by hand once every account answers:" \
    "  for d in <every account dir>; do CLAUDE_CONFIG_DIR=\$d claude agents --json; done   # $short must appear on '$target' only" \
    "then record it: aimail seat confirm $seat --model $model   (from inside the relaunched session)"
  ok "   present on '$target' only, ${settle}s after launch"
  local pstate; pstate="$(poller_state "$seat" 2>/dev/null | head -1 || echo '?')"
  info "   poller: ${pstate:-?} (the seat arms it itself; ARMED may take a minute — check aimail fleet $seat)"

  # ── f. record ──────────────────────────────────────────────────────────────
  _mig_step "f. seat record"
  seat_record_write "$seat" "$target" "$target_dir" "$sid" "$model" "migrate" "$launch_path" "migrate from ${cur_acct:-?} ($launch_path${why:+: $why})" "$cwd"
  ok "   $seat → account=$target session=$short model=$model (confirmed_by=migrate, path=$launch_path)"
  info "   The seat's own \`aimail seat confirm $seat --model <id>\` at boot re-confirms this from the inside."
}
