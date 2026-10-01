# Fleet dispatcher — design

**Status: DESIGN, for review before build.** Priority project (the project owner, 2026-09-24
~17:10, relayed by assistant: "make sure to build the aimail thing... make it priority").
Author: the design seat. This document is generic: no owner, company, project or real customer
name appears anywhere below; seats are referred to by their fleet ROLE (`fable`, `assistant`,
`main`, `code-review`, ...), which is how every other file in this repo already refers to them
(`AIMAIL_FABLE_SEAT`, `AIMAIL_SUPERVISOR`, `AIMAIL_VICE_SUPERVISOR` are the same convention).
Reviewers: code-review (correctness), assistant (vision — does this plan ahead of demand, price
moves/compaction, use per-model limits, treat seats by role, replace the spread rule rather than
sit beside it, ship advisory-first). Main lands only after both are satisfied.

## 0. The problem, as framed

Automate the account balancing `librarian` does by hand today. The owner's own framing: this is
a power grid with demand that changes through the day. Bringing a plant up or down (a seat move)
is slow and expensive — a cold-cache boot — so the action has to come ahead of demand, not react
to a cap already crossed. It is explicitly **not** "N seats over M accounts, spread evenly":
seats differ in price (a heavier model, a longer context), some have their own per-model weekly
ceiling (`fable`), some are pinned to a fixed account (`assistant`, `main`), not every seat runs
at full tilt, and auto-compaction changes a seat's own future cost without moving it at all.

## 1. What exists today, read directly (not from memory of an older doc)

Two real, running systems already cover part of this ground. The dispatcher does not duplicate
either; it **replaces** the parts named below and **keeps** the parts that already work.

### 1.1 `lib/balance.sh` — measurement + account-level pressure (KEEP, extend)

