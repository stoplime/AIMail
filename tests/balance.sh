#!/usr/bin/env bash
# tests/balance.sh — the load balancer's measurement + read-only decision layers
# (lib/balance.sh; docs/load_balancer_design_2026-09-21.md §3.1–§3.4), 2026-09-21.
#
# EVIDENCE RULES (tests/run.sh ①–⑤): every refusing/unmeasured arm has an accepting
# control of the same shape; arms are shown firing first; exit codes captured out of
# pipes; denominator printed. Hermetic: the ccusage CLI is a JSON file behind
# AIMAIL_CCUSAGE_SESSION_JSON, time is AIMAIL_NOW, seat activity is
# AIMAIL_BALANCE_LIVE_STATE, accounts are fake dirs behind AIMAIL_ACCOUNT_DIR_<acct>.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
AIMAIL="$REPO/bin/aimail"

export AIMAIL_ROOT; AIMAIL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aimail-balance-test.XXXXXX")"
export AIMAIL_CONFIG=/dev/null AIMAIL_NO_NETWORK=1 AIMAIL_BLOCK_TTL=999999
unset CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR
# the operator's shell is not part of the fixture -- scrub inherited AIMAIL_* (tests/lib_env.sh)
# shellcheck source=./lib_env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_env.sh"; test_env_sanitize
A="$AIMAIL_ROOT/acct-a"; B="$AIMAIL_ROOT/acct-b"; C="$AIMAIL_ROOT/acct-c"; mkdir -p "$A" "$B" "$C"
export AIMAIL_ACCOUNT_DIR_alpha="$A" AIMAIL_ACCOUNT_DIR_beta="$B" AIMAIL_ACCOUNT_DIR_gamma="$C"
export AIMAIL_FLEET_ACCOUNTS="alpha beta gamma"
export AIMAIL_WEEKLY_CAP_alpha=98 AIMAIL_WEEKLY_CAP_beta=98 AIMAIL_WEEKLY_CAP_gamma=98
export AIMAIL_CAP_alpha=90 AIMAIL_CAP_beta=90 AIMAIL_CAP_gamma=90
export AIMAIL_BALANCE_K=3 AIMAIL_BALANCE_MIN_READINGS=4 AIMAIL_BALANCE_WINDOW_H=3

# shellcheck source=../lib/core.sh
source "$REPO/lib/core.sh"
# shellcheck source=../lib/registry.sh
source "$REPO/lib/registry.sh"
# shellcheck source=../lib/fleet.sh
source "$REPO/lib/fleet.sh"
# shellcheck source=../lib/budget.sh
source "$REPO/lib/budget.sh"
# shellcheck source=../lib/balance.sh
source "$REPO/lib/balance.sh"
ensure_dirs
for s in seat-a seat-b seat-c assistant; do "$AIMAIL" seat add "$s" "t" >/dev/null 2>&1; done

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
chk_contains(){ case "$2" in *"$3"*) chk "$1" 1 1 ;; *) chk "$1" "MISSING[$3]" 1 ;; esac; }
trap 'rm -rf "$AIMAIL_ROOT"' EXIT

T0=1790000000
SID_A="aaaaaaaa-0000-0000-0000-000000000001"; SID_B="bbbbbbbb-0000-0000-0000-000000000002"; SID_X="cccccccc-0000-0000-0000-000000000003"
# seat-a via seat record, seat-b via instance file, seat-c via stopguard, SID_X unattributed
mkdir -p "$STATE_DIR/seat_account" "$STATE_DIR/instances/seat-b" "$STATE_DIR/stopguard"
printf 'seat\tseat-a\naccount\talpha\nsession_id\t%s\nmodel\tm\n' "$SID_A" > "$STATE_DIR/seat_account/seat-a"
printf 'sid\t%s\naccount\talpha\npid\t1\n' "$SID_B" > "$STATE_DIR/instances/seat-b/$SID_B"
SID_C="dddddddd-0000-0000-0000-000000000004"; printf 'seat-c\n' > "$STATE_DIR/stopguard/session.$SID_C"

