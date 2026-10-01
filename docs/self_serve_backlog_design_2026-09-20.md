# Self-serve backlog on a quiet heartbeat (design note)

fable, 2026-09-20. Design only; nothing here is built. Per the project owner's mandate (relayed by
assistant, 20260920T191753, TOP PRIORITY 2): fleet throughput tonight visibly depended on
assistant actively watching and dispatching — a seat that finishes its own assigned work with
nothing new queued just sits idle on the next heartbeat, a structural dependency on a
human/orchestrator remembering to check, the same family of gap as the wedged-session watchdog
(a mechanism that needs zero cooperation or memory from any seat's own turn), but at the
opposite end: that one catches a seat NOT doing its job; this one is about a seat that has
genuinely finished and has nothing to do next, when there IS real work sitting available.

## 1. Why this is an instruction problem, not a new mechanical check

The watchdog (item 1, landed `2d10851`) needed real new code because a bash cron job cannot
*reason* about whether a session is genuinely stuck — it can only compare fields. This ask is
different in kind: **a heartbeat wake already hands control to a full reasoning turn.**
`lib/poller.sh`'s own heartbeat branch (`WAKE=heartbeat: no mail for ${heartbeat_sec}s`, the
"fleet-quiet safety net") already causes the harness to invoke a fresh Claude turn for that
seat — the gap is not that nothing runs, it's that nothing in that turn's own wake-up text
tells it to actively go look for backlog work instead of just noting "no mail" and re-arming.
Assistant's own already-in-progress edit to this exact function (uncommitted, confirmed via
`git diff lib/poller.sh` at write time) already strengthens this once — it tells a waking seat
to check `gateclaim.sh --list` and its own genuine working state before re-arming. This design
is the next, complementary layer on the SAME mechanism: **checking for real, unowned, in-domain
backlog and self-claiming it**, not a separate system.

This means the actual "build" here is mostly **more instruction text in the same heartbeat
message**, not new bash logic to interpret TODO.md — parsing a large, prose-heavy, ever-evolving
narrative file mechanically (regex for "unowned", "no owner assigned", "needs the project owner's word")
would be exactly the kind of brittle, easily-fooled mechanism this fleet's own standing
practice already avoids elsewhere (every ownership judgment call made tonight — one ticket vs.
page_geometry's different shapes, which of the 14 decision-log items were fable's, which
gateclaim entries needed a fresh look vs. trusting the description — was read and reasoned
about by a real turn, never regex-matched). The reasoning belongs to the resuming seat, which
is exactly what a heartbeat wake already provides; the missing piece is only telling it to do
the reasoning, not building a parser to do it worse.

## 2. What's cheap to check MECHANICALLY, before the reasoning turn even starts

`lib/poller.sh` can trivially gate WHEN the self-serve instruction is even shown, no new
subsystem required:

- **Already-true by construction: never fires during a genuine park.** The heartbeat branch
  only runs in the poller's own "not currently parked" path — a parked seat never reaches this
  code at all (confirmed by reading the loop's own structure: the `throttled` check and its
  `continue` sit earlier in the same `while true` loop). No new guard needed for guardrail #4.
- **Cheap to add: skip the self-serve prompt if the seat already holds a gateclaim.** A one-line
  check (`gateclaim.sh --list | grep -q "	$seat	"` or equivalent) before printing the
  self-serve paragraph — a seat mid-claim on something should keep going on that, not be
  nudged to grab a second thing. This directly implements guardrail #1's spirit (don't invite
  a claim collision) at zero reasoning cost, before the turn even starts thinking about it.
