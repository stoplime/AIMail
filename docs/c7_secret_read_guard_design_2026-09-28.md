# C7 secret-read guard + daily scan (2026-09-28)

## Why

On 2026-09-25/26, three real Bash commands printed real secret values into transcripts,
all by reading `zignore/.env` (or a bare `env`) with a keyword filter instead of a
names-only one. A keyword grep still prints the whole matched line, value included; a
`sed` redactor that tries to blank the value afterward is not a fix either, since it
only catches variable names it was told about in advance — it missed several real ones
in the third incident. Two independent nets, from that pattern:

1. **A PreToolUse hook on Bash** (`hooks/secret_read_guard.sh`) that denies a command
   before it runs, if it would print secret values.
2. **A daily scan** (`hooks/secret_scan.sh`) that checks whether a real secret value —
   pulled from a live process's own environment, never typed in by hand — is already
   sitting in plain text anywhere under a given set of repo roots.

Neither replaces the other: the guard stops a *new* leak from an interactive session;
the scan catches what's already on disk in the working trees it is pointed at (a stray log
file, a value pasted into a config or notes file, a leak from before the guard existed).
It skips `.git`, so it does not look through commit history.

## The guard: design choices, and why each one

**Mechanism — JSON output + exit 0, not exit 2.** The original ask described "exit 2
with a reason." This fleet already has two working Bash PreToolUse guards
(`claude_block_git_push.sh`, `claude_linear_write_guard.sh`) and both use
`{"hookSpecificOutput":{"permissionDecision":"deny", ...}}` on stdout with exit 0. That
mechanism is proven to work in this exact harness today; exit 2 is a different,
untested-here code path. Matching the proven pattern was a deliberate deviation from
the literal spec, called out here (and in the gate request) rather than silently
switched.

**Heuristic pattern matching, not a shell parser.** Bash syntax is not regular; a
guard that tried to fully parse it would be a much bigger, much more fragile piece of
code guarding something that runs on every single Bash call the fleet makes. Instead
this is pattern matching over the command string — conservative on the allow side
(ambiguous shapes resolve to ALLOW), validated by two things:
- `tests/c7_secret_guard.sh` — the three real leak commands (must deny), a battery of
  the specified allowed/safe forms (must allow), each paired so a "detects nothing"
  guard cannot pass silently.
- `tests/c7_replay.sh` — runs the guard over every real Bash command actually issued in
  the last 7 days of fleet transcripts (~95k commands) and reports how many it would
  have denied. Target: 0 false denies. See the run's own output for the count as of the
  gate request; any nonzero count there is a guard bug, not evidence it works, and must
  be fixed (or the specific denied shape explicitly accepted) before landing.

**Bash `[[ =~ ]]`, not `grep -E` subprocesses.** The regex patterns themselves are
identical POSIX ERE either way (bash's `=~` uses the same glibc `regexec` that
`grep -E` does), but forking `grep` per check made the REPLAY (95k commands × ~15
checks each) impractically slow. Rewriting each check as a bash builtin regex match
collapses each guard invocation to ~1 bash process + 1 `jq` call, not 1 bash process +
~15 `grep` forks. Re-verified against the full `tests/c7_secret_guard.sh` suite after
the rewrite — same 48/48 pass, same behavior, an order of magnitude faster.

**What counts as "touches a secret source":**
- a path whose basename is exactly `.env`, ends in `.env` (e.g. `app.env`), or starts
  with `.env.` (e.g. `.env.local`, `.env.production`);
- `/proc/<pid|self|$$>/environ`;
- a *bare* `env`, `printenv`, `set`, or `export -p`/`export` invocation with nothing
  downstream to filter it — `set -a`, `set -e`, `set -o pipefail` etc. are option
  toggles (something follows the flag), not dumps, and are explicitly excluded.

**What counts as "prints the value" once a secret source is touched:** `cat`, `head`,
`tail`, `less`, `more`, `tac`, `strings`, `xxd`, `od`, `hexdump`, `nl`, an editor
opening the file directly; a `grep`/`sed`/`awk` stage that isn't one of the safe forms
below; a `cut` stage that isn't specifically `-d= ... -f1` (a `cut -f1` with the wrong
or no delimiter returns the whole un-split line — value included — which is exactly
the kind of near-miss this guard exists to catch, and was a real bug caught by its own
test suite during development, not a hypothetical).

