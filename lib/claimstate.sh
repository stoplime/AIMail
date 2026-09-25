# shellcheck shell=bash
# claimstate.sh — what state is a (seat, claim) PAIR actually in?
#
# ⛔⛔ THE CORRECTION THIS FILE EXISTS TO CARRY: the first proposal for this
#   (assistant's own, TTL auto-expiry on a stale gateclaim entry) was correctly
#   rejected by the project owner -- auto-releasing a lock while its holder is still
#   legitimately working recreates the exact collision gateclaim.sh exists to
#   prevent (see that file's own FIRST/SECOND/THIRD FAILURE headers). Fable's
#   review named the real defect: state was being asked of a SEAT, when the
#   thing that can go stale is a CLAIM. A seat doing unrelated work must never
#   make a stale claim it also happens to hold look alive, and a seat that is
#   demonstrably still advancing ONE claim must never have a DIFFERENT, actually
#   abandoned claim hide behind that activity. Every state below is therefore a
#   property of (seat, claim_key), never of seat alone.
#
# ⭐ FIVE STATES:
#   DOWN     the claim's own holder seat has a dead/missing heartbeat pid.
#   IDLE     a seat holds ZERO claims and its heartbeat pid is alive -- a
#            bare seat-level reading (seat_bare_state below), never printed
#            for an actual claim row, since a claim row always has a holder.
#   WORKING  evidence bound to THIS claim: a live process sitting in the
#            claim's own worktree (strongest -- counts regardless of age), or
#            a commit / a mail naming the claim's key, no older than
#            CLAIM_STUCK_SECONDS.
#   BLOCKED  the holder recorded a typed blocked_on referent
#            (gate:<key> | lock:<name> | seat:<name> | human:<name> |
#            landing:<sha>) and that referent still resolves as live.
#   STUCK    heartbeat pid alive, claim held, not (validly) blocked, no
#            attributable evidence inside the threshold. Never auto-released
#            -- this is a page for a human/orchestrator, not an action taken
#            here. PARKED seats are explicitly excluded (see claim_state).
#
#   A sixth, separate diagnostic -- MIS-SEATED -- rides alongside a DOWN
#   reading rather than replacing it: a dead heartbeat PID does not mean
#   nobody is there. `lib/sessions.sh` / `session_liveness.py` already answer
#   "is there a live session registered to this seat name" independently of
#   the heartbeat file (see fleet.sh's own STALLED-vs-WORKING split, which
#   this reuses rather than re-deriving). A DOWN claim whose seat still has a
#   live session is a session that has not re-armed yet, not an abandoned
#   claim -- reported as an annotation, never silently folded into a bare
#   "DOWN" that would read as "nobody is here" when someone plainly is.
#
# ⭐ THE THRESHOLD, AND WHY IT IS NOT A LITERAL PICKED TO FIT ONE INCIDENT:
#   CLAIM_STUCK_SECONDS is derived from two INDEPENDENTLY MEASURED real
#   outages this fleet actually lived through on 2026-09-17 -- not modeled,
#   not guessed:
#     1. The fleet-wide usage-limit outage (the project owner's account hit a hard rate
#        limit): multiple seats' own role-handover notes independently record
#        resuming "after a ~3-hour poller gap".
#     2. librarian's own session death, timed precisely from its own mail
#        record: last real activity ~17:48-17:52 (the A26 blind-read mails),
#        the 18:15 CHECKPOINT mail delivered but never acted on (the process
#        died before writing the requested handover), then nothing until
#        assistant's direct CLI revival at ~21:07 -- ~3h15m.
#   Both landed close to three hours, from two unrelated causes (an external
#   rate limit; an unexplained process death). A STUCK threshold shorter than
#   that would have paged a human about EVERY claim on the board during
#   either event -- the exact "alert that fires on the healthy case teaches
#   its reader to ignore it" failure fleet.sh's own STALL_ALERT header
#   already names. Set to 2x the larger measured outage, rounded up: 6 hours.
#   Overridable, like every other threshold in this codebase, never silently
#   hardcoded past this file.
CLAIM_STUCK_SECONDS="${AIMAIL_CLAIM_STUCK_SECONDS:-21600}"

