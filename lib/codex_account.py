#!/usr/bin/env python3
"""The Codex account for the fleet: usage reading, model tiers, the codex command line, and a seat worker.

WHAT THIS IS. Codex (OpenAI, ChatGPT login) is a fourth ACCOUNT, next to the Claude ones. A seat
that lives on it has no Claude session, so something has to read its mail and give it to Codex.
This file is that something, in four small parts, none of which names an owner or a company:

  1. usage      newest weekly reading from the Codex session files, shown by `aimail budget pool`.
  2. tiers      one table (etc/codex_account.json) from the fleet's model tiers to Codex models.
  3. command    the exact `codex exec` argument list for one turn, with the safety settings in it.
  4. worker     reads one seat's mailbox, runs one Codex turn per mail batch in the seat's own
                persistent Codex session, mails the final message back, acks, records the reading.

Everything with a side effect takes its dependency as an argument (the runner of codex, the mail
sender, the clock, the directories) so the tests drive it in-process with fakes and never start
codex or touch a real mailbox.

WHAT IT DOES NOT DO (later, and the seat registry says so): port the stop-hook, prompt and
credential guards to Codex hooks, or let a seat that writes code move here. `codex-review` is a
read-mostly seat; the sandbox below keeps even a mistaken write inside its own worktree.
"""
from __future__ import annotations

import argparse
import fcntl
import fnmatch
import glob
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple

HOME = Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = HOME / "etc" / "codex_account.json"


# ─── configuration: ONE table ───────────────────────────────────────────────────────────────────
def load_config(path: Optional[Path] = None) -> Dict[str, Any]:
    """The tier table and safety settings. A missing key is an error here, not a silent default,
    because a silently defaulted model or an absent safety list is exactly how a seat ends up on
    the wrong (or an unguarded) account."""
    p = Path(path) if path else DEFAULT_CONFIG
    cfg = json.loads(p.read_text(encoding="utf-8"))
    for key in ("tier_models", "disabled_features", "env_exclude", "weekly_stop_percent",
                "reading_stale_seconds", "turn_timeout_seconds", "max_attempts", "extra_overrides",
                "failure_backoff_seconds", "capped_backoff_seconds", "heartbeat_seconds", "max_reply_depth"):
        if key not in cfg:
            raise ValueError(f"{p}: missing required key {key!r}")
    return cfg


def model_for_tier(cfg: Mapping[str, Any], tier: str) -> str:
    """The Codex model for a fleet tier. An unknown tier raises: guessing a model would bill the
    wrong one."""
    models = cfg["tier_models"]
    if tier not in models:
        raise KeyError(f"unknown tier {tier!r}; the table has {sorted(models)}")
    return models[tier]


# ─── 1. usage ───────────────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Reading:
    """One rate-limit reading out of a Codex session file."""
    ts: float                    # when Codex wrote it (epoch seconds)
    used_percent: float          # of the weekly window
    window_minutes: int          # 10080 is the weekly window
    resets_at: Optional[int]     # epoch seconds
    plan_type: Optional[str]
    secondary: Optional[Dict[str, Any]]   # a second window, only if the plan ever reports one
    source: str                  # the session file it came from

    def window_open(self, now: float) -> bool:
        """False once the weekly window this figure belongs to has reset: the percentage then
        describes last week, and nothing can refresh it except a turn the cap would block."""
        return self.resets_at is None or self.resets_at > now


def codex_home(env: Optional[Mapping[str, str]] = None) -> Path:
    env = os.environ if env is None else env
    return Path(env.get("CODEX_HOME") or (Path.home() / ".codex"))


