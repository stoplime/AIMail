#!/usr/bin/env bash
# tests/gateclaim_keys.sh — the KEY NAMESPACE of gateclaim.sh.
#
# WHY: on 2026-08-20 01:25 the lock failed with 100% ADOPTION. code-review
# claimed `t100-widget-marks`, audit claimed `T-100-widget` 39s later, and BOTH
# acquires returned 0 — two doors into one room. mkdir excludes over a NAME, not
# over a WORK ITEM.
#
# ⚠ The first proposed fix (lowercase + strip non-alphanumerics) was measured
#   against those two real keys and does NOT catch them:
#       t100-widget-marks -> t100widgetmarks   vs   T-100-widget -> t100widget
#   The difference was never case or punctuation. ARM 1 is that literal event, so
#   any future rewrite of canon() has to keep passing the thing that broke.
#
# Follows tests/run.sh's evidence rules: every rejection arm is paired with an
# accepts arm (③), exit codes are captured out of pipes (⑤), denominator printed (④).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G="${GATECLAIM:-$(dirname "$HERE")/bin/gateclaim.sh}"
export AIMAIL_CLAIMS="${TMPDIR:-/tmp}/gateclaim-keytest-$$"
trap 'rm -rf "$AIMAIL_CLAIMS"' EXIT

PASS=0; FAIL=0; declare -a FAILURES=()
chk(){ if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"
       else FAIL=$((FAIL+1)); FAILURES+=("$1"); printf '  ⛔ %s (want=%s got=%s)\n' "$1" "$3" "$2"; fi; }
fresh(){ rm -rf "$AIMAIL_CLAIMS"; mkdir -p "$AIMAIL_CLAIMS"; }
# Plant a claim in the PRE-canonicalisation namespace, to test migration.
legacy(){ mkdir -p "$AIMAIL_CLAIMS/$1"; printf '%s %s %s\n' "$2" "$(date -Iseconds)" "${3:-$(date +%s)}" > "$AIMAIL_CLAIMS/$1/owner"; }

echo "── canon(): must-collapse ──"
for k in 'T-100' 't100' 't-100' 't100-widget-marks' 'T-100-widget' 'main-T100-wip'; do
  chk "canon('$k') = t100" "$(bash "$G" --canon "$k")" "t100"
done
echo "── canon(): must-NOT-collapse (the false-red direction) ──"
chk "different ticket stays distinct" "$(bash "$G" --canon 'T-200')" "t200"
chk "hex SHA passes through"         "$(bash "$G" --canon 'b3ef4796')" "b3ef4796"
chk "SHA case folds (hex is case-insensitive)" "$(bash "$G" --canon 'B3EF4796')" "b3ef4796"
chk "no spurious ticket match in 'latest-2026'" "$(bash "$G" --canon 'latest-2026')" "latest2026"

echo "── ARM 1: the actual 01:25 event, replayed ──"
fresh; bash "$G" 't100-widget-marks' code-review >/dev/null 2>&1
bash "$G" 'T-100-widget' audit >/dev/null 2>&1; chk "2nd spelling REFUSED" "$?" "1"
out=$(bash "$G" 'T-100-widget' audit 2>&1) || true
chk "refusal names the real holder" "$(printf '%s' "$out" | grep -c 'code-review')" "1"
# ③ the accepts control, on the nearest valid input
bash "$G" 'T-200' foundation >/dev/null 2>&1; chk "a DIFFERENT ticket still acquires" "$?" "0"

echo "── ARM 2: SHA path unchanged (gates have never collided; keep it that way) ──"
fresh
bash "$G" 'b3ef4796' main  >/dev/null 2>&1; chk "SHA acquires" "$?" "0"
bash "$G" 'b3ef4796' audit >/dev/null 2>&1; chk "same SHA refused to 2nd seat" "$?" "1"
bash "$G" '03bb950f' audit >/dev/null 2>&1; chk "different SHA acquires" "$?" "0"

