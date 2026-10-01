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
# ⛔⛔ THE OPERATOR'S SHELL IS NOT PART OF THE FIXTURE (2026-09-22) — see tests/lib_env.sh for the
#   incident (AIMAIL_WEEKLY_CAP_research=99 turned three weekly-cap arms red on one operator's box
#   and green on the next). Scrub inherited AIMAIL_*, drop the caller's session id, pin the config
#   dir to a stub inside the root so `account_id()` is the same word everywhere.
# shellcheck source=./lib_env.sh
source "$HERE/lib_env.sh"; test_env_sanitize; test_env_pin_config_dir
trap 'rm -rf "$AIMAIL_ROOT"' EXIT

_run() { "$AIMAIL" "$@" >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; echo $?; }

# _cache_acct — the block-cache filename is now keyed by account_id() (2026-09-17,
# per-account autopilot). Computed via the CLI, matching the `ACCT=` idiom already
# used elsewhere in this file, rather than requiring lib/budget.sh sourced this
# early (it isn't, until much later, for one specific direct-function-call section).
_cache_acct() { "$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2; }
_block_cache() { echo "$AIMAIL_ROOT/state/block.$(_cache_acct).json"; }
# _throttle_file / _ramp_at_file — same idiom, for the per-account park/ramp
# state added 2026-09-20 (hybrid multi-account design; see budget.sh's own
# THROTTLE_FLAG()/RAMP_AT_FILE()). Every test below that used to touch the
# bare `state/throttled` / `state/ramp_at` files now goes through these.
_throttle_file() { echo "$AIMAIL_ROOT/state/throttled_$(_cache_acct)"; }
_ramp_at_file() { echo "$AIMAIL_ROOT/state/ramp_at_$(_cache_acct)"; }
# _fable_weekly_file [account] — same idiom, for FABLE_WEEKLY_FILE (item 2,
# 2026-09-20). A TEST-LOCAL reimplementation of the path formula, not a call
# into budget.sh's own function: at the point this is first used, budget.sh
# has not been sourced into this script's own shell yet (it only gets sourced
# later, for the AR-14 unit-behavior section), and calling an undefined
# function silently returns an empty string -- exactly the "budget.sh function
# called before budget.sh is sourced" bug class this same work already found
# and fixed in lib/poller.sh. Keeping this independent of source order avoids
# repeating it here.
_fable_weekly_file() { echo "$AIMAIL_ROOT/state/fable_weekly_${1:-$(_cache_acct)}.tsv"; }

# accepts <desc> -- <cmd…>   : must exit 0
accepts() {
  local desc="$1"; shift; [[ "$1" == "--" ]] && shift
  local rc; rc="$(_run "$@")"
  if [[ "$rc" == "0" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else FAIL=$((FAIL+1)); FAILURES+=("$desc (exit $rc)"); printf '  ✖ %s — exit %s\n' "$desc" "$rc"
       sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6; fi
}

# _shas_for <seat> : comma-joined body-sha256 of everything currently in that
# seat's unacked/ — AR-28's --sha argument, computed the same way a real
# reader would (from the actual delivered files), not invented.
_shas_for() {
  grep -h '^body-sha256: ' "$AIMAIL_ROOT/mail/$1/unacked/"*.md 2>/dev/null \
    | cut -d' ' -f2 | paste -sd, -
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
section "suite hygiene — the operator's shell never reaches the fixture (2026-09-22)"
# A child shell that inherits a per-account cap from ITS caller must not see it after the scrub,
# and the pinned account must be the stub word. Exercised through the same helper this file used.
_hyg_out="$(env AIMAIL_WEEKLY_CAP_claude_config_stub=1 AIMAIL_SEAT_CAP_zzz=5 AIMAIL_ROOT="$AIMAIL_ROOT" CLAUDE_CODE_SESSION_ID=leak \
  bash -c 'source "$1/lib_env.sh"; test_env_sanitize; test_env_pin_config_dir; compgen -v | grep -cE "^AIMAIL_(WEEKLY_CAP|SEAT_CAP)"; echo "${CLAUDE_CODE_SESSION_ID:-unset}"; basename "$CLAUDE_CONFIG_DIR"' _ "$HERE")"
if [[ "$_hyg_out" == $'0\nunset\nclaude_config_stub' ]]; then
  PASS=$((PASS+1)); printf '  ✔ inherited AIMAIL_*_CAP_* and the session id are gone; account pinned to claude_config_stub\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("suite hygiene: the scrub left operator state in the fixture")
  printf '  ✖ scrub left state behind — got: %s\n' "$(tr '\n' '|' <<<"$_hyg_out")"
fi
if [[ "$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)" == "claude_config_stub" ]]; then
  PASS=$((PASS+1)); printf '  ✔ aimail budget account reads the stub, not the real account of the operator\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("suite hygiene: budget account still reads the operator's account")
  printf '  ✖ budget account: %s\n' "$("$AIMAIL" budget account 2>&1 | head -2 | tr '\n' ' ')"
fi
unset _hyg_out

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

section "registry — seat unretire: retirement was a one-way door"
# ⛔⛔ THE DEFECT THIS CLOSES: `seat_add` refuses an existing name, so a seat
#   retired by mistake — the real incident: a LIVE seat registered `retired`
#   while still working — had no way back except a HAND EDIT of the registry
#   file. That is the worst possible remedy for exactly this file: its own
#   known defect is lost rows under an uncoordinated read-modify-write (AR-04).
accepts "register a seat to mis-retire"        -- seat add livewrongly "a live seat"
accepts "retire it (simulating the mistake)"   -- seat retire livewrongly
refuses "mail to it now refuses, as designed"  "RETIRED" \
  -- send --to livewrongly --from livewrongly --subject x --body-file /etc/hostname
accepts "unretire reverses it"                 -- seat unretire livewrongly "back, was a mistake"
accepts "mail resolves again post-unretire"    \
  -- send --to livewrongly --from livewrongly --subject "post-unretire" --body-file /etc/hostname
"$AIMAIL" seat list >"$AIMAIL_ROOT/.out" 2>/dev/null
if [[ "$(grep livewrongly "$AIMAIL_ROOT/.out" | awk '{print $2}')" == "active" ]]; then
  PASS=$((PASS+1)); printf '  ✔ status is active again, not left at retired\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unretire did not restore active status")
  printf '  ✖ unretire did not restore active status\n'
fi
# ③ the other direction — unretiring a seat that is NOT retired must refuse,
#    not silently no-op (a silent no-op here would hide a typo'd seat name).
refuses "unretire on an ACTIVE seat is refused, not a silent no-op" "is not retired" \
  -- seat unretire livewrongly "again"
refuses "unretire on an unregistered name is refused" "not a registered seat" \
  -- seat unretire totally-unregistered-name

section "registry — unretire shares the SAME lock as add/retire (does not reopen AR-04)"
# unretire is retire's inverse and touches the identical file the identical
# way — it must be proven to share the lock, not just assumed to, or fixing
# one one-way door could quietly reopen the exact race AR-04 closed.
for i in $(seq 1 8); do
  "$AIMAIL" seat add "unret$i" "seed" >/dev/null 2>&1
  "$AIMAIL" seat retire "unret$i" >/dev/null 2>&1
done
for i in $(seq 1 8); do "$AIMAIL" seat unretire "unret$i" "concurrent unretire" >/dev/null 2>&1 & done
for i in $(seq 1 8); do "$AIMAIL" seat add "unretnew$i" "concurrent add" >/dev/null 2>&1 & done
wait
UNR_ROWS="$(grep -vE '^\s*(#|$)' "$AIMAIL_ROOT/seats.tsv")"
UNR_ACTIVE=$(printf '%s\n' "$UNR_ROWS" | awk -F'\t' '$1 ~ /^unret[0-9]/ && $2=="active"' | wc -l)
UNR_NEW=$(printf '%s\n' "$UNR_ROWS" | awk -F'\t' '$1 ~ /^unretnew/' | wc -l)
if (( UNR_ACTIVE == 8 )); then
  PASS=$((PASS+1)); printf '  ✔ all 8 concurrent unretires landed (0 lost to a race)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unretire concurrency: only $UNR_ACTIVE/8 landed")
  printf '  ✖ unretire concurrency: only %s/8 landed — rows lost\n' "$UNR_ACTIVE"
fi
if (( UNR_NEW == 8 )); then
  PASS=$((PASS+1)); printf '  ✔ all 8 concurrent adds alongside unretire landed (0 lost)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unretire concurrency: only $UNR_NEW/8 concurrent adds landed")
  printf '  ✖ unretire concurrency: only %s/8 concurrent adds landed\n' "$UNR_NEW"
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

# ⛔ R6(h) sender identity (2026-09-23): with a session id in the env AND a seat record naming the
#   seat's registered session, they must agree; everything else fails open.
mkdir -p "$AIMAIL_ROOT/state/seat_account"
printf 'seat\tmain\naccount\tacct-x\nsession_id\tsid-main-0001\nmodel\tm\n' > "$AIMAIL_ROOT/state/seat_account/main"
export CLAUDE_CODE_SESSION_ID=sid-main-0001
accepts "identity: the registered session sends as its own seat" \
  -- send --to main --from main --subject "id ok" --body-file "$BODY"
export CLAUDE_CODE_SESSION_ID=sid-ghost-9999
refuses "identity: another session sending as 'main' is REFUSED, by name" "NOT the registered" \
  -- send --to main --from main --subject "id ghost" --body-file "$BODY"
AIMAIL_SEND_IDENTITY_CHECK=0 accepts "identity: the kill switch lets it through (a human's decision)" \
  -- send --to main --from main --subject "id kill" --body-file "$BODY"
unset CLAUDE_CODE_SESSION_ID
accepts "identity: NO session id in the env -> fail-open (cron, a human's shell)" \
  -- send --to main --from main --subject "id nosid" --body-file "$BODY"
export CLAUDE_CODE_SESSION_ID=sid-ghost-9999
rm -f "$AIMAIL_ROOT/state/seat_account/main"
accepts "identity: NO seat record -> fail-open (a seat that never confirmed)" \
  -- send --to main --from main --subject "id norec" --body-file "$BODY"
unset CLAUDE_CODE_SESSION_ID

# ② the trailing-newline regression (mail.sh's own intake canonicalization,
#    2026-08-31, fable's ruling): a body file with NO final newline used to fail
#    "INTEGRITY FAILURE ... digest != source digest" 100% of the time — the
#    source sha is computed on the file's raw bytes, but the post-delivery
#    integrity check re-extracts the body via `awk 'seen>=2{print}...'`, and
#    awk's own ORS always appends a trailing newline to the last printed
#    record regardless of whether the input had one.
printf '%s' "no trailing newline" > "$AIMAIL_ROOT/notrail.md"
accepts "a body with no trailing newline still sends" \
  -- send --to main --from main --subject "no-trailing-newline" --body-file "$AIMAIL_ROOT/notrail.md"
# The delivered copy must be byte-correct: source content plus EXACTLY the one
# newline the intake canonicalization appends — never two (a body that already
# had one must not gain a second), never zero.
DELIVERED="$(ls -t "$AIMAIL_ROOT/mail/main/"*no-trailing-newline*.md 2>/dev/null | head -1)"
if [[ -n "$DELIVERED" ]]; then
  GOT_BODY="$(awk 'seen>=2{print} /^---$/{seen++}' "$DELIVERED" | sed '1{/^$/d}')"
  if [[ "$GOT_BODY" == "no trailing newline" ]]; then
    PASS=$((PASS+1)); printf '  ✔ delivered body is byte-correct (source + exactly one appended newline)\n'
  else
    FAIL=$((FAIL+1)); FAILURES+=("delivered body for no-trailing-newline send is wrong")
    printf '  ✖ delivered body is wrong: %q (wanted %q)\n' "$GOT_BODY" "no trailing newline"
  fi
else
  FAIL=$((FAIL+1)); FAILURES+=("no-trailing-newline send did not deliver a file")
  printf '  ✖ no delivered file found for no-trailing-newline send\n'
fi
printf '# already balanced\n' > "$AIMAIL_ROOT/hastrail.md"
accepts "a body that already has a trailing newline still sends" \
  -- send --to main --from main --subject "already-has-trailing-newline" --body-file "$AIMAIL_ROOT/hastrail.md"
DELIVERED2="$(ls -t "$AIMAIL_ROOT/mail/main/"*already-has-trailing-newline*.md 2>/dev/null | head -1)"
if [[ -n "$DELIVERED2" ]]; then
  GOT_BODY2="$(awk 'seen>=2{print} /^---$/{seen++}' "$DELIVERED2" | sed '1{/^$/d}')"
  if [[ "$GOT_BODY2" == "# already balanced" ]]; then
    PASS=$((PASS+1)); printf '  ✔ an already-newline-terminated body gains no second newline\n'
  else
    FAIL=$((FAIL+1)); FAILURES+=("an already-terminated body was double-newlined")
    printf '  ✖ delivered body is wrong: %q (wanted %q)\n' "$GOT_BODY2" "# already balanced"
  fi
else
  FAIL=$((FAIL+1)); FAILURES+=("already-has-trailing-newline send did not deliver a file")
  printf '  ✖ no delivered file found for already-has-trailing-newline send\n'
fi

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

section "send — C4: a GREEN verdict must name its producer and consumer"
printf 'Ship it.\n' > "$AIMAIL_ROOT/green_bare.md"
refuses "GREEN with neither line is refused" "Producer" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_bare.md"

printf 'Producer: services/foo.py:12\nConsumer: services/bar.py:34\nFleet tests: n/a, an AIMail change.\nShip it.\n' > "$AIMAIL_ROOT/green_full.md"
accepts "GREEN with both a producer and a consumer line passes" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_full.md"

printf 'Producer: services/foo.py:12\nConsumer: services/bar.py:34\nShip it.\n' > "$AIMAIL_ROOT/green_nofleet.md"
refuses "R-009: GREEN with producer and consumer but no Fleet tests: line is refused" "Fleet tests" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_nofleet.md"

printf 'Producer: services/foo.py:12\nConsumer: services/bar.py:34\nFleet tests:\nShip it.\n' > "$AIMAIL_ROOT/green_emptyfleet.md"
refuses "R-009: an empty Fleet tests: line does not count" "Fleet tests" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_emptyfleet.md"

printf 'Producer: services/foo.py:12\nConsumer: services/bar.py:34\nFleet tests: run_fleet_tests.py --fast passed at 0123abcd: Ran 289 tests, OK\nShip it.\n' > "$AIMAIL_ROOT/green_fleetpass.md"
accepts "R-009: a Fleet tests: line naming the run_fleet_tests.py result passes" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_fleetpass.md"

printf 'Docs-only: no code changed.\nShip it.\n' > "$AIMAIL_ROOT/green_docs.md"
accepts "GREEN with a Docs-only: line passes" \
  -- send --to main --from main --subject "gate GREEN: t123" --body-file "$AIMAIL_ROOT/green_docs.md"

accepts "a non-GREEN subject is untouched by the guard" \
  -- send --to main --from main --subject "status update" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "'greenfield' in a subject is not treated as GREEN" \
  -- send --to main --from main --subject "greenfield project kickoff" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "'evergreen' in a subject is not treated as GREEN" \
  -- send --to main --from main --subject "evergreen dependency bump" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "'blue-green' (a hyphen is not a word boundary here) is not treated as GREEN" \
  -- send --to main --from main --subject "blue-green switch workflow" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "'green-light' (a hyphen is not a word boundary here either) is not treated as GREEN" \
  -- send --to main --from main --subject "green-light the deploy" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "an all-caps hyphenated compound is still not a bare GREEN token" \
  -- send --to main --from main --subject "BLUE-GREEN deploy design" --body-file "$AIMAIL_ROOT/green_bare.md"

accepts "lowercase 'green' as its own word is not a verdict (case-sensitive)" \
  -- send --to main --from main --subject "gate green: t123" --body-file "$AIMAIL_ROOT/green_bare.md"

refuses "GREEN followed by punctuation still refuses" "Producer" \
  -- send --to main --from main --subject "Verdict: GREEN." --body-file "$AIMAIL_ROOT/green_bare.md"

printf 'Producer: services/foo.py:12\nShip it.\n' > "$AIMAIL_ROOT/green_onlyproducer.md"
refuses "GREEN with only a producer line is refused, and names the missing one" "Consumer" \
  -- send --to main --from main --subject "GREEN" --body-file "$AIMAIL_ROOT/green_onlyproducer.md"

printf 'Consumer: services/bar.py:34\nShip it.\n' > "$AIMAIL_ROOT/green_onlyconsumer.md"
refuses "GREEN with only a consumer line is refused, and names the missing one" "Producer" \
  -- send --to main --from main --subject "GREEN" --body-file "$AIMAIL_ROOT/green_onlyconsumer.md"

AIMAIL_SEND_GREEN_GUARD=0 accepts "C4: the kill switch lets a bare GREEN through (a human's decision)" \
  -- send --to main --from main --subject "GREEN" --body-file "$AIMAIL_ROOT/green_bare.md"

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
# ⭐ AR-24 — un-acked mail stays VISIBLE on the next deliver, but as a summary line
#   (📎), not a full re-print (📬): the body already printed once, for real, above.
accepts "un-acked mail re-surfaces on the next deliver, as a summary" -- deliver main
if grep -q '📎' "$AIMAIL_ROOT/.out" && ! grep -q '📬' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ re-delivery SUMMARIZED the un-acked mail, did not re-print its body\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("un-acked mail was not summarized on re-delivery")
  printf '  ✖ un-acked mail was not summarized on re-delivery\n'
fi
accepts "ack archives it"                      -- ack main --all --sha "$(_shas_for main)"
ARCHIVED=$(find "$AIMAIL_ROOT/mail/main/archive" -name '*.md' | wc -l)
if (( ARCHIVED > 0 )); then PASS=$((PASS+1)); printf '  ✔ ack archived %s message(s) into a month shard\n' "$ARCHIVED"
else FAIL=$((FAIL+1)); FAILURES+=("ack did not archive"); printf '  ✖ ack did not archive\n'; fi

section "ack --all — AR-23: refuse to archive anything not just shown"
# ⛔ THE DEFECT: `ack --all` swept EVERYTHING in unacked/ unconditionally,
#   whether or not THIS call had actually just seen it. unacked/ is re-printed
#   on every `deliver`, but nothing tied the ack to a delivery that showed the
#   SAME set — a caller (human or seat) could run `ack --all` from a stale or
#   entirely absent context, or ack from a subject-line grep, and it archived
#   silently. Real cost, per assistant: a hard blocker report lost 100 minutes,
#   twice. ⇒ --all now requires a receipt written by `deliver`, matching
#   unacked/ EXACTLY and recent (AIMAIL_ACK_TTL). Explicit-id ack is untouched:
#   naming an id already IS the claim you read that one.
accepts "register a seat for the ack-receipt guard" -- seat add ackguard "ack --all guard"
printf 'first message\n' > "$AIMAIL_ROOT/body1.md"
accepts "send it a message" -- send --to ackguard --from ackguard --subject one --body-file "$AIMAIL_ROOT/body1.md"
accepts "deliver it (writes a fresh, matching receipt)" -- deliver ackguard
# ① a FRESH, matching receipt — ack --all must succeed exactly as before.
accepts "ack --all succeeds right after a matching deliver" -- ack ackguard --all --sha "$(_shas_for ackguard)"
ACKG1=$(find "$AIMAIL_ROOT/mail/ackguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ACKG1 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ the normal case still works: 1 message archived\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("ack --all with a fresh receipt: got $ACKG1 archived, want 1")
  printf '  ✖ ack --all with a fresh receipt: got %s archived, want 1\n' "$ACKG1"
fi
# ② a STALE receipt (delivery happened, but long enough ago that the caller
#    cannot credibly be acting on what it showed) — must refuse.
printf 'second message\n' > "$AIMAIL_ROOT/body2.md"
accepts "send a second message" -- send --to ackguard --from ackguard --subject two --body-file "$AIMAIL_ROOT/body2.md"
accepts "deliver it" -- deliver ackguard
touch -d "@$(( $(date +%s) - 700 ))" "$AIMAIL_ROOT/state/last_delivered/ackguard"
refuses "ack --all refuses on a STALE receipt (AIMAIL_ACK_TTL=600 default)" "does not match a recent delivery" \
  -- ack ackguard --all
ACKG2=$(find "$AIMAIL_ROOT/mail/ackguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ACKG2 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ the second message was NOT archived on a stale receipt\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("stale-receipt refusal still archived: now $ACKG2 total")
  printf '  ✖ stale-receipt refusal still archived — now %s total\n' "$ACKG2"
fi
# ③ a MISMATCHED receipt — something is sitting in unacked/ that the most
#    recent delivery never actually printed (e.g. a second, concurrent poller
#    wrote it after this caller's `deliver`). Must refuse even though the
#    receipt is fresh.
printf 'never shown\n' > "$AIMAIL_ROOT/mail/ackguard/unacked/20990101T000000-injected-not-really-delivered-0.md"
refuses "ack --all refuses when unacked/ has something the receipt never covered" "does not match a recent delivery" \
  -- ack ackguard --all
ACKG3=$(find "$AIMAIL_ROOT/mail/ackguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ACKG3 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ the un-shown message was NOT archived on a mismatched receipt\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("mismatched-receipt refusal still archived: now $ACKG3 total")
  printf '  ✖ mismatched-receipt refusal still archived — now %s total\n' "$ACKG3"
fi
# ④ --force is still a real escape hatch for a deliberate, eyes-open sweep.
accepts "ack --all --force sweeps it anyway" -- ack ackguard --all --force
ACKG4=$(find "$AIMAIL_ROOT/mail/ackguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ACKG4 == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ --force archived all 3, bypassing the receipt check\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("--force did not sweep everything: got $ACKG4 want 3")
  printf '  ✖ --force did not sweep everything: got %s, want 3\n' "$ACKG4"
fi

section "ack --all — AR-28: naming every message's own sha is the claim you opened it"
# ⛔ THE DEFECT: AR-23's receipt check only proves a delivery just happened, not
#   that anything was read — a caller can chain `poll` -> `ack --all` as a fixed
#   idiom and satisfy AR-23 every single time without attending to content.
#   MEASURED live in this fleet. ⇒ --all also requires --sha naming an 8+ hex
#   prefix of EVERY target's own body-sha256, one per target.
accepts "register a seat for the sha-guard" -- seat add shaguard "ack --all sha guard"
printf 'sha guard body one\n' > "$AIMAIL_ROOT/shabody1.md"
printf 'sha guard body two\n' > "$AIMAIL_ROOT/shabody2.md"
accepts "send message one" -- send --to shaguard --from shaguard --subject shaone --body-file "$AIMAIL_ROOT/shabody1.md"
accepts "send message two" -- send --to shaguard --from shaguard --subject shatwo --body-file "$AIMAIL_ROOT/shabody2.md"
accepts "deliver both (fresh receipt)" -- deliver shaguard
SHA_BOTH="$(_shas_for shaguard)"
SHA_ONE="${SHA_BOTH%%,*}"
# ① no --sha at all — must refuse, even with a perfectly fresh receipt.
refuses "ack --all with NO --sha refuses despite a fresh receipt" "missing --sha" \
  -- ack shaguard --all
SG1=$(find "$AIMAIL_ROOT/mail/shaguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( SG1 == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ neither message was archived without --sha\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("ack --all with no --sha still archived $SG1")
  printf '  ✖ ack --all with no --sha still archived %s\n' "$SG1"
fi
# ② --sha naming only ONE of the two targets — must refuse (partial coverage).
refuses "ack --all naming only 1 of 2 shas refuses" "missing --sha" \
  -- ack shaguard --all --sha "$SHA_ONE"
SG2=$(find "$AIMAIL_ROOT/mail/shaguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( SG2 == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ partial --sha coverage archived neither message\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("partial --sha coverage still archived $SG2")
  printf '  ✖ partial --sha coverage still archived %s\n' "$SG2"
fi
# ③ a fabricated sha that matches nothing real — must refuse exactly like ②.
refuses "ack --all with a made-up sha refuses" "missing --sha" \
  -- ack shaguard --all --sha "deadbeef0000,$SHA_ONE"
SG3=$(find "$AIMAIL_ROOT/mail/shaguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( SG3 == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ a fabricated sha alongside one real one still refused\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("fabricated sha still archived $SG3")
  printf '  ✖ fabricated sha still archived %s\n' "$SG3"
fi
# ④ both real shas, as an 8-char prefix each — must succeed.
accepts "ack --all naming both messages' own sha prefixes succeeds" \
  -- ack shaguard --all --sha "$(printf '%s\n' "${SHA_BOTH//,/$'\n'}" | cut -c1-8 | paste -sd, -)"
SG4=$(find "$AIMAIL_ROOT/mail/shaguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( SG4 == 2 )); then
  PASS=$((PASS+1)); printf '  ✔ both messages archived once every sha was named (8-char prefixes accepted)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("naming both sha prefixes archived $SG4, want 2")
  printf '  ✖ naming both sha prefixes archived %s, want 2\n' "$SG4"
fi
# ⑤ --force still bypasses AR-28 too, as a deliberate, nameable unread sweep.
printf 'sha guard body three\n' > "$AIMAIL_ROOT/shabody3.md"
accepts "send a third message" -- send --to shaguard --from shaguard --subject shathree --body-file "$AIMAIL_ROOT/shabody3.md"
accepts "deliver it" -- deliver shaguard
accepts "ack --all --force still bypasses AR-28 with no --sha" -- ack shaguard --all --force
SG5=$(find "$AIMAIL_ROOT/mail/shaguard/archive" -name '*.md' 2>/dev/null | wc -l)
if (( SG5 == 3 )); then
  PASS=$((PASS+1)); printf '  ✔ --force archived the third message with no --sha required\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("--force with no --sha archived $SG5, want 3")
  printf '  ✖ --force with no --sha archived %s, want 3\n' "$SG5"
fi

section "deliver — AR-24: a seat that can never ack must still stay usably reachable"
# ⛔⛔ THE DEFECT (operator ruling, 2026-08-07): re-printing the FULL un-acked backlog on
#   every wake has no escape hatch. A seat whose OWN ack is refused — for any reason,
#   permanently — can never shrink unacked/, so every new arrival re-triggers a full
#   reprint of an ever-growing pile. MEASURED on assistant's real seat: 27 and climbing,
#   cost compounding with no way to ever pay it down — the rule built to guarantee mail
#   is read guarantees the seat becomes UNREACHABLE once acking stops working at all.
# ▶ ACCEPTANCE TEST (assistant's own ③, verbatim): a seat with N un-acked messages and NO
#   ability to ack can still receive message N+1 — cheaply, and the old N stay VISIBLE.
accepts "register a seat that will never ack" -- seat add neverack "acking is permanently blocked here"
for i in $(seq 1 12); do
  printf 'body of message %s\n' "$i" > "$AIMAIL_ROOT/nb$i.md"
  "$AIMAIL" send --to neverack --from neverack --subject "backlog $i" --body-file "$AIMAIL_ROOT/nb$i.md" >/dev/null 2>&1
done
accepts "first deliver shows all 12 in full (nothing has ever been shown yet)" -- deliver neverack
N1=$(grep -c '📬' "$AIMAIL_ROOT/.out")
if (( N1 == 12 )); then
  PASS=$((PASS+1)); printf '  ✔ all 12 printed in full on the first delivery (correct one-time catch-up)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("first delivery of backlog: got $N1 full prints, want 12")
  printf '  ✖ first delivery of backlog: got %s full prints, want 12\n' "$N1"
fi
# Simulate "ack is permanently refused": simply never ack. Send message 13.
printf 'body of message 13 — the one that must still arrive\n' > "$AIMAIL_ROOT/nb13.md"
accepts "send message 13, with 12 un-ackable messages still outstanding" \
  -- send --to neverack --from neverack --subject "backlog 13 — the new one" --body-file "$AIMAIL_ROOT/nb13.md"
accepts "second deliver: message 13 arrives, the 12 are summarized, not re-printed" -- deliver neverack
N2_FULL=$(grep -c '📬' "$AIMAIL_ROOT/.out")
if (( N2_FULL == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ message 13 (only) printed in full — got %s full print(s)\n' "$N2_FULL"
else
  FAIL=$((FAIL+1)); FAILURES+=("second delivery full-print count: got $N2_FULL, want 1")
  printf '  ✖ second delivery full-print count: got %s, want 1 (backlog leaked into a re-print)\n' "$N2_FULL"
fi
if grep -q "12 previously-shown message(s) remain UN-ACKED" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the 12 un-ackable messages are still VISIBLY reported as outstanding\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("the 12 outstanding messages were not visibly reported")
  printf '  ✖ the 12 outstanding messages were not visibly reported (silently forgotten?)\n'
fi
# ⭐ Prove it does not degrade further: a THIRD delivery with nothing new must cost the
#   same near-zero amount — the summary must not itself start re-growing into bodies.
accepts "third deliver, nothing new: still zero full re-prints of the backlog" -- deliver neverack
N3_FULL=$(grep -c '📬' "$AIMAIL_ROOT/.out")
if (( N3_FULL == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ third delivery: zero full re-prints — the cost never grows back\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("third delivery re-printed $N3_FULL message body(ies)")
  printf '  ✖ third delivery re-printed %s message body(ies) — the fix regressed under repetition\n' "$N3_FULL"
fi
# The receipt (AR-23) must still cover the summarized messages, so a seat that DOES
# regain the ability to ack is not permanently locked out of ever clearing them.
accepts "ack --all still clears the summarized backlog once acking works again" -- ack neverack --all --sha "$(_shas_for neverack)"
ARCHIVED_NA=$(find "$AIMAIL_ROOT/mail/neverack/archive" -name '*.md' 2>/dev/null | wc -l)
if (( ARCHIVED_NA == 13 )); then
  PASS=$((PASS+1)); printf '  ✔ all 13 archived once ack ran — summarizing never blocked eventual acking\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("ack --all after summarizing: got $ARCHIVED_NA archived, want 13")
  printf '  ✖ ack --all after summarizing: got %s archived, want 13\n' "$ARCHIVED_NA"
fi

section "show — AR-25: a body shown somewhere unread must still be recoverable"
# ⛔⛔ THE DEFECT (audit, 2026-08-07 12:03): `aimail poll <seat>` is a harness-tracked
#   BACKGROUND task — the body it prints lands in the task's own output file, not the
#   calling session's context. A seat notified the task finished, who then reads only
#   the documented path (`aimail deliver <seat>`), got a one-line summary — the message
#   was genuinely SHOWN (bytes left the process), just never to a reader who was there.
#   MEASURED: a gate approval and an authoring notice were both lost this way, recovered
#   only by reading unacked/*.md off disk by hand — not a documented command.
accepts "register a seat for the show recovery path" -- seat add showseat "recovery guard"
printf 'the body that must remain recoverable\n' > "$AIMAIL_ROOT/showbody.md"
accepts "send it a message" -- send --to showseat --from showseat --subject "recover me" --body-file "$AIMAIL_ROOT/showbody.md"
accepts "first deliver shows it in full" -- deliver showseat
SHOW_ID=$(basename "$(ls "$AIMAIL_ROOT/mail/showseat/unacked/"*.md | head -1)")
accepts "second deliver: summarized, not re-printed (this is the exposure)" -- deliver showseat
if grep -q '📬' "$AIMAIL_ROOT/.out"; then
  FAIL=$((FAIL+1)); FAILURES+=("second deliver unexpectedly re-printed in full")
  printf '  ✖ second deliver unexpectedly re-printed in full\n'
else
  PASS=$((PASS+1)); printf '  ✔ confirmed: second deliver only summarizes, exactly as AR-24 intends\n'
fi
accepts "show re-prints it in full, unconditionally, despite being 'already shown'" \
  -- show showseat "$SHOW_ID"
if grep -qF "the body that must remain recoverable" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the full body was recovered via show — the exact defect this closes\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("show did not recover the full body")
  printf '  ✖ show did not recover the full body\n'
fi
refuses "show on an unknown id is refused, names where it looked" "checked unacked" \
  -- show showseat "totally-fabricated-id-0"
# show must also work on mail that was NEVER delivered at all (still in the raw inbox) —
# a seat should not need to know delivery state to read a specific message by id.
printf 'never delivered, read directly by id\n' > "$AIMAIL_ROOT/showbody2.md"
accepts "send a second message, do not deliver it" \
  -- send --to showseat --from showseat --subject "undelivered" --body-file "$AIMAIL_ROOT/showbody2.md"
UNDELIVERED_ID=$(basename "$(ls "$AIMAIL_ROOT/mail/showseat/"*.md | head -1)")
accepts "show finds it straight from the inbox, without ever calling deliver" \
  -- show showseat "$UNDELIVERED_ID"
if grep -qF "never delivered, read directly by id" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ show reads directly from the inbox — delivery state is not a precondition\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("show could not read an undelivered message from the inbox")
  printf '  ✖ show could not read an undelivered message from the inbox\n'
fi

section "unread — list what's un-acked, not just its count (companion to AR-25 show)"
# ⛔⛔ `status` gives a bare COUNT of un-acked mail; recovering a missed showing
#   still meant listing unacked/*.md off disk by hand to find an id for `show`
#   (fable, 2026-09-01 ruling: "so recovery never requires archive spelunking").
accepts "register a seat for the unread listing" -- seat add unreadseat "unread listing guard"
accepts "unread on a freshly-registered seat with nothing sent" -- unread unreadseat
if grep -qi "no un-acked mail" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ empty backlog reported as empty, not silently blank\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unread on an empty backlog gave no explanation")
  printf '  ✖ unread on an empty backlog gave no explanation\n'
fi
printf 'first body\n' > "$AIMAIL_ROOT/unread1.md"
printf 'second body\n' > "$AIMAIL_ROOT/unread2.md"
accepts "send message one" -- send --to unreadseat --from unreadseat --subject "first subject" --body-file "$AIMAIL_ROOT/unread1.md"
sleep 1
accepts "send message two" -- send --to unreadseat --from unreadseat --subject "second subject" --body-file "$AIMAIL_ROOT/unread2.md"
accepts "deliver both (now sitting in unacked/)" -- deliver unreadseat
accepts "unread lists both, oldest first" -- unread unreadseat
if grep -qF "2 un-acked" "$AIMAIL_ROOT/.out" \
   && grep -qF "first subject" "$AIMAIL_ROOT/.out" \
   && grep -qF "second subject" "$AIMAIL_ROOT/.out" \
   && [[ "$(grep -n "first subject" "$AIMAIL_ROOT/.out" | cut -d: -f1)" -lt "$(grep -n "second subject" "$AIMAIL_ROOT/.out" | cut -d: -f1)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ both un-acked messages listed, oldest first, subjects visible\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unread did not list both un-acked messages in order")
  printf '  ✖ unread did not list both un-acked messages in order\n'
fi
UNREAD_ID=$(grep -oE '[0-9]{8}T[0-9]{6}-unreadseat-first-subject-[0-9]+' "$AIMAIL_ROOT/.out" | head -1)
accepts "an id from unread's listing is exactly what show accepts" -- show unreadseat "$UNREAD_ID"
if grep -qF "first body" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ unread'"'"'s listed id fed straight into show, no disk-spelunking needed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("an id from unread could not be shown")
  printf '  ✖ an id from unread could not be shown\n'
fi
accepts "ack both away" -- ack unreadseat --all --sha "$(_shas_for unreadseat)"
accepts "unread is empty again once acked" -- unread unreadseat
if grep -qi "no un-acked mail" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ acked mail drops out of the unread listing\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("acked mail still appeared in the unread listing")
  printf '  ✖ acked mail still appeared in the unread listing\n'
fi
refuses "unread with no seat argument is refused" "usage: aimail unread" -- unread

section "recent — ISSUES item 4: a durable index that survives ack, unlike unread"
# ⛔ THE DEFECT UNDER TEST: `unread` (above) answers "what's still outstanding"
#   and empties the instant a message is acked — precisely the moment a seat is
#   most likely to want to look back at it (project owner: "as soon as it's read once
#   and you need to go back to it"). `recent` is a separate, durable log.
accepts "register a seat for the recent-index guard" -- seat add recentseat "recent index guard"
accepts "recent on a freshly-registered seat with nothing sent" -- recent recentseat
if grep -qi "no recent mail recorded" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ empty index reported as empty, not silently blank\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("recent on an empty index gave no explanation")
  printf '  ✖ recent on an empty index gave no explanation\n'
fi
printf 'recent body one\n' > "$AIMAIL_ROOT/recent1.md"
printf 'recent body two\n' > "$AIMAIL_ROOT/recent2.md"
accepts "send message one" -- send --to recentseat --from recentseat --subject "recent subject one" --body-file "$AIMAIL_ROOT/recent1.md"
sleep 1
accepts "send message two" -- send --to recentseat --from recentseat --subject "recent subject two" --body-file "$AIMAIL_ROOT/recent2.md"
accepts "deliver both" -- deliver recentseat
accepts "recent lists both, most-recent first" -- recent recentseat
if grep -qF "2 message" "$AIMAIL_ROOT/.out" \
   && grep -qF "recent subject one" "$AIMAIL_ROOT/.out" \
   && grep -qF "recent subject two" "$AIMAIL_ROOT/.out" \
   && [[ "$(grep -n "recent subject two" "$AIMAIL_ROOT/.out" | cut -d: -f1)" -lt "$(grep -n "recent subject one" "$AIMAIL_ROOT/.out" | cut -d: -f1)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ both messages listed, most-recent first, subjects visible\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("recent did not list both messages in the right order")
  printf '  ✖ recent did not list both messages in the right order\n'
fi
RECENT_ID=$(grep -oE '[0-9]{8}T[0-9]{6}-recentseat-recent-subject-two-[0-9]+' "$AIMAIL_ROOT/.out" | head -1)
accepts "an id from recent's listing is exactly what show accepts" -- show recentseat "$RECENT_ID"
if grep -qF "recent body two" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ recent'"'"'s listed id fed straight into show, no disk-spelunking needed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("an id from recent could not be shown")
  printf '  ✖ an id from recent could not be shown\n'
fi
# ⭐ THE CORE PROPERTY: unlike `unread`, acking must NOT remove the entry.
accepts "ack both away" -- ack recentseat --all --sha "$(_shas_for recentseat)"
accepts "recent STILL lists both after ack -- the durability unread does not have" -- recent recentseat
if grep -qF "2 message" "$AIMAIL_ROOT/.out" \
   && grep -qF "recent subject one" "$AIMAIL_ROOT/.out" \
   && grep -qF "recent subject two" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ acked mail still findable in recent (unread would have emptied)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("recent lost its entries once the messages were acked")
  printf '  ✖ recent lost its entries once the messages were acked\n'
fi
accepts "unread is empty once acked (the contrasting companion)" -- unread recentseat
if grep -qi "no un-acked mail" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ unread empties on ack while recent does not -- the two are genuinely different views\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unread still listed acked mail -- companion contrast broken")
  printf '  ✖ unread still listed acked mail -- companion contrast broken\n'
fi
accepts "recent N=1 returns only the single most recent entry" -- recent recentseat 1
if grep -qF "1 message" "$AIMAIL_ROOT/.out" && grep -qF "recent subject two" "$AIMAIL_ROOT/.out" \
   && ! grep -qF "recent subject one" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ N limits the listing to the N most recent, dropping the older one\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("recent with N=1 did not limit correctly")
  printf '  ✖ recent with N=1 did not limit correctly\n'
fi
refuses "recent with a non-numeric N is refused" "must be a positive integer" -- recent recentseat notanumber
refuses "recent with N=0 is refused" "must be a positive integer" -- recent recentseat 0
refuses "recent with no seat argument is refused" "usage: aimail recent" -- recent
# A summarized re-print (already-shown, still un-acked) must not duplicate the
# entry -- exactly the AR-24 backlog case `_recent_record` is placed to skip.
accepts "register a seat for the no-duplicate-on-summary guard" -- seat add recentdup "recent no-dup guard"
printf 'dup body\n' > "$AIMAIL_ROOT/recentdup.md"
accepts "send one message" -- send --to recentdup --from recentdup --subject "dup subject" --body-file "$AIMAIL_ROOT/recentdup.md"
accepts "deliver once (shown in full)" -- deliver recentdup
accepts "deliver again (same message, now only a summary line)" -- deliver recentdup
accepts "recent still shows exactly one entry, not two" -- recent recentdup
if [[ "$(grep -c "dup subject" "$AIMAIL_ROOT/.out")" -eq 1 ]]; then
  PASS=$((PASS+1)); printf '  ✔ a re-delivered summary line does not duplicate the recent-index entry\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a summarized re-delivery duplicated the recent-index entry")
  printf '  ✖ a summarized re-delivery duplicated the recent-index entry\n'
fi

section "where — a state, never a count"
accepts "where finds an archived message"      -- where main ok
# ⛔ The distinction this asserts is the whole point: `ls | wc -l` returns 0 both
#    when mail was delivered-and-consumed and when it was NEVER WRITTEN. Those
#    are opposite facts, and the previous system reported the second as the
#    first. A miss must exit 4 (UNMEASURABLE), never 0 with a count of zero.
unmeasurable_test "a message that never existed is UNMEASURABLE, not 0" "no message matching" \
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
NOW=$(date +%s)   # beat must be FRESH when fleet reads it (WEDGED limit = interval*6+30 s; a shared NOW goes stale under load)
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
NOW=$(date +%s)   # recaptured: the "fresh" park heartbeat is NOW-2, so a NOW taken before the fleet calls above is already stale when fleet reads it on a loaded machine
_hb main pid=$$ started=$((NOW-600)) beat=$((NOW-90)) park_beat=$((NOW-2))
_fleet_says main "PARKED" "a parked poller (stale beat, fresh park heartbeat) reads PARKED, not WEDGED"
# ③ the other direction — a park heartbeat that has ALSO gone stale must still
#    alarm. Having parked once must not permanently immunise a seat from WEDGED.
_hb main pid=$$ started=$((NOW-9000)) beat=$((NOW-9000)) park_beat=$((NOW-9000))
_fleet_says main "WEDGED" "a stale park heartbeat still alarms — parking once does not mask a later hang"
rm -f "$AIMAIL_ROOT/state/poller/main.hb"

# ⛔⛔ A FRESH beat NEWER than a stale exit_at, with a `pid` that fails
#   `kill -0` (the exact shape measured live: exit_at=1787500677 beat=1787500884,
#   a 207s gap, alongside a CONFIRMED-alive poller process whose pid the
#   heartbeat file did not happen to record). The predecessor required `alive`
#   (a `kill -0` on that recorded pid) to agree before reporting ARMED, so a
#   fragile pid binding — stale from an earlier `hb_start`, never touched by a
#   later `hb_beat`, which only ever rewrites the `beat` key — reported CRASHED
#   for a seat that was, by the very evidence in its own heartbeat, still
#   ticking. This fired the sweep alarm repeatedly while the seat worked.
NOW=$(date +%s)   # recaptured: under load the fleet calls above can age a NOW-3 beat past the ARMED window (R6(j), 2026-09-23)
_hb main pid=999999 started=$((NOW-600)) beat=$((NOW-3)) exit_at=$((NOW-210)) exit_reason=mail
_fleet_says main "ARMED" "a fresh beat outranks a stale exit_at even when the recorded pid is not alive"
rm -f "$AIMAIL_ROOT/state/poller/main.hb"

# ⭐⭐⭐ WEDGED-SYNC (slice 2, fable's poll-persistent wedge design) — a persistent poller
#   beats its heartbeat perfectly well even while running as a plain Bash call outside any
#   Monitor, so a FRESH beat (which would otherwise read plain ARMED) can never by itself
#   distinguish that case from the real 2026-09-22 incident (heartbeat healthy, the calling
#   SESSION synchronously blocked for hours). The one signal that can see it: the process's
#   own real elapsed time (`ps -o etimes=`) past the SAME knob slice 1's self-limit uses.
#   Reuses this script's own pid ($$, real and alive) rather than a synthetic one, same
#   discipline as the plain ARMED positive control above — a deliberate `sleep` (not ambient
#   test-suite elapsed time, which would make this flaky depending on where in the file it
#   runs) guarantees real etimes clears a tiny 1s knob + its 2-tick grace.
sleep 4
NOW=$(date +%s)   # beat must be FRESH when fleet reads it (WEDGED limit = interval*6+30 s; a shared NOW goes stale under load)
_hb main pid=$$ started=$((NOW-600)) beat=$NOW persistent=1
if AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=1 AIMAIL_POLL_INTERVAL=1 "$AIMAIL" fleet main > "$AIMAIL_ROOT/.out" 2>&1 \
   && grep -qE '^main +WEDGED-SYNC' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ a fresh-beating persistent poller past the max-age+grace bound reads WEDGED-SYNC, not ARMED\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("persistent poller past max-age did not read WEDGED-SYNC")
  printf '  ✖ persistent poller past max-age did not read WEDGED-SYNC — got: %s\n' "$(grep -E '^main ' "$AIMAIL_ROOT/.out" 2>/dev/null | head -1)"
fi

# ⭐ CONTROL 1: the SAME old pid/beat, but persistent=0 (a classic `poll`) must NOT trip
#   WEDGED-SYNC — proves the check is gated on the marker, not on age alone (a classic poll
#   can legitimately sit alive a long time in its own plain mail-wait loop, no bug there).
# ⚠ `beat` must be FRESH at the moment `fleet` reads it: with AIMAIL_POLL_INTERVAL=1 the WEDGED limit is
#   interval*6+30 = 36s, and the section's shared $NOW was captured well over 36s earlier under load
#   (2026-09-22: "falsely tripped WEDGED-SYNC -- got: main WEDGED ... HUNG", twice, load 18-20). A stale
#   $NOW turns an ARMED-vs-WEDGED-SYNC arm into a WEDGED arm about the box, not the detector.
NOW=$(date +%s)
_hb main pid=$$ started=$((NOW-600)) beat=$NOW persistent=0
if AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=1 AIMAIL_POLL_INTERVAL=1 "$AIMAIL" fleet main > "$AIMAIL_ROOT/.out" 2>&1 \
   && grep -qE '^main +ARMED' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the SAME age reads plain ARMED when persistent=0 — gated on the marker, not age alone\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a classic (non-persistent) poller falsely tripped WEDGED-SYNC")
  printf '  ✖ a classic (non-persistent) poller falsely tripped WEDGED-SYNC — got: %s\n' "$(grep -E '^main ' "$AIMAIL_ROOT/.out" 2>/dev/null | head -1)"
fi

# ⭐ CONTROL 2: persistent=1, but the max-age knob is high enough that this process's real
#   age never reaches it — must read plain ARMED. Proves the check is a real age comparison,
#   not a tautological always-fires-when-persistent path.
NOW=$(date +%s)   # beat must be FRESH when fleet reads it (WEDGED limit = interval*6+30 s; a shared NOW goes stale under load)
_hb main pid=$$ started=$((NOW-600)) beat=$NOW persistent=1
if AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=999999 "$AIMAIL" fleet main > "$AIMAIL_ROOT/.out" 2>&1 \
   && grep -qE '^main +ARMED' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ persistent=1 with a high max-age knob reads ARMED — not a tautological check\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("WEDGED-SYNC fired even with a high max-age knob (tautological check)")
  printf '  ✖ WEDGED-SYNC fired even with a high max-age knob — got: %s\n' "$(grep -E '^main ' "$AIMAIL_ROOT/.out" 2>/dev/null | head -1)"
fi

# ⭐ ABSENT MARKER: a heartbeat with no `persistent` key at all (pre-dating this slice) must
#   default to "not known to be persistent" and never trip WEDGED-SYNC — the safe direction
#   for a brand-new detector reading data written before it existed.
# ⚠ `beat` must be FRESH at the moment `fleet` reads it: with AIMAIL_POLL_INTERVAL=1 the WEDGED limit is
#   interval*6+30 = 36s, and the section's shared $NOW was captured well over 36s earlier under load
#   (2026-09-22: "falsely tripped WEDGED-SYNC -- got: main WEDGED ... HUNG", twice, load 18-20). A stale
#   $NOW turns an ARMED-vs-WEDGED-SYNC arm into a WEDGED arm about the box, not the detector.
NOW=$(date +%s)
_hb main pid=$$ started=$((NOW-600)) beat=$NOW
if AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=1 AIMAIL_POLL_INTERVAL=1 "$AIMAIL" fleet main > "$AIMAIL_ROOT/.out" 2>&1 \
   && grep -qE '^main +ARMED' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ a heartbeat with no persistent marker at all defaults to ARMED, never WEDGED-SYNC\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a pre-slice heartbeat (no persistent marker) falsely tripped WEDGED-SYNC")
  printf '  ✖ a pre-slice heartbeat (no persistent marker) falsely tripped WEDGED-SYNC — got: %s\n' "$(grep -E '^main ' "$AIMAIL_ROOT/.out" 2>/dev/null | head -1)"
fi
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

section "migrate — AR-16: a dot-path SOURCE must not lose its whole archive"
# ⛔⛔ THE DEFECT: the archive loop's `-not -path '*/.*'` matches the WHOLE path
#   find was given, including the CALLER's own $src prefix — so migrating
#   FROM a dot-path (a real predecessor mailbox commonly lives under
#   ~/.claude/...) excluded EVERY file, not just tooling directories. Prove it
#   with the literal shape: a source nested under a dot-path.
DOTSRC="$AIMAIL_ROOT/.hidden/oldbox"
mkdir -p "$DOTSRC/dotseat/archive"
printf 'old mail from a dot-path source\n' > "$DOTSRC/dotseat/archive/msg1.md"
accepts "migrate from a dot-path source" -- migrate "$DOTSRC"
if find "$AIMAIL_ROOT/mail/dotseat" -name '*.md' 2>/dev/null | grep -q .; then
  PASS=$((PASS+1)); printf '  ✔ the archive imported despite the source living under a dot-path\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-16: migrate from a dot-path source imported nothing")
  printf '  ✖ AR-16: migrate from a dot-path source imported NOTHING — the whole archive was lost\n'
fi

section "migrate — AR-15: the reconciliation must be FALSIFIABLE, not just agree with itself"
# ⛔⛔ THE DEFECT: the old check compared the numerator (the WHOLE target tree)
#   against a denominator (discovered seats only, excluding `*/_*`) computed by
#   a DIFFERENT rule — so a target that already held other mail could make a
#   real partial copy read as "✔ complete", the review's own "12 of 5" shape.
#   Force a REAL cp failure (a read-only destination shard) — not a stub —
#   with unrelated mail ALREADY in the target, which is exactly the condition
#   that made the old check blind to it.
accepts "register the pre-existing seat" -- seat add unrelated-preexisting "pre-existing, unrelated"
mkdir -p "$AIMAIL_ROOT/mail/unrelated-preexisting/archive/2026-01"
for _n in 1 2 3 4; do printf 'pre-existing, unrelated to this migration\n' \
  > "$AIMAIL_ROOT/mail/unrelated-preexisting/archive/2026-01/pre$_n.md"; done
FAILSRC="$AIMAIL_ROOT/failbox"
mkdir -p "$FAILSRC/failseat/archive"
printf 'msg one\n' > "$FAILSRC/failseat/archive/2026-01-msg1.md"
touch -d '2026-01-15' "$FAILSRC/failseat/archive/2026-01-msg1.md"
printf 'msg two\n' > "$FAILSRC/failseat/archive/2026-02-msg2.md"
touch -d '2026-02-15' "$FAILSRC/failseat/archive/2026-02-msg2.md"
mkdir -p "$AIMAIL_ROOT/mail/failseat/archive/2026-02"
chmod 555 "$AIMAIL_ROOT/mail/failseat/archive/2026-02"
"$AIMAIL" migrate "$FAILSRC" >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
chmod 755 "$AIMAIL_ROOT/mail/failseat/archive/2026-02" 2>/dev/null
if grep -q 'RECONCILIATION FAILED' "$AIMAIL_ROOT/.out" "$AIMAIL_ROOT/.err" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a real, forced partial copy is reported as a RECONCILIATION FAILURE\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-15: a real partial copy was NOT reported as a reconciliation failure")
  printf '  ✖ AR-15: a real, forced partial copy did NOT trigger a reconciliation failure\n'
fi
if grep -qE '✔.*(complete|reconciled)' "$AIMAIL_ROOT/.out" 2>/dev/null; then
  FAIL=$((FAIL+1)); FAILURES+=("AR-15: a success line was printed despite the forced partial copy")
  printf '  ✖ AR-15: a success line was ALSO printed — false success alongside the failure\n'
else
  PASS=$((PASS+1)); printf '  ✔ no success line was printed for the seat with the forced failure\n'
fi

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

section "supervisor_guard — selftest in-suite, incl. the real \`aimail fleet\` -> marker -> hook wiring"
# ⚠ Same lesson as stop_guard above: a selftest outside the suite proves nothing on its own.
# The rc AND an expected arm count are asserted, not a tally of printed lines (see the
# stop_guard block's WHY). The two "wiring" arms are the point (2026-09-21, code-review's
# gap on the load balancer landing): every earlier arm touched the marker by hand, so a
# refactor that dropped bin/aimail's supervisor_scan_touch call, or moved the marker in
# core.sh but not in the hook, left the selftest green and the supervisor seat wedged. The three
# "configurable" arms (code-review 19087f6b, fable #276) use a NON-default AIMAIL_SUPERVISOR so a
# hardcoded "assistant" on either side (touch gate or hook) goes red instead of matching by coincidence.
SPG_EXPECTED_ARMS=12
SPG="$(bash "$REPO/hooks/supervisor_guard.sh" selftest 2>&1)"; SPG_RC=$?
while IFS= read -r line; do
  case "$line" in
    *"✔"*) PASS=$((PASS+1)); printf '  %s\n' "$line" ;;
    *"✖"*) FAIL=$((FAIL+1)); FAILURES+=("supervisor_guard: $line"); printf '  %s\n' "$line" ;;
  esac
done <<< "$SPG"
SPG_ARMS="$(printf '%s\n' "$SPG" | grep -cE '✔|✖')"
if [[ $SPG_RC -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ supervisor_guard selftest exited 0\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("supervisor_guard selftest exit=$SPG_RC")
  printf '  ✖ supervisor_guard selftest exited %s — its arms did not run to completion\n' "$SPG_RC"
fi
if [[ $SPG_ARMS -eq $SPG_EXPECTED_ARMS ]]; then
  PASS=$((PASS+1)); printf '  ✔ supervisor_guard reported all %s arms\n' "$SPG_EXPECTED_ARMS"
else
  FAIL=$((FAIL+1)); FAILURES+=("supervisor_guard arms: got $SPG_ARMS want $SPG_EXPECTED_ARMS")
  printf '  ✖ supervisor_guard reported %s arms, expected %s — arms went MISSING, not failing\n' "$SPG_ARMS" "$SPG_EXPECTED_ARMS"
fi
for _w in "wiring: real" "NON-supervisor session leaves no marker" "touch gate reads the variable" "hook reads the variable"; do
  if printf '%s\n' "$SPG" | grep -qF "✔ $_w" || printf '%s\n' "$SPG" | grep -q "✔ .*$_w"; then
    PASS=$((PASS+1)); printf '  ✔ wiring arm present and green: %s\n' "$_w"
  else
    FAIL=$((FAIL+1)); FAILURES+=("supervisor_guard wiring arm missing/red: $_w")
    printf '  ✖ wiring arm missing or red: %s\n' "$_w"
  fi
done

section "ccusage — the PATH install is used, npx only as the fallback; one call per account per TTL, shared across callers (2026-09-22 machine load)"
CCSTUB="$AIMAIL_ROOT/ccstub"; rm -rf "$CCSTUB"; mkdir -p "$CCSTUB"
cat > "$CCSTUB/ccusage" <<'CC'
#!/usr/bin/env bash
echo "ccusage $*" >> "${CC_MARKS:?}"
python3 -c "
import json,datetime
now=datetime.datetime.now(datetime.timezone.utc); end=now+datetime.timedelta(minutes=100); start=end-datetime.timedelta(hours=5)
print(json.dumps({'blocks':[{'isActive':True,'startTime':start.isoformat().replace('+00:00','Z'),'endTime':end.isoformat().replace('+00:00','Z'),'totalTokens':1,'costUSD':0.01,'projection':{'remainingMinutes':100},'burnRate':{'tokensPerMinuteForIndicator':1}}]}))"
CC
cat > "$CCSTUB/npx" <<'NPX'
#!/usr/bin/env bash
echo "npx $*" >> "${CC_MARKS:?}"; exec "${CC_STUBDIR:?}/ccusage" "${@:3}"
NPX
chmod +x "$CCSTUB/ccusage" "$CCSTUB/npx"
_cc_run() { # <PATH dir(s)> -- block_json in a fresh shell with only those dirs (and system bins) on PATH
  env -i HOME="$HOME" PATH="$1:/usr/bin:/bin" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null CC_MARKS="$AIMAIL_ROOT/cc_marks" CC_STUBDIR="$CCSTUB" \
    bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; ensure_dirs; block_json" 2>/dev/null
}
_ccchk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); FAILURES+=("ccusage: $1 (want=$3 got=$2)"); printf '  ✖ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
rm -f "$AIMAIL_ROOT"/state/block.*.json "$AIMAIL_ROOT/cc_marks"
out="$(_cc_run "$CCSTUB")"
_ccchk "with a ccusage on PATH, block_json returns the blocks JSON" "$(grep -c isActive <<<"$out")" 1
_ccchk "…the PATH ccusage ran, with 'blocks --json'" "$(grep -c '^ccusage blocks --json' "$AIMAIL_ROOT/cc_marks" 2>/dev/null)" 1
_ccchk "…and npx did NOT run" "$(grep -c '^npx' "$AIMAIL_ROOT/cc_marks" 2>/dev/null)" 0
out="$(_cc_run "$CCSTUB")"; out="$(_cc_run "$CCSTUB")"
_ccchk "two more callers inside the TTL (another seat, the autopilot) read the shared per-account cache: still ONE ccusage call" "$(grep -c '^ccusage' "$AIMAIL_ROOT/cc_marks")" 1
NPXONLY="$AIMAIL_ROOT/ccstub_npxonly"; rm -rf "$NPXONLY"; mkdir -p "$NPXONLY"; cp "$CCSTUB/npx" "$NPXONLY/npx"
rm -f "$AIMAIL_ROOT"/state/block.*.json "$AIMAIL_ROOT/cc_marks"
out="$(_cc_run "$NPXONLY")"
_ccchk "FALSIFICATION: with no ccusage on PATH, the npx fallback runs (--yes ccusage@latest blocks --json)" "$(grep -c '^npx --yes ccusage@latest blocks --json' "$AIMAIL_ROOT/cc_marks" 2>/dev/null)" 1
_ccchk "…and still returns the JSON" "$(grep -c isActive <<<"$out")" 1
rm -f "$AIMAIL_ROOT"/state/block.*.json "$AIMAIL_ROOT/cc_marks"
out="$(env -i HOME="$HOME" PATH="/usr/bin:/bin" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; ensure_dirs; block_json; echo rc=\$?" 2>/dev/null | tail -1)"
_ccchk "neither on PATH -> block_json returns 1 (unmeasurable, not a guess)" "$out" "rc=1"
_ccchk "the session reader (balance.sh) resolves through the same helper: AIMAIL_CCUSAGE_BIN seam honoured" "$(env -i HOME="$HOME" PATH="/usr/bin:/bin" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null AIMAIL_CCUSAGE_BIN="$CCSTUB/ccusage" CC_MARKS="$AIMAIL_ROOT/cc_marks2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; source '$REPO/lib/balance.sh'; _bal_ccusage_session_json >/dev/null; grep -c 'ccusage session --json' '$AIMAIL_ROOT/cc_marks2'" 2>/dev/null)" 1
rm -f "$AIMAIL_ROOT"/state/block.*.json

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
  > "$(_block_cache)"
}
# Same as _stub_block but takes an ABSOLUTE epoch for the end time, so a test can pin `be`
# to a specific value (e.g. exactly on a 900s-since-epoch boundary) instead of a relative
# offset from "now" — needed to reproduce the bucket-edge-straddle checkpoint bug below.
_stub_block_at() { # _stub_block_at <epoch-seconds>
  mkdir -p "$AIMAIL_ROOT/state"
  python3 -c "
import json,sys,datetime
ep=int(sys.argv[1]); end=datetime.datetime.fromtimestamp(ep, datetime.timezone.utc)
start=end-datetime.timedelta(hours=5); now=datetime.datetime.now(datetime.timezone.utc)
m=int((end-now).total_seconds()/60)
print(json.dumps({'blocks':[{'isActive':True,'startTime':start.isoformat().replace('+00:00','Z'),
 'endTime':end.isoformat().replace('+00:00','Z'),'totalTokens':123,'costUSD':1.0,
 'projection':{'remainingMinutes':m},'burnRate':{'tokensPerMinuteForIndicator':7}}]}))" "$1" \
  > "$(_block_cache)"
}
_stub_block 200
accepts "budget status reads the anchored block"  -- budget status
accepts "budget account resolves an identity"     -- budget account
refuses "a non-numeric callout is refused" "callout <0-100>"  -- budget callout ninety
refuses "a callout over 100 is refused"    "callout <0-100>"  -- budget callout 150
accepts "a valid callout is recorded"                          -- budget callout 42

# ③ the other direction — with no block readable it must say UNMEASURABLE, never
#    report "0 minutes left", which would read as "the block just ended".
rm -f "$(_block_cache)"
AIMAIL_CCUSAGE_TIMEOUT=1 PATH=/nonexistent:/usr/bin:/bin \
  "$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ "$rc" == "4" ]] && grep -qiF "could not be read" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ an unreadable block is UNMEASURABLE (exit 4), not 0 minutes\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("unreadable block did not report UNMEASURABLE")
  printf '  ✖ unreadable block: exit %s (wanted 4)\n' "$rc"
fi

section "budget — a FRESH /usage reset wins the boundary OUTRIGHT (Part 3, 2026-09-01)"
# ⛔⛔ MEASURED DEFECT (project owner, 2026-09-01 live): the predecessor compared a
#    FRESH, authoritative callout/probe against ccusage's coarse floor-to-hour
#    estimate and took whichever was numerically EARLIER — so a real 86%/11:30
#    callout silently lost to ccusage's cruder 11:00 guess. A fresh reading must
#    win outright, never be compared away by a rougher heuristic.
_stub_block 120          # ccusage claims 120 min left
accepts "callout with --left records a reset"  -- budget callout 78 --left 100
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'source: callout' "$AIMAIL_ROOT/.out" && grep -qi 'boundary disagreement' "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ the fresh /usage boundary wins outright, and the disagreement is still logged\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("callout boundary did not override ccusage")
  printf '  ✖ callout boundary did not override ccusage\n'
fi
# ③ THE DIRECTION THAT USED TO FAIL — a fresh callout LATER than ccusage must
#    still win outright now (Part 3's whole point: fresh wins regardless of
#    direction, never compared against ccusage's estimate at all). ccusage is
#    documented as reading LATE by construction, so "ccusage says earlier" is
#    not evidence the callout is wrong — it is exactly the case a coarse
#    heuristic was silently overriding a live authoritative reading before.
_stub_block 30
accepts "a fresh callout later than ccusage still wins outright" -- budget callout 50 --left 300
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'source: callout' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ a fresh callout wins outright even when LATER than ccusage'"'"'s estimate\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a fresh later callout did not win outright")
  printf '  ✖ a fresh callout later than ccusage did not win — Part 3 regressed\n'
fi
# ④ THE OLD BEHAVIOR, PRESERVED for a STALE reading — when the callout/probe was
#    NOT taken recently (its reset technically hasn't passed, but the reading
#    itself is old), neither source is freshly known-good, and the original
#    earlier-wins comparison must still apply, unchanged.
_stub_block 30
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"
printf '%s\t%s\t%s\t%s\t%s\n' "$(( $(date +%s) - 3600 ))" "$ACCT" 50 "callout" "$(( $(date +%s) + 18000 ))" \
  >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'source: ccusage' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ a STALE callout (taken 60 min ago) falls back to the earlier-wins comparison, unchanged\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a stale callout won outright instead of falling back to earlier-wins")
  printf '  ✖ a stale callout was trusted outright — freshness gate did not fire\n'
fi
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
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
# ③ …and a genuinely-moved block end must still checkpoint, or the guard becomes a permanent
# block. ⚠ Must differ from the prior stub (10 min -> here) by MORE than the checkpoint
# marker's own bucket width (900s/15min, see the dedup-jitter fix below) and must still be
# INSIDE the firing window (<= CHECKPOINT_MIN) so this call actually sends rather than
# reporting "not due" — 30 min satisfies both (20 min / 1200s away from the prior stub's ~10
# min, still under the ~45 min checkpoint window).
_stub_block 30
accepts "a new block checkpoints again"            -- budget checkpoint
CK3=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
if (( CK3 > CK2 )); then
  PASS=$((PASS+1)); printf '  ✔ a new block re-fired the checkpoint (%s -> %s)\n' "$CK2" "$CK3"
else
  FAIL=$((FAIL+1)); FAILURES+=("new block did not checkpoint")
  printf '  ✖ a new block did NOT checkpoint (%s -> %s)\n' "$CK2" "$CK3"
fi

section "budget — checkpoint marker absorbs sub-15-min boundary jitter (2026-09-04)"
# ⛔⛔ REAL INCIDENT: `block_end_effective`'s reading jitters by a minute or more tick-to-tick
# (alternates probe/ccusage, and even one source's own reading can shift slightly) — the OLD
# marker compared the raw epoch with `==`, so it almost never matched and the checkpoint
# RE-FIRED every 5-min autopilot tick until the block finally rolled. Measured live,
# 2026-09-04: 4 re-fires in 30 minutes, boundary alternating "0239"/"0240". Fixed by bucketing
# the marker to 15 minutes (blocks are 5 HOURS apart, so no genuinely new block can ever land
# in the same bucket as the previous one's end — only sub-bucket jitter gets absorbed). This
# pins that fix: two `be` readings one minute apart must produce exactly ONE checkpoint.
rm -f "$AIMAIL_ROOT/state/checkpoint_done"
_stub_block 10
accepts "checkpoint fires on the first (jittery) reading"  -- budget checkpoint
CKJ1=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
_stub_block 9
accepts "checkpoint re-run one minute of jitter later"     -- budget checkpoint
CKJ2=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
if (( CKJ1 > 0 && CKJ2 == CKJ1 )); then
  PASS=$((PASS+1)); printf '  ✔ a 1-minute boundary jitter did not re-fire the checkpoint (%s -> %s)\n' "$CKJ1" "$CKJ2"
else
  FAIL=$((FAIL+1)); FAILURES+=("checkpoint re-fired on sub-bucket jitter: $CKJ1 -> $CKJ2")
  printf '  ✖ a 1-minute boundary jitter RE-FIRED the checkpoint: %s -> %s (the 2026-09-04 bug)\n' "$CKJ1" "$CKJ2"
fi

section "budget — checkpoint marker survives jitter that straddles a bucket EDGE (2026-09-05)"
# ⛔⛔ REAL INCIDENT: bucketing to 15 min (the 2026-09-04 fix above) still re-fires when the
# jittery `be` reading straddles the bucket's OWN 900s-since-epoch boundary, rather than
# landing safely inside one bucket — measured live 22:45-23:25 on 2026-09-05, 8 re-fires in
# 40 minutes, because that night's true block end alternated between :29 and :30 and 900s
# ticks over at exactly :30:00. Construct that exact edge deterministically: pin `be` to a
# value sitting ON a 900s boundary, then 60s earlier — one bucket lower under floor
# division, same real block. An EXACT bucket-match marker (the 09-04 fix as originally
# written) fires again here; only a tolerance around the FIRST bucket recorded survives it.
rm -f "$AIMAIL_ROOT/state/checkpoint_done"
NOWEP=$(date +%s)
EDGE=$(( ( (NOWEP + 1500) / 900 + 1) * 900 ))   # next 900s boundary ~25-40 min out
_stub_block_at "$EDGE"
accepts "checkpoint fires on the boundary reading"        -- budget checkpoint
CKE1=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
_stub_block_at $(( EDGE - 60 ))
accepts "checkpoint re-run 60s earlier, one bucket lower" -- budget checkpoint
CKE2=$(find "$AIMAIL_ROOT/mail" -iname '*checkpoint*' | wc -l)
if (( CKE1 > 0 && CKE2 == CKE1 )); then
  PASS=$((PASS+1)); printf '  ✔ a bucket-edge-straddling jitter did not re-fire the checkpoint (%s -> %s)\n' "$CKE1" "$CKE2"
else
  FAIL=$((FAIL+1)); FAILURES+=("checkpoint re-fired across a bucket edge: $CKE1 -> $CKE2")
  printf '  ✖ a bucket-edge-straddling jitter RE-FIRED the checkpoint: %s -> %s (the 2026-09-05 bug)\n' "$CKE1" "$CKE2"
fi

section "budget — park keeps pollers ARMED and the ramp wakes them"
accepts "park writes the throttle flag"            -- budget park "test park"
if [[ -f "$(_throttle_file)" ]] && grep -q 'STAY ARMED' "$(_throttle_file)"; then
  PASS=$((PASS+1)); printf '  ✔ the throttle flag tells seats to STAY ARMED\n'
else FAIL=$((FAIL+1)); FAILURES+=("throttle flag missing the stay-armed instruction")
     printf '  ✖ throttle flag does not say STAY ARMED\n'; fi
# ⭐ THE INTEGRATION CLAIM: a poller parks on the flag, does NOT consume mail,
#    and wakes ITSELF at the ramp with nobody touching it.
printf 'x\n' > "$AIMAIL_ROOT/pk.md"
"$AIMAIL" send --to main --from main --subject "during park" --body-file "$AIMAIL_ROOT/pk.md" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) + 3600 ))" > "$(_ramp_at_file)"
# A fixed sleep here judged "parked" by elapsed time, which a loaded machine turns into a race
# (a poller that has not yet reached the park loop looks the same as one that ignored it). Wait for
# the poller's own park heartbeat instead, from a clean heartbeat file, bounded at 60 s.
rm -f "$AIMAIL_ROOT/state/poller/main.hb"
"$AIMAIL" poll main > "$AIMAIL_ROOT/park.log" 2>&1 &
PARKPID=$!
for _ in $(seq 1 120); do
  grep -q '^park_beat' "$AIMAIL_ROOT/state/poller/main.hb" 2>/dev/null && break
  kill -0 $PARKPID 2>/dev/null || break
  sleep 0.5
done
if kill -0 $PARKPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ poller stays ARMED and asleep under a throttle (does not exit)\n'
else FAIL=$((FAIL+1)); FAILURES+=("poller exited under a throttle"); printf '  ✖ poller exited under a throttle\n'; fi
QD=$(find "$AIMAIL_ROOT/mail/main" -maxdepth 1 -name '*.md' | wc -l)
if (( QD >= 1 )); then
  PASS=$((PASS+1)); printf '  ✔ mail sent during the park is queued, not consumed\n'
else FAIL=$((FAIL+1)); FAILURES+=("parked poller consumed mail"); printf '  ✖ parked poller consumed mail\n'; fi
accepts "ramp clears the throttle"                 -- budget ramp
printf 'at\t%s\n' "$(( $(date +%s) - 10 ))" > "$(_ramp_at_file)"
# Wake time is the poller's own loop interval plus whatever the machine adds; wait for the exit
# (bounded at 60 s) instead of judging it after a fixed 8 s.
for _ in $(seq 1 120); do kill -0 $PARKPID 2>/dev/null || break; sleep 0.5; done
if ! kill -0 $PARKPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the poller woke ITSELF at the ramp — no human, no coordinator\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poller did not self-wake at the ramp"); kill $PARKPID 2>/dev/null
  printf '  ✖ poller did not wake at the ramp\n'
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

section "budget — -h/--help and unknown dash-args never mutate state (HIGH, 2026-09-25 incident: 'budget park --help' parked the whole account for real, librarian hit it live at 08:19)"
# ⭐ FALSIFY FIRST (rule ①): this is the EXACT live incident -- `local reason="\${*}"` took
#   ANY argument, including `--help`, as the literal park reason. Shown reproducing against
#   pre-fix code (main @ f60198a) in the gate/commit message; this arm proves the fix here and
#   guards every future run.
accepts "'budget park --help' exits 0 (prints usage), no error" -- budget park --help
if grep -q 'usage: aimail budget park' "$AIMAIL_ROOT/.out" && [[ ! -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ --help printed usage and did NOT park the fleet\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("'budget park --help' either skipped usage or parked the fleet")
  printf '  ✖ --help did not behave as expected\n'
fi
accepts "'budget park -h' also exits 0, no park" -- budget park -h
if [[ -f "$(_throttle_file)" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("'budget park -h' parked the fleet"); printf '  ✖ -h parked the fleet\n'
else PASS=$((PASS+1)); printf '  ✔ -h did not park the fleet\n'; fi
refuses "'budget park --typo' (unrecognized flag) is refused, not silently taken as the reason" \
  "looks like a flag" -- budget park --typo
if [[ -f "$(_throttle_file)" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("'budget park --typo' parked the fleet"); printf '  ✖ --typo parked the fleet\n'
else PASS=$((PASS+1)); printf '  ✔ --typo did not park the fleet\n'; fi
# ⭐⭐ CONTROL, THE OTHER DIRECTION (rule ③): a real reason -- including one with a mid-sentence
#   dash later in the text -- must still park. An always-refusing guard would pass every arm
#   above for free; this is what proves the guard only inspects the FIRST token.
accepts "a real reason (with a mid-sentence dash) still parks the fleet" \
  -- budget park "disk usage -5pct under floor"
if [[ -f "$(_throttle_file)" ]] && grep -q 'REASON disk usage -5pct under floor' "$(_throttle_file)"; then
  PASS=$((PASS+1)); printf '  ✔ a real reason with a mid-sentence dash still parks, verbatim\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a real park reason with a mid-sentence dash did not take effect")
  printf '  ✖ real reason with a mid-sentence dash did not take effect\n'
fi
"$AIMAIL" budget ramp >/dev/null 2>&1

accepts "'budget night --help' exits 0, prints usage, does not toggle" -- budget night --help
if [[ -f "$AIMAIL_ROOT/state/night_mode" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("'budget night --help' toggled night mode"); printf '  ✖ night --help toggled state\n'
else PASS=$((PASS+1)); printf '  ✔ night --help did not toggle state\n'; fi
accepts "'budget night' (no args) still actually toggles -- proves the guard is not an always-refuse" \
  -- budget night
if [[ -f "$AIMAIL_ROOT/state/night_mode" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a real night call still toggles\n'
else FAIL=$((FAIL+1)); FAILURES+=("'budget night' did not toggle"); printf '  ✖ night did not toggle\n'; fi
refuses "'budget day --typo' is refused (exit 3), night mode left untouched" \
  "not a recognized argument" -- budget day --typo
if [[ -f "$AIMAIL_ROOT/state/night_mode" ]]; then
  PASS=$((PASS+1)); printf '  ✔ day --typo left night mode untouched\n'
else FAIL=$((FAIL+1)); FAILURES+=("'budget day --typo' cleared night mode anyway"); printf '  ✖ day --typo cleared night mode\n'; fi
accepts "'budget day' (no args) still actually clears night mode" -- budget day
if [[ -f "$AIMAIL_ROOT/state/night_mode" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("'budget day' did not clear night mode"); printf '  ✖ day did not clear\n'
else PASS=$((PASS+1)); printf '  ✔ a real day call still clears night mode\n'; fi

printf 'at\t%s\n' "$(( $(date +%s) + 3600 ))" > "$(_ramp_at_file)"
accepts "park for the ramp --help control" -- budget park "ramp --help control park"
accepts "'budget ramp --help' exits 0, prints usage, does not clear the throttle" -- budget ramp --help
if [[ -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ramp --help left the throttle flag in place\n'
else FAIL=$((FAIL+1)); FAILURES+=("'budget ramp --help' cleared the throttle flag"); printf '  ✖ ramp --help cleared the throttle\n'; fi
accepts "'budget ramp' (no args) still actually clears the throttle" -- budget ramp
if [[ -f "$(_throttle_file)" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("'budget ramp' did not clear the throttle"); printf '  ✖ ramp did not clear\n'
else PASS=$((PASS+1)); printf '  ✔ a real ramp call still clears the throttle\n'; fi

accepts "'budget checkpoint --help' exits 0, prints usage" -- budget checkpoint --help
refuses "'budget checkpoint --typo' is refused, not silently ignored" \
  "not a recognized flag" -- budget checkpoint --typo

section "poller.sh — poll-persistent self-limit (AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC)"
# ⭐ THE INTEGRATION CLAIM (fable's poll-persistent wedge finding, 2026-09-22 -- 2 seats hung
#   one night, one for 12.5 hours): a `poll-persistent` invoked as a plain Bash call (not a
#   Monitor task) has no exit path at all under this loop's own design ("does not exit on any
#   wake"). The self-limit bounds TOTAL WALL TIME of the persistent loop, independent of mail/
#   heartbeat/park state, and fires even with no seat activity whatsoever. Non-default knob
#   value (2s), per #276 -- a fixture equal to the real default (2400s) would take 40 minutes
#   to prove anything.
accepts "register a seat for the max-age selftest" -- seat add pollmaxage "max-age selftest seat"
# ⚠ AIMAIL_POLL_INTERVAL=1 (the loop's own tick rate, default 5s) so the check is evaluated
#   well within this test's own wait window -- at the default 5s tick, the earliest re-check
#   after the knob elapses can itself land close to a 5s sleep's own boundary, a real race this
#   test hit once (measured) before pinning the tick rate explicitly.
AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=2 AIMAIL_POLL_INTERVAL=1 "$AIMAIL" poll-persistent pollmaxage \
  > "$AIMAIL_ROOT/maxage.log" 2>&1 &
MAXAGEPID=$!; sleep 6
if ! kill -0 $MAXAGEPID 2>/dev/null && grep -q 'WAKE=max_age' "$AIMAIL_ROOT/maxage.log"; then
  PASS=$((PASS+1)); printf '  ✔ poll-persistent self-limits at the configured max age, printing WAKE=max_age\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent did not self-limit at max age")
  kill $MAXAGEPID 2>/dev/null
  printf '  ✖ poll-persistent did not self-limit at max age\n'
  sed 's/^/      /' "$AIMAIL_ROOT/maxage.log" 2>/dev/null | head -10
fi
wait $MAXAGEPID 2>/dev/null
MAXAGE_EXIT=$?
if [[ "$MAXAGE_EXIT" -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ the self-limit exit is a clean exit 0, not a crash\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("max-age exit was not exit 0 (got $MAXAGE_EXIT)")
  printf '  ✖ max-age exit was not exit 0 (got %s)\n' "$MAXAGE_EXIT"
fi
if grep -q '^exit_reason	max_age$' "$AIMAIL_ROOT/state/poller/pollmaxage.hb" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the exit record names exit_reason=max_age, same mechanism as every other deliberate exit\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("exit record missing exit_reason=max_age")
  printf '  ✖ exit record missing exit_reason=max_age\n'
fi

# ⭐ FALSIFICATION (#276): the SAME invocation with the knob disabled (0) must NOT exit within a
#   comparable window -- proves the arm above is a real, working check and not a tautological
#   always-exits path (e.g. a bug that exits on the very first tick regardless of the knob).
rm -f "$AIMAIL_ROOT/state/poller/pollmaxage.hb"
AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC=0 "$AIMAIL" poll-persistent pollmaxage \
  > "$AIMAIL_ROOT/maxage_disabled.log" 2>&1 &
DISABLEDPID=$!; sleep 5
if kill -0 $DISABLEDPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ knob=0 disables the self-limit -- still running after the same window\n'
  kill $DISABLEDPID 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("max-age fired even with the knob disabled (0)")
  printf '  ✖ max-age fired even with the knob disabled (0)\n'
  sed 's/^/      /' "$AIMAIL_ROOT/maxage_disabled.log" 2>/dev/null | head -10
fi
wait $DISABLEDPID 2>/dev/null

# ⭐ THE ACTUAL DEFAULT (2026-09-25, fable-sat-idle-16min follow-up): lowered from 2400s/40min to
#   1900s/~32min -- a Monitor is capped at 1800s, so 1900 is the smallest margin past that cap
#   that still gives a correctly-Monitor-armed poller room to clear normal tick-scheduling
#   jitter; a Bash-armed one now self-limits ~8min sooner than before. A live run at the real
#   default would itself take ~32 minutes to prove (same reason the arms above use a 2s
#   override, not 2400/1900) -- this checks the CONFIGURED number directly instead; the
#   mechanism firing correctly at ANY threshold is already proven dynamically above.
if grep -qE 'AIMAIL_POLL_PERSISTENT_MAX_AGE_SEC:-1900\}"' "$REPO/lib/poller.sh"; then
  PASS=$((PASS+1)); printf '  ✔ the persistent max-age default is 1900s (was 2400s) -- inside, not past, the 1800s Monitor cap\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("persistent max-age default is not 1900s")
  printf '  ✖ persistent max-age default is not 1900s\n'
fi

section "budget — item 5: per-seat unpark exempts ONE seat, without touching the shared flag"
refuses "unpark requires a registered seat" "not a registered seat" -- budget unpark nosuchseat999
accepts "register a second seat for the exemption comparison" -- seat add unparkother "comparison seat"

printf 'at\t%s\n' "$(( $(date +%s) + 3600 ))" > "$(_ramp_at_file)"
accepts "park writes the throttle flag (item 5 setup)"  -- budget park "item5 test park"
accepts "unpark grants main an exemption"               -- budget unpark main --reason "item5 test grant"
if [[ -f "$AIMAIL_ROOT/state/seat_unpark_main" ]] \
  && grep -q "$(stat -c %Y "$(_throttle_file)")" "$AIMAIL_ROOT/state/seat_unpark_main"; then
  PASS=$((PASS+1)); printf '  ✔ the exemption file captures the CURRENT park episode (throttled mtime) verbatim\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("exemption file missing or did not capture the park episode")
  printf '  ✖ exemption file missing or did not capture the park episode\n'
fi

# ⭐ THE INTEGRATION CLAIM: an EXEMPT seat's poller, under the SAME throttle
# that keeps every other seat parked, still delivers queued mail normally —
# it does not sleep on the flag.
printf 'x\n' > "$AIMAIL_ROOT/pk2.md"
"$AIMAIL" send --to main --from main --subject "during item5 exemption" --body-file "$AIMAIL_ROOT/pk2.md" >/dev/null 2>&1
"$AIMAIL" poll main > "$AIMAIL_ROOT/unpark.log" 2>&1 &
UNPARKPID=$!; sleep 4
if ! kill -0 $UNPARKPID 2>/dev/null && grep -q 'WAKE=unpark' "$AIMAIL_ROOT/unpark.log" \
  && grep -q 'WAKE=mail' "$AIMAIL_ROOT/unpark.log"; then
  PASS=$((PASS+1)); printf '  ✔ the exempt seat skipped the park, logged WAKE=unpark, and delivered its mail normally\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("exempt seat did not behave like an unthrottled poller")
  kill $UNPARKPID 2>/dev/null
  printf '  ✖ exempt seat did not behave like an unthrottled poller\n'
  sed 's/^/      /' "$AIMAIL_ROOT/unpark.log" 2>/dev/null | head -10
fi

# ⭐ code-review's own gate finding on 2f9e4f0: a LEGITIMATE mid-park `ramp_at` refresh (item 2's
# own boundary re-measurement, or anything else that rewrites `ramp_at` WITHOUT starting a new
# park) must NOT invalidate an active grant -- only a change to `throttled`'s own identity does.
# Rewrite `ramp_at` directly here (simulating exactly that refresh) while leaving `throttled`
# untouched, and confirm the SAME grant still applies.
# ── M1 HARD STOP (the owner 2026-09-22): the exemption yields at the seat's own cap ────────────
# Same park, same exemption for main; the account's latest reading is pushed to 96% against a
# seat cap of 95%: the exempt poller must PARK (WAKE=hardstop) and must NOT deliver mail. A fresh
# reading back under the cap lifts it (WAKE=unpark + WAKE=mail again). Falsification: 94 < 95 is
# the control -- the exemption holds and mail flows.
printf 'x\n' > "$AIMAIL_ROOT/pkhs.md"
"$AIMAIL" send --to main --from main --subject "during the hard stop" --body-file "$AIMAIL_ROOT/pkhs.md" >/dev/null 2>&1
"$AIMAIL" budget callout 96 >/dev/null 2>&1
AIMAIL_SEAT_CAP_main=95 "$AIMAIL" poll main > "$AIMAIL_ROOT/hardstop.log" 2>&1 &
HSPID=$!; sleep 4
if kill -0 $HSPID 2>/dev/null && grep -q 'WAKE=hardstop' "$AIMAIL_ROOT/hardstop.log" && ! grep -q 'WAKE=mail' "$AIMAIL_ROOT/hardstop.log"; then
  PASS=$((PASS+1)); printf '  ✔ M1: at 96%% >= seat cap 95%% the EXEMPT seat parks (WAKE=hardstop) and does not deliver\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("M1 hard stop: exempt seat at 96% did not park / or delivered mail")
  printf '  ✖ M1 hard stop: exempt seat at 96%% did not park, or delivered mail\n'; sed 's/^/      /' "$AIMAIL_ROOT/hardstop.log" 2>/dev/null | head -8
fi
kill $HSPID 2>/dev/null; wait $HSPID 2>/dev/null
"$AIMAIL" budget callout 94 >/dev/null 2>&1
AIMAIL_SEAT_CAP_main=95 "$AIMAIL" poll main > "$AIMAIL_ROOT/hardstop2.log" 2>&1 &
HSPID=$!; sleep 4
if ! kill -0 $HSPID 2>/dev/null && grep -q 'WAKE=unpark' "$AIMAIL_ROOT/hardstop2.log" && grep -q 'WAKE=mail' "$AIMAIL_ROOT/hardstop2.log"; then
  PASS=$((PASS+1)); printf '  ✔ M1 control: at 94%% < 95%% the exemption holds and the mail is delivered\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("M1 control: exempt seat at 94% did not resume delivering")
  kill $HSPID 2>/dev/null; printf '  ✖ M1 control failed\n'; sed 's/^/      /' "$AIMAIL_ROOT/hardstop2.log" 2>/dev/null | head -8
fi
# leave the ledger well under every cap for the arms that follow (default seat cap 90) -- a bare
# ledger row, NOT `budget callout`, which also refreshes ramp_at and would disturb the weekly arms below
printf '%s\t%s\t50\tprobe\t\n' "$(date +%s)" "$(cd "$REPO" && source lib/core.sh && source lib/budget.sh && account_id)" >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
printf 'x\n' > "$AIMAIL_ROOT/pk2b.md"
"$AIMAIL" send --to main --from main --subject "during item5 exemption after a ramp_at refresh" --body-file "$AIMAIL_ROOT/pk2b.md" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) + 5400 ))" > "$(_ramp_at_file)"   # a legitimate refresh, same park
"$AIMAIL" poll main > "$AIMAIL_ROOT/unpark_after_refresh.log" 2>&1 &
REFRESHPID=$!; sleep 4
if ! kill -0 $REFRESHPID 2>/dev/null && grep -q 'WAKE=unpark' "$AIMAIL_ROOT/unpark_after_refresh.log" \
  && grep -q 'WAKE=mail' "$AIMAIL_ROOT/unpark_after_refresh.log"; then
  PASS=$((PASS+1)); printf '  ✔ a legitimate ramp_at refresh (throttled untouched) does NOT invalidate the grant\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a ramp_at refresh incorrectly invalidated an active grant")
  kill $REFRESHPID 2>/dev/null
  printf '  ✖ a ramp_at refresh incorrectly invalidated an active grant\n'
  sed 's/^/      /' "$AIMAIL_ROOT/unpark_after_refresh.log" 2>/dev/null | head -10
fi

# ⭐ THE COMPARISON: a DIFFERENT seat, under the SAME throttle, with NO
# exemption of its own, must still park normally — the grant is per-seat, not
# fleet-wide.
"$AIMAIL" poll unparkother > "$AIMAIL_ROOT/otherpark.log" 2>&1 &
OTHERPID=$!; sleep 4
if kill -0 $OTHERPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a seat WITHOUT the exemption still parks under the same throttle\n'
  kill $OTHERPID 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("unexempted seat did not park — exemption leaked fleet-wide")
  printf '  ✖ unexempted seat did NOT park — the exemption leaked fleet-wide\n'
fi

# ⭐ STALENESS: a NEW park episode must silently invalidate an OLDER grant made under the
# previous one — no separate TTL, just the copy going stale. Simulated by bumping `throttled`'s
# OWN mtime (a real new `budget_park` after a `budget_ramp` would do exactly this) -- NOT by
# rewriting `ramp_at`, which a legitimate mid-park refresh can also do without any new park
# actually beginning (code-review's own gate finding on 2f9e4f0 — exactly why the identity moved
# off `ramp_at` and onto `throttled`'s own mtime).
# ⚠ Deliberately NO mail sent here (unlike the exemption test above): staying
#   parked is the assertion, and a message this poller correctly never reaches
#   the mail-check code to deliver would sit in the inbox as leaked state for
#   a LATER section's own poller to pick up — exactly the failure mode that
#   made `AR-05/AR-06`'s own restart-refire check fail for an unrelated reason
#   while this section was still being written.
accepts "unpark grants main a SECOND exemption under the current park" \
  -- budget unpark main --reason "item5 staleness setup"
sleep 1; touch "$(_throttle_file)"   # simulates a genuinely NEW park episode
"$AIMAIL" poll main > "$AIMAIL_ROOT/staleunpark.log" 2>&1 &
STALEPID=$!; sleep 4
if kill -0 $STALEPID 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a grant made under an EARLIER park no longer exempts once a NEW park begins\n'
  kill $STALEPID 2>/dev/null
else
  FAIL=$((FAIL+1)); FAILURES+=("a stale exemption still applied under a newer park")
  printf '  ✖ a stale exemption still applied under a newer park\n'
fi
if [[ ! -f "$AIMAIL_ROOT/state/seat_unpark_main" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the stale exemption file was swept by the poller that found it invalid\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("stale exemption file was not swept")
  printf '  ✖ stale exemption file was not swept\n'
fi

# ⭐ VISIBILITY: budget status surfaces exemptions rather than a silent file.
accepts "unpark grants main another exemption for the status check" \
  -- budget unpark main --reason "item5 status-visibility check"
"$AIMAIL" budget status >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'PER-SEAT EXEMPTIONS' "$AIMAIL_ROOT/.out" && grep -qi 'main.*ACTIVE' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ budget status surfaces the active exemption\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("budget status did not surface the active exemption")
  printf '  ✖ budget status did not surface the active exemption\n'
fi

# ⭐ THE SHARED FLAG IS UNTOUCHED: granting/using an exemption must not clear
# `throttled` itself — that would un-park the ENTIRE fleet, not one seat.
if [[ -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the shared throttle flag is still set — the exemption never touched it\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("the shared throttled flag was cleared by an unpark grant")
  printf '  ✖ the shared throttled flag was cleared by an unpark grant\n'
fi

# ⚠ ROBUST CLEANUP, not conditional on any assertion above having passed. The exemption test's
# own scenario is "does the exempt seat deliver its queued mail" -- that message is left
# UNDELIVERED in main's own inbox whenever that specific behavior does NOT happen (a real bug,
# OR -- caught by code-review's own gate mutation -- the exemption simply not activating for any
# reason). A leftover undelivered message then silently becomes a false "mail waiting" signal for
# the NEXT section's own fresh poller on the same seat, exactly the shape that once made
# AR-05/AR-06's own restart-refire check fail for a completely unrelated reason. Every background
# poller this section started is already killed by PID on its own failure path above (never a
# broad `pkill` here -- this machine runs OTHER, real seats' own live pollers named the same as
# this section's own test seats, and a pattern-matched kill could hit one of those instead of
# this run's own isolated process). Sweeping the INBOX FILES (scoped to this run's own isolated
# $AIMAIL_ROOT, never a real path) is what actually closes the leak; the kills already happened.
rm -f "$AIMAIL_ROOT/mail/main"/*.md
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/seat_unpark_main"

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
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

section "budget — AR-10: a refused checkpoint must not skip the park"
# ⛔ THE DEFECT: `(( left <= CHECKPOINT_MIN )) && budget_checkpoint` — bare, not
#   subshelled. budget_checkpoint uses this codebase's own refused/exit idiom
#   (exit 3 on an unregistered sender), which TERMINATES THE WHOLE AUTOPILOT
#   PROCESS, so the park check just below it never runs. Force the checkpoint
#   to refuse (an unregistered supervisor) at a boundary where BOTH the
#   checkpoint and the park are due, and confirm the park still happens.
_stub_block 5
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/checkpoint_done" "$(_ramp_at_file)"
# ⛔ Park is USAGE-gated, not time-gated (project owner, 2026-08-21, see budget_autopilot) — seed a
#   qualifying reading so autopilot's park CHECK has something to act on, isolating this test to
#   the one thing it actually names (does a refused checkpoint block the park?), not the separate
#   usage-gate. AIMAIL_NO_NETWORK=1 (set for the whole suite) now makes budget_probe a guaranteed
#   no-op, so this seeded reading is not at risk of being clobbered by a real probe response.
"$AIMAIL" budget callout 95 >/dev/null 2>&1
AIMAIL_SUPERVISOR=nobody-registered-here "$AIMAIL" budget autopilot \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the park happened even though the checkpoint step refused (autopilot rc=%s)\n' "$rc"
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-10: a refused checkpoint prevented the park")
  printf '  ✖ AR-10: park did NOT happen — refused checkpoint skipped it (rc=%s)\n' "$rc"
  sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
fi
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/checkpoint_done" "$(_ramp_at_file)"

section "budget — weekly cap must ALSO trigger autopilot's park, independent of the session cap"
# ⛔⛔ THE DEFECT (project owner, 2026-09-03, real incident): budget_autopilot's park check only ever
#   compared against account_cap() (the SESSION/block ceiling) -- weekly hit 97%, well past its own
#   95% cap, with ZERO automatic park, because no code path in autopilot read weekly_cap()/
#   _last_weekly at all. `budget status` has always DISPLAYED the weekly reading with a "wins over
#   session%, regardless" annotation, but nothing enforced it; `budget_watch` checks weekly but is
#   explicitly not a cron job. Seed a session reading comfortably under cap and a weekly reading
#   over cap, and confirm autopilot parks on the weekly number alone.
_stub_block 5
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/checkpoint_done" "$(_ramp_at_file)"
"$AIMAIL" budget callout 10 >/dev/null 2>&1   # session comfortably under its 80% cap
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"
printf '%s\t%s\t%s\n' "$(date +%s)" 97 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
accepts "autopilot runs with a session reading under cap but weekly over cap" -- budget autopilot
if [[ -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the fleet parked on the weekly number alone (session was under its own cap)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("weekly-over-cap did not trigger autopilot park")
  printf '  ✖ weekly at 97%% (cap 95%%) did NOT trigger a park — the exact 2026-09-03 gap\n'
fi
if grep -q "weekly usage" "$(_throttle_file)" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the park reason correctly names weekly usage, not the session cap\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("weekly park did not record a weekly-specific reason")
  printf '  ✖ park reason does not mention weekly usage: %s\n' "$(cat "$(_throttle_file)" 2>/dev/null)"
fi
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/checkpoint_done" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
# Control: weekly comfortably under cap must NOT park on its own (isolates the assertion above --
# confirms the new branch doesn't just always fire).
_stub_block 5
"$AIMAIL" budget callout 10 >/dev/null 2>&1
printf '%s\t%s\t%s\n' "$(date +%s)" 20 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
accepts "autopilot runs with both session and weekly comfortably under cap" -- budget autopilot
if [[ -f "$(_throttle_file)" ]]; then
  FAIL=$((FAIL+1)); FAILURES+=("autopilot parked with both readings under cap")
  printf '  ✖ parked even though neither cap was reached\n'
else
  PASS=$((PASS+1)); printf '  ✔ no park when both session and weekly are comfortably under cap\n'
fi
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/checkpoint_done" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"

section "budget — AR-11: park must never leave ZERO wake path"
# ⛔ THE DEFECT: `[[ -n "$be" ]] && printf ... | atomic_write ramp_at` wrote
#   NOTHING when the block boundary was unmeasurable — a park with the
#   throttle set and no ramp_at at all has NO self-wake path, ever, directly
#   violating this file's own "never remove the last wake path" comment. Force
#   genuine unmeasurability (no cached block, no network, and the most recent
#   callout for this account already expired) and confirm a ramp_at still
#   gets written as a fallback recheck.
rm -f "$(_block_cache)" "$(_ramp_at_file)" "$(_throttle_file)"
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ACCT" 60 "callout" "$(( $(date +%s) - 600 ))" \
  >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
accepts "park succeeds even when the boundary is genuinely unmeasurable" \
  -- budget park "AR-11 unmeasurable-boundary test"
if [[ -f "$(_ramp_at_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ramp_at was written as a fallback recheck even with an unmeasurable boundary\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-11: park left NO ramp_at when the boundary was unmeasurable")
  printf '  ✖ AR-11: park left NO ramp_at — the fleet would park with no wake path at all\n'
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

section "budget — AR-27: a corrected reset time must reach ramp_at while already parked"
# ⛔ THE DEFECT: budget_park returns EARLY ("already parked — leaving the original reason in
#   place") before it would otherwise write ramp_at, so a callout --resets correction recorded
#   mid-park never reached the live ramp_at file — exactly the one time nobody is about to re-run
#   `budget park` to pick it up. FIX: budget_refresh_ramp, called from the tail of budget_callout
#   (and budget_probe), rewrites ONLY ramp_at, never the throttled flag's own REASON/ACCOUNT.
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"
_stub_block 240
"$AIMAIL" budget park "AR-27 initial park" >/dev/null 2>&1
RAT_BEFORE="$(awk -F'\t' '$1=="at"{print $2}' "$(_ramp_at_file)" 2>/dev/null)"
REASON_BEFORE="$(grep '^REASON' "$(_throttle_file)" 2>/dev/null)"
# A corrected reading, EARLIER than the stubbed ccusage boundary (block_end_effective takes the
# earlier of the two on disagreement) — this is the case that matters: a human's real /usage read
# almost always corrects a LATE ccusage guess, never a later one.
"$AIMAIL" budget callout 55 --resets "$(date -d '+100 minutes' '+%H:%M')" >/dev/null 2>&1
RAT_AFTER="$(awk -F'\t' '$1=="at"{print $2}' "$(_ramp_at_file)" 2>/dev/null)"
REASON_AFTER="$(grep '^REASON' "$(_throttle_file)" 2>/dev/null)"
if [[ -n "$RAT_AFTER" && -n "$RAT_BEFORE" && "$RAT_AFTER" -lt "$RAT_BEFORE" ]]; then
  PASS=$((PASS+1)); printf '  ✔ ramp_at moved earlier after the corrected callout while still parked (%s -> %s)\n' "$RAT_BEFORE" "$RAT_AFTER"
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-27: a corrected reset time did not reach ramp_at while parked")
  printf '  ✖ AR-27: ramp_at did not update (before=%s after=%s)\n' "${RAT_BEFORE:-unset}" "${RAT_AFTER:-unset}"
fi
if [[ "$REASON_AFTER" == "$REASON_BEFORE" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle flag'"'"'s own REASON was untouched by the refresh\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-27: refreshing ramp_at also changed the throttle REASON")
  printf '  ✖ AR-27: REASON changed from %s to %s — refresh must touch ONLY ramp_at\n' "$REASON_BEFORE" "$REASON_AFTER"
fi
# ② the other direction — no throttle in force, so there is nothing to correct: a callout must
#   NOT create a ramp_at out of nowhere when the fleet was never parked to begin with.
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"
"$AIMAIL" budget callout 55 --resets "$(date -d '+100 minutes' '+%H:%M')" >/dev/null 2>&1
if [[ ! -f "$(_ramp_at_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a callout while NOT parked did not invent a ramp_at\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-27: a callout while not parked wrote a ramp_at that should not exist")
  printf '  ✖ AR-27: ramp_at was created despite no active park\n'
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"
# ③ code-review's own gate finding on this ticket, reproduced as a permanent regression test —
#   a PERSISTENTLY unmeasurable boundary must NOT make the fallback recheck horizon recede on
#   every single refresh call (budget_watch's loop calls budget_probe, which calls this, every
#   ~30s by default) — the recheck it promises must eventually actually arrive.
rm -f "$(_block_cache)" "$(_ramp_at_file)" "$(_throttle_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$ACCT" 60 "callout" "$(( $(date +%s) - 600 ))" \
  >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
"$AIMAIL" budget park "AR-27 fallback-recede test" >/dev/null 2>&1
RAT1="$(awk -F'\t' '$1=="at"{print $2}' "$(_ramp_at_file)" 2>/dev/null)"
sleep 2
# A callout with no --resets/--left keeps block_end_effective unmeasurable (still no block.json,
# still no valid reset epoch anywhere) — this is the exact "boundary persistently unmeasurable"
# case, exercised through budget_refresh_ramp's real call site rather than calling it directly.
"$AIMAIL" budget callout 61 >/dev/null 2>&1
RAT2="$(awk -F'\t' '$1=="at"{print $2}' "$(_ramp_at_file)" 2>/dev/null)"
if [[ -n "$RAT1" && "$RAT1" == "$RAT2" ]]; then
  PASS=$((PASS+1)); printf '  ✔ an unmeasurable-boundary refresh left the existing fallback ramp_at untouched (%s)\n' "$RAT1"
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-27: an unmeasurable-boundary refresh advanced the fallback ramp_at instead of leaving it")
  printf '  ✖ AR-27: fallback ramp_at moved from %s to %s on an unmeasurable refresh\n' "${RAT1:-unset}" "${RAT2:-unset}"
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"

section "budget — the 2026-09-01 5h21m incident: probe recovers the boundary when ccusage cannot"
# ⛔⛔ THE REAL INCIDENT: `budget_autopilot`'s ONE ccusage-independent fallback
#   (`budget_probe`, a live API hit) used to be reachable only AFTER
#   `block_end_effective` had ALREADY succeeded — so once ccusage went blind
#   (confirmed cause: it reads TOP-LEVEL transcript activity only, and real
#   work that stretch was entirely inside subagents), there was no way back.
#   64 straight 5-min ticks, zero escalation, real usage climbing unmonitored
#   until it hit the account's actual hard limit. THE LAW THIS MINTS: a
#   fallback gated on its primary's success is not a fallback.
#
# Reproduced hermetically: ccusage forced to fail for real (no npx on PATH,
# same exclusion the existing "unreadable block" test above already uses,
# never a stubbed block.json this time), while a stub `curl` ahead of it on
# PATH makes the probe's live endpoint answer for real, so this exercises
# `budget_probe`'s actual code path, not a seeded ledger row standing in for
# it. `AIMAIL_NO_NETWORK` is overridden to 0 for these calls ONLY (the rest of
# the suite stays hermetic via the exported default).
STUBBIN="$AIMAIL_ROOT/stubbin"; mkdir -p "$STUBBIN"
CREDS_DIR="$AIMAIL_ROOT/fake_claude_config"; mkdir -p "$CREDS_DIR"
printf '{"claudeAiOauth":{"accessToken":"faketoken-for-tests"}}\n' > "$CREDS_DIR/.credentials.json"
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
# Stub: ignores its arguments, answers as the live usage endpoint would.
resets="\$(date -u -d '+90 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":42,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"%s"}}\n' "\$resets" "\$resets"
CURLSTUB
chmod +x "$STUBBIN/curl"
_no_ccusage_probe_answers() { # runs a command with: no npx reachable, a real curl stub, real jq/date/etc from /usr/bin
  env -i HOME="$HOME" PATH="$STUBBIN:/usr/bin:/bin" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null \
    AIMAIL_BLOCK_TTL=999999 AIMAIL_NO_NETWORK=0 CLAUDE_CONFIG_DIR="$CREDS_DIR" \
    AIMAIL_CCUSAGE_TIMEOUT=1 "$@"
}
rm -f "$(_block_cache)" "$(_throttle_file)" "$(_ramp_at_file)" \
      "$AIMAIL_ROOT/state/budget_ledger.tsv" "$AIMAIL_ROOT/state/autopilot_unmeasurable_streak" \
      "$AIMAIL_ROOT/state/autopilot_blind"
_no_ccusage_probe_answers "$AIMAIL" budget autopilot >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ "$rc" == "0" ]]; then
  PASS=$((PASS+1)); printf '  ✔ autopilot succeeded (rc=0) via the probe even with ccusage genuinely unreachable\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("autopilot did not recover via the probe when ccusage failed (rc=$rc)")
  printf '  ✖ autopilot exited %s instead of recovering via the probe\n' "$rc"
  sed 's/^/      /' "$AIMAIL_ROOT/.err" | head -6
fi
if grep -qP '\tprobe\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a real probe row landed in the ledger (the endpoint was actually hit, not bypassed)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("no probe row in the ledger — the stub endpoint was never actually reached")
  printf '  ✖ ledger has no probe row:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null
fi
if [[ ! -f "$AIMAIL_ROOT/state/autopilot_unmeasurable_streak" && ! -f "$AIMAIL_ROOT/state/autopilot_blind" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a successful tick left no streak or blind-alarm state behind\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a successful autopilot tick left stale streak/blind state")
  printf '  ✖ streak or blind flag present after a successful tick\n'
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"

section "budget — 2026-09-20 item 2: Fable-model weekly quota extraction + pool view"
# ⛔ Reuses the SAME stub-curl idiom as the section just above (real jq/date
#   from /usr/bin, a fake credentials dir, AIMAIL_NO_NETWORK overridden to 0
#   for these calls only) — this is `budget_probe`'s ACTUAL extraction code
#   running against a response shaped like the real endpoint's `limits[]`
#   array (confirmed live, 2026-09-20 — see the design doc), not a seeded
#   ledger row standing in for it.
POOL_ACCT="$(basename "$CREDS_DIR")"
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
resets="\$(date -u -d '+90 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":42,"resets_at":"%s"},"seven_day":{"utilization":10,"resets_at":"%s"},"limits":[{"kind":"session","group":"session","percent":42},{"kind":"weekly_scoped","group":"weekly","percent":7,"resets_at":"%s","scope":{"model":{"id":null,"display_name":"Fable"}}}]}\n' \
  "\$resets" "\$resets" "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$(_fable_weekly_file "$POOL_ACCT")" "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q 'fable model weekly: 7%' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ budget probe extracted the Fable-scoped weekly_scoped entry from limits[]\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item2: budget probe did not extract the Fable weekly quota")
  printf '  ✖ expected "fable model weekly: 7%%" in probe output, got:\n'; sed 's/^/      /' "$AIMAIL_ROOT/.out"
fi
if [[ -s "$(_fable_weekly_file "$POOL_ACCT")" ]] && grep -qP '^\d+\t7\t\d+$' "$(_fable_weekly_file "$POOL_ACCT")"; then
  PASS=$((PASS+1)); printf '  ✔ the per-account fable_weekly file was written with the right percent + reset epoch\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item2: fable_weekly file missing or malformed")
  printf '  ✖ %s: %s\n' "$(_fable_weekly_file "$POOL_ACCT")" "$(cat "$(_fable_weekly_file "$POOL_ACCT")" 2>/dev/null || echo '(missing)')"
fi
if grep -qP '\tfable_weekly\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a fable_weekly row landed in the shared ledger, tagged distinctly from the account weekly row\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item2: no fable_weekly row in the ledger")
  printf '  ✖ ledger has no fable_weekly-tagged row\n'
fi
# ⚠ ONE capture, graded AND printed: the old shape graded one invocation and printed a second, so a
#   red arm showed a row that matched the regex (2026-09-22, three suites in parallel) and the
#   failing output itself was never seen.
AIMAIL_FLEET_ACCOUNTS="$POOL_ACCT" "$AIMAIL" budget pool > "$AIMAIL_ROOT/.pool" 2> "$AIMAIL_ROOT/.pool_err" || true
if grep -qE "^${POOL_ACCT} +no +.*7%" "$AIMAIL_ROOT/.pool"; then
  PASS=$((PASS+1)); printf '  ✔ aimail budget pool shows the 7%% Fable-weekly figure for this account\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item2: budget pool did not show the Fable-weekly figure")
  printf '  ✖ pool output (the graded capture, stdout then stderr):\n'; sed 's/^/      /' "$AIMAIL_ROOT/.pool"; sed 's/^/      ! /' "$AIMAIL_ROOT/.pool_err"
fi
# ⛔ THE UNMEASURED CASE — a response with NO Fable-scoped entry at all (an
#   ordinary account, or the endpoint reshaped) must read as "?", never "0%".
#   Same "it says so, it doesn't guess zero" discipline as every other reading
#   in this file.
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
resets="\$(date -u -d '+90 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":11,"resets_at":"%s"},"seven_day":{"utilization":2,"resets_at":"%s"}}\n' "\$resets" "\$resets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$(_fable_weekly_file "$POOL_ACCT")" "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
AIMAIL_FLEET_ACCOUNTS="$POOL_ACCT" "$AIMAIL" budget pool > "$AIMAIL_ROOT/.pool2" 2> "$AIMAIL_ROOT/.pool2_err" || true
if [[ ! -s "$(_fable_weekly_file "$POOL_ACCT")" ]] \
   && grep -qE "^${POOL_ACCT} +no +.*\?%" "$AIMAIL_ROOT/.pool2"; then
  PASS=$((PASS+1)); printf '  ✔ no Fable-scoped entry in the response -> pool reads "?%%", not "0%%"\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item2: a response with no Fable entry was not reported as unmeasured")
  # R6(j): a flake here has no cause on record -- print the graded capture so the next one does
  printf '  ✖ fable weekly file present? %s; probe stderr / pool stdout / pool stderr:\n' "$([[ -s "$(_fable_weekly_file "$POOL_ACCT")" ]] && echo yes || echo no)"
  sed 's/^/      ! /' "$AIMAIL_ROOT/.err"; sed 's/^/      /' "$AIMAIL_ROOT/.pool2"; sed 's/^/      ! /' "$AIMAIL_ROOT/.pool2_err"
  printf '  ✖ pool output:\n'; AIMAIL_FLEET_ACCOUNTS="$POOL_ACCT" "$AIMAIL" budget pool 2>&1 | sed 's/^/      /'
fi
rm -f "$(_fable_weekly_file "$POOL_ACCT")" "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/budget_ledger.tsv"

section "budget — probe: NULL five_hour.utilization + NUMERIC seven_day reads as 0%, not unmeasurable"
# ⛔ 2026-09-25: this exact shape means no block has started in the current window -- the
#   endpoint answered for real (proven by seven_day being numeric), so it is NOT the generic
#   "response had no numeric five_hour.utilization" failure. Same stub-curl + fake-creds idiom
#   as the sections above.
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":15,"resets_at":"%s"}}\n' "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; rc=$?
if [[ "$rc" == "0" ]]; then
  PASS=$((PASS+1)); printf '  ✔ null five_hour + numeric seven_day exits 0 (measured), not unmeasurable\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("null five_hour + numeric seven_day: expected exit 0, got $rc")
  printf '  ✖ expected exit 0, got %s. stderr:\n' "$rc"; sed 's/^/      /' "$AIMAIL_ROOT/.err"
fi
if grep -qP "\t${POOL_ACCT}\t0\tprobe\t" "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the ledger records the reading as 0%%, not skipped\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("null five_hour + numeric seven_day: no 0% probe row in the ledger")
  printf '  ✖ ledger:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null
fi
if grep -qi 'five_hour.utilization was null' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the note is printed, distinguishing this from a real 0%% reading off the wire\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("null five_hour + numeric seven_day: no distinguishing note printed")
  printf '  ✖ probe stdout:\n'; sed 's/^/      /' "$AIMAIL_ROOT/.out"
fi
echo "── falsification: BOTH five_hour AND seven_day null — must stay unmeasurable (exit 4) ──"
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
printf '{"five_hour":{"utilization":null,"resets_at":null},"seven_day":{"utilization":null,"resets_at":null}}\n'
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out2" 2>"$AIMAIL_ROOT/.err2"; rc=$?
if [[ "$rc" == "4" ]]; then
  PASS=$((PASS+1)); printf '  ✔ both null still exits 4 (unmeasurable) — the narrow exception did not swallow a real failure\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("both five_hour and seven_day null: expected exit 4, got $rc")
  printf '  ✖ expected exit 4 (unmeasurable), got %s\n' "$rc"
fi
if ! grep -qP '\tprobe\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ no probe row was recorded for the genuinely-unmeasurable case\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("both null: a probe row was recorded despite being unmeasurable")
fi
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"

echo "── falsification: a MALFORMED (non-null, non-numeric) five_hour.utilization — must stay"
echo "   unmeasurable (exit 4), NOT be silently read as 0% just because seven_day is numeric ──"
# ⛔ 2026-09-25 (code-review's own falsified repro during this change's first gate): the first
#   cut gated the exception on "pct failed the numeric regex," which also fires for a malformed
#   string like "N/A" -- not just a genuine null. Fixed by checking the raw field's JSON type
#   directly; this proves the fix, using code-review's own exact repro shape.
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":"N/A","resets_at":null},"seven_day":{"utilization":15,"resets_at":"%s"}}\n' "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out3" 2>"$AIMAIL_ROOT/.err3"; rc=$?
if [[ "$rc" == "4" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a malformed five_hour.utilization ("N/A") exits 4 (unmeasurable), even with numeric seven_day\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("malformed five_hour.utilization: expected exit 4, got $rc")
  printf '  ✖ expected exit 4, got %s. stdout/stderr:\n' "$rc"; sed 's/^/      /' "$AIMAIL_ROOT/.out3"; sed 's/^/      ! /' "$AIMAIL_ROOT/.err3"
fi
if ! grep -qP '\tprobe\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ no probe row recorded — a malformed value was not silently written as 0%%\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("malformed five_hour.utilization: a probe row was recorded despite being unmeasurable")
  printf '  ✖ ledger:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null
fi
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"

echo "── falsification: five_hour MISSING ENTIRELY (not even an explicit null) — must stay"
echo "   unmeasurable (exit 4), NOT be read as 0% just because seven_day is numeric ──"
# ⛔ 2026-09-25 (assistant's HOLD on 09edd7ad, after code-review's own GREEN): a missing key and
#   an explicit null both report `type` == "null" to jq -- indistinguishable by type alone, so the
#   type-only check from the malformed-string fix above ALSO silently read a dropped/renamed
#   five_hour field as 0%. An explicit null is the one shape actually observed to mean "no block
#   started yet" (r2, 2026-09-25) -- a missing key is not evidence of that, it could just as
#   easily mean the endpoint reshaped and this probe is now blind. Fixed by requiring the key to
#   be PRESENT with an explicit null (jq -e object+has+literal-null), not merely absent-or-null.
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"seven_day":{"utilization":15,"resets_at":"%s"}}\n' "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out4" 2>"$AIMAIL_ROOT/.err4"; rc=$?
if [[ "$rc" == "4" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a MISSING five_hour object exits 4 (unmeasurable), even with numeric seven_day\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("missing five_hour object: expected exit 4, got $rc")
  printf '  ✖ expected exit 4, got %s. stdout/stderr:\n' "$rc"; sed 's/^/      /' "$AIMAIL_ROOT/.out4"; sed 's/^/      ! /' "$AIMAIL_ROOT/.err4"
fi
if ! grep -qP '\tprobe\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ no probe row recorded — a missing five_hour object was not silently written as 0%%\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("missing five_hour object: a probe row was recorded despite being unmeasurable")
  printf '  ✖ ledger:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null
fi
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"

echo "── falsification: five_hour present but its own 'utilization' key is MISSING (not null,"
echo "   not a number, just absent) — must stay unmeasurable (exit 4) ──"
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"resets_at":null},"seven_day":{"utilization":15,"resets_at":"%s"}}\n' "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"
_no_ccusage_probe_answers "$AIMAIL" budget probe >"$AIMAIL_ROOT/.out5" 2>"$AIMAIL_ROOT/.err5"; rc=$?
if [[ "$rc" == "4" ]]; then
  PASS=$((PASS+1)); printf '  ✔ five_hour present but missing its own "utilization" key exits 4 (unmeasurable)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("five_hour missing utilization key: expected exit 4, got $rc")
  printf '  ✖ expected exit 4, got %s. stdout/stderr:\n' "$rc"; sed 's/^/      /' "$AIMAIL_ROOT/.out5"; sed 's/^/      ! /' "$AIMAIL_ROOT/.err5"
fi
if ! grep -qP '\tprobe\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ no probe row recorded — a missing utilization key was not silently written as 0%%\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("five_hour missing utilization key: a probe row was recorded despite being unmeasurable")
  printf '  ✖ ledger:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null
fi
rm -f "$AIMAIL_ROOT/state/budget_ledger.tsv"

section "budget pool — LEFT and BLOCK-RESET columns: each account's own block, time left as XhYYm"
# Fixed clock (AIMAIL_NOW) and per-account cached block files, so the columns are exact and no
# ccusage or network is involved. Expected clock times are computed with `date` the same way the
# column does, so the arms hold in any timezone.
mkdir -p "$AIMAIL_ROOT/state"
BR_NOW=1800000000
_br_block_json() { # <end-epoch> -> ccusage-shaped JSON with one active block ending then
  printf '{"blocks":[{"isActive":true,"startTime":"%s","endTime":"%s","totalTokens":1,"costUSD":0,"burnRate":{"tokensPerMinuteForIndicator":0}}]}\n' \
    "$(date -u -d "@$(( $1 - 18000 ))" '+%Y-%m-%dT%H:%M:%S.000Z')" "$(date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z')"
}
# account : minutes left (empty = no cache file at all; negative = block already over)
BR_CASES="brlong:134 brshort:45 brzero:0 brpast:-10 brnone:"
for _c in $BR_CASES; do
  _a="${_c%%:*}"; _m="${_c#*:}"; rm -f "$AIMAIL_ROOT/state/block.$_a.json"
  [[ -n "$_m" ]] && _br_block_json $(( BR_NOW + _m*60 )) > "$AIMAIL_ROOT/state/block.$_a.json"
done
AIMAIL_NOW="$BR_NOW" AIMAIL_FLEET_ACCOUNTS="brlong brshort brzero brpast brnone" "$AIMAIL" budget pool > "$AIMAIL_ROOT/.pool_br" 2> "$AIMAIL_ROOT/.pool_br_err" || true
# _br_cells <account> -> "LEFT BLOCK-RESET" for that row (columns right after SESSION%/CAP)
# (rows after the pool header only: the placement report above it lists the same account names)
_br_cells() { awk -v a="$1" '/^ACCOUNT +PARKED/ {on=1; next} on && $1==a { print $4 " " $5; exit }' "$AIMAIL_ROOT/.pool_br"; }
_br_check() { # <desc> <account> <expected cells>
  local got; got="$(_br_cells "$2")"
  if [[ "$got" == "$3" ]]; then PASS=$((PASS+1)); printf '  ✔ %s (%s)\n' "$1" "$3"
  else FAIL=$((FAIL+1)); FAILURES+=("pool LEFT/BLOCK-RESET: $1 -- wanted '$3', got '$got'")
       printf '  ✖ %s -- wanted %s, got %s\n' "$1" "'$3'" "'$got'"
       sed 's/^/      /' "$AIMAIL_ROOT/.pool_br"; sed 's/^/      ! /' "$AIMAIL_ROOT/.pool_br_err"; fi
}
_br_hm() { date -d "@$(( BR_NOW + $1*60 ))" '+%H:%M'; }
if grep -qE '^ACCOUNT +PARKED +SESSION%/CAP +LEFT +BLOCK-RESET +WEEKLY%/CAP' "$AIMAIL_ROOT/.pool_br"; then
  PASS=$((PASS+1)); printf '  ✔ LEFT and BLOCK-RESET sit beside SESSION%%/CAP; the other columns are still there\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("pool LEFT/BLOCK-RESET: header layout wrong")
  sed 's/^/      /' "$AIMAIL_ROOT/.pool_br"
fi
_br_check "over an hour left reads hours and minutes" brlong  "2h14m $(_br_hm 134)"
_br_check "under an hour left reads 0hMMm"            brshort "0h45m $(_br_hm 45)"
_br_check "exactly zero left is a real 0h00m"         brzero  "0h00m $(_br_hm 0)"
_br_check "an unmeasured block (no data) reads '?' for both" brnone "? ?"
_br_check "a block already over (stale data) reads '?' for both, not negative" brpast "? ?"
for _c in $BR_CASES; do rm -f "$AIMAIL_ROOT/state/block.${_c%%:*}.json"; done

section "budget — _configured_account_pool: explicit-list only, realpath dedupe, seat fallback, empty-pool failure"
# ⛔ 2026-09-25: budget_pool / _pl_accounts / _instance_account_dirs each independently fell
#   back to a seat-only list when AIMAIL_FLEET_ACCOUNTS was unset -- a genuinely seatless
#   account (r2, block rolled at 01:19 with zero seats on it) was invisible to all three.
# ⛔ 2026-09-25 REVISED (assistant's HIGH mail, found live): the first cut globbed $HOME/.claude-*,
#   which (1) listed a symlink-aliased account (e.g. $HOME/.claude -> $HOME/.claude-r2) under TWO
#   names for the same real dir, reading as a TWIN and breaking `seat migrate`, and (2) admitted
#   any other, non-fleet Claude account dir on the machine as a real candidate. The glob is gone;
#   the pool is now explicit-config-only (AIMAIL_ACCOUNT_POOL, or AIMAIL_FLEET_ACCOUNTS), falling
#   back to the live-seat grouping (with a one-time warning) only if neither is set.
FAKEHOME="$AIMAIL_ROOT/fakehome_pool"; rm -rf "$FAKEHOME"; mkdir -p "$FAKEHOME/.claude-poolacct1" "$FAKEHOME/.claude-poolacct2" "$FAKEHOME/.claude-strayacct"
GOT="$(env -i HOME="$FAKEHOME" AIMAIL_ACCOUNT_POOL="poolacct1 poolacct2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOT" == "poolacct1 poolacct2 " ]]; then
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_ACCOUNT_POOL is the explicit pool -- no glob, exactly the names configured\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AIMAIL_ACCOUNT_POOL mismatch: got [$GOT]")
fi
if [[ "$GOT" != *"strayacct"* ]]; then
  PASS=$((PASS+1)); printf '  ✔ an unconfigured ~/.claude-x dir (strayacct) on disk is never a candidate -- not globbed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("an unconfigured account dir leaked into the pool: [$GOT]")
fi
GOTFA="$(env -i HOME="$FAKEHOME" AIMAIL_FLEET_ACCOUNTS="poolacct1 poolacct2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOTFA" == "poolacct1 poolacct2 " ]]; then
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_FLEET_ACCOUNTS is honoured too (older name, same shape) when AIMAIL_ACCOUNT_POOL is unset\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AIMAIL_FLEET_ACCOUNTS mismatch: got [$GOTFA]")
fi
GOTBOTH="$(env -i HOME="$FAKEHOME" AIMAIL_ACCOUNT_POOL="poolacct1" AIMAIL_FLEET_ACCOUNTS="poolacct2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOTBOTH" == "poolacct1 " ]]; then
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_ACCOUNT_POOL wins over AIMAIL_FLEET_ACCOUNTS when both are set\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AIMAIL_ACCOUNT_POOL vs AIMAIL_FLEET_ACCOUNTS priority mismatch: got [$GOTBOTH]")
fi
GOT2="$(env -i HOME="$FAKEHOME" AIMAIL_ACCOUNT_POOL_OVERRIDE="ovracct1 ovracct2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOT2" == "ovracct1 ovracct2 " ]]; then
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_ACCOUNT_POOL_OVERRIDE (test seam) takes priority over everything else\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AIMAIL_ACCOUNT_POOL_OVERRIDE mismatch: got [$GOT2]")
fi

echo "── a symlinked alias dir must not produce a twin -- deduped by REALPATH, not by name ──"
ALIASHOME="$AIMAIL_ROOT/fakehome_alias"; rm -rf "$ALIASHOME"; mkdir -p "$ALIASHOME/.claude-realacct"
ln -s "$ALIASHOME/.claude-realacct" "$ALIASHOME/.claude"
GOTALIAS="$(env -i HOME="$ALIASHOME" AIMAIL_ACCOUNT_POOL="default realacct" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOTALIAS" == "default " ]]; then
  PASS=$((PASS+1)); printf '  ✔ "default" (~/.claude, a symlink) and "realacct" (~/.claude-realacct, its real target)\n'
  printf '    dedupe to ONE entry (first name seen) -- no twin\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("symlink-alias dedupe failed: expected one entry, got [$GOTALIAS]")
fi

echo "── neither AIMAIL_ACCOUNT_POOL nor AIMAIL_FLEET_ACCOUNTS configured -- falls back to the"
echo "   live-seat grouping (pre-2026-09-25 behavior), warns ONCE, never globs the filesystem ──"
SEATHOME="$AIMAIL_ROOT/fakehome_seatfallback"; rm -rf "$SEATHOME"; mkdir -p "$SEATHOME/.claude-seatacct" "$SEATHOME/.claude-strayacct2"
SEATFALLBACK_SCRIPT="$AIMAIL_ROOT/.seatfallback.sh"
cat > "$SEATFALLBACK_SCRIPT" <<'SFEOF'
"$1/bin/aimail" seat add sfseat >/dev/null 2>&1
source "$1/lib/core.sh"; source "$1/lib/registry.sh"; source "$1/lib/budget.sh"; source "$1/lib/seatmigrate.sh"
mkdir -p "$(SEAT_RECORD_DIR)"
printf 'seat\tsfseat\naccount\tseatacct\nsession_id\tsfsess\n' > "$(SEAT_RECORD_DIR)/sfseat"
_configured_account_pool
SFEOF
# AIMAIL_CONFIG=/dev/null: these two cases are about "no pool configured", and a deployment's own
# etc/aimail.conf (which sets AIMAIL_FLEET_ACCOUNTS) must not answer for them.
GOTSEAT="$(env -i HOME="$SEATHOME" AIMAIL_CONFIG=/dev/null AIMAIL_ROOT="$AIMAIL_ROOT/seatfallback_state" bash "$SEATFALLBACK_SCRIPT" "$REPO" 2>"$AIMAIL_ROOT/.seatfallback.err")"
if [[ "$GOTSEAT" == "seatacct" ]]; then
  PASS=$((PASS+1)); printf '  ✔ with neither config var set, the pool falls back to the live-seat account (seatacct)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("seat-fallback mismatch: got [$GOTSEAT]")
fi
if [[ "$GOTSEAT" != *"strayacct2"* ]]; then
  PASS=$((PASS+1)); printf '  ✔ …and the unconfigured stray dir (strayacct2) is still never a candidate -- the fallback is seat-based, not a glob\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a stray dir leaked into the seat-based fallback: [$GOTSEAT]")
fi
if grep -qi 'no AIMAIL_FLEET_ACCOUNTS or AIMAIL_ACCOUNT_POOL configured' "$AIMAIL_ROOT/.seatfallback.err"; then
  PASS=$((PASS+1)); printf '  ✔ …and warns once that no explicit pool is configured\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("expected a warning on the unconfigured-pool fallback, saw: $(cat "$AIMAIL_ROOT/.seatfallback.err")")
fi
rm -f "$SEATFALLBACK_SCRIPT" "$AIMAIL_ROOT/.seatfallback.err"; rm -rf "$AIMAIL_ROOT/seatfallback_state"

EMPTYHOME="$AIMAIL_ROOT/fakehome_empty"; mkdir -p "$EMPTYHOME"
env -i HOME="$EMPTYHOME" AIMAIL_CONFIG=/dev/null AIMAIL_ROOT="$AIMAIL_ROOT/empty_state" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/budget.sh'; _configured_account_pool" >/dev/null 2>&1
if [[ $? != 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ an empty pool (no override, no config, no live seats) returns failure, not an empty success\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("_configured_account_pool returned success on an empty pool")
fi
rm -rf "$AIMAIL_ROOT/empty_state"

section "fleet — _instance_account_dirs: realpath dedupe on EVERY branch, not just _configured_account_pool's"
# ⛔ 2026-09-25 (assistant mail 20260925T083355, "n_live dedup"): _configured_account_pool got
#   its own realpath dedupe (section above) after the $HOME/.claude symlink-alias defect, but
#   _instance_account_dirs has THREE branches and only the _configured_account_pool one
#   (branch 2) ever ran through it -- an explicit AIMAIL_FLEET_ACCOUNTS list (branch 1) or the
#   _autopilot_seat_groups fallback (branch 3) could still list the same real directory under
#   two names, and every caller (n_live/n_work in fleet.sh's own by_seat_state counts, via
#   sessions.sh's _sessions_all_account_projects_dirs) would then query that one real account
#   twice and count its one live session as two -- "2 SESSIONS answering this seat" for a seat
#   with exactly one. Fixed by deduping _instance_account_dirs' OWN combined output, once,
#   downstream of all three branches, so no branch (existing or future) can reintroduce this.
_dedupe_by_realpath_test() {
  env -i HOME="$1" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/fleet.sh'; ${2}"
}
DEDUPHOME="$AIMAIL_ROOT/fakehome_dedupehelper"; rm -rf "$DEDUPHOME/.t"; mkdir -p "$DEDUPHOME/.t/real"
ln -s "$DEDUPHOME/.t/real" "$DEDUPHOME/.t/alias"
GOTHELPER="$(_dedupe_by_realpath_test "$DEDUPHOME" "printf '%s\n%s\n' '$DEDUPHOME/.t/alias' '$DEDUPHOME/.t/real' | _dedupe_by_realpath" 2>/dev/null | tr '\n' ' ')"
if [[ "$GOTHELPER" == "$DEDUPHOME/.t/alias " ]]; then
  PASS=$((PASS+1)); printf '  ✔ _dedupe_by_realpath: a symlink and its real target collapse to ONE line (first seen)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("_dedupe_by_realpath did not collapse an alias pair: got [$GOTHELPER]")
fi
GOTHELPER2="$(_dedupe_by_realpath_test "$DEDUPHOME" "mkdir -p '$DEDUPHOME/.t/other'; printf '%s\n%s\n' '$DEDUPHOME/.t/real' '$DEDUPHOME/.t/other' | _dedupe_by_realpath" 2>/dev/null | sort | tr '\n' ' ')"
if [[ "$GOTHELPER2" == "$DEDUPHOME/.t/other $DEDUPHOME/.t/real " ]]; then
  PASS=$((PASS+1)); printf '  ✔ …and two GENUINELY distinct real dirs are never over-collapsed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("_dedupe_by_realpath over-collapsed distinct dirs: got [$GOTHELPER2]")
fi

echo "── same alias shape, but through _instance_account_dirs' EXPLICIT AIMAIL_FLEET_ACCOUNTS"
echo "   branch -- the one _configured_account_pool's own fix never reaches ──"
IADHOME="$AIMAIL_ROOT/fakehome_iad_alias"; rm -rf "$IADHOME"; mkdir -p "$IADHOME/.claude-realacct2"
ln -s "$IADHOME/.claude-realacct2" "$IADHOME/.claude"
GOTIAD="$(env -i HOME="$IADHOME" AIMAIL_FLEET_ACCOUNTS="default realacct2" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/fleet.sh'; _instance_account_dirs" 2>/dev/null | wc -l)"
if [[ "$GOTIAD" -eq 1 ]]; then
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_FLEET_ACCOUNTS="default realacct2" (an alias pair) yields exactly ONE dir, not two\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("_instance_account_dirs did not dedupe an AIMAIL_FLEET_ACCOUNTS alias pair: $GOTIAD line(s)")
  printf '  ✖ got %s line(s), expected 1\n' "$GOTIAD"
fi
# Falsification: two GENUINELY distinct configured accounts must still both appear -- proves the
# dedupe above isn't just collapsing everything to one line regardless of input.
mkdir -p "$IADHOME/.claude-realacct3"
GOTIAD2="$(env -i HOME="$IADHOME" AIMAIL_FLEET_ACCOUNTS="realacct2 realacct3" bash -c "source '$REPO/lib/core.sh'; source '$REPO/lib/fleet.sh'; _instance_account_dirs" 2>/dev/null | wc -l)"
if [[ "$GOTIAD2" -eq 2 ]]; then
  PASS=$((PASS+1)); printf '  ✔ …while two genuinely distinct accounts still both appear (2 lines) -- not over-collapsed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("_instance_account_dirs over-collapsed two distinct FLEET_ACCOUNTS entries: $GOTIAD2 line(s)")
fi
rm -rf "$IADHOME" "$DEDUPHOME"

section "budget pool / placement — a seatless account (in the configured pool, no live seat) is visible"
# Exercises budget_pool() and _pl_accounts()'s own fallback (AIMAIL_FLEET_ACCOUNTS unset), via
# AIMAIL_ACCOUNT_POOL_OVERRIDE rather than this machine's real ~/.claude-* dirs.
unset AIMAIL_FLEET_ACCOUNTS
export AIMAIL_ACCOUNT_POOL_OVERRIDE="poolwork poolidle"
rm -f "$AIMAIL_ROOT"/state/weekly_poolwork* "$AIMAIL_ROOT"/state/weekly_poolidle* "$AIMAIL_ROOT"/state/throttled_poolwork "$AIMAIL_ROOT"/state/throttled_poolidle
printf '%s\t%s\t%s\n' "$(date +%s)" 60 "" > "$AIMAIL_ROOT/state/weekly_poolwork.tsv"
printf '%s\t%s\t%s\n' "$(date +%s)" 5  "" > "$AIMAIL_ROOT/state/weekly_poolidle.tsv"
"$AIMAIL" budget pool >"$AIMAIL_ROOT/.pool3" 2>"$AIMAIL_ROOT/.pool3_err" || true
if grep -qE '^poolidle\s' "$AIMAIL_ROOT/.pool3"; then
  PASS=$((PASS+1)); printf '  ✔ budget pool lists the seatless account (poolidle) at all -- it used to be invisible\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("budget pool did not list the seatless account poolidle")
  printf '  ✖ pool output:\n'; sed 's/^/      /' "$AIMAIL_ROOT/.pool3"
fi
if grep -qE '^poolidle\s.*\(none live\)' "$AIMAIL_ROOT/.pool3"; then
  PASS=$((PASS+1)); printf '  ✔ …correctly annotated with no live seats, not fabricated as having one\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poolidle row did not show (none live)")
fi
source "$REPO/lib/core.sh"; source "$REPO/lib/budget.sh"; source "$REPO/lib/seatmigrate.sh" 2>/dev/null || true; source "$REPO/lib/placement.sh"
PLPICK="$(AIMAIL_PLACEMENT_SEATS="poolwork:someseat poolidle:" placement_pick someseat 2>/dev/null || true)"
if [[ "$PLPICK" == "poolidle" ]]; then
  PASS=$((PASS+1)); printf '  ✔ placement_pick considers the seatless account (poolidle, most headroom) a real candidate\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("placement_pick did not pick the seatless account (got: ${PLPICK:-none})")
fi
unset AIMAIL_ACCOUNT_POOL_OVERRIDE
rm -f "$AIMAIL_ROOT"/state/weekly_poolwork* "$AIMAIL_ROOT"/state/weekly_poolidle*

section "budget — 2026-09-20 item 3: budget_pick_account() allocation policy"
# ⛔ Pure decision function, tested directly against synthetic account state
#   (weekly files + throttle flags written by hand for made-up account names),
#   not through a live probe -- the policy's own job is to read EXISTING
#   readings correctly, not to go get fresh ones (see the function's own
#   header for why that boundary is deliberate).
_pick_weekly() { printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "${3:-}" > "$AIMAIL_ROOT/state/weekly_$1.tsv"; }
rm -f "$AIMAIL_ROOT"/state/weekly_pickacct* "$AIMAIL_ROOT"/state/throttled_pickacct*
source "$REPO/lib/core.sh"; source "$REPO/lib/budget.sh"

# Basic case: three candidates, one clear headroom winner (pickacctb: 90-10=80,
# vs pickacctA's 90-50=40 and pickacctc's own weekly cap override below).
_pick_weekly pickacctA 50
_pick_weekly pickacctB 10
AIMAIL_WEEKLY_CAP_pickacctC=99 _pick_weekly pickacctC 30   # headroom 69, still less than B's 80
if [[ "$(budget_pick_account pickacctA pickacctB pickacctC)" == "pickacctB" ]]; then
  PASS=$((PASS+1)); printf '  ✔ picks the candidate with the MOST remaining weekly headroom\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: did not pick the max-headroom candidate")
  printf '  ✖ got: %s\n' "$(budget_pick_account pickacctA pickacctB pickacctC 2>&1)"
fi

# Parked -> excluded even though it has the best headroom on paper.
touch "$AIMAIL_ROOT/state/throttled_pickacctB"
if [[ "$(budget_pick_account pickacctA pickacctB pickacctC)" == "pickacctC" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a parked candidate is excluded even with the best headroom (falls through to the next)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: a parked candidate was not excluded")
  printf '  ✖ got: %s\n' "$(budget_pick_account pickacctA pickacctB pickacctC 2>&1)"
fi
rm -f "$AIMAIL_ROOT/state/throttled_pickacctB"

# At/over its own cap -> excluded, even with a real reading on file.
_pick_weekly pickacctD 95   # default weekly cap 95 in this suite's env -> headroom 0
if ! budget_pick_account pickacctD >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf '  ✔ a candidate at/over its own weekly cap is never picked\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: an at-cap candidate was picked")
  printf '  ✖ got: %s\n' "$(budget_pick_account pickacctD 2>&1)"
fi

# Never measured -> excluded, NOT treated as 0% (would otherwise look like maximum headroom).
rm -f "$AIMAIL_ROOT/state/weekly_pickacctE.tsv"
if ! budget_pick_account pickacctE >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf '  ✔ a never-measured candidate is excluded, not assumed to have full headroom\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: an unmeasured candidate was picked (treated as 0%% used)")
  printf '  ✖ got: %s\n' "$(budget_pick_account pickacctE 2>&1)"
fi

# Tie-break: identical headroom, different resets -> the SOONER reset wins.
NOW="$(date +%s)"
_pick_weekly pickacctF 20 "$(( NOW + 500000 ))"   # headroom 70, resets later
_pick_weekly pickacctG 20 "$(( NOW + 100000 ))"   # headroom 70, resets sooner
if [[ "$(budget_pick_account pickacctF pickacctG)" == "pickacctG" ]]; then
  PASS=$((PASS+1)); printf '  ✔ an exact headroom tie breaks toward whichever account resets soonest\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: tie-break did not favor the sooner reset")
  printf '  ✖ got: %s\n' "$(budget_pick_account pickacctF pickacctG 2>&1)"
fi

# Nothing eligible at all -> exit 1, prints nothing, and the CLI refuses cleanly (not a crash).
rm -f "$AIMAIL_ROOT"/state/weekly_pickacct* "$AIMAIL_ROOT"/state/throttled_pickacct*
if ! budget_pick_account pickacctA pickacctB pickacctC >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf '  ✔ with nothing eligible, the function returns non-zero and prints nothing\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item3: an empty candidate pool still returned a pick")
fi
if "$AIMAIL" budget pick pickacctA pickacctB pickacctC >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"; then
  FAIL=$((FAIL+1)); FAILURES+=("item3: aimail budget pick exited 0 with nothing eligible")
  printf '  ✖ CLI exited 0 unexpectedly: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
else
  PASS=$((PASS+1)); printf '  ✔ aimail budget pick refuses cleanly (non-zero, explains why) rather than crashing\n'
fi
rm -f "$AIMAIL_ROOT"/state/weekly_pickacct* "$AIMAIL_ROOT"/state/throttled_pickacct*

section "budget — 2026-09-20 item 4a: budget_stale_candidates() -- only STALE, never genuinely-over-cap"
# ⛔ The project owner's own ruling (20260920T154934) drew this line explicitly: probe a
#   candidate on demand ONLY when its reading is missing or describes an
#   already-closed window; a FRESH reading that's simply over cap is not
#   "stale" and re-probing it wastes a call for an answer already known.
rm -f "$AIMAIL_ROOT"/state/weekly_stale* "$AIMAIL_ROOT"/state/throttled_stale*
NOW="$(date +%s)"
_pick_weekly staleNever 0 >/dev/null 2>&1; rm -f "$AIMAIL_ROOT/state/weekly_staleNever.tsv"   # never measured
_pick_weekly staleExpired 40 "$(( NOW - 1000 ))"    # reset already passed -> describes a dead window
_pick_weekly staleFresh 99 "$(( NOW + 500000 ))"    # fresh AND over cap -- NOT stale, just bad
touch "$AIMAIL_ROOT/state/throttled_staleParked"
_pick_weekly staleParked 10 "$(( NOW + 500000 ))"   # parked -- a probe can't fix that either
STALE_OUT="$(budget_stale_candidates staleNever staleExpired staleFresh staleParked)"
if grep -qx 'staleNever' <<<"$STALE_OUT" && grep -qx 'staleExpired' <<<"$STALE_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ never-measured and reset-already-passed both count as stale\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4a: stale detection missed a genuinely stale candidate")
  printf '  ✖ got: %s\n' "$STALE_OUT"
fi
if ! grep -qx 'staleFresh' <<<"$STALE_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ a FRESH reading that is simply over cap is NOT reported as stale\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4a: a fresh over-cap reading was wrongly treated as stale")
fi
if ! grep -qx 'staleParked' <<<"$STALE_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ a parked account is excluded from the stale set (a probe cannot un-park it)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4a: a parked account was reported as a stale/probe-worthy candidate")
fi
rm -f "$AIMAIL_ROOT"/state/weekly_stale* "$AIMAIL_ROOT"/state/throttled_stale*

section "budget — 2026-09-20 item 4b: budget_pick_account_live() -- probe on demand, not on a schedule"
# ⛔ Reuses the STUBBIN/CREDS_DIR curl-stub idiom (real jq/date, fake creds,
#   AIMAIL_NO_NETWORK overridden to 0 for these calls only) -- this exercises
#   budget_pick_account_live()'s ACTUAL probe call, not a seeded reading
#   standing in for it. AIMAIL_ACCOUNT_DIR_liveAcctH points the synthetic
#   account name at the isolated fake-creds dir (see ACCOUNT_CONFIG_DIR's own
#   override comment) so this never touches the real $HOME.
cat > "$STUBBIN/curl" <<CURLSTUB
#!/usr/bin/env bash
resets="\$(date -u -d '+90 minutes' '+%Y-%m-%dT%H:%M:%SZ')"
wresets="\$(date -u -d '+6 days' '+%Y-%m-%dT%H:%M:%SZ')"
printf '{"five_hour":{"utilization":5,"resets_at":"%s"},"seven_day":{"utilization":20,"resets_at":"%s"}}\n' "\$resets" "\$wresets"
CURLSTUB
chmod +x "$STUBBIN/curl"
rm -f "$AIMAIL_ROOT"/state/weekly_liveAcct* "$AIMAIL_ROOT"/state/throttled_liveAcct*
NOW="$(date +%s)"
# ⚠ liveAcctG is FRESH but genuinely at/over its own cap -- eligible for
#   NOTHING, and (correctly) never re-probed by budget_stale_candidates
#   either. This must be the ONLY way to reach "no eligible account" so the
#   probe-on-demand path actually has to run, unlike this test's own first
#   draft, which gave G a genuinely eligible reading -- the static pick
#   returned G immediately and never needed H at all (per the ruling's own
#   wording: probe only when finalizing "no eligible account", not "maybe a
#   better one exists"). That was this test's bug, not the code's.
_pick_weekly liveAcctG 99 "$(( NOW + 500000 ))"       # fresh, headroom -4 -- not stale, just bad
# ⛔ REAL BUG FOUND WRITING THIS TEST, worth pinning here: account_id() names
#   the account from the CONFIG DIR'S OWN BASENAME (`.claude-<name>`), not
#   from whatever logical name a caller associates with it via
#   AIMAIL_ACCOUNT_DIR_<acct>. Pointing the override at $CREDS_DIR directly
#   (basename "faketest_creds", say) would make budget_probe() record its
#   reading under THAT literal basename, never under "liveAcctH" -- silently
#   filed under the wrong account, invisible to _last_weekly("liveAcctH")
#   ever after. In real production use this can't happen (every real account
#   dir already follows the `.claude-<name>` convention that account_id()
#   expects), but a test pointing at an arbitrary dir name has to honor that
#   same convention explicitly, or it tests something subtly different from
#   the real path. Fix: the fake creds dir's own basename must decode to the
#   exact account name being tested.
LIVEH_DIR="$AIMAIL_ROOT/fakehome/.claude-liveAcctH"; mkdir -p "$LIVEH_DIR"
cp "$CREDS_DIR/.credentials.json" "$LIVEH_DIR/.credentials.json"
export AIMAIL_ACCOUNT_DIR_liveAcctH="$LIVEH_DIR"
# liveAcctH starts with NO reading at all -- the static budget_pick_account() alone cannot see it.
if ! budget_pick_account liveAcctG liveAcctH >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf '  ✔ sanity: the static (non-probing) picker finds NOTHING eligible before any probe\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4b: sanity check on the static picker failed before probing")
  printf '  ✖ got: %s\n' "$(budget_pick_account liveAcctG liveAcctH 2>&1)"
fi
# ⚠ NOT via _no_ccusage_probe_answers directly: it runs under `env -i`, which
#   wipes the WHOLE environment except its own fixed list -- an `export`ed
#   AIMAIL_ACCOUNT_DIR_liveAcctH from this shell never reaches that
#   subprocess at all (found live: the probe silently fell back to the
#   default `~/.claude-liveAcctH`, which does not exist, "no credentials"
#   skip). Same env -i list, with the override folded in explicitly.
LIVE_PICK="$( env -i HOME="$HOME" PATH="$STUBBIN:/usr/bin:/bin" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null \
    AIMAIL_BLOCK_TTL=999999 AIMAIL_NO_NETWORK=0 CLAUDE_CONFIG_DIR="$CREDS_DIR" AIMAIL_CCUSAGE_TIMEOUT=1 \
    AIMAIL_ACCOUNT_DIR_liveAcctH="$LIVEH_DIR" \
    "$AIMAIL" budget pick liveAcctG liveAcctH 2>"$AIMAIL_ROOT/.err" )"
if [[ "$LIVE_PICK" == "pick: liveAcctH" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the live picker probed the never-measured candidate on demand and then picked it (95%% > 45%% headroom)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4b: live pick did not probe+pick the stale/unmeasured candidate")
  printf '  ✖ got: %s\n' "${LIVE_PICK:-(empty)}"; sed 's/^/      /' "$AIMAIL_ROOT/.err"
fi
if grep -qP '\tliveAcctH\t.*\tweekly\t' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the on-demand probe actually reached the endpoint and recorded a real weekly row for liveAcctH\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4b: no weekly ledger row for liveAcctH -- the probe was never really fired")
fi
unset AIMAIL_ACCOUNT_DIR_liveAcctH
rm -f "$AIMAIL_ROOT"/state/weekly_liveAcct* "$AIMAIL_ROOT"/state/throttled_liveAcct* "$AIMAIL_ROOT/state/budget_ledger.tsv"

# ⛔ THE NEGATIVE CONTROL: when the static pick ALREADY succeeds, no probe may
#   fire at all -- "on demand" means never speculative. Point liveAcctJ's
#   config dir at a stub that would make the test FAIL if it were ever
#   called (a poisoned curl), so a wrongful probe is loud, not silently
#   harmless.
cat > "$STUBBIN/curl" <<'CURLSTUB'
#!/usr/bin/env bash
echo "POISON: this stub must never be invoked when a static pick already succeeds" >&2
exit 1
CURLSTUB
chmod +x "$STUBBIN/curl"
_pick_weekly liveAcctK 10 "$(( $(date +%s) + 500000 ))"   # plenty of headroom, already measured
if _no_ccusage_probe_answers "$AIMAIL" budget pick liveAcctK >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err" \
   && ! grep -q POISON "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ a successful static pick never triggers a probe at all\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4b: a probe fired even though the static pick already had an answer")
  printf '  ✖ .err: %s\n' "$(cat "$AIMAIL_ROOT/.err" 2>/dev/null)"
fi
rm -f "$AIMAIL_ROOT"/state/weekly_liveAcct* "$AIMAIL_ROOT"/state/throttled_liveAcct*

section "budget — 2026-09-20 item 4d: budget_recommend_migration() -- decide + report, never act"
# ⛔ Real seat, real live process, real registered supervisor -- the same
#   "a real background process stands in for a live poller" idiom
#   tests/seat_account.sh already established for seat_account_dir/
#   seat_account, reused here rather than mocking the environ.
"$AIMAIL" seat add migsrc >/dev/null 2>&1
"$AIMAIL" seat add migsupervisor >/dev/null 2>&1
MIGSRC_DIR="$AIMAIL_ROOT/migsrcacct"; mkdir -p "$MIGSRC_DIR"
env CLAUDE_CONFIG_DIR="$MIGSRC_DIR" sleep 300 &
MIGSRC_PID=$!
hb_start migsrc
hb_write migsrc pid "$MIGSRC_PID"
rm -f "$AIMAIL_ROOT"/state/weekly_migsrcacct* "$AIMAIL_ROOT"/state/weekly_migtargetacct* \
      "$AIMAIL_ROOT"/state/throttled_migsrcacct* "$AIMAIL_ROOT/state/seat_reassign_migsrc"

# migsrc's own account (migsrcacct) is parked; migtargetacct has real, fresh headroom.
touch "$AIMAIL_ROOT/state/throttled_migsrcacct"
_pick_weekly migtargetacct 10 "$(( $(date +%s) + 500000 ))"

AIMAIL_SUPERVISOR=migsupervisor AIMAIL_FLEET_ACCOUNTS="migsrcacct migtargetacct" \
  "$AIMAIL" budget recommend-migration migsrc >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if [[ -f "$AIMAIL_ROOT/state/seat_reassign_migsrc" ]] \
   && grep -q '^target_account	migtargetacct$' "$AIMAIL_ROOT/state/seat_reassign_migsrc"; then
  PASS=$((PASS+1)); printf '  ✔ wrote a reassign marker naming the correct target account\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4d: no correct reassign marker written")
  printf '  ✖ marker: %s\n' "$(cat "$AIMAIL_ROOT/state/seat_reassign_migsrc" 2>/dev/null || echo '(missing)')"
fi
if MAILFILE="$(find "$AIMAIL_ROOT/mail/migsupervisor" -maxdepth 1 -type f -newer "$AIMAIL_ROOT/state/throttled_migsrcacct" 2>/dev/null | head -1)" \
   && [[ -n "$MAILFILE" ]] && grep -q 'migsrc' "$MAILFILE" && grep -q 'migtargetacct' "$MAILFILE" \
   && grep -q 'aimail seat migrate migsrc migtargetacct' "$MAILFILE" && ! grep -q 'kill <pid>' "$MAILFILE"; then
  # 2026-09-21: the recipe is the scripted `aimail seat migrate`, and it must NOT say `kill <pid>`
  #   -- a killed --bg session is respawned by the CLI scheduler from its original account/model
  #   spec (docs/cli_account_migration.md). The old assertion required the wrong instruction.
  PASS=$((PASS+1)); printf '  ✔ mailed migsupervisor a real, pre-filled recommendation naming both the seat and the target (seat migrate, never kill)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4d: no correctly-shaped mail reached the supervisor's inbox")
  printf '  ✖ inbox listing: %s\n' "$(ls "$AIMAIL_ROOT/mail/migsupervisor" 2>&1)"
fi
if grep -qi 'never asserted with certainty\|BEST-EFFORT\|resolve it manually\|resolves the real one itself' "${MAILFILE:-/dev/null}" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the mail is honest about the session-id resolution being best-effort/manual, never asserted as certain\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4d: mail did not flag the session-id step as best-effort or manual")
fi
if ! grep -qiE '\b(claude --bg|kill \$pid)\b' "$AIMAIL_ROOT/.out" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ nothing was actually killed or relaunched -- the function only decided and reported\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4d: something suggests an actual kill/relaunch was attempted, not just recommended")
fi

# Idempotency: the SAME park episode must not re-mail on a second call.
BEFORE_COUNT="$(find "$AIMAIL_ROOT/mail/migsupervisor" -maxdepth 1 -type f 2>/dev/null | wc -l)"
AIMAIL_SUPERVISOR=migsupervisor AIMAIL_FLEET_ACCOUNTS="migsrcacct migtargetacct" \
  "$AIMAIL" budget recommend-migration migsrc >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
AFTER_COUNT="$(find "$AIMAIL_ROOT/mail/migsupervisor" -maxdepth 1 -type f 2>/dev/null | wc -l)"
if [[ "$BEFORE_COUNT" == "$AFTER_COUNT" ]] && grep -q 'already has a live migration recommendation' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ re-running against the SAME park episode does not send a second mail\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("item4d: a second call for the same park episode re-mailed the supervisor")
  printf '  ✖ inbox count %s -> %s; stdout: %s\n' "$BEFORE_COUNT" "$AFTER_COUNT" "$(cat "$AIMAIL_ROOT/.out")"
fi

# ⛔ REGRESSION FOUND WRITING THIS TEST: a bare `kill` here left migsrc's own
#   heartbeat showing a dead pid with NO exit record -- exactly a CRASHED
#   seat's signature -- which the LATER "fleet sweep" section's own
#   exact-count assertions (it scans every registered seat, not just its own
#   fixture) then tripped over as an extra, unaccounted-for alert. hb_exit
#   first, matching how a poller that stopped on purpose always leaves a
#   verdict artifact (see poller.sh's own header on exactly this point) --
#   THEN kill the process. Order matters: killing first and writing the exit
#   record after would leave the same crash-shaped gap for however long is
#   between the two lines.
hb_exit migsrc done
kill "$MIGSRC_PID" 2>/dev/null || true
# Retire both fixture seats outright, belt-and-suspenders on top of the clean
# hb_exit above: fleet_sweep (run later in this file) skips retired seats
# entirely, so neither migsrc nor migsupervisor can be mistaken for a live
# fixture by anything downstream, regardless of exactly how poller_state
# would otherwise have classified a dead-but-cleanly-exited heartbeat.
"$AIMAIL" seat retire migsrc >/dev/null 2>&1 || true
"$AIMAIL" seat retire migsupervisor >/dev/null 2>&1 || true
rm -f "$AIMAIL_ROOT"/state/weekly_migsrcacct* "$AIMAIL_ROOT"/state/weekly_migtargetacct* \
      "$AIMAIL_ROOT"/state/throttled_migsrcacct* "$AIMAIL_ROOT/state/seat_reassign_migsrc"

section "budget — autopilot escalates loudly after 3 genuinely blind ticks, not before"
# Both sources fail for real this time (no curl stub on PATH either) — the
# actual 2026-08-31 shape: neither ccusage nor the probe can answer.
rm -f "$(_block_cache)" "$(_throttle_file)" "$(_ramp_at_file)" \
      "$AIMAIL_ROOT/state/budget_ledger.tsv" "$AIMAIL_ROOT/state/autopilot_unmeasurable_streak" \
      "$AIMAIL_ROOT/state/autopilot_blind"
for i in 1 2; do
  AIMAIL_SUPERVISOR=nobody-registered-here "$AIMAIL" budget autopilot >/dev/null 2>&1
  if [[ -f "$AIMAIL_ROOT/state/autopilot_blind" ]]; then
    FAIL=$((FAIL+1)); FAILURES+=("autopilot escalated after only $i UNMEASURABLE tick(s), wanted 3")
    printf '  ✖ escalated after only %s tick(s) — too eager\n' "$i"
  fi
done
if [[ ! -f "$AIMAIL_ROOT/state/autopilot_blind" ]]; then
  PASS=$((PASS+1)); printf '  ✔ 2 consecutive UNMEASURABLE ticks did not escalate yet\n'
fi
AIMAIL_SUPERVISOR=nobody-registered-here "$AIMAIL" budget autopilot >/dev/null 2>&1
if [[ -f "$AIMAIL_ROOT/state/autopilot_blind" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the 3rd consecutive UNMEASURABLE tick wrote the passive alarm flag\n'
  grep -q "3 consecutive" "$AIMAIL_ROOT/state/autopilot_blind" \
    && { PASS=$((PASS+1)); printf '  ✔ the flag records the real streak count\n'; } \
    || { FAIL=$((FAIL+1)); FAILURES+=("autopilot_blind flag did not record the streak count"); printf '  ✖ flag missing the streak count\n'; }
  # ⛔ Real defect found by an independent review (2026-09-01): the flag text
  #   named the founding incident's own date wrong (a range that had not
  #   happened yet), on the line most likely to be read mid-incident with the
  #   safety net down. Pin the real range, on one printf, so it can't drift
  #   apart across two lines unnoticed again.
  grep -q "2026-08-31 20:19 -> 2026-09-01 01:40" "$AIMAIL_ROOT/state/autopilot_blind" \
    && { PASS=$((PASS+1)); printf '  ✔ the flag names the real incident date range correctly\n'; } \
    || { FAIL=$((FAIL+1)); FAILURES+=("autopilot_blind flag has the wrong incident date"); printf '  ✖ flag date range wrong or missing:\n'; sed 's/^/      /' "$AIMAIL_ROOT/state/autopilot_blind"; }
else
  FAIL=$((FAIL+1)); FAILURES+=("3 consecutive UNMEASURABLE ticks did not escalate")
  printf '  ✖ no autopilot_blind flag after 3 consecutive UNMEASURABLE ticks\n'
fi
# ⚠ The flag write must not depend on a working mail path (fable: "an alarm
#   must not require the resource whose exhaustion it reports") — it was
#   deliberately written above with AIMAIL_SUPERVISOR pointed at a seat that
#   does not exist, and the flag still landed. Confirmed by the assertion
#   above already succeeding under exactly that condition.
#
# Recovery: once a tick succeeds again, both the streak and the flag clear.
_stub_block 200
"$AIMAIL" budget autopilot >/dev/null 2>&1
if [[ ! -f "$AIMAIL_ROOT/state/autopilot_blind" && ! -f "$AIMAIL_ROOT/state/autopilot_unmeasurable_streak" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a recovered tick cleared both the streak and the blind-alarm flag\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("recovery did not clear the streak/blind-alarm state")
  printf '  ✖ streak or blind flag still present after recovery\n'
fi
rm -f "$(_block_cache)" "$(_throttle_file)" "$(_ramp_at_file)" \
      "$AIMAIL_ROOT/state/budget_ledger.tsv" "$AIMAIL_ROOT/state/autopilot_unmeasurable_streak" \
      "$AIMAIL_ROOT/state/autopilot_blind"

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
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"
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
if [[ ! -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle was actually cleared by the self-detected ramp, not just logged\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-detected ramp fired but left the throttle in place")
  printf '  ✖ throttle still present after the poller reported WAKE=ramp\n'
fi
# ⚠ The restart must be judged on ITS reason. Earlier arms leave real deliveries in main's test
#   inbox (the `budget checkpoint` arm mails every active seat "CHECKPOINT write ROLE.md"), and a
#   poller that exits on WAKE=mail within 3s is a healthy poller reading its mail, not a ramp
#   refire. Clear the inbox first, and on an exit read the log for WAKE=ramp before calling it one.
find "$AIMAIL_ROOT/mail/main" -maxdepth 1 -name '*.md' -delete 2>/dev/null
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar0506b.log" 2>&1 &
P2=$!
sleep 3
if kill -0 "$P2" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ restarting right after does NOT instantly refire — ramp_at was advanced (AR-06a)\n'
  kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
elif ! grep -q 'WAKE=ramp' "$AIMAIL_ROOT/ar0506b.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ restart exited, but NOT on the ramp (%s) — ramp_at was advanced (AR-06a)\n' "$(grep -oE 'WAKE=[a-z_-]+' "$AIMAIL_ROOT/ar0506b.log" | head -1)"
else
  FAIL=$((FAIL+1)); FAILURES+=("restart re-fired immediately — ramp_at was not advanced (AR-06a wake-loop regression)")
  printf '  ✖ restart re-fired immediately on the same stale ramp_at\n'; sed 's/^/      /' "$AIMAIL_ROOT/ar0506b.log" | head -8
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

section "poller — AR-14: a session-block ramp must not lift a WEEKLY park (project owner, 2026-09-11)"
# ⛔⛔ THE DEFECT: `budget_ramp`'s own header has always disclaimed "it cannot see a weekly cap
#   ... and it lifts neither", but nothing upstream of it ever ACTED on that disclaimer -- the
#   poller's ramp-check called `budget_ramp` unconditionally the instant a SESSION-block boundary
#   passed, regardless of WHY the fleet was parked. A park set for "weekly usage 97% is at or over
#   the 95% weekly cap" would ramp right back to full activity at the very next 5-hour boundary
#   even though the 7-day weekly window had not moved at all. The project owner, direct: "it also shouldn't
#   ramp back up if the weekly limit is still past the cap." Two-sided, like every other park/ramp
#   test in this file: confirm the hold fires when weekly is still over cap, AND confirm it does
#   NOT fire (ramps normally) once weekly reads back under cap -- isolating the new branch from
#   "never ramps at all".
ACCT="$("$AIMAIL" budget account 2>/dev/null | grep -oE 'account: [^ ]+' | cut -d' ' -f2)"

# --- Arm 1: weekly still over cap -> must HOLD, not ramp -----------------------------------
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
"$AIMAIL" budget park "automatic: weekly usage 97% is at or over the 95% weekly cap for account $ACCT" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"   # session boundary already passed
printf '%s\t%s\t%s\n' "$(date +%s)" 97 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"   # fresh, still over cap
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar14_hold.log" 2>&1 &
PH1=$!
sleep 3
if kill -0 "$PH1" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the poller stayed ARMED and did not exit -- a session ramp did not lift the weekly park\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: poller exited (ramped) despite weekly still over cap")
  printf '  ✖ poller exited even though weekly is still over cap -- the exact bug the project owner named\n'
fi
if grep -q 'WAKE=weekly-hold' "$AIMAIL_ROOT/ar14_hold.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ it logged WAKE=weekly-hold (noticed the overdue boundary, held anyway)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: no WAKE=weekly-hold logged despite weekly still over cap")
  printf '  ✖ no WAKE=weekly-hold in the poller'"'"'s own log\n'
fi
if [[ -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle is still in place -- the fleet stays parked\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: the throttle was cleared despite weekly still over cap")
  printf '  ✖ throttle was cleared -- the weekly park was lifted anyway\n'
fi
RAT_HOLD="$(awk -F'\t' '$1=="at"{print $2}' "$(_ramp_at_file)" 2>/dev/null)"
if [[ "$RAT_HOLD" =~ ^[0-9]+$ ]] && (( RAT_HOLD > $(date +%s) )); then
  PASS=$((PASS+1)); printf '  ✔ ramp_at was pushed into the future -- will not spin re-checking every tick\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: ramp_at was not pushed forward during a weekly hold")
  printf '  ✖ ramp_at still in the past (%s) -- every tick would re-log the hold\n' "${RAT_HOLD:-unset}"
fi
kill "$PH1" 2>/dev/null; wait "$PH1" 2>/dev/null
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"

# --- Arm 2 (control): weekly back under cap -> must ramp normally, isolating Arm 1's assertion --
"$AIMAIL" budget park "automatic: weekly usage 97% is at or over the 95% weekly cap for account $ACCT" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"
printf '%s\t%s\t%s\n' "$(date +%s)" 20 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"   # fresh, now under cap
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar14_ramp.log" 2>&1 &
PH2=$!
sleep 3
if ! kill -0 "$PH2" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ once weekly reads back under cap, the SAME session-boundary ramp fires normally\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14 control: poller did not ramp even though weekly is back under cap")
  printf '  ✖ poller stayed parked even though weekly recovered -- the hold does not self-clear\n'
  kill "$PH2" 2>/dev/null
fi
if grep -q 'WAKE=ramp' "$AIMAIL_ROOT/ar14_ramp.log" 2>/dev/null && ! grep -q 'WAKE=weekly-hold' "$AIMAIL_ROOT/ar14_ramp.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ it logged the normal WAKE=ramp, not a hold -- the new branch does not fire when weekly is fine\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14 control: wrong wake reason logged once weekly recovered")
  printf '  ✖ expected WAKE=ramp only, got: %s\n' "$(grep -o 'WAKE=[a-z-]*' "$AIMAIL_ROOT/ar14_ramp.log" 2>/dev/null | tr '\n' ' ')"
fi
if [[ ! -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle was actually cleared once weekly recovered\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14 control: throttle still present after weekly recovered")
  printf '  ✖ throttle still present -- the hold outlived the condition that justified it\n'
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"

# --- Arm 3: a SESSION-only park (no weekly in the reason) is completely unaffected -------------
# Isolates the new branch from the existing AR-05/06 path -- confirms `budget_weekly_still_
# blocking` is a no-op (returns false immediately) whenever the park was never about weekly at
# all, so the ordinary session-boundary ramp keeps working exactly as it always has.
"$AIMAIL" budget park "automatic: real usage 85% is at or over the 80% cap for account $ACCT" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"
"$AIMAIL" poll main > "$AIMAIL_ROOT/ar14_session.log" 2>&1 &
PH3=$!
sleep 3
if ! kill -0 "$PH3" 2>/dev/null && grep -q 'WAKE=ramp' "$AIMAIL_ROOT/ar14_session.log" 2>/dev/null && [[ ! -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a SESSION-only park ramps normally, unaffected by the new weekly guard\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: a session-only park was incorrectly held (weekly guard fired on the wrong park type)")
  printf '  ✖ a session-only park did not ramp normally -- the weekly guard is over-matching\n'
  kill "$PH3" 2>/dev/null
fi
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

section "budget — AR-14: budget_weekly_still_blocking() unit behavior, including the unmeasurable case"
# ⛔ MUST NOT CRASH THE CALLER: `budget_probe` calls `unmeasurable()` (core.sh), which is a hard
#   `exit 4`, not a `return`. If `budget_weekly_still_blocking` ever called it unguarded, a stale
#   weekly reading under `AIMAIL_NO_NETWORK=1` (the whole suite's own setting, line ~40) would
#   kill THIS TEST SCRIPT itself, not just fail one assertion -- the exact "zero wake path"
#   self-inflicted failure its own header warns about. This arm is the regression guard for that
#   containment, not merely for the return value.
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
if ! "$AIMAIL" budget park "no reason" >/dev/null 2>&1; then :; fi
"$AIMAIL" budget park "no reason" >/dev/null 2>&1
# no throttled reason mentions weekly, and no weekly file at all yet
source "$REPO/lib/core.sh"
source "$REPO/lib/budget.sh"
if ! budget_weekly_still_blocking; then
  PASS=$((PASS+1)); printf '  ✔ a session-only park reads false immediately (no weekly reading needed at all)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: budget_weekly_still_blocking true for a non-weekly park")
  printf '  ✖ returned true for a park whose own reason never mentions weekly\n'
fi
rm -f "$(_throttle_file)"
"$AIMAIL" budget park "automatic: weekly usage 97% is at or over the 95% weekly cap for account $ACCT" >/dev/null 2>&1
rm -f "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"   # deliberately no reading at all, network disabled for the whole suite
if budget_weekly_still_blocking; then
  PASS=$((PASS+1)); printf '  ✔ an unmeasurable weekly reading (probe disabled, no cached value) stays BLOCKING, not "safe"\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: an unmeasurable weekly reading was treated as safe to ramp")
  printf '  ✖ returned false (safe to ramp) with no weekly reading available at all -- wrong-direction default\n'
fi
printf '%s\t%s\t%s\n' "$(date +%s)" 97 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
if budget_weekly_still_blocking; then
  PASS=$((PASS+1)); printf '  ✔ a fresh reading still over cap reads blocking\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: a fresh over-cap weekly reading did not read as blocking")
  printf '  ✖ returned false with weekly at 97%% against a 95%% cap\n'
fi
printf '%s\t%s\t%s\n' "$(date +%s)" 20 "$(( $(date +%s) + 259200 ))" > "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"
if ! budget_weekly_still_blocking; then
  PASS=$((PASS+1)); printf '  ✔ a fresh reading back under cap reads NOT blocking\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("AR-14: a fresh under-cap weekly reading was still read as blocking")
  printf '  ✖ returned true with weekly at 20%% against a 95%% cap\n'
fi
rm -f "$(_throttle_file)" "$AIMAIL_ROOT/state/weekly_${ACCT}.tsv"

section "budget — 2026-09-20 hybrid multi-account: one account's park must not stall another's"
# ⛔⛔ THE GAP THIS CLOSES: `throttled`/`ramp_at` used to be ONE shared file for every account.
#   With native `claude --bg` sessions, two seats can genuinely run under two different live
#   accounts at once (see docs/hybrid_multi_account_budget_distribution_design_2026-09-20.md) --
#   a shared file meant account A parking at its own cap also read as "parked" for every seat
#   on account B, C, ... THROTTLE_FLAG()/RAMP_AT_FILE() (lib/budget.sh) now key the filename by
#   account_id(), the same idiom WEEKLY_FILE() already used. This is the positive control: two
#   distinct, real account identities, one genuinely parked, the other must read completely
#   unaffected -- not just "the code didn't crash," but the actual file it would consult does
#   not exist for account B at all.
ACCT_ALPHA_DIR="$AIMAIL_ROOT/acctalpha"; ACCT_BETA_DIR="$AIMAIL_ROOT/acctbeta"
mkdir -p "$ACCT_ALPHA_DIR" "$ACCT_BETA_DIR"
rm -f "$AIMAIL_ROOT"/state/throttled_acct* "$AIMAIL_ROOT"/state/ramp_at_acct*
CLAUDE_CONFIG_DIR="$ACCT_ALPHA_DIR" "$AIMAIL" budget park "alpha is over its own cap" >/dev/null 2>&1
if [[ -f "$AIMAIL_ROOT/state/throttled_acctalpha" ]]; then
  PASS=$((PASS+1)); printf '  ✔ parking account alpha wrote an alpha-SPECIFIC throttle file\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("multi-account: park did not write a per-account throttle file")
  printf '  ✖ expected state/throttled_acctalpha to exist after parking alpha\n'
fi
if [[ ! -f "$AIMAIL_ROOT/state/throttled_acctbeta" ]]; then
  PASS=$((PASS+1)); printf '  ✔ account beta has NO throttle file at all -- alpha'"'"'s park never touched it\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("multi-account: parking alpha also created a throttle file for beta")
  printf '  ✖ beta acquired a throttle file it was never parked under\n'
fi
if CLAUDE_CONFIG_DIR="$ACCT_BETA_DIR" "$AIMAIL" budget status 2>/dev/null | grep -q 'THROTTLE IS IN FORCE'; then
  FAIL=$((FAIL+1)); FAILURES+=("multi-account: budget status for beta reported alpha's throttle")
  printf '  ✖ account beta'"'"'s own budget status reads THROTTLED because alpha is\n'
else
  PASS=$((PASS+1)); printf '  ✔ account beta'"'"'s own budget status reads un-throttled while alpha is parked\n'
fi
# NOT re-checked via `budget status` here: that command's own `unmeasurable()` gate
# (lib/budget.sh, "if it cannot measure, it says so") exits before ever reaching the
# throttle-display line whenever the block boundary itself can't be read -- true by
# construction for this synthetic account, which has no real ccusage/ledger history at
# all under AIMAIL_NO_NETWORK=1. The file check is the direct, dependency-free proof
# that beta's own read (just above) did not side-effect alpha's still-active park.
if [[ -f "$AIMAIL_ROOT/state/throttled_acctalpha" ]]; then
  PASS=$((PASS+1)); printf '  ✔ alpha'"'"'s own throttle file is still present after reading beta'"'"'s status\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("multi-account: reading beta's status cleared alpha's own throttle file")
  printf '  ✖ alpha'"'"'s throttle file is gone after a beta-scoped budget status call\n'
fi
rm -f "$AIMAIL_ROOT"/state/throttled_acct* "$AIMAIL_ROOT"/state/ramp_at_acct*

section "poller — poll-persistent never exits on ANY wake (fable's 2026-09-10 ramp-exit finding)"
# ⛔⛔ THE DEFECT: `poller_run_persistent` was first built as a near-total duplicate of the
#   classic loop, and its own header comment said only the mail branch had been changed --
#   "every OTHER exit (account-mismatch ramp, ramp-window-ended, heartbeat, a trapped signal)
#   is UNCHANGED and still exits". That was live and true within an hour of the fleet-wide
#   switch: a `poll-persistent` process hit WAKE=ramp and exited, printing "THIS POLLER HAS NOW
#   EXITED" while advertising itself as the poller that never does. Two-sided per AR-05/AR-06
#   above: same overdue-ramp-while-parked setup, but for `poll-persistent`, which must survive
#   it and keep running, not merely print the right WAKE= text before dying.
"$AIMAIL" budget park "poll-persistent ramp-exit direct test" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"
"$AIMAIL" poll-persistent main > "$AIMAIL_ROOT/pp_ramp.log" 2>&1 &
PP1=$!
sleep 3
if kill -0 "$PP1" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ poll-persistent survived an overdue ramp while parked -- did not exit\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent exited on WAKE=ramp (the live regression)")
  printf '  ✖ poll-persistent exited on an overdue ramp -- the exact live bug\n'
fi
if grep -q 'WAKE=ramp' "$AIMAIL_ROOT/pp_ramp.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ it logged WAKE=ramp (noticed the condition, just did not exit over it)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent did not log WAKE=ramp at all")
  printf '  ✖ no WAKE=ramp in the persistent poller'"'"'s own log\n'
fi
if ! grep -q 'THIS POLLER HAS NOW EXITED' "$AIMAIL_ROOT/pp_ramp.log" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ it did NOT print the classic exit footer -- no false "you no longer have one" claim\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent printed the classic exit footer while still running")
  printf '  ✖ persistent poller printed the classic re-arm footer\n'
fi
if [[ ! -f "$(_throttle_file)" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the throttle was still actually cleared by the self-detected ramp\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent noticed the overdue ramp but left the throttle in place")
  printf '  ✖ throttle still present after poll-persistent logged WAKE=ramp\n'
fi
# Confirm it is genuinely LOOPING, not merely alive-and-hung: a second overdue ramp_at, set
# WHILE it is still running, must also be noticed and logged, proving the loop iterates rather
# than having fallen into some other blocking wait after the first wake.
# ⚠ ORDER MATTERS: `budget park` writes its OWN fresh (future) `ramp_at` as part of parking --
# call it FIRST, then overwrite that fresh timestamp with an overdue one SECOND, exactly the
# order the AR-05/06 arm above uses. Reversed, `budget park` clobbers the overdue value with a
# real future one and the second cycle silently never fires (caught by running this once).
"$AIMAIL" budget park "poll-persistent ramp-exit direct test, second cycle" >/dev/null 2>&1
printf 'at\t%s\n' "$(( $(date +%s) - 5 ))" > "$(_ramp_at_file)"
# R6(j): wait for the SECOND wake, bounded (the loop iterates every AIMAIL_POLL_INTERVAL; under load one
# iteration can exceed a fixed 3 s sleep, which read as "not looping" when it was merely slow)
for _i in $(seq 1 40); do (( $(grep -c 'WAKE=ramp' "$AIMAIL_ROOT/pp_ramp.log" 2>/dev/null || echo 0) >= 2 )) && break; sleep 0.5; done
if kill -0 "$PP1" 2>/dev/null && (( $(grep -c 'WAKE=ramp' "$AIMAIL_ROOT/pp_ramp.log" 2>/dev/null || echo 0) >= 2 )); then
  PASS=$((PASS+1)); printf '  ✔ still alive and noticed a SECOND overdue ramp -- genuinely looping, not hung\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll-persistent did not notice a second overdue ramp -- may be alive but not looping")
  printf '  ✖ no second WAKE=ramp -- alive but possibly stuck rather than looping\n'
fi
kill "$PP1" 2>/dev/null; wait "$PP1" 2>/dev/null
rm -f "$(_throttle_file)" "$(_ramp_at_file)"

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
accepts "ack the probe message" -- ack main --all --sha "$(_shas_for main)"

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
accepts "ack it" -- ack main --all --sha "$(_shas_for main)"
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

section "role — the status banner must never land in a redirected capture (2026-09-02)"
# ⛔⛔ MEASURED INCIDENT: `aimail role show <seat> > file` used to capture the
#    banner ("role: seat NNNB written N min ago") ALONGSIDE the real handover,
#    because the banner printed via `info` (stdout) right before the body was
#    `cat`-ed to the SAME stream. Fable's own role file (and its .prev backup)
#    each accumulated 65 prepended banner lines this way. The fix: the banner
#    now goes to stderr, and `role write` separately refuses a file whose first
#    line IS that banner, verbatim, as a backstop.
"$AIMAIL" role show main >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -q '^role: main' "$AIMAIL_ROOT/.err" && ! grep -q '^role: main' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the status banner goes to stderr, never stdout — a redirect captures ONLY the real content\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("role show's banner leaked into stdout (redirect-capturable)")
  printf '  ✖ banner found in stdout, or missing from stderr — the incident would reproduce\n'
fi
if grep -q '# v2' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the real handover content is still on stdout, unaffected\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("role show's real content did not land on stdout")
  printf '  ✖ real handover content missing from stdout\n'
fi
# ③ the backstop — a file that already starts with the banner (an
#    already-captured redirect, or a copy-paste mistake) must be refused, not
#    silently written as if it were a real handover.
printf 'role: main    42B    written 3 min ago\n\n# real handover below\nDONE: x\n' > "$AIMAIL_ROOT/banner_first.md"
refuses "a file starting with the status banner is refused" "aimail's own role-status banner" \
  -- role write main "$AIMAIL_ROOT/banner_first.md"
# ④ the other direction — a near-miss first line (uses the same words, wrong
#    shape) must NOT false-positive. A guard broad enough to catch every
#    mention of "role:"/"written" would refuse legitimate handovers too.
printf 'role: written by architect, not the tool banner\n\nDONE: x\n' > "$AIMAIL_ROOT/mentions_role.md"
accepts "a near-miss first line (same words, wrong shape) is still accepted" \
  -- role write main "$AIMAIL_ROOT/mentions_role.md"

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
# fleet sweep also runs the RAM/CPU pressure check (lib/pressure.sh), which reads the machine's real
# /proc. This block counts the mails the SEAT-health sweep sends, so the real memory must not add one,
# and the library reads no environment variable a test could set. From here to the end of the file
# $AIMAIL is therefore a COPY of the tree whose pressure.sh points at a healthy fake /proc.
PCOPY="$AIMAIL_ROOT/pcopy"; mkdir -p "$PCOPY" "$AIMAIL_ROOT/fakeproc"
tar -C "$REPO" --exclude=.git -cf - . | tar -C "$PCOPY" -xf -
sed -i "s#^PRESSURE_PROC_ROOT_DIR=/proc#PRESSURE_PROC_ROOT_DIR=$AIMAIL_ROOT/fakeproc#" "$PCOPY/lib/pressure.sh"
printf 'MemTotal: 67108864 kB\nMemAvailable: 3145728 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$AIMAIL_ROOT/fakeproc/meminfo"
AIMAIL="$PCOPY/bin/aimail"
# `aimail fleet pressure` is a real subcommand: a low-memory fake /proc sets the battery stop file, a
# healthy one clears it (an unregistered supervisor means no mail, so the sweep counts below are untouched).
AIMAIL_SUPERVISOR=nobody-registered accepts "fleet pressure runs on a low-memory machine" -- fleet pressure
_pchk() { # _pchk DESC EXIT_CODE_OF_CONDITION
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"
  else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ✖ %s\n' "$1"; fi; }
[ -f "$AIMAIL_ROOT/state/pressure/pressure-stop" ]; _pchk "fleet pressure sets the stop file on CRIT" $?
printf 'MemTotal: 67108864 kB\nMemAvailable: 67108864 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' > "$AIMAIL_ROOT/fakeproc/meminfo"
AIMAIL_SUPERVISOR=nobody-registered accepts "fleet pressure runs on a healthy machine" -- fleet pressure
[ ! -f "$AIMAIL_ROOT/state/pressure/pressure-stop" ]; _pchk "fleet pressure clears the stop file when healthy" $?
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep runs" -- fleet sweep
SWEEP1=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( SWEEP1 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ a CRASHED seat generated exactly one unprompted alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep alert count after 1st run: got $SWEEP1 want 1")
  printf '  ✖ sweep alert count after 1st run: got %s, want 1\n' "$SWEEP1"
  for _f in "$AIMAIL_ROOT"/mail/sweepvisor/*.md; do [[ -f "$_f" ]] && printf '      %s | %s\n' "$(basename "$_f")" "$(grep -m1 '^subject:' "$_f")"; done; unset _f
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

section "fleet sweep — AR-22: STALLED must alert too, past a longer threshold"
# ⛔ THE DEFECT: an untracked/orphaned poller (launched with `&`, or a shell
#   that disowned it) still delivers mail and still writes a clean `hb_exit`
#   — the heartbeat looks identical to a poller that is legitimately mid-turn.
#   Sweep skipped STALLED entirely (`*) continue ;;`), so the ONLY difference
#   between "reading mail right now" and "died 7 hours ago" was whether a
#   human happened to run `aimail fleet`. Measured overnight: main dead ~7h,
#   audit dead ~90m, neither raised. ⇒ alert on STALLED too, but only past
#   AIMAIL_STALL_ALERT — an order of magnitude past REARM_GRACE — so a seat
#   genuinely mid-task for a few minutes never pages anyone.
accepts "register a seat that will stall silently" -- seat add stally "will stall"
mkdir -p "$AIMAIL_ROOT/state/poller"
rm -f "$AIMAIL_ROOT/mail/sweepvisor"/*.md   # this section counts from zero, not from AR-20's leftovers
NOW=$(date +%s)
printf 'pid\t777777\nppid\t1\nstarted\t%s\nbeat\t%s\nexit_at\t%s\nexit_reason\tmail\n' \
  "$((NOW-305))" "$((NOW-305))" "$((NOW-300))" > "$AIMAIL_ROOT/state/poller/stally.hb"
# ① inside the alert grace (300s stalled, default AIMAIL_STALL_ALERT=1200) —
#    STALLED on the dashboard, but must generate NO alert: this is exactly the
#    shape of a seat legitimately still mid-turn.
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep runs while stall is still inside the alert grace" -- fleet sweep
STALL0=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( STALL0 == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ a recently-STALLED seat (inside the grace) generated NO alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a recently-STALLED seat alerted early: got $STALL0 want 0")
  printf '  ✖ a recently-STALLED seat alerted early — got %s message(s), want 0\n' "$STALL0"
fi
# ② past the alert threshold — the actual overnight shape. Same pid/beat, only
#    exit_at moves further into the past, so this is the SAME event aging, not
#    a new one — the dedup key must not change out from under it.
printf 'pid\t777777\nppid\t1\nstarted\t%s\nbeat\t%s\nexit_at\t%s\nexit_reason\tmail\n' \
  "$((NOW-1305))" "$((NOW-1305))" "$((NOW-1300))" > "$AIMAIL_ROOT/state/poller/stally.hb"
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep on a stall now past the alert threshold" -- fleet sweep
STALL1=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( STALL1 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ a STALLED seat past the alert threshold generated exactly one unprompted alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("STALLED-past-threshold alert count: got $STALL1 want 1")
  printf '  ✖ STALLED-past-threshold alert count: got %s, want 1\n' "$STALL1"
fi
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep re-run on the SAME ongoing stall" -- fleet sweep
STALL2=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( STALL2 == 1 )); then
  PASS=$((PASS+1)); printf '  ✔ re-sweeping the SAME ongoing stall did not send a second alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep re-alerted an already-reported stall: now $STALL2 messages")
  printf '  ✖ sweep re-alerted an already-reported stall — now %s message(s)\n' "$STALL2"
fi
# ③ a genuinely NEW stall (different pid/beat), also past threshold, must
#    still alert — proving the dedup is keyed on the event, not the seat name.
printf 'pid\t666666\nppid\t1\nstarted\t%s\nbeat\t%s\nexit_at\t%s\nexit_reason\tmail\n' \
  "$((NOW-1400))" "$((NOW-1400))" "$((NOW-1300))" > "$AIMAIL_ROOT/state/poller/stally.hb"
AIMAIL_SUPERVISOR=sweepvisor accepts "sweep on a NEW, distinct stall" -- fleet sweep
STALL3=$(find "$AIMAIL_ROOT/mail/sweepvisor" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
if (( STALL3 == 2 )); then
  PASS=$((PASS+1)); printf '  ✔ a genuinely NEW stall (different pid/beat) alerted again (%s total)\n' "$STALL3"
else
  FAIL=$((FAIL+1)); FAILURES+=("a new stall did not generate a new alert: got $STALL3 want 2")
  printf '  ✖ a new stall did not generate a new alert: got %s, want 2\n' "$STALL3"
fi
rm -f "$AIMAIL_ROOT/state/poller/stally.hb"

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

section "whoami — AR-26: a deployment's OWN stop hook keeps its OWN session->seat mapping"
# ⛔ THE DEFECT: a deployment can fork/rename hooks/stop_guard.sh into its own
#   hook (wired into ITS settings.json under a different filename) instead of
#   invoking this one — exactly the "two session->seat records that can
#   drift" AR-21's own comment warned about. When that happens, EVERY seat
#   reads as unregistered here even though the deployment's real hook has
#   tracked every session all along. AIMAIL_EXTERNAL_SEAT_DIR is the bridge.
export CLAUDE_CODE_SESSION_ID=selftest-whoami-ext-sid
unset AIMAIL_EXTERNAL_SEAT_DIR
unmeasurable_test "no external dir configured, nothing registered either way" \
  "not registered to any seat" -- whoami
accepts "register a seat for the external-mapping test" -- seat add extwhoseat "test"
printf '# handover\nDONE: external whoami test.\n' > "$AIMAIL_ROOT/whext.md"
accepts "write it a handover" -- role write extwhoseat "$AIMAIL_ROOT/whext.md"
export AIMAIL_EXTERNAL_SEAT_DIR="$AIMAIL_ROOT/external-hook-state"
mkdir -p "$AIMAIL_EXTERNAL_SEAT_DIR"
unmeasurable_test "external dir configured but this session has no file in it" \
  "not registered to any seat" -- whoami
printf 'extwhoseat' > "$AIMAIL_EXTERNAL_SEAT_DIR/seat_selftest-whoami-ext-sid"
accepts "whoami falls back to the external mapping and resumes it" -- whoami
if grep -q "registered as seat 'extwhoseat'" "$AIMAIL_ROOT/.out" && \
   grep -q 'RESUME: extwhoseat' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ external mapping resolved AND resumed, in one command\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("whoami did not fall back to AIMAIL_EXTERNAL_SEAT_DIR")
  printf '  ✖ whoami did not fall back to AIMAIL_EXTERNAL_SEAT_DIR\n'
fi
# AR-26b — aimail's OWN mapping must still win if both exist (never let a
# fallback silently override the primary source of truth).
mkdir -p "$AIMAIL_ROOT/state/stopguard"
printf 'extwhoseat' > "$AIMAIL_ROOT/state/stopguard/session.selftest-whoami-ext-sid"
accepts "seat add for the primary-wins seat" -- seat add primaryseat "test"
printf 'primaryseat' > "$AIMAIL_ROOT/state/stopguard/session.selftest-whoami-ext-sid"
printf '# handover\nDONE.\n' > "$AIMAIL_ROOT/whprim.md"
accepts "write it a handover" -- role write primaryseat "$AIMAIL_ROOT/whprim.md"
accepts "whoami prefers its OWN mapping over the external one when both exist" -- whoami
if grep -q "registered as seat 'primaryseat'" "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ own mapping wins over the external fallback\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("external fallback wrongly overrode aimail's own mapping")
  printf '  ✖ external fallback wrongly overrode aimail'"'"'s own mapping\n'
fi
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AIMAIL_EXTERNAL_SEAT_DIR

section "sessions — PER-SESSION liveness, which every other view here gets wrong"
# ⛔⛔ THE DEFECT UNDER TEST, measured 2026-09-06 and it cost a false fleet alarm:
#    every liveness instrument in this repo is keyed on a SEAT NAME. `poller_state`
#    reads one `<seat>.hb`; the project fork's `status` ran a per-seat process
#    check and printed that ONE answer against every registration row of the seat.
#    46 registrations existed, 39 from sessions that had ended days before, and
#    the report claimed 8 concurrent "main" sessions where there was 1.
#    Simultaneously `fleet` called four WORKING seats STALLED, because "the poller
#    exited and nothing re-armed it" is exactly what a healthy session mid-build
#    produces. Both numbers were wrong in opposite directions from the same cause.
# ⭐ The classifier's own arms live in `aimail sessions --selftest` (fixture /proc
#    table + fixture transcripts, driving the REAL regexes and the REAL ancestry
#    walk). This section asserts it is WIRED IN — a selftest that passes while the
#    verb is unreachable is the "green check that isn't running" case this harness
#    exists to refuse.
accepts "the classifier's own arms all pass"          -- sessions --selftest
if grep -q 'passed, 0 failed' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ sessions --selftest reports 0 failures (and printed its denominator)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sessions --selftest did not report 0 failures")
  printf '  ✖ sessions --selftest did not report 0 failures\n'
fi

# ⭐ a16: `aimail context` has the SAME "wired in" shape — its own module
#   (context_readout.py) carries a synthetic-fixture selftest, and asserting
#   it here through the CLI verb (not by calling the module directly) is what
#   catches the verb being unreachable even though the module passes in
#   isolation. context_readout.py prints its denominator to STDERR
#   ("N FAILED" / "0 FAILED"), unlike sessions --selftest's stdout phrasing —
#   two different modules, two different formats, checked against each one's
#   own actual output rather than copying the other's string.
accepts "the context reader's own selftest arms all pass"  -- context --selftest
if grep -q '0 FAILED' "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ context --selftest reports 0 failures\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context --selftest did not report 0 failures")
  printf '  ✖ context --selftest did not report 0 failures\n'
fi

# ⭐ a16: context --settings, in isolation from the fixture below — the SAME
#   AIMAIL_FLEET_ACCOUNTS / AIMAIL_ACCOUNT_DIR_<acct> override idiom the
#   placement/budget fixtures already use (never a real account's settings.json).
#   Both arms: a set autoCompactWindow reads distinctly from no file at all —
#   collapsing them is exactly how "nobody's set this yet" goes unnoticed.
CTXYES_DIR="$AIMAIL_ROOT/ctxyes"; mkdir -p "$CTXYES_DIR"
printf '{"autoCompactWindow": 500000}\n' > "$CTXYES_DIR/settings.json"
CTXNO_DIR="$AIMAIL_ROOT/ctxno"; mkdir -p "$CTXNO_DIR"
AIMAIL_FLEET_ACCOUNTS="ctxYes ctxNo" \
  AIMAIL_ACCOUNT_DIR_ctxYes="$CTXYES_DIR" AIMAIL_ACCOUNT_DIR_ctxNo="$CTXNO_DIR" \
  "$AIMAIL" context --settings > "$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if grep -qE '^ctxYes +yes +500000' "$AIMAIL_ROOT/.out" && grep -qE '^ctxNo +NO FILE' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ context --settings distinguishes a set autoCompactWindow from no file at all\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context --settings did not distinguish present vs missing autoCompactWindow")
  printf '  ✖ context --settings did not distinguish present vs missing — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi

# A scratch registration store in the EXTERNAL shape (the project fork's
# `seat_<sid>` files), plus a fixture transcript dir and a fixture process table.
# ⚠ AIMAIL_EXTERNAL_SEAT_DIR is the seam AR-26 already added for `whoami`; reusing
#   it rather than inventing a second one is the point — two ways to say where a
#   fork's registrations live is two things that can drift.
SESSDIR="$AIMAIL_ROOT/extseats"; mkdir -p "$SESSDIR"
SESSPROJ="$AIMAIL_ROOT/projects/slug"; mkdir -p "$SESSPROJ"
SNOW=$(date +%s)
export AIMAIL_EXTERNAL_SEAT_DIR="$SESSDIR"
export AIMAIL_SESSION_PROJECTS_DIR="$AIMAIL_ROOT/projects"
export AIMAIL_SESSION_FAKE_PROCS="$AIMAIL_ROOT/fakeprocs"
export AIMAIL_SESSION_FAKE_NOW="$SNOW"
accepts "register the seat these sessions claim"      -- seat add sessseat "per-session tests"
printf 'sessseat' > "$SESSDIR/seat_SESS-LIVE-0001"
printf 'sessseat' > "$SESSDIR/seat_SESS-GONE-0002"
touch -d "@$((SNOW - 20))"        "$SESSPROJ/SESS-LIVE-0001.jsonl"
touch -d "@$((SNOW - 4 * 86400))" "$SESSPROJ/SESS-GONE-0002.jsonl"
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --resume=SESS-LIVE-0001 --verbose
101	100	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll sessseat'	SESS-LIVE-0001
102	101	bash /tmp/aimail-poll.T/bin/aimail poll sessseat	SESS-LIVE-0001
PROCS

accepts "sessions --json runs against both stores"    -- sessions --json
# ① the arm failing first: the live session must read ARMED…
_sess_field() {  # _sess_field <sid> <key>
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for s in d["sessions"]:
    if s["sid"]==sys.argv[2]: print(s[sys.argv[3]]); break
else: print("NOSUCHROW")' "$AIMAIL_ROOT/.out" "$1" "$2"
}
if [[ "$(_sess_field SESS-LIVE-0001 state)" == "ARMED" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the session that owns the poller reads ARMED\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("live session did not read ARMED (got $(_sess_field SESS-LIVE-0001 state))")
  printf '  ✖ live session did not read ARMED\n'
fi
# ⛔ …and ③ the other direction, which is THE BUG: the same SEAT has a live
#    poller, and this row must still not inherit it.
if [[ "$(_sess_field SESS-GONE-0002 state)" == "STALE" ]]; then
  PASS=$((PASS+1)); printf '  ✔ its dead sibling at the SAME seat reads STALE, not LIVE\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("dead sibling of an armed session did not read STALE (got $(_sess_field SESS-GONE-0002 state))")
  printf '  ✖ dead sibling of an armed session did not read STALE\n'
fi
# ④ the denominator: concurrency is a count of SESSIONS, not of rows.
if [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["live_by_seat"].get("sessseat",0))' "$AIMAIL_ROOT/.out")" == "1" ]]; then
  PASS=$((PASS+1)); printf '  ✔ seat concurrency counts 1 session from 2 registrations\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("live_by_seat counted registrations instead of live sessions")
  printf '  ✖ live_by_seat counted registrations instead of live sessions\n'
fi
# ⭐ a16: `aimail context` reads THIS SAME transcript, once it carries one real
#   assistant turn — ARMED (liveness) and context_tokens (payload) are two
#   different questions, proven on one already-fixtured session rather than a
#   second, disconnected fixture. 3 + 97 + 400000 = 400100, never estimated.
#   (Runs after the sessions --json arms above so it doesn't clobber their own
#   read of .out; context does its own sessions --json call internally.)
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":3,"cache_creation_input_tokens":97,"cache_read_input_tokens":400000,"output_tokens":12}}}' >> "$SESSPROJ/SESS-LIVE-0001.jsonl"
touch -d "@$((SNOW - 20))" "$SESSPROJ/SESS-LIVE-0001.jsonl"
accepts "context reads the ARMED session's own transcript"  -- context sessseat --json
if [[ "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("SESS-LIVE-0001", {}).get("context_tokens"))' "$AIMAIL_ROOT/.out" 2>/dev/null)" == "400100" ]]; then
  PASS=$((PASS+1)); printf '  ✔ context reports the exact context_tokens sum from the real transcript\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context did not report the exact context_tokens for a fixture session")
  printf '  ✖ context did not report the expected context_tokens — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
# ⛔ its STALE sibling must not appear at all — context reads LIVE sessions
#   only (a STALE transcript is history, not a cost anyone is currently paying).
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "SESS-GONE-0002" not in d else 1)' "$AIMAIL_ROOT/.out" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ a STALE sibling is excluded from context (history, not a live cost)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context included a STALE session's transcript")
  printf '  ✖ context included a STALE session — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
# ② positive control in the form the instrument claims to detect: a session with
#    no process at all but recent activity is DEAD — the ONE actionable state —
#    and must be distinct from STALE, or "restart this" and "ignore this" merge.
printf 'sessseat' > "$SESSDIR/seat_SESS-DEAD-0003"
touch -d "@$((SNOW - 2400))" "$SESSPROJ/SESS-DEAD-0003.jsonl"
accepts "re-read with a recently-departed session"    -- sessions --json
if [[ "$(_sess_field SESS-DEAD-0003 state)" == "DEAD" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a session gone 40m reads DEAD, distinctly from STALE\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a recently-departed session did not read DEAD (got $(_sess_field SESS-DEAD-0003 state))")
  printf '  ✖ a recently-departed session did not read DEAD\n'
fi
# ⛔ UNMEASURABLE MUST NOT ROUND TO DEAD. No transcript at all + a fresh
#    registration is a session we cannot see, and the pruner reads this field.
printf 'sessseat' > "$SESSDIR/seat_SESS-UNKN-0004"
accepts "re-read with an unmeasurable session"        -- sessions --json
if [[ "$(_sess_field SESS-UNKN-0004 state)" == "UNKNOWN" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a session with no transcript reads UNKNOWN, never DEAD\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("an unmeasurable session did not read UNKNOWN (got $(_sess_field SESS-UNKN-0004 state))")
  printf '  ✖ an unmeasurable session did not read UNKNOWN\n'
fi

# ⭐⭐ a16-followup (2026-09-24, assistant bug report): a seat can carry MORE
#   THAN ONE live-classified session at once (a per-account twin, or a stale
#   registration nobody pruned) -- context_report must pick exactly ONE per
#   seat, never emit every one. Selftest, in the ask's own words: "two rows
#   for one seat, where the older one has the bigger context. It must report
#   the newer one."
printf 'dupeseat' > "$SESSDIR/seat_DUPE-OLD-0001"
printf 'dupeseat' > "$SESSDIR/seat_DUPE-NEW-0002"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":800000,"output_tokens":5}}}' > "$SESSPROJ/DUPE-OLD-0001.jsonl"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":50000,"output_tokens":5}}}' > "$SESSPROJ/DUPE-NEW-0002.jsonl"
touch -d "@$((SNOW - 800))" "$SESSPROJ/DUPE-OLD-0001.jsonl"
touch -d "@$((SNOW - 10))"  "$SESSPROJ/DUPE-NEW-0002.jsonl"
accepts "register a seat (dupeseat) for the two duplicate-row test"  -- seat add dupeseat "duplicate-row test"
accepts "context --json with two live rows for one seat"  -- context dupeseat --json
DUPE_OUT="$AIMAIL_ROOT/.out"
if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if ("DUPE-OLD-0001" in d) != ("DUPE-NEW-0002" in d) else 1)' "$DUPE_OUT" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ exactly ONE of the two duplicate rows is reported, not both/neither\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context reported both duplicate rows for one seat, or neither")
  printf '  ✖ context did not reduce to one row per seat — got: %s\n' "$(cat "$DUPE_OUT")"
fi
if python3 -c 'import json,sys; sys.exit(0 if "DUPE-NEW-0002" in json.load(open(sys.argv[1])) else 1)' "$DUPE_OUT" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the NEWER (fresher-transcript) session was reported, not the older bigger one\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context reported the OLDER duplicate row instead of the newer one")
  printf '  ✖ context did not pick the newer duplicate — got: %s\n' "$(cat "$DUPE_OUT")"
fi
if [[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("DUPE-NEW-0002",{}).get("context_tokens"))' "$DUPE_OUT" 2>/dev/null)" == "50002" ]]; then
  PASS=$((PASS+1)); printf "  ✔ …and its context_tokens is the newer session's own number, not the older bigger one\n"
else
  FAIL=$((FAIL+1)); FAILURES+=("context reported the wrong context_tokens for the reduced duplicate row")
  printf '  ✖ wrong context_tokens for the picked duplicate — got: %s\n' "$(cat "$DUPE_OUT")"
fi
rm -f "$SESSDIR/seat_DUPE-OLD-0001" "$SESSDIR/seat_DUPE-NEW-0002" "$SESSPROJ/DUPE-OLD-0001.jsonl" "$SESSPROJ/DUPE-NEW-0002.jsonl"

# ⭐⭐ a16-followup: MULTI-ACCOUNT transcript discovery -- the bug's actual root
#   cause. A seat's session PROCESS is real and findable regardless of which
#   account it runs under (the process-table scan is account-agnostic), but its
#   TRANSCRIPT lives under THAT account's own <config-dir>/projects/ tree --
#   invisible to a caller that only ever looked at its own account's root.
#   Without the plural AIMAIL_SESSION_PROJECTS_DIRS this reproduces the exact
#   reported symptom (a genuinely live session reads "unmeasurable"); setting
#   it is the fix.
OTHERACCT_ROOT="$AIMAIL_ROOT/otheracct-projects"; OTHERACCT_PROJ="$OTHERACCT_ROOT/slug"
mkdir -p "$OTHERACCT_PROJ"
printf 'otherseat' > "$SESSDIR/seat_OTHER-ACCT-0001"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-sonnet-5","usage":{"input_tokens":4,"cache_creation_input_tokens":6,"cache_read_input_tokens":90,"output_tokens":2}}}' > "$OTHERACCT_PROJ/OTHER-ACCT-0001.jsonl"
touch -d "@$((SNOW - 5))" "$OTHERACCT_PROJ/OTHER-ACCT-0001.jsonl"
cat >> "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
200	1	/usr/bin/claude --resume=OTHER-ACCT-0001 --verbose
PROCS
accepts "register a seat (otherseat) for the multi-account transcript test"  -- seat add otherseat "multi-account test"
accepts "…its session IS live (real process), but WITHOUT the plural var its transcript isn't found" -- context otherseat --json
if [[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("OTHER-ACCT-0001",{}).get("context_tokens"))' "$AIMAIL_ROOT/.out" 2>/dev/null)" == "None" ]]; then
  PASS=$((PASS+1)); printf '  ✔ reproduces the original bug: a live session on another account reads unmeasurable\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("expected the pre-fix symptom (unmeasurable) to still reproduce without the plural var")
  printf '  ✖ did not reproduce the original symptom — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
export AIMAIL_SESSION_PROJECTS_DIRS="research=$OTHERACCT_ROOT"
accepts "…and WITH the plural var naming that account's own root, it reads its real usage" -- context otherseat --json
if [[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("OTHER-ACCT-0001",{}).get("context_tokens"))' "$AIMAIL_ROOT/.out" 2>/dev/null)" == "100" ]]; then
  PASS=$((PASS+1)); printf "  ✔ a session on a DIFFERENT account's projects/ root is now found and read correctly\n"
else
  FAIL=$((FAIL+1)); FAILURES+=("context did not read a session's transcript from a different account's own root")
  printf '  ✖ multi-account transcript lookup failed — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
if [[ "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("OTHER-ACCT-0001",{}).get("account"))' "$AIMAIL_ROOT/.out" 2>/dev/null)" == "research" ]]; then
  PASS=$((PASS+1)); printf '  ✔ …and it carries the account label it was actually found under\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("context did not label the session with the account it was found on")
  printf '  ✖ missing/wrong account label — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
accepts "context (plain text) shows the ACCOUNT column"  -- context otherseat
if grep -qE '^otherseat +research' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the plain-text report shows account next to the seat\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("plain-text context report did not show the ACCOUNT column")
  printf '  ✖ missing ACCOUNT column in plain report — got: %s\n' "$(cat "$AIMAIL_ROOT/.out")"
fi
unset AIMAIL_SESSION_PROJECTS_DIRS
rm -f "$SESSDIR/seat_OTHER-ACCT-0001"
grep -v OTHER-ACCT-0001 "$AIMAIL_SESSION_FAKE_PROCS" > "$AIMAIL_SESSION_FAKE_PROCS.tmp" && mv "$AIMAIL_SESSION_FAKE_PROCS.tmp" "$AIMAIL_SESSION_FAKE_PROCS"

section "sessions --prune — on EVIDENCE, never on a guess"
# ⛔⛔ THE STANDING WARNING THIS HAD TO CLEAR, from poller_guard.sh's own source:
#   "DO NOT 'FIX' THIS BY PRUNING STALE ROWS. A wrong prune de-registers a LIVE
#    session … a stale row misleads, a bad prune wedges." Correct, and it is an
#    argument against pruning on a guess. These four arms are the evidence bar:
#    the STALE one goes, and the LIVE, DEAD and UNKNOWN ones must all survive.
#    ⚠ A pruner that deletes everything passes an "is the stale file gone" test
#      on its own. The three survival arms are what make that test mean anything.
accepts "prune runs"                                  -- sessions --prune
if [[ ! -f "$SESSDIR/seat_SESS-GONE-0002" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the STALE registration was removed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune left the stale registration in place")
  printf '  ✖ prune left the stale registration in place\n'
fi
if [[ -f "$SESSDIR/seat_SESS-LIVE-0001" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the LIVE session survived (de-registering it silences its Stop hook)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune de-registered a LIVE session — its Stop hook is now inert")
  printf '  ✖ prune de-registered a LIVE session\n'
fi
if [[ -f "$SESSDIR/seat_SESS-DEAD-0003" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the DEAD session survived — it is the finding a human must still see\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune deleted a DEAD session's registration — evidence destroyed")
  printf '  ✖ prune deleted a DEAD session — the report erased its own evidence\n'
fi
if [[ -f "$SESSDIR/seat_SESS-UNKN-0004" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the UNMEASURABLE session survived — unmeasurable is not deletable\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune deleted a session it could not measure")
  printf '  ✖ prune deleted a session it could not measure\n'
fi

section "sessions --prune — the UNATTRIBUTED-SESSION gate (fail closed)"
# ⛔⛔ THE HOLE, found by fable in design review 2026-09-06 BEFORE this ran
#   destructively: a session started FRESH and left IDLE is invisible to every
#   signal the classifier has. No `--resume=<sid>` in its own cmdline (it was
#   never resumed) and no CLAUDE_CODE_SESSION_ID in its OWN environ — only its
#   CHILDREN carry that, and an idle session has none. MEASURED on the box: 9
#   live claude processes, 8 attributable, exactly 1 not.
#   ⇒ Its registration ages to STALE like any abandoned one, and deleting it
#     makes its Stop hook `allow-unregistered` FOREVER — silent and permanent.
#   ⇒ We cannot delete "only the safe ones", because identifying which stale row
#     belongs to the unattributed process is exactly what cannot be done.
# ⛔ AND THE RESCUE THAT DOES NOT EXIST, measured so nobody re-tries it: binding
#   the process via a transcript held open in /proc/<pid>/fd. It holds none —
#   all 9 checked, zero *.jsonl descriptors. Claude Code opens, appends, closes.
# ⚠ THREE ARMS. The refusal alone is not the property under test: a guard that
#   refuses unconditionally would pass it while making prune permanently
#   useless, and one that refuses on a no-op only trains the reader to force it.
SESSGATE="$AIMAIL_ROOT/gateseats"; mkdir -p "$SESSGATE"
export AIMAIL_EXTERNAL_SEAT_DIR="$SESSGATE"
printf 'sessseat' > "$SESSGATE/seat_SESS-GONE-0002"
touch -d "@$((SNOW - 4 * 86400))" "$SESSPROJ/SESS-GONE-0002.jsonl"
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --verbose --output-format stream-json
PROCS
# ① the arm failing first — and the exit code is the contract, not just the text.
unmeasurable_test "unattributed live process + a stale candidate -> REFUSES" \
  "cannot prove staleness" -- sessions --prune
if [[ -f "$SESSGATE/seat_SESS-GONE-0002" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the refusal deleted nothing\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune refused but deleted the stale registration anyway")
  printf '  ✖ prune refused but deleted anyway\n'
fi
if grep -q 'pid 100' "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ the refusal NAMES the blocking pid (a refusal you cannot act on is noise)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune refused without naming the unattributed process")
  printf '  ✖ prune refused without naming the unattributed process\n'
fi
# ② the same unattributed process with NOTHING to delete must NOT refuse.
rm -f "$SESSGATE/seat_SESS-GONE-0002"
accepts "unattributed process but nothing stale -> proceeds, no refusal" -- sessions --prune
# ③ THE NEGATIVE CONTROL, and it is the arm that keeps this from becoming a
#    permanent block: with every claude process attributable, prune must still
#    actually delete.
printf 'sessseat' > "$SESSGATE/seat_SESS-GONE-0002"
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --resume=SESS-LIVE-0001 --verbose
PROCS
touch -d "@$((SNOW - 20))" "$SESSPROJ/SESS-LIVE-0001.jsonl"
accepts "every process attributed -> prune runs"      -- sessions --prune
if [[ ! -f "$SESSGATE/seat_SESS-GONE-0002" ]]; then
  PASS=$((PASS+1)); printf '  ✔ with nothing unattributed the stale row IS removed (gate is not blanket)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("the unattributed gate became a permanent refusal")
  printf '  ✖ the gate refuses even with every process attributed\n'
fi
# ⛔ AND IT MUST BE VISIBLE WITHOUT ATTEMPTING A PRUNE. A hole that only
#   announces itself at deletion time is a hole nobody knows they have.
printf 'sessseat' > "$SESSGATE/seat_SESS-GONE-0002"
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --verbose --output-format stream-json
PROCS
"$AIMAIL" sessions > "$AIMAIL_ROOT/.out" 2>&1
if grep -q 'CANNOT ATTRIBUTE TO A SESSION' "$AIMAIL_ROOT/.out" \
   && grep -q 'NOT PRUNABLE RIGHT NOW' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the plain report surfaces it AND withdraws the --prune advice\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sessions report hid the unattributed-process blind spot")
  printf '  ✖ sessions report did not surface the unattributed process\n'
fi
# And the machine-readable contract, so a future caller need not re-derive the rule.
"$AIMAIL" sessions --json > "$AIMAIL_ROOT/.out" 2>&1
if [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prune_safe"])' "$AIMAIL_ROOT/.out")" == "False" ]]; then
  PASS=$((PASS+1)); printf '  ✔ --json exposes prune_safe=false rather than making callers re-derive it\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("prune_safe did not report false with an unattributed process")
  printf '  ✖ prune_safe did not report false\n'
fi
rm -rf "$SESSGATE"
export AIMAIL_EXTERNAL_SEAT_DIR="$SESSDIR"
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --resume=SESS-LIVE-0001 --verbose
101	100	/bin/bash -c source snap.sh && eval '/x/bin/aimail poll sessseat'	SESS-LIVE-0001
102	101	bash /tmp/aimail-poll.T/bin/aimail poll sessseat	SESS-LIVE-0001
PROCS
touch -d "@$((SNOW - 20))" "$SESSPROJ/SESS-LIVE-0001.jsonl"

section "fleet — a down poller is not a dead seat (the STALLED conflation)"
# ⛔⛔ THE FALSE ALARM: STALLED means "a poller exited with a reason and nothing
#   re-armed it". A session forty minutes into a test battery produces that every
#   time, and so does a session that died. `fleet` printed the same "may be
#   mid-task or stuck" for both and a human read it as "stuck", four seats over.
#   Now the per-session evidence decides. BOTH DIRECTIONS ARE REQUIRED: without
#   the nobody-home arm, a `fleet` that never alarms would pass the first.
_hb sessseat pid=999999 started=$((SNOW-9000)) beat=$((SNOW-9000)) exit_at=$((SNOW-9000)) exit_reason=mail
"$AIMAIL" fleet sessseat > "$AIMAIL_ROOT/.out" 2>&1
if grep -qE '^sessseat +STALLED' "$AIMAIL_ROOT/.out" && grep -q 'DO NOT NUDGE' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ STALLED + a live working session reads WORKING, ⛔ do not nudge\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("fleet did not use session evidence to explain a STALLED seat")
  printf '  ✖ fleet did not use session evidence on a STALLED seat — got: %s\n' \
    "$(grep -E '^sessseat ' "$AIMAIL_ROOT/.out" | head -1)"
fi
# ⚠ AND FIRST, THE ASYMMETRY THIS FIXTURE EXPOSED — worth pinning, because the
#   obvious way to write the next arm gets it wrong. Killing the process alone is
#   NOT enough to make a session read dead: a transcript written seconds ago
#   still counts as alive for the whole active window. That is deliberate and the
#   error is deliberately one-sided — a false DEAD gets a working seat killed by
#   a human, a false WORKING costs at most ACTIVE_WINDOW of delay.
: > "$AIMAIL_SESSION_FAKE_PROCS"
"$AIMAIL" sessions --json > "$AIMAIL_ROOT/.out" 2>&1
if [[ "$(_sess_field SESS-LIVE-0001 state)" == "WORKING" ]]; then
  PASS=$((PASS+1)); printf '  ✔ process gone but transcript fresh -> still WORKING (errs away from a false DEAD)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("a just-departed process with a fresh transcript did not stay WORKING")
  printf '  ✖ process gone + fresh transcript should stay WORKING, got %s\n' "$(_sess_field SESS-LIVE-0001 state)"
fi

# ③ the other direction — the SAME stalled heartbeat with nobody at the seat must
#   still say so plainly, or this fix has simply switched off the alarm.
#   ⛔ BOTH signals have to go: no process AND a transcript past the active
#     window. Removing only the process reproduces the arm above, not this one.
touch -d "@$((SNOW - 4000))" "$SESSPROJ/SESS-LIVE-0001.jsonl"
"$AIMAIL" fleet sessseat > "$AIMAIL_ROOT/.out" 2>&1
if grep -q 'NOBODY HOME' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ the same STALLED heartbeat with NO live session reads NOBODY HOME\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("fleet did not flag a stalled seat with no live session")
  printf '  ✖ fleet did not flag a stalled seat with no live session — got: %s\n' \
    "$(grep -E '^sessseat ' "$AIMAIL_ROOT/.out" | head -1)"
fi
# ⛔ AND THE ENRICHMENT MUST NEVER BECOME A DEPENDENCY. With the classifier
#   switched off, every verdict has to fall back to the heartbeat-only wording
#   AND say that it did — a dashboard that silently drops its newest signal is
#   how "0 findings" and "0 readings" become the same line.
AIMAIL_FLEET_NO_SESSIONS=1 "$AIMAIL" fleet sessseat > "$AIMAIL_ROOT/.out" 2>&1
if grep -qE '^sessseat +STALLED +\?' "$AIMAIL_ROOT/.out" \
   && grep -q 'could NOT be measured' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ classifier unavailable -> SESS reads "?" and fleet says so, not 0\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("fleet printed an unmeasured session count as if it were measured")
  printf '  ✖ fleet did not degrade honestly without the classifier\n'
fi
# ⛔ SWEEP IS THE UNATTENDED HALF, and suppressing an alert is a decision that
#   must be logged, not silent. Both arms again: suppressed when a session is
#   demonstrably working, fired when it is not.
cat > "$AIMAIL_SESSION_FAKE_PROCS" <<PROCS
100	1	/usr/bin/claude --resume=SESS-LIVE-0001 --verbose
PROCS
touch -d "@$SNOW" "$SESSPROJ/SESS-LIVE-0001.jsonl"
"$AIMAIL" fleet sweep > "$AIMAIL_ROOT/.out" 2>&1
if grep -q 'mid-task, not stalled; no alert' "$AIMAIL_ROOT/.out" \
   && grep -q '1 suppressed by live-session evidence' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ sweep suppresses a STALLED alert for a working session, and SAYS it did\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep did not suppress-and-log a STALLED alert for a working session")
  printf '  ✖ sweep did not suppress-and-log the alert — got: %s\n' \
    "$(grep -i 'sweep:' "$AIMAIL_ROOT/.out" | tail -2 | tr '\n' ' ')"
fi
rm -f "$AIMAIL_ROOT/state/sweep_alerted/sessseat"
: > "$AIMAIL_SESSION_FAKE_PROCS"
touch -d "@$((SNOW - 4000))" "$SESSPROJ/SESS-LIVE-0001.jsonl"
"$AIMAIL" fleet sweep > "$AIMAIL_ROOT/.out" 2>&1
if grep -q '0 suppressed' "$AIMAIL_ROOT/.out" && grep -qE '[1-9] new alert' "$AIMAIL_ROOT/.out"; then
  PASS=$((PASS+1)); printf '  ✔ with nobody at the seat the same stall DOES alert (suppression is not blanket)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sweep stopped alerting on a genuinely dead stalled seat")
  printf '  ✖ sweep did not alert on a stalled seat with no live session — got: %s\n' \
    "$(grep -i 'sweep:' "$AIMAIL_ROOT/.out" | tail -1)"
fi
rm -f "$AIMAIL_ROOT/state/poller/sessseat.hb"
unset AIMAIL_EXTERNAL_SEAT_DIR AIMAIL_SESSION_PROJECTS_DIR AIMAIL_SESSION_FAKE_PROCS AIMAIL_SESSION_FAKE_NOW

section "watchdog — 2026-09-20: session-state check, per the real 2+ hour wedge incident"
# ⛔ A stub `claude` executable on PATH answers `agents --json` from a file
#   this section rewrites per-arm -- same "stub the external command" idiom
#   the curl-stub budget tests already established, applied to a different
#   command this time. Real seat, real registered mail, real stop_guard
#   session-mapping file -- nothing mocked below the CLI boundary.
"$AIMAIL" seat add wdseat >/dev/null 2>&1
"$AIMAIL" seat add wdsupervisor >/dev/null 2>&1
mkdir -p "$AIMAIL_ROOT/state/stopguard"
WD_SID="wdsession-0000-0000-0000-000000000001"
printf '%s' wdseat > "$AIMAIL_ROOT/state/stopguard/session.$WD_SID"
WD_STUBBIN="$AIMAIL_ROOT/wd_stubbin"; mkdir -p "$WD_STUBBIN"
WD_CREDS="$AIMAIL_ROOT/fake_wd_creds"; mkdir -p "$WD_CREDS"
printf '{"claudeAiOauth":{"accessToken":"x"}}\n' > "$WD_CREDS/.credentials.json"
WD_AGENTS_JSON="$AIMAIL_ROOT/wd_agents_response.json"
cat > "$WD_STUBBIN/claude" <<CLAUDESTUB
#!/usr/bin/env bash
if [[ "\$1" == "agents" ]]; then cat "$WD_AGENTS_JSON"; exit 0; fi
exit 1
CLAUDESTUB
chmod +x "$WD_STUBBIN/claude"
_wd_run() {
  env PATH="$WD_STUBBIN:$PATH" AIMAIL_ROOT="$AIMAIL_ROOT" AIMAIL_CONFIG=/dev/null \
    AIMAIL_FLEET_ACCOUNTS=wdacct AIMAIL_ACCOUNT_DIR_wdacct="$WD_CREDS" AIMAIL_SUPERVISOR=wdsupervisor \
    "$AIMAIL" fleet watchdog "$@"
}
_wd_set_state() { printf '[{"kind":"background","sessionId":"%s","state":"%s"}]\n' "$WD_SID" "$1" > "$WD_AGENTS_JSON"; }
_wd_inbox_count() { find "$AIMAIL_ROOT/mail/wdsupervisor" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l; }
rm -f "$AIMAIL_ROOT"/state/watchdog_blocked_streak_wdseat "$AIMAIL_ROOT"/state/watchdog_alerted/wdseat
rm -f "$AIMAIL_ROOT/mail/wdseat"/*.md "$AIMAIL_ROOT/mail/wdsupervisor"/*.md 2>/dev/null

# ARM 1: blocked state, EMPTY mailbox -- must NEVER accumulate a streak, let alone alert
# (the real bug this whole design was rewritten to fix: framing's own genuinely
# healthy idle seat reads "blocked" the entire time it waits between wakes).
_wd_set_state blocked
_wd_run >/dev/null 2>&1; _wd_run >/dev/null 2>&1; _wd_run >/dev/null 2>&1
if [[ ! -f "$AIMAIL_ROOT/state/watchdog_blocked_streak_wdseat" ]] && (( $(_wd_inbox_count) == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ blocked state with an EMPTY mailbox never accumulates a streak or alerts (ordinary idle time)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: blocked+empty-mailbox incorrectly accumulated a streak or alerted")
  printf '  ✖ streak file: %s   alerts: %s\n' "$(cat "$AIMAIL_ROOT/state/watchdog_blocked_streak_wdseat" 2>/dev/null || echo none)" "$(_wd_inbox_count)"
fi

# ARM 2: blocked state WITH real pending mail, sustained -- must alert after 3 ticks.
echo "go" > "$AIMAIL_ROOT/wd_body.md"
"$AIMAIL" send --to wdseat --from wdsupervisor --subject "a real go-ahead" --body-file "$AIMAIL_ROOT/wd_body.md" >/dev/null 2>&1
_wd_run >/dev/null 2>&1
_wd_run >/dev/null 2>&1
_wd_run >/dev/null 2>&1
if (( $(_wd_inbox_count) >= 1 )); then
  PASS=$((PASS+1)); printf '  ✔ blocked state WITH real pending mail, sustained 3 ticks, DOES alert\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: blocked+pending-mail for 3 ticks did not alert")
fi
if grep -ql 'pending mail\|WITH pending mail' "$AIMAIL_ROOT/mail/wdsupervisor"/*.md 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ the alert names the real cause (pending mail), not just the raw state\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: alert body did not explain the pending-mail reasoning")
fi

# ARM 3: the SAME ongoing block must not re-alert (dedup on sessionId:state).
BEFORE="$(_wd_inbox_count)"
_wd_run >/dev/null 2>&1
AFTER="$(_wd_inbox_count)"
if [[ "$BEFORE" == "$AFTER" ]]; then
  PASS=$((PASS+1)); printf '  ✔ the same ongoing block does not re-alert every tick\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: re-alerted on the same ongoing block ($BEFORE -> $AFTER)")
fi

# ARM 4: recovery (state -> working) clears the streak, even with mail still pending.
_wd_set_state working
_wd_run >/dev/null 2>&1
if [[ ! -f "$AIMAIL_ROOT/state/watchdog_blocked_streak_wdseat" ]]; then
  PASS=$((PASS+1)); printf '  ✔ recovering to "working" clears the streak (self-heals, no human action needed)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: streak survived a recovery to working")
fi

# ARM 5: "done" (a session that finished its turn normally) must read as OK, never alert-worthy,
# even with mail still sitting (a seat between turns with unacked mail is normal -- the poller
# just hasn't run yet; "blocked" mid-invocation is the different fact this check targets).
rm -f "$AIMAIL_ROOT/mail/wdsupervisor"/*.md "$AIMAIL_ROOT"/state/watchdog_blocked_streak_wdseat "$AIMAIL_ROOT"/state/watchdog_alerted/wdseat
_wd_set_state done
_wd_run >/dev/null 2>&1; _wd_run >/dev/null 2>&1; _wd_run >/dev/null 2>&1
if [[ ! -f "$AIMAIL_ROOT/state/watchdog_blocked_streak_wdseat" ]] && (( $(_wd_inbox_count) == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ "done" (a normally-completed turn) is never treated as alert-worthy\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: \"done\" state was incorrectly treated as a wedge")
fi

# ARM 6: an UNREGISTERED session (no stop_guard mapping) is skipped entirely -- known,
# by-design pass-through, same convention poller_guard.sh already uses.
printf '[{"kind":"background","sessionId":"totally-unregistered-session","state":"blocked"}]\n' > "$WD_AGENTS_JSON"
echo "x" > "$AIMAIL_ROOT/wd_body2.md"
"$AIMAIL" send --to wdseat --from wdsupervisor --subject "irrelevant" --body-file "$AIMAIL_ROOT/wd_body2.md" >/dev/null 2>&1
OUT="$(_wd_run 2>&1)"
if grep -q 'checked 0 registered session' <<<"$OUT"; then
  PASS=$((PASS+1)); printf '  ✔ an unregistered session is skipped entirely, not miscounted or alerted on\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("watchdog: an unregistered session was not skipped cleanly")
  printf '  ✖ got: %s\n' "$OUT"
fi

rm -f "$AIMAIL_ROOT/mail/wdseat"/*.md "$AIMAIL_ROOT/mail/wdsupervisor"/*.md \
      "$AIMAIL_ROOT"/state/watchdog_blocked_streak_wdseat "$AIMAIL_ROOT"/state/watchdog_alerted/wdseat \
      "$AIMAIL_ROOT/state/stopguard/session.$WD_SID"

section "poller — 2026-09-20: self-serve backlog prompt on a quiet heartbeat"
# ⛔ A real heartbeat, triggered for real via AIMAIL_POLL_HEARTBEAT_SEC=1 + a fast poll interval
#   -- not a stubbed code path. The suppression arm uses a REAL gateclaim acquire, not a faked
#   state file, so this proves the actual `gateclaim.sh --list` grep this feature depends on.
accepts "register a seat for the self-serve heartbeat check" -- seat add ssbseat
SSB_OUT="$(AIMAIL_POLL_HEARTBEAT_SEC=1 AIMAIL_POLL_INTERVAL=1 timeout 10 "$AIMAIL" poll ssbseat 2>&1)"
if grep -q 'YOU HOLD NO CLAIM RIGHT NOW' <<<"$SSB_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ a claim-free seat sees the self-serve backlog prompt on a real heartbeat\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-serve: claim-free seat did not see the prompt on a real heartbeat")
  printf '  ✖ got: %s\n' "$(sed 's/^/      /' <<<"$SSB_OUT")"
fi
if grep -q "gateclaim.sh <key> ssbseat" <<<"$SSB_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ the prompt names THIS seat in its own suggested command, not a placeholder\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-serve: prompt did not substitute the real seat name")
fi
if "$REPO/bin/gateclaim.sh" ssbtestkey ssbseat --desc "holding something real" >/dev/null 2>&1; then
  PASS=$((PASS+1)); printf '  ✔ claimed a real key for the suppression arm\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-serve: setup claim for the suppression arm failed")
fi
SSB_OUT2="$(AIMAIL_POLL_HEARTBEAT_SEC=1 AIMAIL_POLL_INTERVAL=1 timeout 10 "$AIMAIL" poll ssbseat 2>&1)"
if ! grep -q 'YOU HOLD NO CLAIM RIGHT NOW' <<<"$SSB_OUT2"; then
  PASS=$((PASS+1)); printf '  ✔ a seat that ALREADY holds a claim does NOT see the self-serve prompt (no double-claim nudge)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-serve: a claim-holding seat still saw the self-serve prompt")
  printf '  ✖ got: %s\n' "$(sed 's/^/      /' <<<"$SSB_OUT2")"
fi
if grep -q 'THIS IS NOT A NO-OP' <<<"$SSB_OUT2"; then
  PASS=$((PASS+1)); printf '  ✔ the underlying "actually check your state" warning still fires regardless of claim state\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("self-serve: suppressing the backlog prompt also silenced the base warning")
fi
"$REPO/bin/gateclaim.sh" --release ssbtestkey ssbseat >/dev/null 2>&1

section "poller — 2026-09-21: plain \`poll\` prints its deprecation warning exactly once; poll-persistent never"
# ⛔ The project owner's ask via assistant (20260921T002827): warn, point at poll-persistent, change nothing
#   else. Real invocations (a real heartbeat wake for the classic one, a timeout-killed persistent
#   one) -- the private re-exec re-enters poller_run, so "once" is a real property to prove, not
#   a grep for presence.
accepts "register a seat for the deprecation check" -- seat add depseat
DEP_OUT="$(AIMAIL_POLL_HEARTBEAT_SEC=1 AIMAIL_POLL_INTERVAL=1 timeout 10 "$AIMAIL" poll depseat 2>&1)"
DEP_N="$(grep -c 'DEPRECATED: `aimail poll depseat`' <<<"$DEP_OUT")"
if [[ "$DEP_N" == 1 ]]; then
  PASS=$((PASS+1)); printf '  ✔ plain poll printed the deprecation warning exactly once (private re-exec did not double it)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll deprecation: warning printed $DEP_N times, want exactly 1")
fi
if grep -q 'poll-persistent depseat' <<<"$DEP_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ the warning names the replacement command for THIS seat\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll deprecation: warning did not name poll-persistent for the seat")
fi
if grep -q 'WAKE=heartbeat' <<<"$DEP_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ behaviour unchanged: the classic poller still ran its heartbeat wake\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll deprecation: classic poll no longer reached its heartbeat wake")
fi
DEP_QUIET="$(AIMAIL_POLL_DEPRECATION_QUIET=1 AIMAIL_POLL_HEARTBEAT_SEC=1 AIMAIL_POLL_INTERVAL=1 timeout 10 "$AIMAIL" poll depseat 2>&1)"
if ! grep -q 'DEPRECATED: `aimail poll' <<<"$DEP_QUIET"; then   # the exit footer's own one-line hint still mentions the word; the WARNING line is what QUIET silences
  PASS=$((PASS+1)); printf '  ✔ AIMAIL_POLL_DEPRECATION_QUIET=1 silences it\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll deprecation: QUIET=1 did not silence the warning")
fi
DEP_PP="$(AIMAIL_POLL_INTERVAL=1 timeout 4 "$AIMAIL" poll-persistent depseat 2>&1)"
if ! grep -q 'DEPRECATED: `aimail poll' <<<"$DEP_PP"; then
  PASS=$((PASS+1)); printf '  ✔ poll-persistent prints no deprecation warning\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("poll deprecation: poll-persistent printed the classic warning")
fi

section "main_only_landing_guard — enforcement selftest in-suite (per-repo/per-ref allow-list, 2026-09-22)"
# Same lesson as stop_guard/supervisor_guard above: a selftest outside the suite proves
# nothing on its own -- assert the rc AND an expected arm count, never a tally of printed
# lines. This is the ENFORCEMENT logic itself (does a non-allowed seat actually get
# refused on a protected ref); the landing_guard section right below is a DIFFERENT
# concern (is the hook still resolvable at all) -- both matter, neither substitutes
# for the other.
MOLG_EXPECTED_ARMS=23
MOLG="$(bash "$REPO/hooks/main_only_landing_guard.sh" selftest 2>&1)"; MOLG_RC=$?
while IFS= read -r line; do
  case "$line" in
    *"✔"*) PASS=$((PASS+1)); printf '  %s\n' "$line" ;;
    *"✖"*) FAIL=$((FAIL+1)); FAILURES+=("main_only_landing_guard: $line"); printf '  %s\n' "$line" ;;
  esac
done <<< "$MOLG"
MOLG_ARMS="$(printf '%s\n' "$MOLG" | grep -cE '✔|✖')"
if [[ $MOLG_RC -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ main_only_landing_guard selftest exited 0\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("main_only_landing_guard selftest exit=$MOLG_RC")
  printf '  ✖ main_only_landing_guard selftest exited %s — its arms did not run to completion\n' "$MOLG_RC"
fi
if [[ $MOLG_ARMS -eq $MOLG_EXPECTED_ARMS ]]; then
  PASS=$((PASS+1)); printf '  ✔ main_only_landing_guard selftest ran all %s expected arms\n' "$MOLG_EXPECTED_ARMS"
else
  FAIL=$((FAIL+1)); FAILURES+=("main_only_landing_guard selftest ran $MOLG_ARMS arms, expected $MOLG_EXPECTED_ARMS")
  printf '  ✖ main_only_landing_guard selftest ran %s arms, expected %s — a silently-dropped arm passes for free\n' "$MOLG_ARMS" "$MOLG_EXPECTED_ARMS"
fi

section "landing_guard — resolvability check selftest in-suite (a dangling hook must read red)"
# Same lesson as stop_guard/supervisor_guard above: a selftest outside the suite proves
# nothing on its own. Drive it as a real subprocess, assert its own tally AND its exit.
LG="$(bash "$AIMAIL" landing-guard --selftest 2>&1)"; LG_RC=$?
printf '%s\n' "$LG" | sed 's/^/    /'
if grep -q ' 0 failed' <<<"$LG" && ! grep -q '  FAIL ' <<<"$LG"; then
  PASS=$((PASS+1)); printf '  ✔ landing_guard selftest: every arm passed\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("landing_guard selftest reported a failing arm")
fi
if (( LG_RC == 0 )); then
  PASS=$((PASS+1)); printf '  ✔ landing_guard selftest exited 0\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("landing_guard selftest exit=$LG_RC")
fi
# The verb itself, against a scratch repo that IS correctly guarded. The hook is COPIED into the
# suite's own root with +x rather than symlinked to the repo file: this arm tests the CHECK, not
# the repo's committed mode bit (which the first run of this arm caught at 100644 -- a real finding,
# fixed alongside, but not what this arm is for).
LG_REPO="$AIMAIL_ROOT/lg_repo"; mkdir -p "$LG_REPO" "$AIMAIL_ROOT/lg_hooks"
cp "$REPO/hooks/main_only_landing_guard.sh" "$AIMAIL_ROOT/lg_hooks/main_only_landing_guard.sh"
chmod +x "$AIMAIL_ROOT/lg_hooks/main_only_landing_guard.sh"
git -C "$LG_REPO" init -q -b main && git -C "$LG_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
ln -s "$AIMAIL_ROOT/lg_hooks/main_only_landing_guard.sh" "$LG_REPO/.git/hooks/reference-transaction"
git -C "$LG_REPO" config --add main-landing-guard.protected-ref refs/heads/main
accepts "landing-guard <repo> exits 0 on a correctly guarded repo" -- landing-guard "$LG_REPO"
rm "$LG_REPO/.git/hooks/reference-transaction"
LG_RC="$(_run landing-guard "$LG_REPO")"
if [[ "$LG_RC" != 0 ]] && grep -q "MISSING" "$AIMAIL_ROOT/.err" "$AIMAIL_ROOT/.out" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  ✔ landing-guard <repo> exits non-zero and says MISSING once the hook is gone (rc=%s)\n' "$LG_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("landing-guard <repo> did not go red once the hook was removed (rc=$LG_RC)")
fi

section "sterility"
# shellcheck source=lib/sterility.sh
source "$REPO/lib/sterility.sh"
STER_DIR="$AIMAIL_ROOT/sterility_repo"; mkdir -p "$STER_DIR/lib"
# sterility_scan finds its own root via BASH_SOURCE, i.e. wherever the sourced
# sterility.sh physically lives -- that's correct for the real tool (it always
# checks the repo it ships in) but means a fixture dir must get its OWN copy to
# source, or every "scan" below would silently scan this real repo instead.
cp "$REPO/lib/sterility.sh" "$STER_DIR/lib/sterility.sh"
STER_LIB="$STER_DIR/lib/sterility.sh"
printf 'nothing identifying here\n' > "$STER_DIR/plain.txt"
printf 'Copyright (c) 2026 A Real Person\n' > "$STER_DIR/LICENSE"
printf 'this file names ExampleCorp directly, which it should not\n' > "$STER_DIR/leaky.txt"
( cd "$STER_DIR" && git init -q && git add -A -- plain.txt LICENSE leaky.txt && git -c user.email=t@t -c user.name=t commit -q -m init )

( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="" bash -c '. "'"$STER_LIB"'"; sterility_scan >/dev/null 2>&1' )
if [[ $? -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ unset AIMAIL_STERILITY_TERMS -> no-op (rc=0), nothing checked\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan should no-op with no terms configured")
fi

STER_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleCorp" bash -c '. "'"$STER_LIB"'"; sterility_scan' )"
STER_RC=$?
if [[ "$STER_RC" -gt 0 ]] && grep -q "leaky.txt" <<<"$STER_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ a configured term present in a tracked file is caught, names the file (rc=%s)\n' "$STER_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan did not catch a real configured-term hit (rc=$STER_RC)")
fi

# the exact shape that survived two gates on 2026-09-23: a config-example COMMENT naming the owner with a date
printf '# AIMAIL_PINNED_SEATS="assistant main"   # LOCKED to their account (ExampleOwner 2026-09-22 17:28)\n' > "$STER_DIR/planted.conf.example"
( cd "$STER_DIR" && git add planted.conf.example && git -c user.email=t@t -c user.name=t commit -q -m plant )
STER_PLANT_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleOwner" bash -c '. "'"$STER_LIB"'"; sterility_scan' )"
if [[ $? -gt 0 ]] && grep -q "planted.conf.example:1:" <<<"$STER_PLANT_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ a planted owner-name comment in a .conf.example file is caught, file and line named\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan missed a planted owner-name comment line in a .conf.example file")
fi
STER_LIC_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="A Real Person" bash -c '. "'"$STER_LIB"'"; sterility_scan' )"
if [[ $? -eq 0 ]] && [[ -z "$STER_LIC_OUT" ]]; then
  PASS=$((PASS+1)); printf '  ✔ LICENSE is exempt: a term that only appears there is not flagged\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan should exempt LICENSE, did not")
fi

STER_CLEAN_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="NothingThatAppearsAnywhere" bash -c '. "'"$STER_LIB"'"; sterility_scan' )"
if [[ $? -eq 0 ]] && [[ -z "$STER_CLEAN_OUT" ]]; then
  PASS=$((PASS+1)); printf '  ✔ a configured term that matches nothing reads clean (rc=0)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan false-positived on a term matching nothing")
fi

# The real self-test: this repo's OWN tree, against this repo's OWN configured terms.
# ⛔ WHERE THE TERMS COME FROM, in order: the environment (the scrub in lib_env.sh keeps this one
#   variable on purpose), then this checkout's own gitignored etc/aimail.conf, then the MAIN
#   checkout's conf reached through the shared git common dir -- because a WORKTREE has no
#   etc/aimail.conf of its own (gitignored files are per checkout), so every gate run in a scratch
#   worktree used to hit the "skipped" branch below and a real owner-name line rode through two
#   gates (2026-09-23 01:36, code-review caught it by eye).
# ⛔⛔ NO SILENT SKIP (2026-09-24): the branch below used to print "(skipped)" and count as
#   NEITHER pass nor fail whenever none of the three sources above resolved any terms -- exactly
#   what a genuinely independent fresh clone hits (its own .git has no common-dir relationship to
#   the real deployment's conf, and the gitignored conf file itself is per-checkout). That silent
#   skip is what let 12 real hits (the owner's name, work email and project code names, in
#   hooks/sterility_guard.sh, hooks/sterility_push_guard.sh, tests/ask_ledger.sh) sit in this
#   repo's own tracked tree undetected by a fresh-clone gate run, AND is the reason a fresh clone's
#   full-suite total read 614 instead of 615 -- this exact test silently not existing there, not a
#   pass. This repo is never a "fresh install with nothing configured yet" the way another fleet's
#   day-one install would be: it is THIS deployment's own canonical test suite, and if no checkout
#   anywhere can name this deployment's own terms, that is itself a finding, not nothing to check.
#   So: unresolved terms is now a FAILURE here, loud and counted, never a bare skipped line.
REAL_STER_TERMS="${AIMAIL_STERILITY_TERMS:-}"
_ster_conf_terms() { [[ -r "$1" ]] && sed -n "s/^AIMAIL_STERILITY_TERMS=\"\\(.*\\)\"\$/\\1/p" "$1" | tail -1; }
[[ -n "$REAL_STER_TERMS" ]] || REAL_STER_TERMS="$(_ster_conf_terms "$REPO/etc/aimail.conf")"
if [[ -z "$REAL_STER_TERMS" ]]; then
  _common="$(cd "$REPO" && git rev-parse --git-common-dir 2>/dev/null)"
  [[ -n "$_common" ]] && REAL_STER_TERMS="$(_ster_conf_terms "$(cd "$REPO" && cd "$_common/.." && pwd)/etc/aimail.conf")"
  unset _common
fi
if [[ -n "$REAL_STER_TERMS" ]]; then
  REAL_STER_OUT="$( cd "$REPO" && AIMAIL_STERILITY_TERMS="$REAL_STER_TERMS" bash -c '. "'"$REPO"'/lib/sterility.sh"; sterility_scan' )"
  REAL_STER_RC=$?
  if [[ "$REAL_STER_RC" -eq 0 ]]; then
    PASS=$((PASS+1)); printf '  ✔ this repo'"'"'s own tracked tree is clean against its own configured terms\n'
  else
    FAIL=$((FAIL+1)); FAILURES+=("this repo's own tree has $REAL_STER_RC real sterility hit(s) -- see: AIMAIL_STERILITY_TERMS=\"$REAL_STER_TERMS\" bash -c '. lib/sterility.sh; sterility_scan'")
    printf '%s\n' "$REAL_STER_OUT" | sed 's/^/    /'
  fi
else
  FAIL=$((FAIL+1)); FAILURES+=("no AIMAIL_STERILITY_TERMS resolved from env, $REPO/etc/aimail.conf, or the main checkout's conf via git-common-dir -- this repo's own tree was NOT checked, never treat that as clean")
  printf '  ✖ no terms resolved -- this repo'"'"'s own tree was NOT checked (not the same as clean)\n'
  printf '    Configure AIMAIL_STERILITY_TERMS in etc/aimail.conf (this checkout or the main one), or export it directly.\n'
fi

# sterility_scan_identity -- content scanning above never touches commit author/committer
# metadata; this is the separate check that does.
STER_ID_CLEAN_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleCorp" GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="t@t.example" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="t@t.example" bash -c '. "'"$STER_LIB"'"; sterility_scan_identity' )"
if [[ $? -eq 0 ]] && [[ -z "$STER_ID_CLEAN_OUT" ]]; then
  PASS=$((PASS+1)); printf '  ✔ sterility_scan_identity: a clean author/committer identity reads clean (rc=0)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan_identity false-positived on a clean identity")
fi

STER_ID_LEAK_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleCorp" GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="person@examplecorp.example" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="person@examplecorp.example" bash -c '. "'"$STER_LIB"'"; sterility_scan_identity' )"
STER_ID_LEAK_RC=$?
if [[ "$STER_ID_LEAK_RC" -eq 2 ]] && grep -q "^author:" <<<"$STER_ID_LEAK_OUT" && grep -q "^committer:" <<<"$STER_ID_LEAK_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ sterility_scan_identity: a leaking author AND committer identity is caught, both named (rc=%s)\n' "$STER_ID_LEAK_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan_identity did not catch a real leaking identity (rc=$STER_ID_LEAK_RC)")
fi

# sterility_scan_history -- audit-facing only, must NEVER be wired anywhere that blocks on
# its own result (published history is the owner's call to rewrite, never a seat's).
( cd "$STER_DIR" && GIT_AUTHOR_NAME="t" GIT_AUTHOR_EMAIL="person@examplecorp.example" GIT_COMMITTER_NAME="t" GIT_COMMITTER_EMAIL="person@examplecorp.example" git commit -q --allow-empty -m "leaking-identity commit for the history-scan arm" )
STER_HIST_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleCorp" bash -c '. "'"$STER_LIB"'"; sterility_scan_history' )"
STER_HIST_RC=$?
# ⛔ COMMIT MESSAGES (2026-09-23 02:01: a landed message named the owner while its file content was clean)
( cd "$STER_DIR" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat: ExampleCorp-approved lander policy" )
STER_MSG_OUT="$( cd "$STER_DIR" && AIMAIL_STERILITY_TERMS="ExampleCorp" bash -c '. "'"$STER_LIB"'"; sterility_scan_history' )"
if [[ $? -gt 0 ]] && grep -q "^message:.*ExampleCorp-approved" <<<"$STER_MSG_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ sterility_scan_history: a leaking commit MESSAGE is found, tagged message: and quoted\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan_history missed a leaking commit message")
fi
if [[ "$STER_HIST_RC" -gt 0 ]] && grep -qi "examplecorp" <<<"$STER_HIST_OUT"; then
  PASS=$((PASS+1)); printf '  ✔ sterility_scan_history: a leaking identity already in history is found, sha named (rc=%s)\n' "$STER_HIST_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_scan_history did not find a real leaking identity already in history (rc=$STER_HIST_RC)")
fi

# ⛔ pre-commit hook: the identity check is BLOCKING at commit time, not just reported after.
STER_HOOK_DIR="$AIMAIL_ROOT/sterility_hook_repo"; rm -rf "$STER_HOOK_DIR"; mkdir -p "$STER_HOOK_DIR/lib" "$STER_HOOK_DIR/etc"
cp "$REPO/lib/sterility.sh" "$STER_HOOK_DIR/lib/sterility.sh"
printf 'AIMAIL_STERILITY_TERMS="ExampleCorp"\n' > "$STER_HOOK_DIR/etc/aimail.conf"
( cd "$STER_HOOK_DIR" && git init -q && ln -sf "$REPO/hooks/sterility_guard.sh" .git/hooks/pre-commit \
  && git add etc/aimail.conf lib/sterility.sh \
  && git -c user.email=t@t -c user.name=t commit -q -m setup --no-verify )
( cd "$STER_HOOK_DIR" && echo hook_test > f.txt && git add f.txt \
  && git -c user.name=t -c user.email=person@examplecorp.example commit -q -m "should be refused" ) \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
STER_HOOK_RC=$?
if [[ "$STER_HOOK_RC" -ne 0 ]] && grep -q "sterility_guard" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ pre-commit hook refuses a commit whose own author/committer identity leaks (rc=%s)\n' "$STER_HOOK_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_guard.sh pre-commit hook did not refuse a leaking commit identity (rc=$STER_HOOK_RC)")
fi
( cd "$STER_HOOK_DIR" && git -c user.name=t -c user.email=t@t.example commit -q -m "should succeed" ) \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if [[ $? -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ pre-commit hook allows a commit whose identity is clean\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_guard.sh pre-commit hook refused a genuinely clean identity")
fi

# ⛔⛔ commit-msg hook (2026-09-24): a commit whose CONTENT is clean can still describe
#   itself in prose that names a configured term (a message that read "sterility grep
#   (<configured term list>): clean" carried the terms in). sterility_guard.sh (pre-commit)
#   never reads the message; sterility_push_guard.sh (pre-push) does, but only AI seats
#   never push this repo, so that guard never runs during the ordinary local commit/land
#   workflow. This hook is the one that actually fires for it.
( cd "$STER_HOOK_DIR" && ln -sf "$REPO/hooks/sterility_commit_msg_guard.sh" .git/hooks/commit-msg )
( cd "$STER_HOOK_DIR" && echo msg_hook_test1 > g.txt && git add g.txt \
  && git -c user.name=t -c user.email=t@t.example commit -q -m "feat: ExampleCorp-approved lander policy" ) \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
STER_MSGHOOK_RC=$?
if [[ "$STER_MSGHOOK_RC" -ne 0 ]] && grep -q "sterility_commit_msg_guard" "$AIMAIL_ROOT/.err"; then
  PASS=$((PASS+1)); printf '  ✔ commit-msg hook refuses a commit whose own MESSAGE leaks a configured term (rc=%s)\n' "$STER_MSGHOOK_RC"
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_commit_msg_guard.sh did not refuse a leaking commit message (rc=$STER_MSGHOOK_RC)")
fi
( cd "$STER_HOOK_DIR" && echo msg_hook_test2 > h.txt && git add h.txt \
  && git -c user.name=t -c user.email=t@t.example commit -q -m "feat: the configured term list stays clean here" ) \
  >"$AIMAIL_ROOT/.out" 2>"$AIMAIL_ROOT/.err"
if [[ $? -eq 0 ]]; then
  PASS=$((PASS+1)); printf '  ✔ commit-msg hook allows a message that refers to the term list without spelling it out\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("sterility_commit_msg_guard.sh refused a genuinely clean message")
fi
# ⛔⛔ THE MODE-BIT INCIDENT (2026-09-24): the commit-msg hook above was first committed at
#   100644 -- git silently skips a non-executable hook when installed via the documented
#   `ln -sf` pattern, so it never actually fired once installed anywhere, despite its own
#   content being correct (a real, working script that just never ran). Caught by an
#   independent gate re-run, not this suite -- because nothing here asserted the TRACKED
#   mode, only ever the file's behavior once already executable on disk. This is the guard
#   against that recurring for any hook, present or future.
STER_MODE_BAD=""
while IFS= read -r hf; do
  mode="$(git -C "$REPO" ls-files -s -- "$hf" 2>/dev/null | awk '{print $1}')"
  [[ "$mode" == "100755" ]] || STER_MODE_BAD="${STER_MODE_BAD:+$STER_MODE_BAD, }$hf ($mode)"
done < <(git -C "$REPO" ls-files hooks/)
if [[ -z "$STER_MODE_BAD" ]]; then
  PASS=$((PASS+1)); printf '  ✔ every tracked file under hooks/ is mode 100755 (a non-executable hook is silently skipped by git)\n'
else
  FAIL=$((FAIL+1)); FAILURES+=("hooks/ mode check: not tracked 100755: $STER_MODE_BAD")
fi

section "placement — pinned / precious / fable headroom / spread / projected, on today's 6-on-one incident"
# ⛔ Pure decision functions over synthetic state (weekly files, ledger rows, park flags, a seat map),
#   the same discipline as the budget_pick_account arms above. The scenario IS 2026-09-22 16:55:
#   six non-pinned seats on one account crossing 80% while another account sits at 8%.
source "$REPO/lib/core.sh"; source "$REPO/lib/budget.sh"; source "$REPO/lib/seatmigrate.sh" 2>/dev/null || true; source "$REPO/lib/placement.sh"
_pl_ledger() { printf '%s\t%s\t%s\tprobe\t\n' "$1" "$2" "$3" >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; }   # <epoch> <acct> <pct>
_pl_fable() { printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "$(( $(date +%s) + 86400*5 ))" > "$AIMAIL_ROOT/state/fable_weekly_$1.tsv"; }
_pl_reset() {
  rm -f "$AIMAIL_ROOT"/state/weekly_pl* "$AIMAIL_ROOT"/state/fable_weekly_pl* "$AIMAIL_ROOT"/state/throttled_pl*
  sed -i '/\tpl[a-z0-9]*\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null || true
  export AIMAIL_FLEET_ACCOUNTS="plwork plr2 plres" AIMAIL_SUPERVISOR=plsup AIMAIL_VICE_SUPERVISOR=plmain AIMAIL_PINNED_SEATS="plsup plmain" \
         AIMAIL_FABLE_SEAT=plfable AIMAIL_PRECIOUS_ACCOUNT=plwork \
         AIMAIL_PLACEMENT_SEATS="plwork:plsup,plmain plr2:s1,s2,s3,s4,s5,plfable plres:"
  local now; now="$(date +%s)"
  # block %: work 91 (over the 90 cap), r2 82 (burning 1%/min: 72 ten minutes ago), research 8 (flat)
  _pl_ledger $((now-600)) plwork 90; _pl_ledger $now plwork 91
  _pl_ledger $((now-600)) plr2 72;   _pl_ledger $now plr2 82
  _pl_ledger $((now-600)) plres 8;   _pl_ledger $now plres 8
  _pick_weekly plwork 40; _pick_weekly plr2 16; _pick_weekly plres 30
  _pl_fable plr2 22; _pl_fable plres 15; _pl_fable plwork 40
}
_plchk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); FAILURES+=("placement: $1 (want=$3 got=$2)"); printf '  ✖ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
_pl_reset
_plchk "fair share = ceil(6 non-pinned / 2 accounts with headroom) = 3 (work is over its block cap, so not counted)" "$(placement_fair_share)" 3
placement_report > "$AIMAIL_ROOT/pl_report.txt" 2>&1; rc=$?
_plchk "the incident reads as an IMBALANCE (report exit 1)" "$rc" 1
_plchk "…and says so" "$(grep -c 'PLACEMENT IMBALANCE' "$AIMAIL_ROOT/pl_report.txt")" 1
_plchk "…r2 is marked OVER SHARE" "$(grep -c 'plr2.*OVER SHARE' "$AIMAIL_ROOT/pl_report.txt")" 1
_plchk "R2+R4: a non-pinned seat's pick is research (not r2: over share; not work: precious + over cap)" "$(placement_pick s1)" "plres"
_plchk "R1: the supervisor is never eligible anywhere but its own account" "$(placement_pick plsup)" "plwork"
_plchk "R1: a move of the vice is REFUSED as pinned" "$(placement_check_move plmain plres | cut -f1)" "REFUSE"
_plchk "R3: fable picks the account whose fable budget is most at risk of expiring (same reset: research 85pt > r2 78pt)" "$(placement_pick plfable)" "plres"
# ⭐ THE 19:27 CORRECTION (project owner): fable goes where its fable-model budget would otherwise EXPIRE UNUSED --
#   remaining points per hour to that account's own weekly reset -- not merely where headroom is largest.
#   Tonight's case: research 72% left, resets in ~106h; r2 73% left, resets in ~154h. Headroom alone says r2; the rule says research.
_pl_fable_at() { printf '%s\t%s\t%s\n' "$(date +%s)" "$2" "$(( $(date +%s) + $3 * 3600 ))" > "$AIMAIL_ROOT/state/fable_weekly_$1.tsv"; }
#   Roster for these three arms: r2 and research each carry ONE non-pinned seat, so the spread rule (R4) is silent and
#   only the fable rule decides (in the incident roster r2 is over its share, which would decide first).
_pl_roster_save="$AIMAIL_PLACEMENT_SEATS"; export AIMAIL_PLACEMENT_SEATS="plwork:plsup,plmain plr2:s1 plres:s2"
_pl_fable_at plres 28 106; _pl_fable_at plr2 27 154; _pl_fable_at plwork 40 120
_plchk "R3 expiry: 72pt left resetting in 106h (research) outranks 73pt left resetting in 154h (r2)" "$(placement_pick plfable)" "plres"
_plchk "…the reason names the expiry risk" "$(placement_eligible plfable | head -1 | grep -c 'at risk of expiring')" 1
_pl_fable_at plres 28 154; _pl_fable_at plr2 27 106
_plchk "R3 expiry falsification: swap the resets and the pick swaps to r2" "$(placement_pick plfable)" "plr2"
# ⛔ SENTINEL COLLISION (found by the arms above): work's block reads 91 against a 90 cap -> headroom -1, which the first
#   cut also used for "unmeasured", so the over-cap precious account counted as headroom and the fair share fell to 1.
_plchk "a block reading ONE point over its cap is OVER CAP, not unmeasured: work has no headroom" "$(_pl_has_headroom plwork && echo y || echo n)" "n"
_plchk "…and it reads as MEASURED (a real reading, not a missing one)" "$(_pl_measured plwork && echo y || echo n)" "y"
_plchk "…so the fair share over this roster is ceil(3/2) = 2, not 1" "$(placement_fair_share plfable)" 2
export AIMAIL_PLACEMENT_SEATS="$_pl_roster_save"; unset _pl_roster_save
_pl_fable plr2 22; _pl_fable plres 15; _pl_fable plwork 40
_pl_fable plres 100
_plchk "R3 falsification: with no fable headroom on research, fable is NOT placed there" "$(placement_pick plfable 2>/dev/null || echo none)" "none"
_pl_reset
# R2: give work real headroom -- a non-pinned seat still goes to research first
sed -i '/\tplwork\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv"; _pl_ledger $(( $(date +%s)-600 )) plwork 39; _pl_ledger $(date +%s) plwork 40
_plchk "R2: with work under cap, a non-pinned seat is STILL not placed on work while research has headroom" "$(placement_pick s1)" "plres"
_plchk "R2: a move onto work is REFUSED naming the precious rule" "$(placement_check_move s1 plwork | grep -c precious)" 1
# R2 overflow: park research and r2 -> work carries the overflow
printf 'ACCOUNT\tplres\n' > "$(THROTTLE_FLAG plres)"; printf 'ACCOUNT\tplr2\n' > "$(THROTTLE_FLAG plr2)"
_plchk "R2 overflow: when every other account is parked, work IS eligible (check_move OK)" "$(placement_check_move s1 plwork | cut -f1)" "OK"
_pl_reset
# R4: research already at its share (3) -> a 4th is refused; fair share recomputed with work under cap
export AIMAIL_PLACEMENT_SEATS="plwork:plsup,plmain plr2:s1,s2,s3 plres:s4,s5,plfable"
sed -i '/\tplwork\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv"; _pl_ledger $(( $(date +%s)-600 )) plwork 39; _pl_ledger $(date +%s) plwork 40
_plchk "R4: share with 3 accounts under cap = ceil(6/3) = 2" "$(placement_fair_share)" 2
_plchk "R4: a move onto an account already at/over its share is REFUSED (spread)" "$(placement_check_move s7 plres | grep -c 'spread rule')" 1
# ⛔ SEATS COME FROM THE REGISTRY (2026-09-23 02:01: the placement table showed work with 0 seats while the supervisor and
#   the vice were confirmed there -- neither runs a poller, so the live-process grouping never saw them)
_pl_saved_roster="$AIMAIL_PLACEMENT_SEATS"; unset AIMAIL_PLACEMENT_SEATS
mkdir -p "$(SEAT_RECORD_DIR)"; for _s in plsup plmain; do printf 'seat\t%s\naccount\tplwork\nsession_id\tx\n' "$_s" > "$(SEAT_RECORD_DIR)/$_s"; done
printf 'seat\ts9\naccount\tplres\nsession_id\ty\n' > "$(SEAT_RECORD_DIR)/s9"
_plchk "confirmed seats with NO live process are counted on their account (2 on work)" "$(_pl_seats_by_account | awk -F'\t' '$1=="plwork"{n=split($2,w," "); print n}')" 2
_plchk "…and the single confirmed seat on research is counted too" "$(_pl_seats_by_account | awk -F'\t' '$1=="plres"{print $2}')" "s9"
rm -f "$(SEAT_RECORD_DIR)/plsup" "$(SEAT_RECORD_DIR)/plmain" "$(SEAT_RECORD_DIR)/s9"; export AIMAIL_PLACEMENT_SEATS="$_pl_saved_roster"; unset _pl_saved_roster _s
_pl_reset
# R5: two candidates with equal headroom, different burn -> the slower one lasts longer and wins
export AIMAIL_PLACEMENT_SEATS="plwork:plsup,plmain plr2:s1 plres:s2"
sed -i '/\tpl\(r2\|res\)\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv"
_pl_ledger $(( $(date +%s)-600 )) plr2 30;  _pl_ledger $(date +%s) plr2 40    # 1.0 %/min -> 50 min to cap
_pl_ledger $(( $(date +%s)-600 )) plres 38; _pl_ledger $(date +%s) plres 40   # 0.2 %/min -> 250 min to cap
_pick_weekly plr2 30; _pick_weekly plres 30
_plchk "R5: equal headroom, research burns slower -> research picked (projected time-to-cap)" "$(placement_pick s9)" "plres"
_plchk "R4 with an un-rostered seat: the seat being placed counts toward the total (share ceil(3/2)=2, not 1)" "$(placement_fair_share s9)" 2
_plchk "unmeasured target: check_move is OK with a WARNING, not a refusal (unmeasured is not over cap)" "$(rm -f "$AIMAIL_ROOT/state/weekly_plres.tsv"; placement_check_move s9 plres | cut -f1)" "OK"
_plchk "…and says so" "$(placement_check_move s9 plres | grep -c 'no measured readings')" 1
_pick_weekly plres 30
_plchk "R5 falsification: swap the burns and r2 is picked" "$( sed -i '/\tpl\(r2\|res\)\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv"; _pl_ledger $(( $(date +%s)-600 )) plr2 38; _pl_ledger $(date +%s) plr2 40; _pl_ledger $(( $(date +%s)-600 )) plres 30; _pl_ledger $(date +%s) plres 40; placement_pick s9 )" "plr2"
# the CLI verb
accepts "aimail placement (report) runs"          -- placement
accepts "aimail placement <seat> (eligible list) runs" -- placement s9
_pl_reset; unset AIMAIL_PLACEMENT_SEATS AIMAIL_PRECIOUS_ACCOUNT AIMAIL_FABLE_SEAT AIMAIL_PINNED_SEATS AIMAIL_SUPERVISOR AIMAIL_VICE_SUPERVISOR
export AIMAIL_FLEET_ACCOUNTS=""


section "act — announce-then-do, one seat per tick, never mid-turn, never pinned, cancel, defer, abandon, failed"
source "$REPO/lib/core.sh"; source "$REPO/lib/budget.sh"; source "$REPO/lib/fleet.sh"; source "$REPO/lib/balance.sh"; source "$REPO/lib/placement.sh"; source "$REPO/lib/act.sh"
ACTFAKE="$AIMAIL_ROOT/act_fake_migrate.sh"; ACTCALLS="$AIMAIL_ROOT/act_calls"
cat > "$ACTFAKE" <<'FM'
#!/usr/bin/env bash
echo "$1 $2" >> "${ACT_CALLS:?}"; [[ -f "${ACT_FAIL:-/nonexistent}" ]] && { echo "REFUSED: fake"; exit 3; }; echo "migrated $1 -> $2"; exit 0
FM
chmod +x "$ACTFAKE"
_act_reset() {
  rm -rf "$AIMAIL_ROOT/state/balance"; rm -f "$ACTCALLS" "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null
  rm -f "$AIMAIL_ROOT"/state/weekly_ac* "$AIMAIL_ROOT"/state/fable_weekly_ac* "$AIMAIL_ROOT"/state/throttled_ac*
  sed -i '/\tac[a-z0-9]*\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null || true
  export AIMAIL_FLEET_ACCOUNTS="acwork acr2 acres" AIMAIL_SUPERVISOR=acsup AIMAIL_VICE_SUPERVISOR=acmain AIMAIL_PINNED_SEATS="acsup acmain" AIMAIL_HUMAN_ALERT_SEAT=acsup \
         AIMAIL_PRECIOUS_ACCOUNT=acwork AIMAIL_PLACEMENT_SEATS="acwork:acsup,acmain acr2:acs1,acs2,acs3 acres:" AIMAIL_FABLE_SEAT=acfable \
         AIMAIL_BALANCE_ACT=1 AIMAIL_BALANCE_ACT_LEVEL=80 AIMAIL_BALANCE_ACT_DELAY_MIN=10 AIMAIL_BALANCE_MIGRATE_CMD="$ACTFAKE" ACT_CALLS="$ACTCALLS" \
         AIMAIL_BALANCE_LIVE_STATE="acs1=mid acs2=idle acs3=between acsup=idle acmain=idle"
  unset AIMAIL_NOW ACT_FAIL
  local now; now="$(date +%s)"
  printf '%s\t%s\t%s\tprobe\t%s\n' $((now-600)) acwork 40 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; printf '%s\t%s\t%s\tprobe\t%s\n' $now acwork 41 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
  printf '%s\t%s\t%s\tprobe\t%s\n' $((now-600)) acr2 75 $((now+3000))   >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; printf '%s\t%s\t%s\tprobe\t%s\n' $now acr2 84 $((now+3000))   >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
  printf '%s\t%s\t%s\tprobe\t%s\n' $((now-600)) acres 8 $((now+3000))   >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; printf '%s\t%s\t%s\tprobe\t%s\n' $now acres 8 $((now+3000))    >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
  _pick_weekly acwork 40 $((now+86400*3)); _pick_weekly acr2 30 $((now+86400*3)); _pick_weekly acres 12 $((now+86400*3))
}
_acchk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); FAILURES+=("act: $1 (want=$3 got=$2)"); printf '  ✖ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
_acmails() { ls "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null | wc -l | tr -d ' '; }
"$AIMAIL" seat add acsup "act test supervisor" >/dev/null 2>&1 || true
_act_reset; export AIMAIL_BALANCE_ACT=0
balance_act >/dev/null 2>&1
_acchk "ACT=0: nothing happens (no intent, no mail, no call)" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$(_acmails)|$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)" "none|0|nocall"
_act_reset
out="$(balance_act 2>&1)"
_acchk "ACT=1, r2 at 84% >= 80: an intent is written" "$([[ -s "$(ACT_INTENT)" ]] && echo yes || echo no)" yes
_acchk "…the candidate is the IDLE seat (acs2), not the mid-turn (acs1) nor the between (acs3)" "$(cut -f2 "$(ACT_INTENT)")" acs2
_acchk "…its target is research (placement: not work = precious, not r2 = source)" "$(cut -f4 "$(ACT_INTENT)")" acres
_acchk "…due = now + 10 min" "$(( ($(cut -f5 "$(ACT_INTENT)") - $(cut -f1 "$(ACT_INTENT)")) / 60 ))" 10
_acchk "…ONE announcement mail to the supervisor" "$(_acmails)" 1
_acchk "…that says WILL MOVE, names the seat and the target" "$(grep -l 'WILL MOVE acs2 from acr2 to acres' "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null | wc -l | tr -d ' ')" 1
_acchk "…nothing executed yet" "$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)" nocall
_acchk "…logged ANNOUNCED" "$(grep -c $'\tANNOUNCED\t' "$(ACT_LOG)")" 1
balance_act >/dev/null 2>&1
_acchk "a second tick before the due time: waits (no second intent, no second mail, no call)" "$(_acmails)|$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)" "1|nocall"
export AIMAIL_NOW=$(( $(cut -f5 "$(ACT_INTENT)") + 1 ))
export AIMAIL_BALANCE_LIVE_STATE="acs1=mid acs2=mid acs3=between acsup=idle acmain=idle"
balance_act >/dev/null 2>&1
_acchk "due, but the seat went MID-TURN: deferred, intent kept, no call" "$([[ -s "$(ACT_INTENT)" ]] && echo kept || echo gone)|$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)|$(grep -c $'\tDEFERRED\t' "$(ACT_LOG)")" "kept|nocall|1"
export AIMAIL_BALANCE_LIVE_STATE="acs1=mid acs2=idle acs3=between acsup=idle acmain=idle"
balance_act >/dev/null 2>&1
_acchk "due and idle again: the move EXECUTES through the migrate seam with 'seat target'" "$(cat "$ACTCALLS" 2>/dev/null)" "acs2 acres"
_acchk "…intent cleared, lock released" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$([[ -f "$(ACT_LOCK)" ]] && echo lock || echo nolock)" "none|nolock"
_acchk "…DONE logged and a result mail sent (announce + done = 2 mails)" "$(grep -c $'\tDONE\t' "$(ACT_LOG)")|$(_acmails)" "1|2"
_acchk "…the result mail says moved" "$(grep -l 'BALANCER: moved acs2 from acr2 to acres' "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null | wc -l | tr -d ' ')" 1
# cancel
_act_reset; balance_act >/dev/null 2>&1
out="$("$AIMAIL" budget act cancel 2>&1)"; rc=$?
_acchk "cancel without --why is REFUSED" "$rc" 3
AIMAIL_BALANCE_ACT=1 "$AIMAIL" budget act cancel --why "the owner 19:20: hold r2 tonight" >/dev/null 2>&1
export AIMAIL_NOW=$(( $(cut -f5 "$(ACT_INTENT)") + 1 )); balance_act >/dev/null 2>&1
_acchk "a cancelled intent is dropped at the next tick, nothing executed, CANCELLED logged with the reason" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)|$(grep -c $'\tCANCELLED\tacs2 acr2->acres: the owner 19:20' "$(ACT_LOG)")" "none|nocall|1"
# abandon: placement refuses at execution time (research parked meanwhile)
_act_reset; balance_act >/dev/null 2>&1; printf 'ACCOUNT\tacres\n' > "$(THROTTLE_FLAG acres)"
export AIMAIL_NOW=$(( $(cut -f5 "$(ACT_INTENT)") + 1 )); balance_act >/dev/null 2>&1
_acchk "the target got parked before the due time: ABANDONED, nothing executed, mailed" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$([[ -f "$ACTCALLS" ]] && echo called || echo nocall)|$(grep -c $'\tABANDONED\t' "$(ACT_LOG)")|$(grep -l 'ABANDONED' "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null | wc -l | tr -d ' ')" "none|nocall|1|1"
# failed migrate
_act_reset; balance_act >/dev/null 2>&1; export ACT_FAIL="$AIMAIL_ROOT/act_fail"; : > "$ACT_FAIL"
export AIMAIL_NOW=$(( $(cut -f5 "$(ACT_INTENT)") + 1 )); balance_act >/dev/null 2>&1
_acchk "the migrate refuses (rc 3): FAILED logged, a human-must-look mail, intent cleared, lock released" "$(grep -c $'\tFAILED\tacs2 acr2->acres rc=3' "$(ACT_LOG)")|$(grep -l 'FAILED (rc=3)' "$AIMAIL_ROOT"/mail/acsup/*.md 2>/dev/null | wc -l | tr -d ' ')|$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$([[ -f "$(ACT_LOCK)" ]] && echo lock || echo nolock)" "1|1|none|nolock"
# never pinned, never mid-turn: work at 90% holds only pinned seats -> NO-CANDIDATE, no intent
_act_reset; export AIMAIL_PLACEMENT_SEATS="acwork:acsup,acmain acr2:acs1 acres:acs2"   # r2 within its fair share, so the only trigger is work's 90%
sed -i '/\tacwork\t/d;/\tacr2\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv"
now=$(date +%s); printf '%s\t%s\t%s\tprobe\t%s\n' $((now-600)) acwork 88 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; printf '%s\t%s\t%s\tprobe\t%s\n' $now acwork 90 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
printf '%s\t%s\t%s\tprobe\t%s\n' $((now-600)) acr2 20 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; printf '%s\t%s\t%s\tprobe\t%s\n' $now acr2 20 $((now+3000)) >> "$AIMAIL_ROOT/state/budget_ledger.tsv"
balance_act >/dev/null 2>&1
_acchk "R1: the precious account at 90% holds only pinned seats -> NO-CANDIDATE, no intent, no mail" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$(grep -c $'\tNO-CANDIDATE\tacwork' "$(ACT_LOG)")|$(_acmails)" "none|1|0"
_act_reset; export AIMAIL_BALANCE_LIVE_STATE="acs1=mid acs2=mid acs3=mid acsup=idle acmain=idle"; balance_act >/dev/null 2>&1
_acchk "every seat on the hot account is mid-turn -> NO-CANDIDATE (never a mid-turn move)" "$([[ -f "$(ACT_INTENT)" ]] && echo intent || echo none)|$(grep -c $'\tNO-CANDIDATE\tacr2' "$(ACT_LOG)")" "none|1"
unset AIMAIL_NOW ACT_FAIL AIMAIL_BALANCE_ACT AIMAIL_BALANCE_ACT_LEVEL AIMAIL_BALANCE_ACT_DELAY_MIN AIMAIL_BALANCE_MIGRATE_CMD ACT_CALLS AIMAIL_BALANCE_LIVE_STATE AIMAIL_FLEET_ACCOUNTS AIMAIL_SUPERVISOR AIMAIL_VICE_SUPERVISOR AIMAIL_PINNED_SEATS AIMAIL_HUMAN_ALERT_SEAT AIMAIL_PRECIOUS_ACCOUNT AIMAIL_PLACEMENT_SEATS AIMAIL_FABLE_SEAT

section "warnings — 50/80 crossings on block / weekly / fable-model, one mail per window, projected cap-hit"
source "$REPO/lib/core.sh"; source "$REPO/lib/budget.sh"; source "$REPO/lib/placement.sh"; source "$REPO/lib/warnings.sh"
_wn_reset() {
  rm -rf "$AIMAIL_ROOT/state/warnings"; rm -f "$AIMAIL_ROOT"/state/weekly_wn* "$AIMAIL_ROOT"/state/fable_weekly_wn* "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null
  sed -i '/\twn[a-z0-9]*\t/d' "$AIMAIL_ROOT/state/budget_ledger.tsv" 2>/dev/null || true
  export AIMAIL_FLEET_ACCOUNTS="wna wnb" AIMAIL_SUPERVISOR=wnsup AIMAIL_HUMAN_ALERT_SEAT=wnsup AIMAIL_WARN_LEVELS="50 80" AIMAIL_PLACEMENT_SEATS="wna:wnsup wnb:"
}
_wn_row() { printf '%s\t%s\t%s\tprobe\t%s\n' "$1" "$2" "$3" "$4" >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; }   # <epoch> <acct> <pct> <reset>
_wnchk() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); FAILURES+=("warnings: $1 (want=$3 got=$2)"); printf '  ✖ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
"$AIMAIL" seat add wnsup "warnings test supervisor" >/dev/null 2>&1 || true
_wn_reset; NOW=$(date +%s); RESET=$((NOW+3000))
_wn_row $((NOW-600)) wna 48 $RESET; _wn_row $NOW wna 52 $RESET     # block crossed 50 (burn 0.4 %/min -> cap 90 in ~95 min > 50 min to reset: no projection)
_pick_weekly wna 83 $((NOW+86400*3))                                # weekly crossed 50 AND 80
printf '%s\t%s\t%s\n' "$NOW" 20 $((NOW+86400*3)) > "$AIMAIL_ROOT/state/fable_weekly_wna.tsv"   # fable under 50
_wn_row $NOW wnb 10 $RESET; _pick_weekly wnb 10 $((NOW+86400*3))
out="$(budget_warnings)"; rc=$?
_wnchk "tick exits 0" "$rc" 0
_wnchk "block 50 crossing is NEW" "$(grep -cE '^wna +block +52 +50 .*NEW' <<<"$out")" 1
_wnchk "weekly 50 AND 80 crossings are both NEW (one line per level)" "$(grep -cE '^wna +weekly +83 +(50|80) .*NEW' <<<"$out")" 2
_wnchk "fable at 20 crosses nothing" "$(grep -cE '^wna +fable +20 +- ' <<<"$out")" 1
_wnchk "the quiet account crosses nothing" "$(grep -cE '^wnb .*NEW' <<<"$out")" 0
_wnchk "no projected warning: cap is reached AFTER the reset at this burn" "$(grep -c projected <<<"$out")" 0
_wnchk "exactly ONE mail to the supervisor for the whole tick" "$(ls "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)" 1
_wnchk "…subject names the first crossing" "$(grep -l 'BUDGET CROSSING' "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)" 1
_wnchk "…body carries the placement report" "$(grep -c 'Placement now' "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null)" 1
_wnchk "three markers written (block50, weekly50, weekly80)" "$(ls "$AIMAIL_ROOT/state/warnings" | grep -vc 'warnings.log')" 3
out="$(budget_warnings)"
_wnchk "second tick, same readings: everything SEEN, nothing NEW" "$(grep -c NEW <<<"$out")" 0
_wnchk "…and no second mail" "$(ls "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)" 1
_wn_row $((NOW+1)) wna 55 $((RESET+18000))     # a NEW block window (the reset moved): 50 crosses again
out="$(budget_warnings)"
_wnchk "a new window re-arms the 50 crossing (NEW again)" "$(grep -cE '^wna +block +55 +50 .*NEW' <<<"$out")" 1
_wnchk "…the weekly (same window) stays SEEN" "$(grep -cE '^wna +weekly .*NEW' <<<"$out")" 0
# ⛔ WINDOW-ID JITTER (live cron, 2026-09-24): the r2 80% crossing mailed twice, at 19:16
#   (window 1790295600) and 19:26 (window 1790295599) -- the SAME block, the reported reset
#   one second apart between probes. Unlike the genuine new-block case just above (reset
#   moved by 18000 s), a 1 s jitter on what is really the same window must NOT re-arm.
mail_before_jitter="$(ls "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)"
_wn_row $((NOW+2)) wna 56 $((RESET+18000-1))     # same window as the tick above, reset off by 1s
out="$(budget_warnings)"
_wnchk "a 1s reset jitter on the same window does NOT re-arm (SEEN, not NEW)" "$(grep -cE '^wna +block +56 +50 .*NEW' <<<"$out")" 0
_wnchk "…and mails nothing new" "$(ls "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)" "$mail_before_jitter"
# ⭐ THE LITERAL INCIDENT, pinned directly (code-review's explicit ask, 2026-09-24): an
#   earlier version of this fix floor-rounded to a 60s grid, which does NOT dedupe these
#   two exact values -- 1790295600 is itself an exact multiple of 60 and floors to itself,
#   while 1790295599, one second earlier, floors into the PREVIOUS bucket. Pinned as its
#   own case, independent of $(date +%s), so it can never pass by wall-clock luck.
_wnmk="$(mktemp -u)"
printf '%s\t%s\t%s\n' "$(date +%s)" 80 1790295600 > "$_wnmk"
_warn_is_same_window "$_wnmk" 1790295599; _wnrc=$?
_wnchk "the literal incident pair (recorded 1790295600, new 1790295599) IS the same window" "$_wnrc" 0
_warn_is_same_window "$_wnmk" 1790295600; _wnrc=$?
_wnchk "…the exact recorded value trivially matches itself" "$_wnrc" 0
_warn_is_same_window "$_wnmk" $((1790295600+18000)); _wnrc=$?
_wnchk "…while a genuinely different window (18000s later) is correctly NOT the same" "$_wnrc" 1
rm -f "$_wnmk"
_wn_reset; NOW=$(date +%s); RESET=$((NOW+3000))
_wn_row $((NOW-600)) wna 60 $RESET; _wn_row $NOW wna 70 $RESET     # 1 %/min, headroom 20 -> cap in 20 min < 50 min to reset
_pick_weekly wna 10 $((NOW+86400*3))
out="$(budget_warnings --dry-run)"
_wnchk "PROJECTED: 1 %/min with 20 points of headroom hits the cap in ~20 min, before the reset -> NEW" "$(grep -cE '^wna +projected +~(19|20)m +cap .*NEW' <<<"$out")" 1
_wnchk "dry-run writes NO markers" "$(ls "$AIMAIL_ROOT/state/warnings" 2>/dev/null | grep -vc 'warnings.log')" 0
_wnchk "dry-run mails nothing" "$(ls "$AIMAIL_ROOT"/mail/wnsup/*.md 2>/dev/null | wc -l)" 0
_wnchk "…and says so" "$(grep -c 'dry-run: 2 new crossing' <<<"$out")" 1
# ⭐ WEEKLY projection (2026-09-22 23:09 case): 84% weekly, rising 1.2 pt/h against a 98 cap, reset 4 days out -> caps in ~11 h,
#   about 3 days BEFORE the reset -> a NEW wproj line that names the free reset. The block gauge stays quiet.
_wn_reset; NOW=$(date +%s)
_wn_wrow() { printf '%s\t%s\t%s\tweekly\t%s\n' "$1" "$2" "$3" "$4" >> "$AIMAIL_ROOT/state/budget_ledger.tsv"; }
AIMAIL_WEEKLY_CAP_wna=98 _pick_weekly wna 84 $((NOW+96*3600)); _wn_wrow $((NOW-3*3600)) wna 80.4 $((NOW+96*3600)); _wn_wrow $((NOW-3600)) wna 82.8 $((NOW+96*3600)); _wn_wrow $NOW wna 84 $((NOW+96*3600))
_wn_row $NOW wna 10 $((NOW+3000)); _pick_weekly wnb 10 $((NOW+86400*3))
out="$(AIMAIL_WEEKLY_CAP_wna=98 budget_warnings --dry-run)"
_wnchk "WEEKLY PROJECTED: 84% at 1.2 pt/h against a 98 cap caps in ~11 h, before a reset 96 h out -> NEW wproj line" "$(grep -cE '^wna +wproj +~1[01]h +cap .*NEW' <<<"$out")" 1
# the crossing TEXT goes to the mail and to warnings.log (a dry run still logs it), not to the table on stdout
_wnchk "…the crossing text names the free reset" "$(grep -c 'consider the account.s free reset' "$AIMAIL_ROOT/state/warnings/warnings.log")" 1
_wnchk "…and says how many days before the reset (3)" "$(grep -cE 'about 3 day\(s\) BEFORE its reset' "$AIMAIL_ROOT/state/warnings/warnings.log")" 1
_pick_weekly wna 84 $((NOW+6*3600))                                  # reset in 6 h: the cap comes AFTER the reset -> no projection
out="$(AIMAIL_WEEKLY_CAP_wna=98 budget_warnings --dry-run)"
_wnchk "no weekly projection when the reset comes first" "$(grep -c wproj <<<"$out")" 0
# ⛔ QUANTIZATION NOISE (live cron 2026-09-23 02:00): two rows 300 s apart, one integer point up = 12 pt/h -> "caps in 0 h". Never project from that.
_wn_reset; NOW=$(date +%s); rm -f "$AIMAIL_ROOT/state/warnings/wna_wprojected_"* 2>/dev/null
AIMAIL_WEEKLY_CAP_wna=98 _pick_weekly wna 87 $((NOW+96*3600)); _wn_wrow $((NOW-300)) wna 86 $((NOW+96*3600)); _wn_wrow $NOW wna 87 $((NOW+96*3600))
_wn_row $NOW wna 10 $((NOW+3000)); _pick_weekly wnb 10 $((NOW+86400*3))
out="$(AIMAIL_WEEKLY_CAP_wna=98 budget_warnings --dry-run)"
_wnchk "two weekly rows 300 s apart, one point up -> NO projection (below the 1 h / 2 pt baseline floor)" "$(grep -c wproj <<<"$out")" 0
_wn_wrow $((NOW-2*3600)) wna 85 $((NOW+96*3600))   # a real 2 h baseline: 85 -> 87 = 1 pt/h -> caps in ~11 h, 4 days early -> projects
out="$(AIMAIL_WEEKLY_CAP_wna=98 budget_warnings --dry-run)"
_wnchk "…the same rows plus a 2 h-old baseline row -> the projection is back (rate 1.0 pt/h, ~11 h)" "$(grep -cE '^wna +wproj +~1[01]h ' <<<"$out")" 1
# the block burn has the same floor: two probes 300 s apart one point up is NOT a burn of 0.2 %/min
_wn_reset; NOW=$(date +%s); RESET=$((NOW+3000))
_wn_row $((NOW-300)) wna 88 $RESET; _wn_row $NOW wna 89 $RESET; _pick_weekly wna 10 $((NOW+86400*3))
out="$(budget_warnings --dry-run)"
_wnchk "two block probes 300 s apart, one point up -> NO block projection (burn reads unknown, not 12 %/h)" "$(grep -c '^wna +projected' <<<"$out")" 0
unset AIMAIL_FLEET_ACCOUNTS AIMAIL_SUPERVISOR AIMAIL_HUMAN_ALERT_SEAT AIMAIL_WARN_LEVELS AIMAIL_PLACEMENT_SEATS

section "ask ledger + aimail land — tests/ask_ledger.sh (standalone script, folded in)"
# ⭐ tests/ask_ledger.sh drives the REAL bin/aimail + bin/gateclaim.sh in its OWN
#   throwaway root (its own mktemp -d, its own AIMAIL_ROOT export) -- a
#   separate bash process, so it never touches this suite's own $AIMAIL_ROOT.
#   Run it as a subprocess and fold its own PASS/FAIL count into this suite's
#   totals: one script stays the one source of truth for what it asserts,
#   rather than re-deriving its arms here.
ASKL_OUT="$(bash "$REPO/tests/ask_ledger.sh" 2>&1)"; ASKL_RC=$?
printf '%s\n' "$ASKL_OUT" | sed 's/^/  /'
_askl_nums="$(printf '%s\n' "$ASKL_OUT" | grep -oE 'SUMMARY: [0-9]+ passed, [0-9]+ failed' | grep -oE '[0-9]+')"
ASKL_PASS="$(sed -n '1p' <<<"$_askl_nums")"
ASKL_FAIL="$(sed -n '2p' <<<"$_askl_nums")"
if [[ -n "$ASKL_PASS" && -n "$ASKL_FAIL" ]]; then
  PASS=$((PASS+ASKL_PASS)); FAIL=$((FAIL+ASKL_FAIL))
  (( ASKL_FAIL == 0 && ASKL_RC == 0 )) || FAILURES+=("tests/ask_ledger.sh reported $ASKL_FAIL failure(s), rc=$ASKL_RC (see output above)")
else
  FAIL=$((FAIL+1)); FAILURES+=("tests/ask_ledger.sh produced no parseable SUMMARY line (rc=$ASKL_RC)")
fi

section "drop-prevention guards — tests/drop_guards.sh (standalone script, folded in)"
# Prompt ledger + Stop gate, parking needs a date or trigger, work mail cites an ask id, the
# open-asks digest. Its own throwaway root (separate bash process); counts folded in like the
# ask ledger's above.
DG_OUT="$(bash "$REPO/tests/drop_guards.sh" 2>&1)"; DG_RC=$?
printf '%s\n' "$DG_OUT" | sed 's/^/  /'
_dg_nums="$(printf '%s\n' "$DG_OUT" | grep -oE 'SUMMARY: [0-9]+ passed, [0-9]+ failed' | grep -oE '[0-9]+')"
DG_PASS="$(sed -n '1p' <<<"$_dg_nums")"
DG_FAIL="$(sed -n '2p' <<<"$_dg_nums")"
if [[ -n "$DG_PASS" && -n "$DG_FAIL" ]]; then
  PASS=$((PASS+DG_PASS)); FAIL=$((FAIL+DG_FAIL))
  (( DG_FAIL == 0 && DG_RC == 0 )) || FAILURES+=("tests/drop_guards.sh reported $DG_FAIL failure(s), rc=$DG_RC (see output above)")
else
  FAIL=$((FAIL+1)); FAILURES+=("tests/drop_guards.sh produced no parseable SUMMARY line (rc=$DG_RC)")
fi

section "pre-push owner gate — tests/push_guard.sh (standalone script, folded in)"
# Drives the real hooks/sterility_push_guard.sh in its own throwaway git repo. The owner's
# variable is ALLOW_PUSH=1, the same one every other repo's push lock uses.
PG_OUT="$(bash "$REPO/tests/push_guard.sh" 2>&1)"; PG_RC=$?
printf '%s\n' "$PG_OUT" | sed 's/^/  /'
_pg_nums="$(printf '%s\n' "$PG_OUT" | grep -oE 'push_guard: [0-9]+ passed, [0-9]+ failed' | grep -oE '[0-9]+')"
PG_PASS="$(sed -n '1p' <<<"$_pg_nums")"
PG_FAIL="$(sed -n '2p' <<<"$_pg_nums")"
if [[ -n "$PG_PASS" && -n "$PG_FAIL" ]]; then
  PASS=$((PASS+PG_PASS)); FAIL=$((FAIL+PG_FAIL))
  (( PG_FAIL == 0 && PG_RC == 0 )) || FAILURES+=("tests/push_guard.sh reported $PG_FAIL failure(s), rc=$PG_RC (see output above)")
else
  FAIL=$((FAIL+1)); FAILURES+=("tests/push_guard.sh produced no summary line (rc=$PG_RC)")
fi

section "branch review — tests/review.sh (standalone script, folded in)"
# Drives the real bin/aimail review commands and the two enforcement scripts on a synthetic repo.
RV_OUT="$(bash "$REPO/tests/review.sh" 2>&1)"; RV_RC=$?
printf '%s\n' "$RV_OUT" | sed 's/^/  /'
_rv_nums="$(printf '%s\n' "$RV_OUT" | grep -oE 'review: [0-9]+ passed, [0-9]+ failed' | grep -oE '[0-9]+')"
RV_PASS="$(sed -n '1p' <<<"$_rv_nums")"
RV_FAIL="$(sed -n '2p' <<<"$_rv_nums")"
if [[ -n "$RV_PASS" && -n "$RV_FAIL" ]]; then
  PASS=$((PASS+RV_PASS)); FAIL=$((FAIL+RV_FAIL))
  (( RV_FAIL == 0 && RV_RC == 0 )) || FAILURES+=("tests/review.sh reported $RV_FAIL failure(s), rc=$RV_RC (see output above)")
else
  FAIL=$((FAIL+1)); FAILURES+=("tests/review.sh produced no summary line (rc=$RV_RC)")
fi

section "doctor"
# doctor checks the real tree's git hooks, which the throwaway copy $AIMAIL points at does not have
AIMAIL="$REPO/bin/aimail" accepts "doctor runs"  -- doctor

# ══════════════════════════════════════════════════════════════════════════════
TOTAL=$((PASS+FAIL))
echo; printf '%.0s─' {1..60}; echo
printf '\n%s passed, %s failed, %s total\n' "$PASS" "$FAIL" "$TOTAL"
if (( FAIL )); then printf '\nFAILURES:\n'; printf '  • %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
