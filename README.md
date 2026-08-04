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

## Testing

```bash
bash tests/run.sh
```

35 tests. Every guard is exercised with an input that must trip it (①), paired
with a positive control on the nearest valid input so an always-refusing guard
cannot hide (③), and the suite has been mutation-tested — disabling any of three
guards turns it red, and it returns green when restored.

## Status

**Ported and tested:** registry, send, delivery state machine, ack, archive
sharding, `where`, poller, doctor, test harness.

**Not yet ported:** the gate slot (`gate_slot.sh`/`gate.sh`), `preland.sh`, the
stop-hook liveness guard, and the budget/throttle/ramp layer. See
[docs/PORTING.md](docs/PORTING.md) for what each needs and the defects each must
not reintroduce.
