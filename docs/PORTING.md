# Porting status — defect by defect

`aimail` is a rewrite of a file-based mail bus that coordinated a five-seat AI
fleet for five weeks. This document maps each defect that system accumulated to
its status here: prevented by construction, partially addressed, or not yet
ported.

The `RC-N` (root cause) and `FI-NN` (defect) ids come from that system's own
defect register, which is not published — it is operational detail about a
private project. **Every mechanism worth knowing is restated here in full**, so
nothing below depends on reading it.

⚠ **The predecessor is still live and still running a fleet. Nothing in this repo
modifies it.** This is a parallel build; migration is a separate, later decision.

---

## Root causes

| | Cause | Status here |
|---|---|---|
| RC-1 | Every instrument gitignored, so no claim about one can be dated | ✅ **Fixed by construction.** Code is versioned; data lives in `AIMAIL_ROOT` outside the repo, and `doctor` fails if it is not. `instrument_id()` stamps sha + dirty flag into consequential output. |
| RC-2 | Absence indistinguishable from completion | 🟡 **Partial.** The delivery machine leaves an artifact at every step (`unacked/` is a *state*, not an inference). The gate's verdict artifact is not ported yet. |
| RC-3 | A shared mutable file has no announcement channel | 🟡 **Partial.** `instrument_id()` makes a silent edit visible at the point of use. A change-announcement hook is not built. |
| RC-4 | Instruments report a plausible number instead of refusing | ✅ **Fixed by construction.** Four output states with distinct exit codes; `unmeasurable()` exits 4 and cannot render as 0. |
| RC-5 | Exit codes die in pipes | ✅ **Fixed in this codebase.** No measurement is piped internally; the test harness captures `$?` directly and never through a pipeline. |

---

## Ported

| Id | Defect | How it is structurally prevented |
|---|---|---|
| FI-01 | Poller prints and archives in one step ⇒ unread output = mail lost | `archive/` is unreachable by delivery. Only `ack` moves mail there; un-acked mail re-prints on every poll. **This also closes MAIL_SYSTEM §4.4** — a detached poller can no longer consume mail, because it cannot ack. |
| FI-05 | Counting files cannot detect delivery | `aimail where` reports the *state* (inbox / un-acked / archived) and exits 4 — not 0 — when nothing matches. |
| FI-06 | Delivery check counted files, passed on gutted mail | Body digest is written into the header and re-verified after write; a mismatch deletes the delivered copy and fails loudly. |
| FI-07 | Fabricated timestamps propagated across seats | `--date` is refused. The tool stamps from `date(1)`; there is no path for a remembered time to enter the record. |
| FI-16 | `gate.sh who` takes the slot instead of reading | Verbs are a closed table in `bin/aimail`; an unrecognised word is refused, never used as data. |
| FI-25 | Unquoted heredocs for mail | There is no `--body` string argument. Bodies come from a file or stdin, so the shell never sees them. Unbalanced-fence detection catches bodies corrupted before they arrive. |
| — | Duplicate-inbox black hole (`metrics` vs `metrics-report`) | The registry is the address space. Unregistered ⇒ refused, with substring and edit-distance-2 suggestions. Aliases resolve but are announced on stderr every time. |
| — | `cc:` delivers nothing (§2.4) | The tool fans out: N recipients ⇒ N files. |
| — | Second person in a broadcast (§2.4b) | Refused unless `--broadcast-second-person-ok`. |
| — | Flat archive of 13,327 files | Sharded `archive/YYYY-MM/`. |
| — | Zero-byte shell-accident files in the address space | Seat names validated `^[a-z][a-z0-9-]{1,31}$` on the way in. |

---

## Not yet ported — and what each must not reintroduce

### Gate slot (`gate_slot.sh`, `gate.sh`)
- **FI-17** — a SIGKILLed holder leaks the lock forever. Port with **pid + start
  time in the lock**, and reclaim only when that pid is gone.
  ⛔ Must be decoyed **both** ways before it is trusted: prove `take` reclaims
  after `kill -9`, *and* prove it refuses to reclaim a live holder's lock. A
  reclaim that cannot tell those apart is worse than the gap it replaces.
  ⚠ `_gate_slot.lock` is a **directory** — `cat` returns "Is a directory", which
  is not an emptiness reading. An empty lock is not an empty slot.
- **FI-18** — a pipe destroys the verdict. Emit a machine-checkable token on
  **every** exit path including refusals; until 2026-08-04 only the *completed*
  path printed one, so the only states invisible to a piping caller were the
  states where nothing ran.
- **FI-19** — editing a running script corrupts it. Already solved for the
  poller (`_poller_reexec_private`); apply the same pattern to the gate.