# ccusage stub writer: write_usage <file> <sid> <in> <out> <cc> <cr> <cost> [more triples...]
write_usage() { # file then repeated: sid in out cc cr cost model
  local f="$1"; shift; python3 - "$f" "$@" <<'PY'
import json, sys
f=sys.argv[1]; a=sys.argv[2:]; rows=[]
for i in range(0, len(a), 7):
    sid,i_,o,cc,cr,cost,model = a[i:i+7]
    rows.append({"period": sid, "inputTokens": int(i_), "outputTokens": int(o), "cacheCreationTokens": int(cc),
                 "cacheReadTokens": int(cr), "totalCost": float(cost), "totalTokens": int(i_)+int(o)+int(cc)+int(cr),
                 "modelBreakdowns": [{"modelName": model, "inputTokens": int(i_), "outputTokens": int(o),
                                      "cacheCreationTokens": int(cc), "cacheReadTokens": int(cr), "cost": float(cost)}]})
json.dump({"session": rows, "totals": {}}, open(f, "w"))
PY
}
write_block() { # <acct> <totalTokens>
  printf '{"blocks":[{"isActive":true,"totalTokens":%s,"tokenCounts":{}}]}' "$2" > "$STATE_DIR/block.$1.json"
}

# ═══ 1. seat usage ledger + attribution ══════════════════════════════════════
printf '\n═══ 1. seat usage ledger ═══\n'
export AIMAIL_NOW=$T0
U="$AIMAIL_ROOT/usage.json"; export AIMAIL_CCUSAGE_SESSION_JSON="$U"
write_usage "$U" "$SID_A" 100 10 0 1000 1.0 model-m "$SID_B" 50 5 0 500 0.5 model-m "$SID_C" 10 1 0 100 0.1 model-m "$SID_X" 7 7 7 7 0.07 model-z
write_block alpha 1000000
rc=0; out="$(CLAUDE_CONFIG_DIR="$A" seat_usage_tick alpha 2>&1)" || rc=$?
chk "first tick exits 0" "$rc" 0
L="$(SEAT_USAGE_LEDGER)"
chk "ledger written with 8 rows (4 sessions x all+model)" "$(grep -vc '^#' "$L")" 8
chk "seat record attribution" "$(awk -F'\t' -v s="$SID_A" '$4==s && $5=="all"{print $3}' "$L")" "seat-a"
chk "instance-file attribution" "$(awk -F'\t' -v s="$SID_B" '$4==s && $5=="all"{print $3}' "$L")" "seat-b"
chk "stop-guard attribution" "$(awk -F'\t' -v s="$SID_C" '$4==s && $5=="all"{print $3}' "$L")" "seat-c"
chk "unknown session -> _unattributed, never dropped" "$(awk -F'\t' -v s="$SID_X" '$4==s && $5=="all"{print $3}' "$L")" "_unattributed"
chk "first tick reconciliation is UNMEASURED (no previous tick)" "$(awk -F'\t' '$1=="verdict"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "UNMEASURED"
# second tick: seats move 2000 raw tokens total; block moves 2000 -> MEASURED
export AIMAIL_NOW=$((T0+300))
write_usage "$U" "$SID_A" 1100 10 0 2000 2.0 model-m "$SID_B" 50 5 0 500 0.5 model-m "$SID_C" 10 1 0 100 0.1 model-m "$SID_X" 7 7 7 7 0.07 model-z
write_block alpha 1002000
CLAUDE_CONFIG_DIR="$A" seat_usage_tick alpha >/dev/null 2>&1
chk "second tick: seats delta == block delta -> MEASURED" "$(awk -F'\t' '$1=="verdict"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "MEASURED"
chk "…ratio 1.000" "$(awk -F'\t' '$1=="ratio"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "1.000"
# third tick: seats move 1000, block moves 3000 -> 0.333 -> UNMEASURED
export AIMAIL_NOW=$((T0+600))
write_usage "$U" "$SID_A" 2100 10 0 2000 3.0 model-m "$SID_B" 50 5 0 500 0.5 model-m "$SID_C" 10 1 0 100 0.1 model-m "$SID_X" 7 7 7 7 0.07 model-z
write_block alpha 1005000
CLAUDE_CONFIG_DIR="$A" seat_usage_tick alpha >/dev/null 2>&1
chk "third tick: seats/block = 0.333 outside 15% -> UNMEASURED" "$(awk -F'\t' '$1=="verdict"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "UNMEASURED"
chk_contains "…detail names the ratio" "$(awk -F'\t' '$1=="detail"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "0.333"
# block rollover: total drops -> UNMEASURED, re-baselines
export AIMAIL_NOW=$((T0+900))
write_block alpha 500
CLAUDE_CONFIG_DIR="$A" seat_usage_tick alpha >/dev/null 2>&1
chk_contains "block rollover between ticks -> UNMEASURED, says so" "$(awk -F'\t' '$1=="detail"{print $2}' "$(SEAT_USAGE_STATUS_FILE alpha)")" "rolled over"
# ccusage silent -> exit 4, nothing appended
export AIMAIL_CCUSAGE_SESSION_JSON="$AIMAIL_ROOT/missing.json"; n_before="$(grep -vc '^#' "$L")"
rc=0; CLAUDE_CONFIG_DIR="$A" seat_usage_tick alpha >/dev/null 2>&1 || rc=$?
chk "ccusage not answering -> exit 4" "$rc" 4
chk "…no rows appended" "$(grep -vc '^#' "$L")" "$n_before"
export AIMAIL_CCUSAGE_SESSION_JSON="$U"

