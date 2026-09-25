#!/usr/bin/env bash
# gateclaim.sh — atomic gate claim for the fleet.
#
# WHY THIS EXISTS
#   On 2026-08-16 the mail-based claim protocol failed FIVE times, the worst
#   being four seats claiming the same gate within 19 SECONDS (framing 17:18:47,
#   main 17:18:51, foundation 17:18:58, audit 17:19:06). Every one of them
#   followed the rule correctly. Mail delivery latency is seconds and the
#   decision window is seconds, so every seat reads a queue that was accurate
#   when written and stale when read. No announce-based scheme can arbitrate
#   that — "announce before the first command" was itself the fix adopted after
#   the PREVIOUS collision, and it is what failed 4-way.
#
#   `mkdir` is atomic on POSIX: exactly one caller creates a given directory and
#   everyone else gets EEXIST. That is a real arbiter, already installed.
#
# WHAT IT DOES NOT DO
#   It does not replace the claim MAIL. The mail is how the fleet learns what is
#   happening and carries the reasoning. Send it AFTER winning the lock, so it
#   reports a fact rather than an intention.
#
# ⚠ LIMITATION, stated rather than hidden: this works because every seat runs on
#   ONE box sharing /tmp. If a seat ever runs elsewhere, mkdir stops being an
#   arbiter and this SILENTLY reverts to the old racy behaviour. Re-check this
#   assumption before relying on it in any other topology.
#
# ⛔ SECOND FAILURE, 2026-08-20 01:25 — 100% ADOPTION AND THE LOCK STILL DID NOT LOCK
#   code-review claimed `t100-widget-marks` at 01:25:04. audit claimed `T-100-widget`
#   at 01:25:43. BOTH used this script correctly and BOTH acquires returned 0,
#   because those are two different strings. Two seats, one work item, 39 seconds.
#   ⇒ mkdir gives mutual exclusion over a NAME, not over a WORK ITEM. A lock also
#     requires a shared KEY NAMESPACE, or it is two doors into one room.
#
#   ⚠ The fix first proposed (lowercase + strip non-alphanumerics) was MEASURED
#     against those two real keys and DOES NOT CATCH THEM:
#         t100-widget-marks -> t100widgetmarks
#         T-100-widget      -> t100widget        still distinct.
#     The difference was never case or punctuation — it was the trailing word.
#     So canonicalisation keys on the TICKET ID and DISCARDS the rest.
#
# ⛔⛔⛔ THIRD FAILURE, 2026-08-20 01:46 — AND IT WAS THE AUTHOR OF THE SECOND FIX
#   audit claimed `nightly-report` at 01:45:46. main claimed `main-nightly-report` at 01:46:35.
#   BOTH SUCCEEDED. The work item had NO TICKET NUMBER, so both keys fell through the ticket rule into
#   the free-form branch — which is exactly the "lowercase and strip" scheme measured as insufficient
#   eight minutes earlier, kept for the non-ticket case, and immediately broken by a `main-` prefix.
#   ⇒ ⭐ The ticket rule was never the general fix. It was a fix for keys that HAVE a ticket.
#
#   ⭐ THE GENERAL SIGNAL, and it catches every collision this file records: after canonicalisation
#     one key CONTAINS the other.
#         nightlyreport ⊂ mainnightlyreport      (01:46)
#         t100widget        ⊂ t100widgetmarks            (01:25)
#         b3ef4796        ⊂ b3ef4796a1c2             short-vs-long SHA of ONE commit — a latent hole
#                                                    nobody had hit yet, closed by the same rule
#   ⚠ Containment applies to FREE-FORM canons only, and only when BOTH are >= 8 chars:
#     `t20` is a substring of `t200` and they are DIFFERENT TICKETS, so ticket canons must match
#     EXACTLY. And `demoitem` ⊂ `maindemoitemdemo` is a real alias this does NOT catch — free-form keys
#     shorter than 8 chars are simply not protected. Stated rather than hidden.
#
# USAGE
#   gateclaim.sh <key> <seat> [--role <role>] [--desc "text"]   acquire
#                                                exit 0 = you own it, 1 = you do not
#   gateclaim.sh --release <key> <seat> [--role <role>] [--handoff <seat2>]
#                                                release after the verdict ships
#   gateclaim.sh --list                         show live claims (canonical key + as-typed)
#   gateclaim.sh --canon <key>                  print the canonical form and exit (dry run)
#
#   If `AIMAIL_GUARDED_RELEASE_<CANONICAL_KEY>` (key uppercased, non-alnum -> `_`)
#   is set to a path, --release REFUSES while that path is dirty (git status
#   --porcelain) in the live checkout — the claim protects a real file's edit
#   through to commit, not just through the raw write. `--handoff <seat2>`
#   bypasses the refusal by explicitly naming who the uncommitted state now
#   belongs to, recorded in the release's own output. See the SEVENTH FAILURE
#   comment at the --release implementation for the incident this closes.
#
#   <key> is a GATE SHA or a WORK-ITEM REF. Both are canonicalised; see canon().
#   --role is meaningful only for TICKET-shaped keys: pass it to split a ticket
#   into separate (ticket,role) doors, e.g. --role impl and --role gate on the
#   same ticket do NOT collide. Omitting it on a ticket-shaped key is safe but
#   over-collapses (the whole ticket is one door) — see canon()'s header.
#
#   --desc "text" (acquire only) is a one-line free-text note stored with the
#   claim and printed by --list alongside the seat/timestamp — a live "who's
#   doing what" board for free. ⚠ IT MUST ANSWER "WHY was this claim taken",
#   stable for the claim's whole lifetime — never "WHAT STEP am I on right
#   now", which drifts the moment work moves on, and there is no separate
#   expiry mechanism for it: staleness is judged the same way a bare claim's
#   staleness already is, off the timestamp --list already prints. A crashed
#   seat's claim with a now-stale description is the SAME existing exposure a
#   bare claim already has, not a new one.
#   ⛔ THIS IS A FLAG, NOT A BARE 3RD POSITIONAL ARGUMENT, DELIBERATELY — the
#   design session's own illustration (`<key> <seat> "description"`) was
#   tried first and RETRACTED: it collides with the FIFTH FAILURE's argc guard,
#   because a bare `gateclaim.sh acquire <key> <seat>` (the historical bug
#   shape) is ALSO exactly 3 tokens with a non-"--role" 3rd token. Demonstrated
#   with the existing regression test before switching designs: under the
#   bare-positional reading, `acquire realkey realseat` silently re-parses to
#   RAW=acquire SEAT=realkey DESC=realseat — the exact mis-parse the argc
#   guard exists to refuse, now dressed as valid input instead of an error. A
#   flag makes every shape self-describing, so a bare 3rd token is STILL
#   refused exactly as before. Backward compatible either way: omit --desc
#   and no existing 2-arg or --role caller changes.
#
#   Acquire as the VERY FIRST ACTION, before worktree setup (foundation, 2026-08-16:
#   a losing seat's worktree cleanup cost more than the race itself).
set -u

