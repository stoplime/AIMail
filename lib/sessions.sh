# shellcheck shell=bash
# sessions.sh — who is actually AT each seat, session by session.
#
# ⛔⛔ THE GAP THIS FILLS, AND WHY `aimail fleet` COULD NEVER FILL IT: every
#   instrument in this repo is keyed on a SEAT NAME. `poller_state` reads
#   `state/poller/<seat>.hb`; `last_stop` greps a seat column; the project fork's
#   `poller_guard.sh status` runs a per-seat process check and prints the result
#   against every registration row of that seat. A seat name is not a unit of
#   liveness — a seat can have four concurrent sessions and forty dead ones, and
#   all forty-four render identically.
#
#   MEASURED 2026-09-06 on this deployment, and it produced a false fleet alarm
#   a human had to refute by hand: 46 registrations existed, 39 of them from
#   sessions that ended days earlier and were never pruned. `status` reported
#   8 "main", 7 "audit", 4 "fable", every row `seat-poller=LIVE`, because the
#   liveness column was a per-seat aggregate stamped onto each row. Three
#   different seats then independently re-derived the same manual transcript
#   cross-check to find out which rows were real. That duplicated hand-work is
#   the cost this file removes.
#
# ⭐ WHAT IS DIFFERENT HERE: every signal is keyed to the SESSION ID.
#   `lib/session_liveness.py` holds the evidence rules and their measurements —
#   read its header before changing any threshold. This file only decides WHERE
#   registrations come from and HOW the answer is rendered, which is the half
#   that is deployment-specific.
#
# ⚠ TWO REGISTRATION STORES, BOTH REAL, AND THAT IS NOT AN ACCIDENT. This repo's
#   own `stop_guard.sh` keeps `state/stopguard/session.<sid>`; a project-local
#   Stop-hook fork keeps its own `seat_<sid>` files somewhere else entirely
#   (AIMAIL_EXTERNAL_SEAT_DIR — the same seam AR-26 added for `whoami`, reused
#   rather than invented again). A session can be in one, both, or neither, and
#   "in neither while running" is exactly the 2026-09-03 architect incident that
#   `lib/session.sh` exists to catch. Read both; say which store each row is in.

SESSIONS_PY() { echo "$AIMAIL_LIB/session_liveness.py"; }

# Where the project-local Stop-hook fork keeps its session->seat map. Same env
# var role.sh/whoami already honour, so a deployment configures this ONCE.
EXTERNAL_SEAT_DIR() { echo "${AIMAIL_EXTERNAL_SEAT_DIR:-}"; }

# ─── Collect registrations from every store, as the TSV the classifier eats ──
# Emits: sid \t seat \t registered_epoch \t store
# ⛔ The store column is dropped before the classifier sees it (its contract is
#   three fields) but kept here, because "which file do I delete to prune this"
#   is a question the report has to be able to answer without a second scan.
_sessions_collect() {
  local f sid seat
  if [[ -d "$STATE_DIR/stopguard" ]]; then
    for f in "$STATE_DIR/stopguard"/session.*; do
      [[ -f "$f" ]] || continue
      sid="$(basename "$f")"; sid="${sid#session.}"
      seat="$(cat "$f" 2>/dev/null)"
      printf '%s\t%s\t%s\t%s\n' "$sid" "$seat" "$(stat -c %Y "$f" 2>/dev/null || echo '')" "$f"
    done
  fi
  local ext; ext="$(EXTERNAL_SEAT_DIR)"
  if [[ -n "$ext" && -d "$ext" ]]; then
    for f in "$ext"/seat_*; do
      [[ -f "$f" ]] || continue
      sid="$(basename "$f")"; sid="${sid#seat_}"
      seat="$(cat "$f" 2>/dev/null)"
      printf '%s\t%s\t%s\t%s\n' "$sid" "$seat" "$(stat -c %Y "$f" 2>/dev/null || echo '')" "$f"
    done
  fi
}

# _sessions_all_account_projects_dirs — every configured account's own
# <config-dir>/projects root, as "label=path" pairs joined by ':', ready for
# session_liveness.py's AIMAIL_SESSION_PROJECTS_DIRS. Lazily sources fleet.sh
# for _instance_account_dirs -- the same account-pool enumeration `seat
# migrate`'s own twin/locate check already relies on, not a second one
# invented here. Only dirs that actually exist are listed; an empty/absent
# projects/ subdir is silently skipped rather than passed through as a root
# that will just glob to nothing.
_sessions_all_account_projects_dirs() {
  source "${AIMAIL_LIB}/fleet.sh" 2>/dev/null || return 1
  local dir label out=""
  while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir/projects" ]] || continue
    label="$(basename "$(readlink -f "$dir" 2>/dev/null || echo "$dir")" | sed 's/^\.//; s/^claude-//; s/^claude$/default/')"
    out="${out:+$out:}${label}=${dir}/projects"
  done < <(_instance_account_dirs 2>/dev/null)
  printf '%s' "$out"
}

