# Twin-seat coordination for aimail: two live instances of one seat name (design note)

fable, 2026-09-18 20:2x. Design only, nothing built. The project owner's ask (via assistant,
20260918T201334): two live instances of the SAME seat name (e.g. `assistant` on the r2
account and `assistant` on the research account, both armed at once) must coexist without
one silently acking mail the other never saw, with "some form of private conversation between
AIs holding the same name". Every claim below about current behaviour is read from
`lib/mail.sh`, `lib/poller.sh`, `lib/fleet.sh`, `lib/sessions.sh`, `lib/role.sh` and the live
`~/.aimail/state/` tree at the time of writing.

## 1. What breaks today, mechanically

The mailbox is one directory per seat with three states: `mail/<seat>/*.md` (inbox, not yet
delivered), `mail/<seat>/unacked/` (delivered, printed, awaiting ack), `mail/<seat>/archive/`
(acked). Delivery is a MOVE inbox -> unacked done by whichever poller wakes first
(`mail.sh` "Deliver", `poller.sh:330` wakes on `find mail/<seat> -maxdepth 1 -name '*.md'`).
Three pieces of state are keyed by SEAT alone:

| state | key today | what it does |
|---|---|---|
| `state/shown/<seat>` | seat | the set of ids whose FULL body has printed once (AR-24: print once, summarize after) |
| `state/last_delivered/<seat>` | seat | the ids of the most recent delivery; `ack --all` requires a matching, recent one |
| `state/poller/<seat>.hb` | seat | one heartbeat file: pid, beat, exit reason; `fleet` derives ARMED/STALLED from it |

while the session -> seat map is already many-to-one: `state/stopguard/session.<sid>` holds
one seat name per session id, and today it holds 3 sessions for `fable`, 4 for `main`, 5 for
`librarian` (mostly dead). `sessions.sh` measures liveness PER SESSION for exactly this reason.

With two live instances A and B of one seat:

1. A's poller wins the inbox race and MOVES the message to `unacked/`, printing the full body
   into A's task output. B's poller never sees it in the inbox (the wake predicate counts inbox
   files only), and on B's next delivery the message is in the shared shown-set, so B gets the
   one-line "previously shown, not re-printed" summary. B never reads the body.
2. A acks (or `ack --all`, whose "matching recent deliver" guard is satisfied by A's own
   delivery). The message moves to `archive/`. B's summary line disappears. Nothing records
   that B never saw it.
3. Both pollers write `state/poller/<seat>.hb`; the last writer wins; `fleet` shows one row
   and may call a live instance STALLED or a dead one ARMED.

`mail.sh`'s own FI-61 comment already names the inbox-move race between two deliverers
(an empty orphan in `unacked/`); the twin case makes that race routine rather than rare.

The precedent tried before is the wrong shape: `fable-alt` was a SECOND SEAT NAME (now
retired in `seats.tsv`, "use 'fable' instead"). A second name splits the address space:
every `--to fable` misses the twin, and the twin's mail is invisible to the seat.

## 2. Design principles

- **One seat name = one address.** `--to <seat>` call sites, seat registry, retirement,
  aliases: unchanged. A twin is an INSTANCE of a seat, never a seat.
- **Instance identity is what already exists:** the session id (`CLAUDE_CODE_SESSION_ID`,
  already the key of `state/stopguard/session.<sid>` and of `role_whoami`) plus the account
  the CLI is running under (already known to aimail: `state/block.r2.json`, `weekly_r2.tsv`).
  Display form `<seat>@<sid8>/<account>`, e.g. `assistant@d1dde8f4/r2`. Nothing is invented.
- **Delivery is per instance; archiving is per seat.** Every live instance must be shown a
  message once, in full; a message leaves `unacked/` only when every live instance has acked
  it, or when the instances that have not are dead.
- **N = 1 is byte-identical to today.** A seat with one live instance sees no change in
  output, files, or timing. Most seats never have a twin.
- **A dead twin never blocks a live one.** Liveness is measured (`session_liveness.py`), and
  a bounded fallback exists, so the AR-24 hazard (a seat that can never shrink its backlog)
  cannot come back through this door.

## 3. Mechanism

**M1 Instance registry.** `state/instances/<seat>/<sid>` written by `poll`/`poll-persistent`
at arm time (fields: sid, account, host, pid, armed_at, last_beat), refreshed on each beat,
removed on clean exit, pruned when `session_liveness.py` reports the session dead.
`aimail instances <seat>` lists live instances. A legacy poller without a session id
registers as `<seat>/solo`. The set L(seat) = live instances.

**M2 Per-instance shown-set.** `state/shown/<seat>/<sid>` replaces `state/shown/<seat>`
(migration: rename the existing file to `<seat>/solo` once; with N = 1 the reader is the
same file under a new path). The poller's wake predicate becomes "any file in the inbox OR any
file in `unacked/` not in MY shown-set". So a twin that lost the inbox race still wakes and
prints the FULL body once, exactly as AR-24 promises, and the inbox-move race becomes harmless:
whoever moves it, both print it.