# ═══ 2. seat costs: deltas, weights, window ══════════════════════════════════
printf '\n═══ 2. seat costs ═══\n'
export AIMAIL_NOW=$((T0+900))
# seat-a over the window: input 100->2100 (+2000), cache read 1000->2000 (+1000): weighted 2000*1 + 1000*0.1 = 2100
row="$(seat_costs alpha 3 | awk -F'\t' '$1=="seat-a"')"
chk "seat-a weighted cost = 2000*1.0 + 1000*0.1 = 2100" "$(cut -f2 <<<"$row")" 2100
chk "…raw tokens 3000" "$(cut -f3 <<<"$row")" 3000
chk "seat-b (no movement) = 0" "$(seat_costs alpha 3 | awk -F'\t' '$1=="seat-b"{print $2}')" 0
export AIMAIL_TOKEN_WEIGHTS="1 1 1 1"
chk "AIMAIL_TOKEN_WEIGHTS override: all-ones -> 3000" "$(seat_costs alpha 3 | awk -F'\t' '$1=="seat-a"{print $2}')" 3000
unset AIMAIL_TOKEN_WEIGHTS
export AIMAIL_NOW=$((T0+4*3600))
chk "window: nothing inside the last 1h -> no rows" "$(seat_costs alpha 1 | wc -l | tr -d ' ')" 0
out="$(AIMAIL_NOW=$((T0+900)) "$AIMAIL" budget seats 2>&1)"
chk_contains "budget seats prints the seat" "$out" "seat-a"
chk_contains "…and the reconciliation verdict" "$out" "reconciliation:"