# Source the same project config core.sh uses, so AIMAIL_GUARDED_RELEASE_* (and
# any future gateclaim-relevant setting) is configurable centrally in
# etc/aimail.conf rather than needing each seat's own shell to export it.
# gateclaim.sh is otherwise fully standalone (no core.sh dependency) and stays
# that way — this reads config only, no shared state/functions.
_GC_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GC_HOME="$(dirname "$_GC_SELF")"
_GC_CONF="${AIMAIL_CONFIG:-$_GC_HOME/etc/aimail.conf}"
# shellcheck source=/dev/null
[ -f "$_GC_CONF" ] && source "$_GC_CONF"

DIR="${AIMAIL_CLAIMS:-/tmp/aimail-gate-claims}"
# Matched to the slowest suite run measured on 2026-08-16 (730s under 3-way
# contention). Must stay comfortably ABOVE that or a live gate gets stolen.
STALE_SECONDS="${AIMAIL_CLAIM_STALE:-1800}"

# canon KEY [ROLE] -> the directory name actually locked.
#   A ticket ref collapses to `t<digits>`, so every spelling of one ticket is ONE
#   door: T-100 / t100 / t-100-widget / t100-widget-marks / main-T100-wip -> t100.
#   Anything else lowercases and drops non-alphanumerics, which collapses case and
#   punctuation variants of free-form keys and leaves hex SHAs untouched (a SHA is
#   hex, and `t` is not a hex digit, so the ticket branch cannot fire on one).
# ⚠ This deliberately OVER-collapses: two seats on different facets of one ticket
#   get refused. That is the cheap failure. Under-collapsing is what cost 39
#   seconds of duplicated work tonight and 19 seconds in a 4-way race on 08-16.
#
# ⛔ FOURTH FAILURE, 2026-08-20 04:51 — THE OVER-COLLAPSE BLOCKS A PAIR THE FLEET
#   MANDATES BE SEPARATE: foundation's impl claim on a ticket-shaped key and
#   code-review's gate claim on the SAME TICKET collapse to the identical door,
#   so the gate claim is refused against the implementer's own claim. This was
#   masked for hours only because gate claims happen to be keyed on a SHA in
#   practice, not the ticket — a habit, not a property of the tool.
#   ⭐ FIX: an optional ROLE splits a ticket door into (ticket, role):
#   `t200:impl` and `t200:gate` are two doors, so the mandated pair no longer
#   collides, while every same-role spelling of the same ticket still collapses
#   to one door as before. ROLE only affects TICKET-shaped keys — a free-form or
#   SHA key ignores it, since containment already gives those their own
#   author != gater protection (a gate SHA and a free-form impl key never share
#   a namespace to begin with).
canon() {
  local raw="$1" role="${2:-}" low tick
  # Idempotence: an input already in canonical ticket[:role] form must pass
  # through UNCHANGED. Without this, re-canonicalising "t200:impl" (no role
  # arg) would re-run the ticket regex, match "200", and return bare "t200" —
  # silently dropping the role. legacy_alike() re-canonicalises existing
  # directory NAMES, which are already canonical for every claim taken after
  # this fix shipped, so this path is live, not theoretical.
  if [ -z "$role" ] && printf '%s' "$raw" | grep -qE '^t[0-9]+(:.+)?$'; then
    printf '%s\n' "$raw"; return 0
  fi
  low=$(printf '%s' "$raw" | tr 'A-Z' 'a-z')
  tick=$(printf '%s' "$low" | sed -n 's/.*\bt-\?\([0-9]\{2,4\}\)\b.*/\1/p' | head -1)
  if [ -n "$tick" ]; then
    if [ -n "$role" ]; then printf 't%s:%s\n' "$tick" "$role"
    else printf 't%s\n' "$tick"
    fi
    return 0
  fi
  printf '%s\n' "$(printf '%s' "$low" | tr -cd 'a-z0-9')"
}