echo "── ARM 3: release is canonical too, or canonicalisation strands claims ──"
fresh; bash "$G" 't100-widget-marks' code-review >/dev/null 2>&1
out=$(bash "$G" --release 'T-100' code-review 2>&1) || true
chk "release via another spelling" "$(printf '%s' "$out" | grep -c RELEASED)" "1"
bash "$G" 'T-100-widget' audit >/dev/null 2>&1; chk "freed door reopens" "$?" "0"
out=$(bash "$G" --release 't100' main 2>&1) || true
chk "release by a non-owner still REFUSED" "$(printf '%s' "$out" | grep -c REFUSED)" "1"

echo "── ARM 4: migration — claims taken before this shipped are raw-named ──"
fresh; legacy 't100-widget-marks' code-review
bash "$G" 'T-100' audit >/dev/null 2>&1; chk "legacy raw claim blocks canonical acquire" "$?" "1"
chk "back-out leaves no orphan canonical dir" "$([ -d "$AIMAIL_CLAIMS/t100" ] && echo yes || echo no)" "no"
out=$(bash "$G" --release 't100-widget-marks' code-review 2>&1) || true
chk "legacy claim is releasable, not stranded" "$(printf '%s' "$out" | grep -c RELEASED)" "1"
fresh; legacy 't100-widget-marks' code-review
out=$(bash "$G" --release 'T-100' main 2>&1) || true
chk "legacy claim not stealable by another seat" "$(printf '%s' "$out" | grep -c REFUSED)" "1"

echo "── ARM 5: degenerate key must be refused, never locked ──"
fresh; bash "$G" '---' main >/dev/null 2>&1; chk "empty canon exits 2" "$?" "2"
chk "and locked nothing" "$(find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l)" "0"

echo "── ARM 6: free-form keys still collapse case and punctuation ──"
fresh; bash "$G" 'main-demoitem-demo' main >/dev/null 2>&1
bash "$G" 'main_DEMOITEM_demo' audit >/dev/null 2>&1; chk "free-form variant refused" "$?" "1"

echo "── ARM 7: stale reclaim survives canonicalisation ──"
fresh; legacy 't500' audit "$(( $(date +%s) - 4000 ))"
out=$(bash "$G" 'T-500' main 2>&1) || true
chk "stale claim reclaimed" "$(printf '%s' "$out" | grep -c RECLAIMED)" "1"

echo "── ARM 8: exclusion under TRUE concurrency, not just sequentially ──"
fresh; RACE="$AIMAIL_CLAIMS/../race.$$"; : > "$RACE"
for spell in 'T-100' 't100' 't-100' 't100-widget-marks' 'T-100-widget' 'main-T100-wip'; do
  ( bash "$G" "$spell" "seat-$spell" >> "$RACE" 2>&1 ) &
done
wait
chk "exactly ONE winner across 6 simultaneous spellings" "$(grep -c '^CLAIMED' "$RACE")" "1"
chk "and the other five stood down"                      "$(grep -c 'ALREADY CLAIMED' "$RACE")" "5"
rm -f "$RACE"

echo "── ARM 9: the 01:46 event — a FREE-FORM key with no ticket number ──"
# ⛔ This is the collision the ticket rule did NOT catch: `nightly-report` (audit) vs
#   `main-nightly-report` (main), 49s apart, both acquires succeeded. An affix is a free variable.
fresh; bash "$G" 'nightly-report' audit >/dev/null 2>&1
bash "$G" 'main-nightly-report' main >/dev/null 2>&1; chk "affixed free-form alias REFUSED" "$?" "1"
out=$(bash "$G" 'main-nightly-report' main 2>&1) || true
chk "refusal names the holder" "$(printf '%s' "$out" | grep -c 'audit')" "1"
# reverse order — containment must be symmetric
fresh; bash "$G" 'main-nightly-report' main >/dev/null 2>&1
bash "$G" 'nightly-report' audit >/dev/null 2>&1; chk "and symmetric (longer claimed first)" "$?" "1"
# ③ the accepts control on the nearest valid input
fresh; bash "$G" 'nightly-report' audit >/dev/null 2>&1
bash "$G" 'provenance-census' main >/dev/null 2>&1; chk "an UNRELATED census still acquires" "$?" "0"

