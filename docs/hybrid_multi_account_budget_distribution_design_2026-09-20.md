# Hybrid multi-account budget-distribution design (fable, 2026-09-20)

**Status: DESIGN ONLY, nothing built.** Written per the project owner's direct ask (via assistant,
20260920T143840, scope narrowed 20260920T144745). Report back to assistant for gate/read
before any of this is built, per standing practice.

## 1. The problem, as stated

Replace "burn one account's weekly budget, park, switch to the next" with a system that
distributes fleet load across multiple live Anthropic accounts at once. Two constraints in
tension:

1. **HARD, non-negotiable:** never cross the 5-hour session cap on any single account (90%
   day / 80% night, unoverridden; per-seat overrides exist, e.g. assistant's 95%). Crossing
   it risks a session dying mid-command with no handover written.
2. **Soft, real goal:** still drive aggregate weekly consumption on the WHOLE pool up toward
   each account's own weekly cap by its own reset. Idle headroom left on the table at a reset
   is wasted — weekly usage never banks across a reset either direction.

Confirmed pool (assistant's 14:47 narrowing — this is the design's actual scope, not the
5-account list first sent): **`work`, `research`, `r2` only.** `tempmanas` is emergency-only
and needs reauth first; `tempsteven` is fully out of scope. Current state at design time:

| account  | weekly cap | resets              |
|----------|-----------:|----------------------|
| work     | 98%        | 2026-09-20 19:00 (today, ~4.5h from design time) |
| research | 98%        | 2026-09-27 07:00     |
| r2       | 97%        | 2026-09-22           |

## 2. What already exists — read before designing something that duplicates it

`lib/budget.sh` already solved more of this than the brief assumes. Three real, working
pieces, all landed 2026-09-17 for a different reason (a cron-vs-live-account mismatch
incident) but directly reusable here:

- **Per-account state everywhere it matters.** `account_id()` resolves via the live
  `CLAUDE_CONFIG_DIR`; the block cache (`block.$(account_id).json`), the weekly file
  (`weekly_<acct>.tsv`), and the ledger's own `account` column are already all keyed this
  way. `account_cap()` / `weekly_cap()` already support per-account overrides
  (`AIMAIL_CAP_<acct>`, `AIMAIL_WEEKLY_CAP_<acct>`) — the three accounts' current 98/98/97
  values are exactly this mechanism, already in the crontab.
- **Per-seat GROUND-TRUTH account resolution.** `seat_account_dir(seat)` reads
  `/proc/<pid>/environ` of that seat's own live poller process for its real
  `CLAUDE_CONFIG_DIR` — not a config guess, not the ambient shared symlink. This already
  works today for any seat running as a native `claude --bg` session with its own
  `CLAUDE_CONFIG_DIR`, i.e. exactly the CLI-migrated shape the fleet is now in. **This is
  the one piece of infrastructure that makes "seats genuinely split across different live
  accounts at once" already observable, today, with zero new code.**
- **Autopilot already runs per-account, not per-fleet.** `_autopilot_seat_groups()` groups
  every live, non-retired seat by its own resolved account; `budget_autopilot()` then calls
  `_budget_autopilot_tick()` once per DISTINCT account, with `CLAUDE_CONFIG_DIR` overridden
  for that call only. If two seats are already on two different live accounts right now,
  autopilot is *already* probing, checkpointing, and cap-checking both, independently, every
  5 minutes. Nothing about the probing/checkpointing side of "multi-account" needs building.

## 3. The one real gap — named in the code, not yet closed

`budget.sh`'s own comment (above `budget_park()`) names this exactly:

> the `$STATE_DIR/throttled` flag (and `ramp_at`, and the checkpoint-streak files) is
> GLOBAL, not per-account... If the fleet ever DOES run two genuinely simultaneous
> accounts, one account parking at its own cap would... also freeze the OTHER account's
> park/ramp bookkeeping fleet-wide, since there is only one `throttled` file to check.
> Making park/ramp/checkpoint-streak state genuinely per-account is a real, separate,
> larger piece of work... out of scope here, and not silently assumed solved.

Concretely: `_budget_autopilot_tick()` checks `[[ -f "$STATE_DIR/throttled" ]]` — one file,
shared by every account. If `work` hits its cap and parks, that SAME flag makes
`research`'s and `r2`'s ticks believe *they* are parked too (poller.sh's own park-check
reads the identical file). This is the one piece that must actually change before two
accounts can run live at once without one's cap silently stalling the other. (The
checkpoint-done marker is already partially fixed — `checkpoint_done.$acct` exists — the
park/ramp pair is the piece still sharing one file.)

## 4. Design

### 4a. Per-account park/ramp state (the mechanical fix)

Extend the existing pattern (`block.$(account_id).json`, `weekly_<acct>.tsv`,
`checkpoint_done.$acct`) to the two remaining shared files:

- `throttled` → `throttled.<acct>`
- `ramp_at` → `ramp_at.<acct>`

`budget_park`/`budget_ramp`/`budget_refresh_ramp`/`budget_weekly_still_blocking` take an
account argument (defaulting to `account_id()` for today's single-account callers, so every
existing direct/manual invocation is unchanged). `_budget_autopilot_tick` already carries
`$acct` through its whole body — it just needs to pass it into these four calls instead of
letting them read the ambient file. **This is the only breaking-shaped change in the whole
design** — everything else below is additive. Scope: four functions, ~30 lines, one set of
tests for "account A parks, account B's tick is unaffected."

### 4b. Pool state model — a new read-only view, not a new ledger