# ═══ 3. pressure ═════════════════════════════════════════════════════════════
printf '\n═══ 3. pressure ═══\n'
export AIMAIL_NOW=$((T0+3*3600))
: > "$LEDGER"
# alpha: weekly rises 10 -> 40 over 3h (slope 10 %/h), 7 readings, reset 24h out, cap 98:
#   headroom 58 / 24h = 2.417 %/h sustainable -> pressure 10/2.417 = 4.14
for i in 0 1 2 3 4 5 6; do printf '%s\talpha\t%s\tweekly\t%s\n' $((T0 + i*1800)) $((10 + i*5)) $((T0+3*3600+24*3600)) >> "$LEDGER"; done
# beta: flat 20 -> pressure 0.00
for i in 0 1 2 3 4 5 6; do printf '%s\tbeta\t20\tweekly\t%s\n' $((T0 + i*1800)) $((T0+3*3600+24*3600)) >> "$LEDGER"; done
# gamma: only 2 readings -> UNMEASURED
for i in 0 1; do printf '%s\tgamma\t20\tweekly\t%s\n' $((T0 + i*1800)) $((T0+3*3600+24*3600)) >> "$LEDGER"; done
IFS='|' read -r pw ps det <<<"$(balance_pressure alpha)"
chk "alpha weekly pressure ≈ 4.14 (slope 10%/h vs sustainable 2.42%/h)" "$pw" "4.14"
IFS='|' read -r pw ps det <<<"$(balance_pressure beta)"
chk "beta flat -> 0.00" "$pw" "0.00"
IFS='|' read -r pw ps det <<<"$(balance_pressure gamma)"
chk "gamma with 2 readings -> UNMEASURED (empty)" "$pw" ""
chk_contains "…detail says fewer than N readings" "$det" "fewer than 4"
touch "$(THROTTLE_FLAG gamma)"
IFS='|' read -r pw ps det <<<"$(balance_pressure gamma)"
chk "parked account -> INF" "$pw" "INF"
rm -f "$(THROTTLE_FLAG gamma)"
# a reset inside the window: readings 90,95 then 5,10,15,20,25 -> slope from the post-reset segment only
: > "$LEDGER"
vals=(90 95 5 10 15 20 25); for i in 0 1 2 3 4 5 6; do printf '%s\talpha\t%s\tweekly\t%s\n' $((T0 + i*1800)) "${vals[$i]}" $((T0+3*3600+24*3600)) >> "$LEDGER"; done
IFS='|' read -r pw ps det <<<"$(balance_pressure alpha)"
chk_contains "reset inside the window: only the post-reset segment (5 readings) is fitted" "$det" "over 5 readings"

# ═══ 4. streak: arm / hold / clear, missing readings ═════════════════════════
printf '\n═══ 4. streak ═══\n'
rm -f "$(BALANCE_STREAK_FILE)"
: > "$LEDGER"
export AIMAIL_FLEET_ACCOUNTS="alpha beta"
seed_series() { # <acct> <start%> <slope per 30min> — 7 readings ending at AIMAIL_NOW
  local a="$1" s="$2" d="$3" i; for i in 0 1 2 3 4 5 6; do printf '%s\t%s\t%s\tweekly\t%s\n' $((AIMAIL_NOW - (6-i)*1800)) "$a" $((s + i*d)) $((AIMAIL_NOW+24*3600)) >> "$LEDGER"; done
}
export AIMAIL_NOW=$((T0+3*3600))
seed_series alpha 10 5; seed_series beta 20 0
for i in 1 2; do out="$(balance_evaluate 2>&1)"; export AIMAIL_NOW=$((AIMAIL_NOW+300)); : > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; done
chk_contains "two evaluations over the gap: WATCHING, streak 2/3" "$out" "arming streak 2/3"
out="$(balance_evaluate 2>&1)"
chk_contains "third consecutive: ARMED" "$out" "ARMED"
chk "streak file has 3 lines" "$(wc -l < "$(BALANCE_STREAK_FILE)" | tr -d ' ')" 3
chk "…last line armed=1" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 1
# a missing reading (beta unmeasured) keeps the armed state and streak untouched
: > "$LEDGER"; seed_series alpha 10 5
export AIMAIL_NOW=$((AIMAIL_NOW+300))
out="$(balance_evaluate 2>&1)"
chk_contains "beta unmeasured -> UNMEASURED evaluation" "$out" "UNMEASURED"
chk "…armed state kept" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 1
# gap closes: alpha flat too -> clear needs K evaluations below GAP_OFF
for i in 1 2; do : > "$LEDGER"; seed_series alpha 40 0; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk_contains "gap closed for 2 evaluations: still ARMED (hysteresis)" "$out" "still armed"
: > "$LEDGER"; seed_series alpha 40 0; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"
chk_contains "third below GAP_OFF: CLEARED" "$out" "CLEARED"
chk "…armed=0" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 0
# a short burst (2 evaluations) never arms
rm -f "$(BALANCE_STREAK_FILE)"
for i in 1 2; do : > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
: > "$LEDGER"; seed_series alpha 40 0; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"
chk "burst shorter than K: streak resets, never armed" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 0