# shellcheck source=./fleet.sh
# fleet.sh is not always sourced alongside this file (mirrors budget.sh's own
# defensive source of fleet.sh for the identical reason: hb_read/hb_write,
# poller_state and the session-liveness loader all live there).
source "${BASH_SOURCE[0]%/*}/fleet.sh" 2>/dev/null || true

CLAIM_DIR() { echo "${AIMAIL_CLAIMS:-/tmp/aimail-gate-claims}"; }
GATECLAIM_BIN() { echo "$AIMAIL_HOME/bin/gateclaim.sh"; }
CLAIM_BLOCK_FILE() { echo "$(CLAIM_DIR)/$1/blocked_on"; }

# ─── The real repos this fleet's claims actually build in, plus AIMail itself.
#   AIMAIL_CLAIM_REPOS (space-separated, set in this machine's own gitignored
#   etc/aimail.conf) is the only source for these -- no hardcoded fallback,
#   since this ships to other fleets whose repos are not this deployment's own
#   (same escape hatch fleet.sh's own DISK_KNOWN_REPOS uses, for the same reason).
_claim_repos() {
  local extra="${AIMAIL_CLAIM_REPOS:-}" r
  local -a repos=("$AIMAIL_HOME")
  for r in $extra; do repos+=("$r"); done
  for r in "${repos[@]}"; do
    [[ -d "$r/.git" || -f "$r/.git" ]] && printf '%s\n' "$r"
  done
}

# ─── Canonicalisation — SHELL OUT to gateclaim.sh's own canon(), never
#   reimplement it. That file records SEVEN incidents in its own canon()/
#   alike_keys() logic; a second, hand-copied version here would drift from
#   it silently the next time it is fixed, and a claim-state reader that
#   disagrees with the lock it is describing is worse than no reader.
_claim_canon() {
  local key="$1" role="${2:-}"
  if [[ -n "$role" ]]; then bash "$(GATECLAIM_BIN)" --canon "$key" --role "$role"
  else bash "$(GATECLAIM_BIN)" --canon "$key"; fi
}

_claim_read_owner() {  # canon -> the raw owner-file line, or nothing (rc 1)
  local f; f="$(CLAIM_DIR)/$1/owner"
  [[ -s "$f" ]] || return 1
  cat "$f"
}
_claim_owner_seat()  { _claim_read_owner "$1" 2>/dev/null | awk '{print $1}'; }
_claim_since_epoch() { _claim_read_owner "$1" 2>/dev/null | awk '{print $3}'; }
_claim_raw()         { cat "$(CLAIM_DIR)/$1/raw" 2>/dev/null; }

# Every currently-held canonical key, one per line.
claims_all() {
  local d; [[ -d "$(CLAIM_DIR)" ]] || return 0
  for d in "$(CLAIM_DIR)"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done
}

# ─── BLOCKED — a typed referent, recorded by the holder, never free text ──────
# blocked_on file format: epoch \t seat \t referent   (one line, current state
# only -- like the owner file itself, this is not an append-only log).
claim_set_blocked() {
  local key="$1" seat="$2" referent="$3" canon owner
  canon="$(_claim_canon "$key")"
  [[ -n "$canon" ]] || refused "cannot canonicalise '$key'"
  owner="$(_claim_owner_seat "$canon")"
  [[ -n "$owner" ]] || refused "no live claim for '$canon' -- nothing to mark blocked"
  [[ "$owner" == "$seat" ]] || refused "claim '$canon' is held by '$owner', not '$seat' -- only the holder marks its own block"
  case "$referent" in
    gate:*|lock:*|seat:*|human:*|landing:*) : ;;
    *) refused "blocked_on must be typed: gate:<key> | lock:<name> | seat:<name> | human:<name> | landing:<sha>" \
         "got: '$referent'" ;;
  esac
  printf '%s\t%s\t%s\n' "$(now_epoch)" "$seat" "$referent" > "$(CLAIM_BLOCK_FILE "$canon")"
  ok "recorded: $canon blocked_on $referent"
}