**What neutralizes it (names-only, never prints a value):** `grep -o`/`-oE` whose
pattern is anchored at `^` and ends, as its very last literal character, at an
unrepeated `=` (the invariant, not one fixed spelling — `^[A-Z0-9_]+=`,
`^(DATABASE_URL|POSTGRES_[A-Z]+)=`, `^[A-Z_]*(DB|SQL)[A-Z_]*=` are all equally safe
under this rule, since `-o` plus that shape guarantees the match can never extend past
the `=`); `grep -c`/`-q`/`-l` (count/exit-code/filenames only); `cut -d= -f1` (only in
that exact -d/-f pairing); `[ -n "$VAR" ]`; `test -f`; `ls -la` (metadata, not
content); `ln -s`; `cp`/`mv`/`aws s3 cp` (a copy or rename, unless the destination IS
stdout); `rm` (deletion discloses nothing); `sed -i`/`-i.bak` (in-place, prints
nothing to stdout regardless of what it matches); an unconditional `sed
's/=.*/.../'`  (pattern is exactly `=.*`, nothing before the `=`, so it redacts every
line's value regardless of variable name — distinct from a *keyword-gated* redactor
like `s/PASSWORD=.*/.../`, which misses any name not in its list and is exactly the
third 09-25/26 leak's shape, still correctly denied); `source`/`.` (executes the
file; sourcing itself prints nothing — a script that goes on to `echo` a variable
afterward is a separate command, caught the same way any other command printing that
value would be, which is out of scope for a guard that only sees one command string
at a time); the `while ... read ... export "$k=$v" ... done < <(...)` sourcing idiom;
`VAR=$(...)` / `env $(...)` / `export $(...)` (a captured value feeds a variable or an
argument list, never this command's own stdout, regardless of what the substitution
reads); and a pipeline whose own stdout is redirected to a **file** (`> path`, not
`/dev/stdout`/`/dev/fd/1`/`/dev/stderr`) — same "never reaches stdout" guarantee as
the substitution forms, just via a file redirect.

**Two structural gaps found only by replaying real fleet traffic (`tests/c7_replay.sh`
against 7 days / ~95k real commands), both now fixed:**
- *Argument-blind matching.* `touches_envfile`/`is_content_reader` scan the whole
  command string independently, with nothing tying a content-reader keyword to what
  it's actually reading. A `--subject "... + staging .env) ..."` flag argument on an
  unrelated `aimail send` piped to `| tail -3` (checking the send confirmation, not any
  file) matched both independently and was denied. Fixed by stripping known
  message-carrying flags' own quoted text arguments (`--subject`/`--body`/`--desc`/
  `--message`/`--reason`/`--why`/`--state`) before the envfile check, the same
  precedent as stripping grep/sed/awk's own pattern argument.
- *A literal `>` inside quoted prose read as a real redirect.* The file-redirect-capture
  check (above) originally accepted *any* non-whitespace run after `>` as a path,
  which matched the literal `>` in a sed replacement's `<redacted>` placeholder text
  and misread `sed "s/PASSWORD=.*/PASSWORD=<redacted>/"` as ending in a file redirect —
  silently *allowing* a real, undetected leak. Fixed by restricting the redirect
  target's charset to actual path characters (letters, digits, `_./${}~-`), which a
  quote character can never be part of.

**Human-only escape.** The hook has one, for a real person at a real terminal who
needs to look at a value. Its exact form is only in the hook's source and is left out
of this document on purpose, so it is not text a seat is pointed at.

## The daily scan (`hooks/secret_scan.sh`)

Given a PID and one or more repo roots: reads that process's own `/proc/<pid>/environ`,
filters to variables matching `*(SECRET|PASSWORD|KEY|TOKEN|DSN)*` with values 12+
characters long, holds those values in a `0600` file under `/dev/shm` (shredded on
exit, including on an early error — `trap ... EXIT`), and greps every root for a
literal (`-F`, never re-interpreted as a pattern) match. Output is **only** a count and
the matching file paths — never a value, never the matching line. Exit code is nonzero
when the count is above zero, so it composes into a cron job whose own exit code is the
alert.

## What this does not do

- Does not stop a value from being read into a shell *variable* and used — only from
  being *printed* by the one Bash command a hook sees.
- Does not replace human judgment about what's actually secret; the value-name pattern
  in the daily scan (`SECRET|PASSWORD|KEY|TOKEN|DSN`) is a starting list, not exhaustive.
- Wiring into each account's `settings.json` (`PreToolUse` → `Bash` → this script) is a
  separate step, done only after GATE GREEN and land, each file read first and merged
  in (never overwritten) — not part of this build.

## Review fixes (2026-09-28)

- `(set)` after a word character (`defaultdict(set)`, `list(set)`) is a call, not a subshell
  running `set`: the bare-dump check no longer reads it as a dump.
- The names-only `grep` form is accepted with its flags as separate words
  (`grep -o -E`, `grep -E -o`) as well as one cluster (`-oE`), still requiring the pattern to
  be anchored at `^` and to end at the `=`.
- The `while read ... export ... done < <(...)` sourcing loop is exempt on its own now,
  from `while` through `done` and the input it reads; the rest of the command is still
  checked, so a leak after the loop is denied. Known limit: two such loops in one command
  exempt everything between them.
- The scan passes its values to `grep` through a file (`-f`), one tree walk for all of
  them, so no value appears in the process list.
- Known gaps, left to the daily scan by design (the guard leans to allow): `sort`/`dd`/
  `base64`/`paste`/`tee` and interpreter one-liners that print a `.env`, `printenv NAME`,
  `declare -x`, `compgen -e`, and `/proc/$(pgrep ...)/environ`.