Already landed, already running inside the autopilot tick, already read-only (`docs/
load_balancer_design_2026-09-21.md` §3.1–§3.4, its own header says so explicitly: *"Nothing here
moves a seat, writes a placement marker, or mails anyone... `aimail budget balance` prints what
it WOULD recommend"*).

- **Per-seat usage ledger** (`state/seat_usage.tsv`, `seat_usage_tick`): one row per
  `(session, model)` per tick, cumulative token counts from `ccusage session --json`, session id
  resolved to a seat via the seat record → poller instance file → stop-guard registration, else
  `_unattributed`. **Reconciled every tick** (`_bal_reconcile`) against the account's own active
  block delta; outside `AIMAIL_SEAT_USAGE_TOLERANCE` (15%) the tick is marked UNMEASURED and
  costs for that account are treated as unknown — zero is never substituted. This is real,
  working, tested MEASURE infrastructure; §2 below reuses it as-is.
- **Weighted-token cost** (`seat_costs`): input 1.0, output 5.0, cache-create 1.25, cache-read
  0.1 (price ratios, overridable per model). `budget_seats` prints it per seat with a
  reconciliation verdict.
- **Account pressure** (`balance_pressure`): least-squares slope of weekly% (and block%) over a
  trailing window, divided by the headroom-per-hour needed to land exactly at the cap at the
  reset. `> 1` means the account caps before its reset at the current rate; `parked` = ∞.
- **Streak/hysteresis** (`balance_evaluate`, `state/balance/streak`): arms on a sustained
  hot/cold pressure gap (or a seats-count-AND-weekly% "skew" rule added 2026-09-21 after a
  specific incident), clears on a sustained narrow gap. Auditable, one line per evaluation.
- **What it does with an armed streak, today:** `_bal_would_recommend` picks the idlest,
  cheapest seat on the hot account that narrows the gap without flipping it, then asks
  `placement.sh` (§1.2) for the actual target account, and **prints** the `seat migrate
  --dry-run` line. `AIMAIL_BALANCE_MAIL` (default off) gates a once-per-episode mail. Nothing
  moves a seat. `--plan` (the design doc's own §3.6 water-filling) is explicitly **not built**.

### 1.2 `lib/placement.sh` — the current spread rule (REPLACE)

Built 2026-09-22 after a **named, real incident** in its own header: *"r2 parked at
16:55 with 6 of 9 seats on it while research sat at 8%. The balancer had mailed six
recommendations and nothing moved; the pick logic had recommended moving the assistant itself
off work. The owner: 'never again.'"* Five rules, each a real function:

- **R1 PINNED** — `assistant`/`main` (configurable) never move; only an explicit
  `--owner-approved` overrides.
- **R2 PRECIOUS** — the supervisor's own account is never a *destination* for a non-pinned seat
  while any other account has headroom; it absorbs overflow only.
- **R3 FABLE** — the `fable` seat is placed by **its own model's** weekly headroom / expiry
  risk (`_pl_fable_expiry_risk`: points left, divided by hours to that account's own reset —
  "goes where its budget would otherwise expire unused," a real correction from a real
  2026-09-22 ruling), not the account's general percentage.
- **R4 SPREAD** — no account carries more than `ceil(non-pinned seats / accounts with
  headroom)` non-pinned seats; a move that would exceed this is refused outright.
- **R5 PROJECTED** — among eligible accounts, rank by **minutes to the block cap at the
  current burn rate**, then weekly headroom. Backward-looking only: it has no notion of what a
  seat is about to start doing.

This is the "spread rule" the priority ask names. It is a real, incident-hardened set of
*constraints* (R1–R3 are correct and are kept, see §4), but R4/R5 are a **headcount-fair-share +
backward-burn-rate heuristic**, not a cost model. Concretely, R4/R5 cannot represent any of:

- that a heavy seat and an idle seat count the same toward "share" (R4) — exactly the "it is not
  9 seats / 3 accounts" objection;
- that a seat about to pick up queued work, or about to go idle waiting on someone, burns
  differently going forward than its recent rate (R5 has no forecast, only a two-point recent
  slope, `_pl_burn_pct_per_min`);
- that moving one seat costs a cold-cache boot and moving another (already about to restart
  anyway) costs nothing extra;
- that compaction is a lever at all — `context_readout.py` (§1.3) is not referenced anywhere in
  `placement.sh` or `balance.sh`;
- that a park costs differently depending on the seat's role: `code-review` or `main` parked
  stops every landing fleet-wide; a seat that is itself blocked on someone parked costs ~nothing.

This is the mechanism the priority ask means by *"today the spread rule refused the right move
and would have allowed the wrong one"*: R4/R5 optimize headcount balance and recent burn, not
the thing that actually matters (stall cost minus move cost, going forward).

### 1.3 `lib/context_readout.py` — context size, built, unwired (KEEP, wire in)

Landed 2026-09-23, reads a session's own last real (non-synthetic) assistant turn's
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens` — the exact quantity that
drives cache-read cost every subsequent turn — by seeking backward from EOF in growing chunks
(never loading a multi-MB transcript whole). Self-tested, has a stdin batch mode (`sid \t seat \t
transcript_path` per line → `{sid: {...}}`). **Not called from anywhere in `balance.sh` or
`placement.sh` today.** This is the "current context size" MEASURE item the priority ask names
as already existing; it is real and ready to wire in, not a gap to build.

### 1.4 The ask ledger (`lib/ask.sh`) — the forecast signal, built, unused for this purpose

Landed 2026-09-23 for a different reason (a dropped-task incident), but its schema is exactly
the "owner/waiting_on/next fields" the priority ask names as the forecast signal: `asks.tsv`,
18 columns, key ones being `owner` (col 3), `next` (col 5), `state` (col 8, one of
`OPEN | STALE | WAITING-ON-<seat> | WAITING-ON-OWNER | DONE | WITHDRAWN` via
`_ask_state_label`), `waiting_on` (col 18). `ask_counts <seat>` gives `<open>/<stale>`;
`ask_digest` lists every row blocked on someone. A seat with only `WAITING-ON-*` rows is a real,
already-computed "burns ~0 next" signal; a seat with fresh `OPEN` rows and no `waiting_on` is a
real "queued work" signal. Nothing today reads this ledger for placement.

### 1.5 Real numbers, read live at design time (2026-09-24 17:09, `python3
zignore/fleet/burn_prototype_2026-09-24.py`, trailing-30-minute window, three accounts)

```
account   seat         msgs  cache_write  cache_read   out
work      assistant      93       94k       31.5M      66k
work      main          106      183k       35.1M      72k
r2        fable          87      915k       22.0M     132k
r2        foundation     29       29k        5.9M      12k
r2        code-review   212      239k       30.9M      96k
r2        librarian     180      257k       49.2M      84k
research  architect      30      151k        7.8M      21k
research  framing        60       54k       15.5M      23k
research  audit          19       24k        6.4M       8k
```

This is the concrete shape of the problem, not a hypothetical: on `r2` alone, `librarian`'s
cache-read (49.2M) is more than 8× `foundation`'s (5.9M) in the same 30 minutes, on the same
account — a placement rule that counts both as "1 non-pinned seat" (R4) cannot see this
asymmetry at all. `fable`'s cache-**write** (915k) dwarfs every other seat's by 3-6×, which is
exactly the "fable is pricier" framing — but R3 already handles fable specifically via its own
model-weekly headroom, so this is a KEEP, not a gap. `foundation`/`architect`/`audit` (5.9M/
7.8M/6.4M cache-read) are the near-idle seats the priority ask itself names; a fair-share rule
would never single them out as move candidates ahead of the account's own hot seats, because
R4/R5 do not rank by cost at all inside an account, only across accounts.

### 1.6 A gap in the account inventory itself, verified live (2026-09-25 01:19 incident)

Everything in §1.1–1.5 measures seats and, through them, accounts — but two real incidents
tonight (assistant, checkpoint mail) show the account list the dispatcher would enumerate from
is itself incomplete, in exactly the way that matters most: a freshly-reset, currently-empty
account is invisible right when it is the cheapest possible `MOVE` target.

- **`budget pool` omits an account with no live seats on it** (`lib/budget.sh:843-892`,
  `budget_pool()`): the account list it prints comes from `_autopilot_seat_groups`'s own
  seats-by-account grouping (or `AIMAIL_FLEET_ACCOUNTS` if explicitly set) — an account with
  zero live seats simply has no row in that grouping and never enters `accts[]` at all. Verified
  against tonight's incident directly: `r2`'s block rolled at 01:19 while every seat had already
  moved off it, so it stayed parked and absent from `budget pool`'s own table until a human
  ramped it by hand — not flagged, not printed as "parked, 0 seats," simply not there.
- **`budget probe` reads a not-yet-started block as UNMEASURABLE, not 0%** (`lib/budget.sh:
  415-418`): `jq -r '.five_hour.utilization // empty'` maps a JSON `null` (the shape a block
  that has not started yet returns) to the same empty-string result as a missing field, so it
  falls into the SAME `unmeasurable` path as a broken/changed response shape, a network failure,
  or missing credentials (§ the function's own header rule, "IT DOES NOT FIND A FIELD, IT SAYS
  SO"). That rule is right for every OTHER failure mode it guards — collapsing "genuinely 0%,
  block not started" into the same bucket as "this probe is broken" is the one place it
  overreaches, because a null utilization is not a probe failure, it is a real, meaningful,
  perfectly measurable account state.

**Why this is a dispatcher-design problem, not just a `budget.sh` bug report:** §1.1/§2's own
account-pressure measurement and §5's `MOVE` target search both need to enumerate EVERY account
in the pool, not only the ones with a live seat on them right now — a seat about to be moved
(§5) is, by definition, about to make its source account seat-empty, and the account it is
being ranked against for the move destination may *already* be seat-empty this exact tick. A
plan-search step that inherits `budget_pool`'s own account enumeration would have the identical
blind spot `budget_pool` has today, silently narrowing its own candidate set to "accounts
someone happens to be on" instead of "every account in the pool" — precisely backwards, since
an empty, freshly-reset account is usually the single cheapest destination available. Similarly,
a `predicted_pressure`/`stall_cost` (§4) computed against an UNMEASURABLE-because-null-utilization
account would either be skipped as ineligible (matching `budget_pick_account`'s own explicit
"unmeasured is not eligible, never assumed 0" rule, §1) or, worse, silently read as "no data,"
when the correct value is a known, real `0`.

**A §2 dependency, already in flight as its own fix (§7):** §2's account enumeration must come
from the pool's own CONFIGURED account list (`AIMAIL_FLEET_ACCOUNTS`, already the
fallback-avoiding path `budget_pool` itself supports today when set explicitly) rather than
derived from current live seats, so a zero-seat account still gets a pressure row; and §2/§4's
own reading of `five_hour.utilization` must distinguish "field present and null" (read as 0%, a
real, current, freshly-reset state) from every other unmeasurable failure mode (field absent,
non-numeric, probe error) — the existing `unmeasurable` path is correct for the latter and must
stay conservative there, this is narrowly about the one case where `null` has a known, exact
numeric meaning. Neither is a new instrument; both are precision fixes on data §1.1 already
reads. Assistant queued this exact fix to `foundation` tonight (§7, mail `20260925T014759`) as
its own standalone change, ahead of and independent of this design's own build — §2 depends on
it landing first, rather than owing the fix itself.

## 2. MEASURE — every ~10 min

Reuse §1.1–1.3 verbatim; add nothing that duplicates them (matching this codebase's own stated
preference, `hybrid_multi_account_budget_distribution_design_2026-09-20.md` §4c: "mechanisms
keyed on measurable state over predictive guesses").

- **Per-seat burn, priced by model:** `seat_costs <acct> <window_h>` (§1.1), unchanged. Read at
  1h and 3h windows (both already supported via the `--window` arg) — 1h for PREDICT's
  near-term view, 3h for FORECAST's trend.
- **Per-seat context size:** new tick step `dispatcher_context_tick`: for every live seat, its
  `(sid, seat, transcript_path)` (from `aimail sessions --json`, already exists) piped through
  `context_readout.py`'s stdin batch mode, appended to a new `state/seat_context.tsv` (epoch,
  seat, context_tokens). One line per seat per tick; this is the missing wiring named in §1.3,
  not a new instrument.
- **Idle vs working:** `_bal_seat_activity` (§1.1, already computed: 0 idle / 1 between / 3
  mid-task / 9 not-a-candidate from poller state + `gateclaim.sh --list`). Reused unchanged.
- **Per-account:** `balance_pressure` (§1.1) unchanged — block%, weekly%, per-model weekly% (via
  the existing model-scoped ledger rows §1.1 already carries), reset times, parked flag.

Output: extends the existing `state/seat_usage.tsv` + new `state/seat_context.tsv`, both
autopilot-tick-cadence, both already-proven formats (append-only TSV, reconciled where a ground
truth exists). No new usage store, per the same 2026-09-20 design rule this repo already follows.

## 3. FORECAST — demand per seat, going forward

**Revised per assistant's vision review (20260924T171439, item 3).** The first cut of this
section scaled a seat's own *recent* burn (`cost_1h`) by a 0/1 queue factor — which under-
forecasts exactly the seat the mechanism most needs to get right: one that is near-idle *right
now* because it just picked up new work (its recent-hour burn is low by construction, so
`recent_burn × 1` still reads near-zero). The fix is to forecast against the seat's own
**typical active rate**, not its most recent hour:

- `active_rate(seat)`: median `cost_1h` (§2's own weighted-token ledger) over every tick in the
  trailing `AIMAIL_FORECAST_LOOKBACK` (default 7 days) where `_bal_seat_activity(seat)` (§1.1,
  already computed) was NOT idle (0) — i.e. the seat's own historical "when working, burns
  about this much" rate, immune to whatever it happens to be doing this exact hour.
- `queue_factor(seat)`, from the ask ledger (§1.4): **not** a bare 0/1 gate on `recent_burn`.
  - Every open row `WAITING-ON-*` (owner or another seat) → `queue_factor = AIMAIL_BLOCKED_FLOOR`
    (default 0.05, not exactly 0 — a blocked seat's poller and mail traffic still cost
    something, and a hard zero has made a real balancer wrongly certain before, see
    `placement.sh`'s own R5 header incident).
  - At least one `OPEN` row with a non-empty `next` and empty `waiting_on` (real queued work,
    stated next step) → `queue_factor = 1.0` — this is the case the review named: a seat that
    looks idle by recent burn but is about to become the fleet's next hot seat.
  - No open rows at all → `queue_factor = AIMAIL_IDLE_FLOOR` (default 0.15) — genuinely between
    tasks, not blocked on anyone, so somewhat likelier to pick up new work than a seat actively
    waiting on someone else, but not assumed busy.
- `context_tokens` (§2) forecasts the **per-turn** cost multiplier going forward (roughly linear
  in cache-read price) independent of how many turns are forecast — a seat sitting at 800k
  context costs ~2× one at 400k for the same amount of *work*, which is exactly why compaction
  is a priced lever in §5 rather than only a move.

Output: `forecast_burn(seat) = active_rate(seat) × queue_factor(seat)`,
`forecast_context_multiplier(seat) = context_tokens / AIMAIL_CONTEXT_BASELINE` (default 400k,
**per-model config** per assistant's answer to the open question — a smaller-context-window
model needs its own baseline). Both are read-only derivations over §2's own data plus the
existing ask ledger — no new measurement. `queue_factor`'s three-state shape (blocked-floor /
idle-floor / active) stays deliberately coarse for v1, per assistant's own answer: "keep it
two-state plus active-rate for v1" — the third state here is the *floor value*, not a new
continuous model; whether it should get richer is a v1-outcome-log question (§7), not guessed
now.

## 4. PREDICT — which account caps before reset, and what that costs

For each account, using `balance_pressure` (§1.1, unchanged) but fed `forecast_burn` (§3) in
place of the raw ledger slope where a seat's queue factor is 0 (i.e., predicted pressure can be
*lower* than measured pressure for an account whose seats are mostly blocked right now — the
one case R5's backward-only view structurally cannot produce):

`predicted_pressure(account) = Σ_seats forecast_burn(seat) / sustainable(account)` — same
`sustainable` definition as §1.1 (headroom ÷ hours to reset), computed separately for the
**block** reset and each **weekly** reset (including the model-scoped weekly, §7 item 7) an
account tracks — a seat can be fine against one and about to cap against another.

**Stall cost, weighted by role** (new — nothing today computes this) — **revised per assistant's
vision review, item 4: the first cut multiplied role weight by a pressure ratio, which is
dimensionless and does not answer "how much did this actually cost." The real quantity is idle
landing-capacity-TIME**, so:

- `role_weight`: `critical_path` (config `AIMAIL_CRITICAL_PATH_SEATS`, default `main
  code-review` — a park here stops every landing fleet-wide, per assistant's own answer to the
  open question) = high; `blocked` (a seat with only `WAITING-ON-*` open rows, from §3) = ~0;
  `normal` (working, not on the critical path) = 1. This is a distinct concept from
  `AIMAIL_PINNED_SEATS`/`AIMAIL_SUPERVISOR` (a seat's own placement constraint) — `main`/
  `code-review` here are named for who *depends on them*, not for where they may be placed.
- `projected_cap_time(account, window)` — the epoch `predicted_pressure(account, window)`
  crosses 1.0, from the same slope used in §1.1/§4 (linear extrapolation from the current
  forecast-fed rate).
- `stall_duration(account, window) = reset_time(account, window) − projected_cap_time(account,
  window)` when positive (the account caps before its own reset; zero otherwise) — this is
  literally the hours the account sits parked before it would have reset anyway.
- `stall_cost(account) = Σ_windows Σ_seats-on-account role_weight(seat) × stall_duration(account,
  window)` — role-weighted **landing-capacity-hours lost**, the quantity the doc's own prose
  always meant; a park with only `blocked` seats on it costs ~0 no matter how long it lasts, a
  park with a `critical_path` seat on it costs in proportion to how long every landing fleet-wide
  is stopped.

Output: `predict_report()` — per account, per window (block + each weekly), `predicted_pressure`,
`projected_cap_time` (if `predicted_pressure > 1`), and `stall_cost` at that time. This is
`aimail budget balance`'s existing table (§1.1) with the pressure column replaced by a
forecast-fed one and a new stall-duration/stall-cost column — additive to what already prints,
not a new surface.

## 5. PLAN — the actions that minimize total cost under hard constraints

**Revised per assistant's vision review (20260924T171439, items 1, 2, 5, 6, 8, 9).** This is
what replaces §1.2's R4/R5. R1 stays a hard constraint; R2/R3 are reframed as described below
rather than left as blanket bans.

**Hard constraints, v1:**
- R1 PINNED seats never move (unchanged from `placement.sh` — item 9 leaves this one as-is).
- R2 PRECIOUS, **reframed as cost, not a blanket ban** (item 9): the account holding the fleet's
  own supervising/landing infrastructure carries a very high `role_weight` in `stall_cost` (§4)
  plus a safety margin — a move onto it is allowed only if `predicted_pressure(account, block) <
  AIMAIL_PRECIOUS_MARGIN` (default 0.8) **through its own next reset**, not merely "has headroom
  right now." Kept as a hard gate in v1 for simplicity (assistant: "it can stay a hard rule in
  v1 if simpler"), explicitly named as the first rule the cost model should absorb once the
  outcome log (§6) has enough data to trust a soft version.
- R3 FABLE → **R3 PER-MODEL** (item 8): the constraint is never about a *seat*, it is about a
  *model's* own weekly ceiling on an account — any seat can change model, and `assistant` itself
  runs a non-default model. For every `(seat, model)` the seat is actually running under this
  tick, the target account must have positive headroom on **that model's own** weekly, ranked by
  `expiry_risk(account, model)` (the same points-left/hours-to-reset shape `_pl_fable_expiry_risk`
  already computes, generalized from "the fable seat" to "whichever model this seat runs" — see
  §7 item 7 for extending this ranking fleet-wide, not only at placement time).

**Actions, three kinds (item 2: HOLD is a first-class action, not a no-op):**
- `HOLD(seat, until)` — defer non-urgent queued work by holding the mail that would start it.
  **Cost:** `delay_cost(seat, until)` — near-zero for a seat whose queued work has no external
  deadline, high for a seat on the critical path (`role_weight`, §4) whose hold blocks a landing.
  This was the single best move available at design time (assistant's own example: holding one
  seat's new work until a specific account's imminent block reset cut that account's forecast
  pressure with zero boot cost) — a plan that cannot propose this can never find the cheapest
  lever, which is why it is priced and searched exactly like a move, not assumed away.
- `COMPACT(seat)` — **priced for real, not near-zero (item 6).** `/compact` (or lowering the
  account's own `autoCompactWindow`, `sessions.sh`'s existing report-only reader) reads the
  seat's full current context once (a cache-read-priced pass over `context_tokens`) and writes a
  smaller summary that the next turn re-reads as a fresh cache-write:
  `compaction_cost(seat) = context_tokens(seat) × weight_cache_read + context_tokens_after ×
  weight_cache_write` (weights from §1.1's own `_bal_weights`, `context_tokens_after` a
  configured fraction of `context_tokens`, `AIMAIL_COMPACT_RATIO`, default 0.3, until the outcome
  log has real before/after pairs). It also has a **quality cost** the token math cannot price
  (lost working detail) — eligibility is therefore restricted to a seat `_bal_seat_activity`
  (§1.1) scores idle (0) or between (1), **never mid-task (3)**, matching item 6 exactly.
  ⚠ **Mechanism, verified rather than assumed:** grepping this repo's own `lib/` and `bin/` finds
  exactly two compaction levers — the account-level `autoCompactWindow` setting
  (`sessions.sh`'s `context --settings`, already report-only) and the interactive `/autocompact
  <tokens>` slash command, which needs a live turn to type it. **Neither is an existing external
  trigger a dispatcher could call on a background seat today.** This is a real v1 gap, not
  "already a supported live command" as the first draft assumed: v1's `COMPACT` action needs
  either (a) delivering the compact instruction as an aimail message the seat's own next turn
  acts on (seats already treat aimail as an instruction channel, so this reuses an existing
  pattern), or (b) writing that account's `autoCompactWindow` down for one tick then restoring
  it. Neither is built; §6 lists this as a named v1 dependency, not a given.
- `MOVE(seat, account)` — unchanged mechanism (`seat migrate`, §1.1/§1.2), but **priced for real
  (item 5):** `cold_boot_cost(seat) = context_tokens(seat) × weight_cache_write` (§1.1's own
  weight, 1.25 by default) — the real cost of the first turn after resume re-establishing the
  seat's own context as a fresh cache write. This needs no fitting to be principled (it is the
  same weighted-token arithmetic §1.1 already trusts for billing), and is exactly what a flat
  constant could not express: a seat with a large handover costs more to move than one with a
  small one, which is visible today, not hypothetical.

**Cost function:** `total_cost(plan) = Σ moves cold_boot_cost(seat) + Σ compactions
compaction_cost(seat) + Σ holds delay_cost(seat, until) + Σ accounts stall_cost(account, plan)`
(§4's stall cost, recomputed for the plan's resulting schedule). A plan may compact a seat before
moving it — `cold_boot_cost` is then computed against the post-compaction `context_tokens`,
which is why compacting first is cheaper, exactly as the priority ask itself states.

**Search:** for the fleet sizes this runs at (single digits of seats, low single digits of
accounts), exhaustive enumeration of {no-op, HOLD-seat-X-until-T, COMPACT-seat-X,
MOVE-seat-X-to-account-Y} combinations is cheap; no heuristic search is needed in v1. A plan is
accepted only if `total_cost(plan) < total_cost(no-op)` by a margin (`AIMAIL_PLAN_MARGIN`,
default matching the existing hysteresis gap `GAP_ON`).

**Timing — bug fixed (item 1):** `not_before` for a `MOVE` or `COMPACT` is the target account's
own **block (5-hour) reset**, not its weekly reset (the first draft's error: a real move today
was timed to a 17:20 block reset, days before that account's actual weekly reset). A `HOLD`'s
`until` is whichever reset the plan is draining load toward (§7 item 7's plan horizon). Only
actions whose `not_before` has already passed are handed to §6 as executable now; the rest are
the plan's own forward schedule, re-evaluated every tick.

Output: `dispatcher_plan()` — the accepted action list (each with its own cost breakdown,
`not_before`, and the constraint that admitted it), or "no-op: <reason>" mirroring
`_bal_would_recommend`'s existing "none — <reason>" shape.

## 6. EXECUTE — staged, like every other sensor this fleet has built

Matches this repo's own established pattern (`beam_post` sensor fusion staging, `balance.sh`'s
own "recommend-only until a full weekly cycle is read" rule) — nothing here skips straight to
auto-execution.

- **v1 ADVISORY, with lead time (item 10).** `dispatcher_plan()` prints its reasoning (the same
  table shape as `aimail budget balance` today, extended with the PLAN section's cost breakdown)
  and appends one row per proposed action to `state/dispatcher/proposals.tsv` (epoch, action,
  seat, target, `not_before`, predicted cost, predicted outcome). A proposal whose `not_before`
  falls inside the next `AIMAIL_DISPATCH_LEAD_MIN` (default 30 min) triggers a mail to the
  operator NOW, naming the exact time and action ("at 17:20: move code-review r2→research,
  because...") — planning ahead only helps if the operator hears about it before the window,
  not printed-and-forgotten in a table nobody re-reads on schedule. `librarian` (the existing
  manual operator) approves and executes by hand, exactly as today, but now reading the
  dispatcher's proposal instead of re-deriving the picture from `budget pool`/`budget balance`
  separately.
  **Outcome log, extended (item 11):** a second row is appended when the outcome is known,
  recording BOTH (a) the measured result (did the account actually cap when predicted; did the
  seat's burn match the forecast) and (b) **the operator's own decision** — accepted /
  modified (and how) / rejected (and why), free text — `state/dispatcher/outcomes.tsv`, keyed to
  the proposal it scores. (b) is what lets v1 learn where its judgment diverges from the
  operator's own, which a forecast-accuracy score alone cannot show (a "correct" forecast the
  operator still overrode for a reason the model doesn't know is exactly the gap v2 needs
  closed before any auto-execution). This generalizes `load_balancer_design_2026-09-21.md` §5
  step 2's own discipline (nothing recommends until read against a full cycle) to score both
  forecast accuracy and operator agreement, not only the arm/clear boundary.
- **v2 auto-execute, low-risk actions only**, gated on v1's own logged accuracy (a stated
  threshold, not a date — e.g. N proposals with a forecast-vs-outcome error under X%, mirroring
  §6 of the 2026-09-21 doc's own "at least ten recommended moves executed by hand... with zero
  twin/regression incidents" bar): **compacting an idle seat** (no process kill, fully
  reversible — but only once the `COMPACT` trigger mechanism §5/§7 names as a real, unbuilt v1
  gap actually exists; v2 auto-compact is gated on that mechanism, not assumed already live) and
  **a timed move of a non-pinned, non-critical seat onto a fresh block boundary it was going to
  restart on anyway** (the 2026-09-21 doc's own "natural cycle point" lever, §3.5 there).
- **Always human/assistant approval:** anything touching the account that must never cap (§5's
  generalized R2), or moving a pinned seat. No version of this system auto-executes either.

Every increment ships through the existing tooling-repo process (this repo's own README/CLAUDE
convention, restated in the priority ask): commit goes live at once, code-review gates
correctness, assistant gates vision (the five checks named in the ask's own process mail), main
lands only after both. `docs/` naming and status-header convention (`Status: DESIGN` →
implementation replaces the header) matches every existing doc in this directory.

## 6a. Plan horizon and use-it-or-lose-it (item 7 — resolved into the design)

The cut above evaluates PREDICT/PLAN against the *current* block only. Assistant's example:
research sits at 85/99 weekly with 2.5 days to its reset tonight — the plan should be actively
draining load onto r2 once r2's own next block resets fresh, *before* research caps, not waiting
for research to actually arm hot. Concretely: §4's `predicted_pressure`/`stall_cost` already run
per-window (block + every weekly, including model-scoped); PLAN's search (§5) extends over the
next `AIMAIL_PLAN_HORIZON_H` (default 24h) of known reset boundaries for every account in the
pool (each account's own next block reset, its weekly reset, and every model-scoped weekly reset
it tracks — all already-known epochs, no new measurement), not only "now." A `HOLD` or `MOVE`'s
`not_before` (§5) is chosen from this same set of upcoming resets. **Use-it-or-lose-it** falls
out of the same per-window pressure directly: an account with real headroom whose weekly resets
soon (`sustainable(account, weekly)` large relative to remaining time) has *negative* slack the
plan should actively fill, ranked by `expiry_risk` — the exact quantity R3 (§5) already computes
for a model-scoped cap, generalized here from "one model on one account" to **every tracked
model-weekly on every account**, not only wherever `fable` happens to run. This is one search
extended over more of the same already-known data, not a second planning mechanism.

## 7. Open for the owner — resolved or still open

**Resolved by assistant's review (20260924T171439):**
- `critical_path` seats: config `AIMAIL_CRITICAL_PATH_SEATS`, default `main code-review` (§4).
- `cold_boot_cost`: principled today from `context_tokens × weight_cache_write` (§5), not a
  flat placeholder — no fitting needed before v1, the outcome log then checks it.
- `queue_factor`: keep it two-state-plus-active-rate for v1 (§3) — richer than a bare 0/1 gate,
  but not a continuous model; a later refinement is a v1-outcome-log question, not guessed now.
- `AIMAIL_CONTEXT_BASELINE`: per-model config (§3) — resolved, not a single global default.

**Still open, not guessed:**
- **The `COMPACT` action's own trigger mechanism (§5) is a named v1 dependency, not yet built.**
  Two candidates were found by direct grep of this repo (§5): delivering the compact instruction
  as an aimail message the seat's own next turn acts on, or writing that account's
  `autoCompactWindow` for one tick then restoring it. Neither is implemented; picking one (or
  proposing a third) is real design work still owed before v2 can rely on `COMPACT` at all — v1
  can ship without it (a plan simply never proposes `COMPACT` until the mechanism exists,
  `dispatcher_plan()` names this as a known gap rather than silently never firing it).
- **`AIMAIL_COMPACT_RATIO` (§5, default 0.3)** — the fraction of pre-compaction `context_tokens`
  assumed to remain after a real `/compact` — is a placeholder until the outcome log has real
  before/after pairs to fit it from, exactly like `cold_boot_cost` was before this revision.
- **`AIMAIL_PRECIOUS_MARGIN` (§5, default 0.8)** and **`AIMAIL_PLAN_HORIZON_H`** (§6a, default
  24h) are proposed defaults, not owner-confirmed numbers, same status as the 2026-09-21 doc's
  own thresholds (its own §7: "proposed defaults, all config, to be read against the first
  weekly cycle's streak file before anyone trusts them").
- **§1.6's two account-inventory gaps are real, verified, and already queued as their own fix
  — NOT deferred to whoever builds §2.** Assistant queued both to `foundation` tonight (mail
  `20260925T014759`, "Queue: budget pool hides seatless accounts; probe null five_hour should
  read 0%"), as a standalone `lib/budget.sh` change with tests, normal gate path, ahead of and
  independent of this design's own build. §2's MEASURE stage **depends on that fix landing
  first** — it reads `budget_pool`'s account enumeration and `budget_probe`'s `five_hour.
  utilization` as-is (§2 itself adds no new instrument here), so a §2 implementation started
  before `20260925T014759`'s fix lands would inherit both gaps unchanged. This is a landing-order
  dependency to track, not open design work.
