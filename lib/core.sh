# shellcheck shell=bash
# core.sh — configuration, time, output discipline, and the refusal vocabulary.
#
# Sourced by every command. Defines the rules the rest of the codebase cannot opt out of.
#
# ═══ THE FOUR OUTPUT STATES ═══════════════════════════════════════════════════
# Every instrument here reports exactly one of:
#
#   MEASURED     a real reading, with the command that produced it
#   UNMEASURABLE the instrument could not measure — NOT zero, NOT clean
#   REFUSED      the caller asked for something the tool will not do
#   DERIVED      computed from a measurement; never interchangeable with MEASURED
#
# WHY this vocabulary exists (root cause RC-4 in the fleet defect report): the
# repeated failure was never a crash, it was *a plausible number*. A 384%
# projection, a 0.00%/hour burn rate read as "fleet idle, poke it", a census
# printing "0 of 0" as an all-clear. Each looked like an answer.
# ⇒ `unmeasurable` below EXITS NONZERO and prints why. It is deliberately harder
#   to ignore than printing 0 would be.

set -uo pipefail

AIMAIL_VERSION="0.1.0"

# ─── Paths ────────────────────────────────────────────────────────────────────
# CODE lives in the repo (versioned). DATA lives in AIMAIL_ROOT (machine-local).
# WHY the split is enforced here rather than by convention: in the system this
# replaces, the instruments themselves were gitignored, so no claim about one
# could be dated — a grep result was valid for one (inode, mtime) and nothing
# recorded which. That single fact generated most of the defect report.
AIMAIL_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIMAIL_HOME="$(dirname "$AIMAIL_LIB")"

_load_config() {
  local cfg="${AIMAIL_CONFIG:-$AIMAIL_HOME/etc/aimail.conf}"
  # shellcheck source=/dev/null
  [[ -f "$cfg" ]] && source "$cfg"
  AIMAIL_ROOT="${AIMAIL_ROOT:-$HOME/.aimail}"
  MAIL_DIR="$AIMAIL_ROOT/mail"
  STATE_DIR="$AIMAIL_ROOT/state"
  SEATS_FILE="$AIMAIL_ROOT/seats.tsv"
  LEDGER="$STATE_DIR/budget_ledger.tsv"
  export AIMAIL_ROOT MAIL_DIR STATE_DIR SEATS_FILE LEDGER
}
_load_config

# ─── Output ───────────────────────────────────────────────────────────────────
_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
info()  { printf '%s\n' "$*"; }
ok()    { _c '0;32'; printf '✔ %s\n' "$*"; _c '0'; }
warn()  { _c '0;33'; printf '⚠ %s\n' "$*" >&2; _c '0'; }

# die — an operational failure. Exit 1.
die() { _c '0;31'; printf '✖ %s\n' "$*" >&2; _c '0'; exit 1; }

# refused — the caller asked for something invalid. Exit 3, distinct from die,
# so a caller can tell "you asked wrongly" from "it broke".
refused() {
  _c '0;31'; printf '⛔ REFUSED: %s\n' "$1" >&2; _c '0'
  shift; for l in "$@"; do printf '   %s\n' "$l" >&2; done
  exit 3
}

# _dash_arg_guard <usage-line> -- "$@" — call as the FIRST line of a
# state-changing subcommand that takes no meaningful positional/flag
# arguments of its own (budget night/day/ramp/checkpoint). Only inspects
# $1: prints <usage-line> and exits 0 (nothing changed) when it is -h or
# --help; refuses (exit 3, nothing changed) when it starts with '-' and is
# neither. Returns normally, without exiting, for anything else (including
# no args at all) — the caller proceeds with its own logic unmodified.
# ⛔ 2026-09-25 (assistant, HIGH, mail 20260925T082038): `aimail budget park
#   --help` parked the whole account with reason "--help" (a real incident,
#   the librarian hit it live, 08:19). budget_park's own reason text is
#   free-form so it keeps a bespoke guard (see lib/budget.sh) rather than
#   this one, but every sibling subcommand that takes NO free-text argument
#   at all shares this exact check, added here rather than copy-pasted per
#   caller.
_dash_arg_guard() {
  local usage="$1"; shift
  case "${1:-}" in
    -h|--help) info "$usage"; info "  Nothing was changed."; exit 0 ;;
    -*) refused "'$1' is not a recognized argument here." "$usage" "Nothing was changed." ;;
  esac
}

# unmeasurable — the instrument ran and could not produce a reading. Exit 4.
# ⛔ NEVER substitute 0 here. "Unmeasurable" and "zero" are different claims and
#    zero reads as safe in whichever direction happens to be dangerous.
unmeasurable() {
  _c '0;35'; printf '❓ UNMEASURABLE: %s\n' "$1" >&2; _c '0'
  shift; for l in "$@"; do printf '   %s\n' "$l" >&2; done
  exit 4
}

# ─── Time — the only sanctioned source ────────────────────────────────────────
# ⛔ NO CALLER MAY SUPPLY A TIMESTAMP. In the previous system every HH:MM in one
#    seat's record was ~7.5h fast because timestamps were invented, and a second
#    seat then advanced its own clock from those headers rather than from a
#    clock — so the drift GREW between seats. Two invented numbers consistent
#    with each other cannot be caught by inspection.
# ⇒ These read the system clock. `mail.sh` refuses a caller-supplied date.
now_epoch() { date +%s; }