# Claims written before canonicalisation shipped are raw-named, so a canonical
# acquire would not see them and would hand out a second door to a LIVE claim.
# Scan for any existing dir that canonicalises to the same key. Best-effort by
# construction (a scan is not atomic) — the atomic mkdir below is still the
# arbiter; this only stops the namespace CHANGE from voiding claims in flight.
# ticket_parts STR -> "TICKET ROLE" if STR is exactly `t<digits>` or
# `t<digits>:<role>` (both ends anchored, so a free-form canon that merely
# STARTS WITH t+digits, e.g. "t500plans", never matches this — the free-form
# branch's output can never contain a colon, and canon() never emits a
# ticket-shaped whole-string form for anything the ticket regex rejected in
# the first place). Prints nothing if STR is not ticket-shaped.
ticket_parts() {
  printf '%s' "$1" | sed -n 's/^\(t[0-9]\{1,\}\)\(:\(.*\)\)\{0,1\}$/\1 \3/p'
}

# Is $1 an alias of $2? Ticket canons (`t<digits>[:role]`) on the SAME ticket
# number are alike UNLESS both sides declare a role and the roles differ — the
# one split (ticket,role) exists to allow (foundation's `t200:impl` next to
# code-review's `t200:gate`). A ticket canon with NO declared role blocks every
# role on that ticket, which is the safe direction during a mixed old/new-
# caller transition: until a caller opts into --role, the whole ticket stays
# one door, same as before this fix. `t20` vs `t200` stay distinct — the
# ticket number itself is always exact, never a substring match.
# Free-form canons additionally collide on CONTAINMENT, but only when both are
# >= 8 chars, so a short key cannot swallow an unrelated longer one.
_MIN_CONTAIN=8
alike_keys() {
  local a="$1" b="$2"
  [ "$a" = "$b" ] && return 0
  local pa pb ta tb ra rb
  pa=$(ticket_parts "$a"); pb=$(ticket_parts "$b")
  if [ -n "$pa" ] && [ -n "$pb" ]; then
    ta="${pa%% *}"; ra="${pa#* }"
    tb="${pb%% *}"; rb="${pb#* }"
    [ "$ta" = "$tb" ] || return 1
    [ -n "$ra" ] && [ -n "$rb" ] && [ "$ra" != "$rb" ] && return 1
    return 0
  fi
  if [ -n "$pa" ] || [ -n "$pb" ]; then
    return 1
  fi
  case "$a$b" in *[!a-z0-9]*) return 1 ;; esac
  [ "${#a}" -ge "$_MIN_CONTAIN" ] && [ "${#b}" -ge "$_MIN_CONTAIN" ] || return 1
  case "$b" in *"$a"*) return 0 ;; esac
  case "$a" in *"$b"*) return 0 ;; esac
  return 1
}

