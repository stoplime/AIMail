---
name: aimail
description: Reference for the aimail fleet-mail CLI (poll, ack, send, fleet, budget, gateclaim, seat, role, review) and the standing operational rules for a multi-seat AI fleet. Use whenever reviewing, gating or approving a branch, or about to say GREEN, approved, ready or PR (aimail review); polling/checking mail, acking a message, sending mail to another seat, checking fleet/seat status, checking or recording token-usage budget, claiming exclusive work with gateclaim, or writing/reading a seat's role handover doc. Also use when unsure of exact aimail syntax rather than guessing it.
---

# aimail — fleet mail, budget, and gate-claim reference

This is the canonical, version-controlled reference for `aimail` and its companion
`gateclaim.sh`, installed as a personal skill (symlinked from every account
directory into `/mnt/workdrive/AI/AIMail/skills/aimail/`) so it survives an
account switch and never needs re-deriving from memory. **When unsure of exact
syntax, read this file — do not guess or invent a flag.** The full design
rationale lives in `/mnt/workdrive/AI/AIMail/README.md`; this file is the
quick-reference command surface plus the rules that caused real incidents when
violated.

## Critical rules — violating these has broken the fleet before

- **Never hand the owner a push command, or call a branch ready, except through `aimail review handoff`.** It is
  the one path that checks the ledger for the branch's exact current commit. A push command typed by hand into a
  reply has skipped the check, however sure the seat is.
- **A review reported only by mail is not an approval.** A seat that says "GREEN", "approved" or
  "passes" about a branch headed for a PR, in a mail or a reply, has approved nothing: an approval is a row
  written by `aimail review approve <sha>`. The receiving seat replies asking for that command, and does not
  act on the result (no landing, no handoff to the owner) until `aimail review status <repo> <branch>` reads
  `approved` for the branch's current commit. This binds the orchestrator too: nothing a mail calls GREEN
  goes to the owner unless the status says approved. A new commit makes the old approval `stale`.

