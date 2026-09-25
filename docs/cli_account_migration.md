# Fleet sessions on the Claude CLI: finding, stopping, moving and verifying a seat

The single authoritative reference for everything this fleet knows about managing a
seat's Claude Code background session from OUTSIDE that session: how the CLI's
background-job scheduler behaves, how to find a seat's real session, why `kill` is
wrong, how a seat is moved between accounts, and how to verify the move actually
stuck. Tooling here is `aimail seat migrate` / `seat locate` / `seat confirm` /
`seat record` (`lib/seatmigrate.sh`). If a fact about CLI session management is not in
this file, add it here — not in a seat's memory, not in a mail thread.

Rewritten 2026-09-21. The earlier version documented `kill <pid>` as the way to end a
session; following it caused a seat to run twice, under one session id, on two accounts,
on the wrong model. Nothing in this file names a real seat, account, project or session.

---

## 1. The scheduler model — what a `--bg` session is

`claude --bg …` starts a session under a **background-job scheduler** owned by the CLI.
Everything below follows from three facts about it:

1. **It tracks each job against its ORIGINAL launch spec.** Under the account's
   config dir, `jobs/<short-id>/state.json` holds `respawnFlags` (the original
   `--model`, permission flags, …), the original `intent` (the prompt), the job
   `state`, and `template: "bg"`. The short id is the first 8 characters of the
   session id.
2. **A process that dies without `claude stop` looks like a crash, and the scheduler
   RESPAWNS it from that spec** — same account dir, same `--model`, same flags —
   within minutes. A hand relaunch under a different account does not change the
   original spec, so the old job comes back beside the new one. Result: one session
   id live on two accounts, two AIs reading one mailbox and writing one role file.
3. **`claude stop <short-id>` deregisters the job cleanly.** No respawn. The
   conversation is kept and can be resumed later.