# Find an existing claim that is an alias of $1 (skipping the dir named $2). Covers BOTH claims taken
# before canonicalisation shipped (raw-named, so a canonical acquire would not see them) and aliases
# that differ by an affix. Best-effort by construction — a scan is not atomic; the mkdir below is
# still the arbiter. This stops the namespace from handing out two doors into one room.
legacy_alike() {
  local want="$1" self="$2" d base
  [ -d "$DIR" ] || return 0
  for d in "$DIR"/*/; do
    [ -d "$d" ] || continue
    base=$(basename "$d")
    [ "$base" = "$self" ] && continue
    if alike_keys "$want" "$(canon "$base")"; then printf '%s\n' "$base"; return 0; fi
  done
  return 0
}

# ⛔ Pre-existing bug fixed in passing: this pointed at lines 42-47, which was
#   the "WHAT IT DOES NOT DO" prose, never the USAGE block -- usage() has been
#   printing the wrong section since canon() grew a header long enough to
#   push line numbers around. Hardcoded ranges into a growing comment block
#   are exactly the kind of drift this file has spent all night finding
#   elsewhere; re-pointed at the current, correct range.
usage() {
  # ⚠ 2026-08-20: was a hardcoded `sed -n '59,72p'`, which went STALE the moment
  # the --desc feature's USAGE comment grew past line 72 — every guard calling
  # usage() (bare/-h/--help, --canon/--release with a missing key) then printed
  # a block truncated mid-sentence. Neither of the two independent gates on
  # that build caught it, because no assertion checks --help's literal text.
  # Fixed to derive the range from the file's own markers rather than a second
  # magic number that can drift out of sync with the comment again.
  sed -n '/^# USAGE$/,/^set -u$/p' "$0" | sed '$d'
  exit 2
}

case "${1:-}" in
  --list)
    [ -d "$DIR" ] || { echo "no claims"; exit 0; }
    found=0
    for d in "$DIR"/*/; do
      [ -d "$d" ] || continue
      found=1
      raw=$(cat "$d/raw" 2>/dev/null || true)
      note=""
      [ -n "$raw" ] && [ "$raw" != "$(basename "$d")" ] && note="   (as typed: $raw)"
      printf '%s  %s%s\n' "$(basename "$d")" "$(cat "$d/owner" 2>/dev/null || echo '(no owner file)')" "$note"
    done
    [ "$found" = 1 ] || echo "no claims"
    exit 0
    ;;
  --canon)
    [ -n "${2:-}" ] || usage
    if [ "$#" -eq 2 ]; then
      canon "$2"; exit 0
    elif [ "$#" -eq 4 ] && [ "$3" = "--role" ]; then
      canon "$2" "$4"; exit 0
    else
      echo "REFUSED: bad arguments (got $#: $*) -- usage: --canon <key> [--role <role>]"
      exit 2
    fi
    ;;
  --release)
    RAW="${2:-}"; SEAT="${3:-}"; RROLE=""; HANDOFF=""
    shift 3 2>/dev/null || true
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --role)    [ -n "${2:-}" ] || { echo "REFUSED: --role needs a value"; exit 2; }; RROLE="$2"; shift 2 ;;
        --handoff) [ -n "${2:-}" ] || { echo "REFUSED: --handoff needs a value"; exit 2; }; HANDOFF="$2"; shift 2 ;;
        *) echo "REFUSED: bad arguments -- usage: --release <key> <seat> [--role <role>] [--handoff <seat>]"; exit 2 ;;
      esac
    done
    [ -n "$RAW" ] && [ -n "$SEAT" ] || usage
    # Release by CANONICAL key, so a holder who typed one spelling can release
    # with another. Without this, canonicalisation would strand claims.
    # --role disambiguates which door to release when a ticket has more than
    # one live role-door — without it, the legacy-alike fallback below could
    # find either one and release the wrong door.
    SHA=$(canon "$RAW" "$RROLE")
    # ⛔⛔ SIXTH FAILURE (found in review, 2026-08-31, before this ever shipped):
    # canon()'s ticket branches (both the idempotence passthrough and the
    # --role splice) never sanitize for path-unsafe characters the way the
    # free-form branch's `tr -cd 'a-z0-9'` does implicitly. A --role value (or
    # an already-canonical "tNNN:role" key) containing "/" or ".." survives
    # into $SHA unchanged, and $SHA drives `mkdir "$DIR/$SHA"` and, on release,
    # `rm -rf "${DIR:?}/${SHA:?}"` -- reproduced live in an isolated sandbox:
    # `--role "impl/../../pwned2"` creates pwned2 as a SIBLING of the claims
    # directory and a matching --release call rm -rf's it, both via the tool's
    # own documented --role workflow, not an obscure corner case. Refuse any
    # SHA that could escape $DIR before it touches the filesystem at all.
    case "$SHA" in
      */*) echo "REFUSED: '$RAW'${RROLE:+ --role '$RROLE'} canonicalises to an unsafe key '$SHA' (contains '/')"; exit 2 ;;
    esac
    # A claim taken BEFORE canonicalisation shipped lives under its raw name, so
    # the canonical dir does not exist and a naive release reports NOT CLAIMED
    # and STRANDS it — the lock would then sit there until the stale timeout.
    # Fall back to a name-alike, same rule the acquire path uses.
    if [ ! -d "$DIR/$SHA" ]; then
      LEG=$(legacy_alike "$SHA" "$SHA")
      [ -n "$LEG" ] && SHA="$LEG"
    fi
    OWNER=$(cut -d' ' -f1 "$DIR/$SHA/owner" 2>/dev/null || true)
    if [ -z "$OWNER" ]; then echo "NOT CLAIMED $SHA"; exit 0; fi
    if [ "$OWNER" != "$SEAT" ]; then
      # Refuse rather than steal — releasing someone else's claim is the same
      # class of harm as dropping their stash entry by index.
      echo "REFUSED: $SHA is held by $OWNER, not $SEAT"; exit 1
    fi
    # ⛔⛔⛔ SEVENTH FAILURE, 2026-09-01/02 — A DOCUMENTED NORM IS NOT ENFORCEMENT.
    #   The lock-through-commit norm (hold the claim until the edit is actually
    #   committed, not until the raw write succeeds) was written into SKILL.md
    #   at 11:13 and violated at 19:46 by a seat that helped write it: the claim
    #   released the moment the write succeeded, five minutes before anything
    #   committed it, and a later landing's sync overwrote the live file
    #   unconditionally — the fifth destroyed-uncommitted-work loss in two days.
    #   Same shape as `safe_sync.sh`'s own refuse-loudly logic, applied at the
    #   release boundary instead of the sync boundary: a claim guarding a real
    #   file's edit REFUSES to release while that file is dirty in the live
    #   checkout, unless the edit is already committed (clean) or the release
    #   explicitly names who it's handing the uncommitted state to.
    #
    #   Configure per key with `AIMAIL_GUARDED_RELEASE_<CANONICAL_KEY>=<path>`
    #   (key uppercased, non-alnum -> `_`, e.g. `AIMAIL_GUARDED_RELEASE_TODOEDIT=
    #   /path/to/TODO.md`). `git status --porcelain` on that path finds its own
    #   repo root by upward search, so the path need not be the repo root
    #   itself. `--handoff <seat>` bypasses the refusal for a NAMED recipient
    #   (recorded in this release's own stdout, not silently) — the protection
    #   window then belongs to the handoff seat until THEY commit or release.
    GVAR="AIMAIL_GUARDED_RELEASE_$(printf '%s' "$SHA" | tr -c 'A-Za-z0-9' '_' | tr 'a-z' 'A-Z')"
    GPATH="${!GVAR:-}"
    if [ -n "$GPATH" ] && [ -z "$HANDOFF" ]; then
      if [ ! -e "$GPATH" ]; then
        echo "⚠ guard configured for $SHA ($GVAR=$GPATH) but that path does not exist -- not blocking release on a path that isn't there"
      else
        GDIRTY="$(git -C "$(dirname "$GPATH")" status --porcelain -- "$GPATH" 2>/dev/null || true)"
        if [ -n "$GDIRTY" ]; then
          echo "REFUSED: $SHA guards $GPATH, which is dirty in the live checkout -- commit it first, or pass"
          echo "  --handoff <seat> to explicitly hand the uncommitted state to another seat instead of"
          echo "  silently dropping the protection. Dirty diff:"
          echo "$GDIRTY" | sed 's/^/  /'
          exit 1
        fi
      fi
    fi
    if [ -n "$HANDOFF" ]; then
      echo "HANDOFF $SHA: $SEAT -> $HANDOFF (uncommitted-state protection transfers, not released clean)"
    fi
    rm -rf "${DIR:?}/${SHA:?}" && echo "RELEASED $SHA by $SEAT"
    exit 0
    ;;
  ''|-h|--help) usage ;;
  --*)
    echo "REFUSED: unknown option '$1' -- see gateclaim.sh --help"
    exit 2
    ;;
esac

# Bare acquire form: <key> <seat> [--role <role>] [--desc "text"]. Refuse on
# ARGUMENT SHAPE, not a verb allowlist. FIFTH FAILURE, 2026-08-20 04:57 —
# there was no `acquire` subcommand, so `gateclaim.sh acquire <key> <seat>`
# fell through to here with RAW="acquire", SEAT="<key>", and the real seat
# silently discarded — printing CLAIMED while the real key stayed open, and
# corrupting the owner field with whatever string was mistaken for a key
# (main, demonstrated: owner became the sha itself). It fired for REAL once
# (framing, live, on 5f86c61c's lock, 05:39). A verb allowlist only catches
# verbs someone thought of; argument shape is structural and catches all of
# them, plus trailing garbage, in one rule.
# ⚠ `--desc` is a FLAG, not a bare 3rd positional argument, precisely so this
#   guard keeps refusing every bare-3-arg shape (including "acquire <key>
#   <seat>") exactly as before — see the USAGE block above for why the
#   positional form was tried and retracted.
# ⭐ ASK-LEDGER PREEMPTION: `--preempt-ok "<quote>"` may appear anywhere among
# the acquire args below; extract it BEFORE the exact-arg-count shape check so
# the remaining args still match one of the 2/4/6-arg shapes untouched. Only
# meaningful on a bare acquire -- --list/--canon/--release already exited above.
PREEMPT=""
_ga_kept=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --preempt-ok)
      [ -n "${2:-}" ] || { echo "REFUSED: --preempt-ok needs a value"; exit 2; }
      PREEMPT="$2"; shift 2 ;;
    *)
      _ga_kept+=("$1"); shift ;;
  esac
done
set -- "${_ga_kept[@]}"

if [ "$#" -eq 2 ]; then
  RAW="$1"; SEAT="$2"; ROLE=""; DESC=""
elif [ "$#" -eq 4 ] && [ "$3" = "--role" ]; then
  RAW="$1"; SEAT="$2"; ROLE="$4"; DESC=""
elif [ "$#" -eq 4 ] && [ "$3" = "--desc" ]; then
  RAW="$1"; SEAT="$2"; ROLE=""; DESC="$4"
elif [ "$#" -eq 6 ] && [ "$3" = "--role" ] && [ "$5" = "--desc" ]; then
  RAW="$1"; SEAT="$2"; ROLE="$4"; DESC="$6"
else
  echo "REFUSED: bad arguments (got $#: $*) -- usage: <key> <seat> [--role <role>] [--desc \"text\"] [--preempt-ok \"<owner quote>\"]"
  exit 2
fi
[ -n "$SEAT" ] || usage
# A description is free text but the owner file is a ONE-LINE record every
# reader (`cut -d' ' -f1`/`-f3`, the retry loop's `[ -s ... ]`) assumes stays
# single-line — strip embedded newlines rather than let a pasted multi-line
# note silently corrupt that assumption.
DESC="${DESC//$'\n'/ }"
SHA=$(canon "$RAW" "$ROLE")
[ -n "$SHA" ] || { echo "REFUSED: '$RAW' canonicalises to the empty string"; exit 2; }
# ⛔⛔ SIXTH FAILURE -- see the matching guard in the --release branch above for
# the full incident write-up. Same unsanitized-ticket-canon path-traversal
# risk, this time driving the acquire path's own `mkdir "$DIR/$SHA"` below.
case "$SHA" in
  */*) echo "REFUSED: '$RAW'${ROLE:+ --role '$ROLE'} canonicalises to an unsafe key '$SHA' (contains '/')"; exit 2 ;;
