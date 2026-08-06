#!/usr/bin/env bash
# tests/run.sh — dependency-free test harness.
#
# ═══ THE EVIDENCE RULES THIS HARNESS ENFORCES ═════════════════════════════════
# These are the fleet's standing rules, encoded rather than written down:
#
#  ① SHOW THE ARM FAILING FIRST. A check that isn't running looks exactly like a
#    check that passes. Every guard here is exercised with an input that MUST
#    trip it.
#
#  ② EVERY REJECTION ARM NEEDS A POSITIVE CONTROL, and the control must use a
#    form the instrument claims to detect. A quiet control may simply not
#    qualify — proving nothing while looking rigorous.
#
#  ③ AND CONTROL THE OTHER DIRECTION TOO. An always-refusing guard never fires
#    on the case it was built for, which is the dangerous direction. So every
#    `refuses` test is paired with an `accepts` test on the nearest valid input.
#
#  ④ PRINT THE DENOMINATOR. The summary reports pass/total, never just failures.
#
#  ⑤ CAPTURE THE EXIT CODE OUT OF ANY PIPE. Nothing here pipes a command whose
#    status is the measurement.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
AIMAIL="$REPO/bin/aimail"

PASS=0; FAIL=0; declare -a FAILURES=()

# Isolated data root per run — the tests can never touch a real mailbox.
# ⚠ The predecessor's test suite once wrote ~190 fabricated rows into the live
#   billing ledger, because the script derived its state path from its own
#   location and offered no override. Isolation here is by construction: the
#   root is an env var the tests set to a temp dir.
export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-test.XXXXXX")"
export AIMAIL_CONFIG=/dev/null
# ⛔ NO NETWORK, AND NO CACHE EXPIRY. A stubbed block must stay stubbed for the
#    whole run; an expiring stub silently becomes a live ccusage call.
export AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
trap 'rm -rf "$AIMAIL_ROOT"' EXIT

_run() { "$AIMAIL" "$@" >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; echo $?; }

# accepts <desc> -- <cmd…>   : must exit 0
accepts() {
  local desc="$1"; shift; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "0" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc)"); printf '  ✖ %s — exit %s\n' "$desc" "$rc"
       sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6; fi
}

# refuses <desc> <expect-substring> -- <cmd…> : must exit 3 AND explain
# ⚠ The substring matters. A test that only asserts "nonzero" passes when the
#   tool fails for an unrelated reason — the guard could be absent entirely.
refuses() {
  local desc="$1" expect="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "3" ]] && grep -qiF -- "$expect" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc, wanted 3 + '$expect')")
    printf '  ✖ %s — exit %s, wanted 3 containing %s\n' "$desc" "$rc" "'$expect'"
    sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
  fi
}

# unmeasurable_test <desc> <expect> -- <cmd…> : must exit 4, distinctly from 3.
# ⚠ 3 and 4 are deliberately different exits. "You asked wrongly" (REFUSED) and
#   "I could not measure" (UNMEASURABLE) are different claims, and collapsing
#   them is how "unmeasurable" ends up rendering as "clean".
unmeasurable_test() {
  local desc="$1" expect="$2"; shift 2; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "4" ]] && grep -qiF -- "$expect" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc, wanted 4 + '$expect')")
    printf '  ✖ %s — exit %s, wanted 4 containing %s\n' "$desc" "$rc" "'$expect'"
    sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
  fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ══════════════════════════════════════════════════════════════════════════════
section "registry — the address space"
accepts "register a seat"                      -- seat add main "General work"
accepts "register a seat with an alias"        -- seat add metrics-report "Metrics" "metrics,metr"
accepts "list seats"                           -- seat list

# ① the arm failing first — the exact defect that motivated the registry
refuses "unregistered name is refused" "not a registered seat" \
  -- send --to metrcs --from main --subject x --body-file /etc/hostname
# ③ …and the other direction: the near-miss real name still works
accepts "the real seat still accepts mail" \
  -- send --to metrics-report --from main --subject x --body-file /etc/hostname
# ② positive control in the form the tool claims to detect: an ALIAS resolves
accepts "a registered alias resolves"          -- seat resolve metrics
refuses "an invalid seat name is refused" "not a valid seat name" -- seat add "ALL:"
accepts "register a seat that will be retired"  -- seat add oldseat "To be retired"
accepts "retire it, naming a successor"         -- seat retire oldseat main
refuses "a retired seat refuses mail" "RETIRED" \
  -- send --to oldseat --from main --subject x --body-file /etc/hostname

section "registry — AR-04: concurrent add/retire must lose nothing"
# ⛔⛔ THE DEFECT: `seat_add` was check-then-append; `seat_retire` was a
#   WHOLE-FILE read-modify-write, with no coordination between them. A retire
#   interleaved with an add replaces the file from a snapshot taken BEFORE the
#   add's row landed, silently discarding it; two concurrent retires each
#   compute from the same stale snapshot and whichever writes last wins,
#   discarding the other's retirement entirely. Reproduce the review's own
#   shape: 12 retires racing 12 NEW concurrent adds. Real background
#   processes, not a stub — this is exactly the class of defect a green suite
#   using stubbed state cannot see.
for i in $(seq 1 12); do "$AIMAIL" seat add "ar04r$i" "seed" >/dev/null 2>&1; done
for i in $(seq 1 12); do "$AIMAIL" seat retire "ar04r$i" >/dev/null 2>&1 & done
for i in $(seq 1 12); do "$AIMAIL" seat add "concurrent$i" "concurrent add" >/dev/null 2>&1 & done
wait
AR04_ROWS="$(grep -vE '^\s*(#|$)' "$AIMAIL_ROOT/seats.tsv")"
AR04_RETIRED=$(printf '%s\n' "$AR04_ROWS" | awk -F'\t' '$1 ~ /^ar04r/ && $2=="retired"' | wc -l)
AR04_NEW=$(printf '%s\n' "$AR04_ROWS" | awk -F'\t' '$1 ~ /^concurrent/' | wc -l)
if (( AR04_RETIRED == 12 )); then
  PASS=$((PASS+1)); printf '  ✔ all 12 concurrent retires landed (0 lost to the race)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-04: only $AR04_RETIRED/12 retires landed")
  printf '  ✖ AR-04: only %s/12 retires landed — rows lost to the race\n' "$AR04_RETIRED"