# ─── Run the classifier over whatever was collected ──────────────────────────
# Returns the JSON on stdout, or nothing (non-zero) if it could not run at all.
#
# ⛔⛔ MULTI-ACCOUNT, NOT JUST THE CALLER'S OWN (2026-09-24): session_liveness.py
#   used to default to scanning only `$CLAUDE_CONFIG_DIR/projects` -- i.e. only
#   the account THIS shell happens to be running under. Every other account's
#   sessions read as having no transcript at all, not because they lacked one
#   but because nothing ever looked in their own `~/.claude-<account>/projects/`
#   tree. AIMAIL_SESSION_PROJECTS_DIRS (plural) is populated here from the
#   account pool UNLESS a caller (a test fixture) already set it explicitly --
#   `local -x` scopes the export to this function only, so it never leaks into
#   the caller's own environment.
_sessions_json() {
  local py; py="$(SESSIONS_PY)"
  [[ -f "$py" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  local -x AIMAIL_SESSION_PROJECTS_DIRS="${AIMAIL_SESSION_PROJECTS_DIRS:-}"
  # ⚠ Only auto-discover when NEITHER override is set. A test (or any caller)
  #   that pins the singular AIMAIL_SESSION_PROJECTS_DIR to an isolated fixture
  #   dir must stay fully isolated -- auto-populating the plural var on top of
  #   it would leak THIS BOX's real account project dirs (this very session's
  #   own transcript included) into what is supposed to be a closed fixture.
  if [[ -z "$AIMAIL_SESSION_PROJECTS_DIRS" && -z "${AIMAIL_SESSION_PROJECTS_DIR:-}" ]]; then
    AIMAIL_SESSION_PROJECTS_DIRS="$(_sessions_all_account_projects_dirs)"
  fi
  _sessions_collect | cut -f1-3 | python3 "$py" 2>/dev/null
}

# ─── The dashboard ───────────────────────────────────────────────────────────
sessions_report() {
  local want_json=0 do_prune=0
  local -a filter=()
  local a
  for a in "$@"; do
    case "$a" in
      --json)  want_json=1 ;;
      --prune) do_prune=1 ;;
      -*)      refused "unknown option '$a' for 'aimail sessions'" \
                 "Try: aimail sessions [seat…] [--json] [--prune]" ;;
      *)       filter+=("$(seat_resolve "$a")") || exit $? ;;
    esac
  done

  local json; json="$(_sessions_json)"
  [[ -n "$json" ]] || unmeasurable \
    "session liveness could not be measured (no python3, or $(SESSIONS_PY) is missing)" \
    "This is NOT 'every session is fine' — nothing was read." \
    "Until it is fixed, 'aimail fleet' remains a PER-SEAT view only."

  if (( want_json )); then printf '%s\n' "$json"; return 0; fi

  local store_map; store_map="$(_sessions_collect)"
  printf '%s' "$json" | AIMAIL_SESSIONS_FILTER="${filter[*]:-}" \
    AIMAIL_SESSIONS_STORES="$store_map" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
flt = [s for s in os.environ.get("AIMAIL_SESSIONS_FILTER", "").split() if s]
stores = {}
for line in os.environ.get("AIMAIL_SESSIONS_STORES", "").splitlines():
    p = line.split("\t")
    if len(p) >= 4:
        stores[p[0]] = p[3]

rows = [s for s in d["sessions"] if not flt or s["seat"] in flt]
live = [s for s in rows if s["state"] in ("ARMED", "WORKING", "UNARMED")]
act  = [s for s in rows if s["state"] in ("UNARMED", "ORPHANED", "DEAD")]
stale = [s for s in rows if s["state"] == "STALE"]
unk  = [s for s in rows if s["state"] == "UNKNOWN"]

if not d["transcripts_measurable"]:
    print("⚠ NO TRANSCRIPT DIRECTORY at %s — every row below is judged on the"
          % d["projects_dir"])
    print("  process table alone, so an idle-but-live session may read DEAD.")
    print()

print("%-16s %-10s %-9s %-11s %-7s %s"
      % ("SEAT", "SESSION", "STATE", "TRANSCRIPT", "POLLER", "WHAT IT MEANS"))
print("─" * 108)

