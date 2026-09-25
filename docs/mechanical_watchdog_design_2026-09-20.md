# Mechanical wedged-session + stale-claim watchdog (design note)

fable, 2026-09-20. Design only; nothing here is built. Per the project owner's direct mandate (relayed by
assistant, 20260920T184459, TOP PRIORITY): a real 2+ hour incident today (foundation's live
session sat `state: "blocked"` per `claude agents --json` while its own poller kept cycling
normal 30-minute heartbeats and a real go-ahead sat unprocessed in its inbox the whole time) means
this needs a mechanism that fires with **zero cooperation or memory from any seat**, not another
reminder that depends on a seat's own turn running.

## 1. Why today's mechanisms did not catch this, confirmed by reading the actual code

- `aimail fleet <seat>` / `fleet_sweep` (`lib/fleet.sh`) already classify session liveness, but
  through `_fleet_load_sessions` → `sessions.sh`'s own transcript-mtime-based classifier
  (ARMED/WORKING/UNARMED — no "blocked" state exists in that vocabulary at all). A session can be
  internally wedged (stuck mid-tool-call, waiting on something that will never resolve) while its
  transcript still looks recently-touched enough to read as healthy. **Confirmed: nothing in this
  codebase calls `claude agents --json` today** (`grep -rn "agents --json" lib/*.sh` — zero hits) —
  this is a genuinely new, independent data source, not an extension of the existing classifier.
- The poller's own 30-minute heartbeat (`lib/poller.sh`'s `WAKE=heartbeat`) is a dead-man's switch
  for "is anyone invoking this session at all," not for "is the invocation actually completing."
  Today's incident shows these are different facts: the poller cycle (exit → harness re-invokes →
  new turn starts → poller re-arms) can complete its OUTER loop (hence "no mail" heartbeats firing
  on schedule) while the INNER turn itself gets stuck and never reaches the code that would notice
  a real message sitting unprocessed.

## 2. Ground truth confirmed live, both checks

**`claude agents --json` is per-account**, not machine-global (confirmed: `CLAUDE_CONFIG_DIR=~/.claude-work claude agents --json` and the `r2` equivalent both return `0 sessions` right now, while the ambient `research` account returns the 9 real live sessions) — a watchdog covering the whole fleet must loop over the account
pool, same `AIMAIL_FLEET_ACCOUNTS` idiom `_autopilot_seat_groups` already uses for budget
autopilot. Each `background`-kind entry carries `sessionId`, `status` ("busy"/etc, process-level),
and `state` ("working"/"blocked"/"done" — unofficial/undocumented, no `--help` text for the
vocabulary, same "confirmed live, not published" category as the budget usage endpoint this fleet
already depends on elsewhere).

