# The Codex account — MVP

Codex (a ChatGPT login, no API key) is a fourth account. A seat hosted there has no Claude session,
so `lib/codex_account.py` feeds it its mail. Nothing in it names an owner or a company.

## What ships
| Piece | Where |
|---|---|
| Weekly reading in `aimail budget pool` | newest non-null `rate_limits.primary` across `~/.codex/sessions/**/*.jsonl`; a SESSION row only if `secondary` ever appears; reading age + STALE marker; none found prints `UNMEASURED`, never 0% |
| Tier table (the only one) | `etc/codex_account.json`: haiku→gpt-6-luna, sonnet and opus→gpt-6.1-sol, fable→gpt-6-astra |
| `aimail codex usage / models / seat-add / worker` | `bin/aimail` → `lib/codex_account.py` |
| Seat worker | one Codex turn per batch of waiting mail, in the seat's persistent session; final message mailed to each sender; mail archived; reading appended to `$AIMAIL_ROOT/codex/readings.tsv`; heartbeat in the normal poller file so `aimail fleet` shows ARMED |

## Mechanics checked against codex 0.160.0
- New session: `codex exec -m M -C WORKTREE -s workspace-write --json -o OUT … -`; the thread id comes from the `thread.started` event and is stored per seat.
- Resume: `codex exec resume ID …` has **no** `-C` or `-s`: the worker runs it with the worktree as the process cwd and sets the sandbox with `-c sandbox_mode="workspace-write"`. Verified: context kept, a write outside the worktree fails.
- Context window is 272k (the Claude seats have 500k): a seat relies on its role handover, not on a long session.

## Safety on every invocation
`-c features.<x>=false` for apps, browser_use, browser_use_external, computer_use, in_app_browser; `shell_environment_policy.exclude` for `*KEY* *SECRET* *TOKEN* *PASSWORD*`; the codex process itself also gets a scrubbed environment; network stays at the sandbox default (off); `git push` is already refused by the pre-push guard. The worker stops taking mail at the weekly stop percent (95) and leaves it un-acked.

## Worker guards (after the framing gate)
- One reader per seat: a per-seat flock, and a refusal to start beside a live Claude poller for the same seat.
- Heartbeat from a thread every 15 s (turns last minutes), `persistent 0`, an exit record on a clean stop.
- Weekly stop only applies to a reading whose window is still open (`resets_at` in the future); after the reset the next turn refreshes the figure.
- Replies never loop: none to itself, to another hosted seat, to `wake: no` mail, or past a `Re:` depth of 2; give-up notices go `--no-wake`.
- A reply that cannot be sent counts as a failed attempt (count saved first); the loop survives errors; failures back off 60 s, a cap or missing settings 300 s; after a failed batch mails are retried one at a time.
- Network off (`sandbox_workspace_write.network_access=false`) and `approval_policy="never"` are pinned on every call; the secret-name list also covers PASSWD, CREDENTIAL, AUTH, PAT.
- Optional per-seat sender allow-list (`seat-add --senders a,b`); set it on any seat that is not read-mostly.
- A timed-out turn kills the whole process group.

## Design limits to know
workspace-write limits WRITES only: a command the model runs can still READ files the user can read (including `~/.codex/auth.json` and `~/.aimail`), and a mailed instruction could carry that back in the reply. Acceptable for the read-mostly `codex-review` seat with the sender allow-list; not acceptable to host a seat that takes mail from anyone. The worker acks by moving the file itself (it is the mail's only reader, so the bulk-ack receipt check has nothing to guard).

## Failure behaviour
A non-zero exit or empty reply leaves the mail un-acked and counts an attempt; after `max_attempts` (3) the sender gets one no-wake notice and the mail is not retried.

## Not in the MVP
Codex-hook ports of the stop, prompt and credential guards (needed before a seat that writes code moves here), and the aimail skill as a Codex skill.

## Tests
`fleet-workspace/fleet_tests/test_codex_account.py` — in-process, injected runner/sender/clock, temp dirs, sets not orders.