def _iso_epoch(text: str) -> float:
    # 2026-10-02T19:48:55.974Z
    from datetime import datetime, timezone
    return datetime.strptime(text[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()


def _readings_in(path: str) -> List[Reading]:
    out: List[Reading] = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"rate_limits"' not in line:
                    continue          # cheap text test first: most lines are not usage events
                try:
                    event = json.loads(line)
                except ValueError:
                    continue          # a half-written last line is normal while a turn runs
                payload = event.get("payload") if isinstance(event, dict) else None
                limits = payload.get("rate_limits") if isinstance(payload, dict) else None
                primary = limits.get("primary") if isinstance(limits, dict) else None
                if not isinstance(primary, dict) or primary.get("used_percent") is None:
                    continue          # most token events carry rate_limits with primary null
                try:
                    ts = _iso_epoch(event["timestamp"])
                except (KeyError, ValueError, TypeError):
                    continue
                resets = primary.get("resets_at")
                try:
                    used = float(primary["used_percent"])
                    window = int(primary.get("window_minutes") or 0)
                except (TypeError, ValueError):
                    continue          # a reading with a non-number in it is no reading
                out.append(Reading(
                    ts=ts, used_percent=used, window_minutes=window,
                    resets_at=int(resets) if isinstance(resets, (int, float)) else None,
                    plan_type=limits.get("plan_type"),
                    secondary=limits.get("secondary") if isinstance(limits.get("secondary"), dict) else None,
                    source=path))
    except OSError:
        pass
    return out


def latest_reading(home: Optional[Path] = None) -> Optional[Reading]:
    """The newest usable reading across all session files, or None when there is none.

    A file's readings can never be newer than the file's own modification time, so files are read
    newest-first and the scan stops as soon as the next file is older than the best reading found.
    None means UNMEASURED (never read as 0%)."""
    root = (home or codex_home()) / "sessions"
    files = []
    for p in glob.glob(str(root / "**" / "*.jsonl"), recursive=True):
        try:
            files.append((os.path.getmtime(p), p))
        except OSError:
            continue          # deleted while we scanned
    files.sort(reverse=True)
    best: Optional[Reading] = None
    for mtime, path in files:
        if best is not None and mtime < best.ts:
            break
        for r in _readings_in(path):
            if best is None or r.ts > best.ts:
                best = r
    return best


def _fmt_age(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 90:
        return f"{seconds}s"
    minutes = seconds // 60
    if minutes < 120:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def pool_lines(reading: Optional[Reading], now: float, cfg: Mapping[str, Any]) -> List[str]:
    """The block `aimail budget pool` prints for the Codex account."""
    lines = ["codex account (OpenAI, ChatGPT login) — weekly window"]
    if reading is None:
        lines.append("  WEEKLY%: ?    UNMEASURED — no session file carries a rate-limit reading yet.")
        lines.append("  A reading appears after the first Codex turn; '?' is never 0%.")
        return lines
    age = now - reading.ts
    if not reading.window_open(now):
        lines.append(f"  WEEKLY%: ?    window RESET — the last figure ({reading.used_percent:g}%, {_fmt_age(age)} old) "
                     f"belongs to the previous week; the next Codex turn takes a new reading.")
        return lines
    stale = age > float(cfg["reading_stale_seconds"])
    window = f"{reading.window_minutes // 1440}d" if reading.window_minutes % 1440 == 0 else f"{reading.window_minutes}m"
    resets = time.strftime("%m-%d %H:%M", time.localtime(reading.resets_at)) if reading.resets_at else "?"
    lines.append(f"  WEEKLY%: {reading.used_percent:g}%/{cfg['weekly_stop_percent']}%    window {window}    "
                 f"RESETS {resets}    plan {reading.plan_type or '?'}")
    lines.append(f"  reading age {_fmt_age(age)}" + ("  STALE — no Codex turn since; the figure can only have gone up"
                                                     if stale else "") +
                 "    (a reading is written only when a turn runs)")
    if reading.secondary:
        sec = reading.secondary
        lines.append(f"  SESSION window: {sec.get('used_percent', '?')}% of {sec.get('window_minutes', '?')}m "
                     f"(second window reported by the plan)")
    return lines


# ─── 3. the codex command line ──────────────────────────────────────────────────────────────────
def scrubbed_env(environ: Mapping[str, str], patterns: Sequence[str]) -> Dict[str, str]:
    """The environment handed to the codex process itself: everything except names that look like
    secrets. This is on top of `shell_environment_policy`, which does the same for the commands the
    model runs. Values are never printed or logged anywhere in this file."""
    return {k: v for k, v in environ.items()
            if not any(fnmatch.fnmatchcase(k.upper(), p.upper()) for p in patterns)}


def codex_argv(cfg: Mapping[str, Any], *, model: str, worktree: str, session_id: Optional[str],
               last_message_path: str, codex_bin: str = "codex") -> List[str]:
    """The argument list for ONE turn; the prompt goes on stdin (`-`).

    A new session uses `codex exec` with -C and -s. A resumed one uses `codex exec resume <id>`,
    which accepts neither of those options (checked against codex 0.160.0): the working directory
    is the process's own (the caller runs it in the worktree) and the sandbox is set with
    `-c sandbox_mode=...`. Verified: on a resumed session the same sandbox applies, a write outside
    the worktree fails and one inside succeeds, and the earlier context is still there."""
    overrides: List[str] = []
    for feature in cfg["disabled_features"]:
        overrides += ["-c", f"features.{feature}=false"]
    for override in cfg["extra_overrides"]:         # network off, approvals never: pinned, not inherited
        overrides += ["-c", override]
    excludes = json.dumps(list(cfg["env_exclude"]))
    overrides += ["-c", f"shell_environment_policy.exclude={excludes}"]
    common = ["-m", model, "--skip-git-repo-check", "--json", "-o", last_message_path]
    if session_id:
        return [codex_bin, "exec", "resume", session_id, *common,
                "-c", 'sandbox_mode="workspace-write"', *overrides, "-"]
    return [codex_bin, "exec", *common, "-C", worktree, "-s", "workspace-write", *overrides, "-"]


def parse_events(jsonl: str) -> Tuple[Optional[str], Optional[str]]:
    """(thread id, last agent message) from `codex exec --json` output. Either may be None."""
    thread: Optional[str] = None
    message: Optional[str] = None
    for line in jsonl.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "thread.started" and event.get("thread_id"):
            thread = str(event["thread_id"])
        item = event.get("item")
        if event.get("type") == "item.completed" and isinstance(item, dict) and item.get("type") == "agent_message":
            message = str(item.get("text") or "")
    return thread, message


# ─── 4. the seat worker ─────────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class Mail:
    path: Path
    id: str
    sender: str
    subject: str
    body: str
    wake: bool


_HEADER_END = re.compile(r"^---\s*$", re.M)


def parse_mail(path: Path) -> Mail:
    """A mail file: `---`, header lines, `---`, then the body (the format `aimail send` writes)."""
    text = path.read_text(encoding="utf-8", errors="replace")
    headers: Dict[str, str] = {}
    body = text
    parts = _HEADER_END.split(text, maxsplit=2)
    if len(parts) == 3 and parts[0].strip() == "":
        for line in parts[1].splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        body = parts[2].lstrip("\n")
    return Mail(path=path, id=headers.get("id") or path.stem, sender=headers.get("from", "unknown"),
                subject=headers.get("subject", "(no subject)"), body=body,
                wake=headers.get("wake", "yes").lower() != "no")


@dataclass
class TurnResult:
    ok: bool
    mail_ids: List[str]
    reply: str = ""
    note: str = ""
    backoff: float = 0.0        # seconds the loop waits before trying again (0 = the normal interval)


Runner = Callable[[Sequence[str], str, Mapping[str, str], str, float], "subprocess.CompletedProcess[str]"]
Sender = Callable[[str, str, str, str, bool], None]       # (to, from, subject, body, wake)


def run_codex(argv: Sequence[str], stdin: str, env: Mapping[str, str], cwd: str, timeout: float):
    """The real runner; tests pass a fake with the same signature. codex runs in its own process
    group so that on a timeout everything the model started goes with it, not just codex."""
    proc = subprocess.Popen(list(argv), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=dict(env), cwd=cwd, start_new_session=True)
    try:
        out, err = proc.communicate(stdin, timeout=timeout)
    except BaseException:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        raise
    return subprocess.CompletedProcess(list(argv), proc.returncode, out, err)


_RE_PREFIX = re.compile(r"^\s*(re:\s*)+", re.I)


def reply_depth(subject: str) -> int:
    """How many `Re:` prefixes a subject carries: the chain depth of a reply conversation."""
    m = _RE_PREFIX.match(subject)
    return len(re.findall(r"re:", m.group(0), re.I)) if m else 0


class SeatWorker:
    """One Codex-hosted seat: mail in, one Codex turn, mail back.

    Directories are arguments, not discovered: `mail_dir` is `<root>/mail`, `state_dir` is
    `<root>/state` and `codex_dir` is `<root>/codex` (per-seat settings, locks, the readings log).

    Guards a worker needs because nobody is watching it: one instance per seat (a lock), no reply to
    itself, to another hosted seat, to a `wake: no` mail or beyond a reply-chain depth (replies
    must not loop and burn the weekly quota), a window-reset-aware weekly stop, a back-off after
    failures, and a heartbeat that keeps beating while a long turn runs."""

    def __init__(self, seat: str, *, cfg: Mapping[str, Any], root: Path, codex_home_dir: Path,
                 runner: Runner = run_codex, send: Optional[Sender] = None,
                 clock: Callable[[], float] = time.time, environ: Optional[Mapping[str, str]] = None):
        self.seat = seat
        self.cfg = cfg
        self.mail_dir = Path(root) / "mail" / seat
        self.state_dir = Path(root) / "state"
        self.codex_dir = Path(root) / "codex"
        self.roles_dir = Path(root) / "roles"
        self.codex_home = codex_home_dir
        self.runner = runner
        self.send = send or self._send_via_cli
        self.clock = clock
        self.environ = os.environ if environ is None else environ
        self._lock_fh = None
        self._hb_stop: Optional[threading.Event] = None

    # one worker per seat ----------------------------------------------------------------------
    def acquire(self) -> bool:
        """Take the seat's lock; False when another worker holds it or a Claude poller is live for
        the seat (two readers of one mailbox answer every mail twice)."""
        if self._lock_fh is not None:
            return True
        d = self.codex_dir / "locks"
        d.mkdir(parents=True, exist_ok=True)
        fh = open(d / f"{self.seat}.lock", "a+")
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            return False
        hb = self._read_hb()
        pid = hb.get("pid", "")
        fresh = self.clock() - float(hb.get("beat", 0) or 0) < 120
        if pid.isdigit() and int(pid) != os.getpid() and fresh and hb.get("kind") != "codex_worker" and self._alive(int(pid)):
            fh.close()
            self._log(f"refused to start: a poller (pid {pid}) is already live for '{self.seat}'")
            return False
        self._lock_fh = fh
        return True

    def close(self) -> None:
        if self._lock_fh is not None:
            self._lock_fh.close()
            self._lock_fh = None

    @staticmethod
    def _alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def _log(self, message: str) -> None:
        """A local log line (never a secret: only seat, ids and counts are passed in)."""
        self.codex_dir.mkdir(parents=True, exist_ok=True)
        with open(self.codex_dir / "worker.log", "a", encoding="utf-8") as fh:
            fh.write(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(self.clock()))} {self.seat}: {message}\n")

    # seat settings: tier, worktree, allowed senders, the persistent session id -----------------
    @property
    def _seat_file(self) -> Path:
        return self.codex_dir / "seats" / f"{self.seat}.json"

    def seat_settings(self) -> Dict[str, Any]:
        try:
            return json.loads(self._seat_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def save_seat_settings(self, settings: Mapping[str, Any]) -> None:
        self._seat_file.parent.mkdir(parents=True, exist_ok=True)
        tmp = self._seat_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(dict(settings), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(tmp, self._seat_file)

    def _is_hosted_seat(self, name: str) -> bool:
        return (self.codex_dir / "seats" / f"{name}.json").is_file()

    # heartbeat: the file `aimail fleet` reads. `persistent 0` because this is not a Monitor-armed
    # poller (persistent 1 makes the fleet call it wedged after 40 minutes); a thread keeps the beat
    # fresh while a turn runs, since a turn can outlast the fleet's hung-loop window ----------------
    def _read_hb(self) -> Dict[str, str]:
        out: Dict[str, str] = {}
        try:
            for line in (self.state_dir / "poller" / f"{self.seat}.hb").read_text().splitlines():
                if "\t" in line:
                    k, v = line.split("\t", 1)
                    out[k] = v
        except OSError:
            pass
        return out

    def heartbeat(self, started: float, exit_reason: Optional[str] = None) -> None:
        d = self.state_dir / "poller"
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / f".hb.{os.getpid()}.{threading.get_ident()}"
        now = int(self.clock())
        body = (f"pid\t{os.getpid()}\nppid\t{os.getppid()}\nstarted\t{int(started)}\n"
                f"persistent\t0\nkind\tcodex_worker\nbeat\t{now}\n")
        if exit_reason:
            body += f"exit_at\t{now}\nexit_reason\t{exit_reason}\n"
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, d / f"{self.seat}.hb")

    def start_heartbeat(self, started: float) -> None:
        stop = threading.Event()
        self._hb_stop = stop
        every = float(self.cfg["heartbeat_seconds"])

        def beat() -> None:
            while not stop.is_set():
                try:
                    self.heartbeat(started)
                except OSError:
                    pass
                stop.wait(every)
        threading.Thread(target=beat, name=f"hb-{self.seat}", daemon=True).start()

    def stop_heartbeat(self) -> None:
        if self._hb_stop is not None:
            self._hb_stop.set()
            self._hb_stop = None

    # mail ---------------------------------------------------------------------------------
    def pending(self) -> List[Mail]:
        """Mail not yet answered, oldest first: top-level and unacked/, minus the ones given up on
        and minus senders outside the seat's allow-list (when it has one). Held mail (`wake: no`)
        is read only when at least one wake mail is also waiting, the Claude poller's own rule."""
        gave_up = set(self._attempts().get("gave_up", []))
        allowed = self.seat_settings().get("senders")
        files: List[Tuple[float, Path]] = []
        for d in (self.mail_dir, self.mail_dir / "unacked"):
            if d.is_dir():
                for p in d.glob("*.md"):
                    try:
                        files.append((p.stat().st_mtime, p))
                    except OSError:
                        continue
        files.sort(key=lambda t: t[0])
        mails = [parse_mail(p) for _, p in files if p.stem not in gave_up]
        if allowed:
            mails = [m for m in mails if m.sender in allowed]
        if not any(m.wake for m in mails):
            return []
        return mails

    def _attempts(self) -> Dict[str, Any]:
        try:
            return json.loads((self.codex_dir / "attempts" / f"{self.seat}.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    def _save_attempts(self, data: Mapping[str, Any]) -> None:
        p = self.codex_dir / "attempts" / f"{self.seat}.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(dict(data), indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def prompt_for(self, mails: Sequence[Mail], first_turn: bool) -> str:
        parts: List[str] = []
        if first_turn:
            role = self.roles_dir / f"{self.seat}.md"
            parts.append(f"You are the fleet seat '{self.seat}'. Read the repository AGENTS.md and the memory "
                         f"index your global instructions point to before acting.")
            if role.is_file():
                parts.append("Your role handover:\n" + role.read_text(encoding="utf-8", errors="replace"))
        parts.append("New mail follows. Act on it. Your final message is mailed back to the sender "
                     "as the reply, so end with the answer itself, not a progress note.")
        for m in mails:
            parts.append(f"=== MAIL {m.id}\nfrom: {m.sender}\nsubject: {m.subject}\n\n{m.body}")
        return "\n\n".join(parts)

    def _may_reply(self, m: Mail) -> bool:
        """Replies must never start or feed a loop."""
        return (m.sender != self.seat and m.wake and not self._is_hosted_seat(m.sender)
                and reply_depth(m.subject) < int(self.cfg["max_reply_depth"]))

    # one batch ----------------------------------------------------------------------------
    def run_once(self) -> Optional[TurnResult]:
        """Process what is waiting as ONE turn (or, after a failed batch, one mail at a time, so a
        poison mail cannot take good mail down with it). None when there is nothing to do."""
        if not self.acquire():
            return TurnResult(False, [], note="another reader holds this seat", backoff=float(self.cfg["failure_backoff_seconds"]))
        mails = self.pending()
        if not mails:
            return None
        counts = self._attempts().get("counts", {})
        retried = [m for m in mails if counts.get(m.path.stem)]
        if retried:
            mails = retried[:1]
        reading = latest_reading(self.codex_home)
        now = self.clock()
        if reading is not None and reading.window_open(now) and reading.used_percent >= float(self.cfg["weekly_stop_percent"]):
            return TurnResult(False, [m.id for m in mails], backoff=float(self.cfg["capped_backoff_seconds"]), note=(
                f"weekly cap reached ({reading.used_percent:g}% >= {self.cfg['weekly_stop_percent']}%); mail left waiting"))
        settings = self.seat_settings()
        tier, worktree = settings.get("tier"), settings.get("worktree")
        if not tier or not worktree:
            return TurnResult(False, [m.id for m in mails], backoff=float(self.cfg["capped_backoff_seconds"]),
                              note="seat has no tier or worktree; run `aimail codex seat-add`")
        model = model_for_tier(self.cfg, tier)
        session_id = settings.get("session_id")
        out_file = self.codex_dir / "last" / f"{self.seat}.txt"
        out_file.parent.mkdir(parents=True, exist_ok=True)
        if out_file.exists():
            out_file.unlink()
        argv = codex_argv(self.cfg, model=model, worktree=str(worktree), session_id=session_id,
                          last_message_path=str(out_file))
        env = scrubbed_env(self.environ, self.cfg["env_exclude"])
        prompt = self.prompt_for(mails, first_turn=session_id is None)
        try:
            done = self.runner(argv, prompt, env, str(worktree), float(self.cfg["turn_timeout_seconds"]))
        except Exception as exc:                       # timeout, missing binary, ...
            return self._failed(mails, f"codex did not run: {type(exc).__name__}")
        thread, last = parse_events(done.stdout or "")
        reply = out_file.read_text(encoding="utf-8", errors="replace").strip() if out_file.exists() else (last or "")
        if done.returncode != 0 or not reply:
            return self._failed(mails, f"codex exit {done.returncode}, reply {'empty' if not reply else 'present'}")
        if thread and thread != session_id:
            settings["session_id"] = thread            # the seat keeps this context from now on
        elif not thread and not session_id:
            self._log("first turn printed no thread id: the next turn will start a new session")
        settings["last_turn"] = int(now)
        self.save_seat_settings(settings)
        self.record_reading()
        return self._deliver(mails, reply)

    def _deliver(self, mails: Sequence[Mail], reply: str) -> TurnResult:
        """Reply (where allowed) and ack, one mail at a time: send first, so a crash can repeat a
        reply but never lose one. A reply that cannot be sent counts as a failed attempt."""
        attempts = self._attempts()
        counts = attempts.setdefault("counts", {})
        failed: List[str] = []
        for m in mails:
            if self._may_reply(m):
                try:
                    self.send(m.sender, self.seat, f"Re: {m.subject}", reply, True)
                except Exception as exc:
                    failed.append(m.path.stem)
                    counts[m.path.stem] = counts.get(m.path.stem, 0) + 1
                    self._log(f"reply to {m.sender} for {m.id} could not be sent ({type(exc).__name__}), "
                              f"attempt {counts[m.path.stem]}")
                    if counts[m.path.stem] >= int(self.cfg["max_attempts"]):
                        attempts.setdefault("gave_up", []).append(m.path.stem)
                        self._log(f"gave up on {m.id}: its reply cannot be delivered")
                    continue
            self._ack(m)
            counts.pop(m.path.stem, None)
        self._save_attempts(attempts)
        return TurnResult(not failed, [m.id for m in mails], reply=reply,
                          note="" if not failed else f"{len(failed)} reply(ies) not sent",
                          backoff=float(self.cfg["failure_backoff_seconds"]) if failed else 0.0)

    def _failed(self, mails: Sequence[Mail], why: str) -> TurnResult:
        attempts = self._attempts()
        counts = attempts.setdefault("counts", {})
        gave_up = attempts.setdefault("gave_up", [])
        newly: List[Mail] = []
        for m in mails:
            counts[m.path.stem] = counts.get(m.path.stem, 0) + 1
            if counts[m.path.stem] >= int(self.cfg["max_attempts"]) and m.path.stem not in gave_up:
                gave_up.append(m.path.stem)
                newly.append(m)
        self._save_attempts(attempts)            # the count is on disk before anything that can fail
        for m in newly:
            self._log(f"gave up on {m.id} after {self.cfg['max_attempts']} tries ({why})")
            if self._may_reply(m):
                try:
                    self.send(m.sender, self.seat, f"Re: {m.subject}",
                              f"The Codex seat '{self.seat}' could not answer this mail after "
                              f"{self.cfg['max_attempts']} tries ({why}). It is left un-acked in the seat's mailbox.", False)
                except Exception as exc:
                    self._log(f"give-up notice for {m.id} could not be sent ({type(exc).__name__})")
        return TurnResult(False, [m.id for m in mails], note=why, backoff=float(self.cfg["failure_backoff_seconds"]))

    def record_reading(self) -> None:
        r = latest_reading(self.codex_home)
        if r is None:
            return
        log = self.codex_dir / "readings.tsv"
        log.parent.mkdir(parents=True, exist_ok=True)
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(f"{int(self.clock())}\t{self.seat}\t{r.used_percent:g}\t{r.window_minutes}\t{r.resets_at or ''}\n")

    # mail side effects --------------------------------------------------------------------------
    def _ack(self, m: Mail) -> None:
        """Move the mail to the archive the way `aimail ack` does (same layout). The worker is the
        mail's only reader, so the bulk-ack receipt check (which guards against acking unread mail)
        has nothing to guard here. A file that has already gone is fine."""
        shard = self.mail_dir / "archive" / time.strftime("%Y-%m", time.localtime(self.clock()))
        shard.mkdir(parents=True, exist_ok=True)
        try:
            os.replace(m.path, shard / m.path.name)
        except FileNotFoundError:
            pass

    def _send_via_cli(self, to: str, frm: str, subject: str, body: str, wake: bool = True) -> None:
        aimail = HOME / "bin" / "aimail"
        tmp = self.codex_dir / "outbox" / f"{int(self.clock())}-{os.getpid()}.md"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(body, encoding="utf-8")
        argv = [str(aimail), "send", "--to", to, "--from", frm, "--subject", subject, "--body-file", str(tmp)]
        if not wake:
            argv.append("--no-wake")
        try:
            subprocess.run(argv, check=True, capture_output=True, text=True, env=dict(self.environ), timeout=120)
        finally:
            tmp.unlink(missing_ok=True)

    def loop(self, interval: float, once: bool = False) -> int:   # pragma: no cover - the real loop
        if not self.acquire():
            print(f"refused: another reader already holds seat '{self.seat}' (a worker or a live poller)", file=sys.stderr)
            return 2
        started = self.clock()
        self.start_heartbeat(started)
        try:
            while True:
                try:
                    result = self.run_once()
                except Exception as exc:                  # a bug must slow the worker, not flap it
                    self._log(f"loop error: {type(exc).__name__}")
                    result = TurnResult(False, [], note="loop error", backoff=float(self.cfg["failure_backoff_seconds"]))
                if once:
                    return 0
                time.sleep(interval if result is None else (result.backoff or 1))
        finally:
            self.stop_heartbeat()
            self.heartbeat(started, exit_reason="stopped")
            self.close()


# ─── command line ───────────────────────────────────────────────────────────────────────────────
def _root() -> Path:
    return Path(os.environ.get("AIMAIL_ROOT") or (Path.home() / ".aimail"))


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="aimail codex")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("usage", help="the Codex account's weekly reading")
    sub.add_parser("pool-section", help="the block `aimail budget pool` appends")
    sub.add_parser("models", help="the tier table")
    sa = sub.add_parser("seat-add", help="host a seat on the Codex account")
    sa.add_argument("seat")
    sa.add_argument("--tier", required=True)
    sa.add_argument("--worktree", required=True)
    sa.add_argument("--senders", default="", help="comma list of seats whose mail this seat answers (empty = any registered)")
    wk = sub.add_parser("worker", help="run a hosted seat's mail loop")
    wk.add_argument("seat")
    wk.add_argument("--once", action="store_true")
    wk.add_argument("--interval", type=float, default=5.0)
    args = ap.parse_args(argv)
    cfg = load_config()
    now = time.time()
    if args.cmd in ("usage", "pool-section"):
        print("\n".join(pool_lines(latest_reading(), now, cfg)))
        return 0
    if args.cmd == "models":
        for tier, model in cfg["tier_models"].items():
            print(f"{tier}\t{model}")
        return 0
    worker = SeatWorker(args.seat, cfg=cfg, root=_root(), codex_home_dir=codex_home())
    if args.cmd == "seat-add":
        model_for_tier(cfg, args.tier)            # refuse an unknown tier now, not at the first mail
        wt = Path(args.worktree)
        if not wt.is_dir():
            print(f"refused: worktree {wt} is not a directory", file=sys.stderr)
            return 2
        settings = worker.seat_settings()
        settings.update({"tier": args.tier, "worktree": str(wt.resolve())})
        senders = [x for x in args.senders.split(",") if x]
        if senders:
            settings["senders"] = senders
        else:
            settings.pop("senders", None)
        worker.save_seat_settings(settings)
        print(f"seat {args.seat}: tier {args.tier} ({model_for_tier(cfg, args.tier)}), worktree {wt.resolve()}")
        return 0
    if args.cmd == "worker":
        return worker.loop(args.interval, once=args.once)
    return 2


if __name__ == "__main__":
    sys.exit(main())