claim_clear_blocked() {
  local key="$1" seat="$2" canon owner
  canon="$(_claim_canon "$key")"
  [[ -n "$canon" ]] || refused "cannot canonicalise '$key'"
  owner="$(_claim_owner_seat "$canon")"
  [[ "$owner" == "$seat" ]] || refused "claim '$canon' is held by '${owner:-nobody}', not '$seat'"
  rm -f "$(CLAIM_BLOCK_FILE "$canon")"
  ok "cleared blocked_on for $canon"
}

# _claim_blocked_cycle <origin_canon> <start_canon> -> 0 (cycle found) or 1
# Walks a chain of gate:<key> referents up to 10 hops. A cycle is A blocked on
# B's gate while B (transitively) is blocked on A's -- neither side's block
# will ever clear on its own, which is exactly the case a human must see
# rather than have it silently read as two ordinary BLOCKED rows.
_claim_blocked_cycle() {
  local origin="$1" cur="$2" depth=0 referent type ref rcanon
  while (( depth < 10 )); do
    depth=$((depth+1))
    referent="$(cut -f3 "$(CLAIM_BLOCK_FILE "$cur")" 2>/dev/null)"
    [[ -n "$referent" ]] || return 1
    type="${referent%%:*}"; ref="${referent#*:}"
    [[ "$type" == "gate" ]] || return 1
    rcanon="$(_claim_canon "$ref")"
    [[ "$rcanon" == "$origin" ]] && return 0
    [[ -d "$(CLAIM_DIR)/$rcanon" ]] || return 1
    cur="$rcanon"
  done
  return 1
}

# _claim_blocked_validity <canon> -> "none" | "valid" | "dangling: <why>" | "cycle: <why>"
# ⛔ NEVER SILENTLY TRUSTED. A referent is re-checked every read, because the
#   thing it names (a gate, a landing sha) can resolve at any time without the
#   holder ever coming back to clear its own blocked_on file.
_claim_blocked_validity() {
  local canon="$1" referent type ref
  [[ -f "$(CLAIM_BLOCK_FILE "$canon")" ]] || { echo "none"; return; }
  referent="$(cut -f3 "$(CLAIM_BLOCK_FILE "$canon")" 2>/dev/null)"
  [[ -n "$referent" ]] || { echo "none"; return; }
  type="${referent%%:*}"; ref="${referent#*:}"
  case "$type" in
    gate)
      local rcanon; rcanon="$(_claim_canon "$ref")"
      if [[ ! -d "$(CLAIM_DIR)/$rcanon" ]]; then
        echo "dangling: referenced gate '$ref' ($rcanon) is not currently held -- already resolved"
      elif _claim_blocked_cycle "$canon" "$rcanon"; then
        echo "cycle: $canon -> $rcanon, which transitively blocks back on $canon"
      else
        echo "valid"
      fi ;;
    lock)
      if [[ -d "$(CLAIM_DIR)/$(_claim_canon "$ref")" ]]; then echo "valid"
      else echo "dangling: referenced lock '$ref' is not currently held"; fi ;;
    seat)
      if seat_exists "$ref"; then echo "valid"
      else echo "dangling: seat '$ref' is not a registered seat"; fi ;;
    human)
      if [[ -n "$ref" ]]; then echo "valid"
      else echo "dangling: empty human referent"; fi ;;
    landing)
      local r found=0
      for r in $(_claim_repos); do
        if git -C "$r" cat-file -e "${ref}^{commit}" 2>/dev/null; then found=1; break; fi
      done
      if (( found )); then echo "dangling: landing '$ref' already exists in the repo -- the block has resolved"
      else echo "valid"; fi ;;
    *) echo "dangling: unrecognised referent type '$type'" ;;
  esac
}