fi
if (( AR04_NEW == 12 )); then
  PASS=$((PASS+1)); printf '  ✔ all 12 concurrent adds landed (0 lost to the race)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-04: only $AR04_NEW/12 concurrent adds landed")
  printf '  ✖ AR-04: only %s/12 concurrent adds landed — rows lost to the race\n' "$AR04_NEW"
fi

section "registry — a refusal must name the seat you meant"
# ⚠ A guard that refuses without naming the alternative is a wall, not a guard.
#   `metrcs` -> `metrics-report` is edit distance 8 against the full name,
#   so a naive threshold misses the exact case this registry was built for.
accepts "register the seats the real typos target"  -- seat add review "Review"
for t in metrcs reveiw; do
  rc="$(_run seat resolve "$t")"
  want="$([[ $t == metrcs ]] && echo metrics-report || echo review)"
  if [[ "$rc" == "3" ]] && grep -qF "$want" "$AIMAIL_ROOT/.err"; then
    PASS=$((PASS+1)); printf '  ✔ %s refuses and suggests %s\n' "$t" "$want"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$t did not suggest $want")
    printf '  ✖ %s did not suggest %s (exit %s)\n' "$t" "$want" "$rc"
  fi
done
# ③ the other direction — the suggester must NOT match everything, or a
#    suggestion carries no information at all.
rc="$(_run seat resolve totallyunrelated)"
if [[ "$rc" == "3" ]] && grep -qF "no similar registered names" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ an unrelated name suggests nothing\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("suggester matched an unrelated name")
  printf '  ✖ suggester matched an unrelated name\n'
fi

section "send — the body is never touched by the shell"
BODY="$AIMAIL_ROOT/body.md"
printf '# real body\n\n```\ncode\n```\n' > "$BODY"
accepts "a balanced body sends"                -- send --to main --from main --subject "ok" --body-file "$BODY"

# ① FI-06: the corruption signature — an unclosed fence
printf '# gutted\n\n```\ncode that never closes\n' > "$AIMAIL_ROOT/bad.md"
refuses "unbalanced code fence is refused" "UNCLOSED" \
  -- send --to main --from main --subject "bad" --body-file "$AIMAIL_ROOT/bad.md"
# ③ …but --force still allows it, so the guard cannot become a permanent block
accepts "--force overrides the fence check" \
  -- send --to main --from main --subject "bad" --body-file "$AIMAIL_ROOT/bad.md" --force

refuses "--body string argument does not exist" "no --body string argument" \
  -- send --to main --from main --subject x --body "inline"
refuses "a caller-supplied timestamp is refused" "may not supply a timestamp" \
  -- send --to main --from main --subject x --body-file "$BODY" --date 2026-01-01
refuses "missing --from is refused" "--from is required" \
  -- send --to main --subject x --body-file "$BODY"
refuses "an unknown flag is refused, not ignored" "unknown argument" \
  -- send --to main --from main --subject x --body-file "$BODY" --cc other

section "broadcast — N recipients means N files, and pronouns need a referent"
printf 'Your claim about the gate was wrong.\n' > "$AIMAIL_ROOT/pron.md"
refuses "second person in a broadcast is refused" "second-person pronouns" \
  -- send --to main --to metrics-report --from main --subject x --body-file "$AIMAIL_ROOT/pron.md"
printf 'The gate claim was wrong; nobody in the chain read it.\n' > "$AIMAIL_ROOT/third.md"
accepts "the same claim in third person broadcasts" \
  -- send --to main --to metrics-report --from main --subject x --body-file "$AIMAIL_ROOT/third.md"
accepts "second person to ONE seat is fine" \
  -- send --to main --from main --subject x --body-file "$AIMAIL_ROOT/pron.md"

