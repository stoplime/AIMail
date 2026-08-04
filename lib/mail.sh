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
    local dest="$MAIL_DIR/$t/$id.md" n=1
    while [[ -e "$dest" ]]; do dest="$MAIL_DIR/$t/${id}-$n.md"; n=$((n+1)); done
    {
      printf -- '---\n'
      printf 'id: %s\n' "$(basename "$dest" .md)"
      printf 'from: %s\n' "$from"
      printf 'to: %s\n' "$t"
      printf 'date: %s\n' "$iso"
      printf 'subject: %s\n' "$subject"
      printf 'body-sha256: %s\n' "$sha"
      printf 'body-bytes: %s\n' "$bytes"
      (( ${#resolved[@]} > 1 )) && printf 'broadcast-to: %s\n' "$(IFS=,; echo "${resolved[*]}")"
      printf -- '---\n\n'
      cat "$body"
    } | atomic_write "$dest"

    # ─── Integrity, not existence (FI-06) ────────────────────────────────────
    # The previous delivery check counted FILES and reported 5/5 for mail whose
    # every code block had been deleted. This compares the delivered body's
    # digest against the source's. A delivery count is not an integrity check.
    local got; got="$(sed -n '/^---$/,/^---$/!p' "$dest" | sed '1{/^$/d}' | sha256sum | cut -d' ' -f1)"
    if [[ "$got" != "$sha" ]]; then
      rm -f "$dest"
      rm -f "$body"
      die "INTEGRITY FAILURE writing to '$t' — delivered body digest != source digest. Nothing left in the inbox."
    fi
    delivered+=("$t:$(basename "$dest")")
  done
  rm -f "$body"

  ok "delivered to ${#delivered[@]} seat(s), ${bytes}B each"
  local d; for d in "${delivered[@]}"; do info "   ${d%%:*}  ${d#*:}"; done
  info "verified: body sha256 ${sha:0:12}… matches in every copy"
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
mail_deliver() {
  local seat="$1" maxb="${2:-60000}"
  local total=0 shown=0 deferred=0
  mkdir -p "$MAIL_DIR/$seat/unacked"

  local -a queue=()
  # Oldest first — mail order is CAUSAL. A retraction must never be read before
  # the claim it retracts. Sorting by mtime rather than filename is the only
  # order that survives a drifted stamp: a retraction whose filename was 6h
  # stale once sorted BELOW older mail and was read after the thing it retracted
  # had already been acted on and committed.
  while IFS= read -r f; do [[ -n "$f" ]] && queue+=("$f"); done < <(
    { find "$MAIL_DIR/$seat/unacked" -maxdepth 1 -name '*.md' -printf '%T@\t%p\n' 2>/dev/null
      find "$MAIL_DIR/$seat"         -maxdepth 1 -name '*.md' -printf '%T@\t%p\n' 2>/dev/null
    } | sort -n | cut -f2-
  )

  (( ${#queue[@]} == 0 )) && { info "no mail"; return 0; }

  local f b sz
  for f in "${queue[@]}"; do
    [[ -f "$f" ]] || continue
    b="$(basename "$f")"; sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
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
      [[ "$(dirname "$f")" == "$MAIL_DIR/$seat" ]] && mv -f -- "$f" "$MAIL_DIR/$seat/unacked/"
      total=$((total+sz)); shown=$((shown+1))
    else
      warn "COULD NOT READ — left in place, not advanced: $b"
    fi
  done

  printf '%s\n' "════════════════════════════════════════════════════════════════════"
  info "$shown message(s) delivered. NOT YET ARCHIVED."
  (( deferred > 0 )) && info "⏸ $deferred deferred (size cap) — they arrive on the next poll."
  info ""
  info "▶ TWO STEPS, both required:"
  info "    1. aimail ack $seat --all      (after you have acted on them)"
  info "    2. aimail poll $seat           (re-arm; background task)"
  info ""
  info "⚠ Un-acked mail is RE-PRINTED on every poll until you ack it. That is"
  info "  deliberate: a delivery nobody read must not look like one that was."
  return 0
}

# ─── Acknowledge ──────────────────────────────────────────────────────────────
mail_ack() {
  local seat="$1"; shift
  local unacked="$MAIL_DIR/$seat/unacked"
  local -a targets=()
  if [[ "${1:-}" == "--all" ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && targets+=("$f"); done \
      < <(find "$unacked" -maxdepth 1 -name '*.md' 2>/dev/null | sort)
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
      "This means it was never written to this seat — NOT that it was consumed." \
      "If you expected it here, check the sender's resolved recipient:" \
      "  aimail seat list"
  fi
  local h
  for h in "${hits[@]}"; do
    printf '%-22s %s\n' "${h%%|*}" "$(basename "${h#*|}")"
  done
  info ""
  info "${#hits[@]} match(es) for '${pattern}' in seat '$seat'"
}
