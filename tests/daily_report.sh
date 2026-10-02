#!/usr/bin/env bash
# tests/daily_report.sh — `aimail budget report`: the daily cost-per-task report. Driven through the
# real bin/aimail in a throwaway state root. The ccusage command is a fixture script (AIMAIL_CCUSAGE_BIN)
# that prints canned JSON and records how it was called, so the real tool is never run. The ask ledger is
# a fixture file. Every arm runs under three different time zones, with fixture times built in the SAME
# zone, so the report's notion of "the local date" is proven independent of the machine's zone.
# Runs standalone (`bash tests/daily_report.sh`) and inside tests/run.sh.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AIMAIL_ROOT="$T/root" AIMAIL_CONFIG="$T/aimail.conf"
# the operator's shell is not part of the fixture: drop every inherited AIMAIL_* knob first
# shellcheck source=./lib_env.sh
source "$REPO/tests/lib_env.sh"; test_env_sanitize
export AIMAIL_STERILITY_TERMS="" AIMAIL_SEND_IDENTITY_CHECK=0 AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AIMAIL_SUPERVISOR AIMAIL_FLEET_ACCOUNTS AIMAIL_CCUSAGE_BIN
mkdir -p "$AIMAIL_ROOT" "$T/cfg/alpha" "$T/cfg/beta"; printf 'AIMAIL_ROOT="%s"\n' "$AIMAIL_ROOT" > "$AIMAIL_CONFIG"
export AIMAIL_ACCOUNT_POOL="alpha beta"
export AIMAIL_ACCOUNT_DIR_alpha="$T/cfg/alpha" AIMAIL_ACCOUNT_DIR_beta="$T/cfg/beta"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  ✖ %s (expected %s, got %s)\n' "$1" "$3" "$2"; fi; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
"$AIMAIL" seat add sup "supervisor (fixture)" >/dev/null 2>&1

# the ccusage fixture: records its arguments and the config dirs it was given, prints $T/daily.json,
# or fails when $T/cc_fail exists
cat > "$T/cc.sh" <<EOS
#!/usr/bin/env bash
echo "ARGS: \$*" >> "$T/cc.log"
echo "DIRS: \${CLAUDE_CONFIG_DIR:-unset}" >> "$T/cc.log"
[[ -e "$T/cc_fail" ]] && exit 1
cat "$T/daily.json"
EOS
chmod +x "$T/cc.sh"; export AIMAIL_CCUSAGE_BIN="$T/cc.sh"

# ep <YYYY-MM-DD> <HH:MM:SS> -> the epoch of that LOCAL time in the current zone
ep() { date -d "$1 $2" +%s; }
# ledger_row <id> <state> <done_epoch>  (21 columns, tab separated)
ledger_row() {
  printf '%s\t%s\tsup\task %s\tnext\ttrue\t5\t%s\t%s\tsup\ttxt\tev\t%s\tout\t0\t0\t\t\t0\t\t\n' "$1" "$(ep 2026-09-01 09:00:00)" "$1" "$2" "$(ep 2026-09-01 09:00:00)" "$3"
}

