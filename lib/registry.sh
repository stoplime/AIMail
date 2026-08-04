# shellcheck shell=bash
# registry.sh — the seat registry. THE REGISTRY IS THE ADDRESS SPACE.
#
# ⛔ THE DEFECT THIS EXISTS TO KILL: a directory named `metrics` was created
#    alongside the real seat `metrics-report`. No poller watched it. Mail
#    addressed there was never read and never bounced — it was a silent black
#    hole, and the seat it was meant for sat waiting.
#
# ⭐ THE FIX IS NOT "BE CAREFUL WITH NAMES". It is that a name is only an address
#    if it is REGISTERED. A directory existing means nothing; `send` resolves
#    against this file and refuses anything it cannot resolve. A typo is now a
#    loud refusal at send time instead of an outage discovered hours later.
#
# Format — TSV, one seat per row, comments and blank lines ignored:
#   name <TAB> status <TAB> aliases(comma-sep, or -) <TAB> description
#
# `status` is one of:
#   active    accepts mail
#   parked    accepts mail; the seat is deliberately not working right now
#   retired   REFUSES mail, and says what to use instead
#
# WHY `retired` rather than deleting the row: deleting it turns a message to a
# real-but-finished seat back into an unresolvable name, which is a worse error
# than the one it fixes. A retired seat can name its successor.

_seats_init() {
  [[ -f "$SEATS_FILE" ]] && return 0
  ensure_dirs
  atomic_write "$SEATS_FILE" <<'EOF'
# aimail seat registry — THE address space. A name not in here is not an address.
# name	status	aliases	description
EOF
}

# _seat_rows — every non-comment, non-blank row.
_seat_rows() { _seats_init; grep -vE '^\s*(#|$)' "$SEATS_FILE" 2>/dev/null || true; }

seat_names() { _seat_rows | awk -F'\t' '{print $1}'; }

seat_field() {
  local name="$1" n="$2"
  _seat_rows | awk -F'\t' -v s="$name" -v n="$n" '$1==s{print $n; exit}'
}

seat_exists() { [[ -n "$(seat_field "$1" 1)" ]]; }

# seat_resolve <name> — the ONLY way to turn a caller's string into an address.
# Prints the canonical name on stdout. Any alias resolution is announced on
# stderr, loudly and every time.
#
# ⚠ WHY AN ALIAS IS ANNOUNCED RATHER THAN APPLIED SILENTLY: a silent redirect is
#   how mail reaches a seat the sender did not intend. The sender must be able to
#   see that `metrics` was not the address they think it was.
seat_resolve() {
  local want="$1" canon
  [[ -n "$want" ]] && return_early=0

  if seat_exists "$want"; then canon="$want"
  else
    canon="$(_seat_rows | awk -F'\t' -v w="$want" '
      { n=split($3, a, ",");
        for (i=1;i<=n;i++) { gsub(/^[ \t]+|[ \t]+$/,"",a[i]); if (a[i]==w) { print $1; exit } } }')"
    [[ -n "$canon" ]] && warn "alias: '$want' resolved to registered seat '$canon'"
  fi

  if [[ -z "$canon" ]]; then
    local suggestions
    suggestions="$(_seat_suggest "$want")"
    refused "'$want' is not a registered seat — nothing was sent." \
      "The registry is the address space: an unregistered name is not an address," \
      "and mail written to one is never read and never bounces." \
      "" \
      "${suggestions:-  (no similar registered names)}" \
      "" \
      "  aimail seat list          show every registered seat" \
      "  aimail seat add <name>    register a new one"
  fi

  local status; status="$(seat_field "$canon" 2)"
  if [[ "$status" == "retired" ]]; then
    refused "seat '$canon' is RETIRED — nothing was sent." \
      "$(seat_field "$canon" 4)" \
      "A retired seat has no reader. Send to its successor instead."
  fi
  printf '%s\n' "$canon"
}