### Liveness (`poller_guard.sh` stop hook, `fleet_idle.sh`)
- **FI-03 / FI-04** — `pgrep` self-matches, counts a healthy poller as 2, and
  cannot distinguish tracked from detached without reading the PPID. And a
  poller being down means *both* "mid-turn, working" and "dead".
  ⇒ Port `fleet_idle.sh` (reads stop-hook events) as the **only** sanctioned
  activity answer, and ship one `poller_state` returning
  `ARMED-TRACKED | ARMED-DETACHED | DOWN` with the pids it used.
  ⛔ **Do not port `fleet_idle.sh`'s closing advice verbatim.** Lines 64–67 of
  the original still tell the reader that under a freeze a seat *should* disarm.
  `MAIL_SYSTEM.md` §4.3 retracted exactly that on 2026-08-04 after it cost the
  fleet 3h24m — but the tool was never updated, so it prints the retracted rule
  at the moment of decision. **A parked poller wakes itself; a disarmed one never
  does.** They are identical on a token bill and opposite in recoverability.
- **FI-02** — the poller exits on delivery, so liveness is a timestamp not a
  state. Unchanged here and inherent to the harness-wake design.

### Budget / throttle / ramp
- **FI-10** — `IFS=$'\t' read` collapses consecutive tabs, so a ledger row with
  empty middle fields silently shifts every later field left. This blinded the
  cold-start guard and would have re-throttled the fleet on a fabricated
  183%/hour rate. `core.sh` already forbids the pattern (`tsv_last_field` uses
  `awk -F'\t'`). **The remaining call sites in the old system —
  `token_watch.py`, `burn.py`, `night_watchdog.sh`, `poller.sh`, `preflight.sh` —
  are unaudited and are the highest risk-to-effort item on the board.**
- **FI-13** — one threshold governed every account, but a *shared* account must
  park lower; overrunning there takes tokens from someone not in the
  conversation. `etc/aimail.conf.example` already has per-account caps
  (`AIMAIL_CAP_<account>`); the consumer is not written yet.
  ⇒ Account identity is available: the profile switcher repoints the `~/.claude`
  symlink, so `readlink -f ~/.claude` names the active account. That is also why
  transcript-derived numbers are automatically per-account — each profile has its
  own `projects/` tree.
- **FI-11** — a projection printed without its anchor's age read as live when the
  anchor was a day old. Never print a projection without the anchor age, and
  refuse to project across a window boundary. ⚠ **A window closing is a RESET,
  not a budget being spent.**
- **FI-14** — only a human `/usage` callout is ground truth for the *level*.
  Confirmed still true: [issue #20636](https://github.com/anthropics/claude-code/issues/20636)
  asked to expose rate-limit usage programmatically and was closed unimplemented.
  It is not available via statusLine, hooks, files, API or env.
  ⇒ Keep the callout ledger as the authoritative channel; structurally
  distinguish MEASURED from DERIVED in every output.
- **The window model.** `token_watch.py` measures a **trailing** 5h window;
  Anthropic uses an **anchored block** (starts at first message, runs 5h). Right
  after a reset the trailing window still reaches into the dead block — it read
  90% against an official 30%. ⛔ **Do not fix this by rescaling the budget**;
  over-reading at a boundary is structural and scaling makes it under-report for
  the rest of the window. ⇒ Replace with `ccusage blocks --json`, which models
  anchored blocks natively.
- **The ramp is on hardcoded wall-clock cron** (01:55, 06:55) and never consults
  the ledger or the window end, while the real block is anchored to first message
  and drifts daily. ⇒ Ramp on the block, not the clock.
- ⭐ **Decouple the ROLE.md checkpoint from the percentage.** "Write your ROLE.md
  near window end" is currently gated on the least reliable component and fires
  at the worst moment. The *block end* is known hours ahead and does not need the
  percentage at all. Checkpoint at block-end-minus-N. This is the single biggest
  robustness win available.

### Shell hazards to keep out (FI-20…FI-24)
```
⛔ never `… | grep -q` with pipefail — grep -q SIGPIPEs upstream; 60/60 deterministic
   failure measured with >64KB input. Use process substitution or -Fxc.
⛔ never `cmd | tail || fallback` — the status is tail's, so the fallback never runs.
⛔ never `[ test ] && … && cmd` — a false test short-circuits the command too.
⛔ `find -newermt` returned 0 for in-range files on this box (117 by ls). Verify before use.
⛔ `grep` is ugrep interactively and GNU grep 3.11 in a script — same word, two programs.
```

---

## Regressions not to introduce

```
⛔ Do NOT pgrep pollers to decide who is working. It is a liveness sample, never an idle signal.
⛔ Do NOT print 0 when you cannot measure. Zero reads as safe in whichever direction is dangerous.
⛔ Do NOT gate an edit on a predicate that can never clear (pollers run permanently).
⛔ Do NOT rescale the budget window to fix a boundary over-read.
⛔ Do NOT use a cold/session-start anchor as a rate endpoint — 25% in the first 30
   minutes is a cold-cache artifact, not a rate.
```