4. **A stopped background session keeps its SAVED LAUNCH OPTIONS, and `--resume <id>` with
   flags does not continue it.** When the account's `jobs/<short-id>/state.json` exists,
   `claude --bg --resume <id> --model … --permission-mode …` starts a COPY under a NEW session
   id and says so only in stdout ("… keeps its own saved options, so the flags you passed
   started a copy as <new-id>. Without flags, the same command continues <id> itself."). The
   flagless form continues the original. A relaunch on an account that has never held this
   session (a cross-account move) has no saved spec there, so flags are needed and honoured.

Consequences:

- `kill <pid>` on a seat's session is **never** the right instrument. Not "risky":
  wrong, because of (2).
- `claude agents --json` (run with `CLAUDE_CONFIG_DIR=<account dir>`) is the
  scheduler's own listing and the only honest source for "is this session live, and
  where". Without `--all` it lists live sessions; with `--all` it also lists stopped
  ones. Each row has `sessionId`, `id` (short id), `pid`, `state`, `status`, `cwd`,
  `name`, `startedAt`, `kind` (`background` or `interactive`). It does **not** carry
  the account or the model — the account is which config dir's listing names the
  session; the model is read from `jobs/<short-id>/state.json` (`respawnFlags`) or
  from the transcript (`projects/*/<session-id>.jsonl`, last `"model"` field).
- A session id is **not unique across accounts**. `--resume <id>` under a second
  account creates a second live job with the same id. Treat (config dir, session id)
  as the identity, never the id alone.

## 2. Finding a seat's session from outside

A seat **cannot report its own killable pid from inside**: every tool call runs in a
fresh subshell under a shared worker-pool process, so `$$`, `$PPID` and walking up the
tree land on ephemeral shells or a shared `bg-spare` worker, not on the job. Ask the
scheduler instead.

```
aimail seat locate <seat>
```

prints `key<TAB>value` lines: `sid`, `account`, `config_dir`, `pid`, `short_id`,
`state`, `cwd`, `liveness` (`live` | `dead` | `unknown` | `twin`), `source`
(`agents` | `record`). It works from three inputs, in this order of authority:

1. **`claude agents --json` across every account dir in the pool**
   (`AIMAIL_FLEET_ACCOUNTS`, else the accounts live seats resolve to). A candidate
   session id that the listing names is `live`, on that account.
2. **Poller instance files** (`state/instances/<seat>/<sid>`): every session that has
   armed a poller for this seat, with the account it registered under. These supply
   the candidate ids.
3. **The persisted seat record** (`state/seat_account/<seat>`, §3): the last account,
   session id and model the seat itself confirmed. When nothing is live, this is the
   answer for "which session do we relaunch, on which account, with which model".

Exit codes: 0 located; 1 nothing to go on; 2 UNKNOWN (an account dir did not answer —
never read as "not there"); 3 TWINS (live under more than one session/account; each
printed as a `twin` line). Twins are never resolved automatically — see §6.

Last resort, when no instance file and no record exist (a seat's first appearance on an
account): the transcript heuristic. Under `<config dir>/projects/*/`, the transcript
whose `poll <seat>` count dwarfs every other seat name is that seat's own session
(a seat polls itself far more than it names anyone else); cross-check with
`aimail role write <seat>` occurrences (a seat only writes its own role file). Pass the
result as `--sid` to `seat migrate`; the tool prints it as a heuristic, never as a fact.

## 3. The persisted seat record — `aimail seat confirm`

`state/seat_account/<seat>` (runtime state, gitignored like everything under
`state/`): `seat`, `account`, `config_dir`, `session_id`, `short_id`, `model`,
`confirmed_at`, `confirmed_by` (`boot` | `migrate` | a label), `host`.

It is written only when the account is known with certainty:

- **By the seat, at boot**, from inside its own session:
  `aimail seat confirm <seat> --model <id>`. The session id and the resolved
  `CLAUDE_CONFIG_DIR` are facts in that shell; the model is the id the seat quotes
  from its own system prompt (or, without `--model`, detected from the launch spec /
  transcript — recorded as `unknown` with a warning if neither has it; a model is
  never defaulted).
- **By `aimail seat migrate`**, after the settle re-verification passes (§4 step f).

`aimail session <seat>` checks the record every boot: missing → fix printed; record
names a different session id → "stale boot record or a TWIN"; account mismatch →
re-confirm. `aimail seat record <seat>` / `aimail seat records` print it.

## 4. Moving a seat between accounts — `aimail seat migrate`

```
aimail seat migrate <seat> <target-account> [--model <id>] [--from <supervisor-seat>]
    [--sid <id>] [--cwd <dir>] [--prompt-file <f>]
    [--handover-wait <s>=300] [--settle <s>=90] [--stop-timeout <s>=60]
    [--launch-timeout <s>=120] [--dry-run] [--force-no-handover]
```

Each step verifies its own result before the next runs; a step that cannot verify
REFUSES (exit 3) rather than continuing. `--dry-run` runs the read-only locate and
prints every command the remaining steps would run.

| step | what | verified by |
|---|---|---|
| a. locate | §2. Refuses on twins, on UNKNOWN, on "already live on the target", and when no model is known (`--model`, else the record, else the launch spec / transcript — never a default). | the listing |
| b. handover | If the session is live: mails the seat "write your role handover now" and waits (up to `--handover-wait`) for the role file's mtime to advance. Refuses on timeout unless `--force-no-handover` (only for a provably wedged session). Skipped when the session is not live. | role file mtime |
| c. stop | `CLAUDE_CONFIG_DIR=<current dir> claude stop <short-id>`, then polls that account's `claude agents --json` until the session id is ABSENT (up to `--stop-timeout`). Refuses if still listed — nothing is relaunched beside a live original. Then kills this session's orphaned poller processes (a stopped session's backgrounded `aimail poll…` survives it; only pids whose own command line is an aimail poller are touched). | the listing |
| d. relaunch | If the target already holds `jobs/<short-id>/state.json` (§1 fact 4): `cd <cwd> && CLAUDE_CONFIG_DIR=<target dir> claude --bg --resume <session-id> "<prompt>"` — FLAGLESS, so the CLI continues the session itself; refuses first if the saved spec pins a different model than requested (a flagged resume would not change it, it would fork). Otherwise: `… --resume <session-id> --model <model> --allow-dangerously-skip-permissions --permission-mode bypassPermissions "<prompt>"`. Either way the CLI's stdout is checked for "started a copy as <new-id>": if present the copy is stopped at once and the migration REFUSES (no record) — the tool never reports a resume that created a different session. The cwd is the one the listing reported (the trust dialog is per-cwd, §7). Default prompt: read the role file, register both stop hooks, arm the poller, run `aimail seat confirm`, report account + model back; `--prompt-file` overrides it. | command exit + stdout |
| e. verify + settle | Polls the target's listing until the id is present (`--launch-timeout`), then SLEEPS `--settle` seconds and re-checks: still present on the target, AND absent from every other account dir in the pool. A hit elsewhere is the respawn signature → refuses, printing the `claude stop` for the wrong one. An account that did not answer → also refuses (its absence is UNVERIFIED, so nothing is confirmed and no record is written; the session is live on the target, re-check by hand once every account answers). | the listings, twice |
| f. record | Writes the seat record (`confirmed_by=migrate`). The seat's own `seat confirm` at boot re-confirms from the inside. | file written |

Why the settle step exists: a respawn from the old spec appears a minute or two after
the kill, so a confirmation taken right after the relaunch is true at that instant and
false shortly after. The re-check is the whole point; do not shorten `--settle` below
the respawn window you have observed.

### 4a. Resume by default, transcript carried, fresh only on request (2026-09-22)

**Root cause found, four seats deep:** the CLI resolves `--resume <sid>` against the
TARGET config dir's own `projects/<cwd-slug>/<sid>.jsonl`. A session that has never run
on that account has no transcript there, so the job is recorded
`state: failed, detail: source session <sid> not found` (never a pid) and a ~1 KB stub
(titles, last prompt, no conversation) is left behind, so the next attempt fails the
same way. That is why fable, code-review, framing and foundation all ended up on fresh
sessions on 2026-09-22, and why the "DISAPPEARED during the settle window" refusals were
false: the `failed` row counted as "listed" and then dropped out.

What `seat migrate` does now, before step d:

| | |
|---|---|
| registry | `state/seat_sessions/<seat>`: one row per account (`account sid model confirmed_at by launch_path`) plus an append-only `.log` with who and why. Updated automatically by every `seat confirm`, every verified migrate, and the two verbs below. `aimail seat sessions [seat]` prints it. |
| default = resume | (i) the seat's own PREVIOUS session on the target, when the registry names one and its transcript is really there; else (ii) the located session, whose transcript (`<sid>.jsonl` and its `<sid>/` sidecar directory, same cwd slug) is COPIED into the target's config dir first, replacing any stub. If no transcript with a conversation exists anywhere in the pool, the run REFUSES and names the one escape. |
| `--fresh --why "<reason>"` | An explicit, logged fresh launch (no `--resume`; a NEW session id, found by diffing the target's listing, never by parsing CLI prose). the owner's rule: only for a seat that will not follow the orchestrator and is blocking the fleet. Never automatic. |
| step e | Reads the target's `jobs/<short>/state.json` first: `failed` refuses immediately, quoting the scheduler's own `detail`. `_sid_listed` counts only live rows (`failed`/`stopped` are not "present"). The settle re-check follows the sid that actually runs. |
| step f | The record carries `launch_path` (`resume` / `resume-prior` / `fresh`) and the registry row for the target account is written with the reason. |
| adjust | `aimail seat set-session <seat> <account> <sid> [--model <id>] --why "<r>"` and `aimail seat reset-session <seat> <account> --why "<r>"`; `--why` is mandatory and lands in the log. |

The role handover (§ Role handover in `skills/aimail/SKILL.md`) still travels with every
move and step b is still not optional: a resumed session gets its conversation back, a
fresh one gets only the handover.

## 5. Manual fallback — only when the tool cannot run

Same steps, same order, same verification; the tool's `--dry-run` prints them
pre-filled. Never skip c's "verified absent" or e's settle re-check by hand.

```
CLAUDE_CONFIG_DIR=<dir> claude agents --json | python3 -c 'import json,sys;[print(d["id"],d["sessionId"],d["state"],d["cwd"]) for d in json.load(sys.stdin)]'
CLAUDE_CONFIG_DIR=<dir> claude stop <short-id>
CLAUDE_CONFIG_DIR=<dir> claude agents --json           # the id must be gone
cd <cwd> && CLAUDE_CONFIG_DIR=<target dir> claude --bg --resume <session-id> --model <id> \
    --allow-dangerously-skip-permissions --permission-mode bypassPermissions "<prompt>"   # cross-account only
cd <cwd> && CLAUDE_CONFIG_DIR=<target dir> claude --bg --resume <session-id> "<prompt>"   # same account, or the target has jobs/<short-id>/: NO flags (§1 fact 4)
#   read the command's stdout: "started a copy as <new-id>" means it forked -- stop the copy, retry flagless
CLAUDE_CONFIG_DIR=<target dir> claude agents --json     # present …
sleep 90; for d in <every account dir>; do CLAUDE_CONFIG_DIR=$d claude agents --json; done   # … and only there
aimail seat confirm <seat> --model <id>                 # from inside the relaunched session
```

Other CLI verbs: `claude logs <short-id>` (recent terminal output; strip ANSI with
`sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'`), `claude attach <short-id>` (interactive),
`claude rm <short-id>` (delete a stopped session and its worktree; unlike `stop` it
works on already-exited sessions). `claude agents --json --all` includes stopped rows.

## 6. Twins — one seat, two live sessions

Symptoms: `aimail seat locate` exits 3; `aimail session` reports the seat record names
another session id; two different accounts' listings both show the id; the role file
changes under a seat that did not write it; mail bodies a seat never saw are already
acked. Cause: a killed job respawned (§1), or a relaunch made before the stop was
verified absent.

Resolution is a human/supervisor decision, never the tool's: pick the survivor (the
intended account and model — check `jobs/<short-id>/state.json` → `respawnFlags` on
each side), run `CLAUDE_CONFIG_DIR=<wrong dir> claude stop <short-id>`, confirm the id
is gone from that listing, re-run `aimail seat locate`, then have the survivor run
`aimail seat confirm`. Real work the wrong twin landed is kept if it was correct;
its role-file writes are superseded by the survivor's next write.

## 7. Prerequisites, once per (account, seat) — unchanged mechanics

An account that has been dormant needs all three before `claude --bg` works there:

1. **Config file present.** `CLAUDE_CONFIG_DIR=<dir> claude auth status` erroring
   about a missing config → restore the latest timestamped copy from `<dir>/backups/`.
2. **OAuth valid.** `auth status` → `"loggedIn": false` → `CLAUDE_CONFIG_DIR=<dir>
   claude auth login`, run by a human in a real terminal (browser flow; a raw-mode
   TTY app — piping input or writing into its pty fails silently and can burn a
   one-time code). To hand the authorize URL to the human when it opened in the
   wrong browser, record with a flushed `script -qfc "claude auth login" <log>` and
   grep the URL out of the log.
3. **Trust dialog for the project directory.** `--bg` with `bypassPermissions`
   refuses with "requires accepting the disclaimer first"; the prompt it means is the
   trust-this-folder dialog, scoped to the cwd the command runs FROM. Set
   `projects["<absolute cwd>"].hasTrustDialogAccepted = true` in `<dir>/.claude.json`
   (add the key by copying a sibling's defaults if absent); if `--bg` still refuses,
   `"skipDangerousModePermissionPrompt": true` in `<dir>/settings.json`. Always launch
   from the real project directory — the tool uses the cwd the listing reported.

## 8. What NOT to do

- `kill <pid>` / `pkill` on a seat's session — §1. (Killing an ORPHANED POLLER whose
  session is provably gone is a different thing and is what step c and the arm-time
  sweep do, by pid fingerprint.)
- Relaunch before the stop is verified absent from the listing.
- Confirm a migration from the first sighting — wait the settle window and re-check
  every account dir.
- Default a model. A seat exists to run a specific model; `seat migrate` refuses
  without one it can name.
- Pass flags to `--resume` on an account that already holds the session's saved launch
  options — it forks a copy under a new id (§1 fact 4). Flagless there, and read the stdout.
- Trust a pid a seat reports from inside its own session as a handle to that session.
- Skip the handover because the seat "was just booted" — a seat resumed without a
  current role file re-derives work already done.
- Launch `--bg` from a scratch directory to "test" — it creates a trust entry for the
  wrong cwd and helps nothing.
