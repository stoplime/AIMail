# shellcheck shell=bash
# mail.sh — compose, deliver, acknowledge, archive.
#
# ═══ THE DELIVERY STATE MACHINE ═══════════════════════════════════════════════
#
#     send                poll                    ack
#   ──────────>  inbox  ────────>  unacked/  ────────>  archive/YYYY-MM/
#                  ▲                   │
#                  └───────────────────┘
#                   re-surfaced on the next poll, forever, until acked
#
# ⛔⛔ THE ARCHITECTURAL DEFECT THIS REPLACES (FI-01): the previous poller printed
#    a mail's content and moved it to `archive/` IN ONE STEP. If the consuming
#    agent never opened that task output, the mail was archived **unread**, with
#    no trace that it was missed. It happened to a stop-work notice, and the seat
#    kept building descoped code for fifteen minutes.
#
# ⭐ THE FIX IS THAT `archive/` IS NO LONGER REACHABLE BY DELIVERY. Only an
#    explicit `aimail ack` moves a message there. Anything delivered but not
#    acked sits in `unacked/` and is RE-PRINTED by every subsequent poll.
#    ⇒ A delivery that nobody read is now self-healing rather than silent, and
#      this also closes the detached-poller gap: a poller nobody is waiting on
#      can no longer consume mail, because it cannot ack.

# ─── Compose ──────────────────────────────────────────────────────────────────
# ⛔⛔ THE BODY IS NEVER TOUCHED BY THE SHELL (FI-06 / FI-25).
#    A mail was once composed with an UNQUOTED heredoc (`<<EOF`), so the shell
#    expanded `$(...)` and backticks INSIDE THE BODY and the write died partway
#    through each fenced code block. Headings and the signature survived; every
#    piece of evidence vanished — so it read as *asserted without measurement*
#    rather than as *damaged*. The author's own delivery check reported "5/5"
#    because it counted FILES.
# ⇒ Bodies arrive here by `--body-file` or stdin. There is no `--body` string
#   argument, deliberately: the interface makes the unsafe form unavailable.