# ═══ 5. would-recommend: idlest first, smallest sufficient, exclusions ═══════
printf '\n═══ 5. would-recommend ═══\n'
rm -f "$(BALANCE_STREAK_FILE)"; : > "$(SEAT_USAGE_LEDGER)"
export AIMAIL_NOW=$((T0+10*3600)); NOW=$AIMAIL_NOW
# alpha's seats over the window: assistant 5000 (supervisor), seat-a 3000 (mid), seat-b 1000 (idle), seat-c 200 (idle)
S_AS="eeeeeeee-0000-0000-0000-000000000005"; printf 'seat\tassistant\naccount\talpha\nsession_id\t%s\nmodel\tm\n' "$S_AS" > "$STATE_DIR/seat_account/assistant"
printf 'seat\tseat-c\naccount\talpha\nsession_id\t%s\nmodel\tm\n' "$SID_C" > "$STATE_DIR/seat_account/seat-c"
for pair in "$S_AS 0 5000" "$SID_A 0 3000" "$SID_B 0 1000" "$SID_C 0 200"; do set -- $pair
  printf '%s\talpha\t%s\t%s\tmodel-m\t%s\t0\t0\t0\t0\n' $((NOW-3600)) "$(_bal_sid_to_seat "$1")" "$1" "$2" >> "$(SEAT_USAGE_LEDGER)"
  printf '%s\talpha\t%s\t%s\tmodel-m\t%s\t0\t0\t0\t0\n' "$NOW" "$(_bal_sid_to_seat "$1")" "$1" "$3" >> "$(SEAT_USAGE_LEDGER)"
done
export AIMAIL_BALANCE_LIVE_STATE="assistant=idle seat-a=mid seat-b=idle seat-c=idle" AIMAIL_SUPERVISOR=assistant
# T-917: the recommendation's TARGET now comes from the placement rules, which need the target's own
# WEEKLY reading (block may be unmeasured); the pressure series alone was enough before. alpha hot
# (60%), beta cold (10%) -- the same shape section 3 used.
printf '%s\t60\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE alpha)"
printf '%s\t10\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE beta)"
: > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0
for i in 1 2 3; do export AIMAIL_NOW=$((AIMAIL_NOW+300)); : > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; out="$(balance_evaluate 2>&1)"; done
chk_contains "armed -> prints a would-recommend line" "$out" "would recommend"
chk_contains "…the idlest seat that narrows without flipping: seat-c is too small? no -- smallest idle that narrows: seat-c" "$out" "move 'seat-c'"
chk_contains "…never the supervisor" "$(grep -c "move 'assistant'" <<<"$out")" "0"
chk_contains "…prints the dry-run command, never runs it" "$out" "--dry-run"
export AIMAIL_BALANCE_LIVE_STATE="assistant=idle seat-a=mid seat-b=mid seat-c=mid"
out="$(balance_evaluate 2>&1)"
chk_contains "all candidates mid-task: still picks the smallest mid one rather than nothing (activity ties)" "$out" "move 'seat-c'"
export AIMAIL_BALANCE_LIVE_STATE="assistant=idle seat-a=parked seat-b=parked seat-c=parked"
out="$(balance_evaluate 2>&1)"
chk_contains "no eligible seat -> says none" "$out" "would recommend: none"
out="$("$AIMAIL" budget balance 2>&1)"
chk_contains "budget balance prints pressures" "$out" "PRESS_W"
chk_contains "…and the streak tail" "$out" "streak"
chk_contains "…and says it is read-only" "$out" "READ-ONLY"