# ─── Evidence bound to the SPECIFIC claim ─────────────────────────────────────
_claim_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }

# Worktrees whose branch name or path contains the canonical key as a
# substring, under the SAME normalisation (lowercase, alnum-only) gateclaim's
# own free-form canon() applies -- so "librarian/aimail-acctauto" and
# "aimailacctauto" agree without a second canonicalisation scheme to drift
# from the first.
# ⛔ THE PATH IS CHECKED EVEN WITH NO "branch" LINE. A `git worktree add
#   --detach` worktree's porcelain block never emits one (it emits "detached"
#   instead) -- exactly the shape this build's own isolated-worktree
#   convention uses. Matching only inside the branch-line case silently
#   excluded every detached worktree, including this claim's own, from ever
#   producing WORKING evidence at all (measured live: `aimailseatstate`'s own
#   worktree path normalises to a superstring of its canon and was never
#   being checked).
_claim_worktrees() {
  local canon="$1" nc r line path branch
  nc="$(_claim_norm "$canon")"
  [[ -n "$nc" ]] || return 0
  _wt_emit() {
    case "$(_claim_norm "${branch}${path}")" in
      *"$nc"*) printf '%s\n' "$path" ;;
    esac
  }
  for r in $(_claim_repos); do
    path=""; branch=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) path="${line#worktree }"; branch="" ;;
        "branch "*)   branch="${line#branch refs/heads/}" ;;
        "")
          [[ -n "$path" ]] && _wt_emit
          path=""; branch="" ;;
      esac
    done < <(git -C "$r" worktree list --porcelain 2>/dev/null; printf '\n')
  done
}

