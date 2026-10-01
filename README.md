# aimail

File-based mail, work claims and budget control for a fleet of AI coding
sessions that cannot see each other's context.

A fleet of sessions shares nothing but the disk. `aimail` gives each session an
address (a *seat*), a way to be woken when mail arrives, and a set of mechanical
guards so that a request, a claim or a stop notice cannot quietly fall on the
floor. Everything is plain files and bash; there is no server.

Contents: [Install](#install) · [Quick start](#quick-start) ·
[Seats and mail](#seats-and-mail) · [Output states](#the-four-output-states) ·
[Fleet dashboard](#the-fleet-dashboard) · [Asks and prompts](#asks-prompts-and-the-drop-prevention-guards) ·
[Claims](#claims) · [Landing and git guards](#landing-and-git-guards) ·
[Review](#review-an-approval-is-a-recorded-fact-about-one-commit) ·
[Budget](#budget-checkpoints-and-unattended-running) · [Hooks](#hooks-and-kill-switches) ·
[Configuration](#configuration) · [Tests](#tests) · [Known limits](#known-limits)

---

## Install

Requirements: `bash`, `git`, `python3`, `jq`, `flock`, `sha256sum`, `curl`.
The budget commands also use `ccusage` (and `node`), and the session commands
(`seat locate`, `seat migrate`, `sessions`) expect the `claude` CLI.

```bash
git clone <this repo> && cd aimail
cp etc/aimail.conf.example etc/aimail.conf     # gitignored; set AIMAIL_ROOT at least
export PATH="$PWD/bin:$PATH"
aimail doctor                                   # checks this installation
```

`etc/aimail.conf` is the only deployment-specific file. Mail and state live
under `AIMAIL_ROOT` (default `~/.aimail`), which must be outside the repo: mail
is machine-local coordination, not source.

## Quick start

```bash
aimail seat add main "General work"
aimail seat add backend "Backend work" "be"      # a name, a description, aliases

aimail send --to backend --from main --subject "gate is free" --body-file ./msg.md
aimail poll-persistent backend    # run as a Monitor/background task; see "Polling"
aimail unread backend             # what is waiting, by id
aimail ack backend <id>           # after acting on it
```

Start every new session with `aimail session [seat]`. It checks, read-only, the
budget mode, the role handover, the poller, and each Stop-hook registration, and
prints the exact command that fixes anything wrong.

---

## Seats and mail

A **seat** is a registered name. A name that is not registered is not an
address: `aimail send` refuses it, and `aimail seat resolve <name>` says what a
name would deliver to. Seats can have aliases and can be retired
(`seat retire <name> [successor]`) or restored (`seat unretire`).

```
aimail send --to <seat> [--to <seat> ...] --from <seat> --subject <s> --body-file <path>
aimail send ... < body.md          # the body may also arrive on stdin
aimail unread <seat>               # un-acked mail: id, sender, subject, size
aimail show <seat> <id>            # re-print one message in full
aimail recent <seat> [N]           # last N ids this seat has ever seen
aimail where <seat> <pattern>      # which state is a message in
aimail ack <seat> <id>...          # archive what has been acted on
```

### What `send` refuses, and why

Every refusal replaces an incident. The tool enforces these rather than
documenting them, because a rule in a document loses to recall at the moment of
use.

| Refusal | The failure behind it |
|---|---|
| Sending to an unregistered name | A directory existed beside the real seat's. No poller watched it, so mail there was never read and never bounced. |
| `--body "some string"` | A body composed with an unquoted heredoc had its fenced code blocks eaten by shell expansion. The headings survived, so it read as asserted-without-evidence rather than as damaged. |
| An unbalanced code fence | The detection signature of the above, caught before delivery. |
| `--date` or any caller-supplied timestamp | One seat's clock ran fast, and another seat advanced its own clock from those headers, so the drift grew. |
| Second-person pronouns in a broadcast | A correction addressed to "you" went to five seats and the wrong one answered it. Use the third person, send individually, or pass `--broadcast-second-person-ok` when quoting someone whose referent is unambiguous. |
| A missing `--from` | Mail without a sender cannot be traced: "what did this seat send?" returned nothing. |
| A sender that is not the calling session's registered seat | Mail must come from the seat's own session (`AIMAIL_SEND_IDENTITY_CHECK=0` disables it; a human's decision). |
| A work mail with no open ask | See [asks](#asks-prompts-and-the-drop-prevention-guards). |
| A GREEN verdict missing its evidence lines | A subject containing an uppercase `GREEN` is a licence to land, so the body must carry `Producer: <file:line>`, `Consumer: <file:line>` (or `Docs-only: <reason>`) and a `Fleet tests:` line, each starting its own line, and must not use the bare word "hold". `AIMAIL_SEND_GREEN_GUARD=0` disables it. |
| Unknown verbs and flags | A status-looking word once created a lock holder with that name and started a full test run. |

### Delivery

```
  send              poll                   ack
────────>  inbox  ───────>  unacked/  ───────>  archive/YYYY-MM/
             ▲                  │
             └──────────────────┘
              re-printed every poll until acked
```

`archive/` is not reachable by delivery. Delivery moves mail to `unacked/`; only
`aimail ack` archives it. Un-acked mail is shown as a one-line summary on every
later poll (`aimail show` re-prints it in full), so a delivery nobody read is
visible rather than silently lost. A message body is printed in full exactly once.

- `aimail ack <seat> --all` also needs a matching, recent `deliver`
  (`AIMAIL_ACK_TTL`, default 600 s) **and** `--sha <prefix>[,<prefix>...]`, an
  8+ hex-character prefix of each target's `body-sha256` header, taken from the
  delivery you just read. `--force` skips both and is for a deliberate unread
  sweep only.
- Delivery is size-capped (`POLLER_DRAIN_MAXB`). The remainder stays queued; it
  is never consumed.

### Polling

```
aimail poll-persistent <seat>    # the normal reader: stays armed, prints each delivery
aimail poll <seat>               # deprecated one-shot: exits on the first delivery
aimail deliver <seat>            # deliver once, no loop (for tests)
```

Run a poller as its own standalone background task (for example a Claude Code
Monitor) with nothing chained to it: no `&`, no `;`, no pipe into `tail`. A
chained poller is orphaned and the harness loses track of it. A persistent
poller is capped at 30 minutes; re-arm it when it ends, and run only one at a
time per seat. A poller's exit is itself a delivery: read its output before
doing anything else.

---

## The four output states

Every instrument reports exactly one state, with a distinct exit code.

| State | Exit | Meaning |
|---|---|---|
| measured | 0 | a real reading |
| refused | 3 | the request is something the tool will not do |
| unmeasurable | 4 | it could not measure; this is **not** zero and **not** clean |
| error | 1 | it broke |

`unmeasurable` exists because the recurring failure was never a crash. It was a
plausible number: a 384% projection, a 0.00%/hour burn read as "fleet idle", a
census printing "0 of 0" as an all-clear. Zero reads as safe in whichever
direction is dangerous.

---

## The fleet dashboard

```
aimail fleet                  # one row and one verdict per seat
aimail sessions [--json]      # one row per session, each judged on its own evidence
aimail context [seat...]      # each live session's current context size
aimail whoami                 # a fresh session finds its own seat
```

```
SEAT      POLLER     LAST-STOP  QUEUED  UNACK  VERDICT
main      RE-ARMING  2m              0      1  WORKING: mid-turn, reading mail. Do not nudge
review    ARMED      14m             2      0  IDLE & REACHABLE: mail will wake it
backend   CRASHED    51m             0      3  UNREACHABLE: killed, not finished
```

A poller is down both when a seat is mid-turn reading its mail and when the
seat was killed. Those need opposite responses, and a process sample cannot tell
them apart. So the dashboard uses two event sources instead of `pgrep`:

- **The poller's heartbeat records why it stopped.** An exit that says
  `reason=mail` is a poller that did its job. An absent heartbeat with no exit
  record is a poller that was killed.
- **The stop hook logs the moment a session ends a turn**, which is what "idle"
  actually means.

Verdicts: `ARMED`, `RE-ARMING` (the poller fired and the seat is reading; it has
`AIMAIL_REARM_GRACE`, default 180 s, to re-arm), `STALLED` (past
`AIMAIL_STALL_ALERT`, default 1200 s), `WEDGED`, `CRASHED` (no process and no
exit record; the one state that needs a human) and `NEVER`.

`fleet` counts seats, not sessions: a seat with four concurrent sessions has one
heartbeat and one row. Use `aimail sessions` when the question is which session
is alive; `sessions --prune` removes only registrations proven to belong to
ended sessions.

Cron entries that keep the fleet honest:

```cron
*/5 * * * *  aimail fleet sweep    >> sweep.log 2>&1      # mails a supervisor about CRASHED/WEDGED/STALLED seats
*/5 * * * *  aimail fleet watchdog >> watchdog.log 2>&1   # supervisor liveness; wakes or escalates
* * * * *    aimail fleet pressure >> pressure.log 2>&1   # RAM/CPU/swap pressure; optional, per minute
```

Seat sessions can be located and moved between accounts with
`aimail seat locate|confirm|record|migrate|launch|sessions`
(see [docs/cli_account_migration.md](docs/cli_account_migration.md)). Migration
resumes the seat's own session by default; never `kill` a session by pid.

---

## Asks, prompts and the drop-prevention guards

Four mechanical guards keep something a person asked for from quietly falling
out of the fleet's attention. `tests/drop_guards.sh` exercises each one with a
refusal arm and an acceptance arm.

**The ask ledger.** An *ask* is a task someone requested that must not be
silently dropped.

```
aimail ask add --owner <seat> --quote "<their words>" --next "<step>" --check '<shell predicate>' [--prompt <p####>]
aimail ask touch <id> --by <seat> --state "<where it stands>" [--evidence <ref>] [--next "<step>"]
aimail ask list [--owner <seat>] [--stale] [--all]      aimail ask show <id>
aimail ask sweep                  # cron, every 10 minutes
aimail ask owner-digest [--owner <seat>]
aimail ask withdraw <id> --owner-approved "<quote>"
```

`--check` decides when the row closes on its own: `ask sweep` runs it and closes
the row on exit 0. A row untouched for `AIMAIL_ASK_STALE` seconds is stale, and
the sweep mails its seat and the supervisor once per stale episode; a `touch`
ends the episode. There is no `ask done`; the single manual close is `withdraw`
with a quoted approval.

1. **Prompt ledger and triage gate.** `hooks/prompt_guard.sh capture` (a
   UserPromptSubmit hook) records every human prompt as `untriaged` and tells
   the session the prompt id; machine text such as harness notifications and
   poller wakes is skipped (`AIMAIL_AUTOMATED_PROMPT_RE`). `hooks/prompt_guard.sh gate` (a
   Stop hook) refuses to end the turn while the session still has an untriaged
   prompt. Each ends in `aimail prompt triage <p####> --ask <k####>` (the ask
   must exist) or `--no-ask "<reason>"` (a real reason, 8+ characters);
   `ask add ... --prompt <p####>` adds the ask and triages in one step. Only a
   registered seat's session is captured or gated. The gate blocks at most once
   per stop attempt and fails open on error.
2. **A park needs an end.** `ask touch|park <id> ... --waiting-on <who>` is
   refused unless it carries `--until <date>` (`YYYY-MM-DD`,
   `'YYYY-MM-DD HH:MM'`, `+3d`, `+12h`; must be in the future) or
   `--trigger "<the named event that ends the park>"`. An expired `--until`
   un-parks the row: it reads STALE and the sweep mails it again. Clearing a park
   (`--waiting-on ''`) needs neither.
3. **A work mail cites an ask.** `aimail send` refuses a subject that announces
   work (`Task:`, `Assignment:`, `Assign:`, `Work request:`;
   `AIMAIL_WORK_SUBJECT_RE`) unless the subject or body cites a ledger id that
   exists and is still open.
4. **The open-asks digest.** `aimail ask owner-digest` prints every open ask with
   its seat, age, state, park date or trigger and next step, plus the number of
   prompts never triaged.

**A person-only row needs an end too.** `ask add --check false` (a row only a
person can close) is refused without `--until <date>` or `--trigger "<event>"`.
A row past its `--until` reads `OWNER-OVERDUE` in `ask list` and is mailed as
stale by the sweep; `ask touch <id> --until <date>` renews it. A trigger-only row
keeps waiting until it is closed or touched.

---

## Claims

```
gateclaim.sh <key> <seat> --desc "why this claim was taken"    # exit 0 = you own it
gateclaim.sh --release <key> <seat>
gateclaim.sh --list                                            # who is doing what
gateclaim.sh --canon <key>                                     # print the canonical key
aimail claims [seat...]            # is each holder still advancing its claim?
aimail claims block <key> <seat> <ref>      aimail claims unblock <key> <seat>
```

A claim is an atomic lock, taken before the work starts. It is the arbiter;
announcing a claim by mail is not, because a mail-announced claim has a race
window shorter than mail's own latency. Use it for any exclusive work item or
gate, keyed by the bare ticket id or the commit sha. Keys are canonicalised
(short and long forms of one sha, or two spellings of one ticket, collide into
one lock). Always pass `--desc`: it is the "why", stable for the claim's life,
and it makes `--list` a live board.

`aimail claims` judges the (seat, claim) pair: `DOWN` (the holder's process is
gone), `WORKING` (a live process in the claim's worktree, or a recent commit or
mail naming the key), `BLOCKED` (a typed referent such as `gate:`, `lock:`,
`seat:`, `human:` or `landing:` is checked live for dangling or cycles) or
`STUCK` (alive, held, not blocked, no evidence past `AIMAIL_CLAIM_STUCK_SECONDS`;
surfaced, never auto-released).

**The claim gate refuses a stale owner.** A new `gateclaim.sh` claim by a seat
that owns a stale open ask is refused and names the row, so a newer task cannot
displace an older one by default. `--preempt-ok "<quote>"` records the quote on
the row and proceeds. It never applies to `--release`, `--list` or `--canon`.

---

## Landing and git guards

```
aimail land <repo-path> <ref> <sha> --from <seat>
```

The one way to move a shared ref. It locks the (repo, ref), re-reads the live tip
inside the lock, refuses unless the move is a real fast-forward, moves the ref
with the three-argument `update-ref` (expected-old is the tip just read),
verifies, and prints the log and stat for the landing mail. It never
materialises a working tree. When a must-prove ref is configured, it also refuses
without a `--gate-summary` that `bin/check_battery_summary.sh` accepts for the
exact sha.

Installable git hooks, each verified by an `aimail` check command:

| Hook | Git hook type | What it does | Check |
|---|---|---|---|
| `hooks/main_only_landing_guard.sh` | `reference-transaction` | Refuses an update of a protected ref from any session not registered as the landing seat (plus the per-ref extras in `AIMAIL_LANDING_GUARD_ALLOW`), and any non-fast-forward or deletion (`AIMAIL_LANDING_GUARD_REQUIRE_FF`). | `aimail landing-guard` |
| `hooks/sterility_guard.sh` | `pre-commit` | Refuses a commit whose staged diff adds a term from `AIMAIL_STERILITY_TERMS`. | `aimail doctor` |
| `hooks/sterility_commit_msg_guard.sh` | `commit-msg` | The same, for the commit message. | `aimail commit-msg-guard` |
| `hooks/sterility_push_guard.sh` | `pre-push` | Refuses any push from a non-human seat, and any outgoing commit carrying a sterility term. | `aimail push-guard` |
| `hooks/review_prepush_guard.sh` | `pre-push` | Refuses a push of a branch that is not approved for its exact tip (see [Review](#review-an-approval-is-a-recorded-fact-about-one-commit)). | `aimail review status` |

Each check takes `--selftest`. A dangling symlink or a `core.hooksPath` into a
vanished directory makes git run no hooks, silently, which is why the checks
verify that a hook is installed **and resolvable**. `aimail session` and
`aimail doctor` run them for the repos in `AIMAIL_LANDING_GUARD_REPOS`.

Separately: `hooks/secret_read_guard.sh` (a PreToolUse hook) denies a command
that would print secret **values** from an env-style file, `/proc/<pid>/environ`
or a bare `env`/`printenv` dump into the transcript, while allowing names-only
reads and sourcing; `hooks/secret_scan.sh` is the daily scan for secret values
already sitting in plain text under given repo roots (prints counts and paths,
never values).

`bin/run_canonical_battery.sh` runs a downstream project's full test battery
from a clean checkout of an exact sha, one at a time, and
`bin/battery_queue.sh` queues them. `bin/check_battery_summary.sh` accepts a
battery summary only when its tree matches the sha being landed.

---

## Review: an approval is a recorded fact about one commit

A mail saying "reviewed, looks good" is text; nobody can ask it which commit it meant. `aimail review`
turns approval into a row that names the exact commit, the reviewer, the version of the checker and the
time. Asking for the status of a branch always answers for the branch's **current** tip, so a new commit
makes an older approval stale without anyone having to say so. Nothing here reads message text.

```
aimail review start <repo> <branch> --by <seat> [--base <ref>] [--author <seat>]...
aimail review check <sha>                       # runs the configured checker, prints pass or fail
aimail review approve <sha> --by <seat>
aimail review reject  <sha> --by <seat> --reason "..."
aimail review status <repo> <branch> | --sha <full-sha> [--quiet]   # approved | stale | in review | rejected | none
aimail review list                              # every open review with its age
aimail review handoff <repo> <branch>           # the only way to hand over a branch for pushing
```

- **`start`** opens a review of the branch's current commit and refuses a seat that wrote any of it. Authors
  are the commit authors between the base and the tip, any `--author` given here, and `Seat: <name>`
  trailers in the commit messages. It writes a record skeleton, from the checker, to the records folder.
- **`check`** runs the checker on the filled-in record and the diff. It stores the checker file's hash **at
  that moment**, so editing the checker later cannot change what an approval vouched for.
- **`approve`** needs a passing check on a record that has not changed since, and must come from the
  record's reviewer. **`reject`** records a reason.
- **`--by` is tied to the session.** `start` refuses a session registered to a different seat, and `approve`
  and `reject` also refuse a session that is not registered to any seat (`status` and `list` work anywhere).
  Without this tie an author could simply type someone else's name.
- **`handoff`** refuses unless the branch's current commit is approved (a stale or unreviewed branch both
  refuse, naming the status). On success it prints the push command and the path of the pull-request
  description named by the record's `pr-description:` line, and appends the commit, branch, reviewer, user
  and time to `state/review_handoffs.log`. A refused handoff logs nothing. Anyone giving a person a push
  command or calling a branch ready goes through this command, not through a mail.
- **The push gate.** `hooks/review_prepush_guard.sh` is a `pre-push` hook that asks the same question at
  push time. A push of a branch that is not approved for its exact tip is refused; branches matching the
  repo's exempt pattern (merge targets) are not asked about. `PR_READY_OVERRIDE="<reason>"` gets past it and
  is logged to `state/review_overrides.log`.

Repos are declared in `etc/aimail.conf`, so the library itself names no project. `AIMAIL_REVIEW_REPOS` lists
the repo names; for each name `<repo>` (hyphens become underscores in variable names) set:

| Variable | Meaning |
|---|---|
| `AIMAIL_REVIEW_PATH_<repo>` | where the repo is checked out |
| `AIMAIL_REVIEW_RECORDS_<repo>` | where the `<full-sha>.md` records live |
| `AIMAIL_REVIEW_CHECK_<repo>` | the checker command, called as `<cmd> <sha> --repo <path> --records <dir> --base <ref>`; it exits 0 when the record and diff pass. With `--template` instead of `--records` it prints a record skeleton |
| `AIMAIL_REVIEW_BASE_<repo>` | the default base (`--base` overrides) |
| `AIMAIL_REVIEW_CHECKER_FILE_<repo>` | the checker file to hash at check time (optional) |
| `AIMAIL_REVIEW_URL_<repo>` | a regex for the remote URLs the push gate applies to |
| `AIMAIL_REVIEW_PUSH_EXEMPT_<repo>` | a regex for branches the push gate does not ask about (optional) |
| `AIMAIL_REVIEW_REMOTE_<repo>` | the remote `handoff` prints in the push command (default `origin`) |

What it cannot know is who wrote a commit when seats commit under one shared git identity. That is why
`start --author` exists: the person who knows fills the gap, and the record's own `author:` line is a second
witness. `tests/review.sh` (part of `tests/run.sh`) exercises every refusal beside an acceptance arm.

---

## Budget, checkpoints and unattended running

```
aimail budget status          # block, last reading and its age, schedule, throttle
aimail budget callout <pct>   # record a /usage reading: a human's word, authoritative
aimail budget probe           # read usage from the live endpoint and record it
aimail budget autopilot       # cron: checkpoint, then park, then ramp
aimail budget checkpoint [--now]       aimail budget park [reason] | ramp
aimail budget unpark <seat>            aimail budget night | day
aimail budget account         # which account is active and its cap
```

The idea it is built around: the five-hour block **boundary** is measurable
(`ccusage` models it as an anchored block), but the **percentage** is not,
through anything official. Everything that must run unattended is keyed on the
boundary; only advisory output is keyed on the percentage. A *checkpoint* fires
on the clock, hours before the boundary: "write your role handover while there is
still budget to write it". When an account is switched every session's context
goes with it, so those handover files are the only continuity.

`budget callout` records a human's `/usage` reading and is the one claim nothing
else substitutes for. `budget probe` calls an unofficial, undocumented endpoint
using the token Claude Code already stores; it could change or disappear in any
release, so its rows are tagged `probe`, and when it fails it reports
unmeasurable rather than guessing.

A cap percentage is not a decision point for a seat. The cap is the safety
margin, chosen deliberately; seeing usage approach it authorises nothing in
either direction. Only the automated park and ramp machinery acts on it.

```cron
*/5 * * * * aimail budget autopilot >> autopilot.log 2>&1
```

`autopilot` ramps if the block rolled, checkpoints `AIMAIL_CHECKPOINT_MIN`
before the end, and parks at `AIMAIL_PARK_MIN`. It belongs in cron because a
background task is a child of the session and dies with it, which is the
scenario unattended running exists to survive.

**Park is not disarm.** Parking sets a flag; every poller sleeps on it and wakes
itself at the ramp, so a parked poller costs nothing and recovers on its own. A
disarmed poller also costs nothing and never wakes: only a human can restart it.
Never tell a seat to disarm. `budget unpark <seat>` exempts one seat from the
current park only and vouches for nothing about its usage.

Per-account caps:

```bash
AIMAIL_CAP_DEFAULT=90
AIMAIL_CAP_shared=80     # a shared account parks lower
```

The account is read from the `~/.claude` symlink target. Further budget commands:
`budget history`, `seats`, `warnings` (50/80 crossings, one mail per level and
window), `balance` and `act` (an announce-then-do balancer, off unless
`AIMAIL_BALANCE_ACT=1`) and `placement` (which accounts may host a seat).

---

## Hooks and kill switches

| Hook | Wired as | Purpose |
|---|---|---|
| `hooks/stop_guard.sh` | Stop | Will not let a session end its turn with no live poller; logs every turn end, which feeds the dashboard's LAST-STOP column. Register the session with `stop_guard.sh register <seat>`. |
| `hooks/prompt_guard.sh capture` / `gate` | UserPromptSubmit / Stop | The prompt ledger. |
| `hooks/supervisor_guard.sh` | Stop (supervisor seat only) | The supervisor cannot end a turn without having looked at the fleet and budget recently. |
| `hooks/secret_read_guard.sh` | PreToolUse (Bash) | See above. |

Registration is per `CLAUDE_CODE_SESSION_ID` and does not survive a session or
account switch. A project that forks the stop hook keeps a separate
registration; `aimail session` reports both, because an unregistered session is a
silent pass-through that looks identical to a healthy one.

Kill switches exist for a human to use, not for a seat to use around a refusal:

| Variable | Disables |
|---|---|
| `AIMAIL_PROMPT_CAPTURE=0` | recording prompts in the ledger |
| `AIMAIL_PROMPT_GATE=0` | the triage gate on Stop |
| `AIMAIL_WORK_MAIL_GUARD=0` | the work-mail-cites-an-ask check |
| `AIMAIL_SEND_GREEN_GUARD=0` | the GREEN evidence-line check |
| `AIMAIL_SEND_IDENTITY_CHECK=0` | the sender-is-the-calling-seat check |
| `AIMAIL_LANDING_GUARD_REQUIRE_FF=0` | the fast-forward-only rule in the landing hook |

---

## Configuration

`etc/aimail.conf.example` documents every setting; the common ones:

| Variable | Default | Meaning |
|---|---|---|
| `AIMAIL_ROOT` | `~/.aimail` | where mail and state live (outside the repo) |
| `AIMAIL_POLL_INTERVAL` | 5 | seconds between polls; an idle poll costs a `find` and a sleep |
| `POLLER_DRAIN_MAXB` | 60000 | delivery size cap in bytes |
| `AIMAIL_REARM_GRACE` | 180 | seconds a fired poller may take to re-arm |
| `AIMAIL_STALL_ALERT` | 1200 | seconds before a seat reads STALLED |
| `AIMAIL_ASK_STALE` | 1800 | seconds before an untouched ask row is stale |
| `AIMAIL_CAP_DEFAULT` | 90 | session cap percentage; `AIMAIL_CAP_<account>` overrides |
| `AIMAIL_ACCOUNT_POOL` | unset | the accounts the fleet manages, by name. Set it. |
| `AIMAIL_STERILITY_TERMS` | unset | `|`-separated terms that must not appear in tracked files; unset means the check is a no-op |
| `AIMAIL_LANDING_GUARD_REPOS` / `_ALLOW` | see example | repos the landing guard covers, and extra landers per ref |

`aimail migrate <old-mailbox> [--dry-run]` imports an existing mailbox. It copies,
never moves, is idempotent and resumable, and keeps the chronology.

---

## Tests

```bash
bash tests/run.sh                    # the whole suite; run it in the background, it is long
bash tests/drop_guards.sh            # one file
bash hooks/stop_guard.sh selftest    # also run by the suite
```

Every guard is exercised with an input that must trip it, paired with a positive
control on the nearest valid input so an always-refusing guard cannot hide. When
you check a guard by mutating it, assert that the patch actually applied before
drawing a conclusion: a decoy that cannot apply its patch proves nothing.

[docs/PORTING.md](docs/PORTING.md) maps known defects of the system this one
replaced to prevented, partial or not-yet-ported.

---

## Known limits

- **A clean exit can report `CRASHED`.** That verdict means "no exit record, a
  human must intervene", so a false positive pages someone for nothing. The cause
  is not settled, and the heartbeat file overwrites its own evidence on the next
  poll, so any fix must start by capturing what the check actually saw.
- **A stop instruction that ends with "stop" leaves a seat unreachable.** The
  poller exits on delivery; a seat that stops without re-arming has no reader and
  nothing can wake it. Any stop procedure must end with re-arm, then stop.
- **An active seat with no reader accepts mail silently.** `send` warns when a
  recipient has no poller heartbeat, but the registry state is still legal. Retire
  the seat or start a reader.
- **Command-name guards match spelling.** The secret-read hook and similar guards
  stop accidents and first drafts, not a session determined to get around them. A
  real boundary is an operating-system permission.

**The standing caution:** for a fleet using it, `aimail` is the only channel
between seats. A bad patch here does not raise a false alarm, it produces
silence, and silence looks the same as everyone being busy. Change it in daylight,
with someone watching, and never in the middle of an incident.