# ccusage_cmd — the ONE place that decides how the ccusage CLI is invoked. Prints the command
# words on one line (callers split them into an array) or returns 1 when nothing can run it.
#   1. AIMAIL_CCUSAGE_BIN (a test seam or an explicit path)
#   2. a `ccusage` on PATH (the global install: 2026-09-22 the owner/assistant -- `npx -y
#      ccusage@latest` re-resolved the package from npm and spawned a fresh node on EVERY call,
#      measured at ~390% CPU per burst; the autopilot cron plus per-seat probes made it a real
#      share of the machine's load, load 27 on 16 threads, swap full)
#   3. `npx --yes ccusage@latest` -- the fallback, for a machine without the install
ccusage_cmd() {
  if [[ -n "${AIMAIL_CCUSAGE_BIN:-}" ]]; then echo "$AIMAIL_CCUSAGE_BIN"; return 0; fi
  if command -v ccusage >/dev/null 2>&1; then echo ccusage; return 0; fi
  if command -v npx >/dev/null 2>&1; then echo "npx --yes ccusage@latest"; return 0; fi
  return 1
}
now_iso()   { date '+%Y-%m-%dT%H:%M:%S%z'; }
now_stamp() { date '+%Y%m%dT%H%M%S'; }

# age_min <epoch> — whole minutes since epoch. UNMEASURABLE on a bad input
# rather than defaulting to 0, which would read as "just now".
age_min() {
  local t="${1:-}"
  [[ "$t" =~ ^[0-9]+$ ]] || unmeasurable "age_min: '$t' is not an epoch" \
    "A missing timestamp must not read as age 0 ('just now')."
  echo $(( ( $(now_epoch) - t ) / 60 ))
}

# ─── Filesystem ───────────────────────────────────────────────────────────────
ensure_dirs() { mkdir -p "$MAIL_DIR" "$STATE_DIR" "$AIMAIL_ROOT/tmp"; }

# supervisor_scan_touch — hooks/supervisor_guard.sh's marker. Called by the dashboard
# commands (fleet, budget pool, budget balance); touches $STATE_DIR/supervisor_scan ONLY
# when the invoking session is registered (stop_guard.sh) as the supervisor seat, so the
# supervisor's Stop hook can tell "looked recently" from "did not". Any other session:
# no-op. Never fails the caller.
supervisor_scan_touch() {
  local sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; [[ -n "$sid" ]] || return 0
  local f="$STATE_DIR/stopguard/session.$sid"; [[ -f "$f" ]] || return 0
  [[ "$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')" == "${AIMAIL_SUPERVISOR:-assistant}" ]] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null && touch "$STATE_DIR/supervisor_scan" 2>/dev/null || true
}

# atomic_write <dest> — reads stdin, writes via a temp file on the SAME
# filesystem, then renames.
# WHY: rename(2) is atomic, so a reader never observes a partial file. The
# previous system composed mail directly into the inbox, so a poller could drain
# and archive a half-written message — and archiving is destructive of "unread".
atomic_write() {
  local dest="$1" tmp
  tmp="$(mktemp "$(dirname "$dest")/.tmp.XXXXXX")" || die "atomic_write: mktemp failed in $(dirname "$dest")"
  cat > "$tmp" || { rm -f "$tmp"; die "atomic_write: write failed for $dest"; }
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "atomic_write: rename failed for $dest"; }
}

# tsv_field <file> <row-selector> <n> — read field N without IFS collapse.
# ⛔⛔ NEVER `IFS=$'\t' read -r a b c d e`. Tab is IFS whitespace, so CONSECUTIVE
#    TABS COLLAPSE. A ledger row with empty middle fields yields 3 fields instead
#    of 5, silently shifting every later field left. In the previous system this
#    blinded the cold-start guard and would have re-throttled the whole fleet on
#    a fabricated 183%/hour rate.
#      printf '1\t0\t\t\tcold\n' | IFS=$'\t' read -r a b _ _ e; echo "[$e]"  ->  []
#      awk -F'\t' '{print $5}'                                              ->  cold
# ⇒ awk -F'\t' does not collapse empty fields. It is the only sanctioned reader.
tsv_last_field() {
  local file="$1" n="$2"
  [[ -s "$file" ]] || unmeasurable "tsv_last_field: '$file' is empty or missing" \
    "An empty log answers every query with 'clean'. That is not a reading."
  awk -F'\t' 'NF{last=$0} END{if(last==""){exit 4}; split(last,a,FS); print a['"$n"']}' "$file"
}

# ─── Instrument identity (root cause RC-3) ────────────────────────────────────
# A shared mutable instrument has no announcement channel: an edit and its
# announcement are separate acts, so there is always a window in which other
# readers measure a file that has silently changed. Printing the code identity
# with any consequential output closes that window at the point of use.
instrument_id() {
  local rev dirty
  rev="$(git -C "$AIMAIL_HOME" rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
  dirty=""
  git -C "$AIMAIL_HOME" diff --quiet 2>/dev/null || dirty="+dirty"
  printf 'aimail %s (%s%s)' "$AIMAIL_VERSION" "$rev" "$dirty"
}

# ─── supervisor-unreachable alert (lib/watchdog.sh writes it; session/fleet/doctor print it) ──
# ⛔ The one state that has no other channel: the supervisor seat is dead or wedged past a ramp
#   and the cron wake could not bring it back. Nothing that depends on the supervisor's own
#   session can report this, so every seat's own dashboard prints it FIRST until it is cleared
#   (`aimail fleet supervisor-ack`, or the watchdog clearing it on a verified wake).
SUPERVISOR_ALERT_FILE() { echo "$STATE_DIR/ALERT_supervisor_unreachable"; }
supervisor_alert_banner() {
  local f; f="$(SUPERVISOR_ALERT_FILE)"
  [[ -f "$f" ]] || return 0
  warn "⛔⛔ SUPERVISOR UNREACHABLE — $(head -1 "$f")"
  sed -n '2,6p' "$f" | sed 's/^/     /' >&2
  warn "   (details: $f — whoever reads this first runs the wake command it names, then clears it)"
}
