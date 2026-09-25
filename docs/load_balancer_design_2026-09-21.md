# Proactive, gradual multi-account load balancing — design

Status: DESIGN, for review before build. Author: the design seat, 2026-09-21. Requested by the
fleet owner after a night in which seats were moved between accounts reactively (an account
parked, then a hand scramble) and one batch "proactive" move of three seats at once turned out to
be the wrong shape too. This document is generic: it names no real seat, account, project or
session. It extends `docs/hybrid_multi_account_budget_distribution_design_2026-09-20.md` (the
park-triggered allocation policy, §4c/§4d there) rather than replacing it, and it builds on
`aimail seat migrate` (`docs/cli_account_migration.md`) as the only way a seat is ever moved.

## 1. What exists today, measured (the design uses only this)

- **Account-level usage series, already a time series.** `budget_probe` runs inside the autopilot
  cron tick (every 5 min, once per account dir) and appends to `state/budget_ledger.tsv` three rows
  per account: session-block `%`, weekly `%` (with the weekly reset epoch), and the model-scoped
  weekly `%` for the premium model when the endpoint reports one. Measured today: ~290 rows per
  source per account per day, i.e. a reading every ~2–5 minutes. Nothing reads it as a series yet
  except `budget history`.
- **Live seat → account resolution.** `_autopilot_seat_groups()` (from each seat's own poller
  process environ) and, since today, the persisted seat record (`state/seat_account/<seat>`:
  account, session id, model) plus `aimail seat locate` (the CLI's own `claude agents --json`
  across the account pool, by session id).
- **Pool declaration.** `AIMAIL_FLEET_ACCOUNTS` (space-separated) with per-account caps
  `AIMAIL_CAP_<acct>` / `AIMAIL_WEEKLY_CAP_<acct>` and an optional `AIMAIL_ACCOUNT_DIR_<acct>`.
  Adding an account is a config edit, no code.
- **Allocation on park.** `budget_pick_account` (greedy max weekly headroom among non-parked,
  measured accounts) and `budget_recommend_migration` (one recommendation per park episode,
  mailed to the supervisor, now pointing at `aimail seat migrate`).
- **Per-session usage, on disk, not yet used.** `ccusage session --json` (the same tool
  `block_json` already relies on for the block boundary) reports, per Claude session id
  (`period`), cumulative `inputTokens`, `outputTokens`, `cacheCreationTokens`,
  `cacheReadTokens`, `totalCost`, and a `modelBreakdowns[]` list per model. It reads the
  transcripts under the config dir it is pointed at, so it is per account by construction.
  `ccusage blocks --json` (already cached as `state/block.<acct>.json`) gives the account's
  active 5-hour block totals — the reconciliation target.
- **Session id → seat.** Three sources, in order of authority: the seat record (the seat's own
  `aimail seat confirm`), the poller instance files (`state/instances/<seat>/<sid>`), the stop-guard
  registrations (`state/stopguard/session.<sid>` holds the seat name).
- **Seat activity state.** `claude agents --json` (`state`: working/blocked/stopped), the poller
  heartbeat (ARMED / RE-ARMING / PARKED), `gateclaim.sh --list` (a held claim = mid-work), and
  the recent-mail/recent-commit signals `aimail claims` already uses.

## 2. Ruling on the shape

1. **Recommend-only.** The balancer decides and reports; a human or the supervisor seat executes
   with `aimail seat migrate <seat> <account>` (which itself verifies, settles and re-verifies).
   Auto-execution is reserved behind a flag that defaults off and is not built in this
   increment; see §6 for the condition under which it would be.
2. **Trend, not snapshot.** Nothing is recommended from one probe. A recommendation needs a
   sustained gap across K consecutive evaluations, with hysteresis to clear.
3. **One seat at a time, narrow the gap, never flip it.** After any executed move the balancer
   is silent for a cooldown while the trend re-forms.
4. **Prefer the natural cycle point.** The gentlest lever is where a seat lands when it boots
   anyway (crash recovery, block-boundary restart, fresh launch). A placement marker per seat
   carries the recommendation to that moment; a mid-task force-migrate is recommended only when
   the trend has persisted much longer.
5. **One data source.** Everything derives from the ledger, `ccusage`, the seat record and the
   CLI listing that already exist. No parallel store of usage.
6. **N accounts.** The pool is whatever `AIMAIL_FLEET_ACCOUNTS` says; nothing below assumes two.

## 3. Design

### 3.1 Per-seat usage ledger (`state/seat_usage.tsv`) — the new measurement

A `budget seats-tick` step inside the autopilot tick, once per account dir (the tick already
iterates accounts with `CLAUDE_CONFIG_DIR` set):

1. Run `ccusage session --json` for that config dir (seam: `AIMAIL_CCUSAGE_SESSION_JSON` for
   tests, the same idea as the existing block stub).
2. For each session row: resolve `period` (a session id) to a seat via the seat record, else an
   instance file, else a stop-guard registration; unresolved rows go to the seat `_unattributed`.
