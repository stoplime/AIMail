#!/usr/bin/env bash
# tests/review.sh — `aimail review` and its two enforcement scripts, driven through the real bin/aimail and
# hooks in a throwaway state root, on a synthetic git repo with a stand-in checker. Every refusal arm has an
# acceptance arm next to it. Runs standalone and inside tests/run.sh.
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AIMAIL="$REPO/bin/aimail"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export AIMAIL_ROOT="$T/root" AIMAIL_CONFIG="$T/aimail.conf"
unset PR_READY_OVERRIDE CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
mkdir -p "$AIMAIL_ROOT" "$T/records"
PASS=0; FAIL=0
check() { if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ✔ %s\n' "$1"; else FAIL=$((FAIL+1)); printf '  ✖ %s (expected %s, got %s)\n' "$1" "$3" "$2"; fi; }
rc() { "$@" >"$T/out" 2>"$T/err"; echo $?; }
# as <seat> cmd... : run cmd in a session registered to <seat> (the stop-guard session map)
as() { local seat="$1"; shift; mkdir -p "$AIMAIL_ROOT/state/stopguard"; printf '%s' "$seat" > "$AIMAIL_ROOT/state/stopguard/session.sid-$seat"
       CLAUDE_CODE_SESSION_ID="sid-$seat" "$@"; }
saw() { grep -q -- "$1" "$T/out" "$T/err"; echo $?; }

# a stand-in checker: passes iff the record holds the line PASS-ME; prints a skeleton for --template
cat > "$T/checker.sh" <<'EOS'
#!/usr/bin/env bash
sha="$1"; shift; records=""; tmpl=0
while (( $# )); do case "$1" in --records) records="$2"; shift 2 ;; --template) tmpl=1; shift ;; *) shift ;; esac; done
if (( tmpl )); then printf 'reviewer: <x>\nauthor: <y>\nsha: %s\n' "$sha"; exit 0; fi
grep -q '^PASS-ME' "$records/$sha.md" 2>/dev/null && { echo "PASS stand-in"; exit 0; }
echo "FAIL stand-in: the record lacks PASS-ME"; exit 1
EOS
chmod +x "$T/checker.sh"
git init -q -b base "$T/r"; G=(git -C "$T/r" -c user.name=base-author -c user.email=a@a)
echo base > "$T/r/f"; "${G[@]}" add -A; "${G[@]}" commit -q -m base
"${G[@]}" checkout -q -b work; echo w1 > "$T/r/g"; "${G[@]}" add -A
git -C "$T/r" -c user.name=Writer-Seat -c user.email=w@w commit -q -m "work one"
SHA1="$(git -C "$T/r" rev-parse HEAD)"
cat > "$AIMAIL_CONFIG" <<EOC
AIMAIL_ROOT="$AIMAIL_ROOT"
AIMAIL_REVIEW_REPOS="demo"
AIMAIL_REVIEW_PATH_demo="$T/r"
AIMAIL_REVIEW_RECORDS_demo="$T/records"
AIMAIL_REVIEW_CHECK_demo="$T/checker.sh"
AIMAIL_REVIEW_CHECKER_FILE_demo="$T/checker.sh"
AIMAIL_REVIEW_BASE_demo="base"
AIMAIL_REVIEW_URL_demo="demo-remote"
AIMAIL_REVIEW_PUSH_EXEMPT_demo="^(base|trunk)$"
EOC

echo "start"
check "start by an author (git author name) is refused"        "$(rc "$AIMAIL" review start demo work --by writer-seat)" 3
check "  ...and says who the authors are"                      "$(saw 'Writer-Seat\|writer-seat')" 0
check "start by a seat named with --author is refused"         "$(rc "$AIMAIL" review start demo work --by other-seat --author other-seat)" 3
check "start of an unknown repo is refused"                    "$(rc "$AIMAIL" review start nope work --by rev)" 3
check "start of an unknown branch is refused"                  "$(rc "$AIMAIL" review start demo nobranch --by rev)" 3
check "start by a second seat opens the review"                "$(rc "$AIMAIL" review start demo work --by rev)" 0
check "  the record exists, prefilled with reviewer and author" "$(grep -c '^reviewer: rev$\|^author: writer-seat$' "$T/records/$SHA1.md")" 2
check "start by another seat while one is open is refused"     "$(rc "$AIMAIL" review start demo work --by rev2)" 3
check "start again by the same reviewer is accepted"           "$(rc "$AIMAIL" review start demo work --by rev)" 0
printf 'Seat: Trailer-Seat\n' > /dev/null
echo w2 > "$T/r/h"; "${G[@]}" add -A; "${G[@]}" commit -q -m "work two" -m "Seat: trailer-seat"
check "start by a seat named in a Seat: trailer is refused"    "$(rc "$AIMAIL" review start demo work --by trailer-seat)" 3
"${G[@]}" reset -q --hard "$SHA1"

echo "check and approve"
check "approve without a check is refused"                     "$(rc as rev "$AIMAIL" review approve "$SHA1" --by rev)" 3
check "check fails while the record lacks the line"            "$(rc "$AIMAIL" review check "$SHA1")" 1
check "approve after a FAILED check is refused"                "$(rc as rev "$AIMAIL" review approve "$SHA1" --by rev)" 3
echo "PASS-ME" >> "$T/records/$SHA1.md"
check "check passes once the record is right"                  "$(rc "$AIMAIL" review check "$SHA1")" 0
check "approve by someone who is not the reviewer is refused"  "$(rc as rev2 "$AIMAIL" review approve "$SHA1" --by rev2)" 3
check "approve by an author is refused"                        "$(rc as writer-seat "$AIMAIL" review approve "$SHA1" --by writer-seat)" 3
echo "edited later" >> "$T/records/$SHA1.md"
check "approve after the record changed is refused"            "$(rc as rev "$AIMAIL" review approve "$SHA1" --by rev)" 3
check "check again passes"                                     "$(rc "$AIMAIL" review check "$SHA1")" 0
check "status is not approved before the approval"             "$(rc "$AIMAIL" review status demo work)" 1
OLDV="$(sha256sum "$T/checker.sh" | cut -c1-12)"; echo "# edited after the check" >> "$T/checker.sh"
check "approve by the reviewer after a passing check succeeds" "$(rc as rev "$AIMAIL" review approve "$SHA1" --by rev)" 0
check "the approval row names sha, reviewer and the checker version from CHECK time" "$(awk -F'\t' -v s="$SHA1" -v v="$OLDV" '$2==s && $5=="rev" && $6=="approved" && $7==v {n++} END {print n+0}' "$AIMAIL_ROOT/state/review_approvals.tsv")" 1

echo "the session tie"
check "approve from a session registered to another seat is refused"  "$(rc as rev2 "$AIMAIL" review approve "$SHA1" --by rev)" 3
check "  and says which seat the session is"                          "$(saw "registered to seat 'rev2'")" 0
check "approve from a session registered to no seat is refused"       "$(rc "$AIMAIL" review approve "$SHA1" --by rev)" 3
check "  and says to register"                                        "$(saw 'not registered to a seat')" 0
check "start from a session registered to another seat is refused"    "$(rc as rev2 "$AIMAIL" review start demo work --by rev)" 3
check "status and list work from an unregistered session"             "$(rc "$AIMAIL" review list)" 0

echo "status"
check "status is approved for the branch's current commit"     "$(rc "$AIMAIL" review status demo work)" 0
check "  --quiet prints the one word"                          "$("$AIMAIL" review status demo work --quiet)" approved
check "status --sha is approved for the exact sha"             "$(rc "$AIMAIL" review status --sha "$SHA1")" 0
echo w3 > "$T/r/i"; "${G[@]}" add -A; "${G[@]}" commit -q -m "work three"; SHA2="$(git -C "$T/r" rev-parse HEAD)"
check "a new commit makes the approval stale"                  "$("$AIMAIL" review status demo work --quiet 2>/dev/null)" stale
check "  and status exits non-zero"                            "$(rc "$AIMAIL" review status demo work)" 1
check "a branch never reviewed reads none"                     "$( "${G[@]}" branch other base; "$AIMAIL" review status demo other --quiet 2>/dev/null)" none
check "status of a sha with no review is not approved"         "$(rc "$AIMAIL" review status --sha "$SHA2")" 1

"${G[@]}" checkout -q -b feature/x base; echo f > "$T/r/j"; "${G[@]}" add -A; "${G[@]}" commit -q -m featx; SHA3="$(git -C "$T/r" rev-parse HEAD)"
"${G[@]}" checkout -q work
echo "reject and list"
check "list shows nothing open once approved"                  "$("$AIMAIL" review list | grep -c "$SHA1" )" 0
check "start on the new commit opens a review"                 "$(rc "$AIMAIL" review start demo work --by rev)" 0
check "list shows the open review with its age"                "$("$AIMAIL" review list | grep -c "${SHA2:0:12}.*open")" 1
check "reject needs a reason"                                  "$(rc as rev "$AIMAIL" review reject "$SHA2" --by rev)" 3
check "reject by a non-reviewer is refused"                    "$(rc as rev2 "$AIMAIL" review reject "$SHA2" --by rev2 --reason x)" 3
check "reject by the reviewer with a reason succeeds"          "$(rc as rev "$AIMAIL" review reject "$SHA2" --by rev --reason 'tests read source')" 0
check "a rejected sha reads rejected"                          "$("$AIMAIL" review status --sha "$SHA2" --quiet)" rejected

echo "the push gate"
refs_for() { printf 'refs/heads/work %s refs/heads/work %s\n' "$1" "$(printf '0%.0s' {1..40})"; }
push() { refs_for "$1" | "$REPO/hooks/review_prepush_guard.sh" origin "$2" >"$T/out" 2>"$T/err"; echo $?; }
check "an unapproved sha pushed to a configured remote is refused" "$(push "$SHA2" git@x:demo-remote.git)" 1
check "  and the message says how to proceed"                   "$(saw 'aimail review start')" 0
check "the approved sha is let through"                        "$(push "$SHA1" git@x:demo-remote.git)" 0
check "another remote is not asked"                            "$(push "$SHA2" git@x:elsewhere.git)" 0
check "an exempt branch (a merge target) is not asked"         "$(printf 'refs/heads/base %s refs/heads/base %s\n' "$SHA2" "$(printf '0%.0s' {1..40})" | "$REPO/hooks/review_prepush_guard.sh" origin git@x:demo-remote.git >/dev/null 2>&1; echo $?)" 0
check "a deletion is not asked"                                "$(printf '(delete) %s refs/heads/work %s\n' "$(printf '0%.0s' {1..40})" "$SHA2" | "$REPO/hooks/review_prepush_guard.sh" origin git@x:demo-remote.git >/dev/null 2>&1; echo $?)" 0
check "an override with a reason passes"                       "$(PR_READY_OVERRIDE='hotfix, owner asked' push "$SHA2" git@x:demo-remote.git)" 0
check "  and is logged with sha and reason"                    "$(grep -c "$SHA2.*hotfix, owner asked" "$AIMAIL_ROOT/state/review_overrides.log")" 1
check "an empty override is no override"                       "$(PR_READY_OVERRIDE='  ' push "$SHA2" git@x:demo-remote.git)" 1
check "  and logs nothing more"                                "$(wc -l < "$AIMAIL_ROOT/state/review_overrides.log" | tr -d ' ')" 1

echo "the handoff command"
printf 'pr-description: /tmp/pr-body.md\n' >> "$T/records/$SHA1.md"
check "handoff of a branch whose current sha is not approved is refused"   "$(rc "$AIMAIL" review handoff demo work)" 3
check "  and names the status"                                  "$(saw 'not approved (status: ')" 0
printf '2026-10-01T00:00:00Z\t%s\tdemo\tstl\trev\tapproved\tv\t-\n' "$SHA1" >> "$AIMAIL_ROOT/state/review_approvals.tsv"
"${G[@]}" checkout -q -b stl "$SHA1"; echo w4 > "$T/r/k"; "${G[@]}" add -A; "${G[@]}" commit -q -m w4
check "handoff of a stale branch (approved at an older sha) is refused"    "$(rc "$AIMAIL" review handoff demo stl)" 3
check "  and says stale"                                        "$(saw 'status: stale')" 0
"${G[@]}" checkout -q work
check "handoff of an unknown branch is refused"                 "$(rc "$AIMAIL" review handoff demo nobranch)" 3
check "handoff of an unknown repo is refused"                   "$(rc "$AIMAIL" review handoff nope work)" 3
"${G[@]}" branch -f appr "$SHA1"
check "handoff of an approved branch succeeds"                  "$(rc "$AIMAIL" review handoff demo appr)" 0
check "  and prints the push command"                            "$(grep -c 'git -C .* push origin appr' "$T/out")" 1
check "  and the PR description path from the record"            "$(grep -c '/tmp/pr-body.md' "$T/out")" 1
check "  and logs sha, branch and reviewer"                      "$(grep -c "appr.*$SHA1.*rev" "$AIMAIL_ROOT/state/review_handoffs.log")" 1
check "a refused handoff logs nothing"                          "$(rc "$AIMAIL" review handoff demo work >/dev/null; wc -l < "$AIMAIL_ROOT/state/review_handoffs.log" | tr -d ' ')" 1
check "the removed text-matching hook is gone"                  "$(test -e "$REPO/hooks/review_handoff_guard.sh"; echo $?)" 1
check "the remaining hook is executable and committed 100755"   "$(test -x "$REPO/hooks/review_prepush_guard.sh" && git -C "$REPO" ls-files -s hooks/review_prepush_guard.sh 2>/dev/null | awk '$1!="100755"' | wc -l | tr -d ' ')" 0

echo; echo "review: $PASS passed, $FAIL failed"
exit $(( FAIL > 0 ))