echo "── ARM 10: containment must NOT swallow different tickets or short keys ──"
fresh; bash "$G" 'T-200' foundation >/dev/null 2>&1
bash "$G" 'T-44' main >/dev/null 2>&1; chk "t20 vs t200 stay DISTINCT (ticket = exact)" "$?" "0"
fresh; bash "$G" 'main-demoitem-demo' main >/dev/null 2>&1
bash "$G" 'tgateclaim-keynorm' audit >/dev/null 2>&1; chk "unrelated free-form keys distinct" "$?" "0"

echo "── ARM 11: short-vs-long SHA of ONE commit — latent hole, closed by the same rule ──"
fresh; bash "$G" 'b3ef4796' main >/dev/null 2>&1
bash "$G" 'b3ef4796a1c2' audit >/dev/null 2>&1; chk "longer SHA of same commit REFUSED" "$?" "1"
fresh; bash "$G" 'b3ef4796' main >/dev/null 2>&1
bash "$G" '03bb950f' audit >/dev/null 2>&1; chk "a DIFFERENT SHA still acquires" "$?" "0"

echo "── ARM 12: the 04:57 event — argc dispatch, replayed ──"
# ⛔ There is no `acquire` subcommand. A bare first word with a 3rd argument
#   used to fall through to the acquire path with RAW=<word>, SEAT=<real key>,
#   and the real seat silently discarded — printing CLAIMED while leaving the
#   real key open, and corrupting the owner field. Fired for real once
#   (framing, live, 05:39, on a gate lock). Fix: refuse on argument SHAPE.
fresh
out=$(bash "$G" acquire realkey realseat 2>&1); rc=$?
chk "bare 3-arg form REFUSED, not silently mis-parsed" "$rc" "2"
chk "and nothing got locked under it" "$(find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l)" "0"
out=$(bash "$G" realkey realseat trailing 2>&1); rc=$?
chk "trailing garbage (3 args, different shape) REFUSED" "$rc" "2"
out=$(bash "$G" realkey realseat --role 2>&1); rc=$?
chk "--role with no value (3 args) REFUSED" "$rc" "2"
out=$(bash "$G" --acquire realkey realseat 2>&1); rc=$?
chk "unknown -- flag REFUSED, not treated as a bare key" "$rc" "2"
fresh; bash "$G" realkey realseat >/dev/null 2>&1; chk "valid 2-arg form still acquires" "$?" "0"

echo "── ARM 13: the 04:51 event — (ticket,role) compound key ──"
# ⛔ A ticket-shaped impl claim and a ticket-shaped gate claim on the SAME
#   ticket used to collapse to one door, refusing the mandated author != gater
#   pair. Fix: an optional --role splits the door into (ticket,role).
fresh
bash "$G" 't200-gizmo-gateready' foundation --role impl >/dev/null 2>&1
out=$(bash "$G" 't200' code-review --role gate 2>&1); rc=$?
chk "impl and gate on the SAME ticket BOTH acquire" "$rc" "0"
chk "impl door is t200:impl" "$(bash "$G" --canon 't200-gizmo-gateready' --role impl)" "t200:impl"
chk "gate door is t200:gate"  "$(bash "$G" --canon 't200' --role gate)" "t200:gate"
fresh; bash "$G" 't200' main --role impl >/dev/null 2>&1
out=$(bash "$G" 'T-200-fix' audit --role impl 2>&1); rc=$?
chk "same ticket, SAME role, different spelling REFUSED" "$rc" "1"
chk "refusal names the holder" "$(printf '%s' "$out" | grep -c 'main')" "1"
fresh; bash "$G" 't200' main >/dev/null 2>&1
out=$(bash "$G" 'T-200' audit --role impl 2>&1); rc=$?
chk "a BARE (no-role) ticket claim blocks a later role claim (safe transition)" "$rc" "1"
fresh; bash "$G" 't200' main --role impl >/dev/null 2>&1
out=$(bash "$G" 'T-200' audit 2>&1); rc=$?
chk "and the reverse: a role claim blocks a later bare claim too" "$rc" "1"
fresh
chk "canon() is idempotent on an already-role-suffixed string" \
    "$(bash "$G" --canon 't200:impl')" "t200:impl"