3. Append one row per (session, model): `epoch, account, seat, sid, model, cum_input, cum_output,
   cum_cache_create, cum_cache_read, cum_cost`. Cumulative, never a delta: deltas are derived at
   read time from consecutive rows for the same (sid, model), which makes a missed tick harmless.
4. **Reconcile every tick:** Σ over seats of the block-window delta (all models) vs the account's
   active block totals from `block.<acct>.json`. Within `AIMAIL_SEAT_USAGE_TOLERANCE` (default
   15%) the tick is MEASURED; outside it (or when either side is missing) the tick is marked
   UNMEASURED in `state/seat_usage_status_<acct>` and the balancer treats per-seat costs for that
   account as unknown for that evaluation. Zero is never substituted.

Cost unit: **weighted tokens**, not dollars — the quota being balanced is a usage percentage,
and cache reads are billed far below input/output. Default weights: input 1.0, output 5.0, cache
creation 1.25, cache read 0.1 (ratios of the public per-token prices; overridable per model with
`AIMAIL_TOKEN_WEIGHTS_<model>` so a price change is a config edit). Dollars from `ccusage` are
recorded alongside for reporting only. The read-time derived quantities per seat: `cost_1h`,
`cost_3h`, `cost_block` (weighted tokens), `share_of_account` (fraction of the account's
block delta), and `model` (dominant model by cost).

### 3.2 Account pressure — one number per account, per window

From the ledger's weekly series for account a over a trailing window W (default 3 h, at least
6 readings, else UNMEASURED):

- `burn_w` = slope of weekly `%` per hour (least squares over the window; resets inside the
  window split it and only the post-reset segment counts).
- `sustainable_w` = (weekly_cap − weekly% now) / hours until the weekly reset.
- `pressure_w` = burn_w / sustainable_w. 1.0 means "on track to arrive at the cap exactly at
  the reset"; > 1 means headroom runs out early; < 1 means headroom is being left unused.

The same for the 5-hour session block (`pressure_s`, window 60 min, at least 6 readings) and,
where a model-scoped weekly reading exists, `pressure_m` for that model. The account pressure
used for balancing is `max(pressure_w, pressure_s)`; `pressure_m` is a constraint on seats
running that model (§3.4), not part of the account number. A parked account has pressure ∞.

### 3.3 Trend gate and hysteresis

Let `hot` be the account with the highest pressure and `cold` the lowest among measured,
non-parked accounts with at least one live seat or room for one.

- **Arm** when `pressure(hot) − pressure(cold) ≥ GAP_ON` (default 0.40) AND `pressure(hot) ≥
  1.10` for K consecutive evaluations (default K = 6 at the 5-minute cadence = 30 min).
- **Clear** when the gap has been `< GAP_OFF` (default 0.20) for K consecutive evaluations, or
  after an executed move (§3.5 cooldown).
- Missing readings do not count toward K in either direction; they reset nothing and extend
  nothing. A burst (a landing sprint, a census run) shorter than K evaluations never arms.

State lives in `state/balance/streak` (one line per evaluation: epoch, hot, cold, gap, armed)
so the decision is auditable after the fact and the tests can drive it row by row.

### 3.4 Candidate selection — the smallest move that narrows the gap, from the idlest seat

When armed, for each seat s on `hot`:

1. **Eligibility:** not the supervisor seat; not holding a gateclaim; seat record present (so
   the target relaunch has a model); its model's scoped weekly on `cold` is not worse than on
   `hot`; `cold` is not parked and has weekly headroom > 0 after the move.
2. **Effect:** projected `pressure(hot)′` and `pressure(cold)′` after moving s, using the seat's
   `cost_3h` as its burn contribution. Keep only moves with `pressure(hot)′ ≥ pressure(cold)′`
   (narrow, never flip) and `pressure(hot)′ − pressure(cold)′ < gap`.
3. **Rank:** activity first, then size. Activity score from the listing and the poller: idle
   (ARMED, `state` not working for > 10 min, no claim, no mail sent in 15 min) = 0; between
   tasks (working but no claim, no commit in 30 min) = 1; mid-task (claim held, or a commit /
   handoff mail in the last 30 min) = 3; PARKED/unreachable = not a candidate (nothing to
   move cleanly). Among equal activity, prefer the smallest `cost_3h` that still satisfies 2.
4. Exactly one recommendation. If no seat satisfies 1–2, the recommendation is "none — the gap
   cannot be narrowed by a single seat" with the reason per seat, which is itself a useful
   report (e.g. every seat on the hot account is one heavy seat).

### 3.5 Where the recommendation goes — placement first, force-migrate later

- **Placement marker** `state/seat_placement/<seat>`: target account, reason, the evaluation
  epoch, and an expiry (default 6 h). Written when armed. Consumed by: `aimail seat migrate`
  (it prints "placement marker says <acct>" and refuses a different target unless `--force`),
  `aimail resume`/boot guidance (`aimail session` shows it), and the relaunch step of any
  crash-recovery or block-boundary restart the supervisor performs. Most moves should happen
  here, at a moment the seat is restarting anyway.