section "delivery state machine — archive is unreachable by delivery"
accepts "deliver moves inbox → unacked"        -- deliver main
UNACKED=$(find "$AIMAIL_ROOT/mail/main/unacked" -name '*.md' | wc -l)
ARCHIVED=$(find "$AIMAIL_ROOT/mail/main/archive" -name '*.md' 2>/dev/null | wc -l)
if (( UNACKED > 0 && ARCHIVED == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ delivery did NOT archive (%s un-acked, %s archived)\n' "$UNACKED" "$ARCHIVED"
else
  FAIL=$((FAIL+1)); FAILURES+=("delivery reached archive/ without an ack")
  printf '  ✖ delivery reached archive/: %s un-acked, %s archived\n' "$UNACKED" "$ARCHIVED"
fi
accepts "un-acked mail re-surfaces on the next deliver" -- deliver main
if grep -q '📬' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ re-delivery re-printed the un-acked mail\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("un-acked mail was not re-printed")
  printf '  ✖ un-acked mail was not re-printed\n'
fi
accepts "ack archives it"                      -- ack main --all
ARCHIVED=$(find "$AIMAIL_ROOT/mail/main/archive" -name '*.md' | wc -l)
if (( ARCHIVED > 0 )); then PASS=$((PASS+1)); printf '  ✔ ack archived %s message(s) into a month shard\n' "$ARCHIVED"
else FAIL=$((FAIL+1)); FAILURES+=("ack did not archive"); printf '  ✖ ack did not archive\n'; fi

section "where — a state, never a count"
accepts "where finds an archived message"      -- where main ok
# ⛔ The distinction this asserts is the whole point: `ls | wc -l` returns 0 both
#    when mail was delivered-and-consumed and when it was NEVER WRITTEN. Those
#    are opposite facts, and the previous system reported the second as the
#    first. A miss must exit 4 (UNMEASURABLE), never 0 with a count of zero.
unmeasurable_test "a message that never existed is UNMEASURABLE, not 0" "never written to this seat" \
  -- where main zzz-no-such-message

section "dispatcher — unknown verbs are refused"
refuses "unknown command is refused" "unknown command"      -- frobnicate
refuses "unknown seat subcommand is refused" "unknown 'seat' subcommand" -- seat frobnicate

section "fleet — the distinction a process count cannot make"
# ⛔ THE DEFECT UNDER TEST: a poller is DOWN both when a seat is mid-turn reading
#    its mail (normal — do not nudge) and when it was killed (needs a human).
#    `ps` cannot tell those apart. The exit record can, and the arms below prove
#    it does — including the ones that must NOT alarm, because an instrument
#    that alarms on everything is as useless as one that alarms on nothing.
#    (Extended for AR-09/AR-12 — see the arms after STALLED.)
_hb() {  # _hb <seat> <key=value>…
  local seat="$1"; shift
  mkdir -p "$AIMAIL_ROOT/state/poller"
  : > "$AIMAIL_ROOT/state/poller/$seat.hb"
  local kv; for kv in "$@"; do
    printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$AIMAIL_ROOT/state/poller/$seat.hb"
  done
}
_fleet_says() {  # _fleet_says <seat> <expected-state> <desc>
  "$AIMAIL" fleet "$1" > "$AIMAIL_ROOT/.out" 2>&1
  if grep -qE "^$1 +$2" "$AIMAIL_ROOT/.out"; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$3"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$3")
    printf '  ✖ %s — got: %s\n' "$3" "$(grep -E "^$1 " "$AIMAIL_ROOT/.out" | head -1)"
  fi
}
NOW=$(date +%s)
# ① the seat fired and is reading its mail — the false alarm we are killing
_hb main pid=999999 started=$((NOW-600)) beat=$((NOW-10)) exit_at=$((NOW-5)) exit_reason=mail
_fleet_says main "RE-ARMING" "a poller that exited delivering mail reads as RE-ARMING, not down"
# ③ the other direction — the SAME absent process, but killed, must still alarm
_hb main pid=999999 started=$((NOW-600)) beat=$((NOW-600))
_fleet_says main "CRASHED"   "no exit record + no process reads as CRASHED"
# ② positive control: a live, beating poller
_hb main pid=$$ started=$((NOW-600)) beat=$NOW
_fleet_says main "ARMED"     "a live beating poller reads as ARMED"
# and the grace boundary must actually expire, or RE-ARMING would mask a stall
_hb main pid=999999 started=$((NOW-9000)) beat=$((NOW-9000)) exit_at=$((NOW-9000)) exit_reason=mail
_fleet_says main "STALLED"   "an exit older than the grace window reads as STALLED"
rm -f "$AIMAIL_ROOT/state/poller/main.hb"

# ⛔ AR-09 — a poller that is CORRECTLY parked (throttled, `beat` deliberately
#   stale by design) must never read the same as one that is hung. Before the
#   fix, both had only a staling `beat` to judge by, so a healthy park crossed
#   into WEDGED after `limit` seconds and the dashboard told a human to kill it.
_hb main pid=$$ started=$((NOW-600)) beat=$((NOW-90)) park_beat=$((NOW-2))
_fleet_says main "PARKED" "a parked poller (stale beat, fresh park heartbeat) reads PARKED, not WEDGED"
# ③ the other direction — a park heartbeat that has ALSO gone stale must still
#    alarm. Having parked once must not permanently immunise a seat from WEDGED.
_hb main pid=$$ started=$((NOW-9000)) beat=$((NOW-9000)) park_beat=$((NOW-9000))
_fleet_says main "WEDGED" "a stale park heartbeat still alarms — parking once does not mask a later hang"
rm -f "$AIMAIL_ROOT/state/poller/main.hb"

# ⛔ AR-12 — hb_start must land pid/ppid/started/beat via ONE mv, not four. The
#   predecessor wrote them as four separate hb_write calls, each its own
#   mktemp+mv, leaving a window where a concurrent reader saw the file
#   truncated-but-empty or `pid` with no `beat` yet, and reported CRASHED or
#   WEDGED for a poller that was in fact starting up cleanly.
#   ⚠ A content check taken AFTER hb_start returns cannot see this: four
#     sequential writes and one atomic write leave an IDENTICAL final file, so
#     that check passes on both the broken and the fixed code — proven by
#     running it against the pre-fix lib/fleet.sh, where it also passed.
#   ⇒ Count the actual mv(1) invocations instead, via a PATH-shadowed `mv` that
#     logs then execs the real binary. This is deterministic (no timing luck
#     needed) and discriminates every time: old code = 4 mv calls per start,
#     fixed code = 1. Separately reproduced under real concurrency (not a CI
#     arm — timing-based): old code lost 51/160 concurrent reads to
#     CRASHED/WEDGED against a continuously-alive pid; fixed code lost 0/160
#     under the identical stress.
MVSHIM="$(mktemp -d)"
cat > "$MVSHIM/mv" <<'SHIM'
#!/usr/bin/env bash
echo mv >> "$MV_COUNT_FILE"
exec /bin/mv "$@"
SHIM
chmod +x "$MVSHIM/mv"
(
  source "$REPO/lib/core.sh"; source "$REPO/lib/fleet.sh"
  export MV_COUNT_FILE; MV_COUNT_FILE="$(mktemp)"
  PATH="$MVSHIM:$PATH" hb_start ar12test
  n=$(wc -l < "$MV_COUNT_FILE")
  rm -f "$STATE_DIR/poller/ar12test.hb" "$MV_COUNT_FILE"
  [[ "$n" -eq 1 ]]
)
if [[ $? -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ hb_start performs exactly ONE mv — no partial-record window\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("hb_start performed more than one mv — the AR-12 race window is back")
  printf '  ✖ hb_start performed more than one mv — the AR-12 race window is back\n'
fi
rm -rf "$MVSHIM"

section "migrate — import without touching the source"
SRC="$AIMAIL_ROOT/oldbox"
mkdir -p "$SRC/legacy/archive"
printf 'old mail\n' > "$SRC/legacy/archive/2026-01-01-old.md"
printf 'unread\n'   > "$SRC/legacy/live.md"
printf 'role doc\n' > "$SRC/legacy/ROLE.md"
accepts "migrate --dry-run writes nothing"     -- migrate "$SRC" --dry-run
if [[ ! -d "$AIMAIL_ROOT/mail/legacy" ]]; then
  PASS=$((PASS+1)); printf '  ✔ dry run created no mail directory\n'
else FAIL=$((FAIL+1)); FAILURES+=("dry run wrote to the target"); printf '  ✖ dry run wrote to the target\n'; fi
accepts "migrate imports"                      -- migrate "$SRC"
ARCH=$(find "$AIMAIL_ROOT/mail/legacy/archive" -name '*.md' 2>/dev/null | wc -l)
LIVE=$(find "$AIMAIL_ROOT/mail/legacy" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
ROLE=$([[ -f "$AIMAIL_ROOT/roles/legacy.md" ]] && echo 1 || echo 0)
if (( ARCH == 1 && LIVE == 1 && ROLE == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ archive→shard, inbox→inbox, ROLE.md→roles/ (%s/%s/%s)\n' "$ARCH" "$LIVE" "$ROLE"
else
  FAIL=$((FAIL+1)); FAILURES+=("migrate routed files wrong: arch=$ARCH live=$LIVE role=$ROLE")
  printf '  ✖ migrate routed files wrong: arch=%s live=%s role=%s\n' "$ARCH" "$LIVE" "$ROLE"
fi
# ⛔ ROLE.md must NOT land in the inbox, or it is delivered forever as mail.
if [[ ! -f "$AIMAIL_ROOT/mail/legacy/ROLE.md" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ROLE.md did not land in the inbox\n'
else FAIL=$((FAIL+1)); FAILURES+=("ROLE.md landed in the inbox"); printf '  ✖ ROLE.md landed in the inbox\n'; fi
SRC_COUNT=$(find "$SRC" -name '*.md' | wc -l)
if (( SRC_COUNT == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ source untouched (%s files still there)\n' "$SRC_COUNT"
else FAIL=$((FAIL+1)); FAILURES+=("migrate modified the source"); printf '  ✖ migrate modified the source\n'; fi
accepts "migrate is idempotent (re-run is safe)" -- migrate "$SRC"

# ⛔ REGRESSION ARM — a real mailbox had a SECOND archive directory named
#    `_archive`, holding 12 genuine messages. The migrator read only `archive/`
#    and reported success. A per-seat reconciliation against the source caught
#    it; the tool's own summary did not. Any subdirectory holds mail.
mkdir -p "$SRC/oddball/_archive" "$SRC/oddball/archive/nested"
printf 'in _archive\n' > "$SRC/oddball/_archive/alt.md"
printf 'nested\n'      > "$SRC/oddball/archive/nested/deep.md"
printf 'normal\n'      > "$SRC/oddball/archive/plain.md"
accepts "migrate imports a seat with odd archive layouts" -- migrate "$SRC"
ODD=$(find "$AIMAIL_ROOT/mail/oddball/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ODD == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ all 3 archived messages found across _archive/, archive/ and archive/nested/\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("odd archive layouts: got $ODD of 3")
  printf '  ✖ odd archive layouts: got %s of 3 — a non-standard dir was skipped\n' "$ODD"
fi
# ③ the other direction: a dot-directory is tooling and must NOT be imported
mkdir -p "$SRC/oddball/.pytest_cache"; printf 'junk\n' > "$SRC/oddball/.pytest_cache/j.md"
accepts "migrate re-run with a dot-dir present"          -- migrate "$SRC"
if ! find "$AIMAIL_ROOT/mail/oddball" -name 'j.md' | grep -q .; then
  PASS=$((PASS+1)); printf '  ✔ dot-directory contents were NOT imported\n'
else FAIL=$((FAIL+1)); FAILURES+=("dot-dir imported"); printf '  ✖ dot-directory contents were imported\n'; fi

section "stop hook — five arms, each asserting its logged DECISION"
# ⚠ Run as part of the suite, not as a separate manual step. The first version of
#   this selftest lived outside the suite, and its two "allow" arms passed while
#   the guard was switched off entirely.
# WHY the count and the rc are asserted, not just the printed lines: this block used to
# tally ✔/FAILED from a subprocess and assert neither. A selftest that died before its
# first arm emitted NOTHING, so both counters advanced by zero and the suite reported
# "0 failed" with five arms silently missing (measured: 92 -> 87 passed, exit 0).
# ⇒ A tally over a subprocess's output cannot distinguish "all arms passed" from
#   "no arm ran". Only the rc and an EXPECTED COUNT can.
SG_EXPECTED_ARMS=6
SG="$(bash "$REPO/hooks/stop_guard.sh" selftest 2>&1)"; SG_RC=$?
while IFS= read -r line; do
  case "$line" in
    *"✔"*) PASS=$((PASS+1)); printf '  %s\n' "$line" ;;
    *FAILED*) FAIL=$((FAIL+1)); FAILURES+=("stop_guard: $line"); printf '  ✖ %s\n' "$line" ;;
  esac
done <<< "$SG"
SG_ARMS="$(printf '%s\n' "$SG" | grep -cE '✔|FAILED')"
if [[ $SG_RC -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ stop_guard selftest exited 0\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("stop_guard selftest exit=$SG_RC")
  printf '  ✖ stop_guard selftest exited %s — its arms did not run to completion\n' "$SG_RC"
fi
# WHY the DECISIONS are asserted and not just the count: a count catches an arm that
# VANISHES, and nothing else. An arm that still prints ✔ while asserting nothing walks
# straight through it (verified: hollowing _arm's failure branch leaves rc=0, count=5,
# suite green). Each ✔ line carries the decision the arm actually OBSERVED, so requiring
# all five distinct decisions also catches the case the suite really exists for —
# stop_guard's BEHAVIOUR regressing. If it stopped blocking, ARM 1 would report an
# allow-* decision and this fires even though the count is still 5.
# ⛔ The remaining escape is a hollow branch that prints a hardcoded CORRECT string.
#   That is deliberate falsification, not rot, and no in-suite check can distinguish it.
for _d in BLOCK-no-poller allow-stop-hook-active-loop-breaker allow-poller-armed allow-exempt allow-disarmed allow-unmapped; do
  if printf '%s\n' "$SG" | grep -qF "decision=$_d"; then
    PASS=$((PASS+1)); printf '  ✔ stop_guard observed decision=%s\n' "$_d"
  else
    FAIL=$((FAIL+1)); FAILURES+=("stop_guard missing decision=$_d")
    printf '  ✖ stop_guard never observed decision=%s — an arm is gone or its behaviour changed\n' "$_d"
  fi
done
if [[ $SG_ARMS -eq $SG_EXPECTED_ARMS ]]; then
  PASS=$((PASS+1)); printf '  ✔ stop_guard reported all %s arms\n' "$SG_EXPECTED_ARMS"
else
  FAIL=$((FAIL+1)); FAILURES+=("stop_guard arms: got $SG_ARMS want $SG_EXPECTED_ARMS")
  printf '  ✖ stop_guard reported %s arms, expected %s — arms went MISSING, not failing\n' \
    "$SG_ARMS" "$SG_EXPECTED_ARMS"
fi

section "budget — the boundary is measurable, the percentage is not"
# Stub the block cache so these are fast and deterministic. block_json reads the
# cache when it is fresher than AIMAIL_BLOCK_TTL, so no network call happens.
_stub_block() { # _stub_block <minutes-until-end>
  mkdir -p "$AIMAIL_ROOT/state"
  python3 -c "
import json,sys,datetime
m=int(sys.argv[1]); now=datetime.datetime.now(datetime.timezone.utc)
end=now+datetime.timedelta(minutes=m); start=end-datetime.timedelta(hours=5)
print(json.dumps({'blocks':[{'isActive':True,'startTime':start.isoformat().replace('+00:00','Z'),
 'endTime':end.isoformat().replace('+00:00','Z'),'totalTokens':123,'costUSD':1.0,
 'projection':{'remainingMinutes':m},'burnRate':{'tokensPerMinuteForIndicator':7}}]}))" "$1" \
  > "$AIMAIL_ROOT/state/block.json"
}
_stub_block 200
accepts "budget status reads the anchored block"  -- budget status
accepts "budget account resolves an identity"     -- budget account
refuses "a non-numeric callout is refused" "callout <0-100>"  -- budget callout ninety
refuses "a callout over 100 is refused"    "callout <0-100>"  -- budget callout 150
accepts "a valid callout is recorded"                          -- budget callout 42

# ③ the other direction — with no block readable it must say UNMEASURABLE, never
#    report "0 minutes left", which would read as "the block just ended".
rm -f "$AIMAIL_ROOT/state/block.json"
AIMAIL_CCUSAGE_TIMEOUT=1 PATH=/nonexistent:/usr/bin:/bin \
  "$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ "$rc" == "4" ]] && grep -qiF "could not be read" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ an unreadable block is UNMEASURABLE (exit 4), not 0 minutes\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unreadable block did not report UNMEASURABLE")
  printf '  ✖ unreadable block: exit %s (wanted 4)\n' "$rc"
fi

section "budget — a /usage reset beats ccusage, and the EARLIER one wins"
# ⛔ MEASURED DEFECT: ccusage floors a block's start to the hour, so its end reads
#    LATE — 20 minutes, against a real /usage reset. The direction is the
#    dangerous one: a park at end−10 would fire AFTER the real boundary, so the
#    fleet would never park at all. Being early costs one unneeded checkpoint;
#    being late costs the handover.
_stub_block 120          # ccusage claims 120 min left
accepts "callout with --left records a reset"  -- budget callout 78 --left 100
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'source: callout' "$AIMAIL_ROOT/.out" && grep -qi 'boundary disagreement' "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ the earlier /usage boundary wins, and the disagreement is announced\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("callout boundary did not override ccusage")
  printf '  ✖ callout boundary did not override ccusage\n'
fi
# ③ THE OTHER DIRECTION — if the callout is LATER than ccusage, ccusage wins.
#    A rule that always prefers the callout is not "take the earlier", and would
#    happily accept a boundary later than the evidence supports.
_stub_block 30
accepts "callout later than ccusage"           -- budget callout 50 --left 300
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'source: ccusage' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ when the callout is LATER, the earlier ccusage boundary wins\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("did not take the earlier boundary when callout was later")
  printf '  ✖ did not take the earlier boundary when the callout was later\n'
fi
# ② a callout whose reset has already PASSED describes a dead window and must
#    not govern anything — a window CLOSING is a reset, not a budget spent.
printf '%s\t%s\t%s\tcallout\t%s\n' "$(date +%s)" "$("$AIMAIL" budget account | grep -oE 'account: [^ ]+' | cut -d' ' -f2)" 60 "$(( $(date +%s) - 600 ))" >> "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null || true
_stub_block 120
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>&1
if grep -q 'source: ccusage' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ an expired callout reset is ignored (falls back to ccusage)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("expired callout reset still governed the schedule")
  printf '  ✖ an expired callout reset still governed the schedule\n'
fi

section "budget — checkpoint fires once per block, not once per tick"
# ① the arm failing first: an unregistered sender must REFUSE and, critically,
#    must NOT write the done-marker — otherwise a failed checkpoint records
#    itself as complete and never retries for that block.
_stub_block 10
refuses "an unregistered supervisor refuses the checkpoint" "not a registered seat" \
  -- budget checkpoint
if [[ ! -f "$AIMAIL_ROOT/state/checkpoint_done" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a refused checkpoint wrote NO marker, so it will retry\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("refused checkpoint wrote a done-marker")
  printf '  ✖ a refused checkpoint wrote a done-marker — that block would never retry\n'
fi
accepts "register the supervisor seat"             -- seat add assistant "Supervisor"
_stub_block 200
accepts "checkpoint not due far from the boundary" -- budget checkpoint
_stub_block 10
accepts "checkpoint fires inside the window"       -- budget checkpoint
CK1=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
accepts "checkpoint is idempotent within a block"  -- budget checkpoint
CK2=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
# ⛔ `now >= X` stays true forever once true. Keyed on a boolean this becomes a
#    wake loop firing every tick — the most expensive bug in a supervision path.
if (( CK1 > 0 && CK2 == CK1 )); then
  PASS=$((PASS+1)); printf '  ✔ sent %s, re-run sent 0 more (marker keyed on the block end)\n' "$CK1"
else
  FAIL=$((FAIL+1)); FAILURES+=("checkpoint re-fired: $CK1 -> $CK2")
  printf '  ✖ checkpoint re-fired within one block: %s -> %s\n' "$CK1" "$CK2"
fi
# ③ …and a NEW block must still checkpoint, or the guard becomes a permanent block
_stub_block 9
accepts "a new block checkpoints again"            -- budget checkpoint
CK3=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
if (( CK3 > CK2 )); then
  PASS=$((PASS+1)); printf '  ✔ a new block re-fired the checkpoint (%s -> %s)\n' "$CK2" "$CK3"
else
  FAIL=$((FAIL+1)); FAILURES+=("new block did not checkpoint")
  printf '  ✖ a new block did NOT checkpoint (%s -> %s)\n' "$CK2" "$CK3"
fi

section "budget — park keeps pollers ARMED and the ramp wakes them"
accepts "park writes the throttle flag"            -- budget park "test park"
if [[ -f "$AIMAIL_ROOT/state/throttled" ]] && grep -q 'STAY ARMED' "$AIMAIL_ROOT/state/throttled"; then
  PASS=$((PASS+1)); printf '  ✔ the throttle flag tells seats to STAY ARMED\n'
else FAIL=$((FAIL+1)); FAILURES+=("throttle flag missing the stay-armed instruction")
     printf '  ✖ throttle flag does not say STAY ARMED\n'; fi
# ⭐ THE INTEGRATION CLAIM: a poller parks on the flag, does NOT consume mail,
#    and wakes ITSELF at the ramp with nobody touching it.
printf 'x\n' > "$AIMAIL_ROOT/pk.md"
"$AIMAIL" send --to main --from main --subject "during park" --body-file "$AIMAIL_ROOT/pk.md" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) + 3600 ))" > "$AIMAIL_ROOT/state/ramp_at"
"$AIMAIL" poll main > "$AIMAIL_ROOT/park.log" 2>&1 &
PARKPID=$!; sleep 4
if kill -0 $PARKPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ poller stays ARMED and asleep under a throttle (does not exit)\n'
else FAIL=$((FAIL+1)); FAILURES+=("poller exited under a throttle"); printf '  ✖ poller exited under a throttle\n'; fi
QD=$(find "$AIMAIL_ROOT/mail/main" -maxdepth 1 -name '*.md' | wc -l)
if (( QD >= 1 )); then
  PASS=$((PASS+1)); printf '  ✔ mail sent during the park is queued, not consumed\n'
else FAIL=$((FAIL+1)); FAILURES+=("parked poller consumed mail"); printf '  ✖ parked poller consumed mail\n'; fi
accepts "ramp clears the throttle"                 -- budget ramp
printf 'at\t%s\n' "$(( $(date +%s) - 10 ))" > "$AIMAIL_ROOT/state/ramp_at"
sleep 8
if ! kill -0 $PARKPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the poller woke ITSELF at the ramp — no human, no coordinator\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poller did not self-wake at the ramp"); kill $PARKPID 2>/dev/null
  printf '  ✖ poller did not wake at the ramp\n'
fi
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/ramp_at"

section "budget — AR-03: a failed write must never report PARKED"
# ⛔ THE DEFECT: `{ ... } | atomic_write "$dest"` runs atomic_write's `die` in a
#   SUBSHELL (the pipe's receiving end). `set -uo pipefail` makes the pipeline's
#   own exit status correctly reflect that failure, but nothing read it — so a
#   failed write was followed, unconditionally, by "✔ fleet PARKED". Force the
#   write to fail (a read-only state dir) and confirm the function now refuses
#   loudly instead of claiming success.
chmod 555 "$AIMAIL_ROOT/state" 2>/dev/null
"$AIMAIL" budget park "AR-03 forced-failure test" >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
chmod 755 "$AIMAIL_ROOT/state" 2>/dev/null
if [[ "$rc" != "0" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a failed write is reported loudly (rc=%s), not as success\n' "$rc"
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-03: budget park reported success despite a failed write")
  printf '  ✖ AR-03: budget park exited 0 despite the write failing\n'
fi
if grep -qi 'PARKED' "$AIMAIL_ROOT/.out" 2>/dev/null; then
  FAIL=$((FAIL+1)); FAILURES+=("AR-03: 'fleet PARKED' was printed despite the write failing")
  printf '  ✖ AR-03: success message printed anyway\n'
else
  PASS=$((PASS+1)); printf '  ✔ no success message was printed for a write that did not happen\n'
fi
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/ramp_at"

section "budget — AR-10: a refused checkpoint must not skip the park"
# ⛔ THE DEFECT: `(( left <= CHECKPOINT_MIN )) && budget_checkpoint` — bare, not
#   subshelled. budget_checkpoint uses this codebase's own refused/exit idiom
#   (exit 3 on an unregistered sender), which TERMINATES THE WHOLE AUTOPILOT
#   PROCESS, so the park check just below it never runs. Force the checkpoint
#   to refuse (an unregistered supervisor) at a boundary where BOTH the
#   checkpoint and the park are due, and confirm the park still happens.
_stub_block 5
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/checkpoint_done" "$AIMAIL_ROOT/state/ramp_at"
AIMAIL_SUPERVISOR=nobody-registered-here "$AIMAIL" budget autopilot \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ -f "$AIMAIL_ROOT/state/throttled" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the park happened even though the checkpoint step refused (autopilot rc=%s)\n' "$rc"
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-10: a refused checkpoint prevented the park")
  printf '  ✖ AR-10: park did NOT happen — refused checkpoint skipped it (rc=%s)\n' "$rc"
  sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
fi
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/checkpoint_done" "$AIMAIL_ROOT/state/ramp_at"

section "budget — AR-11: park must never leave ZERO wake path"
# ⛔ THE DEFECT: `[[ -n "$be" ]] && printf ... | atomic_write ramp_at` wrote
#   NOTHING when the block boundary was unmeasurable — a park with the
#   throttle set and no ramp_at at all has NO self-wake path, ever, directly
#   violating this file's own "never remove the last wake path" comment. Force
#   genuine unmeasurability (no cached block, no network, and the most recent
#   callout for this account already expired) and confirm a ramp_at still
#   gets written as a fallback recheck.
rm -f "$AIMAIL_ROOT/state/block.json" "$AIMAIL_ROOT/state/ramp_at" "$AIMAIL_ROOT/state/throttled"
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ACCT" 60 "callout" "$(( $(date +%s) - 600 ))" \
  >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
accepts "park succeeds even when the boundary is genuinely unmeasurable" \
  -- budget park "AR-11 unmeasurable-boundary test"
if [[ -f "$AIMAIL_ROOT/state/ramp_at" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ramp_at was written as a fallback recheck even with an unmeasurable boundary\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-11: park left NO ramp_at when the boundary was unmeasurable")
  printf '  ✖ AR-11: park left NO ramp_at — the fleet would park with no wake path at all\n'
fi
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/ramp_at"

section "poller — AR-05/AR-06: ramp self-detected while parked, and no refire on restart"
# ⛔⛔ THE DEFECT: the throttle branch `continue`d unconditionally, so a poller
#   that was ALREADY parked could never itself notice its own ramp_at had
#   passed — only a separate `budget ramp` CLI call (or a working `autopilot`
#   cron, which AR-05b found was independently dead) could lift it. This is an
#   OBSERVED-PROCESS test, not a stubbed heartbeat read, because the review's
#   own finding on this exact class was that a green suite can certify a hollow
#   or fail-open guard — see code-review's stop_guard.sh finding.
"$AIMAIL" budget park "AR-05/06 direct test" >/dev/null 2>&1
# Ramp time already in the past, and NO external `budget ramp` call anywhere
# in this arm — if the poller cannot detect this itself, it parks forever.
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$AIMAIL_ROOT/state/ramp_at"
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar0506.log" 2>&1 &
P1=$!
sleep 3
if ! kill -0 "$P1" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ poller woke ITSELF on an overdue ramp_at while still throttled — no external budget-ramp call\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poller did not self-detect an overdue ramp while parked (AR-05a)")
  printf '  ✖ poller did not self-detect an overdue ramp while parked — still alive after 3s\n'
  kill "$P1" 2>/dev/null
fi
if grep -q 'WAKE=ramp' "$AIMAIL_ROOT/ar0506.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ it woke for the right reason (ramp, not a coincidental mail delivery)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poller exited but not with WAKE=ramp")
  printf '  ✖ poller exited but the log does not show WAKE=ramp\n'
fi
# AR-06a — the self-detection must ALSO clear the throttle and push ramp_at
# forward, not merely notice it. Otherwise a seat that re-arms right after
# waking hits the SAME stale timestamp and refires instantly: a wake loop of
# full session turns, which is worse than the original "never wakes" bug.
if [[ ! -f "$AIMAIL_ROOT/state/throttled" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle was actually cleared by the self-detected ramp, not just logged\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-detected ramp fired but left the throttle in place")
  printf '  ✖ throttle still present after the poller reported WAKE=ramp\n'
fi
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar0506b.log" 2>&1 &
P2=$!
sleep 3
if kill -0 "$P2" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ restarting right after does NOT instantly refire — ramp_at was advanced (AR-06a)\n'
  kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("restart re-fired immediately — ramp_at was not advanced (AR-06a wake-loop regression)")
  printf '  ✖ restart re-fired immediately on the same stale ramp_at\n'
fi
rm -f "$AIMAIL_ROOT/state/throttled" "$AIMAIL_ROOT/state/ramp_at"

section "poller — AR-06b: un-acked mail is not, by itself, a wake reason"
# ⛔ THE DEFECT: the wake predicate counted `unacked/` as well as the live
#   inbox, so a seat that re-armed before acking woke instantly on the exact
#   message it had just finished reading. Deliver one message, deliberately
#   do NOT ack it, then confirm a fresh poller does not instantly exit on it.
printf 'y\n' > "$AIMAIL_ROOT/unacked_test.md"
"$AIMAIL" send --to main --from main --subject "unacked probe" --body-file "$AIMAIL_ROOT/unacked_test.md" >/dev/null 2>&1
accepts "deliver it (moves inbox -> unacked)" -- deliver main
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar06b.log" 2>&1 &
P3=$!
sleep 3
if kill -0 "$P3" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ un-acked mail alone does not wake a freshly-armed poller\n'
  kill "$P3" 2>/dev/null; wait "$P3" 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("poller instantly woke on un-acked mail alone (AR-06b regression)")
  printf '  ✖ poller exited instantly — un-acked mail is still being counted as pending\n'
fi
accepts "ack the probe message" -- ack main --all

section "poller — AR-07/R-2: a non-regular *.md entry must not wake or wedge the poller"
# ⛔⛔ THE DEFECT: the wake predicate (`find -name '*.md' | wc -l`) and the
#   delivery predicate (which skips anything failing `[[ -f "$f" ]]`) disagreed
#   about what a message IS. A directory named `notes.md` — or a broken
#   symlink — was counted as pending forever, delivery silently skipped it and
#   removed nothing, and NO VERB could clear the resulting loop. Reproduce the
#   exact shape named in the review: a directory, not a file.
mkdir -p "$AIMAIL_ROOT/mail/main/notes.md"
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar07.log" 2>&1 &
P4=$!
sleep 3
if kill -0 "$P4" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a directory named *.md in the inbox does not wake the poller\n'
  kill "$P4" 2>/dev/null; wait "$P4" 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("poller woke/exited on a non-regular *.md entry (AR-07 regression)")
  printf '  ✖ poller exited — got fooled by a non-regular *.md entry: %s\n' "$(cat "$AIMAIL_ROOT/ar07.log" 2>/dev/null | head -3)"
fi
# ③ the other direction — `deliver` must not choke on the same entry, and a
#    REAL message sitting alongside it must still be delivered normally.
printf 'z\n' > "$AIMAIL_ROOT/real.md"
"$AIMAIL" send --to main --from main --subject "real message beside the phantom" --body-file "$AIMAIL_ROOT/real.md" >/dev/null 2>&1
accepts "deliver still works with a phantom *.md directory present" -- deliver main
if grep -q 'real message beside the phantom' "$AIMAIL_ROOT/.out" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the real message alongside the phantom directory was delivered\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("real message was not delivered alongside a phantom *.md entry")
  printf '  ✖ real message alongside the phantom was not delivered\n'
fi
accepts "ack it" -- ack main --all
rm -rf "$AIMAIL_ROOT/mail/main/notes.md"

section "role — the handover, and the resume that reads it"
# ⛔ A seat with no handover resumes BLIND after an account switch. "No role file"
#    and "an empty handover" must not read the same as "nothing to hand over".
unmeasurable_test "a missing role file is UNMEASURABLE, not empty" "resumes blind" \
  -- role show main
printf '# handover\n\nDONE: nothing yet.\n' > "$AIMAIL_ROOT/h.md"
accepts "write a handover from a file"          -- role write main "$AIMAIL_ROOT/h.md"
accepts "show it back"                          -- role show main
accepts "role path prints a location"           -- role path main
# ⚠ The handover must NOT be reachable by the mail glob — that was the whole
#   reason it moved out of the inbox.
# ⛔ NOT `find | xargs -r grep -l ... >/dev/null 2>&1`. `xargs -r` (no-run-if-empty)
#   exits 0 when `find` matches NOTHING — indistinguishable from grep exiting 0
#   because it found a match. An empty, healthy inbox and a leaking one then
#   read as the SAME "reachable by the glob" failure. (Found it dormant: this
#   fired the first time the live inbox happened to be genuinely empty at this
#   checkpoint — reproduced directly against `find /empty/dir | xargs -r grep`,
#   exit 0 either way.) Count matches explicitly instead.
HANDOVER_LEAKS=$(find "$AIMAIL_ROOT/mail/main" -maxdepth 1 -type f -name '*.md' \
  -exec grep -l 'DONE: nothing yet' {} \; 2>/dev/null | wc -l)
if (( HANDOVER_LEAKS == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ the handover is not in the inbox, so it can never be delivered as mail\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("handover landed where mail is globbed")
  printf '  ✖ the handover is reachable by the inbox glob\n'
fi
# a rewrite keeps the previous version — an overwritten handover is a silent loss
printf '# v2\n' > "$AIMAIL_ROOT/h2.md"
accepts "rewrite the handover"                  -- role write main "$AIMAIL_ROOT/h2.md"
if [[ -f "$AIMAIL_ROOT/roles/.main.prev.md" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the previous handover was kept\n'
else FAIL=$((FAIL+1)); FAILURES+=("previous handover not kept"); printf '  ✖ previous handover was discarded\n'; fi

section "role stale — the checkpoint's verification arm"
# ⭐ Sending the checkpoint proves a REQUEST was made. It proves nothing about
#    whether a handover exists. These two arms are that difference.
_stub_block 200
rc="$(_run role stale)"
if [[ "$rc" == "1" ]] && grep -qi 'resume BLIND' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ seats without a current handover are reported, exit 1\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("role stale did not flag missing handovers (exit $rc)")
  printf '  ✖ role stale did not flag missing handovers (exit %s)\n' "$rc"
fi
# ③ the other direction — once every active seat has a fresh handover it must
#    say SAFE. A check that can only ever refuse would block every switch forever.
while IFS= read -r s; do
  [[ -n "$s" ]] || continue
  [[ "$("$AIMAIL" seat resolve "$s" >/dev/null 2>&1; echo ok)" == "ok" ]] || continue
  "$AIMAIL" role write "$s" "$AIMAIL_ROOT/h.md" >/dev/null 2>&1
done < <("$AIMAIL" seat list 2>/dev/null | awk 'NR>2 && $2=="active"{print $1}')
rc="$(_run role stale)"
if [[ "$rc" == "0" ]] && grep -qi 'Safe to switch' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ with every active seat current, it reports SAFE TO SWITCH (exit 0)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("role stale never clears (exit $rc)")
  printf '  ✖ role stale never clears — it would block every switch (exit %s)\n' "$rc"
fi
accepts "resume prints the handover and the next steps" -- resume main
if grep -q 'YOUR NEXT THREE COMMANDS' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ resume names the exact commands that make a seat reachable\n'
else FAIL=$((FAIL+1)); FAILURES+=("resume did not print next steps"); printf '  ✖ resume did not print next steps\n'; fi

section "fleet sweep — AR-20: an ACTIVE alert, not a dashboard nobody calls"
# ⛔ THE DEFECT: `aimail fleet` was a correct, read-only dashboard that nobody
#   is obligated to run — a CRASHED seat sits invisible until a human happens
#   to look. `sweep` is the active half: it must actually mail a supervisor,
#   unprompted, and it must NOT spam that same mail every time it is re-run
#   for the SAME ongoing crash.
accepts "register the sweep supervisor" -- seat add sweepvisor "Supervisor for this arm"
accepts "register a seat that will crash" -- seat add crashy "will crash"
mkdir -p "$AIMAIL_ROOT/state/poller"
printf 'pid\t999999\nppid\t1\nstarted\t%s\nbeat\t%s\n' "$(date +%s)" "$(date +%s)" \
  > "$AIMAIL_ROOT/state/poller/crashy.hb"
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep runs" -- fleet sweep
SWEEP1=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( SWEEP1 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ a CRASHED seat generated exactly one unprompted alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep alert count after 1st run: got $SWEEP1 want 1")
  printf '  ✖ sweep alert count after 1st run: got %s, want 1\n' "$SWEEP1"
fi
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep re-run on the SAME ongoing crash" -- fleet sweep
SWEEP2=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( SWEEP2 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ re-sweeping the SAME ongoing crash did not send a second alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep re-alerted an already-reported crash: now $SWEEP2 messages")
  printf '  ✖ sweep re-alerted an already-reported crash — now %s message(s)\n' "$SWEEP2"
fi
# ③ the other direction — a NEW crash (different pid/beat) must still alert,
#    proving the dedup is keyed on the EVENT, not on "this seat, ever again".
printf 'pid\t888888\nppid\t1\nstarted\t%s\nbeat\t%s\n' "$(date +%s)" "$(date +%s)" \
  > "$AIMAIL_ROOT/state/poller/crashy.hb"
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep on a NEW, distinct crash" -- fleet sweep
SWEEP3=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( SWEEP3 == 2 )); then
  PASS=$((PASS+1)); printf '  ✔ a genuinely NEW crash (different pid/beat) alerted again (%s total)\n' "$SWEEP3"
else
  FAIL=$((FAIL+1)); FAILURES+=("a new crash did not generate a new alert: got $SWEEP3 want 2")
  printf '  ✖ a new crash did not generate a new alert: got %s, want 2\n' "$SWEEP3"
fi
rm -f "$AIMAIL_ROOT/state/poller/crashy.hb"

section "whoami — AR-21: a fresh session with no seat name yet"
# ⛔ THE DEFECT: `resume <seat>` requires the caller to already know its own
#   name. `whoami` closes the actual cold-start gap by reusing the SAME
#   session->seat mapping the stop-hook guard already maintains.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
unmeasurable_test "no session id in the environment" "no session id" -- whoami
export CLAUDE_CODE_SESSION_ID=selftest-whoami-sid
unmeasurable_test "a session id that was never registered" "not registered to any seat" -- whoami
accepts "register a seat for whoami to resolve" -- seat add whoseat "test"
printf '# handover\nDONE: whoami test.\n' > "$AIMAIL_ROOT/wh.md"
accepts "write it a handover" -- role write whoseat "$AIMAIL_ROOT/wh.md"
mkdir -p "$AIMAIL_ROOT/state/stopguard"
printf 'whoseat' > "$AIMAIL_ROOT/state/stopguard/session.selftest-whoami-sid"
accepts "whoami resolves a registered session and resumes it" -- whoami
if grep -q "registered as seat 'whoseat'" "$AIMAIL_ROOT/.out" && grep -q 'RESUME: whoseat' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ whoami identified the seat AND printed its resume, in one command\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("whoami did not both identify and resume the seat")
  printf '  ✖ whoami did not both identify and resume the seat\n'
fi
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

section "doctor"
accepts "doctor runs"                          -- doctor

# ══════════════════════════════════════════════════════════════════════════════
TOTAL=$((PASS+FAIL))
echo; printf '%.0s─' {1..60}; echo
printf '\n%s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TOTAL"
if (( FAIL )); then printf '\nFAILURES:\n'; printf '  • %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
