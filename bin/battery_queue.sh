#!/usr/bin/env bash
# bin/battery_queue.sh -- the FIFO wait queue behind `run_canonical_battery.sh --wait <minutes>`
# (test-throughput design, 2026-09-21; the first live case was a blocked FULL run).
#
# WHY: the wrapper's guards REFUSE an over-budget or lock-held launch and the caller retries by
# hand. 80 of 121 launches on 2026-09-21 were refusals, and the order of admission was "whoever
# retried fastest" -- a 21-minute FULL could not find a whole-budget window while 10-minute FASTs
# kept grabbing it. This file replaces refuse-and-retry with a ticket queue:
#
#   * a ticket is one file in $BATTERY_QUEUE_DIR named  <class>.<epoch_ns>.<seat>.<pid>
#     class 0 = full, 1 = fast  ->  plain `sort` puts every FULL ahead of every FAST, then oldest first.
#   * the HEAD is the first LIVE ticket in that order; only the head may launch. A FAST behind a
#     waiting FULL is therefore held until the FULL has started (its ticket is dropped at admission).
#   * a ticket is LIVE while its pid is alive AND that pid's cmdline names run_canonical_battery
#     (pid-reuse guard, same shape as lib/fleet.sh's _instance_pid_is_poller). Any caller that
#     lists the queue removes stale tickets -- a killed waiter never blocks the line.
#   * a STARTING reservation  starting.<epoch_s>.<seat>.<pid>.<requested>  is written at admission
#     and counts as <requested> occupied worker slots for $BATTERY_QUEUE_START_GRACE_S seconds
#     (default 120): the occupancy reader counts live worker children, and a run admitted a moment
#     ago has not spawned them yet, so two heads admitted back to back would both read the same
#     free slots. The reservation closes that window; it expires on its own.
#
# The wrapper SOURCES this file. It is also runnable: `battery_queue.sh --list` prints the live
# queue for a human (used by `gateclaim.sh --list` readers wondering why a launch was refused).
#
# Test knobs (never set in production):
#   BATTERY_QUEUE_DIR        queue directory (default /tmp/aimail-battery-queue; same one-box /tmp
#                            assumption gateclaim.sh documents at its own top).
#   BATTERY_QUEUE_LIVE_PIDS  space-separated pids to treat as live INSTEAD of the real check
#                            (set to a single space to mean "none live"). Unset = real check.

BATTERY_QUEUE_DIR="${BATTERY_QUEUE_DIR:-/tmp/aimail-battery-queue}"
BATTERY_QUEUE_START_GRACE_S="${BATTERY_QUEUE_START_GRACE_S:-120}"

bq_dir() {
    mkdir -p "$BATTERY_QUEUE_DIR" 2>/dev/null
    chmod 1777 "$BATTERY_QUEUE_DIR" 2>/dev/null || true
    printf '%s\n' "$BATTERY_QUEUE_DIR"
}

# bq_pid_live PID -> 0 when the pid is a live run_canonical_battery process.
bq_pid_live() {
    local pid="$1"
    # the sourcing process's own ticket is always live (a wrapper waiting on its own ticket)
    [ "$pid" = "$$" ] && return 0
    if [ -n "${BATTERY_QUEUE_LIVE_PIDS+x}" ]; then
        local p
        for p in $BATTERY_QUEUE_LIVE_PIDS; do [ "$p" = "$pid" ] && return 0; done
        return 1
    fi
    [ -d "/proc/$pid" ] || return 1
    local cmd
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    case "$cmd" in
        *run_canonical_battery*) return 0 ;;
    esac
    return 1
}

# bq_class GATE -> the sort class for a gate mode (full sorts first).
bq_class() {
    case "$1" in
        full) printf '0' ;;
        *)    printf '1' ;;
    esac
}

# bq_live_tickets -> prints live ticket NAMES in admission order; deletes stale tickets it meets.
bq_live_tickets() {
    local dir name pid
    dir="$(bq_dir)"
    for name in $(ls -1 "$dir" 2>/dev/null | grep -E '^[01]\.[0-9]+\.[^.]+\.[0-9]+$' | sort); do
        pid="${name##*.}"
        if bq_pid_live "$pid"; then
            printf '%s\n' "$name"
        else
            rm -f "$dir/$name" 2>/dev/null
        fi
    done
}

