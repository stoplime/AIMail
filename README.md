# aimail

File-based mail for a fleet of AI coding sessions that cannot see each other's context.

It is a port of a system that ran a five-seat fleet for five weeks and carried
13,327 messages. **This repo exists because that system was gitignored**, so no
claim about any of its instruments could be dated, and roughly one message in
eleven was about the coordination system rather than the work.

---

## The five-minute version

```bash
git clone <this repo> && cd aimail
cp etc/aimail.conf.example etc/aimail.conf     # edit AIMAIL_ROOT
export PATH="$PWD/bin:$PATH"

aimail seat add main "General work"
aimail seat add backend "Backend work" "be"

aimail send --to backend --from main --subject "gate is free" --body-file ./msg.md
aimail poll backend        # arm in a BACKGROUND task; it exits when mail lands
aimail ack backend --all   # after acting on it
```

Run `aimail doctor` after install. It checks the six things that have actually
gone wrong.

---

## What it refuses to do, and why

Every refusal below replaces an incident. The tool enforces these rather than
documenting them, because **a rule in a document loses to recall at the moment
of use** — four seats broke the same documented rule within one hour of it being
written down.

| Refusal | The incident behind it |
|---|---|
| Sending to an unregistered name | A directory named `metrics` existed beside the real seat `metrics-report`. No poller watched it. Mail there was never read and never bounced. |
| `--body "some string"` | A mail composed with an unquoted heredoc had every fenced code block eaten by shell expansion. The headings survived, so it read as *asserted without evidence* rather than as *damaged* — and the sender's delivery check reported 5/5 because it counted files. |
| An unbalanced ``` fence | The detection signature of the above, caught before delivery. |
| `--date` / caller-supplied timestamps | Every `HH:MM` in one seat's record was ~7.5h fast. A second seat then advanced its clock *from those headers*, so the drift grew between seats. |
| Second-person pronouns in a broadcast | A correction sent to five seats saying "Your claim…" was resolved by the wrong seat, which then had to prove it never made the claim. |
| Missing `--from` | 118 of 122 messages once omitted it, so "what did this seat send?" returned **zero** while the seat had sent 122. |
| Unknown verbs and flags | `gate.sh who` — which reads exactly like a status query — created a lock holder named `who` and started a full test suite. |

## The delivery state machine

```
  send              poll                   ack
────────>  inbox  ───────>  unacked/  ───────>  archive/YYYY-MM/
             ▲                  │
             └──────────────────┘
              re-printed every poll until acked