mail_send() {
  local -a to=()
  local from="" subject="" body_file="" allow_pronouns=0 force=0

  while (( $# )); do
    case "$1" in
      -h|--help)
        info "usage: aimail send --to <seat> [--to <seat>...] --from <seat> --subject <s> --body-file <p>"
        info "  Body may also arrive on stdin in place of --body-file. Nothing was sent."
        exit 0 ;;
      --to)        to+=("$2"); shift 2 ;;
      --from)      from="$2"; shift 2 ;;
      --subject)   subject="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --broadcast-second-person-ok) allow_pronouns=1; shift ;;
      --force)     force=1; shift ;;
      --date|--time|--timestamp)
        # ⛔ FI-07. Every HH:MM in one seat's record was once ~7.5 HOURS fast
        #    because timestamps were invented rather than read; a second seat
        #    then advanced ITS clock from those headers, so the drift GREW
        #    between seats. Two invented numbers consistent with each other
        #    cannot be caught by inspection.
        refused "a caller may not supply a timestamp." \
          "aimail stamps every message from the system clock, precisely so that" \
          "a remembered or estimated time can never enter the record." ;;
      --body)
        refused "there is no --body string argument, by design." \
          "A body passed as a shell argument has already been through word" \
          "splitting and expansion before aimail sees it. A mail composed that" \
          "way once lost every fenced code block in it and still delivered." \
          "" \
          "  aimail send --to X --from Y --subject Z --body-file ./msg.md" \
          "  aimail send --to X --from Y --subject Z < ./msg.md" ;;
      *) refused "unknown argument to send: '$1'" \
          "Unknown verbs and flags are refused rather than ignored: a tool that" \
          "silently drops an argument it does not recognise will one day drop" \
          "the recipient." ;;
    esac
  done

  [[ -n "$from" ]]    || refused "--from is required." \
    "A message with no machine-resolvable sender silently empties every 'what did" \
    "this seat send?' query. 118 of 122 messages once omitted it, so that query" \
    "returned ZERO while the seat had in fact sent 122."
  (( ${#to[@]} )) || refused "at least one --to is required."
  [[ -n "$subject" ]] || refused "--subject is required."

  # The sender must itself be registered — otherwise a reply has nowhere to go.
  from="$(seat_resolve "$from")" || exit $?

  # ⛔ R6(h) SENDER IDENTITY (2026-09-23, after two mails sent under a seat's name by processes that
  #   were not the seat's own turn): when the calling process carries a session id AND the seat
  #   record names a registered session, they must agree. A ghost of a superseded session, a twin,
  #   or a session writing as another seat is refused here, by name. FAIL-OPEN, on purpose: no
  #   session id in the environment (cron, a human's shell, a script) or no seat record (a seat
  #   that never confirmed) changes nothing. A fork or subagent inside the seat's own process
  #   inherits the seat's session id and is NOT distinguishable here -- the fleet rule against
  #   forks remains the control for that case; this check does not claim to cover it.
  #   AIMAIL_SEND_IDENTITY_CHECK=0 is the kill switch (default on; never a dark switch).
  if [[ "${AIMAIL_SEND_IDENTITY_CHECK:-1}" != "0" ]]; then
    local _snd_sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" _snd_rec="$STATE_DIR/seat_account/$from" _snd_rsid=""
    if [[ -n "$_snd_sid" && -f "$_snd_rec" ]]; then
      _snd_rsid="$(awk -F'\t' '$1=="session_id"{print $2; exit}' "$_snd_rec")"
      if [[ -n "$_snd_rsid" && "$_snd_rsid" != "$_snd_sid" ]]; then
        refused "send: this session (${_snd_sid:0:8}) is NOT the registered '$from' session (${_snd_rsid:0:8}) -- not sending under that name." \
          "A mail must come from the seat's own registered session (aimail seat sessions $from)." \
          "If THIS session is the seat now: aimail seat confirm $from --model <id>  (from this session), then resend." \
          "If this is a superseded or twin session: stop; it does not speak for the seat." \
          "Kill switch, a human's decision only: AIMAIL_SEND_IDENTITY_CHECK=0."
      fi
    fi
  fi

  # Body: file or stdin. Never an argument.
  local body; body="$(mktemp "$AIMAIL_ROOT/tmp/body.XXXXXX")"
  if [[ -n "$body_file" ]]; then
    [[ -f "$body_file" ]] || { rm -f "$body"; refused "--body-file '$body_file' does not exist."; }
    cat -- "$body_file" > "$body"
  else
    [[ -t 0 ]] && { rm -f "$body"; refused "no body given." \
      "Pass --body-file <path>, or pipe the body on stdin."; }
    cat > "$body"
  fi
  [[ -s "$body" ]] || { rm -f "$body"; refused "the body is empty — nothing was sent."; }

  # ⛔⛔ CANONICALIZE THE TRAILING NEWLINE HERE, ONCE, AT INTAKE — never weaken the
  # integrity comparison downstream instead (fable's ruling, 2026-08-31). The source
  # sha below is computed on these raw bytes, but the post-delivery integrity check
  # (line ~198) re-extracts the body via `awk 'seen>=2{print}...'`, and awk's own ORS
  # always appends a trailing newline to the last printed record regardless of
  # whether the input had one — so a body file missing its final newline round-trips
  # with one EXTRA byte the source digest never saw, and "INTEGRITY FAILURE ...
  # digest != source digest" fired 100% of the time. Appending it here, before the
  # source digest is ever computed, makes the source and the awk-recovered copy
  # agree by construction for every body from now on — the comparison itself stays
  # exactly as strict as it was.
  [[ "$(tail -c1 "$body")" == $'\n' ]] || printf '\n' >> "$body"

  _check_body_integrity "$body" "$force" || { rm -f "$body"; exit 3; }

  # ─── §2.4b — second person requires exactly one addressee ──────────────────
  # A correction was once broadcast to five seats subject-lined "Your 'nobody
  # read it' claim…" with a header of only `from:`. One seat resolved "Your" to
  # itself, grepped every mail it had sent, and had to write back proving it had
  # never made the claim — the author was a third seat. The recipient did not
  # misremember; THE MAIL GAVE THEM NO OTHER REFERENT.
  # ⚠ Broadcast itself is fine and often right. What breaks is the PRONOUN.
  if (( ${#to[@]} > 1 && allow_pronouns == 0 )) && grep -qiE '(^|[^[:alnum:]])(you|your|yours|you'"'"'re)([^[:alnum:]]|$)' "$body"; then
    rm -f "$body"
    refused "second-person pronouns in a message addressed to ${#to[@]} seats." \
      "'you' and 'your' have no unambiguous referent in a broadcast, and a reader" \
      "will resolve them to themselves. Either:" \
      "  • rewrite in the third person ('nobody in the chain read it'), or" \
      "  • send separately to each seat, or" \
      "  • pass --broadcast-second-person-ok if the referent is genuinely clear."
  fi

  # ─── §2.4c — a GREEN verdict must name its producer and consumer ───────────
  # The ecosystem check ("the dead bear rule"): a feature was once built,
  # unit-tested and approved GREEN while reading an input field that no stage
  # ever wrote — it could never have fired. Nobody had named, at gate time,
  # the file:line that produces each new input the change reads or the
  # file:line that consumes each new output it writes. An input with no
  # producer, or an output with no consumer, is a design question, not a
  # detail to fix later — so a GREEN verdict is refused here until it says so.
  # Docs-only gates are exempt: they carry no producer or consumer to name.
  # A code-change GREEN must also carry a Fleet tests: line (see below).
  # ⚠ CASE-SENSITIVE, uppercase GREEN only, and a hyphen does NOT count as a word
  # boundary here (unlike the pronoun guard's own [^[:alnum:]] test above) — a real
  # verdict is always shouted in full caps ("GATE GREEN", "-- GREEN"), but ordinary
  # prose routinely both lower-cases and hyphen-compounds this exact word ("blue-green",
  # "green-light", "evergreen", "greenfield"). The old case-insensitive, hyphen-as-boundary
  # test matched "green" inside "blue-green" and refused two real, non-verdict subjects
  # in one week (2026-09-28) before this fix.
  if [[ "${AIMAIL_SEND_GREEN_GUARD:-1}" != "0" ]] \
     && grep -qE '(^|[^A-Za-z-])GREEN([^A-Za-z-]|$)' <<<"$subject"; then
    local _has_docs_only=0 _has_producer=0 _has_consumer=0
    grep -qE '^Docs-only:[[:space:]]*[^[:space:]]' "$body" && _has_docs_only=1
    grep -qE '^Producer:[[:space:]]*[^[:space:]]'  "$body" && _has_producer=1
    grep -qE '^Consumer:[[:space:]]*[^[:space:]]'  "$body" && _has_consumer=1
    if (( _has_docs_only == 0 )) && (( _has_producer == 0 || _has_consumer == 0 )); then
      rm -f "$body"
      local _missing
      if (( _has_producer == 0 && _has_consumer == 0 )); then
        _missing="a Producer: line and a Consumer: line"
      elif (( _has_producer == 0 )); then
        _missing="a Producer: line"
      else
        _missing="a Consumer: line"
      fi
      refused "a GREEN subject needs $_missing (or a Docs-only: line) in the body." \
        "A GREEN verdict is refused unless the body names both the producer and" \
        "the consumer it verified — the file:line that really writes each new" \
        "input this change reads, and the file:line that really reads each new" \
        "output it writes — or states Docs-only: for a gate with neither." \
        "" \
        "  Producer: path/to/file.py:42" \
        "  Consumer: path/to/other_file.py:17" \
        "  (verdict text follows)" \
        "" \
        "Kill switch, a human's decision only: AIMAIL_SEND_GREEN_GUARD=0."
    fi
    # ─── the fleet-tests line (R-009) ──────────────────────────────────
    # An approval of a code change names the fleet-test run it stands on. On
    # 2026-09-30 a Platform approval went out without one, and the fleet
    # registry-isolation test then failed on the very commit it approved. A
    # Docs-only: gate has no code to run them on; every other GREEN says either
    # that run_fleet_tests.py passed at the gated sha (paste its summary line) or
    # `Fleet tests: n/a` with the reason (a change outside the Platform tree).
    if (( _has_docs_only == 0 )) \
       && ! grep -qE '^Fleet tests:[[:space:]]*(n/a|.*run_fleet_tests)' "$body"; then
      rm -f "$body"
      refused "a GREEN subject on a code change needs a Fleet tests: line in the body." \
        "The approval has to say what the fleet suite did on the exact tree:" \
        "" \
        "  Fleet tests: run_fleet_tests.py --fast passed at <full sha>: Ran N tests, OK" \
        "  Fleet tests: n/a, <why: e.g. an AIMail change, nothing in the Platform tree>" \
        "" \
        "A Docs-only: line is exempt. Kill switch, a human's decision only: AIMAIL_SEND_GREEN_GUARD=0."
    fi
  fi

  # ─── §2.4d — a WORK mail must cite the ask it works on (drop-prevention guard 3) ─────────
  # A mail that hands a seat work ("Task: …", "Assignment: …") with no ledger id is work the
  # ledger cannot see: if the thread is crowded out nothing brings it back, and the owner's ask
  # it came from has no pointer to it. So a send whose SUBJECT announces work is refused unless
  # its subject or body cites a ledger id (k#### from `aimail ask add`, or an imported a##) that
  # exists and is still open. Only the subject triggers the guard; mails that merely discuss work
  # are untouched. AIMAIL_WORK_SUBJECT_RE names the work prefixes (extended regex, case-insensitive).
  # Kill switch, a human's decision only: AIMAIL_WORK_MAIL_GUARD=0.
  if [[ "${AIMAIL_WORK_MAIL_GUARD:-1}" != "0" ]] \
     && grep -qiE "${AIMAIL_WORK_SUBJECT_RE:-^[[:space:]]*(new )?(task|assignment|assign|work request)[[:space:]]*[:—–-]}" <<<"$subject"; then
    source "$(dirname "${BASH_SOURCE[0]}")/ask.sh"
    local _cited _id _row _st _good="" _bad=""
    _cited="$( { printf '%s\n' "$subject"; cat "$body"; } \
      | grep -oE '(^|[^[:alnum:]])(k[0-9]{4}|a[0-9]{2,3})([^[:alnum:]]|$)' \
      | grep -oE 'k[0-9]{4}|a[0-9]{2,3}' | sort -u )"
    for _id in $_cited; do
      _row="$(_ask_row "$_id")"
      _st="$(_ask_field "$_row" 8)"
      if [[ -n "$_row" && ( "$_st" == "open" || "$_st" == "waiting_owner" ) ]]; then _good="$_good $_id"
      else _bad="$_bad $_id"; fi
    done
    if [[ -z "$_good" ]]; then
      rm -f "$body"
      if [[ -n "$_bad" ]]; then
        refused "a work mail must cite an OPEN ask, and none of the ids it names is one:${_bad}." \
          "An id that is not in the ledger, or whose ask is already done or withdrawn, gives the work no home." \
          "  aimail ask list --all   (find the right id)   |   aimail ask add …   (open a new ask)" \
          "Kill switch, a human's decision only: AIMAIL_WORK_MAIL_GUARD=0."
      else
        refused "a work mail (subject '${subject:0:50}…') must cite the ledger ask it works on." \
          "Put the id (k####, or an imported a##) in the subject or the body:" \
          "  aimail ask list          (find the ask this work belongs to)" \
          "  aimail ask add --owner <seat> --quote \"<the owner's words>\" --next \"<step>\" --check '<predicate>'" \
          "A send that assigns work without a ledger id is work the ledger cannot see or chase." \
          "Kill switch, a human's decision only: AIMAIL_WORK_MAIL_GUARD=0."
      fi
    fi
  fi

  # ─── One file per recipient (§2.4) ─────────────────────────────────────────
  # ⛔ A `cc:` line delivers NOTHING — it is text inside one recipient's file.
  #    122 messages were once sent with a cc: header and the intended readers
  #    received none of them. N recipients means N files, and the tool does the
  #    fan-out so a sender cannot get it wrong.
  local stamp iso slug id sha bytes
  stamp="$(now_stamp)"; iso="$(now_iso)"
  slug="$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]' \
          | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//' | cut -c1-60)"
  sha="$(sha256sum < "$body" | cut -d' ' -f1)"
  bytes="$(wc -c < "$body" | tr -d ' ')"

  local -a resolved=() delivered=()
  local t; for t in "${to[@]}"; do resolved+=("$(seat_resolve "$t")") || exit $?; done

  for t in "${resolved[@]}"; do
    id="${stamp}-${from}-${slug}"
    # ⛔⛔ CLAIM THE PATH ATOMICALLY, AND LOOK IN ALL THREE PLACES AN ID CAN LIVE.
    # WHY: the id is (second, from, subject-slug), so two sends in the same second
    # collide. The old code probed only the INBOX with `[[ -e ]]` and wrote later —
    # a check-then-write race. Measured here at 2-way concurrency: 12/12 trials
    # ended with an EMPTY inbox. Not "one lost" — BOTH destroyed, because the
    # loser's integrity check re-read the WINNER's body, mismatched, and removed it.
    # A message also lives on in unacked/ and archive/<shard>/, so a path free in the
    # inbox is not proof the id is unused.
    #
    # ⛔⛔ SENDER-VS-DELIVERER (found 2026-09-10, poll-persistent pilot): the fix for
    # the above (noclobber-touch an EMPTY file to claim the path, fill it in
    # afterward via `atomic_write`) is atomic against another SENDER but not against
    # a concurrent DELIVERER — `mail_deliver` treats any file it can `cat` as real
    # mail, and an empty file `cat`s successfully (exit 0, prints nothing). A
    # deliverer that reads the claimed-but-not-yet-filled path in that gap moves the
    # EMPTY file into unacked/ and counts it delivered; when this sender's own fill
    # step later runs, the destination no longer has anything there to overwrite (the
    # deliverer took it), so the fill just recreates the path fresh with the real
    # content — leaving a permanently-empty orphan in unacked/ and the real content
    # stranded, unmoved, back in the inbox. Reproduced deterministically (forced delay
    # in the claim->fill gap, 20/20 trials empty in the fixed version's absence) —
    # confirmed live 2026-09-10 17:10 on a real send (`20260910T171046-...`), 0 bytes
    # in unacked/, full content landed back in the inbox under the same id.
    # FIX: build the full, final content in a temp file FIRST — nothing is visible
    # under the candidate name yet, no matter how long composing it takes — then
    # claim the path with `ln`: one syscall that either creates the name WITH its
    # full content already present, or fails EEXIST leaving nothing behind. There is
    # no intermediate state left for a concurrent deliverer to observe, which closes
    # this regardless of why any particular send was slow between claim and fill (the
    # same pattern Maildir delivery uses: write to a temp name, `link` it into place).
    local dest="" n=0 claimed=0 tries=0 tmp=""
    while (( tries++ < 1000 )); do        # FI-61: bounded — never spin on an unwritable inbox
      local cand="$MAIL_DIR/$t/${id}${n:+-$n}.md" base
      base="$(basename "$cand" .md)"
      if [[ -e "$cand" ]] \
         || [[ -e "$MAIL_DIR/$t/unacked/$base.md" ]] \
         || compgen -G "$MAIL_DIR/$t/archive/*/$base.md" >/dev/null 2>&1; then
        n=$((n+1)); continue
      fi
      # Build this candidate's full content (the id: line embeds its own basename)
      # before anything is visible under that name at all.
      tmp="$(mktemp "$MAIL_DIR/$t/.tmp.XXXXXX" 2>/dev/null)" || {
        rm -f "$body"
        die "cannot write to seat '$t' inbox ($MAIL_DIR/$t) — unwritable or disk-full; aborted (FI-61). Recipients before '$t' may already be delivered (FI-60)."
      }
      {
        printf -- '---\n'
        printf 'id: %s\n' "$base"
        printf 'from: %s\n' "$from"
        printf 'to: %s\n' "$t"
        printf 'date: %s\n' "$iso"
        printf 'subject: %s\n' "$subject"
        printf 'body-sha256: %s\n' "$sha"
        printf 'body-bytes: %s\n' "$bytes"
        (( ${#resolved[@]} > 1 )) && printf 'broadcast-to: %s\n' "$(IFS=,; echo "${resolved[*]}")"
        printf -- '---\n\n'
        cat "$body"
      } > "$tmp"
      # Atomic create-if-absent — the ONLY test-and-claim that is atomic between
      # processes AND leaves no empty-visible window: `ln` either creates $cand with
      # this content already in place, or fails EEXIST and creates nothing.
      if ln "$tmp" "$cand" 2>/dev/null; then
        rm -f "$tmp"; dest="$cand"; claimed=1; break
      fi
      # FI-61: the link failed though the path was free a moment ago. If $cand EXISTS
      # now it was a race (another sender claimed it between our -e check and the
      # link) -> retry. If it still does NOT exist, the inbox itself cannot be
      # written (unwritable dir / disk-full / quota) and retrying would spin FOREVER,
      # hanging the whole send — so fail LOUD instead of wedging the channel every
      # seat depends on.
      # ⚠ CHOSEN TRADEOFF, not an oversight: if a third process REMOVES $cand between the
      # failed link and this re-check, a genuine collision reads as "absent" and we die
      # a spurious FALSE-LOUD. That is the correct direction to err — a spurious failure
      # is recoverable (re-send), a spin is not (it wedges the shared channel) — and the
      # bounded backstop below covers the inverse. DO NOT "fix" this to retry-on-absent:
      # that reintroduces FI-61's infinite spin on a real unwritable/full inbox.
      rm -f "$tmp"
      if [[ ! -e "$cand" ]]; then
        rm -f "$body"
        die "cannot write to seat '$t' inbox ($MAIL_DIR/$t) — unwritable or disk-full; aborted (FI-61). Recipients before '$t' may already be delivered (FI-60)."
      fi
      n=$((n+1))
    done
    # FI-61 backstop — a SECOND, INDEPENDENT guard, and deliberately UNREACHABLE in
    # practice. The discriminator above already fails loud on a real unwritable/full
    # inbox (the path stays absent), so this bound is NOT the protection for that case.
    # It guards a DIFFERENT one: a genuine 1000-deep id-collision storm — 1000 messages
    # sharing the same second+from+subject stem — which cannot occur in practice. That
    # unreachability IS the point: a bound on a formerly-unbounded loop must never spin
    # even in the impossible case. ⛔ NOT dead code — do not delete it as "unreachable".
    [[ $claimed -eq 1 ]] || { rm -f "$body" "$tmp"; die "could not claim a destination for '$t' after 1000 attempts — aborted (FI-61 backstop)."; }

    # ─── Integrity, not existence (FI-06) ────────────────────────────────────
    # The previous delivery check counted FILES and reported 5/5 for mail whose
    # every code block had been deleted. This compares the delivered body's
    # digest against the source's. A delivery count is not an integrity check.
    # FI-54: strip the frontmatter by COUNTING delimiters, not by a sed range. The old
    # `sed -n '/^---$/,/^---$/!p'` re-opened a fresh range on any later bare `---`, so a
    # body containing a horizontal rule had everything after it swallowed -> false digest
    # mismatch -> a correct message deleted, failing closed with a misleading "integrity
    # failure". The frontmatter is always exactly the first TWO `---` lines; print only
    # what follows the 2nd, and a body `---` is body (seen>=2) not a delimiter.
    local got; got="$(awk 'seen>=2{print} /^---$/{seen++}' "$dest" | sed '1{/^$/d}' | sha256sum | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
      # ⛔ Remove ONLY what this process claimed. The old unconditional `rm -f "$dest"`
      # deleted whatever occupied the path; under a race that was another sender's
      # correctly-delivered message. An integrity guard must never destroy a message
      # it did not write.
      [[ $claimed -eq 1 ]] && rm -f "$dest"
      rm -f "$body"
      die "INTEGRITY FAILURE writing to '$t' — delivered body digest != source digest. Nothing left in the inbox."
    fi
    delivered+=("$t:$(basename "$dest")")
  done
  rm -f "$body"

  ok "delivered to ${#delivered[@]} seat(s), ${bytes}B each"
  local d; for d in "${delivered[@]}"; do info "   ${d%%:*}  ${d#*:}"; done
  info "verified: body sha256 ${sha:0:12}… matches in every copy"

  # ─── A DELIVERY TO A SEAT NOBODY READS IS A SILENT SUCCESS ───────────────────
  # Two seats were registered `active` with several queued messages each and no
  # poller had EVER run for either: a send wrote the file, reported delivery and
  # verified the digest, and nothing would ever read it. That is worse than a
  # retired seat, whose state is at least legible — an `active` seat READS AS A
  # LIVE ADDRESS. One message absorbed that way was an operator ruling, broadcast
  # and reported as delivered to the whole fleet.
  # The discriminator is the poller HEARTBEAT FILE, not the ARMED state: a heartbeat
  # exists once a seat has EVER polled and survives the poller exiting on delivery, so
  # this fires on NEVER-READ seats and stays silent for a seat merely between polls.
  # Warning only — it must never affect delivery, which has already completed above.
  local _t _hb
  for _t in "${resolved[@]}"; do
    _hb="$STATE_DIR/poller/${_t}.hb"
    [[ -e "$_hb" ]] && continue
    warn "'${_t}' is registered active but NO POLLER HAS EVER RUN for it — this message was written and will NOT be read. Retire the seat, or start a reader."
  done
}

# _check_body_integrity — catch the corruption signature BEFORE it is delivered.
# An odd number of ``` fences means a code block was left open, which is exactly
# what a shell-expanded heredoc produces when the write dies mid-block.
_check_body_integrity() {
  local body="$1" force="$2" fences
  fences="$(grep -c '^```' "$body" || true)"
  if (( fences % 2 == 1 )); then
    if (( force )); then
      warn "body has $fences code fences (odd — a block is unclosed). Sending anyway: --force."
      return 0
    fi
    refused "the body has $fences \`\`\` fences — an odd count means a code block is UNCLOSED." \
      "This is the signature of a body that was expanded by the shell before" \
      "aimail received it: the write dies partway through a fenced block, and" \
      "the result still looks like a message while every piece of evidence in" \
      "it has vanished." \
      "" \
      "  • If the body was composed with <<EOF, re-compose it with <<'EOF'." \
      "  • If the unbalanced fence is genuinely intended, pass --force."
    return 3
  fi
  return 0
}

# ─── Deliver (called by the poller) ───────────────────────────────────────────
# Prints content, then moves to unacked/. NEVER to archive/.
LAST_DELIVERED_FILE() { echo "$STATE_DIR/last_delivered/$1"; }
# ⛔⛔ AR-24 — REPRINTING THE FULL UN-ACKED BACKLOG ON EVERY WAKE HAS NO ESCAPE HATCH
#   (operator ruling, 2026-08-07). MEASURED on a live supervisor seat: its own
#   `ack` was refused by a permission classifier, so unacked/ could never shrink; every new
#   arrival re-triggered a full reprint of the WHOLE growing backlog (27 and climbing), each
#   one costing more than the last with no way to ever pay it down. ⇒ A seat that cannot ack
#   for ANY reason — refused, crashed mid-ack, wedged — is not merely behind, it becomes
#   PERMANENTLY UNARMABLE: the very rule built to guarantee mail is read (re-print until
#   acked) guarantees the seat is unreachable once acking stops working at all.
# ⭐ THE FIX IS NOT "STOP REPRINTING" (⛔ ruled: that reopens the exact hazard the AR-23
#   receipt guard just closed — mail archived, or now silently dropped, before anyone read
#   it). It separates SHOWN from ACKED: a message's FULL body prints exactly ONCE ever,
#   the first time it is queued. On every later delivery, still un-acked, it is a ONE-LINE
#   entry in a compact summary — visibly still outstanding (②), but at near-zero cost. A
#   seat with 27 un-acked and no ability to ack still gets message 28 in full, cheaply,
#   forever (③) — the backlog's SIZE no longer determines whether the poller can stay useful.
SHOWN_FILE() { echo "$STATE_DIR/shown/$1"; }

# ─── Recent (durable index of ids this seat has SEEN, surviving ack/archive) ──
# ISSUES_2026-08-20.md item 4 (project owner): "showing recent mail should be
# something useful that way you don't need to dig into the thousands of old
# archive mail as soon as it's read once and you need to go back to it." SHOWN_FILE
# above (and `unread`, its reader-facing view) answers "what's still un-acked" and
# is PRUNED to exactly that set — a message drops out the moment it's acked, which
# is precisely when a seat is most likely to need to look back at it. This is a
# separate, durable, append-only log, one line per message ever shown IN FULL
# (never a summary re-print, which would be the same id a second time) — small,
# cheap, local, capped rather than unbounded, and not a search engine or a
# reason to touch the archive tree.
RECENT_MAX_LINES=500
RECENT_FILE() { echo "$STATE_DIR/recent/$1"; }
_recent_record() {
  local seat="$1" f="$2" id from subj rf
  id="$(basename "$f" .md)"
  from="$(sed -n 's/^from: //p' "$f" | head -1)"
  subj="$(sed -n 's/^subject: //p' "$f" | head -1)"
  # One line per record, every reader (mail_recent's own tab-split) assumes
  # stays single-line -- strip embedded tabs/newlines rather than let a
  # pasted multi-line subject silently corrupt that assumption.
  from="${from//$'\t'/ }"; from="${from//$'\n'/ }"
  subj="${subj//$'\t'/ }"; subj="${subj//$'\n'/ }"
  rf="$(RECENT_FILE "$seat")"
  mkdir -p "$(dirname "$rf")"
  { [[ -f "$rf" ]] && cat -- "$rf"
    printf '%s\t%s\t%s\n' "$id" "${from:-?}" "${subj:-(no subject)}"
  } | tail -n "$RECENT_MAX_LINES" > "$rf.tmp"
  mv -f "$rf.tmp" "$rf"
}

mail_deliver() {
  local seat="$1" maxb="${2:-60000}"
  local total=0 shown=0 deferred=0 summarized=0
  local -a shown_names=() summary_names=()

  # Load the persisted "shown" set, then PRUNE it to whatever is still actually in
  # unacked/ right now — anything acked, archived, or otherwise gone drops out on its
  # own, so this file can never grow past unacked/'s own current size.
  mkdir -p "$MAIL_DIR/$seat/unacked"
  local -A already_shown=()
  if [[ -f "$(SHOWN_FILE "$seat")" ]]; then
    local _sn
    while IFS= read -r _sn; do
      [[ -n "$_sn" && -f "$MAIL_DIR/$seat/unacked/$_sn" ]] && already_shown["$_sn"]=1
    done < "$(SHOWN_FILE "$seat")"
  fi

  local -a queue=()
  # Oldest first — mail order is CAUSAL. A retraction must never be read before
  # the claim it retracts. Sorting by mtime rather than filename is the only
  # order that survives a drifted stamp: a retraction whose filename was 6h
  # stale once sorted BELOW older mail and was read after the thing it retracted
  # had already been acted on and committed.
  # ⛔⛔ AR-07 / R-2 — `-type f` here too. This find used to build the queue from
  #   ANY `*.md` dirent, then skip non-regular ones below via `[[ -f "$f" ]]`
  #   with no further action — so a directory named `notes.md` or a broken
  #   symlink stayed in the inbox FOREVER, un-skippable and un-deliverable, and
  #   (before the matching poller.sh fix) kept the wake predicate permanently
  #   non-zero. Filtering here means the queue only ever contains what this
  #   function can actually act on, and the `[[ -f "$f" ]]` below becomes
  #   defense-in-depth rather than the only thing standing between a stray
  #   dirent and an unbounded loop.
  while IFS= read -r f; do [[ -n "$f" ]] && queue+=("$f"); done < <(
    { find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -type f -name '*.md' -printf '%T@\t%p\n' 2>/dev/null
      find "$MAIL_DIR/$seat"         -maxdepth 1 -type f -name '*.md' -printf '%T@\t%p\n' 2>/dev/null
    } | sort -n | cut -f2-
  )

  (( ${#queue[@]} == 0 )) && { info "no mail"; return 0; }

  local f b sz
  for f in "${queue[@]}"; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"
    # ⭐ AR-24 — a message already in the shown-set has been printed in full at least
    #   once, EVER, and is still un-acked. Summarize it, never re-spend tokens on its
    #   body — regardless of the size cap, since a one-line entry costs nothing close
    #   to it. This is what breaks the compounding cost: the summary list grows O(1)
    #   per message, not O(body size), and it is never gated by maxb.
    if [[ -n "${already_shown[$b]:-}" ]]; then
      summarized=$((summarized+1)); summary_names+=("$b")
      continue
    fi
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if (( total > 0 && total + sz > maxb )); then
      deferred=$((deferred+1))
      info "⏸ DEFERRED (over ${maxb}B cap, still queued): $b"
      continue
    fi
    printf '%s\n' "════════════════════════════════════════════════════════════════════"
    printf '📬 %s   (%sB, written %s)\n' "$b" "$sz" "$(date -r "$f" '+%F %H:%M' 2>/dev/null)"
    printf '%s\n' "════════════════════════════════════════════════════════════════════"
    # ⛔ The move happens ONLY if the content printed successfully. Archiving —
    #    or here, advancing the state of — something the reader never saw would
    #    convert "unread mail" into "vanished mail", and the reader would have no
    #    way to detect it: the failure would be invisible and would read as calm.
    if cat -- "$f"; then
      _recent_record "$seat" "$f"
      [[ "$(dirname "$f")" == "$MAIL_DIR/$seat" ]] && mv -f -- "$f" "$MAIL_DIR/$seat/unacked/"
      total=$((total+sz)); shown=$((shown+1)); shown_names+=("$b")
    else
      warn "COULD NOT READ — left in place, not advanced: $b"
    fi
  done

  if (( summarized > 0 )); then
    printf '%s\n' "────────────────────────────────────────────────────────────"
    printf '📎 %s previously-shown message(s) remain UN-ACKED (not re-printed):\n' "$summarized"
    printf '   %s\n' "${summary_names[@]}"
    printf '   Never actually read one (e.g. it was shown by a background `poll`,\n'
    printf '   not to you)? Run `aimail show %s <id>` to re-print it in full.\n' "$seat"
  fi

  # Persist the shown-set: everything just shown in full, plus everything already
  # in it that survived the prune at the top (still un-acked, still known).
  mkdir -p "$(dirname "$(SHOWN_FILE "$seat")")"
  { printf '%s\n' "${shown_names[@]}"; printf '%s\n' "${!already_shown[@]}"; } \
    | sed '/^$/d' | sort -u > "$(SHOWN_FILE "$seat")"

  # ⭐ AR-23 — the delivery RECEIPT `ack --all` checks against. Covers everything this
  #   call told the caller about, in EITHER form (full body or summary line) — a
  #   summarized message was still named, so acking it is still grounded in something
  #   this delivery actually showed, not something the caller merely remembers.
  mkdir -p "$(dirname "$(LAST_DELIVERED_FILE "$seat")")"
  { printf '%s\n' "${shown_names[@]}"; printf '%s\n' "${summary_names[@]}"; } \
    | sed '/^$/d' | sort -u > "$(LAST_DELIVERED_FILE "$seat")"

  printf '%s\n' "════════════════════════════════════════════════════════════════════"
  info "$shown message(s) delivered in full. NOT YET ARCHIVED."
  (( summarized > 0 )) && info "📎 $summarized already-shown message(s) summarized above, not re-printed."
  (( deferred > 0 )) && info "⏸ $deferred deferred (size cap) — they arrive on the next poll."
  info ""
  # ⛔ MODE-AWARE STEP 2 (footer gap, 2026-09-10): a
  # persistent poller (`aimail poll-persistent`, see lib/poller.sh) never exits on mail, so
  # "re-arm" is FALSE under it -- printing it anyway is a real "one definition per kind"
  # violation (fable's own review of 60fb78b): a reader gets two contradictory instructions in
  # one delivery, one from this shared footer, one from `poller_run_persistent`'s own
  # `_persistent_notice` line. `AIMAIL_POLL_PERSISTENT=1` is exported once by
  # `poller_run_persistent` (never by `poller_run`, whose own callers never set it, so the
  # default branch below is byte-identical to before this change for every existing caller).
  if [[ "${AIMAIL_POLL_PERSISTENT:-}" == "1" ]]; then
    info "▶ ONE STEP required (this poller is PERSISTENT -- do not re-arm, it is still watching):"
    info "    1. aimail ack $seat --all      (after you have acted on them)"
  else
    info "▶ TWO STEPS, both required:"
    info "    1. aimail ack $seat --all      (after you have acted on them)"
    info "    2. aimail poll $seat           (re-arm; background task)"
  fi
  info ""
  info "⚠ A message's FULL BODY prints exactly once. Still un-acked after that, it is a"
  info "  one-line summary on every later poll — visible, but never re-spent in full."
  return 0
}

# ─── Show (re-print a specific message, full body, unconditionally) ──────────
# ⛔⛔ AR-25 — "SHOWN EXACTLY ONCE" HAD NO RECOVERY PATH WHEN THE ONE SHOWING WAS
#   MISSED (audit, 2026-08-07 12:03). `aimail poll <seat>` is a harness-tracked
#   BACKGROUND task: the body it prints lands in the task's OWN output file, not
#   in the calling session's context — the seat is notified the task finished,
#   it is not hand-delivered the content. If the seat then runs only the
#   documented read path (`aimail deliver <seat>`) expecting to see it, it gets
#   a one-line summary instead — the message was genuinely SHOWN (bytes left
#   the process), just not to a reader who was there to receive them. MEASURED:
#   this ate a gate approval and an authoring notice inside 15 minutes;
#   both were recoverable only by reading unacked/ off disk by hand, which is
#   not a documented command. ⇒ `show` closes that gap directly: it re-prints
#   ONE message's full body, unconditionally, regardless of shown-state — the
#   summary line below now names it explicitly, so recovery never requires
#   knowing the mailbox's on-disk layout.
#
# ⭐ unreadmailtoolfix (architect/fable, 2026-09-01) — a report of mail "archived
#   unread" turned out to have TWO distinct candidate causes that look identical
#   from the reader's side: aimail's own delivery path silently dropping bytes
#   (this file's problem), or a display/rendering layer above it (resume banner,
#   task-notification replay) truncating what aimail already wrote in full (not
#   this file's problem — outside this code's reach). Two repro experiments this
#   date found aimail's own batch-cap and shown-set bookkeeping intact at up to
#   96KB in one message; the reported 34KB cut was never reproduced here and the
#   original session was gone by the time of the dig — inconclusive either way.
#   ⇒ THE DISCRIMINATING CHECK, for whoever hits this next: the moment a large
#   delivery looks cut, `wc -c` the task's OWN OUTPUT FILE on disk and compare
#   against what the session actually displayed. File complete + display cut =
#   rendering layer, harness territory. File itself cut = this file's delivery
#   path, and worth reopening as a real aimail bug. One command settles which
#   layer owns it — run it before assuming either side.
mail_show() {
  local seat="$1" id="$2"
  local p="$id"; [[ "$p" == *.md ]] || p="$p.md"
  local f
  for f in "$MAIL_DIR/$seat/unacked/$p" "$MAIL_DIR/$seat/$p" "$MAIL_DIR/$seat"/archive/*/"$p"; do
    if [[ -f "$f" ]]; then
      cat -- "$f"
      return 0
    fi
  done
  refused "no message '$id' found for seat '$seat' (checked unacked/, inbox, archive/)." \
    "  aimail status $seat   shows what is currently outstanding"
}

# ─── Unread (list, don't just count, what's still un-acked) ──────────────────
# ⛔⛔ `status` gives a bare COUNT of un-acked mail; recovering from a missed
#   showing (AR-25) still meant listing unacked/ off disk by hand to find an id
#   to pass to `show` — "spelunking" (fable, 2026-09-01 ruling on unread-mail).
#   ⇒ This is that index: id, sender, subject, size, age, oldest first — the
#   exact set `show <seat> <id>` can act on, with nothing to grep for by hand.
mail_unread() {
  local seat="$1"
  local dir="$MAIL_DIR/$seat/unacked"
  local -a files=()
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(
    find "$dir" -maxdepth 1 -type f -name '*.md' -printf '%T@\t%p\n' 2>/dev/null | sort -n | cut -f2-
  )
  if (( ${#files[@]} == 0 )); then
    info "no un-acked mail for '$seat'."
    return 0
  fi
  info "${#files[@]} un-acked message(s) for '$seat' (oldest first):"
  local f b sz from subj
  for f in "${files[@]}"; do
    b="$(basename "$f" .md)"
    sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    from="$(sed -n 's/^from: //p' "$f" | head -1)"
    subj="$(sed -n 's/^subject: //p' "$f" | head -1)"
    printf '  %-58s  %6sB  from %-14s %s\n' "$b" "$sz" "${from:-?}" "${subj:-(no subject)}"
  done
  info ""
  info "▶ aimail show $seat <id>   re-prints one in full, unconditionally."
}

# ─── Recent (what this seat has SEEN lately, acked or not) ───────────────────
# ISSUES_2026-08-20.md item 4. Companion to `unread` above: `unread` is the
# live un-acked queue and empties the instant a message is acked; `recent` is
# the durable log `_recent_record` (see RECENT_FILE above) appends to on every
# first-time full showing, so a message already acted on and archived hours
# ago is still findable here — recovery is `aimail recent <seat>` -> pick an
# id -> `aimail show <seat> <id>`, never "remember which background-task
# output happened to print it."
mail_recent() {
  local seat="$1" n="${2:-20}"
  case "$n" in
    '' | *[!0-9]*) refused "N must be a positive integer, got '$n'" ;;
  esac
  (( n > 0 )) || refused "N must be a positive integer, got '$n'"
  local rf; rf="$(RECENT_FILE "$seat")"
  if [[ ! -s "$rf" ]]; then
    info "no recent mail recorded yet for '$seat'."
    return 0
  fi
  local -a lines=()
  while IFS= read -r l; do [[ -n "$l" ]] && lines+=("$l"); done < <(tail -n "$n" -- "$rf")
  info "last ${#lines[@]} message(s) '$seat' has seen (most recent first):"
  local i id from subj
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    IFS=$'\t' read -r id from subj <<<"${lines[$i]}"
    printf '  %-58s  from %-14s %s\n' "$id" "${from:-?}" "${subj:-(no subject)}"
  done
  info ""
  info "▶ aimail show $seat <id>   re-prints one in full, unconditionally."
}

# ─── Acknowledge ──────────────────────────────────────────────────────────────
# ⛔⛔ AR-23 — `ack --all` used to sweep EVERY file in unacked/ unconditionally.
#   unacked/ is re-printed on every `deliver`, but nothing tied THIS ack to a
#   delivery that had just shown the SAME set — a caller could run `ack --all`
#   in a fresh context long after the actual reading happened (or never
#   happened at all: acked from a subject-line grep, not from what was on
#   screen), and it archived silently. MEASURED: a hard blocker report lost
#   for 100 minutes, twice. ⇒ --all now requires a RECENT delivery RECEIPT
#   (written by mail_deliver every call) whose file set matches unacked/
#   EXACTLY. Acking by explicit id is unaffected — naming an id already is
#   the claim you read that one — and --force still allows a deliberate sweep.
#
# ⛔⛔ AR-28 (project owner, 2026-09-03) — AR-23's receipt check only proves a
#   delivery just happened, not that anything was read. A caller (human or
#   agent) that mechanically chains `poll` → `ack --all` as a fixed idiom
#   satisfies AR-23 every time without ever attending to the content — MEASURED
#   live in this fleet the same morning this was written. ⇒ `--all` now also
#   requires `--sha <prefix>[,<prefix>...]` naming an 8+ hex-char prefix of
#   EVERY target's own `body-sha256`, one prefix per target (order-independent,
#   duplicates collapse). The prefix is not printable proof of comprehension —
#   nothing mechanical can be — but it cannot be produced without opening the
#   actual delivered content (the header of each message, at minimum) and
#   copying a value out of it, which a fixed muscle-memory idiom cannot do.
#   `--force` still bypasses this too, as a deliberate, nameable "sweep it
#   unread" — never the default path.
mail_ack() {
  local seat="$1"; shift
  local unacked="$MAIL_DIR/$seat/unacked"
  local force=0 sha_arg=""
  local -a rest=()
  local a prev=""
  for a in "$@"; do
    if [[ "$prev" == "--sha" ]]; then sha_arg="$a"; prev=""; continue; fi
    case "$a" in
      --force) force=1 ;;
      --sha)   prev="--sha" ;;
      --sha=*) sha_arg="${a#--sha=}" ;;
      *)       rest+=("$a") ;;
    esac
  done
  set -- "${rest[@]}"

  local -a targets=()
  if [[ "${1:-}" == "--all" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && targets+=("$f"); done \
      < <(find "$unacked" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
    if (( force == 0 )) && (( ${#targets[@]} > 0 )); then
      local receipt; receipt="$(LAST_DELIVERED_FILE "$seat")"
      local cur have age ttl
      cur="$(printf '%s\n' "${targets[@]##*/}" | sort)"
      have=""; [[ -f "$receipt" ]] && have="$(sort "$receipt")"
      ttl="${AIMAIL_ACK_TTL:-600}"
      age=999999
      [[ -f "$receipt" ]] && age=$(( $(now_epoch) - $(stat -c %Y "$receipt" 2>/dev/null || echo 0) ))
      if [[ "$cur" != "$have" ]] || (( age > ttl )); then
        refused "'$seat' ack --all does not match a recent delivery — refusing to archive unread mail." \
          "  What's in unacked/ right now must have been shown by a 'deliver' in the" \
          "  last ${ttl}s, exactly. Run 'aimail deliver $seat' to see the current set," \
          "  then ack — or 'aimail ack $seat --all --force' to sweep it unread."
      fi

      # AR-27: every target's body-sha256 prefix must be named explicitly.
      local -a want_shas=() missing=()
      local f fsha
      for f in "${targets[@]}"; do
        fsha="$(sed -n 's/^body-sha256: //p' "$f" | head -1)"
        want_shas+=("$fsha")
      done
      local -a given=()
      IFS=',' read -r -a given <<< "${sha_arg// /}"
      local i matched
      for i in "${!want_shas[@]}"; do
        matched=0
        local g
        for g in "${given[@]}"; do
          [[ -n "$g" ]] && [[ "${want_shas[$i]}" == "$g"* ]] && { matched=1; break; }
        done
        (( matched == 0 )) && missing+=("$(basename "${targets[$i]}" .md)  sha=${want_shas[$i]:0:12}…")
      done
      if (( ${#missing[@]} > 0 )); then
        refused "'$seat' ack --all is missing --sha for ${#missing[@]} message(s) — refusing to archive unread mail." \
          "  Naming a message's own body-sha256 prefix is the claim you opened it. Missing:" \
          "$(printf '    %s\n' "${missing[@]}")" \
          "  Re-run with, e.g.: aimail ack $seat --all --sha <sha1>,<sha2>,…" \
          "  or 'aimail ack $seat --all --force' to sweep it unread, deliberately."
      fi
    fi
  else
    local id; for id in "$@"; do
      local p="$unacked/$id"; [[ "$p" == *.md ]] || p="$p.md"
      [[ -f "$p" ]] || refused "no un-acked message '$id' for seat '$seat'." \
        "  aimail status $seat   shows what is awaiting acknowledgement"
      targets+=("$p")
    done
  fi

  (( ${#targets[@]} == 0 )) && { info "nothing awaiting acknowledgement for '$seat'"; return 0; }

  # Archive is sharded by month. 13,327 messages in flat directories is what the
  # previous system reached in five weeks, and every `ls` over it got slower.
  local shard="$MAIL_DIR/$seat/archive/$(date '+%Y-%m')"
  mkdir -p "$shard"
  local f n=0
  for f in "${targets[@]}"; do
    # ⚠ `mv` preserves mtime, so an archived message's mtime remains its WRITE
    #   time and its ctime becomes the move time. Both are meaningful and a
    #   consumer needs to know which it is reading.
    mv -f -- "$f" "$shard/" && n=$((n+1))
  done
  ok "acknowledged and archived $n message(s) → $shard"
}

# ─── Delivery check — state, never a count (FI-05) ────────────────────────────
# `ls <seat>/*.md | wc -l` returns 0 both when mail was delivered and consumed
# and when it was NEVER WRITTEN. Those are opposite facts. This reports WHICH.
mail_where() {
  local seat="$1" pattern="${2:-}"
  local -a hits=()
  local d state
  for d in "$MAIL_DIR/$seat:INBOX (undelivered)" \
           "$MAIL_DIR/$seat/unacked:DELIVERED, NOT ACKED" ; do
    state="${d#*:}"
    while IFS= read -r f; do
      [[ -n "$f" ]] && hits+=("$state|$f")
    done < <(find "${d%%:*}" -maxdepth 1 -name "*${pattern}*.md" 2>/dev/null)
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] && hits+=("ACKED, ARCHIVED|$f")
  done < <(find "$MAIL_DIR/$seat/archive" -name "*${pattern}*.md" 2>/dev/null)

  if (( ${#hits[@]} == 0 )); then
    # Not "0 messages" — a claim about where we looked.
    unmeasurable "no message matching '${pattern}' anywhere in seat '$seat'" \
      "Searched: inbox, unacked/, and every archive shard." \
      "This means NO FILENAME matched the pattern — NOT that the seat is empty. The pattern" \
      "is a filename GLOB, not a regex: use '' to match everything; a bare '.' matches only" \
      "names with a literal dot (usually just the .md), so it finds nothing on a full inbox." \
      "If you expected a hit, widen the pattern or check the resolved recipient: aimail seat list"
  fi
  local h
  for h in "${hits[@]}"; do
    printf '%-22s %s\n' "${h%%|*}" "$(basename "${h#*|}")"
  done
  info ""
  info "${#hits[@]} match(es) for '${pattern}' in seat '$seat'"
}