esac

# ⭐ ASK-LEDGER GATE: a seat that owns a STALE open ask cannot start a new
# claim -- this is how "a newer task drops the older ones" becomes impossible
# by default (lib/ask.sh's own header). `--preempt-ok "<owner quote>"` records
# the quote on every stale row (as a touch, ending its stale episode) instead
# of refusing. Never reached for --release/--list/--canon -- those exit above.
STALE_ROWS="$("$_GC_SELF/aimail" ask stale-for "$SEAT" 2>/dev/null)"
if [ -n "$STALE_ROWS" ]; then
  if [ -n "$PREEMPT" ]; then
    while IFS=$'\t' read -r _ask_id _ask_text; do
      [ -n "$_ask_id" ] || continue
      "$_GC_SELF/aimail" ask touch "$_ask_id" --by "$SEAT" \
        --state "preempted by claim '$RAW': $PREEMPT" --evidence "gateclaim $SHA" >/dev/null 2>&1
    done <<<"$STALE_ROWS"
  else
    echo "REFUSED: $SEAT owns a STALE open ask -- touch it first (aimail ask touch <id> --by $SEAT --state \"...\"), or pass --preempt-ok \"<owner quote>\":"
    while IFS=$'\t' read -r _ask_id _ask_text; do
      [ -n "$_ask_id" ] || continue
      echo "  $_ask_id: $_ask_text"
    done <<<"$STALE_ROWS"
    exit 1
  fi
