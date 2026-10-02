# shellcheck shell=bash
# report.sh — `aimail budget report`: the daily cost-per-task report.
#
# One screen for one local date: what the fleet spent across every configured account, how many
# asks were closed that day, what that makes per closed ask, and (once review rounds are recorded)
# how many review rounds each approved branch took. The point is a number someone can watch move,
# so a figure that was not measured prints as `n/a`, never as 0 and never as a division by zero.
#
#   aimail budget report [--date YYYY-MM-DD] [--mail]
#
# Spend comes from `ccusage daily --json`, run once with every configured account's config
# directory joined by commas in CLAUDE_CONFIG_DIR (ccusage reads a comma-separated list and sums
# across the directories). The command is resolved by core.sh's ccusage_cmd, so AIMAIL_CCUSAGE_BIN
# replaces it (tests point it at a fixture that prints canned JSON). With AIMAIL_NO_NETWORK=1 and
# no override the report never shells out and says the spend is unmeasurable.
#
# Closed asks are rows of the ask ledger whose state is `done` and whose closing time falls inside
# the local date. Withdrawn rows are shown separately and are not counted: a withdrawn ask was
# abandoned, not delivered, and counting it would make the cost per delivered ask look cheaper.
#
# `--mail` sends the same text to the supervisor seat (AIMAIL_SUPERVISOR; the command refuses when
# it is unset or not registered) with --no-wake, so it is read at the next real wake and never
# causes one. Run it from cron at the end of the day; the line is in the README.