fresh; bash "$G" 't200' main --role impl >/dev/null 2>&1
out=$(bash "$G" --release 't200' main --role impl 2>&1)
chk "--release accepts --role and releases the right door" "$(printf '%s' "$out" | grep -c RELEASED)" "1"
bash "$G" 'T-200' audit --role impl >/dev/null 2>&1; chk "freed role-door reopens" "$?" "0"
fresh; bash "$G" 't500' foundation --role impl >/dev/null 2>&1
out=$(bash "$G" 't200' main --role impl 2>&1); rc=$?
chk "a DIFFERENT ticket with the same role still acquires" "$rc" "0"

echo "── ARM 14: status-message field (2026-08-20, ISSUES_2026-08-20.md sec 5) ──"
# ⚠ Built as a `--desc` FLAG, not the design session's illustrative bare 3rd
#   positional argument — that form was tried first and RETRACTED here, in
#   this file, because it collides with ARM 12's own FIFTH FAILURE protection:
#   a bare `acquire <key> <seat>` is ALSO exactly 3 tokens with a non-"--role"
#   3rd token, so "3 args = description" silently re-opened the historical
#   mis-parse instead of refusing it. This arm exists to keep that collision
#   from regressing silently if anyone "simplifies" this back to positional.
fresh
out=$(bash "$G" 'descA' main --desc "verifying T-437 item 3" 2>&1); rc=$?
chk "acquire with --desc succeeds" "$rc" "0"
chk "--list shows the description" "$(bash "$G" --list | grep -c 'verifying T-437 item 3')" "1"

fresh
out=$(bash "$G" 't600' foundation --role impl --desc "gate-checklist skill build" 2>&1); rc=$?
chk "--role and --desc compose on one acquire" "$rc" "0"
chk "--list shows BOTH the role-door and the description" \
    "$(bash "$G" --list | grep 't600:impl' | grep -c 'gate-checklist skill build')" "1"

fresh; bash "$G" 'descB' main >/dev/null 2>&1
chk "no --desc given -> owner-file line has no trailing separator" \
    "$(grep -c ' | ' "$AIMAIL_CLAIMS/descb/owner")" "0"
chk "no --desc given -> owner-file field 1/3 (seat/epoch) still cut cleanly" \
    "$(cut -d' ' -f1 "$AIMAIL_CLAIMS/descb/owner")" "main"

# ⭐ THE REGRESSION THIS ARM EXISTS TO PIN — re-run ARM 12's own scenario and
#   confirm it is STILL refused now that a 3rd argument has a new meaning.
fresh
out=$(bash "$G" acquire realkey realseat 2>&1); rc=$?
chk "ARM 12's regression still refused (bare 3-arg 'acquire ...')" "$rc" "2"
chk "and still locked nothing" "$(find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l)" "0"
out=$(bash "$G" realkey realseat 'a plausible-looking description' 2>&1); rc=$?
chk "bare 3rd positional arg is STILL refused, not silently accepted as desc" "$rc" "2"