**A session-id → seat mapping already exists and needs no new registration mechanism**:
`stop_guard.sh register <seat>` (every seat already runs this every session, per the aimail
skill's own standing "Starting a session" checklist) writes `$STATE_DIR/stopguard/session.<sid>`
containing the seat name in plain text — confirmed live (`session.67bfd143-...` → `fable`,
matching this very session). The watchdog reads this file, it does not write to it or duplicate
it.

**`gateclaim.sh --list` already prints machine-parseable age**: seat, ISO timestamp, AND raw
epoch, one line per claim (confirmed against the live board today).

## 3. Check 1 — session-state watchdog

`fleet_watchdog_sessions()` (new function, `lib/fleet.sh` or a new `lib/watchdog.sh` — build
decides; either way, run from the SAME cron line as `fleet sweep`, same 5-minute cadence):

1. Resolve the account pool: `AIMAIL_FLEET_ACCOUNTS` if set, else the distinct accounts
   `_autopilot_seat_groups` already resolves from live seats (same fallback shape, no new
   discovery mechanism).
2. For each account: `CLAUDE_CONFIG_DIR=<dir> claude agents --json`, filter to `kind=="background"`.
3. For each background session: look up its seat via `$STATE_DIR/stopguard/session.<sessionId>`.
   No mapping found → skip (an unregistered session is a known, by-design pass-through, same
   convention `poller_guard.sh` already uses for a stray human/subagent session — not this
   watchdog's problem to solve).
4. If `state` is present and not `"working"` (i.e. `"blocked"`, or any future value that isn't
   `"working"` — an ALLOWLIST of the one known-good value, not a denylist of known-bad ones, so an
   undocumented API changing shape fails toward alerting, not toward silence): bump a per-seat
   streak counter (`$STATE_DIR/watchdog_blocked_streak_<seat>`), **exact same idiom as
   `AUTOPILOT_UNMEASURABLE_N`/`_autopilot_measured_fail` in `budget.sh`** — do not invent a second
   streak mechanism when one already exists and is already proven.
5. **Threshold: 3 consecutive ticks (15 minutes)** — reusing fable's own already-ruled number for
   the autopilot-blind alarm ("long enough that one transient blip never pages anyone, short
   enough that this never again runs blind for hours"), not a new number invented for this check.
   15 minutes is a small fraction of today's 2+ hour undetected window — this alone turns a
   multi-hour blind spot into a 15-minute one.
6. On threshold: mail the supervisor, same shape as `fleet_sweep`'s own alert body (seat, state,
   how long, the raw `claude agents --json` entry for direct inspection), deduped on
   `(seat, sessionId, state)` so the SAME ongoing block doesn't re-alert every tick, but a genuinely
   new block (even of the same seat) gets its own alert — identical dedup philosophy to
   `fleet_sweep`'s own `(pid,beat)` key.
7. On recovery (`state` reads `"working"` again, or the session disappears from the list entirely):
   clear the streak file. Self-healing, no separate "all clear" mail, matching `fleet_sweep`'s own
   one-directional dedup philosophy (alert once per incident, no recovery spam).

**Why this is independent of the poller heartbeat, by construction**: this reads `claude agents
--json` directly — a fact about the underlying process the harness manages — never the poller's
own heartbeat file, which is exactly the signal that read "fine" for 2+ hours today.

## 4. Check 2 — gateclaim-age-vs-reality watchdog

`fleet_watchdog_claims()`:

1. `gateclaim.sh --list`, parse each line: key, seat, epoch.
2. For each claim older than **90 minutes** (a real FULL battery run is measured elsewhere in this
   fleet's own history at up to ~22 minutes; 90 minutes gives a wide margin above the longest
   observed real-work duration before treating age alone as suspicious — a number to tune once
   this runs for real, named explicitly as a first guess, not a measured constant like the 15-min
   threshold above):
   a. **Primary signal — git activity**: `git log --all --since="<claim's own age>" --grep="<seat
      name>" --oneline` across both real repos (the secondary repo and the primary repo
      checkout's own landing-branch/tracked-branch state) — this fleet's own standing convention
      names the responsible seat in every commit message (confirmed: every commit produced this
      session does this), so grepping commit subjects for the seat's own name is a reliable,
      already-existing signature, not a new convention to invent.
   b. **Secondary signal — outgoing mail**: any file under `$MAIL_DIR/*/archive/*/` (or the live,
      not-yet-acked mailboxes) with a `from: <seat>` header and a `date:` inside the claim's own
      age window. Scoped with `find -newermt` to the relevant window before grepping, not a full
      mailbox scan every tick — this fleet's mailboxes are large (thousands of archived messages
      per seat) and a naive full-grep every 5 minutes does not scale.
   c. If NEITHER signal shows activity in the window: escalate. If EITHER shows activity: the claim
      is old but the seat is demonstrably still working (a long FULL battery, or working on
      something adjacent to the claim without having released it yet) — not a stall, no alert.
3. Dedup on `(key, seat, claim's own acquisition epoch)` — a claim released and re-acquired (a
   genuinely new episode, even under the same key) gets evaluated fresh, matching the exact
   identity discipline `gateclaim.sh`'s own guarded-release mechanism and `seat_unpark_<seat>`
   already use elsewhere in this fleet (key the episode on its own start time, never on "still old
   right now").

## 5. What this design deliberately does NOT do

- **Does not kill or release anything automatically.** Same standing boundary as the budget
  migration-recommendation mailer (item 4 of the earlier budget-distribution design): a wedged
  session or a stale claim needs a human (or a supervisor acting with an explicit go) to actually
  intervene — killing a live process or force-releasing a claim out from under a seat that might
  still be legitimately using it is a real, destructive-adjacent action this fleet's own standing
  rules already reserve for supervised action, not unattended automation.
- **Does not replace `fleet_sweep`'s existing CRASHED/WEDGED/STALLED checks.** Those stay exactly
  as they are; this adds two NEW, independent signals alongside them, run from the same cron
  entry point for operational simplicity (one job, not two competing schedules), not as a
  replacement.
- **Does not attempt to resolve WHICH repo/branch a claim's work lives in.** The git-activity check
  greps commit MESSAGES for the seat's own name across both real repos wholesale, rather than
  trying to map a claim key to a specific branch — simpler, and matches how this fleet already
  reads its own history (by seat name in the message, not by branch-to-claim mapping, which does
  not exist as a formal convention today).

## 6. Build order

1. Check 1 (session-state watchdog) first — it is the DIRECT fix for today's actual incident, the
   simpler of the two mechanically (one already-existing per-account loop, one already-existing
   streak idiom, one already-existing session→seat file), and has no cross-repo git-scanning
   complexity.
2. Check 2 (gateclaim-age-vs-reality) second — genuinely new mechanism (nothing today cross-checks
   a claim's age against git/mail activity), needs the 90-minute threshold tuned against a few
   real long-running claims before trusting it unattended.
3. Wire both into the existing `*/5 * * * * ... fleet sweep` cron line (or a clearly-named sibling
   line immediately after it) rather than a new, separate cron schedule — one thing to remember
   to keep running, not two.

## 7. Open question for the project owner (via assistant) — not resolved here

Assistant's own mail noted a second, separate failure tonight: assistant relying on self-reported
mail/landing confirmations instead of independently checking git/session state on a schedule, and
misjudging main's backlog as stuck by checking the wrong repo. Both checks above are aimed at
CATCHING a wedged seat or stale claim automatically — they do not, by themselves, fix a supervisor
(human or assistant) trusting a self-report over ground truth. That is a process/discipline
question, not a mechanical one this design can close by itself; flagging it back rather than
silently assuming this design solves it too.