# _report_day_bounds <YYYY-MM-DD> — "<start-epoch> <end-epoch>" of that LOCAL date (end exclusive).
# Both ends come from the same `date -d`, so the answer follows the machine's zone consistently
# and a day that is 23 or 25 hours long (a clock change) is measured as the length it really was.
_report_day_bounds() {
  local d="$1" s e
  s="$(date -d "$d 00:00:00" +%s 2>/dev/null)" || return 1
  # Noon of the next day, then its own midnight: "+ 1 day" after a time reads as a zone offset, and
  # noon is never inside a clock change, so the next date is always right.
  local nd; nd="$(date -d "$d 12:00:00 tomorrow" +%F 2>/dev/null)" || return 1
  e="$(date -d "$nd 00:00:00" +%s 2>/dev/null)" || return 1
  [[ "$s" =~ ^[0-9]+$ && "$e" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s\n' "$s" "$e"
}

# _report_accounts — the configured accounts, one per line (same source order as `budget pool`).
_report_accounts() {
  local a
  if [[ -n "${AIMAIL_FLEET_ACCOUNTS:-}" ]]; then
    for a in $AIMAIL_FLEET_ACCOUNTS; do printf '%s\n' "$a"; done; return 0
  fi
  local got=0
  while IFS= read -r a; do [[ -n "$a" ]] && { printf '%s\n' "$a"; got=1; }; done < <(_configured_account_pool 2>/dev/null || true)
  (( got )) || account_id
}

# _report_spend <YYYY-MM-DD> — prints "<usd>" (two decimals) on success; on failure prints the reason
# to stderr and returns 4. The usd figure sums totalCost of the daily rows dated exactly that day.
_report_spend() {
  local d="$1"
  local -a cc=(); read -r -a cc <<<"$(ccusage_cmd 2>/dev/null || true)"
  (( ${#cc[@]} )) || { echo "no ccusage command (none on PATH, no npx, AIMAIL_CCUSAGE_BIN unset)" >&2; return 4; }
  if [[ "${AIMAIL_NO_NETWORK:-0}" == "1" && -z "${AIMAIL_CCUSAGE_BIN:-}" ]]; then
    echo "AIMAIL_NO_NETWORK=1 and no AIMAIL_CCUSAGE_BIN: ccusage is not run" >&2; return 4
  fi
  local -a dirs=(); local a dir joined
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    dir="$(ACCOUNT_CONFIG_DIR "$a")"
    [[ -d "$dir" ]] && dirs+=("$dir")
  done < <(_report_accounts)
  (( ${#dirs[@]} )) || { echo "none of the configured accounts has a config directory on this machine" >&2; return 4; }
  joined="$(IFS=,; echo "${dirs[*]}")"
  local ymd="${d//-/}" tmp; tmp="$(mktemp "$STATE_DIR/.report.XXXXXX")"
  # The exit status is taken directly, not through a pipe, so a failed ccusage cannot hide behind
  # the parser's success.
  if ! CLAUDE_CONFIG_DIR="$joined" timeout "${AIMAIL_CCUSAGE_TIMEOUT:-120}" "${cc[@]}" daily --json --since "$ymd" --until "$ymd" > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "ccusage did not answer (or timed out)" >&2; return 4
  fi
  local out rc
  out="$(python3 - "$d" "$tmp" <<'PY'
import json, sys
day, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(4)
rows = d.get("daily") if isinstance(d, dict) else None
if not isinstance(rows, list):
    sys.exit(4)
tot = 0.0
for r in rows:
    if isinstance(r, dict) and r.get("date") == day:
        c = r.get("totalCost", r.get("costUSD"))
        if not isinstance(c, (int, float)):
            sys.exit(4)
        tot += float(c)
print("%.2f" % tot)
PY
)"; rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || { echo "ccusage output could not be read as daily JSON" >&2; return 4; }
  printf '%s\n' "$out"
}

# _report_closed_asks <start> <end> — "<done> <withdrawn>" counts for closing times in [start, end).
_report_closed_asks() {
  local s="$1" e="$2" f; f="$(ASK_FILE)"
  [[ -f "$f" ]] || { echo "0 0"; return 0; }
  awk -F'\t' -v s="$s" -v e="$e" 'NR>1 && $13 ~ /^[0-9]+$/ && $13>=s && $13<e { if ($8=="done") d++; else if ($8=="withdrawn") w++ }
    END { printf "%d %d\n", d+0, w+0 }' "$f"
}

# _report_review_rounds <start> <end> — the "review rounds per approved branch" value, or "n/a ...".
# Rounds come from review_rounds.tsv (lib/review.sh): a branch approved in the window counts the rounds
# (verdicts) it took, the approving one included. n/a when no branch was approved in the window.
_report_review_rounds() {
  local f="$STATE_DIR/review_rounds.tsv"
  [[ -f "$f" ]] || { echo "n/a (no branch approved that day)"; return 0; }
  awk -F'\t' -v s="$1" -v e="$2" '
    $7=="approved" && $1>=s && $1<e { n++; sum+=$6; if ($6>mx) mx=$6 }
    END { if (n==0) print "n/a (no branch approved that day)";
          else printf "%.2f average over %d approved branch(es), max %d\n", sum/n, n, mx }' "$f"
}

# budget_report [--date YYYY-MM-DD] [--mail]
budget_report() {
  local date_arg="" mail=0
  while (( $# )); do
    case "$1" in
      -h|--help)
        info "usage: aimail budget report [--date YYYY-MM-DD] [--mail]"
        info "  The day's spend across the configured accounts, asks closed, cost per closed ask,"
        info "  review rounds per approved branch. --mail sends it (no-wake) to the supervisor seat."
        info "  Nothing was changed."
        exit 0 ;;
      --date) [[ $# -ge 2 ]] || refused "usage: aimail budget report --date YYYY-MM-DD"
              date_arg="$2"; shift 2 ;;
      --mail) mail=1; shift ;;
      *) refused "unknown report argument: '$1'" "usage: aimail budget report [--date YYYY-MM-DD] [--mail]" ;;
    esac
  done
  local day
  if [[ -n "$date_arg" ]]; then
    [[ "$date_arg" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -d "$date_arg" +%F >/dev/null 2>&1 \
      || refused "--date must be a real calendar date, YYYY-MM-DD (got '$date_arg')"
    day="$date_arg"
  else
    day="$(date -d "@${AIMAIL_NOW:-$(now_epoch)}" +%F)"
  fi
  local supervisor="${AIMAIL_SUPERVISOR:-}"
  if (( mail )); then
    [[ -n "$supervisor" ]] || refused "report --mail needs the supervisor seat: AIMAIL_SUPERVISOR is not set." \
      "Set it in etc/aimail.conf; the tool does not guess which seat that is."
    seat_exists "$supervisor" || refused "report --mail: the supervisor seat '$supervisor' is not registered."
  fi
  ensure_dirs
  local bounds start end
  bounds="$(_report_day_bounds "$day")" || die "report: could not compute the bounds of $day"
  read -r start end <<<"$bounds"

  local spend="" spend_err="" rc=0
  spend="$(_report_spend "$day" 2>"$STATE_DIR/.report.err")" || rc=$?
  spend_err="$(cat "$STATE_DIR/.report.err" 2>/dev/null)"; rm -f "$STATE_DIR/.report.err"
  local closed withdrawn; read -r closed withdrawn <<<"$(_report_closed_asks "$start" "$end")"

  local n_acct; n_acct="$(_report_accounts | wc -l | tr -d ' ')"
  local spend_line per_line
  if (( rc == 0 )); then
    spend_line="\$$spend  (ccusage, $n_acct configured account(s))"
  else
    spend_line="UNMEASURABLE: ${spend_err:-ccusage gave no answer}"
  fi
  if (( rc != 0 )); then
    per_line="n/a (spend is unmeasurable)"
  elif (( closed == 0 )); then
    per_line="n/a (0 asks closed)"
  else
    per_line="\$$(awk -v s="$spend" -v c="$closed" 'BEGIN{printf "%.2f", s/c}')"
  fi

  local report
  report="$(
    printf 'aimail daily report for %s (local date)\n' "$day"
    printf '%s\n' '------------------------------------------------------------'
    printf '%-34s %s\n' "Spend, all configured accounts:" "$spend_line"
    printf '%-34s %s\n' "Asks closed that day:" "$closed  (withdrawn that day: $withdrawn, not counted)"
    printf '%-34s %s\n' "Cost per closed ask:" "$per_line"
    printf '%-34s %s\n' "Review rounds per approved branch:" "$(_report_review_rounds "$start" "$end")"
    printf '%s\n' '------------------------------------------------------------'
    printf 'n/a means not measured; it is never a zero.\n'
  )"
  printf '%s\n' "$report"

  if (( mail )); then
    local body; body="$(mktemp "$AIMAIL_ROOT/tmp/report.XXXXXX")"
    printf '%s\n' "$report" > "$body"
    # In a subshell: mail_send exits on a hard failure, and the report text has already been printed.
    if ( mail_send --to "$supervisor" --no-wake --from "$supervisor" \
           --subject "DAILY REPORT $day" --body-file "$body" ) >/dev/null 2>&1; then
      info "mailed to '$supervisor' (no-wake)"
    else
      rm -f "$body"; die "report: the report could not be mailed to '$supervisor'"
    fi
  fi
  (( rc == 0 )) || exit 4
  return 0
}