# Newest commit, in any of the claim's own matched worktrees, authored at or
# after the claim's own since-epoch. Prints "epoch\tsha summary", or nothing.
_claim_commit_evidence() {
  local canon="$1" since="$2" wt line ep best_epoch=0 best=""
  while IFS= read -r wt; do
    [[ -n "$wt" && -d "$wt" ]] || continue
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      ep="${line%%$'\t'*}"
      [[ "$ep" =~ ^[0-9]+$ ]] || continue
      if (( ep > best_epoch )); then best_epoch="$ep"; best="$line"; fi
    done < <(git -C "$wt" log --since="@$since" --format='%at%x09%h %s' 2>/dev/null)
  done < <(_claim_worktrees "$canon")
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# Newest mail, FROM the claim's own owner seat, dated at or after the claim's
# since-epoch, whose body or headers name either spelling of the key. Scans
# every seat's mailbox (inbox + unacked + archive) because the evidence a
# holder produces lands in a RECIPIENT's mailbox, not its own -- this repo
# keeps no per-sender copy.
# ⛔⛔ MEASURED, not assumed cheap: this fleet's real mail archive holds
#   80,000+ .md files. A naive per-file bash loop (awk for the header, stat
#   for mtime, grep for the body, once EACH, per claim) does not finish in
#   any reasonable time against that corpus -- `aimail claims` on the real
#   board hung past a full minute before this fix. `find -newer` narrows the
#   candidate set with ONE fast C-level mtime scan (measured: 0.17s down to
#   ~2000 files from 80,000 real files) BEFORE any per-file work happens, and
#   the content match runs as ONE grep -l invocation over that narrowed list
#   rather than a bash loop invoking grep once per file.
_claim_mail_evidence() {
  local owner="$1" raw="$2" canon="$3" since="$4" f from mtime best_epoch=0 best=""
  local marker; marker="$(mktemp "${TMPDIR:-/tmp}/aimail-claim-since.XXXXXX")"
  touch -d "@$since" "$marker" 2>/dev/null || touch -t "$(date -d "@$since" +%Y%m%d%H%M.%S)" "$marker" 2>/dev/null || true
  local -a candidates=()
  if [[ -n "$canon" && "$canon" != "$raw" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && candidates+=("$f"); done < <(
      find "$MAIL_DIR" -type f -name '*.md' -newer "$marker" -print0 2>/dev/null \
        | xargs -0 -r grep -liF -e "$raw" -e "$canon" 2>/dev/null)
  else
    while IFS= read -r f; do [[ -n "$f" ]] && candidates+=("$f"); done < <(
      find "$MAIL_DIR" -type f -name '*.md' -newer "$marker" -print0 2>/dev/null \
        | xargs -0 -r grep -liF -- "$raw" 2>/dev/null)
  fi
  rm -f "$marker"
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    from="$(awk -F': ' '/^from: /{print $2; exit}' "$f" 2>/dev/null)"
    [[ "$from" == "$owner" ]] || continue
    mtime="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    (( mtime >= since )) || continue
    if (( mtime > best_epoch )); then best_epoch="$mtime"; best="$mtime	$f"; fi
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
}

# The strongest signal: a LIVE process whose cwd resolves under one of the
# claim's own worktrees. Counts regardless of any time threshold.
# ⚠ STATED LIMITATION: this checks WHICH DIRECTORY a process sits in, never
#   WHICH SESSION/SEAT it belongs to -- a process cd'd into the worktree by
#   coincidence would false-positive as WORKING. Disclosed rather than built
#   out further: two seats concurrently inside the same claim's own worktree
#   is exactly the collision gateclaim.sh exists to prevent, so the incidence
#   this could misjudge is already supposed to be near zero.
_claim_process_evidence() {
  local canon="$1" wt pid cwd w
  local -a worktrees=()
  while IFS= read -r wt; do [[ -n "$wt" ]] && worktrees+=("$wt"); done < <(_claim_worktrees "$canon")
  (( ${#worktrees[@]} )) || return 1
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    [[ -n "$cwd" ]] || continue
    for w in "${worktrees[@]}"; do
      case "$cwd" in
        "$w"|"$w"/*) printf '%s\t%s\n' "$pid" "$cwd"; return 0 ;;
      esac
    done
  done
  return 1
}

# ─── DOWN / mis-seated — the seat's own heartbeat pid, independent of any
#   claim's evidence ─────────────────────────────────────────────────────────
_claim_seat_alive() {
  local seat="$1" pid
  pid="$(hb_read "$seat" pid 2>/dev/null || echo '')"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then echo 1; else echo 0; fi
}

# A live session (its own claude process, per session_liveness.py, reused via
# fleet.sh's _fleet_load_sessions rather than re-derived) registered to this
# SAME seat name, independent of whether the seat's heartbeat pid is alive.
# This is the exact evidence fleet.sh's own STALLED-vs-WORKING split already
# reads; claimstate borrows it rather than re-deriving a second copy that
# could disagree with the first.
_claim_mis_seated() {
  local seat="$1"
  _fleet_load_sessions || return 1
  (( ${FLEET_SESS_LIVE[$seat]:-0} > 0 ))
}

# ─── The per-claim state machine ──────────────────────────────────────────────
# claim_state <canon> -> STATE \t DETAIL on stdout.
claim_state() {
  local canon="$1" owner since_epoch raw now
  owner="$(_claim_owner_seat "$canon")"
  if [[ -z "$owner" ]]; then
    printf 'UNKNOWN\tno live claim for %s\n' "$canon"
    return 1
  fi
  since_epoch="$(_claim_since_epoch "$canon")"
  [[ "$since_epoch" =~ ^[0-9]+$ ]] || since_epoch=0
  raw="$(_claim_raw "$canon")"; [[ -n "$raw" ]] || raw="$canon"
  now="$(now_epoch)"

  # ── 1. BLOCKED, checked first: a validly blocked claim is not judged for
  #    activity at all -- "no commits while waiting on someone else's gate"
  #    is the correct, intended shape, not a defect. A stale (dangling/cycle)
  #    block is flagged but does not freeze the reading -- it falls through
  #    to normal evaluation, carrying the flag along to whatever state that
  #    evaluation lands on. ──
  local block_note=""
  if [[ -f "$(CLAIM_BLOCK_FILE "$canon")" ]]; then
    local referent validity
    referent="$(cut -f3 "$(CLAIM_BLOCK_FILE "$canon")" 2>/dev/null)"
    validity="$(_claim_blocked_validity "$canon")"
    if [[ "$validity" == valid ]]; then
      printf 'BLOCKED\tblocked_on %s (recorded by %s)\n' "$referent" "$owner"
      return 0
    fi
    block_note=" ⚠ its own blocked_on ($referent) is $validity -- not trusted, should be cleared"
  fi

  # ── 2. Evidence, strongest first: a live process in the claim's own
  #    worktree counts regardless of age. ──
  local proc_ev
  if proc_ev="$(_claim_process_evidence "$canon" 2>/dev/null)"; then
    printf 'WORKING\tlive process (pid %s) sitting in this claim'"'"'s own worktree%s\n' \
      "$(cut -f1 <<<"$proc_ev")" "$block_note"
    return 0
  fi

  local commit_ev mail_ev last_ev=0 last_detail=""
  commit_ev="$(_claim_commit_evidence "$canon" "$since_epoch")"
  if [[ -n "$commit_ev" ]]; then
    local cep; cep="$(cut -f1 <<<"$commit_ev")"
    if [[ "$cep" =~ ^[0-9]+$ ]] && (( cep > last_ev )); then
      last_ev="$cep"; last_detail="commit $(cut -f2- <<<"$commit_ev")"
    fi
  fi
  mail_ev="$(_claim_mail_evidence "$owner" "$raw" "$canon" "$since_epoch")"
  if [[ -n "$mail_ev" ]]; then
    local mep; mep="$(cut -f1 <<<"$mail_ev")"
    if [[ "$mep" =~ ^[0-9]+$ ]] && (( mep > last_ev )); then
      last_ev="$mep"; last_detail="mail $(basename "$(cut -f2- <<<"$mail_ev")")"
    fi
  fi

  # If there's recent evidence, that alone settles WORKING -- no need to even
  # ask whether the seat is alive.
  if (( last_ev > 0 )) && (( now - last_ev <= CLAIM_STUCK_SECONDS )); then
    printf 'WORKING\t%s (%sm ago)%s\n' "$last_detail" "$(( (now-last_ev)/60 ))" "$block_note"
    return 0
  fi

  # ── 3. No fresh evidence. Is the seat even here? Checked BEFORE any grace
  #    period: a dead heartbeat is a positive fact about right now, and a
  #    claim being young does not un-kill a dead process. DOWN always wins
  #    over "give it time". ──
  local alive; alive="$(_claim_seat_alive "$owner")"
  if (( alive == 0 )); then
    local misseated=""
    if _claim_mis_seated "$owner"; then
      misseated=" ⚠ MIS-SEATED: a live session is registered to '$owner' even though its poller heartbeat pid is dead -- compare session id -> seat mapping (aimail sessions $owner) before treating this claim as abandoned"
    fi
    printf 'DOWN\theartbeat pid for %s is dead/missing; held since %s%s%s\n' \
      "$owner" "$(date -d "@$since_epoch" '+%F %H:%M' 2>/dev/null || echo "epoch $since_epoch")" \
      "$misseated" "$block_note"
    return 0
  fi

  # Alive, holds the claim, not blocked, no fresh evidence. Two things still
  # excuse this before it counts as STUCK:
  #
  # ⛔ A claim with NO evidence yet is not the same claim as one with STALE
  #   evidence -- the first is simply YOUNG. Judging staleness off `last_ev`
  #   alone made a claim read STUCK within seconds of its own acquire
  #   (MEASURED live against this fleet's real board: this build's own claim,
  #   ~18 minutes old, no commit or progress mail sent yet, read STUCK "past
  #   the 6h threshold" -- 18 minutes cannot be 6 hours stale). Grace applies
  #   only here, AFTER confirming the seat is actually alive -- a dead seat
  #   never gets "it just started", checked above.
  if (( now - since_epoch <= CLAIM_STUCK_SECONDS )) && (( last_ev == 0 )); then
    printf 'WORKING\tclaimed %sm ago, no evidence yet but still inside the grace period (a fresh claim has not had time to produce a commit or mail)%s\n' \
      "$(( (now-since_epoch)/60 ))" "$block_note"
    return 0
  fi

  # PARKED is explicitly excluded from STUCK -- a correctly parked seat under
  # a budget throttle is not stuck, it is doing exactly what the throttle asks.
  local pstate pdetail
  IFS=$'\t' read -r pstate pdetail < <(poller_state "$owner" 2>/dev/null)
  if [[ "$pstate" == "PARKED" ]]; then
    printf 'WORKING\tseat is correctly PARKED under a budget throttle -- claim age is not held against a parked seat%s\n' "$block_note"
    return 0
  fi

  local age_desc="no attributable evidence at all"
  (( last_ev > 0 )) && age_desc="last evidence $(( (now-last_ev)/3600 ))h ago"
  printf 'STUCK\t%s holds this claim since %s, alive, not blocked, %s -- past the %sh threshold. Never auto-released; needs a human/orchestrator look.%s\n' \
    "$owner" "$(date -d "@$since_epoch" '+%F %H:%M' 2>/dev/null || echo "epoch $since_epoch")" \
    "$age_desc" "$(( CLAIM_STUCK_SECONDS/3600 ))" "$block_note"
}

# ─── The bare seat-level reading, for a seat holding ZERO claims ─────────────
# seat_bare_state <seat> -> IDLE \t detail   or   DOWN \t detail
seat_bare_state() {
  local seat="$1" alive
  alive="$(_claim_seat_alive "$seat")"
  if (( alive == 1 )); then
    printf 'IDLE\talive, holds no gateclaim entries\n'
  else
    local misseated=""
    if _claim_mis_seated "$seat"; then
      misseated=" ⚠ MIS-SEATED: a live session is registered to '$seat' even though its poller heartbeat pid is dead"
    fi
    printf 'DOWN\theartbeat pid is dead/missing, holds no gateclaim entries%s\n' "$misseated"
  fi
}

# ─── The dashboard ────────────────────────────────────────────────────────────
claims_report() {
  local -a filter=()
  local a
  for a in "$@"; do
    case "$a" in
      -*) refused "unknown option '$a' for 'aimail claims'" "Try: aimail claims [seat…] [--json]" ;;
      *)  filter+=("$(seat_resolve "$a")") || exit $? ;;
    esac
  done

  # Group currently-held claims by owner seat.
  local -A by_seat=()
  local canon owner
  while IFS= read -r canon; do
    [[ -n "$canon" ]] || continue
    owner="$(_claim_owner_seat "$canon")"
    [[ -n "$owner" ]] || continue
    by_seat["$owner"]="${by_seat[$owner]:-}${by_seat[$owner]:+ }$canon"
  done < <(claims_all)

  local -a seats=()
  if (( ${#filter[@]} )); then
    seats=("${filter[@]}")
  else
    while IFS= read -r a; do
      [[ -n "$a" ]] || continue
      [[ "$(seat_field "$a" 2)" == "retired" ]] && continue
      seats+=("$a")
    done < <(seat_names)
  fi

  printf '%-14s %-10s %-30s %s\n' SEAT STATE CLAIM DETAIL
  printf '%.0s─' {1..110}; echo

  local seat claims_str state detail
  for seat in "${seats[@]}"; do
    claims_str="${by_seat[$seat]:-}"
    if [[ -z "$claims_str" ]]; then
      IFS=$'\t' read -r state detail < <(seat_bare_state "$seat")
      printf '%-14s %-10s %-30s %s\n' "$seat" "$state" "(none)" "$detail"
      continue
    fi
    for canon in $claims_str; do
      IFS=$'\t' read -r state detail < <(claim_state "$canon")
      printf '%-14s %-10s %-30s %s\n' "$seat" "$state" "$canon" "$detail"
    done
  done
}