- **Never `kill <pid>` a seat's Claude session; never migrate a seat by hand.**
  The CLI's background-job scheduler tracks every `claude --bg` session against
  its ORIGINAL launch spec (account dir, `--model`, flags: see
  `<config-dir>/jobs/<short-id>/state.json`, key `respawnFlags`). A killed
  process reads as a crash and is RESPAWNED from that spec — original account,
  original model — minutes after any hand relaunch, so the seat ends up running
  TWICE under one session id on two accounts (real incident, 2026-09-21).
  `claude stop <short-id>` deregisters the job cleanly. The one procedure is
  `aimail seat migrate <seat> <account>` (locate → handover → stop, verified
  gone → relaunch with an explicit model → settle → re-verify present on the
  target and absent everywhere else → record); `--dry-run` prints the exact
  commands. Every fleet-session fact (how to find a session from outside, why a
  pid read inside a session is not a handle, the relaunch flag shapes) lives in
  `docs/cli_account_migration.md` — the single authoritative reference. At boot,
  every seat runs `aimail seat confirm <seat> --model <id>` (§ Starting a
  session, step 3b) so a fully dead seat can still be relaunched onto the
  right account from the persisted record.
  **Since 2026-09-22 (the owner's rule) `seat migrate` RESUMES by default**: it
  picks the seat's own previous session on the target from the per-account
  session registry (`aimail seat sessions [seat]`, auto-updated by every
  `seat confirm`/migrate), or carries the current session's transcript
  (`projects/<cwd-slug>/<sid>.jsonl` + its `<sid>/` dir) into the target's
  config dir first -- the missing transcript is what "source session not
  found" meant on every failed move that day. A FRESH session is never a
  fallback: only `--fresh --why "<reason>"`, reserved for a seat that will not
  follow the orchestrator and is blocking the fleet; the path taken is recorded.
  `aimail seat set-session <seat> <acct> <sid> --why` / `reset-session` adjust
  the registry, every change logged with who and why.
- **The supervisor never dies at the hard limit (the owner, 2026-09-22).** Three
  mechanisms, none of which depend on the supervisor's own session: (1) an
  unpark exemption is honoured only BELOW the seat's own cap
  (`AIMAIL_SEAT_CAP_<seat>`, assistant 95) -- at or above it the exempt poller
  parks with `WAKE=hardstop` until a reading under the cap or a ramp; (2) the
  cron `aimail fleet watchdog` checks the supervisor every 5 min and, after a
  ramp, wakes an idle session or resumes a dead one from the session registry
  (flagless `claude --bg --resume <sid>`), one episode at a time with a retry
  knob; (3) when that fails it mails the vice orchestrator
  (`AIMAIL_VICE_SUPERVISOR`, main) and `AIMAIL_HUMAN_ALERT_SEAT` if set, and
  writes `state/ALERT_supervisor_unreachable`, which `aimail session`, `fleet`
  and `doctor` print FIRST for every seat until `aimail fleet supervisor-ack`.
  The supervisor AND the vice (`AIMAIL_PINNED_SEATS`, default "assistant main")
  are PINNED to the work account: `seat migrate` refuses either without
  `--owner-approved "<their words>"`, which is logged. Budget balance is fable's
  (balancer + warnings) and librarian's (ledger) -- not main's.
- **Placement rules (T-917, `lib/placement.sh`, after the 2026-09-22 16:55 park
  with six of nine seats on one account).** Pinned seats never move; the
  supervisor's account is the most precious and takes a non-pinned seat only
  when no other account has headroom; fable is placed by its own model's
  weekly headroom; no account carries more than ceil(non-pinned seats /
  accounts with headroom); ties go to the account that lasts longest at its
  current burn. `seat migrate` REFUSES a move that breaks a rule (override:
  `--owner-approved`), the balancer takes its target from
  `placement_pick`, and `aimail placement [seat]` / `budget pool` / `fleet`
  print the report and flag an imbalance on sight.
- **Run `aimail session [seat]` at the start of every new session, before any
  real work.** One command checks budget mode, role-handover freshness,
  poller state, `stop_guard.sh` registration, AND any project-local Stop-hook
  fork's SEPARATE registration — the exact thing that went silently wrong for
  hours on 2026-09-03 (see "Starting a session," step 0, for the full
  incident). It replaces walking five separate checks by hand and remembering
  that a second, easy-to-forget registration exists at all.
- **A poller is a standalone background task, never chained.** Run
  `aimail poll <seat>` as its own call with `run_in_background=true` and
  nothing else in the command — no `&`, no `;`, no piping into `tail`. Chaining
  it after another command (`ack ... && poll ... &`) orphans it: the harness
  loses track of the process and it becomes unreachable.
- **A poller EXIT is a mail delivery, not a failure.** When it exits, the mail
  body printed once, into the task's own output file. Read that file — do not
  re-derive the message from a one-line summary on a later poll.
- **Ack after reading, never before, and never while a task is still in
  flight.** `ack --all` archives everything currently delivered-but-unacked,
  including a message you have not actually read yet if you call it blind.
  Bulk-acking mid-task is exactly how a stop signal gets archived unread.
- **Re-arm before stopping, every time**, in that order: finish the current
  mail cycle, `ack`, then `poll` again — not the reverse. A poller down between
  turns means the seat is unreachable until the next check.
- **Never disarm a poller as a throttle.** `aimail budget park` sets a flag
  every armed poller sleeps on and self-wakes from at the block roll. A
  disarmed poller also costs nothing but never wakes on its own — only a human
  restart brings it back. "Throttle" means park, never disarm.
- **A broadcast (`--to` more than once) refuses second-person pronouns** ("you",
  "your") because they have no unambiguous referent to more than one reader.
  Rewrite in the third person, send individually, or pass
  `--broadcast-second-person-ok` only when quoting someone else's words whose
  referent is genuinely unambiguous (e.g. relaying a direct quote).
- **Claim exclusive work with `gateclaim.sh` BEFORE starting**, not just before
  requesting a gate. This applies to any backlog/priority item more than one
  free seat might reach for, not only gates — mail-announced claiming has a
  race window shorter than mail's own latency and has caused real collisions.
  Key by the bare ticket ID when one exists (`t-437`, not `t437-xxyy-marks`) —
  gateclaim canonicalizes ticket-shaped keys itself, but a free-form key with
  no ticket number is only protected by containment, and free-form keys under
  8 characters aren't protected at all.
- **Always claim with `--desc "why this claim was taken"`** (e.g.
  `gateclaim.sh <key> <seat> --desc "verifying T-437 item 3"`), not a bare
  2-arg acquire. This is what makes `--list` a live "who's doing what" board
  for the whole fleet — the project owner, 2026-08-20, standing practice going forward,
  not opt-in. The description is "why," stable for the claim's whole
  lifetime — never "what step I'm on right now," which drifts and goes stale.
  Staleness is judged off the claim's own timestamp, same as always; the
  description doesn't need (and doesn't get) a separate expiry.
- **`AIMAIL_ACK_TTL`-aware `--all` requires a matching, recent `deliver`** —
  add `--force` only when acking something outside that window (e.g. recovering
  after a stall), and only after actually reading it first.
