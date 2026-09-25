#!/usr/bin/env bash
# tests/idle_backlog_sweep.sh — the idle-capacity/unowned-backlog watchdog folded into
# fleet_sweep(): correlates genuine idle seat capacity against a real, aged, unreferenced
# "Status: OPEN, unowned" TODO.md item. Neither signal alone triggers this (see fleet.sh's
# own header comment on idle_backlog_sweep for why); every arm below proves that explicitly.
#
# Follows tests/disk_worktree_sweep.sh's own evidence rules: every rejection/finding arm is
# paired with a clean control, exit codes captured out of pipes, denominator printed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-idlebacklogtest.XXXXXX")"
mkdir -p "$AIMAIL_ROOT/state" "$AIMAIL_ROOT/tmp" "$AIMAIL_ROOT/roles"
STATE_DIR="$AIMAIL_ROOT/state"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/aimail-idlebacklogtest-files.XXXXXX")"
trap 'rm -rf "$AIMAIL_ROOT" "$SCRATCH"' EXIT

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }

echo "── _parse_todo_header_epoch: real date, and this repo's own fuzzy-minute convention ──"
E1="$(_parse_todo_header_epoch '### 🔸 2026-09-21 15:00 — a precise header')"
E2="$(date -d '2026-09-21 15:00' +%s)"
chk "precise HH:MM parses to the exact real epoch" "$E1" "$E2"

E3="$(_parse_todo_header_epoch '### 🔸 2026-09-21 17:3x — a fuzzy-minute header, this repo real convention')"
E4="$(date -d '2026-09-21 17:30' +%s)"
chk "fuzzy 'x' minute floors to the decade (17:3x -> 17:30)" "$E3" "$E4"

chk "a header with no date at all returns nothing" "$(_parse_todo_header_epoch '### not a dated header' 2>/dev/null; echo x)" "x"

echo "── _referenced_in_any_handover: a real token check across every REGISTERED seat's own file ──"
seat_names() { printf 'seat-a\nseat-b\n'; }  # only these two are "registered" for this section
echo "some prose mentioning the widget-registration gap and other things" > "$AIMAIL_ROOT/roles/seat-a.md"
echo "unrelated handover content" > "$AIMAIL_ROOT/roles/seat-b.md"
if _referenced_in_any_handover "widget-registration gap"; then R1=yes; else R1=no; fi
chk "token present in ONE of several handovers is found" "$R1" "yes"
if _referenced_in_any_handover "nothing anywhere mentions this exact phrase"; then R2=yes; else R2=no; fi
chk "token present in NO handover is correctly not found" "$R2" "no"

echo "  a token only in a NON-registered-seat file (a dated archive/one-off note) does not count"
echo "some prose mentioning the stray-archive-token here" > "$AIMAIL_ROOT/roles/seat-a.archive-2026-08-18.md"
if _referenced_in_any_handover "stray-archive-token"; then R5=yes; else R5=no; fi
chk "token present ONLY in a non-registered-seat roles/ file is NOT found" "$R5" "no"

echo "── _unowned_backlog_items: real TODO.md fixture, the exact repo convention ──"
TODO="$SCRATCH/TODO.md"
NOW_TS="$(date +%Y-%m-%d\ %H:%M)"
OLD_TS="$(date -d '3 hours ago' +%Y-%m-%d\ %H:%M)"
RECENT_TS="$(date -d '10 minutes ago' +%Y-%m-%d\ %H:%M)"
cat > "$TODO" << EOF
### 🔸 $OLD_TS — an old, real, unowned item nobody is tracking

Some real ticket text. Status: OPEN, unowned.

### 🔸 $RECENT_TS — a JUST-written unowned item, too fresh to count yet

Real text. Status: OPEN, unowned.

### 🔸 $OLD_TS — an old unowned item, but someone tracks it in a handover

Real text. Status: OPEN, unowned.

### 🔸 $NOW_TS — a normal, owned/closed item

Status: CLOSED, not a finding.

### 🔸 $OLD_TS — cleanup

A short-titled real item. Status: OPEN, unowned.

### 🔸 $OLD_TS — WEEK-AUDIT block with six real unowned sub-items, real repo shape

Sub-item 1. Status: OPEN, unowned.

Sub-item 2. Status: OPEN, unowned.