```

**`archive/` is not reachable by delivery.** The predecessor's poller printed a
message and archived it in one step, so if the agent never opened that task
output the mail was archived unread with no trace. It happened to a stop-work
notice, and the seat kept building cancelled scope for fifteen minutes.

Here, delivery moves mail to `unacked/` and only `aimail ack` archives it.
Un-acked mail is re-printed on every subsequent poll. A delivery nobody read is
now self-healing instead of silent — which also closes the detached-poller gap,
since a poller nobody is waiting on cannot ack.

## The four output states

Every instrument reports exactly one, with distinct exit codes:

| State | Exit | Meaning |
|---|---|---|
| measured | 0 | a real reading |
| refused | 3 | you asked for something the tool will not do |
| unmeasurable | 4 | it could not measure — **not** zero, **not** clean |
| error | 1 | it broke |

`unmeasurable` exists because the recurring failure was never a crash, it was *a
plausible number*: a 384% projection, a 0.00%/hour burn rate read as "fleet idle,
poke it", a census printing "0 of 0" as an all-clear. **"Unmeasurable" and "zero"
are different claims, and zero reads as safe in whichever direction is dangerous.**

## The fleet dashboard

```
aimail fleet
```

```
SEAT             POLLER      LAST-STOP  QUEUED  UNACK  VERDICT
main             RE-ARMING   2m              0      1  WORKING — mid-turn, reading mail. ⛔ DO NOT NUDGE
review           ARMED       14m             2      0  IDLE & REACHABLE — mail will wake it, send work
backend          CRASHED     51m             0      3  ⛔ UNREACHABLE — killed, not finished. Only a human can restart it
```

**The distinction this exists for:** a poller is down both when a seat is
mid-turn reading its mail and when it was killed. Those demand opposite
responses, and a process sample cannot tell them apart — which produced both
failure directions repeatedly: redundant nudges, and a seat sitting unreachable
for ~25 minutes.

Two event sources, neither of which is a `pgrep`:

- **The poller's heartbeat records why it stopped.** An exit that says
  `reason=mail` is a poller that did its job. An absent heartbeat with *no exit
  record* is a poller that was killed. Finished, killed and crashed otherwise
  leave identical evidence — no process — so the finishing path has to write
  something the other two cannot.
- **The stop hook logs the moment a session ends a turn**, which is what "idle"
  actually means. A process sample can never answer "when did this last stop".

Six states where a process count had two: `ARMED`, `RE-ARMING`, `STALLED`,
`WEDGED`, `CRASHED`, `NEVER`. `AIMAIL_REARM_GRACE` (default 180s) names the
window in which a fired poller is still expected to re-arm — reporting that
window as "down" is the most common false alarm in fleet supervision.

## Migrating an existing mailbox

```bash
aimail migrate /path/to/old/mailbox --dry-run   # always first
aimail migrate /path/to/old/mailbox
```

Copies — never moves. The source stays intact and running, the import is
idempotent and resumable, archives are re-sharded by each message's **write**
mtime so the chronology survives, and `ROLE.md` moves out of the inbox to
`$AIMAIL_ROOT/roles/` so it can never be delivered as mail.

## Testing

```bash
bash tests/run.sh                    # 81 tests
bash hooks/stop_guard.sh selftest    # 5 arms, also run by the suite
```

Every guard is exercised with an input that must trip it (①), paired with a
positive control on the nearest valid input so an always-refusing guard cannot
hide (③).

Mutation-verified: disabling the fence guard, the ack gate, the broadcast-pronoun
guard, the crashed/re-arming distinction, the exit-record branch, the
archive-traversal fix, the checkpoint marker ordering, or the poller's park
behaviour each turns the suite red, and it returns green when restored.

⚠ One of those mutations initially reported a false all-clear, because the `sed`
meant to apply it silently did not match. **A decoy that cannot apply its patch
proves nothing** — assert the patch landed before drawing any conclusion from the
result. The same shape appeared in the stop-hook selftest, where two "allow" arms
passed while the guard was switched off entirely.

## Budget, checkpoint, and unattended overnight running

```bash
aimail budget status          # the block, the last callout AND ITS AGE, the schedule
aimail budget callout 42      # record a /usage reading — the only true level
```

**The one idea this is built around: the block boundary is measurable, the
percentage is not.** Everything that must work unattended is keyed on the
boundary; only advisory output is keyed on the percentage.

`/usage` shows the official session and weekly percentages and is **not
programmatically accessible** — not via statusLine, hooks, files, an API, or an
environment variable ([issue #20636](https://github.com/anthropics/claude-code/issues/20636),
closed unimplemented). So a human reading `/usage` aloud is the only source of a
true level. `budget callout` is first-class, not a fallback.

The *boundary*, though, is knowable: a block starts at your first message and
runs exactly 5 hours, and `ccusage` models that as an anchored block. So the
checkpoint — *"write your ROLE.md while there is still budget to write it"* —
fires on the clock, hours of warning, no percentage involved. When an account is
switched every session's context switches with it, so those ROLE.md files **are**
the handover.

⛔ **Do not "fix" a boundary over-read by rescaling a budget.** A *trailing* 5h
window over-reads right after a reset by construction — it still reaches into the
dead block. Rescaling to correct that makes it under-report for the rest of the
window, inventing headroom. Anchored blocks avoid the artefact entirely.

### Cron — because a session's children die with the session

```cron
*/5 * * * * /path/to/aimail/bin/aimail budget autopilot >> ~/.aimail/state/autopilot.log 2>&1
```

`autopilot` ramps if the block rolled, checkpoints at `AIMAIL_CHECKPOINT_MIN`
before the end, and parks at `AIMAIL_PARK_MIN`. It belongs in cron because a
`run_in_background` task is a *child of the session* — it dies exactly when the
session dies, which is the scenario night mode exists to survive.

### Park is not disarm

Setting the throttle flag makes every poller **sleep on it and wake itself at the
ramp**. Verified end to end in the suite: a parked poller stays alive, mail sent
during the park stays queued rather than being consumed, and the poller exits on
its own when the ramp passes — no human, no coordinator.

A parked poller costs nothing and wakes itself. A **disarmed** poller also costs
nothing and *never wakes* — only a human can restart it. Identical on a token
bill, opposite in recoverability. Never tell a seat to disarm.

### Per-account caps

```bash
AIMAIL_CAP_DEFAULT=90
AIMAIL_CAP_shared=80     # a shared account must park lower
```

The account is read from the `~/.claude` symlink target, which is what the VS
Code profile switcher repoints. That also means each account has its own
transcripts, so anything derived from them is already per-account. Overrunning on
a shared account spends someone else's tokens, and they are not in the
conversation to object — nobody should learn which account they are on from a
lockout.

## Status

Measured against the toolset it replaces:

| Predecessor tool | Status |
|---|---|
| `poller.sh` + 7 per-seat wrappers | ✅ one `aimail poll <seat>`, plus the ack gate and heartbeat |
| `poller_health.sh`, `poller_fleet_sweep.sh` | ✅ subsumed by `aimail fleet` |
| `fleet_idle.sh` | ✅ the `LAST-STOP` column |
| stop hook | ✅ `hooks/stop_guard.sh`, 5-arm selftest |
| `staleness_check.sh` | 🟡 partial — `status` shows un-acked counts, no age alarm |
| `fleet_watch.sh` (progress watchdog) | ❌ not ported |
| `fleet_dashboard.sh` (HTML page) | ❌ not ported — terminal only |
| `gate.sh`, `gate_slot.sh`, `preland.sh`, `preflight.sh`, `verify_refs.sh` | ❌ not ported |
| `budget.sh`, `token_watch.py`, `burn.py`, `night_gate.sh`, `night_watchdog.sh` | ✅ replaced by `aimail budget` on anchored `ccusage` blocks |

⚠ Still missing for a full cutover: the **gate** (suite serialisation) and
`preland` (the uncommitted-worktree collision check). Those protect a shared test
suite and a shared trunk; nothing here replaces them yet.

[docs/PORTING.md](docs/PORTING.md) maps every known defect to prevented, partial,
or not-yet-ported, and lists the regressions not to reintroduce.