- **`ack --all` also requires `--sha <prefix>[,<prefix>...]`** (AR-28,
  2026-09-03) naming an 8+ hex-char prefix of every target's own
  `body-sha256` header, one prefix per message being archived — get them from
  the poll/deliver output you just read, not invented. This exists because the
  TTL/receipt check above only proves a delivery just happened, not that
  anything was read — a `poll` → `ack --all` chain run as a fixed idiom
  satisfies it every time with zero actual reading, which is exactly what kept
  happening fleet-wide. `--force` bypasses this too, same as it bypasses the
  receipt check — a deliberate, nameable unread sweep, never the default.
- **A cap percentage on `budget status` is not a decision point for you, in
  either direction.** Real incident, 2026-09-03: assistant read weekly at
  85%/95% as "close to the reset" and told the whole fleet to wind down for
  the night to "conserve" the remainder — backwards, since weekly usage does
  not bank across the reset; idling before it just wastes the headroom
  instead of spending it, and nothing about a session cap approaching means
  spend faster either. The cap number IS the safety margin, chosen
  deliberately — seeing usage approach it authorizes nothing on its own. The
  only thing licensed to change fleet behavior off these numbers is the
  automated park/ramp machinery itself, which fires exactly at/over cap. If a
  percentage makes you want to change pace, don't — `budget status` now
  prints this same rule inline for exactly this reason.

**Crossing warnings (T-917 item 3).** `aimail budget warnings [--dry-run]` prints, per account, the block / weekly / Fable-model gauges against the 50 and 80 levels (`AIMAIL_WARN_LEVELS`) plus a PROJECTED line when the current burn reaches the block cap before the block resets. `budget autopilot` runs it once per tick; each (account, gauge, level, window) mails the supervisor and the human seat ONCE, with the placement report in the body. Markers live under `state/warnings/`.

**The balancer acts (T-917 item 4).** With `AIMAIL_BALANCE_ACT=1`, each autopilot tick may ANNOUNCE one move (an account at/over `AIMAIL_BALANCE_ACT_LEVEL`, default 80, or over its fair share; the candidate is an idle non-pinned seat whose placement target passes `placement_check_move`) and, on the first tick after `AIMAIL_BALANCE_ACT_DELAY_MIN` (default 10), EXECUTES it through the resume-by-default `seat migrate` if the seat is still idle and placement still agrees. `aimail budget act` shows the pending intent; `aimail budget act cancel --why "<reason>"` stops it. A pinned seat is never a candidate; a mid-turn seat defers the move; every step is in `state/balance/acts.log`.

## Reviewing and approving branches (`aimail review`)

**Use it for every review of a branch headed for a pull request, by every seat.** It replaces "GREEN" in a
mail: the approval is a recorded state for one exact commit, and `status` always answers for the branch's
current tip. Which repos it covers, where the records live and which checker runs come from `etc/aimail.conf`
(`AIMAIL_REVIEW_REPOS`, `AIMAIL_REVIEW_PATH_/RECORDS_/CHECK_/BASE_<repo>`); the requirements file the checker
enforces is named by that repo's checker, so read it from the configured path, not from memory.

The sequence, in this order:
1. `aimail review start <repo> <branch> --by <seat> [--base <ref>] [--author <seat>]...` opens the record for the
   branch's current commit and prefills reviewer, authors and the test-file list. It refuses a seat that wrote
   any commit in `base..sha` (git author names, `Seat:` trailers, and every `--author`). Seats that commit under
   a shared git name cannot be seen from git: pass `--author` for them. `--by` must be the seat the session is
   registered to (`stop_guard.sh register <seat>`); `approve` and `reject` refuse an unregistered session.
2. Fill the record: one section per requirement, each answer naming evidence (file, function, plan id, crop or
   command). "Looks fine" fails.
3. `aimail review check <sha>` runs the checker and prints pass/fail per requirement.
4. `aimail review approve <sha> --by <seat>` only after a passing check on the unchanged record, by the
   record's reviewer. Or `aimail review reject <sha> --by <seat> --reason "..."`.
5. `aimail review status <repo> <branch>` (exit 0 only when `approved`; `stale` means a newer commit exists) and
   `aimail review list` for the open reviews with their age.

The requirement categories, one line each: **A** design and architecture (right place, design stated, no
workarounds); **B** root cause for a fix (named and shown, removed not patched, related cases checked);
**C** behavior and billing (changes listed, bill changes measured on real plans, one subject per PR);
**D** tests (product behavior, fail when broken, fast, every test file read and given a verdict);
**E** description and paperwork (matches the code, no fleet jargon, ticket drafted); **F** process (the
reviewer did not write the code, exact commit).

Two things ask the same question ("is this exact sha approved?") and neither reads any text:
- `aimail review handoff <repo> <branch>` is the only way to give the owner a push. It refuses unless the
  branch's current sha is approved; on success it prints the push command and the PR description path from the
  record and logs the handoff.
