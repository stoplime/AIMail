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