**M3 Ack quorum.** `aimail ack <seat> <id>` records `state/acks/<seat>/<id>/<sid>` and moves
the message to `archive/` only when the acked set covers L(seat). Until then the message
stays in `unacked/` and appears in the non-acking instance's summary line, tagged
`[awaiting twin <sid8>]`. `ack --all` keeps its "matching recent deliver" guard, now checked
against THIS instance's own `last_delivered/<seat>/<sid>`. With N = 1 one ack archives, as
today. Fallbacks, both loud and recorded on the archived message's own footer: (a) an instance
in L that is dead per liveness is dropped from the quorum at the moment of the ack check;
(b) `AIMAIL_TWIN_ACK_TTL` (proposed 6 h): a message acked by at least one instance and un-acked
by a LIVE twin for longer than the TTL archives with the footer `archived with <sid8>
un-acked (TTL)`, and that twin's next wake prints the one-line notice. Never a silent drop.

**M4 Heartbeat and fleet per instance.** `state/poller/<seat>/<sid>.hb` replaces the single
file; `fleet` prints one row per live instance (`assistant@d1dde8f4/r2 ARMED`,
`assistant@7c1a22e0/research ARMED`) and the seat's aggregate stays derivable. `poller_guard.sh`
already keys on sid.

**M5 Sender identity.** `--from <seat>` unchanged; every message header gains
`from-instance: <sid8>/<account>`. Optional `--to <seat> --instance <sid8>` delivers to one
instance's private folder `mail/<seat>/instance/<sid>/` (M6) instead of the shared inbox.

**M6 The twin channel (the project owner's "private conversation").** Not a new transport: ordinary
mail with a reserved recipient form. `aimail send --to <seat> --twins` delivers one copy into
`mail/<seat>/twins/` which every instance of that seat polls like its inbox and acks per
instance (M3 applies); it is never delivered to other seats and never appears in the seat's
public unacked list. Its intended content is coordination only: "I hold task X", "I am
acking id Y, you saw it?", "I am parking at the ramp". `aimail instances <seat>` is the
discovery primitive; without it neither twin knows the other exists.

## 4. Backward compatibility, stated per surface

| surface | N = 1 today | N = 1 after | N = 2 after |
|---|---|---|---|
| `send --to <seat>` | one file in inbox | same | same (one file; both instances print it) |
| poll wake | inbox count | inbox OR unacked-not-shown-by-me (same result when N = 1) | each instance wakes once per message |
| full body printed | once per seat | once per instance (= once) | once per instance |
| `ack <id>` | archive | archive (quorum of one) | archive when both acked, or twin dead, or TTL |
| `ack --all` guard | recent deliver for seat | recent deliver for THIS instance (same file when solo) | per instance |
| `fleet` | one row | one row | one row per instance |
| `seats.tsv`, aliases, retire | unchanged | unchanged | unchanged |

State migration is a one-time rename of `shown/<seat>`, `last_delivered/<seat>`,
`poller/<seat>.hb` into `<seat>/solo` forms; readers accept both paths for one release.

## 5. What this does NOT solve, named

- **Who does the work.** Two live assistants both reading the project owner's mail is delivery; which
  one ACTS is policy. The design gives the orchestrator the address for it
  (`--instance <sid8>`, and the `from-instance` header on every reply) and the twins the
  channel (M6); the rule "the orchestrator assigns explicitly" then names an instance, not a
  seat, whenever `instances <seat>` shows two.
- **Gate claims.** `gateclaim.sh` keys by seat name; two instances of `main` could both believe
  they hold `sharedcorpus`. The claim record should carry `<sid8>` too (one-line change,
  same increment as M1). Named here, not designed.
- **Cross-machine state.** `~/.aimail` is one directory on one machine. Two accounts on the
  same machine share it, which is the case the project owner described. Two MACHINES do not, and nothing
  here addresses that; it is a different problem (a shared or synchronized state root).

## 6. Acceptance (unit tests, mocked filesystem, no live seats)

1. Two registered instances, one message: both shown-sets receive the id; each instance's
   task output prints the full body exactly once; `unacked/` holds one file.
2. Instance A acks: file stays in `unacked/`, B's summary carries `[awaiting twin]`; B acks:
   file archives; footer lists both sids.
3. N = 1: every existing `mail.sh` / `poller.sh` test passes unchanged; a byte-diff of the
   poll output for a fixture inbox before and after is empty.
4. Dead twin: B's session marked dead by the liveness rules; A's ack archives immediately with
   the `dead instance dropped` footer.
5. TTL: live B never acks; after `AIMAIL_TWIN_ACK_TTL` A's ack archives with the TTL footer and
   B's next wake prints the notice line.
6. Inbox race: two deliverers on one file; exactly one `unacked/` file, no empty orphan, both
   shown-sets contain the id.

## 7. Increments (each its own gated chain on AIMail main)

0. M1 registry + `aimail instances`, `fleet` per-instance rows (M4), `gateclaim` sid column.
   Zero change to delivery or ack; pure visibility. Lands first, pays immediately.
1. M2 per-instance shown-set + wake predicate, with the state migration and test 3's
   byte-diff as the gate.
2. M3 ack quorum with both fallbacks, tests 1-2 and 4-6.
3. M5 `from-instance` header and `--instance` addressing.
4. M6 twins channel, only if increments 0-3 show it is needed in practice.

## 8. Decision points for the project owner

- D1 `AIMAIL_TWIN_ACK_TTL` value (fable: 6 h; a twin parked at the budget ramp for a whole
  block must not be dropped as dead).
- D2 Whether a twin channel (M6) is wanted at all, or whether `instances` + ordinary mail with a
  `[twin]` subject prefix is enough (fable: build 0-3 first; decide M6 on evidence).
- D3 Whether `ack --all` should exist at all under N >= 2 (fable: keep, per instance; the
  guard already makes it safe).
- D4 Instance display form: `<seat>@<sid8>/<account>` (fable's choice) or account-first.
