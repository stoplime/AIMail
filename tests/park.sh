#!/usr/bin/env bash
# tests/park.sh — seat parking with a cost guard, and the cold-seat watchdog. Driven through the real
# bin/aimail in a throwaway state root with a fixed clock (AIMAIL_NOW). Bounded real pollers (a 4-second
# `timeout`) prove what a parked seat is woken by. Runs standalone (`bash tests/park.sh`) and inside
# tests/run.sh. No assertion depends on the machine's time zone: times in expected text are built with `date`.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AIMAIL_ROOT="$T/root" AIMAIL_CONFIG="$T/aimail.conf"
# shellcheck source=./lib_env.sh
source "$REPO/tests/lib_env.sh"; test_env_sanitize
export AIMAIL_STERILITY_TERMS="" AIMAIL_SUPERVISOR="sup" AIMAIL_SEND_IDENTITY_CHECK=0 AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
export AIMAIL_POLL_INTERVAL=1 AIMAIL_POLL_DEPRECATION_QUIET=1
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID AIMAIL_POLL_HEARTBEAT_SEC AIMAIL_PARK_GUARD_HOURS AIMAIL_COLD_IDLE_MIN AIMAIL_COLD_AFTER_MIN
mkdir -p "$AIMAIL_ROOT/state" "$AIMAIL_ROOT/tmp"; printf 'AIMAIL_ROOT="%s"\n' "$AIMAIL_ROOT" > "$AIMAIL_CONFIG"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  ✖ %s (expected %s, got %s)\n' "$1" "$3" "$2"; fi; }
has() { # <desc> <text> <fragment>
  if grep -qF -- "$3" <<<"$2"; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  ✖ %s (missing: %s)\n' "$1" "$3"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }
NOW=1800000000; H=3600
STATE="$AIMAIL_ROOT/state"
am() { AIMAIL_NOW="$NOW" "$AIMAIL" "$@" 2>&1; }          # prints output; rc via $?
inbox_n() { find "$AIMAIL_ROOT/mail/$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }
send() { printf 'body of %s\n' "$2" > "$T/body.md"; local to="$1" s="$2"; shift 2
         "$AIMAIL" send --to "$to" --from sup --subject "$s" --body-file "$T/body.md" "$@" >/dev/null 2>&1; }
fresh() { rm -rf "$AIMAIL_ROOT/mail/$1" "$STATE/shown/$1" "$STATE/last_delivered/$1" "$STATE/seat_park_$1"; mkdir -p "$AIMAIL_ROOT/mail/$1/unacked"; }
for s in sup alpha beta gamma; do "$AIMAIL" seat add "$s" "fixture $s" >/dev/null 2>&1; done

section "park: a recorded state, and what it requires"
OUT="$(am seat park alpha --reason "nothing queued")"; RC=$?
check "park without --until or --trigger is refused" "$RC" 3
has "  ...and says a park needs an end" "$OUT" "a park needs an end"
OUT="$(am seat park alpha --until +4h)"; RC=$?
check "park without --reason is refused" "$RC" 3
OUT="$(am seat park alpha --until 2001-01-01 --reason "past")"; RC=$?
check "park --until a past time is refused" "$RC" 3
check "  ...and recorded nothing" "$([[ -f "$STATE/seat_park_alpha" ]] && echo 1 || echo 0)" 0
OUT="$(am seat park nosuchseat --until +4h --reason x)"; RC=$?
check "park of an unregistered seat is refused" "$([[ $RC -ne 0 ]] && echo 1 || echo 0)" 1
OUT="$(am seat park alpha --until +8h --reason "quiet night")"; RC=$?
check "park --until +8h succeeds" "$RC" 0
check "  ...writes a state file under the state dir" "$([[ -f "$STATE/seat_park_alpha" ]] && echo 1 || echo 0)" 1
check "  ...recording the park time" "$(awk -F'\t' '$1=="parked_at"{print $2}' "$STATE/seat_park_alpha")" "$NOW"
check "  ...and the end time" "$(awk -F'\t' '$1=="until"{print $2}' "$STATE/seat_park_alpha")" "$(( NOW + 8*H ))"
check "  ...and the reason" "$(awk -F'\t' '$1=="reason"{print $2}' "$STATE/seat_park_alpha")" "quiet night"
OUT="$(am seat park alpha --until +8h --reason again)"; RC=$?
check "parking an already parked seat is refused" "$RC" 3
am seat park beta --trigger "the review lands" --reason "waiting on review" >/dev/null
check "park --trigger records the trigger" "$(awk -F'\t' '$1=="trigger"{print $2}' "$STATE/seat_park_beta")" "the review lands"
check "  ...and no end time" "$(awk -F'\t' '$1=="until"{print $2}' "$STATE/seat_park_beta")" ""

section "unpark guard: refused under 5 hours, with the park time and the time left"
NOW=$(( NOW + 1*H ))
OUT="$(am seat unpark alpha)"; RC=$?
check "unpark 1 hour after the park is refused" "$RC" 3
has "  ...the message names the park time" "$OUT" "$(date -d "@1800000000" '+%F %H:%M')"
has "  ...states the cost reason" "$OUT" "costs more than keeping the seat warm"
has "  ...states the time left (4h00m)" "$OUT" "in 4h00m"
has "  ...and when the guard lifts" "$OUT" "$(date -d "@$(( 1800000000 + 5*H ))" '+%F %H:%M')"
check "  ...the park is still in place" "$([[ -f "$STATE/seat_park_alpha" ]] && echo 1 || echo 0)" 1
check "  ...and nothing was logged as a bypass" "$([[ -s "$STATE/park_overrides.log" ]] && echo 1 || echo 0)" 0
OUT="$(am seat unpark alpha --expensive-ok "")"; RC=$?
check "--expensive-ok with an empty reason is refused" "$RC" 3
OUT="$(am seat unpark alpha --expensive-ok "urgent customer work")"; RC=$?
check "unpark with --expensive-ok passes inside the guard" "$RC" 0
check "  ...the park is removed" "$([[ -f "$STATE/seat_park_alpha" ]] && echo 1 || echo 0)" 0
check "  ...the bypass is logged with seat, time and reason" "$(awk -F'\t' '{print $1 "|" $3 "|" $4}' "$STATE/park_overrides.log")" "$NOW|alpha|urgent customer work"
am seat park alpha --until +30h --reason "second park" >/dev/null
NOW=$(( NOW + 2*H ))
am seat unpark alpha --expensive-ok "second bypass" >/dev/null
check "the bypass log is append-only: a second bypass adds a line" "$(wc -l < "$STATE/park_overrides.log" | tr -d ' ')" 2
check "  ...the first line is intact" "$(sed -n 1p "$STATE/park_overrides.log" | awk -F'\t' '{print $4}')" "urgent customer work"

section "unpark guard: lifts at the guard length"
NOW=1800000000; am seat park gamma --trigger "event" --reason "long idle" >/dev/null
NOW=$(( 1800000000 + 5*H - 1 ))
OUT="$(am seat unpark gamma)"; RC=$?
check "one second before the guard lifts: still refused" "$RC" 3
NOW=$(( 1800000000 + 5*H ))
OUT="$(am seat unpark gamma)"; RC=$?
check "at exactly 5 hours: unpark passes" "$RC" 0
check "  ...the park is removed" "$([[ -f "$STATE/seat_park_gamma" ]] && echo 1 || echo 0)" 0
check "  ...no bypass was logged for it" "$(grep -c "gamma" "$STATE/park_overrides.log")" 0
OUT="$(am seat unpark gamma --expensive-ok "not needed")"; RC=$?
check "unparking a seat that is not parked changes nothing" "$RC" 0
export AIMAIL_PARK_GUARD_HOURS=1
NOW=1800000000; am seat park gamma --trigger "event" --reason "short guard" >/dev/null
NOW=$(( 1800000000 + H ))
am seat unpark gamma >/dev/null; RC=$?
check "AIMAIL_PARK_GUARD_HOURS=1 lifts the guard at 1 hour" "$RC" 0
unset AIMAIL_PARK_GUARD_HOURS
am seat park gamma --trigger x --reason y >/dev/null
OUT="$(AIMAIL_PARK_GUARD_HOURS=bogus am seat unpark gamma)"; RC=$?
check "a non-numeric guard setting is refused, not guessed" "$RC" 3
check "  ...and the park is still in place" "$([[ -f "$STATE/seat_park_gamma" ]] && echo 1 || echo 0)" 1
rm -f "$STATE/seat_park_gamma" "$STATE/seat_park_beta"

section "a parked seat's poller: held mail, urgent mail, expiry"
NOW=1800000000
poll_for() { timeout 4 env AIMAIL_NOW="$NOW" "$AIMAIL" poll "$1" > "$T/poll.out" 2>&1; echo $? > "$T/poll.rc"; cat "$T/poll.out"; }
POLL_RC() { cat "$T/poll.rc"; }
fresh beta
am seat park beta --until +2h --reason "park for poller" >/dev/null
send beta "ordinary mail"
OUT="$(poll_for beta)"
check "a parked seat's poller does not wake for ordinary mail" "$(POLL_RC)" 124
check "  ...no WAKE line was printed" "$(grep -c '^WAKE=' <<<"$OUT")" 0
check "  ...the mail is held in the inbox" "$(inbox_n beta)" 1
send beta "urgent mail" --wake
OUT="$(poll_for beta)"
check "mail sent with --wake wakes a parked seat" "$(grep -c '^WAKE=mail' <<<"$OUT")" 1
has "  ...the urgent mail prints in full" "$OUT" "body of urgent mail"
has "  ...and the held ordinary mail prints in full on that wake" "$OUT" "body of ordinary mail"
fresh beta
am seat park beta --until +2h --reason "expiry" >/dev/null
send beta "mail before expiry"
NOW=$(( 1800000000 + 3*H ))
OUT="$(poll_for beta)"
check "once --until has passed the park no longer holds mail: the poller wakes" "$(grep -c '^WAKE=mail' <<<"$OUT")" 1
has "  ...and the held mail prints in full" "$OUT" "body of mail before expiry"
check "an expired park is not a park for the count" "$(AIMAIL_NOW=$NOW bash -c 'source "$1/lib/core.sh"; source "$1/lib/mail.sh"; seat_park_active beta && echo parked || echo free' _ "$REPO")" free
OUT="$(am seat unpark beta)"; RC=$?
check "unpark of an expired park passes without the guard and removes the record" "$RC$([[ -f "$STATE/seat_park_beta" ]] && echo present || echo gone)" "0gone"
NOW=1800000000

section "cold-watch: one alert per idle stretch, none for a parked seat"
STOPLOG="$STATE/stophook.log"
stop() { printf '%s\t%s\t%s\tsid\tallow\n' "$1" "x" "$2" >> "$STOPLOG"; }   # <epoch> <seat>
cw() { am seat cold-watch; }
alerts() { find "$AIMAIL_ROOT/mail/sup" -maxdepth 1 -type f -name '*.md' -exec grep -l 'goes cold in about' {} + 2>/dev/null | wc -l | tr -d ' '; }
fresh sup; : > "$STOPLOG"
stop $(( NOW - 44*60 )) alpha
cw >/dev/null
check "a seat idle 44 minutes gets no alert" "$(alerts)" 0
: > "$STOPLOG"; rm -rf "$STATE/cold_alert"
stop $(( NOW - 45*60 )) beta
cw >/dev/null
check "a seat idle exactly 45 minutes gets one alert" "$(alerts)" 1
F="$(grep -l 'goes cold in about' "$AIMAIL_ROOT"/mail/sup/*.md | head -1)"
has "  ...saying which seat and what to do" "$(cat "$F")" "beta goes cold in about 15 minutes: give it work or park it"
check "  ...sent no-wake" "$(grep -c '^wake: no$' "$F")" 1
cw >/dev/null; NOW=$(( NOW + 10*60 )); cw >/dev/null; NOW=$(( NOW + 10*60 )); cw >/dev/null
check "further runs in the same idle stretch send nothing more" "$(alerts)" 1
stop $(( NOW + 60 )) beta                  # beta is active again: a new last stop
NOW=$(( NOW + 2*60 )); cw >/dev/null
check "activity ends the stretch; no alert while it is fresh" "$(alerts)" 1
NOW=$(( NOW + 50*60 )); cw >/dev/null
check "a new idle stretch of 45+ minutes alerts again (second alert)" "$(alerts)" 2
cw >/dev/null
check "  ...and only once for that stretch" "$(alerts)" 2
fresh sup; : > "$STOPLOG"; rm -rf "$STATE/cold_alert"
stop $(( NOW - 120*60 )) alpha
am seat park alpha --trigger "event" --reason "parked and idle" >/dev/null
cw >/dev/null
check "a parked seat gets no watchdog alert" "$(alerts)" 0
rm -f "$STATE/seat_park_alpha"
stop $(( NOW - 120*60 )) gamma 2>/dev/null; : > "$STOPLOG"
cw >/dev/null
check "a seat with no stop record is unknown, never idle: no alert" "$(alerts)" 0
OUT="$(AIMAIL_SUPERVISOR= am seat cold-watch)"; RC=$?
check "without a supervisor configured cold-watch is refused" "$RC" 3
OUT="$(AIMAIL_NOW=$NOW AIMAIL_SUPERVISOR=nobody "$AIMAIL" seat cold-watch 2>&1)"; RC=$?
check "a supervisor that is not a registered seat is refused" "$RC" 3
stop $(( NOW - 60*60 )) alpha
OUT="$(am seat cold-watch --dry-run)"
has "--dry-run names the seat it would alert" "$OUT" "would alert: alpha"
check "  ...and sends nothing" "$(alerts)" 0

section "budget pool: per-seat section"
: > "$STOPLOG"; fresh sup
stop $(( NOW - 90*60 )) sup
am seat park alpha --until +48h --reason "weekend lull" >/dev/null
am seat park beta --trigger "release cut" --reason "waiting for release" >/dev/null
NOW=$(( NOW + 6*H ))
export AIMAIL_FLEET_ACCOUNTS="acct1" AIMAIL_ACCOUNT_POOL="acct1"
OUT="$(AIMAIL_NOW="$NOW" "$AIMAIL" budget pool 2>/dev/null)"
row() { awk -v s="$1" '/^SEAT +ACCOUNT/{on=1;next} on && $1==s{print; exit}' <<<"$OUT"; }
has "the seat section has a header" "$OUT" "PARKED-FOR"
R="$(row alpha)"
has "a parked seat reads yes" "$R" " yes "
has "  ...parked for 6h00m" "$R" "6h00m"
has "  ...with its end time" "$R" "until $(date -d "@$(awk -F'\t' '$1=="until"{print $2}' "$STATE/seat_park_alpha")" '+%m-%d %H:%M')"
has "  ...its reason" "$R" "weekend lull"
has "  ...and no cost-guard hold, since the guard lifted after 5 hours" "$R" " no "
R="$(row beta)"
has "a trigger park shows the trigger" "$R" "trigger: release cut"
R="$(row sup)"
has "an unparked seat shows idle time since its last stop (1h30m before the +6h shift => 7h30m)" "$R" "7h30m"
R="$(row gamma)"
has "an unparked seat with no stop record shows ? for idle" "$R" " ? "
NOW=1800000000; am seat unpark alpha --expensive-ok "fixture cleanup" >/dev/null
am seat park alpha --trigger "e" --reason "fresh" >/dev/null
NOW=$(( NOW + 1*H ))
OUT="$(AIMAIL_NOW="$NOW" "$AIMAIL" budget pool 2>/dev/null)"
check "a park under the guard length reads GUARD yes (an un-park now would be refused)" "$(row alpha | awk '{print $3 "|" $4 "|" $6}')" "yes|1h00m|yes"

echo; printf 'park: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