- `hooks/review_prepush_guard.sh` is the last resort at push; `PR_READY_OVERRIDE="<reason>"` gets past it and
  is logged. The seat that owns the hook installs it; a reviewer never does.

## Starting (or resuming) a session — do these in order

Every fresh session on a seat — first boot, resuming after a stop, or picking
up after an account switch — starts with this sequence, before any real work:

0. **Run `aimail session [seat]` FIRST, before anything below.** This is the
   single command that checks everything steps 1-5 check by hand — budget
   mode, role-handover freshness, poller state, `stop_guard.sh` registration,
   AND any project-local Stop-hook fork's SEPARATE registration (step 5) —
   and prints the exact fix command for anything wrong, inline, rather than
   requiring you to know which of five places to look.
   ⛔ **WHY THIS COMMAND EXISTS AT ALL (2026-09-03, live incident)**: an
   architect session ran across a full block-boundary stall, ended its turn
   dozens of times over many hours, and a project's `poller_guard.sh` Stop
   hook fired on every single one — and returned `allow-unregistered` every
   single time, because step 4 (`stop_guard.sh register`) had been done but
   step 5 (that PROJECT's OWN, separate `poller_guard.sh register`) never
   was. Nothing about the running session looked wrong from the inside:
   `aimail fleet` read whatever the poller process table said (fine, most of
   the time), `aimail whoami` found the `stop_guard.sh` mapping and reported
   healthy, and a hook that fires-and-silently-allows is indistinguishable
   from a hook that fires-and-genuinely-approves, unless you go read ITS OWN
   log for the decision string. `aimail session` exists so nobody has to
   remember to go read that log by hand, or even remember that a second,
   separate registration exists at all.
   ⚠ It is a REPORT, not an action — it registers and arms nothing itself
   (matching `resume`'s own philosophy: tell the caller the next command,
   never silently take it for them, because auto-registering to a GUESSED
   seat is worse than asking). Run the fix commands it prints, then run it
   again — do not assume one fix cleared every problem it found.
   ⚠ It also does not replace steps 1-5 below as KNOWLEDGE — read them once,
   so a fix command's own output makes sense rather than being cargo-culted.

1. **Check the budget alarm and mode, don't assume it's right.**
   `aimail budget status` — read the cap %, whether the last reading is fresh
   or stale, and whether the fleet is currently parked. Also explicitly check
   `aimail budget account` for which day/night mode is active: **an incident
   on 2026-08-24 had the fleet stuck in night mode (80% cap) during the day
   because nobody re-checked the mode after a switch — usage read 86%, over
   the 80% cap, and the alarm should have read as fine at a 90% day cap.**
   Don't infer the mode from the cap number alone; call `aimail budget day`
   explicitly if it's daytime and the account was just switched. If the
   last reading is stale (a callout or probe from a dead time block), get a
   fresh one (`budget probe`, or `budget callout <pct>` after reading
   `/usage` yourself) before trusting any go/no-go decision built on it.
2. **Read your own role handover before doing anything else.**
   `aimail role show <seat>`. This is what survives an account switch — your
   own conversational context does not. If it looks stale (check its own
   timestamp; `aimail role stale` flags this), say so rather than silently
   proceeding as if it's current.
3. **Arm your poller**, its own call, `run_in_background=true`, nothing else
   chained onto it (see Critical rules). Verify with `aimail fleet <seat>` —
   it must read ARMED, not just "no error returned." A relative path breaks
   on cwd drift; use the absolute path to the aimail repo.
3b. **Confirm the account and model this session is CERTAIN of:**
   `aimail seat confirm <seat> --model <the model id quoted from this session's
   own system prompt>`. It writes the persisted seat record (account, session id,
   model, time) that `aimail seat migrate` and a supervisor relaunching a fully
   dead seat rely on; `aimail session` flags a missing or mismatched record. A
   record whose session id is not this one means a stale boot or a TWIN —
   `aimail seat locate <seat>` shows every account the session is live on.
   Never `kill` the other one; `claude stop <short-id>` from its own account
   dir (see the Critical rule above and `docs/cli_account_migration.md`).
4. **Register this session with `stop_guard.sh`, if the project wires it.**
   `bash $AIMAIL_HOME/hooks/stop_guard.sh register <seat>` — this is what
   `aimail fleet`'s LAST-STOP column actually reads (`lib/fleet.sh::last_stop()`
   has no fallback path; it hardcodes `stop_guard.sh`'s own event log). A
   project-local fork of the stop-guard concept (e.g. a `poller_guard.sh`
   installed under that project's own `.claude/hooks/`, per step 5 below) does
   **not** feed this column — confirmed 2026-08-24 on a project where only the
   local fork was wired, and LAST-STOP read "never" for every seat until
   `stop_guard.sh`'s own hook was additively wired into that project's
   `settings.json` alongside it. Registration is per
   `CLAUDE_CODE_SESSION_ID` — it does **not** survive a session or account
   switch, so this step repeats every time step 1-3 do, not just once per
   project.
5. **Register with the PROJECT-LOCAL `poller_guard.sh` too — a SEPARATE
   registration from step 4, not satisfied by it.** Check
   `.claude/settings.json` for a `Stop` hook wired to a project path (e.g.
   `.claude/hooks/poller_guard.sh hook`). If one is wired, it keeps its OWN
   state directory (`<project>/zignore/mailbox/_stophook/`, or wherever that
   fork's `STATE` points), completely separate from `stop_guard.sh`'s. An
   unregistered session is a KNOWN, silent, by-design pass-through for this
   hook — "unmapped session -> allow" exists so a stray human/subagent
   session is never trapped — which means an unregistered SEAT session gets
   the exact same free pass, indistinguishable from one that's genuinely
   exempt. Nothing warns you this happened; every hook firing looks
   identical to a healthy one until you read its own log.
   ⛔ **CONFIRMED LIVE 2026-09-03**: an architect session ran for hours
   across a full block-boundary stall, ended its turn dozens of times, and
   the hook fired every single time and returned `allow-unregistered` every
   single time — because step 4's `stop_guard.sh register` was done, but the
   project's own `poller_guard.sh register <seat>` (a different script,
   different state, same session id) never was. The seat believed it was
   protected because *a* hook was firing; it never checked *which* decision
   that hook was making.
   Run it explicitly, every session, right after step 4:
   `bash <project>/.claude/hooks/poller_guard.sh register <seat>`
   (it reads `CLAUDE_CODE_SESSION_ID` on its own; no need to pass it).
   Then verify the registration actually took and check for a firing history
   red flag, before trusting the hook to have your back:
   `bash <project>/.claude/hooks/poller_guard.sh status` — the seat should
   appear under "registered", and if it shows `⚠ MULTIPLE SESSIONS
   REGISTERED`, that is real signal (a stale entry can mask this exact gap)
   even though it does not by itself block anything.
   `grep "$CLAUDE_CODE_SESSION_ID" <project>/zignore/mailbox/_stophook/fired.log`
   — if every line reads `allow-unregistered`, the hook has never once
   actually evaluated this session's poller state, no matter how many times
   it fired.
6. **Know what the (now-registered) stop hook actually enforces, every
   turn.** `poller_guard.sh` blocks a seat from ending its turn with no live
   poller and no explicit "done" marker — it will re-print the re-arm
   instructions and refuse to let the turn end otherwise. This is not
   optional housekeeping to skip when busy; treat a stop-hook block exactly
   like a compile error. The one sanctioned exception is a genuine budget
   throttle: the hook recognizes `_budget_throttled` and will not force a
   re-arm while the fleet is correctly parked — but it does **not**
   proactively tell you to write your role handover first. That
   step-2-in-reverse (record state, THEN let the park stand) is manual,
   always — see the incident note in step 1's context: four of eight seats
   were parked today with zero same-day update to their own role file,
   because nothing automatic prompted it.

Steps 1 and 2 are cheap and easy to skip when eager to get to real work —
they're listed first because skipping them is exactly what caused a real
incident, not as bureaucracy for its own sake.

## Seats — the address space

```
aimail seat list                          every registered seat
aimail seat add <name> [desc] [aliases]   register one
aimail seat retire <name> [successor]     stop accepting mail, say what to use
aimail seat unretire <name> [desc]        reverse a mistaken/stale retirement
aimail seat resolve <name>                what would this name deliver to?
```
A name is only a valid address if registered — `seat resolve` checks that
before you send to it.

## Mail

```
aimail send --to <seat> [--to <seat>…] --from <seat> --subject <s> --body-file <p>
aimail send … < body.md                   body may also arrive on stdin
aimail ack <seat> --all | <id>…           acted on it → archive it
aimail where <seat> <pattern>             which STATE is a message in?
aimail show <seat> <id>                   re-print ONE message's full body,
                                           unconditionally — use this to recover
                                           a body shown only in a poll's own
                                           background task-output file
```
`--body-file` must point at a real file on disk — `/dev/stdin` does not work as
a path here; write the body to a scratch file first if composing it inline.

## Polling

```
aimail poll-persistent <seat>   arm the wake loop — run it as a Monitor task (30-min cap; re-arm at each expiry)
aimail poll <seat>       DEPRECATED (2026-09-21): the classic exit-on-delivery mode; still works, prints a warning
aimail deliver <seat>    deliver once, no loop (for testing)
```
A message's full body prints exactly once, ever. Still un-acked later, it
becomes a one-line summary on every subsequent poll — visible, but not
re-spent in full (use `aimail show` to recover it in full).

## Fleet status

```
aimail fleet [seat…]     the dashboard, with a VERDICT per seat
aimail who               alias for fleet
aimail fleet sweep       ACTIVE check: mails a supervisor about any CRASHED/WEDGED
                          seat, or one STALLED past AIMAIL_STALL_ALERT (default
                          1200s), unprompted. Runs from cron.
aimail whoami            fresh session, no seat name yet? Looks up this session's
                          registered seat and resumes it.
```
Read the verdict carefully: **RE-ARMING is not down** — the poller fired and
the seat is reading its mail, and will re-arm on its own within the grace
window (`AIMAIL_REARM_GRACE`, default 180s). **STALLED** past the alert
threshold usually means genuinely behind, not necessarily stuck — ping before
escalating. **CRASHED** — no live process and no exit record — is the only
state that needs a human, since it means the seat did not stop on purpose.

## Budget — usage tracking and throttling

```
aimail budget status          block, last reading (with its age and TYPE), the schedule
aimail budget callout <pct>   record a /usage reading — a HUMAN's word, authoritative
aimail budget probe           hit the live usage endpoint and record it automatically
aimail budget block           just the block boundary, one line
aimail budget checkpoint [--now]   ask every seat to write its ROLE.md handover
aimail budget park [reason] | ramp   set/clear the throttle flag
aimail budget autopilot       the cron entry point (checkpoint → park → ramp)
aimail budget watch [interval=30]   LOOP, not cron — probe + seat-check every
                                     seat each interval, mail the supervisor once
                                     per OK→HALT crossing. Dies with whatever
                                     started it; supervise it, don't cron it.
aimail budget night | day     toggle the day/night cap mode (per-seat overrides,
                               e.g. assistant's 95%, are unaffected either way)
aimail budget account         which account is active, and its cap
aimail budget seats           per-seat weighted token cost per account (from ccusage session,
                               reconciled against the account block: MEASURED / UNMEASURED)
aimail budget balance         account pressure (burn ÷ sustainable), the arming streak, and what
                               the balancer WOULD recommend — READ-ONLY (design §5: one weekly
                               cycle of readings before any recommendation is emitted)
```

**Any seat can check usage at any time** with `aimail budget probe` — it hits
the same (unofficial, undocumented, but confirmed live and working) endpoint
Claude Code's own `/status` command calls internally, using the OAuth token
already stored in the active account's config directory. No human needs to
read `/usage` aloud for this reading specifically — `budget probe` and
`budget callout` both feed the same schedule, but are tagged differently in
the ledger (`probe` vs `callout`) and `budget status` labels them accordingly,
because a probe is not the same kind of claim as a human's word: it depends on
an endpoint that is not published and could change shape or vanish with zero
notice. If `budget probe` ever starts failing (missing token, network error,
unexpected response shape), it reports `UNMEASURABLE` rather than guessing —
fall back to `budget callout <pct>` after reading `/usage` yourself.

**The one idea the budget system is built around: the 5-hour block BOUNDARY is
measurable (from local transcripts via `ccusage`), the PERCENTAGE is not —
through anything official.** Everything that must run unattended (checkpoint,
park, ramp) is keyed on the boundary; the percentage is advisory. `budget park`
is not disarm — see Critical rules above.

## gateclaim.sh — the atomic exclusive-work lock

```
gateclaim.sh <key> <seat>              acquire — exit 0 = you own it, 1 = you do not
gateclaim.sh --release <key> <seat>    release after the verdict ships
gateclaim.sh --list                    show live claims (canonical key + as-typed)
gateclaim.sh --canon <key>             print the canonical form and exit (dry run)
```
`<key>` is either a gate SHA or a work-item ref; both are canonicalized before
the lock is taken, so two spellings of the same ticket or the same short-vs-long
SHA collide into one lock rather than both silently succeeding. Use this for
ANY exclusive claim, not only gates — see Critical rules above. Acquire it
BEFORE any worktree setup or any other work, and announce the claim after
acquiring (not instead of acquiring — the lock is the actual arbiter; the
announcement is only so other seats don't have to discover the collision
themselves).

`--role <role>` splits a ticket-shaped key into a separate door per role
(`t200:impl` and `t200:gate` never collide) — pass it on BOTH acquire and
release for the same door, since it changes the canonical key. Only affects
ticket-shaped keys; a free-form or SHA key ignores it.

⚠ **A claim is a WORK-ITEM lock, not a FILE lock.** Editing a shared file
(TODO.md, a shared checkout's own tracked files) needs its own `todoedit`
claim — a `t602:impl` work claim does not also protect a write to TODO.md;
they are two different doors, even on the same ticket. A seat that believes
its work claim covers a file edit has caused real, uncommitted-work-lost
incidents (2026-08-31). **Hold `todoedit` for the WHOLE edit-through-commit
cycle**, not just around the commit moment — release it only once the edit
is actually committed (or hand off explicitly, naming who commits, in mail).
A release with the edit still sitting uncommitted is the exposure window
that caused the incident.

## safe_sync.sh — syncing a shared checkout's working tree without destroying an uncommitted edit

```
safe_sync.sh <old-ref> <new-ref> <path> [<path> ...]
```
The standing land procedure commits in a fresh DETACHED worktree, then
fast-forwards the target branch with `git update-ref`, then has to catch the
SHARED checkout's own working tree up for whatever files changed. Do that
sync with `safe_sync.sh`, never a bare `git checkout <ref> -- <path>` — the
bare form gives zero protection for a single-path checkout (unlike a branch
switch, it silently overwrites uncommitted changes to that path with no
warning). Two real seat-authored uncommitted edits were destroyed this way
in one night before this tool existed.

`safe_sync.sh` refuses loudly (never auto-stashes — a stash nobody knows to
pop is the same silent loss one level down) when a path's on-disk bytes
differ from its content at `<old-ref>` — i.e. something touched it since the
last known-safe point, whether staged or not. `<old-ref>` is the same value
the land procedure already captures right before its own `update-ref` call
(compare against `<old-ref>`, not `HEAD` — `update-ref` moves HEAD before the
working tree catches up, and that ordinary lag would otherwise read as a
false positive). If it refuses, that is real uncommitted work: read the
printed diff and decide explicitly — commit it, mail it to its author, or
fold it into your own commit — before re-running, never force past a
refusal.

## Never chain a destructive worktree op with its own replacement — WIP-commit first

**Standing rule (3 real incidents, 2026-08-31/09-01, three different mechanisms — foundation's
TODO sync-clobber, audit's `T-602 worktree remove --force`, audit's `W2/O3` worktree move):
WIP-commit before any `git worktree remove`/move/prune touching content that might not be
committed.** `git add -A && git commit -m WIP` costs nothing, survives any subsequent
`--force`, and makes the loss class structurally impossible — there's nothing left to lose once
it's committed, even to a throwaway commit.

`git worktree remove` already refuses on a dirty tree by default — **`--force` is what bypasses
that built-in guard, and `--force` is never the first resort.** Preservation (a WIP commit, or
an explicitly-named copy) comes before force, not instead of it. A `--force` that follows a real
preservation step is routine; a `--force` that substitutes for one is the incident.

**Never chain a destructive op directly into the command meant to replace what it destroyed**
(e.g. `git worktree remove --force <old> && git worktree add --detach <new> <sha>` in one
call) — same law as never chaining `ack`+`poll` in one aimail call, same reason: a timeout or
failure mid-chain executes the destructive half and abandons the recovery half, with nothing to
show it happened until someone goes looking for the thing that's now gone. Run the destructive
step, verify its result, then run the replacement as its own separate, verified call.

**Design-proposal documents under `docs/` are committed at write time — never left
untracked.** Real incident, 2026-09-01: a T-602 §3c redesign proposal, written to `docs/` and
cited repeatedly in TODO.md, was confirmed gone from disk with zero git history anywhere (no
commit, no stash, no worktree, no session scratchpad had it) by the time anyone went looking —
the fourth destroyed-uncommitted-work instance in two days, and the first to take a design
record rather than working code. `docs/` is a tracked path; an untracked file there is exactly
the fragile state this whole family of rules exists to close. If the proposal's content is
still moving, WIP-commit it as it's written rather than leaving it untracked between edits —
the standing gate (investigate → root-cause → proposal → review → implement) makes the
proposal doc a load-bearing artifact, and it needs the durability of one from the moment it
exists.

**A documented norm is not enforcement — the lock-through-commit rule above is now a
MECHANISM, not just words.** Fable, 2026-09-01/02: the lock-through-commit norm (hold a
shared-file claim, e.g. `todoedit`, until the edit actually commits, not until the raw write
succeeds) was written into SKILL.md at 11:13 and violated at 19:46 by a seat that helped write
it — the 5th destroyed-uncommitted-work loss in two days. `gateclaim.sh --release` now REFUSES
when `AIMAIL_GUARDED_RELEASE_<CANONICAL_KEY>` (set in `etc/aimail.conf`, e.g.
`AIMAIL_GUARDED_RELEASE_TODOEDIT=/path/to/TODO.md`) names a path that is dirty in the live
checkout — `--handoff <seat>` bypasses it explicitly rather than silently. `todoedit` is
guarded this way today; see gateclaim.sh's own SEVENTH FAILURE comment and `tests/
gateclaim_keys.sh`'s ARM 20 for the mechanics. Separately: `safe_sync.sh`'s new-file bypass (no
baseline blob exists, so a verified manual diff is the only option) stays legitimate; an
EXISTING path is different in kind and has no manual-bypass case — it always goes through
safe_sync.sh, never a bare `git checkout <ref> -- <path>` by hand, exactly the behavior that
tool exists to replace (see its own header for the distinction spelled out).

## Read a ticket's own LATEST ruling before acting on a relayed clearance

**Real incident, 2026-09-01: T-602 landed on `main` against a standing NOT-LICENSED ruling
that was already recorded in the same TODO.md entry, ~90 lines below the "clear to land" line
that got cited.** A ticket entry accumulates rulings over its life; a later one can supersede
or outright refute an earlier one written in the same entry. Reading only as far as the first
clearance-shaped sentence and stopping there — even when it's attributed to a named ruling,
even when it comes with real corroborating detail (a census, a test count) — is reading a
stale summary, not the ticket's current state. **Before citing a ticket's own ruling as
license to act (land, revert, retune, ship), read to the end of that entry for a later
dated ruling on the same question, not just the first one that answers it.** A dated ruling
beats an earlier one on the same ticket the same way a fresh probe beats a stale one on
budget, or `HEAD` beats a cached ref — recency inside the SAME document is not optional to
check just because the document already looks authoritative.

**Two mechanics that make this cheap (fable, 2026-09-01):**
1. **Grep the entry for every dated `RULED`/`SEALED`/`HOLD` line and sort by TIMESTAMP, not
   file position.** A ticket's blocks get appended in more than one place as work continues
   across sessions/days — the physically-last block in the file is not guaranteed to be the
   most recently dated one.
2. **A landing note must cite the specific ruling id/timestamp it relies on** ("clears per
   fable's 03:18 ruling"), never a bare, undated appeal ("fable's disposition", "assistant's
   relay"). A dated citation makes a stale one visible to a gate reviewer immediately; an
   undated one hides exactly the gap that caused this incident until someone goes looking.

This is distinct from the destructive-op rule above: that one is about the MECHANICS of a
git operation; this one is about whether the record you're reading has already moved past the
sentence you're citing.

## A claimed write carries a checkable pointer — verify against the artifact, never the mail

**Real pattern, 2026-09-01: the shared checkout's real state diverged from seats' beliefs
about it at least eight times in two days** (five uncommitted-work losses, plus three separate
instances the same night of "I wrote X" not matching reality — twice a reader checked the
wrong location in a shared file, once a claimed TODO.md edit never actually reached a commit).
Not a coincidence — a mechanism, and the same cheap defense already used for rulings and
landings generalizes to any artifact claim.

**Any claim that a file, doc, or record was written carries a CHECKABLE POINTER** — a commit
sha for a landed change, a line number or grep-able anchor for an in-place edit — **and anyone
relying on that claim verifies it against the artifact before building on it, never against the
mail.** This covers both failure directions at once: a reader who checks the wrong spot in a
shared document (a pointer would have shown them exactly where to look), and a writer whose
edit never actually landed (a pointer that can't be supplied surfaces the gap immediately,
instead of hours later when someone else goes looking and finds nothing). A bare "updated the
doc" or "wrote the record" is not a delivery — a sha or line anchor is.

## Role handover — the one thing that crosses an account switch

```
aimail role show <seat>     print the current handover
aimail role write <seat> [file]   write it (or pipe the content on stdin)
aimail role stale [seat]    flag handovers that are old
aimail role path <seat>     print where it lives on disk
```
The handover does **not** live in the seat's inbox — it lives outside it,
specifically so it can never be delivered as mail. When an account is
switched, every session's context switches with it; the handover is the only
thing that survives. Write it with concrete state: what's DONE (with a sha,
path, or command output as evidence), what's IN FLIGHT (with the exact next
step), what it's BLOCKED on (and who owes the answer). Keep it current state,
not an append-only log — a handover large enough to consume a fresh session's
context defeats its own purpose.

## Status and diagnostics

```
aimail status [seat]    queues, un-acked counts, registry health
aimail doctor           check this installation for structural problems
aimail version          the running instrument's identity and AIMAIL_ROOT
```

## Full design rationale

For the "why" behind any of the above — the specific incidents that shaped
each rule, the block-boundary-vs-percentage design, the gateclaim canonicalization
algorithm and its stated limits — read `/mnt/workdrive/AI/AIMail/README.md` and
the `lib/*.sh` source directly. Those files, not this summary, are the
source of truth if the two ever disagree; update this file when they do.