# ═══ 6. skew path (code-review's AND rule) and the once-per-episode alert mail ═══
printf '\n═══ 6. skew path + alert mail ═══\n'
rm -f "$(BALANCE_STREAK_FILE)" "$(BALANCE_DIR)/mailed_episode" "$(BALANCE_DIR)/alerts.log"
export AIMAIL_FLEET_ACCOUNTS="alpha beta" AIMAIL_BALANCE_LIVE_STATE="assistant=idle seat-a=idle seat-b=idle seat-c=idle"
# flat pressures on both (no pressure signal), but alpha has 5 seats at 60% weekly vs beta 1 seat at 10%
printf '%s\t60\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE alpha)"
printf '%s\t10\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE beta)"
export AIMAIL_BALANCE_SEATS="alpha:5 beta:1"
for i in 1 2 3; do : > "$LEDGER"; seed_series alpha 60 0; seed_series beta 10 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk_contains "seat skew (5 vs 1) AND usage skew (60 vs 10) with flat pressures -> ARMED via the skew path" "$out" "skew: seats 5 vs 1"
# seat skew alone (usage equal) never arms
rm -f "$(BALANCE_STREAK_FILE)"
printf '%s\t60\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE beta)"
for i in 1 2 3; do : > "$LEDGER"; seed_series alpha 60 0; seed_series beta 60 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk "seat skew alone (usage equal) never arms" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 0
# usage skew alone (seats equal) never arms via skew (and flat pressure gives no pressure arm)
rm -f "$(BALANCE_STREAK_FILE)"; export AIMAIL_BALANCE_SEATS="alpha:2 beta:2"
printf '%s\t10\t%s\n' "$AIMAIL_NOW" $((AIMAIL_NOW+24*3600)) > "$(WEEKLY_FILE beta)"
for i in 1 2 3; do : > "$LEDGER"; seed_series alpha 60 0; seed_series beta 10 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk "usage skew alone (seats equal) never arms" "$(tail -1 "$(BALANCE_STREAK_FILE)" | cut -f6)" 0
unset AIMAIL_BALANCE_SEATS
# alert mail: pressure-armed episode with AIMAIL_BALANCE_MAIL=1 mails the supervisor ONCE
rm -f "$(BALANCE_STREAK_FILE)" "$(BALANCE_DIR)/mailed_episode" "$(BALANCE_DIR)/alerts.log"
rm -f "$MAIL_DIR"/assistant/*.md "$MAIL_DIR"/seat-c/*.md 2>/dev/null; mkdir -p "$MAIL_DIR/assistant" "$MAIL_DIR/seat-c"
export AIMAIL_BALANCE_MAIL=0
for i in 1 2 3; do : > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk "MAIL=0 (default): armed, alerts.log written, no mail" "$(find "$MAIL_DIR/assistant" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" 0
chk "…alerts.log has the ARMED line" "$(grep -c 'ARMED' "$(BALANCE_DIR)/alerts.log")" 1
export AIMAIL_BALANCE_MAIL=1 AIMAIL_HUMAN_ALERT_SEAT=seat-c
: > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"
chk "MAIL=1: one alert mail reached the supervisor" "$(find "$MAIL_DIR/assistant" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" 1
chk "…and one reached the human alert seat" "$(find "$MAIL_DIR/seat-c" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" 1
chk_contains "…the mail carries the dry-run recommendation" "$(cat "$MAIL_DIR"/assistant/*.md)" "--dry-run"
: > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"
chk "still armed next evaluation: NO second mail (once per episode)" "$(find "$MAIL_DIR/assistant" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" 1
unset AIMAIL_BALANCE_MAIL AIMAIL_HUMAN_ALERT_SEAT
# a recipient whose mailbox cannot be written: logged as MAIL-FAILED, and still only one attempt per episode
rm -f "$(BALANCE_STREAK_FILE)" "$(BALANCE_DIR)/mailed_episode"; rm -rf "$MAIL_DIR/seat-c"
export AIMAIL_BALANCE_MAIL=1 AIMAIL_HUMAN_ALERT_SEAT=seat-c
for i in 1 2 3 4; do : > "$LEDGER"; seed_series alpha 10 5; seed_series beta 20 0; export AIMAIL_NOW=$((AIMAIL_NOW+300)); out="$(balance_evaluate 2>&1)"; done
chk "unwritable recipient: MAIL-FAILED logged once" "$(grep -c 'MAIL-FAILED' "$(BALANCE_DIR)/alerts.log")" 1
chk "…episode marker still written (no retry storm)" "$([[ -f "$(BALANCE_DIR)/mailed_episode" ]] && echo yes)" "yes"
mkdir -p "$MAIL_DIR/seat-c"
unset AIMAIL_BALANCE_MAIL AIMAIL_HUMAN_ALERT_SEAT

printf '\n═══ %d/%d passed ═══\n' "$PASS" $((PASS+FAIL))
if (( FAIL )); then printf 'FAILED:\n'; printf '  - %s\n' "${FAILURES[@]}"; exit 1; fi
exit 0