echo "── ARM 15: --desc malformed shapes, refused structurally ──"
fresh
out=$(bash "$G" descC main --desc 2>&1); rc=$?
chk "--desc with no value REFUSED" "$rc" "2"
out=$(bash "$G" descD main --desc "x" --role impl 2>&1); rc=$?
chk "--desc before --role (wrong order) REFUSED" "$rc" "2"
out=$(bash "$G" descE main --role 2>&1); rc=$?
chk "--role with no value still REFUSED (ARM 12 unaffected by this change)" "$rc" "2"
chk "nothing locked across all of ARM 15's refusals" \
    "$(find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l)" "0"

echo "── ARM 16: description text is sanitised and survives a reclaim ──"
fresh
bash "$G" 'descF' main --desc "line one
line two" >/dev/null 2>&1
chk "an embedded newline is flattened -- owner file stays single-line" \
    "$(wc -l < "$AIMAIL_CLAIMS/descf/owner")" "1"
chk "and both halves of the text survive, space-joined" \
    "$(grep -c 'line one line two' "$AIMAIL_CLAIMS/descf/owner")" "1"

fresh; legacy 'descg' audit "$(( $(date +%s) - 4000 ))"
out=$(bash "$G" 'descg' main --desc "reclaimed with a fresh reason" 2>&1)
chk "a reclaim carries the NEW claimant's description, not the old one" \
    "$(printf '%s' "$out" | grep -c RECLAIMED)" "1"
chk "the reclaimed owner file shows the new description" \
    "$(grep -c 'reclaimed with a fresh reason' "$AIMAIL_CLAIMS/descg/owner")" "1"

echo "── ARM 17: --release is unaffected — --desc was never asked for there ──"
fresh; bash "$G" 'desch' main --desc "why" >/dev/null 2>&1
out=$(bash "$G" --release 'desch' main --desc "irrelevant" 2>&1); rc=$?
chk "--release does not accept --desc (out of scope, refused structurally)" "$rc" "2"
out=$(bash "$G" --release 'desch' main 2>&1)
chk "plain release of a --desc'd claim still works" "$(printf '%s' "$out" | grep -c RELEASED)" "1"

echo "── ARM 18: usage() prints the WHOLE block, not a truncated one ──"
# ⛔ 2026-08-20: usage() was a hardcoded `sed -n '59,72p'` and the --desc feature
#   grew the USAGE comment past line 72 without updating it -- --help printed a
#   block cut off mid-sentence. Neither of the two gates on that build caught
#   it, since no assertion checked --help's literal text until this one. Pins
#   the FINAL LINE of the comment block, so a future edit that grows the block
#   again fails HERE rather than silently truncating.
fresh
HELP_OUT=$(bash "$G" --help 2>&1)
chk "usage() output contains the block's actual final line" \
    "$(printf '%s' "$HELP_OUT" | grep -c "a losing seat's worktree cleanup cost more than the race itself")" "1"
chk "usage() output does NOT cut off mid-sentence on the --desc paragraph" \
    "$(printf '%s' "$HELP_OUT" | grep -c 'no existing 2-arg or --role caller changes')" "1"
chk "and nothing got locked by a bare --help" \
    "$(find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d | wc -l)" "0"