- **The exclusivity guardrail (#1, never grab something already claimed by someone else) is
  ALREADY mechanically enforced** — `gateclaim.sh`'s own atomic acquire refuses a taken key
  outright. The instruction only needs to tell the seat what to do on a REFUSAL (fall back,
  don't force it, don't grab something else impulsively either — re-arm as normal), not to
  re-implement the exclusivity check itself.

## 3. What has to stay a reasoning instruction, not a mechanical rule

- **"Real, unowned, in-domain."** TODO.md's own append-only-narrative convention (stated at its
  own top) means "unowned" is a judgment about the LATEST dated ruling on an item, not a fixed
  keyword — this fleet already has a standing rule for exactly this ("read a ticket's own latest
  ruling before acting on a relayed clearance," aimail skill's own reference doc) precisely
  because a stale summary earlier in an entry can be superseded by a later one. A seat waking on
  a heartbeat needs to apply that SAME reading discipline, not a keyword match.
- **The explicit "needs the project owner's word" exclusion** (the WMAPE morning-triage items are the
  named example) is exactly this kind of judgment: recognizing "filed for triage, not yet
  decided" as different from "filed and ready to build" requires reading the entry, not
  detecting a string.
- **"In its own established lane."** Recognizing that a given TODO.md item is audit-shaped vs.
  framing-shaped vs. fable-shaped is the same skill every design-authority ruling tonight
  already required — not reducible to a fixed keyword-to-seat map, since new item shapes appear
  constantly and a rigid map would either miss them or force a wrong-lane grab through a stale
  category.

**Recommendation: state this as an explicit instruction in the heartbeat message itself**
(added to assistant's own already-in-progress warning text in the same function), roughly:
"If gateclaim.sh shows you hold nothing, read TODO.md's most recent entries for a real item that
is (a) actually unowned as of its OWN latest ruling, not a stale earlier line, (b) not marked as
waiting on the project owner's word, and (c) genuinely in your own established lane. If one exists,
`gateclaim.sh <key> <seat> --desc "..."` it and start working. If the claim is refused (someone
else got there first), fall back to standing by, don't grab something else impulsively. Report
the self-claim to assistant, briefly, either way." This puts the judgment where this fleet
already trusts it — the resuming seat's own reasoning — while making the MECHANICAL guardrails
(park suppression, already-holding-a-claim suppression, atomic exclusivity) real code, not
instruction text that could be skipped.

## 4. Coordination note, not a design point

`lib/poller.sh`'s heartbeat branch has an uncommitted, in-progress edit from assistant right now
(the "this is not a no-op" warning text, confirmed live via `git diff` while writing this note).
This design's own build should ADD to that same block, not replace or work around it — the two
are the same mechanism at two layers (check your own state honestly; then, if genuinely idle
with nothing owed, go find real work) — and should be sequenced so assistant's own edit lands
first (or the two land together in one pass) rather than either seat editing the same
uncommitted lines independently and risking one silently overwriting the other.

## 5. What this deliberately does not do

- **Does not remove the "report to assistant" step.** Self-directed does not mean silent — the
  design keeps a mail to assistant on every self-claim, same visibility principle the migration-
  recommendation mailer (budget-distribution design, item 4) and this design's own sibling
  watchdog both already use: decide and report, the supervisor stays informed even when nothing
  needs their explicit go-ahead first.
- **Does not build a TODO.md parser or a keyword-to-seat ownership map.** Named explicitly in
  §3 as the wrong shape for this problem — would be brittle against TODO.md's own evolving,
  prose-first convention and duplicate reasoning this fleet's seats already do correctly by
  hand every night.
- **Does not touch check 2 of the watchdog design** (gateclaim-age-vs-reality, still held per
  its own agreement) — a different, unrelated mechanism that happens to share a mail (both
  named "TOP PRIORITY" tonight) but not a design.

## 6. Owner

Design-only note; report back for gate before building, per standing practice. Build itself is
small (one instruction paragraph in `lib/poller.sh`'s existing heartbeat branch, plus the two
cheap mechanical gates in §2) — the size of this note is mostly the reasoning for WHY it should
stay small and instruction-shaped rather than a new subsystem, not a preview of a large build.