Sub-item 3. Status: OPEN, unowned.

Sub-item 4. Status: OPEN, unowned.

Sub-item 5. Status: OPEN, unowned.

Sub-item 6. Status: OPEN, unowned.

### 🔸 $OLD_TS — closed-at-end shape: opened unowned, then CLOSED at the end (the 2026-09-22 false positive)

Root cause traced in \`some_probe.py\`. Status: OPEN, unowned — owner architect (traced
the defect, fix built, gate pending at the time of writing).

**Status: CLOSED.** Fix landed \`cd8a07fc9\` (both branches synced), gate GREEN from code-review
(independent re-verification, 73/73), peer-reviewed GREEN.

### 🔸 $OLD_TS — shouted but negated: a CLOSED token inside a still-open paragraph

Real text. Status: OPEN, unowned.

Not CLOSED yet -- still waiting on the gate; LANDED is what the ticket will say once it is.

### 🔸 $OLD_TS — re-opened: resolved first, then opened again, last disposition wins

Status: CLOSED, landed as abc1234.

Regression found the next morning. Status: OPEN, unowned.
EOF
cat > "$AIMAIL_ROOT/roles/tracking-seat.md" << 'EOF'
still working on: an old unowned item, but someone tracks it in a handover -- almost done
EOF
cat > "$AIMAIL_ROOT/roles/other-seat.md" << 'EOF'
doing some cleanup on the side, nothing related
EOF
seat_names() { printf 'tracking-seat\nother-seat\n'; }
AIMAIL_GUARDED_RELEASE_TODOEDIT="$TODO"
BACKLOG_ITEM_AGE_MIN=120
# this block measures the MIRROR (the default: no classifier configured)
unset AIMAIL_TODO_ARCHIVE_TOOL
mapfile -t FOUND < <(_unowned_backlog_items 2>/dev/null)
FOUND_TXT="$(printf '%s\n' "${FOUND[@]}")"

chk "old + unreferenced unowned item IS a finding" \
  "$(grep -c "an old, real, unowned item nobody is tracking" <<<"$FOUND_TXT")" "1"
chk "too-fresh unowned item is NOT a finding (under the age floor)" \
  "$(grep -c "too fresh to count" <<<"$FOUND_TXT")" "0"
chk "old but REFERENCED-in-a-handover item is NOT a finding" \
  "$(grep -c "someone tracks it in a handover" <<<"$FOUND_TXT")" "0"
chk "a normal owned/closed item is never a finding" \
  "$(grep -c "normal, owned" <<<"$FOUND_TXT")" "0"
chk "a short generic title IS still a finding even though a handover happens to contain the word (under the token floor, never suppressed)" \
  "$(grep -c "cleanup (" <<<"$FOUND_TXT")" "1"
chk "a header with SIX unowned sub-lines is ONE finding, not six (fable's real finding, live run against 670d0ac)" \
  "$(grep -c "WEEK-AUDIT block with six real unowned sub-items" <<<"$FOUND_TXT")" "1"
chk "that one finding's own detail names the real sub-line count (6), not a made-up one" \
  "$(grep -c "6 unowned line(s)" <<<"$FOUND_TXT")" "1"
chk "an entry opened unowned and CLOSED at its end is NOT a finding (last disposition wins -- the closed-at-end false positive)" \
  "$(grep -c "closed-at-end shape" <<<"$FOUND_TXT")" "0"
chk "a CLOSED/LANDED token inside a NEGATED paragraph does not resolve the entry (still a finding)" \
  "$(grep -c "shouted but negated" <<<"$FOUND_TXT")" "1"
chk "resolved first, re-opened later -> the later OPEN wins (still a finding)" \
  "$(grep -c "re-opened: resolved first" <<<"$FOUND_TXT")" "1"
chk "exactly 5 real findings (the six-line block counts once; the closed-at-end entry not at all)" "${#FOUND[@]}" "5"
chk "each finding is identity<TAB>display -- the identity field never embeds an age/count" \
  "$(printf '%s\n' "${FOUND[@]}" | grep -c $'\t')" "5"
echo "── _backlog_entry_id: the SAME id the classifier's --classify mode assigns (sha1 of the raw heading line + newline) ──"
H1='### 🔸 2026-09-22 10:2x — wall-thickness bug: record-consistency defect — fix built (platform)'
EXP1="$(printf '%s\n' "$H1" | python3 -c 'import sys,hashlib; print("NARR-"+hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:10])')"
chk "unicode heading (🔸, em dashes) hashes to the tool's own NARR id" "$(_backlog_entry_id "$H1")" "$EXP1"
chk "a heading naming a ticket takes that T-id verbatim (first match)" "$(_backlog_entry_id '### 🔸 2026-09-22 09:00 — T-741 follow-up, see also T-742')" "T-741"
chk "the trailing newline IS part of the hash (stripping it changes the id)" \
  "$( [[ "$(printf '%s' "$H1" | sha1sum | cut -c1-10)" != "${EXP1#NARR-}" ]] && echo differs )" "differs"

echo "── the tool's verdict wins when present; the mirror decides when it is absent ──"
# a fake --classify that calls the FIRST fixture entry resolved (the mirror calls it open) and the
# closed-at-end entry open (the mirror calls it resolved): if the sweep really consults the tool,
# both flip; if it silently fell back, neither does.
mkdir -p "$SCRATCH/tools"
ID_FIRST="$(_backlog_entry_id "$(grep -m1 '^### .*nobody is tracking' "$TODO")")"
ID_CMU="$(_backlog_entry_id "$(grep -m1 '^### .*closed-at-end shape' "$TODO")")"
ID_NEG="$(_backlog_entry_id "$(grep -m1 '^### .*shouted but negated' "$TODO")")"
cat > "$SCRATCH/tools/classifier.py" << PYEOF
import sys
assert sys.argv[1] == "--classify", sys.argv
print("${ID_FIRST}\tresolved\tfake: landed as deadbeef")
print("${ID_CMU}\topen\tfake: reopened")
print("T-999\topen\t")
# the negated-shout entry: emitted TWICE, resolved then open -- the per-id rule says open sticks
print("${ID_NEG}\tresolved\tfake: an earlier block of the same id")
print("${ID_NEG}\topen\tfake: a later block still open")
PYEOF
export AIMAIL_TODO_ARCHIVE_TOOL="$SCRATCH/tools/classifier.py"   # config-only: the sweep never derives a path itself
rm -f "$(_BACKLOG_CLASSIFY_CACHE)" "$SCRATCH/tools/calls"
printf 'open("'"$SCRATCH"'/tools/calls","a").write("x")\n' >> "$SCRATCH/tools/classifier.py"   # count invocations
mapfile -t FOUND2 < <(_unowned_backlog_items 2>"$SCRATCH/sweep.err")
FOUND2_TXT="$(printf '%s\n' "${FOUND2[@]}")"
chk "tool says resolved -> the mirror's 'open' entry is NOT a finding" "$(grep -c "nobody is tracking" <<<"$FOUND2_TXT")" "0"
chk "tool says open -> the mirror's 'resolved' closed-at-end entry IS a finding" "$(grep -c "closed-at-end shape" <<<"$FOUND2_TXT")" "1"
chk "an id the tool lists as resolved AND open reads open (any-open rule) -> still a finding" "$(grep -c "shouted but negated" <<<"$FOUND2_TXT")" "1"
chk "entries the tool does not name keep the mirror's verdict (re-opened entry still a finding)" "$(grep -c "re-opened: resolved first" <<<"$FOUND2_TXT")" "1"
chk "no fallback notice on stderr when the tool answered" "$(grep -c 'built-in mirror' "$SCRATCH/sweep.err")" "0"
chk "the classifier ran exactly once for the first sweep" "$(wc -c < "$SCRATCH/tools/calls" 2>/dev/null || echo 0)" "1"
mapfile -t FOUND2B < <(_unowned_backlog_items 2>/dev/null)
chk "second sweep, TODO unchanged -> the classifier is NOT invoked again (cache on mtime+size)" "$(wc -c < "$SCRATCH/tools/calls")" "1"
chk "…and the cached verdicts give the same findings" "${#FOUND2B[@]}" "${#FOUND2[@]}"
printf '\n### 🔸 %s — appended after the first sweep\n\nText. Status: OPEN, unowned.\n' "$OLD_TS" >> "$TODO"; touch -d '+1 second' "$TODO" 2>/dev/null || true
_unowned_backlog_items >/dev/null 2>&1
chk "TODO changed (size/mtime) -> the classifier runs again" "$(wc -c < "$SCRATCH/tools/calls")" "2"
unset AIMAIL_TODO_ARCHIVE_TOOL
_unowned_backlog_items >/dev/null 2>"$SCRATCH/sweep.err"
chk "AIMAIL_TODO_ARCHIVE_TOOL UNSET (the default) -> mirror, and the sweep SAYS so (stderr)" "$(grep -c 'built-in mirror' "$SCRATCH/sweep.err")" "1"
export AIMAIL_TODO_ARCHIVE_TOOL="$SCRATCH/no-such-tool.py"
_unowned_backlog_items >/dev/null 2>"$SCRATCH/sweep.err"
chk "tool path set but absent -> mirror, said out loud" "$(grep -c 'built-in mirror' "$SCRATCH/sweep.err")" "1"
printf 'import sys; sys.exit(3)\n' > "$SCRATCH/tools/classifier.py"; export AIMAIL_TODO_ARCHIVE_TOOL="$SCRATCH/tools/classifier.py"; rm -f "$(_BACKLOG_CLASSIFY_CACHE)"
mapfile -t FOUND3 < <(_unowned_backlog_items 2>/dev/null)
chk "tool present but FAILING -> mirror verdicts, same 6 findings as without it (5 + the appended entry)" "${#FOUND3[@]}" "6"
export AIMAIL_TODO_ARCHIVE_TOOL="$SCRATCH/no-such-tool.py"

echo "── _backlog_para_disposition: the v5 forms, one paragraph at a time ──"
chk "ALL-CAPS CLOSED token -> resolved" "$(_backlog_para_disposition 'Fix built. CLOSED.')" "resolved"
chk "lower-case 'closed' is an adjective, not a disposition" "$(_backlog_para_disposition 'the closed set of walls')" ""
chk "Status: landed (any case) -> resolved" "$(_backlog_para_disposition '  Status: landed 2026-09-20')" "resolved"
chk "'landed as <sha>' -> resolved" "$(_backlog_para_disposition 'fix landed as 9f3e2a1 on develop')" "resolved"
chk "negation in the same paragraph voids it ('not LANDED yet')" "$(_backlog_para_disposition 'not LANDED yet, waiting on the gate')" ""
chk "'GATE REQUESTED' voids a LANDED claim in the same paragraph" "$(_backlog_para_disposition 'wiring LANDED on develop, non-author gate requested')" ""
chk "the sweep trigger reads open" "$(_backlog_para_disposition 'Real text. Status: OPEN, unowned.')" "open"
chk "prose with neither reads nothing" "$(_backlog_para_disposition 'some discussion of the plan')" ""

echo "── idle_backlog_sweep: BOTH signals required, neither alone triggers it ──"
SENT_COUNT=0
mail_send() { SENT_COUNT=$((SENT_COUNT+1)); return 0; }
seat_exists() { [ "$1" = "assistant" ]; }
info() { :; }; warn() { :; }
IDLE_BACKLOG_ALERT_MIN=20

# Stub the seat/session layer directly rather than a real registry.
seat_names() { printf 'idle-seat\nbusy-seat\n'; }
seat_field() { echo "active"; }  # neither seat retired
# Default: no seat has a live "working" session (never hit the real `claude` binary from a
# test) -- every arm below is otherwise identical to before this stub existed.
_idle_seat_has_live_working_session() { return 1; }

echo "  arm: backlog exists, but NO seat is idle -- must not alert"
poller_state() { printf 'ARMED\tworking\n'; }   # ARMED but...
last_stop() { printf '%s\tstop\n' "$(( $(now_epoch) - 60 ))"; }  # ...only 1 minute idle, under the floor
_unowned_backlog_items() { printf 'a real aged unowned item\n'; }
rm -rf "$AIMAIL_ROOT/state/sweep_alerted"
idle_backlog_sweep
chk "backlog alone (no idle seat past the floor): no alert" "$SENT_COUNT" "0"

echo "  arm: a seat IS idle long enough, but NO real backlog -- must not alert"
last_stop() { printf '%s\tstop\n' "$(( $(now_epoch) - 1800 ))"; }  # 30 min idle now
_unowned_backlog_items() { :; }  # nothing
idle_backlog_sweep
chk "idle seat alone (no real backlog): no alert" "$SENT_COUNT" "0"

echo "  arm: BOTH at once -- this is the actual signal"
_unowned_backlog_items() { printf 'a real aged unowned item\n'; }
idle_backlog_sweep
chk "idle seat AND real backlog together: alerts exactly once" "$SENT_COUNT" "1"

echo "  arm: a seat with an old last_stop but a LIVE 'working' session right now is NOT idle"
echo "  (fable's real finding, peer review of f3df8f4: last_stop only updates on turn-end, so a"
echo "   seat continuously mid-turn reads identical to a genuinely idle one on that signal alone)"
_idle_seat_has_live_working_session() { return 0; }  # every seat that WOULD read idle is mid-turn
rm -rf "$AIMAIL_ROOT/state/sweep_alerted"; SENT_COUNT=0
idle_backlog_sweep
chk "every idle-looking seat is mid-turn (live 'working'): excluded, no alert despite the last_stop floor" "$SENT_COUNT" "0"

_idle_seat_has_live_working_session() { return 1; }  # back to: no live working session anywhere
idle_backlog_sweep
chk "same seats, once no longer mid-turn: correctly idle again, alert fires" "$SENT_COUNT" "1"

echo "  arm: identical pairing again -- dedup, no re-alert"
idle_backlog_sweep
chk "SAME idle+backlog pairing again: does NOT re-alert (dedup)" "$SENT_COUNT" "1"

echo "  arm: the backlog item CHANGES (new title) -- a new finding, re-alerts"
_unowned_backlog_items() { printf 'a DIFFERENT real aged unowned item\n'; }
idle_backlog_sweep
chk "a genuinely NEW backlog item: DOES re-alert" "$SENT_COUNT" "2"

echo "  arm: SAME identity as just alerted, but the DISPLAY text's age-in-minutes now differs"
echo "  (real incident, main, 2026-09-22: the dedup key used to be built from display text,"
echo "   which bakes in an age that increases every tick BY DEFINITION -- an unchanged real"
echo "   backlog item re-alerted on ~every 5-minute cron tick for hours because of this)"
_unowned_backlog_items() { printf 'a DIFFERENT real aged unowned item\ta DIFFERENT real aged unowned item (999m old, 1 unowned line(s), unreferenced in any handover)\n'; }
idle_backlog_sweep
chk "same identity, changed age-in-minutes DISPLAY text only: still dedupes, no re-alert" "$SENT_COUNT" "2"

echo "  arm: SAME backlog item, but a DIFFERENT seat is the one that's idle (real incident,"
echo "  assistant, 2026-09-22, ~25min after the first fix: which seat is idle rotates"
echo "  naturally in a working fleet -- foundation idle at 23:40, main at 00:00/00:05/00:30,"
echo "  librarian at 00:15 -- so keying dedup on the idle-seat SET too meant the SAME unowned"
echo "  backlog item kept re-alerting every time a different seat crossed the idle floor)"
seat_names() { printf 'a-different-idle-seat\n'; }
poller_state() { printf 'ARMED\tworking\n'; }
last_stop() { printf '%s\tstop\n' "$(( $(now_epoch) - 1800 ))"; }
_unowned_backlog_items() { printf 'a DIFFERENT real aged unowned item\ta DIFFERENT real aged unowned item (1050m old, 1 unowned line(s), unreferenced in any handover)\n'; }
idle_backlog_sweep
chk "same backlog item, a DIFFERENT seat is now the idle one: still dedupes, no re-alert" "$SENT_COUNT" "2"

echo "  arm: a retired seat is never counted as idle capacity"
seat_field() { [ "$1" = "idle-seat" ] && echo "retired" || echo "active"; }
seat_names() { printf 'idle-seat\n'; }  # only the (now retired) idle seat exists
rm -rf "$AIMAIL_ROOT/state/sweep_alerted"; SENT_COUNT=0
idle_backlog_sweep
chk "the only idle-looking seat is retired: no alert" "$SENT_COUNT" "0"

echo
echo "── SUMMARY: $PASS passed, $FAIL failed, $((PASS+FAIL)) total ──"
if (( FAIL > 0 )); then
  printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