echo "── ARM 19: SIXTH FAILURE — a --role (or an already-canonical raw key) cannot escape \$DIR ──"
# ⛔⛔ 2026-08-31, found in review before this ever shipped: canon()'s ticket
#   branches (the idempotence passthrough AND the --role splice) never
#   sanitised for path-unsafe characters the way the free-form branch's own
#   `tr -cd 'a-z0-9'` does implicitly. $SHA drives `mkdir "$DIR/$SHA"` and, on
#   release, `rm -rf "${DIR:?}/${SHA:?}"` -- reproduced live in an isolated
#   sandbox: a fresh acquire with `--role "impl/../../pwned2"` created
#   `pwned2` as a SIBLING of the claims directory, and the matching --release
#   call `rm -rf`'d it. Both via the tool's own documented --role workflow,
#   not a contrived corner case.
# This arm runs under its OWN scratch parent (not the shared $TMPDIR) so that
# even if the guard regressed and the traversal actually escaped, the escape
# target is still inside a directory this arm fully controls and removes --
# never the real shared /tmp.
# The real exploit needs a legitimate `t100:impl` directory to ALREADY exist
# before the traversal: plain `mkdir "$DIR/$SHA"` cannot create more than one
# new path level at once, so `t100:impl/../../pwned2` only resolves past the
# `t100:impl` component if that component is real. This is exactly the order
# the live sandbox reproduction used — claim it for real FIRST, matching the
# actual exploit chain, not a shortcut that would let the escape assertions
# below pass vacuously (true on both guarded AND vulnerable code) instead of
# actually discriminating between them.
ARM19_PARENT="$(mktemp -d)"
ARM19_CLAIMS="$ARM19_PARENT/claims"
(
  export AIMAIL_CLAIMS="$ARM19_CLAIMS"
  mkdir -p "$AIMAIL_CLAIMS"
  bash "$G" 't100' seatA --role impl >"$ARM19_PARENT/out0" 2>&1
  bash "$G" 't100' seatC --role "impl/../../pwned2" >"$ARM19_PARENT/out1" 2>&1
  echo "$?" > "$ARM19_PARENT/rc1"
  bash "$G" 't100:impl/../../pwned3' seatD >"$ARM19_PARENT/out2" 2>&1
  echo "$?" > "$ARM19_PARENT/rc2"
  bash "$G" --release 't100' seatC --role "impl/../../pwned2" >"$ARM19_PARENT/out3" 2>&1
  echo "$?" > "$ARM19_PARENT/rc3"
  find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l > "$ARM19_PARENT/nlocked"
)
chk "the prerequisite ordinary --role claim succeeds (control, not over-collapsed)" \
    "$(grep -c CLAIMED "$ARM19_PARENT/out0")" "1"
chk "a traversal --role is REFUSED (exit 2), not accepted" "$(cat "$ARM19_PARENT/rc1")" "2"
chk "refusal names the unsafe key so it's diagnosable" \
    "$(grep -c 'unsafe key' "$ARM19_PARENT/out1")" "1"
chk "nothing escaped \$AIMAIL_CLAIMS -- no sibling 'pwned2' dir exists" \
    "$([ -d "$ARM19_PARENT/pwned2" ] && echo 1 || echo 0)" "0"
chk "the ALREADY-CANONICAL raw-key path (no --role) is refused the same way" "$(cat "$ARM19_PARENT/rc2")" "2"
chk "no sibling 'pwned3' dir exists either" \
    "$([ -d "$ARM19_PARENT/pwned3" ] && echo 1 || echo 0)" "0"
chk "the matching --release call is ALSO refused, not just the acquire" "$(cat "$ARM19_PARENT/rc3")" "2"
chk "only the ONE legitimate claim is locked -- traversal attempts left nothing extra" \
    "$(cat "$ARM19_PARENT/nlocked")" "1"
rm -rf "$ARM19_PARENT"