# bq_take GATE SEAT PID REQUESTED -> creates the ticket atomically, prints its name.
bq_take() {
    local gate="$1" seat="$2" pid="$3" requested="$4" dir name
    dir="$(bq_dir)"
    name="$(bq_class "$gate").$(date +%s%N).$seat.$pid"
    ( set -o noclobber; printf 'seat=%s gate=%s pid=%s requested=%s queued=%s\n' \
        "$seat" "$gate" "$pid" "$requested" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$dir/$name" ) 2>/dev/null \
        || return 1
    printf '%s\n' "$name"
}

# bq_drop NAME -> removes a ticket (idempotent).
bq_drop() {
    rm -f "$(bq_dir)/$1" 2>/dev/null
    return 0
}

# bq_head -> the name of the live head ticket, or nothing.
bq_head() {
    bq_live_tickets | head -n 1
}

# bq_position NAME -> "k n": 1-based position of NAME among live tickets and the live count.
# k=0 when NAME is not live (dropped or stale).
bq_position() {
    local want="$1" k=0 n=0 name
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        n=$((n+1))
        [ "$name" = "$want" ] && k=$n
    done < <(bq_live_tickets)
    printf '%s %s\n' "$k" "$n"
}

# bq_describe NAME -> "seat/gate" for a ticket name (from the name, no file read needed).
bq_describe() {
    local name="$1" cls seat
    cls="${name%%.*}"
    seat="${name#*.*.}"; seat="${seat%.*}"
    case "$cls" in 0) printf '%s/full' "$seat" ;; *) printf '%s/fast' "$seat" ;; esac
}

# bq_reserve SEAT PID REQUESTED -> writes a starting reservation, prints its name.
bq_reserve() {
    local seat="$1" pid="$2" requested="$3" dir name
    dir="$(bq_dir)"
    name="starting.$(date +%s).$seat.$pid.$requested"
    : > "$dir/$name" 2>/dev/null || return 1
    printf '%s\n' "$name"
}

# bq_unreserve SEAT PID -> removes this process's own reservation(s).
bq_unreserve() {
    local seat="$1" pid="$2" dir
    dir="$(bq_dir)"
    rm -f "$dir"/starting.*."$seat"."$pid".* 2>/dev/null
    return 0
}

# bq_reserved_slots -> sum of <requested> over reservations younger than the grace; deletes
# expired ones. A reservation whose pid is dead is expired regardless of age.
bq_reserved_slots() {
    local dir now name ts pid req sum=0
    dir="$(bq_dir)"
    now="$(date +%s)"
    for name in $(ls -1 "$dir" 2>/dev/null | grep -E '^starting\.[0-9]+\.[^.]+\.[0-9]+\.[0-9]+$'); do
        ts="$(printf '%s' "$name" | cut -d. -f2)"
        pid="$(printf '%s' "$name" | cut -d. -f4)"
        req="$(printf '%s' "$name" | cut -d. -f5)"
        if [ $((now - ts)) -ge "$BATTERY_QUEUE_START_GRACE_S" ] || ! bq_pid_live "$pid"; then
            rm -f "$dir/$name" 2>/dev/null
            continue
        fi
        sum=$((sum + req))
    done
    printf '%s\n' "$sum"
}

# bq_list -> human listing of the live queue and reservations.
bq_list() {
    local dir name k=0
    dir="$(bq_dir)"
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        k=$((k+1))
        printf '%2d  %-24s %s\n' "$k" "$(bq_describe "$name")" "$(cat "$dir/$name" 2>/dev/null)"
    done < <(bq_live_tickets)
    [ "$k" -eq 0 ] && printf '(queue empty)\n'
    printf 'reserved starting slots (grace %ss): %s\n' "$BATTERY_QUEUE_START_GRACE_S" "$(bq_reserved_slots)"
}

# Runnable form.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --list|"") bq_list ;;
        *) echo "usage: battery_queue.sh [--list]" >&2; exit 2 ;;
    esac
fi