run_zone() {
  local zone="$1"; export TZ="$zone"
  section "zone $zone"
  mkdir -p "$AIMAIL_ROOT/state"; : > "$T/cc.log"; rm -f "$T/cc_fail"
  { printf 'id\tasked_at\towner\task\tnext\tcheck\trank\tstate\tlast_touch\ttouched_by\tstate_text\tevidence\tdone_at\tdone_output\tstale_mailed_at\tescalated_at\tasked_at_text\twaiting_on\tpark_until\tpark_trigger\tprompt_id\n'
    ledger_row k0001 done "$(ep 2026-09-30 10:00:00)"        # on the date
    ledger_row k0002 done "$(ep 2026-09-30 23:59:59)"        # last second of the date
    ledger_row k0003 done "$(ep 2026-09-29 23:59:59)"        # the day before
    ledger_row k0004 done "$(ep 2026-10-01 00:00:00)"        # the day after, first second
    ledger_row k0005 withdrawn "$(ep 2026-09-30 11:00:00)"   # closed that day but withdrawn
    ledger_row k0006 open ""                                  # still open
  } > "$AIMAIL_ROOT/state/asks.tsv"
  cat > "$T/daily.json" <<'EOJ'
{"daily":[{"date":"2026-09-29","totalCost":99.5},{"date":"2026-09-30","totalCost":12.0},{"date":"2026-10-01","totalCost":77.0}],"totals":{"totalCost":188.5}}
EOJ

  local out rc
  out="$("$AIMAIL" budget report --date 2026-09-30 2>&1)"; rc=$?
  check "report for a date exits 0" "$rc" 0
  check "  spend is the fixture's figure for that date only" "$(grep -c 'Spend, all configured accounts: *\$12.00' <<<"$out")" 1
  check "  asks closed counts the two done rows on the date (edges inclusive of the last second, exclusive of next midnight)" "$(grep -c 'Asks closed that day: *2 ' <<<"$out")" 1
  check "  the withdrawn row is shown but not counted" "$(grep -c 'withdrawn that day: 1, not counted' <<<"$out")" 1
  check "  cost per closed ask is spend / closed" "$(grep -c 'Cost per closed ask: *\$6.00' <<<"$out")" 1
  check "  review rounds line is n/a when no round file exists" "$(grep -c 'Review rounds per approved branch: *n/a (no branch approved that day)' <<<"$out")" 1
  check "  the report fits one screen (24 lines)" "$([[ "$(wc -l <<<"$out")" -le 24 ]] && echo ok || echo long)" ok
  check "ccusage got 'daily --json' for exactly that date" "$(grep -c '^ARGS: daily --json --since 20260930 --until 20260930$' "$T/cc.log")" 1
  check "  with BOTH account directories comma-joined, once" "$(grep -c "^DIRS: $T/cfg/alpha,$T/cfg/beta$" "$T/cc.log")" 1

  # fixture rounds (epoch, time, repo, branch, sha, round, verdict, scope, detail, reviewer, tests, findings)
  rr() { printf '%s\t-\tdemo\t%s\tsha%s\t%s\t%s\tfirst\t-\trev\t-\t-\n' "$(ep "$1" "$2")" "$3" "$3$4" "$4" "$5"; }
  { rr 2026-09-30 09:00:00 alpha 1 rejected; rr 2026-09-30 10:00:00 alpha 2 rejected; rr 2026-09-30 11:00:00 alpha 3 approved
    rr 2026-09-30 23:59:59 beta 1 approved                       # last second of the date
    rr 2026-09-30 12:00:00 gamma 1 rejected                      # rejected only: not an approved branch
    rr 2026-09-29 23:59:59 delta 5 approved                      # the day before
    rr 2026-10-01 00:00:00 eps 7 approved                        # the day after
  } > "$AIMAIL_ROOT/state/review_rounds.tsv"
  out="$("$AIMAIL" budget report --date 2026-09-30 2>&1)"
  check "  rounds per approved branch: two approved that day (3 and 1 rounds), edges respected" "$(grep -c 'Review rounds per approved branch: *2.00 average over 2 approved branch(es), max 3' <<<"$out")" 1
  out="$("$AIMAIL" budget report --date 2026-09-22 2>&1)"
  check "  a day with no approval reads n/a, not 0" "$(grep -c 'Review rounds per approved branch: *n/a (no branch approved that day)' <<<"$out")" 1
  rm -f "$AIMAIL_ROOT/state/review_rounds.tsv"

  # the default date is today's LOCAL date, from the fixed clock (00:30 local is the previous day in UTC for far-east zones)
  out="$(AIMAIL_NOW="$(ep 2026-09-30 00:30:00)" "$AIMAIL" budget report 2>&1)"
  check "no --date: the header is the local date of the clock (00:30 local)" "$(grep -c 'report for 2026-09-30 ' <<<"$out")" 1
  out="$(AIMAIL_NOW="$(ep 2026-09-30 23:30:00)" "$AIMAIL" budget report 2>&1)"
  check "no --date: still that date at 23:30 local" "$(grep -c 'report for 2026-09-30 ' <<<"$out")" 1

  # zero closed -> n/a, no division, never a measured-looking 0
  cat > "$T/daily.json" <<'EOJ'
{"daily":[{"date":"2026-09-25","totalCost":5.0}]}
EOJ
  out="$("$AIMAIL" budget report --date 2026-09-25 2>&1)"; rc=$?
  check "zero closed asks: exits 0 (no division by zero)" "$rc" 0
  check "  cost per closed ask prints n/a" "$(grep -c 'Cost per closed ask: *n/a (0 asks closed)' <<<"$out")" 1
  check "  and prints no zero cost-per-ask figure" "$(grep 'Cost per closed ask' <<<"$out" | grep -c '\$0\|0\.00')" 0
  check "  the spend is still shown" "$(grep -c 'Spend, all configured accounts: *\$5.00' <<<"$out")" 1

  # ccusage knows nothing for the date but answers: a real zero spend, closed 0
  cat > "$T/daily.json" <<'EOJ'
{"daily":[]}
EOJ
  out="$("$AIMAIL" budget report --date 2026-09-24 2>&1)"
  check "an empty but valid ccusage answer is a measured \$0.00 spend" "$(grep -c 'Spend, all configured accounts: *\$0.00' <<<"$out")" 1

  # ccusage failure -> unmeasurable, exit 4, never a zero
  touch "$T/cc_fail"
  out="$("$AIMAIL" budget report --date 2026-09-30 2>&1)"; rc=$?
  check "ccusage failing is UNMEASURABLE (exit 4), not a zero" "$rc" 4
  check "  spend line says UNMEASURABLE" "$(grep -c 'Spend, all configured accounts: *UNMEASURABLE' <<<"$out")" 1
  check "  cost per ask is n/a, not computed from a missing spend" "$(grep -c 'Cost per closed ask: *n/a (spend is unmeasurable)' <<<"$out")" 1
  rm -f "$T/cc_fail"

  # --mail: through the real send path, no-wake
  export AIMAIL_SUPERVISOR=sup
  rm -rf "$AIMAIL_ROOT/mail/sup"; mkdir -p "$AIMAIL_ROOT/mail/sup/unacked"
  cat > "$T/daily.json" <<'EOJ'
{"daily":[{"date":"2026-09-30","totalCost":12.0}]}
EOJ
  out="$("$AIMAIL" budget report --date 2026-09-30 --mail 2>&1)"; rc=$?
  check "--mail exits 0" "$rc" 0
  local f; f="$(grep -l '^subject: DAILY REPORT 2026-09-30$' "$AIMAIL_ROOT"/mail/sup/*.md 2>/dev/null | head -1)"
  check "  one report mail was delivered to the supervisor seat" "$([[ -n "$f" ]] && echo 1 || echo 0)" 1
  check "  its header marks it no-wake" "$([[ -n "$f" ]] && grep -c '^wake: no$' "$f" || echo 0)" 1
  check "  its body is the report" "$([[ -n "$f" ]] && grep -c 'Cost per closed ask: *\$6.00' "$f" || echo 0)" 1
  check "  the report is also printed" "$(grep -c 'aimail daily report for 2026-09-30' <<<"$out")" 1
  unset AIMAIL_SUPERVISOR
  out="$("$AIMAIL" budget report --date 2026-09-30 --mail 2>&1)"; rc=$?
  check "--mail with no AIMAIL_SUPERVISOR is refused (exit 3), no seat name is guessed" "$rc" 3
  check "  and the refusal names the variable" "$(grep -c 'AIMAIL_SUPERVISOR' <<<"$out")" 1
  out="$(AIMAIL_SUPERVISOR=nobody "$AIMAIL" budget report --date 2026-09-30 --mail 2>&1)"; rc=$?
  check "--mail to an unregistered supervisor is refused (exit 3)" "$rc" 3

  # input validation
  "$AIMAIL" budget report --date 2026-13-45 >/dev/null 2>&1; check "an impossible date is refused (exit 3)" "$?" 3
  "$AIMAIL" budget report --date yesterday  >/dev/null 2>&1; check "a non-numeric date is refused (exit 3)" "$?" 3
  "$AIMAIL" budget report --bogus           >/dev/null 2>&1; check "an unknown flag is refused (exit 3)" "$?" 3
}

for z in UTC Pacific/Kiritimati America/Los_Angeles; do run_zone "$z"; done

section "hermetic: with no network and no override the real ccusage is never run"
# a stand-in named ccusage sits first on PATH; if the report ever resolved it, it would log a line
unset AIMAIL_CCUSAGE_BIN; : > "$T/cc.log"; mkdir -p "$T/pathbin"
printf '#!/bin/sh\necho "PATH ccusage ran: $*" >> "%s"\necho "{\\"daily\\":[]}"\n' "$T/cc.log" > "$T/pathbin/ccusage"; chmod +x "$T/pathbin/ccusage"
out="$(PATH="$T/pathbin:$PATH" "$AIMAIL" budget report --date 2026-09-30 2>&1)"; rc=$?
check "no AIMAIL_CCUSAGE_BIN under AIMAIL_NO_NETWORK=1 is unmeasurable (exit 4)" "$rc" 4
check "  and a ccusage on PATH was not executed" "$(wc -l < "$T/cc.log" | tr -d ' ')" 0

echo; printf 'daily_report: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