def dur(s):
    if s is None: return "—"
    if s < 90: return "%ds" % s
    if s < 5400: return "%dm" % (s // 60)
    if s < 172800: return "%dh" % (s // 3600)
    return "%dd" % (s // 86400)

MEANING = {
 "ARMED":    "alive AND reachable — mail will wake it",
 "WORKING":  "alive, mid-turn. Pollerless right now is NORMAL — ⛔ do not nudge",
 "UNARMED":  "⚠ alive but DEAF — no poller; mail cannot reach it",
 "ORPHANED": "⚠ poller with no session — it will eat a wake nobody gets",
 "DEAD":     "⛔ gone — ONLY state that needs a human to restart it",
 "STALE":    "historical noise — not a session, does not count",
 "UNKNOWN":  "not measurable — NOT a claim that it is dead",
}
# Stale rows last and collapsed: they are the bulk of the file and the whole
# point is that a reader never has to sift them again.
order = {"DEAD":0,"ORPHANED":1,"UNARMED":2,"ARMED":3,"WORKING":4,"UNKNOWN":5,"STALE":6}
for s in sorted(rows, key=lambda r: (order.get(r["state"],9), r["seat"], r["sid"])):
    if s["state"] == "STALE":
        continue
    pol = ",".join(str(p["pid"]) for p in s["pollers"]) or "—"
    print("%-16s %-10s %-9s %-11s %-7s %s"
          % (s["seat"], s["sid"][:8], s["state"], dur(s["transcript_age"]),
             pol, MEANING.get(s["state"], "")))
    if s["poller_seat_mismatch"]:
        print("%-16s %-10s ⚠ registered to \x27%s\x27 but its poller is on \x27%s\x27 — its Stop"
              % ("", "", s["seat"], s["pollers"][0]["seat"]))
        print("%-16s %-10s   guard checks one seat while its mail comes from another."
              % ("", ""))
    if len(s["pollers"]) > 1:
        print("%-16s %-10s ⚠ %d pollers armed for ONE session — each exits on the same"
              % ("", "", len(s["pollers"])))
        print("%-16s %-10s   delivery, so all but one are wasted wakes." % ("", ""))

print()
print("CONCURRENT LIVE SESSIONS PER SEAT (the number a seat-name count gets wrong):")
if d["live_by_seat"]:
    for seat in sorted(d["live_by_seat"]):
        if flt and seat not in flt: continue
        n = d["live_by_seat"][seat]
        flag = "   ⚠ more than one session is answering this seat" if n > 1 else ""
        print("  %-16s %d%s" % (seat, n, flag))
else:
    print("  (none)")

if stale:
    seats = {}
    for s in stale: seats[s["seat"]] = seats.get(s["seat"], 0) + 1
    print()
    print("%d STALE registration(s) hidden above — sessions that ended, never pruned:"
          % len(stale))
    print("  " + "  ".join("%s×%d" % (k, v) for k, v in sorted(seats.items())))
    if d.get("prune_safe", True):
        print("  These do NOT count as sessions. Remove them:  aimail sessions --prune")
    else:
        print("  ⛔ NOT PRUNABLE RIGHT NOW — see the unattributed process warning below.")

# ⛔⛔ SURFACED ON EVERY RUN, not only when someone tries to prune. This is the
#   one condition under which the whole report has a hole in it, and a hole that
#   only announces itself at deletion time is a hole nobody knows they have.
if d.get("unattributed_claude"):
    print()
    print("⚠ %d CLAUDE PROCESS(ES) THIS REPORT CANNOT ATTRIBUTE TO A SESSION:"
          % len(d["unattributed_claude"]))
    for u in d["unattributed_claude"]:
        print("    pid %-8s %s" % (u["pid"], u["cmd"]))
    print("  A session that was started FRESH and is sitting IDLE carries no")
    print("  --resume in its cmdline and no CLAUDE_CODE_SESSION_ID in its own")
    print("  environ (only its children do, and an idle one has none). So each")
    print("  process above MIGHT own one of the STALE registrations, and nothing")
    print("  readable from outside it can say which.")
    print("  ⇒ Rows above are still correct. --prune REFUSES while this list is")
    # WHY \x27 AND NOT A LITERAL APOSTROPHE ANYWHERE IN THIS BLOCK, INCLUDING IN
    # COMMENTS: the whole block is a single-quoted `python3 -c` argument, so one
    # bare apostrophe closes the shell string and every line after it is parsed
    # as shell. It cost a suite run to find, and then a second one, because the
    # comment first written to explain the rule itself contained one.
    print("    non-empty, because deleting the wrong one makes that session\x27s")
    print("    Stop hook allow-unregistered forever — silently, permanently.")

if unk:
    print()
    print("%d registration(s) UNMEASURABLE (no transcript found, too recent to"
          % len(unk))
    print("  call abandoned). Reported, never pruned, never counted as dead:")
    for s in unk:
        print("  %-16s %s" % (s["seat"], s["sid"]))

if d["unregistered_live"]:
    print()
    print("⚠ LIVE SESSION(S) WITH NO REGISTRATION IN ANY STORE:")
    print("  A Stop hook cannot enforce anything for these — it fires")
    print("  allow-unregistered every time, silently, forever (the 2026-09-03 case).")
    for u in d["unregistered_live"]:
        print("  %s  polling=%s  transcript=%s ago"
              % (u["sid"], ",".join(u["polling"]) or "nothing", dur(u["transcript_age"])))

if d["untracked_pollers"]:
    print()
    print("⚠ UNTRACKED POLLER PROCESS(ES) — running, but not descended from any")
    print("  live session, so an exit wakes nobody:")
    for p in d["untracked_pollers"]:
        print("  pid %-8s seat=%-14s session=%s" % (p["pid"], p["seat"], p["sid"] or "unknown"))

print()
print("HOW TO READ THIS — the distinctions the per-seat view cannot make:")
print("  WORKING is not down. The poller exits on delivery BY DESIGN, so a")
print("  session that is genuinely busy is pollerless for part of every cycle.")
print("  Its transcript is the proof it is alive; its poller is not.")
print()
print("  DEAD is the only row that needs a human. STALE rows are not sessions at")
print("  all — they are files left by sessions that ended normally days ago.")
print()
print("  Windows: active=%dm, stale-after=%dh (AIMAIL_SESSION_ACTIVE_WINDOW,"
      % (d["active_window"] // 60, d["stale_after"] // 3600))
print("  AIMAIL_SESSION_STALE_AFTER).")
print()
print("%d live, %d needing attention, %d stale, %d unmeasurable, of %d registration(s)."
      % (len(live), len(act), len(stale), len(unk), len(rows)))
'
  local rc=$?

  if (( do_prune )); then
    echo
    sessions_prune
    return $?
  fi
  return $rc
}

# ─── context — how large is each seat's LIVE session, right now ─────────────
#
# ⭐⭐ WHY THIS EXISTS (owner's ask, 2026-09-23): fleet cost is ~all cache
#   reads -- every turn re-reads the whole context, so a seat sitting at
#   800k+ tokens costs roughly double what one at 400k does, every single
#   turn, independent of how much real work either is doing. The fix
#   (`/autocompact <tokens>`, or the account's own settings.json
#   `autoCompactWindow`) already applies live; this is the missing SEEING
#   half -- which seats are large, read from their own transcripts, never
#   estimated. See lib/context_readout.py's own header for the exact
#   token-field arithmetic and why the tail-only read is safe.
#
# ⚠ ONLY LIVE SESSIONS (ARMED/WORKING/UNARMED) are read -- a STALE or DEAD
#   session's transcript is history, not a cost anyone is currently paying,
#   and reading it would report a number nobody can act on (there is no
#   process to resume with a lower cap).
CONTEXT_READOUT_PY() { echo "$AIMAIL_LIB/context_readout.py"; }

context_report() {
  local want_json=0
  local -a filter=()
  local a
  for a in "$@"; do
    case "$a" in
      --json)  want_json=1 ;;
      -*)      refused "unknown option '$a' for 'aimail context'" \
                 "Try: aimail context [seat…] [--json]" ;;
      *)       filter+=("$(seat_resolve "$a")") || exit $? ;;
    esac
  done

  local json; json="$(_sessions_json)"
  [[ -n "$json" ]] || unmeasurable \
    "session liveness could not be measured (no python3, or $(SESSIONS_PY) is missing)" \
    "Without it there is no live-session list to read a context size for."

  local py; py="$(CONTEXT_READOUT_PY)"
  [[ -f "$py" ]] || unmeasurable \
    "context_readout.py is missing at $py" \
    "The context-size reading cannot run without it."

  # sid \t seat \t transcript \t account \t age_s, ONE row per seat, fed
  # straight to context_readout.py's own stdin contract (same TSV shape
  # session_liveness.py itself takes, extended with two trailing columns it
  # already ignores if absent -- see context_readout.py's own comment).
  #
  # ⛔⛔ THE BUG THIS REPLACES (2026-09-24, assistant): a seat can carry MORE
  #   THAN ONE live-classified session at once (a per-account twin, or a prior
  #   registration nobody pruned) and the old version below emitted EVERY one
  #   of them, keyed only by sid in context_readout.py's own output dict --
  #   nothing here ever picked ONE per seat. `aimail context` reported a
  #   STOPPED sibling session's stale number for a seat whose real, live
  #   session sat right next to it in the same JSON, because whichever row
  #   happened to be built LAST won no reduction at all was applied.
  #   `better()` below picks the session that ACTUALLY IS the seat right now:
  #   a real OS process outranks one with none, then the freshest transcript
  #   write, then (if both are silent) the newest registration -- never
  #   registration file ORDER, which is a directory glob, not a timeline.
  local tsv; tsv="$(printf '%s' "$json" | AIMAIL_CONTEXT_FILTER="${filter[*]:-}" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
flt = [s for s in os.environ.get("AIMAIL_CONTEXT_FILTER", "").split() if s]
LIVE = ("ARMED", "WORKING", "UNARMED")

def better(a, b):
    a_proc, b_proc = a.get("proc_pid") is not None, b.get("proc_pid") is not None
    if a_proc != b_proc:
        return a_proc
    a_age, b_age = a.get("transcript_age"), b.get("transcript_age")
    if a_age is not None or b_age is not None:
        if a_age is None:
            return False
        if b_age is None:
            return True
        if a_age != b_age:
            return a_age < b_age
    return (a.get("registered_epoch") or 0) > (b.get("registered_epoch") or 0)

best = {}
for s in d["sessions"]:
    if s["state"] not in LIVE:
        continue
    if flt and s["seat"] not in flt:
        continue
    seat = s["seat"]
    if seat not in best or better(s, best[seat]):
        best[seat] = s
for s in best.values():
    age = s.get("transcript_age")
    print("%s\t%s\t%s\t%s\t%s" % (
        s["sid"], s["seat"], s["transcript"] or "",
        s.get("account") or "", "" if age is None else age))
')"

  local usage_json="{}"
  if [[ -n "$tsv" ]]; then
    usage_json="$(printf '%s\n' "$tsv" | python3 "$py")"
  fi

  if (( want_json )); then printf '%s\n' "$usage_json"; return 0; fi

  printf '%s' "$usage_json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
rows = sorted(d.values(), key=lambda r: (-(r.get("context_tokens") or -1), r.get("seat") or ""))
if not rows:
    print("(no live session matched)")
    sys.exit(0)

def age_str(a):
    if a is None:
        return "?"
    if a < 90: return "%ds" % a
    if a < 90 * 60: return "%dm" % (a // 60)
    if a < 48 * 3600: return "%dh" % (a // 3600)
    return "%dd" % (a // 86400)

print("%-16s %-10s %-10s %6s   %s" % ("SEAT", "ACCOUNT", "SESSION", "AGE", "CONTEXT / READING"))
print("-" * 90)
for r in rows:
    seat = r.get("seat") or "?"
    acct = r.get("account") or "?"
    sid = (r.get("sid") or "?")[:8]
    age = age_str(r.get("age_s"))
    ct = r.get("context_tokens")
    if ct is None:
        print("%-16s %-10s %-10s %6s   unmeasurable (no real assistant turn found in its transcript)"
              % (seat, acct, sid, age))
    else:
        print("%-16s %-10s %-10s %6s   %9dk  input=%d cache_creation=%d cache_read=%d"
              % (seat, acct, sid, age, ct // 1000, r.get("input_tokens", 0),
                 r.get("cache_creation_input_tokens", 0),
                 r.get("cache_read_input_tokens", 0)))
'
}

# ─── context --settings — does every known account have autoCompactWindow set ─
#
# ⚠ REPORTS ONLY, NEVER WRITES. Setting the value is a per-account decision
#   (which cap, whether to override a specific seat) that stays with whoever
#   owns that account's settings.json; this only names which accounts are
#   still silently defaulted so nobody has to open each one by hand to find
#   out.
context_settings_check() {
  { source "$AIMAIL_LIB/placement.sh"; source "$AIMAIL_LIB/budget.sh"; } 2>/dev/null || true
  command -v _pl_accounts >/dev/null 2>&1 || unmeasurable \
    "cannot enumerate accounts (_pl_accounts unavailable)" \
    "lib/placement.sh did not load."

  printf '%-14s %-9s %s\n' ACCOUNT PRESENT VALUE
  printf -- '-%.0s' {1..50}; echo
  local acct dir settings has val
  while IFS= read -r acct; do
    [[ -n "$acct" ]] || continue
    dir="$(ACCOUNT_CONFIG_DIR "$acct")"
    settings="$dir/settings.json"
    if [[ ! -f "$settings" ]]; then
      printf '%-14s %-9s %s\n' "$acct" "NO FILE" "$settings does not exist"
      continue
    fi
    val="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception as e:
    print("UNREADABLE:%s" % e)
    sys.exit(0)
v = d.get("autoCompactWindow")
print("MISSING" if v is None else str(v))
' "$settings" 2>/dev/null)"
    if [[ "$val" == "MISSING" ]]; then
      printf '%-14s %-9s %s\n' "$acct" "NO" "-"
    elif [[ "$val" == UNREADABLE:* ]]; then
      printf '%-14s %-9s %s\n' "$acct" "?" "${val#UNREADABLE:}"
    else
      printf '%-14s %-9s %s\n' "$acct" "yes" "$val"
    fi
  done < <(_pl_accounts)
}

# ─── prune — remove ONLY registrations proven to belong to ended sessions ────
#
# ⛔⛔ THE STANDING WARNING THIS HAD TO ANSWER, verbatim from poller_guard.sh:
#   "DO NOT 'FIX' THIS BY PRUNING STALE ROWS. A wrong prune de-registers a LIVE
#    session … The risk is asymmetric: a stale row misleads, a bad prune wedges."
#   That warning is correct, and it is an argument against pruning on a GUESS —
#   which is all the old code had, since it could not tell a live session from a
#   dead one at all. It is not an argument against pruning on EVIDENCE.
#
# ⇒ Three independent conditions must ALL hold before a file is removed, and any
#   one of them being unmeasurable aborts that row:
#     1. the classifier called it STALE — no `claude --resume=<sid>` process,
#        and no transcript activity inside AIMAIL_SESSION_STALE_AFTER (24h);
#     2. the registration file's own mtime has not changed since the scan —
#        `register` rewrites it, so a session that re-registered mid-run is
#        skipped rather than raced;
#     3. the file still contains the seat the scan read.
#   DEAD is deliberately NOT prunable: a dead seat is the one thing a human must
#   see, and a report that erases its own evidence is worse than no report.
sessions_prune() {
  local json; json="$(_sessions_json)"
  [[ -n "$json" ]] || unmeasurable \
    "cannot prune: session liveness is unmeasurable" \
    "Nothing was removed. An unmeasurable session must never round to 'deletable'."

  local stores; stores="$(_sessions_collect)"

  # ⛔⛔ THE FAIL-CLOSED GATE (fable, design review 2026-09-06, before this ever
  #   ran destructively). An IDLE, NEVER-RESUMED session is invisible to every
  #   signal the classifier has: no `--resume` in its own cmdline, and no child
  #   carrying CLAUDE_CODE_SESSION_ID to bind through. MEASURED: 9 live claude
  #   processes on this box, 8 attributable, exactly 1 not.
  #   ⇒ Such a session's registration ages to STALE like any abandoned one, and
  #     deleting it makes its Stop hook `allow-unregistered` FOREVER — a silent
  #     permanent pass-through. Nothing about that state looks wrong afterwards,
  #     which is what makes it worse than a crash.
  #   ⇒ While ANY claude process is unattributed, we cannot say WHICH stale row
  #     might be its registration. So the whole operation refuses. Not "skip the
  #     risky ones" — we cannot identify the risky ones; that is the point.
  # ⚠ GATED ON THERE BEING SOMETHING TO DELETE. With zero stale candidates prune
  #   is a no-op, and refusing a no-op would train the reader to pass a --force
  #   they do not need. Refuse only when the refusal is actually protecting
  #   something.
  local n_unattr n_stale
  n_unattr="$(printf '%s' "$json" | python3 -c \
    'import json,sys; print(len(json.load(sys.stdin)["unattributed_claude"]))' 2>/dev/null || echo 0)"
  n_stale="$(printf '%s' "$json" | python3 -c \
    'import json,sys; print(sum(1 for s in json.load(sys.stdin)["sessions"] if s["state"]=="STALE"))' 2>/dev/null || echo 0)"
  if (( n_unattr > 0 )) && (( n_stale > 0 )); then
    # The PIDs go to stderr alongside the refusal, because "there is an
    # unattributable process" is not actionable without saying which.
    printf '%s' "$json" | python3 -c '
import json, sys
for u in json.load(sys.stdin)["unattributed_claude"]:
    print("   unattributed claude pid %-8s %s" % (u["pid"], u["cmd"]))
' >&2 2>/dev/null
    unmeasurable \
      "cannot prove staleness while an unattributed live session exists ($n_unattr claude process(es), $n_stale stale candidate(s))" \
      "Nothing was removed." \
      "An idle session that was never RESUMED carries no --resume in its cmdline and" \
      "no CLAUDE_CODE_SESSION_ID in its own environ (only its children do, and an idle" \
      "session has none). It is indistinguishable from an abandoned registration, and" \
      "deleting the wrong one makes that session's Stop hook allow-unregistered forever." \
      "  ⇒ Close or resume the process(es) listed above, then prune." \
      "  ⇒ Or check by hand: aimail sessions   (the row is not there — that is the problem)"
  fi
  local -a targets=()
  while IFS= read -r line; do [[ -n "$line" ]] && targets+=("$line"); done < <(
    printf '%s' "$json" | AIMAIL_SESSIONS_STORES="$stores" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
stores = {}
for line in os.environ.get("AIMAIL_SESSIONS_STORES", "").splitlines():
    p = line.split("\t")
    if len(p) >= 4:
        stores[p[0]] = (p[1], p[2], p[3])
for s in d["sessions"]:
    if s["state"] != "STALE":
        continue
    st = stores.get(s["sid"])
    if not st:
        continue
    seat, mtime, path = st
    print("\t".join([s["sid"], seat, mtime, path]))
')

  if (( ${#targets[@]} == 0 )); then
    ok "prune: 0 stale registration(s) — nothing to remove"
    return 0
  fi

  local removed=0 skipped=0 line sid seat mtime path now_mtime now_seat
  for line in "${targets[@]}"; do
    IFS=$'\t' read -r sid seat mtime path <<<"$line"
    [[ -f "$path" ]] || { skipped=$((skipped+1)); continue; }
    now_mtime="$(stat -c %Y "$path" 2>/dev/null || echo 'x')"
    now_seat="$(cat "$path" 2>/dev/null)"
    if [[ "$now_mtime" != "$mtime" || "$now_seat" != "$seat" ]]; then
      warn "prune: SKIPPED $sid — it changed under us (re-registered mid-run)"
      skipped=$((skipped+1)); continue
    fi
    if rm -f "$path" 2>/dev/null; then
      info "  pruned  $seat  $sid"
      removed=$((removed+1))
    else
      warn "prune: could not remove $path"
      skipped=$((skipped+1))
    fi
  done
  ok "prune: removed $removed stale registration(s), skipped $skipped, of ${#targets[@]} candidate(s)"
  info "  Only STALE rows are ever removed. DEAD sessions are kept on purpose —"
  info "  a dead seat is the one finding a human still has to see."
  return 0
}

# ─── selftest — the classifier's own arms, against a fixture process table ───
# ⛔ EVERY ARM DRIVES THE REAL session_liveness.py. The fixture replaces only its
#   INPUTS (a synthetic /proc table and a synthetic transcript directory), never
#   its logic — a hand-copied rule in a test passes while the real code is
#   broken, which is how this fleet's last three guard bugs survived review.
sessions_selftest() {
  local py; py="$(SESSIONS_PY)"
  local t; t="$(mktemp -d)"
  local pass=0 fail=0 now; now="$(date +%s)"
  local PROJ="$t/projects/slug"; mkdir -p "$PROJ"

  _t() { if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; pass=$((pass+1));
         else echo "  FAIL  $1 (expected '$3', got '$2')"; fail=$((fail+1)); fi; }
  _state() {  # _state <sid> ; reads $t/procs and $PROJ
    printf '%s\tseatx\t%s\n' "$1" "${2:-$now}" \
      | AIMAIL_SESSION_FAKE_PROCS="$t/procs" \
        AIMAIL_SESSION_PROJECTS_DIR="$t/projects" \
        AIMAIL_SESSION_FAKE_NOW="$now" \
        python3 "$py" 2>/dev/null \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["sessions"][0]["state"] if d["sessions"] else "NONE")'
  }
  _tr() { touch -d "@$(( now - $2 ))" "$PROJ/$1.jsonl"; }

  echo "sessions.sh selftest (fixtures under $t)"

  # A live claude process for SID-AAAA, with a harness-tracked poller under it.
  # 100 = claude, 101 = the /bin/bash -c wrapper, 102 = the poller itself.
  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
101	100	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll seatx'	SID-AAAA
102	101	bash /tmp/aimail-poll.X/bin/aimail poll seatx	SID-AAAA
EOF
  _tr SID-AAAA 5
  _t "alive session + tracked poller -> ARMED" "$(_state SID-AAAA)" "ARMED"

  # ① THE ARM FAILING FIRST — the exact false alarm. Same live session, poller
  #    gone (it exited on delivery, as designed). It must NOT read as anything
  #    a human should act on.
  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
EOF
  _t "alive session, poller exited on delivery -> WORKING (not DEAD/STALLED)" \
     "$(_state SID-AAAA)" "WORKING"

  # ③ …and the other direction: transcript quiet, process alive -> alive but deaf.
  _tr SID-AAAA 4000
  _t "alive process, transcript quiet 66m, no poller -> UNARMED (deaf, not dead)" \
     "$(_state SID-AAAA)" "UNARMED"

  # ② POSITIVE CONTROL FOR 'DEAD' — no process at all, quiet inside the horizon.
  : > "$t/procs"
  _t "no process, transcript quiet 66m -> DEAD (the one actionable state)" \
     "$(_state SID-AAAA)" "DEAD"

  # …and the same absent process, but the session ended days ago -> noise.
  _tr SID-AAAA $(( 3 * 86400 ))
  _t "no process, transcript 3d old -> STALE (noise, not a dead seat)" \
     "$(_state SID-AAAA)" "STALE"

  # ⛔ THE ONE THAT MUST NEVER BE PRUNED: unmeasurable is not dead.
  rm -f "$PROJ/SID-AAAA.jsonl"
  _t "no transcript at all, fresh registration -> UNKNOWN, never DEAD" \
     "$(_state SID-AAAA "$now")" "UNKNOWN"
  _t "no transcript at all, registration 3d old -> STALE" \
     "$(_state SID-AAAA $(( now - 3 * 86400 )))" "STALE"

  # ⛔⛔ THE CORE REGRESSION — a poller for the SEAT does not make a SESSION
  #    live. This is the 8-rows-one-poller bug in its smallest form: SID-BBBB is
  #    dead, but SID-AAAA is alive and polling the very same seat. The old per-seat
  #    check reported LIVE for both.
  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
101	100	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll seatx'	SID-AAAA
102	101	bash /tmp/aimail-poll.X/bin/aimail poll seatx	SID-AAAA
EOF
  _tr SID-AAAA 5
  _tr SID-BBBB 4000
  _t "SEAT has a live poller but THIS session is gone -> DEAD, not LIVE" \
     "$(_state SID-BBBB)" "DEAD"
  _t "…and the session that actually owns that poller still reads ARMED" \
     "$(_state SID-AAAA)" "ARMED"

  # ⛔ An ORPHANED poller: the process is there, its session is not. Ancestry
  #   (reparented to init) is what separates this from a tracked one; measured
  #   live on this box, where three abandoned sessions' workers were still
  #   running under systemd carrying their dead owners' session ids.
  cat > "$t/procs" <<EOF
102	1	bash /tmp/aimail-poll.X/bin/aimail poll seatx	SID-BBBB
EOF
  _t "poller alive but reparented away from its session -> ORPHANED" \
     "$(_state SID-BBBB)" "ORPHANED"

  # ⭐ A FRESH session (never resumed) has NO --resume to match on. It must
  #   still read alive, bound through a child that carries the id AND whose
  #   ancestry reaches the claude process.
  cat > "$t/procs" <<EOF
200	1	/usr/bin/claude --verbose
201	200	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll seatx'	SID-CCCC
202	201	bash /tmp/aimail-poll.Y/bin/aimail poll seatx	SID-CCCC
EOF
  _tr SID-CCCC 30
  _t "fresh session with no --resume, bound via child ancestry -> ARMED" \
     "$(_state SID-CCCC)" "ARMED"
  # …and the negative control: the same env var on a process that does NOT
  #   descend from a live claude must not resurrect the session.
  cat > "$t/procs" <<EOF
300	1	/usr/bin/python3 leftover-worker.py	SID-DDDD
EOF
  _tr SID-DDDD 4000
  _t "orphan worker carrying a dead session's id -> DEAD, not alive" \
     "$(_state SID-DDDD)" "DEAD"

  # ⛔ The wrapper must not be counted as a poller in its own right (T-351: one
  #   healthy poller matches a loose pattern twice, so a count cannot tell one
  #   from two). Assert the POLLER LIST length, not just the state.
  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
101	100	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll seatx'	SID-AAAA
102	101	bash /tmp/aimail-poll.X/bin/aimail poll seatx	SID-AAAA
EOF
  _tr SID-AAAA 5
  local n
  n="$(printf 'SID-AAAA\tseatx\t%s\n' "$now" \
       | AIMAIL_SESSION_FAKE_PROCS="$t/procs" AIMAIL_SESSION_PROJECTS_DIR="$t/projects" \
         AIMAIL_SESSION_FAKE_NOW="$now" python3 "$py" 2>/dev/null \
       | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"][0]["pollers"]))')"
  _t "wrapper + child counts as ONE poller, not two" "$n" "1"

  # ⛔⛔ THE SELF-MATCH REGRESSION, and it is here because this file COMMITTED it
  #   and a live run caught it inside a minute. The legacy `poller_<seat>.sh`
  #   alternative, unanchored, reads `bash .claude/hooks/poller_guard.sh status`
  #   as a poller for a seat called `guard` — so the CHECKER counted itself and
  #   attributed its own two processes to the session that ran the check.
  #   poller_guard.sh's own header records three separate bugs of this exact
  #   family; this is the fourth. Both directions are asserted: the guard's
  #   command must NOT register as a poller, and a genuine legacy poller
  #   (no trailing verb) still must.
  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
101	100	bash /home/x/.claude/hooks/poller_guard.sh status	SID-AAAA
102	100	bash /home/x/.claude/hooks/poller_guard.sh hook	SID-AAAA
EOF
  _tr SID-AAAA 5
  local npol
  npol="$(printf 'SID-AAAA\tseatx\t%s\n' "$now" \
        | AIMAIL_SESSION_FAKE_PROCS="$t/procs" AIMAIL_SESSION_PROJECTS_DIR="$t/projects" \
          AIMAIL_SESSION_FAKE_NOW="$now" python3 "$py" 2>/dev/null \
        | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["sessions"][0]["pollers"]))')"
  _t "poller_guard.sh's OWN processes are not counted as pollers" "$npol" "0"
  _t "…and that session reads WORKING (not ARMED off its own checker)" \
     "$(_state SID-AAAA)" "WORKING"

  cat > "$t/procs" <<EOF
100	1	/usr/bin/claude --resume=SID-AAAA --verbose
101	100	/bin/bash -c source snap.sh && eval 'bash /x/poller_seatx.sh'	SID-AAAA
102	101	bash /x/poller_seatx.sh	SID-AAAA
EOF
  _t "a genuine legacy poller_<seat>.sh is still recognised -> ARMED" \
     "$(_state SID-AAAA)" "ARMED"

  rm -rf "$t"
  echo "  ---- $pass passed, $fail failed"
  [[ "$fail" -eq 0 ]]
}