fi

mkdir -p "$DIR" 2>/dev/null

if mkdir "$DIR/$SHA" 2>/dev/null; then
  # Won the canonical door. Now check for a pre-canonicalisation claim on the
  # same work item and BACK OUT if one exists — see legacy_alike(). Only one
  # seat can reach this, so the back-out cannot itself race.
  ALIKE=$(legacy_alike "$SHA" "$SHA")
  if [ -n "$ALIKE" ]; then
    AOWN=$(cut -d' ' -f1 "$DIR/$ALIKE/owner" 2>/dev/null || echo unknown)
    rmdir "$DIR/$SHA" 2>/dev/null
    echo "ALREADY CLAIMED $SHA by $AOWN — ALIAS of existing claim '$ALIKE' — stand down"
    exit 1
  fi
  # Write via temp+mv so a loser never reads a half-written owner file.
  # SUFFIX stays empty when no description was given, so an old-style caller's
  # owner-file bytes are UNCHANGED — the field is purely additive.
  # ⭐ SID column (twin-seat coordination, increment 0,
  #   docs/twin_seat_coordination_design_2026-09-18.md §5: "the claim record
  #   should carry <sid8> too"). Inserted as field 4, AFTER the existing
  #   field3 epoch every reader's `cut -d' ' -f3` already targets and BEFORE
  #   the "| DESC" suffix -- field1 (`-f1` SEAT) and field3 stay at their same
  #   positions for every existing reader; a legacy no-sid claim simply lacks
  #   field4, which nothing reads today. "solo" for a pre-M1 poller with no
  #   session id, matching instance_register's own fallback in lib/fleet.sh.
  SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-solo}}"
  SUFFIX=""; [ -n "$DESC" ] && SUFFIX=" | $DESC"
  printf '%s %s %s %s%s\n' "$SEAT" "$(date -Iseconds)" "$(date +%s)" "$SID" "$SUFFIX" > "$DIR/$SHA/.owner.tmp"
  mv -f "$DIR/$SHA/.owner.tmp" "$DIR/$SHA/owner"
  printf '%s\n' "$RAW" > "$DIR/$SHA/raw"
  NOROLE=""
  if [ -z "$ROLE" ] && printf '%s' "$SHA" | grep -qE '^t[0-9]+$'; then
    NOROLE="   ⚠ no --role given -- this ticket door blocks EVERY role on $SHA, including a same-ticket gate/impl pair that is supposed to be allowed. Prefer: <key> $SEAT --role impl|gate"
  fi
  if [ "$SHA" != "$RAW" ]; then
    echo "CLAIMED $SHA by $SEAT   (canonicalised from '$RAW')$NOROLE"
  else
    echo "CLAIMED $SHA by $SEAT$NOROLE"
  fi
  exit 0