echo "── ARM 20: SEVENTH FAILURE — a documented norm is not enforcement: release-guard ──"
# ⛔⛔⛔ 2026-09-01/02: the lock-through-commit norm (hold a shared-file claim
#   until the edit actually commits, not until the raw write succeeds) was
#   documented in SKILL.md at 11:13 and violated at 19:46 by a seat that
#   helped write it -- the claim released the moment a write succeeded, and a
#   later landing's sync overwrote the live file before it was ever committed:
#   the 5th destroyed-uncommitted-work loss in two days. This arm proves the
#   MECHANISM (AIMAIL_GUARDED_RELEASE_<KEY> + --release's dirty-check), not
#   just the norm, actually closes that gap.
# Runs under its own scratch git repo + parent dir (never the real project's
# TODO.md, even though the real config guards it) so this arm stays hermetic
# regardless of what etc/aimail.conf has configured for the real project.
ARM20_PARENT="$(mktemp -d)"
ARM20_CLAIMS="$ARM20_PARENT/claims"
ARM20_REPO="$ARM20_PARENT/repo"
mkdir -p "$ARM20_CLAIMS" "$ARM20_REPO"
(
  cd "$ARM20_REPO"
  git init -q
  git config user.email t@t.com
  git config user.name t
  echo "line1" > GUARDED.md
  git add GUARDED.md
  git commit -qm initial
  export AIMAIL_CLAIMS="$ARM20_CLAIMS"
  export AIMAIL_GUARDED_RELEASE_ARM20KEY="$ARM20_REPO/GUARDED.md"

  bash "$G" arm20key seatA >"$ARM20_PARENT/out_acq1" 2>&1
  bash "$G" --release arm20key seatA >"$ARM20_PARENT/out_rel1" 2>&1
  echo "$?" > "$ARM20_PARENT/rc_rel1"

  bash "$G" arm20key seatA >"$ARM20_PARENT/out_acq2" 2>&1
  echo "line2" >> GUARDED.md
  bash "$G" --release arm20key seatA >"$ARM20_PARENT/out_rel2" 2>&1
  echo "$?" > "$ARM20_PARENT/rc_rel2"
  find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l > "$ARM20_PARENT/nlocked_after_refuse"

  bash "$G" --release arm20key seatA --handoff seatB >"$ARM20_PARENT/out_rel3" 2>&1
  echo "$?" > "$ARM20_PARENT/rc_rel3"
  find "$AIMAIL_CLAIMS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l > "$ARM20_PARENT/nlocked_after_handoff"

  # unguarded key, same dirty file present in the SAME repo/cwd -- proves the
  # guard is keyed on the CLAIM, not a global "any dirty file blocks anything".
  bash "$G" arm20nokey seatA >"$ARM20_PARENT/out_acq3" 2>&1
  bash "$G" --release arm20nokey seatA >"$ARM20_PARENT/out_rel4" 2>&1
  echo "$?" > "$ARM20_PARENT/rc_rel4"
)
chk "control: acquire while clean succeeds" "$(grep -c CLAIMED "$ARM20_PARENT/out_acq1")" "1"
chk "release while clean succeeds (no guard false-positive)" "$(cat "$ARM20_PARENT/rc_rel1")" "0"
chk "re-acquire for the dirty test succeeds" "$(grep -c CLAIMED "$ARM20_PARENT/out_acq2")" "1"
chk "release while the guarded path is dirty is REFUSED (exit 1)" "$(cat "$ARM20_PARENT/rc_rel2")" "1"
chk "the refusal names the guarded path" "$(grep -c 'guards.*GUARDED.md' "$ARM20_PARENT/out_rel2")" "1"
chk "the refusal prints the actual dirty diff" "$(grep -c '^   M GUARDED.md' "$ARM20_PARENT/out_rel2")" "1"
chk "refused release leaves the claim LOCKED, not released" "$(cat "$ARM20_PARENT/nlocked_after_refuse")" "1"
chk "--handoff bypasses the refusal (exit 0)" "$(cat "$ARM20_PARENT/rc_rel3")" "0"
chk "--handoff's transfer is recorded in the release's own output" "$(grep -c 'HANDOFF arm20key: seatA -> seatB' "$ARM20_PARENT/out_rel3")" "1"
chk "after the handoff release, the claim is actually gone" "$(cat "$ARM20_PARENT/nlocked_after_handoff")" "0"
chk "an UNGUARDED key releases fine despite the same dirty file on disk" "$(cat "$ARM20_PARENT/rc_rel4")" "0"
rm -rf "$ARM20_PARENT"

echo
printf 'gateclaim key namespace: %d/%d passed\n' "$PASS" "$((PASS+FAIL))"
if [ "$FAIL" -ne 0 ]; then printf '  FAILED: %s\n' "${FAILURES[@]}"; exit 1; fi