No new storage. `_autopilot_seat_groups()` already computes "which live seats are on which
account, right now" every 5 minutes — it's just never been surfaced to a human or to a
policy function, only consumed internally by autopilot. Add `aimail budget pool`: for each
of the three accounts, print session%/weekly%/reset/cap (from the existing per-account
ledger reads) and the seat list from `_autopilot_seat_groups()`. This is the dashboard the
brief asks for — built entirely from data that already exists.

### 4c. Allocation policy — deliberately simple, not an optimizer

When a seat's own account is parked (session or weekly HALT) or a seat needs a fresh
account (e.g. first launch after a reset), the policy is: **assign the live-eligible
account with the most remaining weekly headroom** (`weekly_cap - weekly%`), among accounts
that are not themselves currently parked. Ties break toward whichever account resets
soonest (use up its headroom first, since idle time there is closer to being wasted).

This is a greedy max-headroom assignment, not a scheduler that reasons about future burn
rate — matching this fleet's own stated preference (see `budget.sh`'s own header) for
mechanisms keyed on measurable state over predictive guesses. It directly serves the soft
goal (spread load so all three trend toward their own cap by their own reset, instead of
sequentially exhausting one) without needing to model or predict anything.

Explicitly NOT in scope for this policy: proactively moving a seat OFF an account it's
using fine, just to "balance" load. Reassignment triggers only on (a) a park event for that
seat's current account, or (b) a seat with no live account at all. A healthy seat on a
healthy account is left alone — churn has a real cost (see 4d) that a purely cosmetic
rebalance would not justify.

### 4d. Seat migration — decide + report automatically, act only under supervision

Moving a LIVE seat to a different account is not a config write — per
`docs/cli_account_migration.md`, it means killing that seat's process and relaunching
`claude --bg --resume <that-account's-own-session-id-for-this-seat>` under the new
account's `CLAUDE_CONFIG_DIR`, then waiting for the seat's own confirmation mail. That is a
real, destructive-adjacent action (killing a live process) — this fleet's own standing
rules already say a kill needs a liveness/WORKING check first and is not something
automated infrastructure does unattended.

So the automatic half stops at deciding and reporting:
1. Autopilot's per-account tick detects a park for account X.
2. For every seat whose `seat_account()` resolves to X: force a checkpoint (`budget_checkpoint
   --now`) if not already done for this episode — this already happens today for the
   session-cap park path (see `_budget_autopilot_tick`'s own "force the checkpoint here"
   block); extend the same call to the weekly-cap park path, which currently does the same
   force-checkpoint but the reassignment step below is new.
3. Run the 4c policy to pick a target account Y.
4. Write a `seat_reassign_<seat>` marker (target account, reason, timestamp — same shape as
   the existing `seat_unpark_<seat>` grant file) and mail the seat's supervisor (not the
   seat itself, which is about to be killed) with the exact migration command from
   `cli_account_migration.md`, pre-filled with the seat name and target account.
5. A human (or assistant, acting as supervisor with an explicit go) runs the kill +
   relaunch. This keeps the migration itself a one-line copy-paste of an already-proven
   procedure, not a new script that has never been run unattended.

A fully automatic kill/relaunch is a natural future increment once this manual step has
been exercised safely a few times — not proposed here, to keep this design's first version
provably safe rather than clever.

### 4e. Interim step for today's `work` reset at 19:00

No new mechanism is needed to use this. `work` resets, someone (assistant or the project owner) picks
whichever currently-live seat is closest to its own cap on `research` or `r2`, and runs the
existing, already-proven `cli_account_migration.md` procedure to move that one seat onto
`work`. 4a-4d above make this decision and the reporting around it automatic for *future*
resets; tonight's first move can and should just be done by hand with the existing process,
since the mechanical fix (4a) is the only piece any of this actually depends on, and it has
not been built or tested yet.

## 5. Open question for the project owner — do not guess

The brief says: "each account has a separate limit for that" re: tracking fable's own
budget/usage per account. Two different things this could mean, with different designs:

- **(a)** Fable's own seat-level consumption, watched as its own line per account it runs
  on — this already exists as data (the ledger's account column + `seat_account()`), it
  just isn't surfaced as its own report today. Cheap to add as a `budget pool --seat fable`
  view.
- **(b)** Fable's role handovers are unusually large (60KB+, over the file's own 32KB
  guideline) and this is really a concern about fable's own footprint eating a
  disproportionate share of whichever account it's on — a handover-hygiene problem, not a
  budget-distribution one, and a different fix entirely (compaction discipline, not new
  tracking).

Not guessing which one is meant; flagging back per the brief's own instruction to ask
rather than build the wrong one.

## 6. "Improved aimail system" — separate ask, not folded in here

The project owner mentioned this in the same breath but unscoped beyond that. The overlap with this
design is real but narrow: 4a's per-account state files touch `budget.sh` directly. Nothing
else here (the pool view, the allocation policy, the migration mailer) reaches into
aimail's own delivery/ledger mechanism. Treating "improved aimail system" as its own,
later, separately-scoped design rather than letting it expand this one — per the brief's
own instruction.

## 7. Build order, if this design is accepted

1. 4a (per-account throttle/ramp) — the only piece with real correctness risk; needs its
   own test (`account A parks, account B's tick unaffected`) before anything else depends
   on it.
2. 4b (`budget pool` read-only view) — zero risk, pure reporting, useful immediately even
   before 4c/4d exist.
3. 4c + 4d (policy + supervised-migration mailer) — depends on 4a being correct, since the
   policy's own "is this account parked" check must be reading the per-account flag, not
   the old global one.