# _seat_suggest — near matches, so a refusal is actionable rather than a wall.
# Substring first (catches metrics → metrics-report, the real case), then
# edit distance 1-2 (catches reveiw → review).
_seat_suggest() {
  local want="$1" out=""
  local sub; sub="$(seat_names | grep -iF -- "$want" || true)"
  local rev; rev="$(seat_names | while read -r n; do [[ -n "$n" && "$want" == *"$n"* ]] && echo "$n"; done)"
  # ⚠ Edit distance against the FULL name is not enough for the case that
  #   motivated this whole registry: `metrcs` -> `metrics-report` is
  #   distance 8, far outside any sane threshold, yet it is obviously the
  #   intended seat. The typo is in a PREFIX of a long hyphenated name.
  # ⇒ Also compare the query against each name truncated to the query's length,
  #   which scores `metrcs` vs `metric` at 2. A refusal that cannot name
  #   the seat you meant is a wall, not a guard.
  local near; near="$(seat_names | while read -r n; do
      [[ -z "$n" ]] && continue
      local d dp
      d="$(_edit_distance "$want" "$n")"
      dp="$(_edit_distance "$want" "${n:0:${#want}}")"
      (( d > 0 && d <= 2 )) && { echo "$n"; continue; }
      (( ${#n} > ${#want} && dp <= 2 )) && echo "$n"
    done)"
  out="$(printf '%s\n%s\n%s\n' "$sub" "$rev" "$near" | grep -v '^$' | sort -u || true)"
  [[ -z "$out" ]] && return 0
  printf '  Did you mean:\n'
  printf '%s\n' "$out" | sed 's/^/    /'
}

# _edit_distance — Levenshtein, in awk to avoid a runtime dependency.
_edit_distance() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      la=length(a); lb=length(b);
      for (i=0;i<=la;i++) d[i,0]=i;
      for (j=0;j<=lb;j++) d[0,j]=j;
      for (i=1;i<=la;i++) for (j=1;j<=lb;j++) {
        c = (substr(a,i,1)==substr(b,j,1)) ? 0 : 1;
        m = d[i-1,j]+1;
        if (d[i,j-1]+1 < m) m = d[i,j-1]+1;
        if (d[i-1,j-1]+c < m) m = d[i-1,j-1]+c;
        d[i,j]=m;
      }
      print d[la,lb];
    }'
}

# ─── Mutations ────────────────────────────────────────────────────────────────
# ⚠ A seat name is validated against a character class on the way IN. The
#   previous system had zero-byte files named `ALL:`, `you:` and `GREEN` sitting
#   in the same flat namespace as the inboxes — shell-redirect accidents that
#   became indistinguishable from addresses.
_valid_seat_name() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,31}$ ]]; }

seat_add() {
  local name="$1" desc="${2:-}" aliases="${3:--}"
  _valid_seat_name "$name" || refused "'$name' is not a valid seat name." \
    "Allowed: lowercase letters, digits and hyphens; 2-32 chars; must start with a letter." \
    "This rejects the shell-accident names (\`ALL:\`, \`you:\`) that the previous system" \
    "accumulated in the same namespace as real inboxes."
  seat_exists "$name" && refused "seat '$name' is already registered." "  aimail seat list"
  _seats_init
  printf '%s\t%s\t%s\t%s\n' "$name" "active" "${aliases:--}" "${desc:-(no description)}" >> "$SEATS_FILE"
  mkdir -p "$MAIL_DIR/$name/archive" "$MAIL_DIR/$name/unacked"
  ok "registered seat '$name'"
  info "  inbox: $MAIL_DIR/$name"
}

seat_retire() {
  local name="$1" successor="${2:-}"
  seat_exists "$name" || refused "'$name' is not a registered seat."
  local note="retired"; [[ -n "$successor" ]] && note="retired — use '$successor' instead"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v OFS='\t' -v s="$name" -v note="$note" \
    '$1==s{$2="retired"; $4=note} {print}' "$SEATS_FILE" > "$tmp"
  atomic_write "$SEATS_FILE" < "$tmp"; rm -f "$tmp"
  ok "seat '$name' retired. Mail addressed to it is now refused, not silently dropped."
}

seat_list() {
  _seats_init
  printf '%-22s %-8s %-18s %s\n' SEAT STATUS ALIASES DESCRIPTION
  printf '%.0s─' {1..92}; echo
  local n=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    n=$((n+1))
    printf '%-22s %-8s %-18s %s\n' \
      "$(cut -f1 <<<"$row")" "$(cut -f2 <<<"$row")" "$(cut -f3 <<<"$row")" "$(cut -f4 <<<"$row")"
  done < <(_seat_rows)
  echo
  # ④ PRINT THE DENOMINATOR — "0 of 0 because nothing ran" and "0 of 19" look
  #    almost identical, and the fleet has published the first as an all-clear.
  info "$n seat(s) registered in $SEATS_FILE"
  (( n == 0 )) && warn "no seats registered — every send will refuse until one is added"
  return 0
}