- **Force-migrate recommendation** only when the arm has persisted for `FORCE_AFTER` (default
  2 h) with no natural cycle having consumed the marker: mail the supervisor ONCE per episode
  (episode = one armed streak; same dedup shape as `budget_recommend_migration`'s marker) with
  the exact `aimail seat migrate <seat> <acct> --from <supervisor>` line, the pressures, the
  seat's cost share, and its activity score. Never mail the seat itself.
- **Cooldown:** after any move the balancer observes for `COOLDOWN` (default 60 min) before it
  can arm again; the trend must re-form on post-move data.

### 3.6 Autonomous target distribution — advisory, one move at a time

`budget balance --plan` computes an ideal assignment by water-filling: seats sorted by `cost_3h`
descending; each assigned to the account whose projected pressure after taking it is lowest,
subject to §3.4's constraints. The plan is a report (which seats would live where, projected
pressures) and its diff against the live placement is the ordered list of moves. The balancer
still recommends only the first move; the plan exists so the owner can see the destination
and judge the trend, and so a full re-placement after a reset (when every seat restarts anyway)
can be done from one printed list.

### 3.7 Surface

- `aimail budget balance` — per account: weekly% / cap / reset, `pressure_w`, `pressure_s`,
  trend arrow over W, seats with `cost_3h`, share and activity; then the streak state and the
  current recommendation (or why none). `--plan` adds §3.6. `--json` for the dashboard.
- `aimail budget seats [--window 3h]` — the per-seat table alone, with the reconciliation
  verdict for each account.
- Autopilot tick appends the `seats-tick` and `balance` steps after the existing park/ramp
  logic; both are read-only apart from their own state files and the once-per-episode mail.
- `aimail session <seat>` prints the seat's placement marker when one exists.

### 3.8 Tests (hermetic, the harness's five rules)

Synthetic ledger rows and a stubbed `ccusage session` JSON per account dir; synthetic seat
records and instance files; a stubbed listing. Arms, each with its refusing and accepting
control: (a) a burst shorter than K never arms; a sustained gap arms at exactly K; (b) hysteresis
clears only below GAP_OFF for K; (c) one recommendation per episode, cooldown after a move;
(d) the smallest sufficient seat is chosen over a larger one; an idle seat over a mid-task one
of equal size; a supervisor seat and a claim-holder are never chosen; (e) a move that would
flip the gap is refused; (f) reconciliation outside tolerance → UNMEASURED, no recommendation
that evaluation; (g) three accounts, one parked: the parked one is never a target and its
seats are candidates; (h) placement marker written, honored by `seat migrate`, expired after
6 h; (i) the plan's water-filling on a fixed fixture reproduces a hand-computed assignment.

## 4. Expected effect, stated as what to measure after

- Recommendations per day and how many were executed (marker consumed vs force mail sent).
- Time from arm to move, and whether the move happened at a natural cycle point.
- Pressure spread across the pool at each weekly reset (the goal: every account arrives near
  its cap near its reset; today one account exhausts while another idles).
- Reconciliation pass rate of the per-seat ledger (the credibility of `cost_3h`).
- Zero twin incidents from balancer-driven moves (each goes through `seat migrate`).

## 5. Order and owners

1. §3.1 per-seat ledger + reconciliation + `budget seats` (measurement first; nothing else is
   trustworthy without it). Own tests.
2. §3.2–3.3 pressure + streak + `budget balance` read-only view (no marker, no mail yet):
   run for at least one full weekly cycle and read the streak file against what the fleet
   actually experienced before any recommendation is emitted. Own tests.
3. §3.4–3.5 candidate selection, placement marker, `seat migrate` honoring it, force mail.
4. §3.6 `--plan`.
   Builders assigned by the supervisor; the design seat rules and peer-reviews landed commits.

## 6. Not adopted, and when it would be

- **Auto-execution** (`AIMAIL_BALANCE_AUTO=1`): not built. Condition to revisit: at least ten
  recommended moves executed by hand through `seat migrate` with zero twin/regression
  incidents and the streak file showing the recommendations were right in hindsight.
- **Equalizing pressures** across accounts: not a goal; narrowing a sustained gap is. Equal
  pressure is neither necessary nor measurable in the presence of different reset times.
- **Snapshot triggers**, dollar-based cost, a second usage store: excluded by §2.
- **Moving a mid-task seat before FORCE_AFTER**: excluded; the placement marker is the lever.

## 7. Open for the owner (not guessed)

- Thresholds `GAP_ON` 0.40 / `GAP_OFF` 0.20 / `K` 6 / `FORCE_AFTER` 2 h / `COOLDOWN` 60 min /
  tolerance 15% / window 3 h — proposed defaults, all config, to be read against the first
  weekly cycle's streak file (§5 step 2) before anyone trusts them.
- Whether the model-scoped weekly ceiling should also drive placement of the seat that runs
  that model on its own (a seat whose model has its own quota is the one case where an
  account with headroom may still be the wrong target); §3.4 treats it as a constraint only.
- Whether cache-read weight 0.1 undercounts: it is the price ratio, but the quota endpoint's
  own accounting is unpublished; §3.1's reconciliation is what will show the error.