fi

# Already held. ⚠ THE DIRECTORY EXISTS BEFORE THE OWNER FILE DOES — a loser that
# reads immediately can find it absent. Measured: in a real 4-way race one loser
# printed "ALREADY CLAIMED by  " with an empty owner. The LOCK was still correct
# (exactly one winner); only the diagnostic was blank. Retry briefly so the
# message names the actual holder.
OWNER=""; WHEN=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -s "$DIR/$SHA/owner" ]; then
    OWNER=$(cut -d' ' -f1 "$DIR/$SHA/owner" 2>/dev/null || true)
    WHEN=$(cut -d' ' -f3 "$DIR/$SHA/owner" 2>/dev/null || true)
    [ -n "$OWNER" ] && break
  fi
  sleep 0.05
done
OWNER="${OWNER:-unknown}"; WHEN="${WHEN:-0}"
NOW=$(date +%s)
AGE=$(( NOW - ${WHEN:-0} ))

if [ "${WHEN:-0}" -gt 0 ] && [ "$AGE" -gt "$STALE_SECONDS" ]; then
  SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-solo}}"
  SUFFIX=""; [ -n "$DESC" ] && SUFFIX=" | $DESC"
  printf '%s %s %s %s%s\n' "$SEAT" "$(date -Iseconds)" "$NOW" "$SID" "$SUFFIX" > "$DIR/$SHA/owner"
  echo "RECLAIMED $SHA from $OWNER (stale ${AGE}s > ${STALE_SECONDS}s) by $SEAT"
  exit 0
fi

echo "ALREADY CLAIMED $SHA by $OWNER (${AGE}s ago) — stand down"
exit 1
