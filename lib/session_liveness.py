#!/usr/bin/env python3
# =============================================================================
#  session_liveness.py — TRUE PER-SESSION liveness, where every existing
#  instrument in this fleet could only answer PER SEAT NAME.
#
#  ⛔⛔ THE DEFECT THIS EXISTS TO KILL (2026-09-06, measured, cost a false
#     fleet-wide alarm to a human who then had to refute it by hand):
#     `poller_guard.sh status` printed 8 rows for seat "main", 7 for "audit",
#     4 for "fable", every one reading `seat-poller=LIVE`. There was ONE live
#     poller per seat. The liveness column took only a SEAT NAME, so a single
#     true reading was stamped onto every historical registration row of that
#     seat. Simultaneously `aimail fleet` called four OTHER seats STALLED —
#     which means "the poller exited and nothing re-armed it", a state a
#     perfectly healthy session mid-way through a 100-minute build produces
#     every single time.
#     ⇒ THREE GENUINELY DIFFERENT WORLDS RENDERED IDENTICALLY:
#         (a) a session that is alive and working, poller between cycles
#         (b) a session that ended normally days ago, registration never pruned
#         (c) a session that died and needs a human
#       Only (c) is actionable. The tooling could not name which was which, so
#       three separate seats each re-derived the same manual cross-check by
#       hand in one evening.
#
#  ⭐ THE FIX IS NOT A BETTER PROCESS SAMPLE. It is to key every signal to the
#     SESSION ID, which is the thing that is actually singular:
#
#     1. THE SESSION'S OWN CLAUDE PROCESS. `claude … --resume=<sid>` carries the
#        session id in its own cmdline. MEASURED 2026-09-06: 8 live sessions,
#        8 matching processes, exact 1:1.
#        ⚠ A session started FRESH (never resumed) has no `--resume`, so this
#          alone is not sufficient — see signal 3 and the ancestry bind below.
#
#  ⛔⛔ THE HOLE IN 1 AND 3, AND IT IS THE REASON `prune` CAN REFUSE (found by
#     fable in design review, 2026-09-06, before this shipped — measured, not
#     predicted): a FRESH session that is IDLE has neither signal. It carries no
#     `--resume` in its own cmdline (it was never resumed) and no
#     CLAUDE_CODE_SESSION_ID in its OWN environ — only its CHILDREN carry that,
#     and an idle session has no children to bind through. MEASURED on this box:
#     of 9 live claude CLI processes, 8 carried `--resume=<sid>` and exactly one
#     (a human's own open window) carried neither.
#     ⇒ Such a session reads DEAD after ACTIVE_WINDOW and STALE after
#       STALE_AFTER — at which point a pruner would DELETE its registration, and
#       its Stop hook becomes `allow-unregistered` FOREVER. That is a silent,
#       permanent pass-through, and silent is worse than wedged: nothing about
#       that state looks wrong from any angle.
#     ⇒ `unattributed_claude` below names every claude process we could not bind
#       to a session id. A CALLER THAT DELETES ANYTHING MUST REFUSE WHILE THAT
#       LIST IS NON-EMPTY (see PRUNABLE_STATES). Reporting is still fine — a
#       wrong label costs a second look; a wrong delete costs a deaf seat nobody
#       can see.
#
#  ⛔ AND THE ATTRIBUTION TRICK THAT DOES NOT WORK — MEASURED, so nobody spends
#     the afternoon on it again. The obvious rescue is to bind an unattributed
#     claude process to a session by finding the transcript it holds open via
#     `/proc/<pid>/fd`. IT DOES NOT HOLD ONE. Checked all 9 live claude
#     processes: ZERO have any `*.jsonl` descriptor open — Claude Code opens the
#     transcript, appends and closes. The only `.claude`-ish fd any of them has
#     is the VS Code extension's own log file, which is byte-identical across
#     every process and therefore has no discriminating power whatsoever.
#     ⇒ There is no known way to attribute an idle, never-resumed session from
#       outside it. Refusal is not a placeholder for a better signal; it is the
#       answer until the CLI itself exposes one.
#
#     2. THE SESSION'S OWN TRANSCRIPT. Claude Code appends to
#        `<config>/projects/<project-slug>/<sid>.jsonl` continuously while the
#        session works, whether or not it ever touches its mail poller. One file
#        per session id — inherently per-session, which the registration file is
#        not. MEASURED: the same 8 sessions, all < 3 min stale; every other
#        transcript on the box hours-to-weeks old, matching the seats' own
#        self-reports exactly.
#        ⛔ Transcript-quiet is NOT dead: a live session idling at a prompt
#          writes nothing. That is why signal 1 exists and why the two are OR-ed
#          for "alive", never AND-ed.
#
#     3. PROCESS ANCESTRY, which is what makes a poller attributable at all.
#        A harness-tracked poller's parent chain runs
#          bash …/aimail poll <seat>  →  /bin/bash -c …eval…  →  claude --resume=<sid>
#        so the poller belongs to a NAMED session, not merely to a seat name.
#        MEASURED, and this is the discriminating half: a poller (or any child)
#        left behind by a session that has since exited reparents to
#        `systemd --user` and NEVER reaches a claude process. So ancestry
#        separates "this live session's poller" from "a leftover process of a
#        dead one" — a distinction `pgrep -f 'poller.*<seat>'` cannot express.
#        Children also carry CLAUDE_CODE_SESSION_ID in their environment
#        (verified on the live poller processes), which is preferred when
#        present because it is exact rather than inferred.
#
#  ⚠ FAIL OPEN, AND SAY UNKNOWN RATHER THAN GUESS. Every unreadable /proc entry,
#    missing transcript directory or absent signal degrades one field, never the
#    whole reading, and a session we cannot measure is reported UNKNOWN — never
#    DEAD. This module is read by a pruner; "unmeasurable" must never round to
#    "safe to delete", because deleting a LIVE session's registration turns its
#    Stop hook into a permanent silent pass-through (`allow-unregistered`), and
#    that failure is invisible by construction.
#
#  ── I/O CONTRACT ────────────────────────────────────────────────────────────
#  stdin : one registration per line, TSV — `sid \t seat \t registered_epoch`
#          (the third field may be empty; it is only used to age a registration
#          that has no transcript at all)
#          WHY stdin and not a directory scan: every caller keeps its own
#          registration store (aimail's `state/stopguard/session.<sid>`, the
#          project fork's `_stophook/seat_<sid>`, and any future one). Which
#          files are registrations is the CALLER's knowledge; what state a
#          session is in is THIS module's. Splitting them there means neither
#          side has to learn the other's private layout — the same boundary
#          `session.sh::_session_fork_registered` already draws by asking the
#          fork rather than reading its state dir.
#  stdout: one JSON object (see `main`).
#
#  ── STATES ──────────────────────────────────────────────────────────────────
#    ARMED    session alive AND owns a live harness-tracked poller  → reachable
#    WORKING  session alive, transcript moving, no poller this instant
#             → NORMAL. The poller exits on delivery by design; a working
#               session is pollerless for part of every cycle. Do not nudge.
#    UNARMED  session process alive but transcript quiet AND no poller
#             → alive and DEAF. Mail cannot wake it. Actionable, not dead.
#    ORPHANED a live poller whose owning session is gone → it will consume a
#             wake nobody receives. Actionable.
#    DEAD     no process, no poller, last activity inside the stale horizon
#             → THE ONLY "restart this seat" state.
#    STALE    no process and last activity older than the stale horizon
#             → historical registration noise. Excluded from every concurrency
#               count, and the only state the pruner will remove.
#    UNKNOWN  not measurable (no transcript found and the registration is too
#             young to call it abandoned) → never counted, never pruned.
# =============================================================================
import argparse
import glob
import json
import os
import re
import sys
import time

# How long a transcript may be quiet before a session stops counting as
# "currently working". Deliberately generous: the failure of a SHORT window is
# to call a heads-down session idle, which is the exact false alarm this file
# exists to kill.
DEFAULT_ACTIVE_WINDOW = 15 * 60
# How old the last activity must be before a registration is noise rather than
# a dead session someone should look at. A day, because a session left open
# overnight and resumed in the morning is normal here and must not be pruned.
DEFAULT_STALE_AFTER = 24 * 60 * 60


# ─── /proc access, each call independently fail-open ─────────────────────────
def _read(path, binary=False):
    try:
        with open(path, "rb" if binary else "r") as f:
            return f.read()
    except OSError:
        return None


def _cmdline(pid):
    raw = _read("/proc/%d/cmdline" % pid, binary=True)
    if raw is None:
        return None
    return raw.replace(b"\0", b" ").decode(errors="replace").strip()


def _ppid(pid):
    st = _read("/proc/%d/status" % pid)
    if st is None:
        return None
    for line in st.splitlines():
        if line.startswith("PPid:"):
            try:
                return int(line.split()[1])
            except (IndexError, ValueError):
                return None
    return None


def _env_sid(pid):
    """CLAUDE_CODE_SESSION_ID out of a process's own environment.

    ⚠ PRESENCE OF THE VARIABLE IS NOT PROOF THE SESSION LIVES. Measured on this
      box: three long-abandoned session ids were still carried by orphaned
      worker processes reparented to systemd. This value says WHOSE the process
      is, never that the owner is alive — the ancestry walk answers that.
    """
    raw = _read("/proc/%d/environ" % pid, binary=True)
    if raw is None:
        return None
    for kv in raw.decode(errors="replace").split("\0"):
        if kv.startswith("CLAUDE_CODE_SESSION_ID="):
            return kv.split("=", 1)[1] or None
    return None


# The Claude Code CLI's own process. Matched on the FIRST token's basename so a
# command that merely mentions the word (this script's own invocation, a grep,
# an editor) can never qualify — the same anchoring discipline poller_guard.sh
# had to learn three times in one night after a loose pattern matched the
# checking command itself.
# ⚠ NOT ANCHORED TO A UUID SHAPE. Session ids are UUIDs today, and a
#   `[0-9a-f-]{36}` pattern would be tighter — but it would also silently stop
#   matching the day the id format changes, and the failure would present as
#   "every session is dead", which is the loudest possible wrong answer. A
#   generic token is safe here because the captured value is only ever used as a
#   KEY to look up against a registration and a transcript filename: a value
#   that is not really a session id simply matches nothing.
_RESUME_RE = re.compile(r"--resume[= ]([A-Za-z0-9][A-Za-z0-9_.-]{7,})")


def _is_claude_cli(cmd):
    if not cmd:
        return False
    first = cmd.split(" ", 1)[0]
    return os.path.basename(first) == "claude"


# The poller invocation, in both shapes this fleet has ever launched:
#   bash …/poller.sh <seat>      (retired channel, kept so an old one is still seen)
#   [bash] …/aimail poll <seat>  (current; the leading `bash` is OPTIONAL because
#                                 the skill's instructed form is an absolute path
#                                 run as an executable — a mandatory `bash\s+`
#                                 here is precisely what false-BLOCKed the fable
#                                 seat on 2026-09-03.)
_POLLER_RE = re.compile(
    r"^(?:/bin/)?(?:bash\s+)?\S*(?:poller\.sh\s+(?P<a>[A-Za-z0-9_.-]+)(?:\s|$)"
    # ⛔⛔ THE LEGACY `poller_<seat>.sh` FORM IS ANCHORED TO END-OF-COMMAND, and
    #   that is not tidiness — it is the fix for a self-match this file committed
    #   and the live run caught within a minute. Unanchored, this alternative
    #   matches `bash .claude/hooks/poller_guard.sh status`: it reads
    #   "poller_" + "guard" + ".sh" and reports a poller for a seat named
    #   `guard`. Two of the CHECKER'S OWN processes were then attributed to the
    #   session running the check, which printed a bogus "2 pollers for ONE
    #   session" warning against a perfectly healthy row.
    #   ⇒ The retired poller took NO arguments (`bash …/poller_main.sh`), while
    #     every invocation of the guard has a verb after it. Requiring
    #     end-of-command separates them exactly, and it fails in the safe
    #     direction: the worst case is missing a poller on a channel that was
    #     retired 2026-08-11, versus inventing one on a script that runs on every
    #     Stop of every seat.
    #   ⚠ FOURTH TIME THIS FAMILY HAS BITTEN in this codebase — poller_guard.sh's
    #     own header records the other three, all "the checker counted itself".
    #     `_exclude_self` below is the second, independent guard against it.
    r"|poller_(?P<b>[A-Za-z0-9_.-]+)\.sh\s*$"
    # `poll-persistent` too (2026-09-10, ahead of the fleet-wide switch): same
    # re-exec-from-a-private-copy shape as plain `poll` (measured live), just a
    # different verb -- both must classify as a real poller during rollout.
    r"|aimail\s+poll(?:-persistent)?\s+(?P<c>[A-Za-z0-9_.-]+)(?:\s|$))"
)

# Any process running the Stop-hook guard itself is never a poller, whatever its
# name pattern suggests. Belt to the anchor's braces: the anchor stops the one
# shape we found, this stops the family.
_NOT_A_POLLER = re.compile(r"poller_guard\.sh(?:\s|$)")


def _poller_seat(cmd):
    """The seat a process is polling for, or None if it is not a poller.

    ⛔ ANCHORED (`^`) ON PURPOSE. An unanchored search matches the harness
      WRAPPER too (`/bin/bash -c … eval '… aimail poll main'`), and the wrapper
      is not itself the poller — counting both doubles every seat's poller
      count, which is exactly the T-351 trap that makes a bare `pgrep -cf`
      unable to tell one healthy poller from two.
    """
    if not cmd or _NOT_A_POLLER.search(cmd):
        return None
    m = _POLLER_RE.match(cmd)
    if not m:
        return None
    return m.group("a") or m.group("b") or m.group("c")


class ProcTable(object):
    """A snapshot of every process this user can see, plus the derived binds.

    Taken ONCE. Two /proc walks a second apart disagree about a poller that
    exited between them, and a report whose fields come from different instants
    is exactly the kind of internally-inconsistent reading that started this.
    """

    def __init__(self, fake=None):
        self.cmd = {}
        self.parent = {}
        self.env_sid = {}
        self.measurable = True
        self._mine_cache = None
        self._pollers_cache = None
        # A fixture process table has no relationship to this python process, so
        # excluding "my" pids from it would silently drop fixture rows whose
        # numbers happened to collide with a real ancestor pid.
        self._faked = fake is not None
        if fake is not None:
            self._load_fake(fake)
        else:
            self._load_proc()
        self.claude_pids = {p for p, c in self.cmd.items() if _is_claude_cli(c)}
        # sid -> pid, for a session started with --resume (the common case here)
        self.resumed = {}
        for p in self.claude_pids:
            m = _RESUME_RE.search(self.cmd.get(p) or "")
            if m:
                self.resumed[m.group(1)] = p
        # A FRESH session's claude process carries no --resume, so bind it from
        # any child that does carry the id in its environment AND whose ancestry
        # actually reaches that claude process. Without the ancestry condition
        # an orphaned worker of a long-dead session would resurrect it.
        for p, sid in self.env_sid.items():
            if not sid or sid in self.resumed:
                continue
            root = self.claude_ancestor(p)
            if root is not None:
                self.resumed[sid] = root

    def _load_fake(self, path):
        """Fixture seam: pid \t ppid \t cmdline \t sid  (sid may be empty).

        ⛔ THE REAL REGEXES AND THE REAL WALK RUN AGAINST THIS. Never a
          hand-copied pattern in the test — a copy drifts from the code and then
          passes while the code is broken, which this fleet has now paid for on
          three separate guards.
        """
        data = _read(path)
        if data is None:
            self.measurable = False
            return
        for line in data.splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            while len(parts) < 4:
                parts.append("")
            try:
                pid, ppid = int(parts[0]), int(parts[1])
            except ValueError:
                continue
            self.cmd[pid] = parts[2]
            self.parent[pid] = ppid
            if parts[3]:
                self.env_sid[pid] = parts[3]

    def _load_proc(self):
        try:
            pids = [int(p) for p in os.listdir("/proc") if p.isdigit()]
        except OSError:
            self.measurable = False
            return
        for pid in pids:
            cmd = _cmdline(pid)
            if cmd is None:
                continue          # exited between listdir and read — normal
            self.cmd[pid] = cmd
            pp = _ppid(pid)
            if pp is not None:
                self.parent[pid] = pp
            # environ is the expensive read, so only where it can matter:
            # a poller, or a direct child of something that could be a session.
            if _poller_seat(cmd) or "aimail" in cmd or "claude" in cmd:
                sid = _env_sid(pid)
                if sid:
                    self.env_sid[pid] = sid

    def ancestors(self, pid, limit=40):
        seen = []
        cur = pid
        while cur and cur != 1 and len(seen) < limit:
            seen.append(cur)
            nxt = self.parent.get(cur)
            if nxt is None or nxt in seen:
                break
            cur = nxt
        return seen

    def claude_ancestor(self, pid):
        """The live claude-CLI process this pid descends from, or None.

        ⚠ STATED BOUND, inherited knowingly from poller_guard.sh's own note: a
          poller DETACHED with `&` inside a tool call still descends from the
          live wrapper for as long as that call runs, and so reads as tracked
          during that window. In production the reading is taken after the call
          returns, the wrapper is gone, the process has reparented to systemd,
          and the verdict is right. Recorded rather than patched, because the
          fragile alternative (sniffing for `setsid`/`&` near the match) trades
          a rare understood blind spot for an unpredictable one.
        """
        for a in self.ancestors(pid)[1:]:
            if a in self.claude_pids:
                return a
        return None

    def sid_of(self, pid):
        """Whose session this process belongs to: its own env first, then the
        session id of the claude process it descends from."""
        sid = self.env_sid.get(pid)
        if sid:
            return sid
        root = self.claude_ancestor(pid)
        if root is None:
            return None
        for s, p in self.resumed.items():
            if p == root:
                return s
        return None

    def _mine(self):
        """This process and its ancestors — never countable as pollers.

        ⛔ THE CHECKER MUST NEVER COUNT ITSELF. poller_guard.sh's header records
          three separate bugs of exactly this shape in one night, each one a
          pollerless seat reading as healthy because the checking shell matched
          the pattern it was checking for. That script excludes its own ancestry
          for this reason and so does this one — the caller here is typically
          `bash …/poller_guard.sh status`, whose whole command line is a poller
          pattern's worst nightmare.
        """
        if self._mine_cache is None:
            self._mine_cache = set() if self._faked else set(self.ancestors(os.getpid()))
        return self._mine_cache

    def pollers(self):
        """Every live poller process, with its seat, owner session and whether
        it is harness-TRACKED (i.e. can actually wake anybody)."""
        if self._pollers_cache is not None:
            return self._pollers_cache
        out = []
        mine = self._mine()
        for pid, cmd in self.cmd.items():
            if pid in mine:
                continue
            seat = _poller_seat(cmd)
            if not seat:
                continue
            root = self.claude_ancestor(pid)
            out.append({
                "pid": pid,
                "seat": seat,
                "sid": self.sid_of(pid),
                "tracked": root is not None,
                "cmd": cmd[:160],
            })
        # Cached: `classify` is called once per registration and would otherwise
        # re-walk every ancestry chain 46 times over for one report.
        self._pollers_cache = out
        return out


# ─── Transcripts ─────────────────────────────────────────────────────────────
def transcript_index(projects_dirs):
    """sid -> (newest_mtime, transcript_path, account_label) across every root.

    NEWEST across project dirs, because a session id is unique but the same box
    holds several project slugs and this fleet has already moved its checkout
    once (both `-mnt-workdrive-…` and `-home-sudolime-…` slugs hold live
    registrations today). Scanning one slug would report every session of the
    other as having no transcript at all — an absence manufactured by the
    search, not found in the world.

    ⛔⛔ AND ONE ROOT IS NOT ENOUGH, found 2026-09-24: this fleet runs one seat
      across SEVERAL ACCOUNTS, each with its OWN `~/.claude-<account>/projects/`
      tree, entirely separate from every other account's. A caller that only
      passed its OWN account's root (the single-`projects_dir` shape this
      function used to take) silently manufactured "no transcript" for every
      session on any OTHER account — measured as `aimail context` reporting 6
      genuinely live seats "unmeasurable", and a 7th (framing) reporting a
      STOPPED sibling session's stale number because that was the only one of
      its two registrations whose transcript this box's default root could see.
      `projects_dirs` therefore takes MULTIPLE roots (a single path string for
      backward compatibility, or an iterable of `(account_label, path)` pairs /
      bare path strings) and merges newest-wins across ALL of them, the same
      way it already merged newest-wins across project slugs within one root.
    """
    if not projects_dirs:
        return None
    if isinstance(projects_dirs, str):
        roots = [("", projects_dirs)]
    else:
        roots = [(r[0], r[1]) if isinstance(r, (tuple, list)) else ("", r)
                 for r in projects_dirs]
    idx = {}
    any_dir = False
    for label, root in roots:
        if not root or not os.path.isdir(root):
            continue
        any_dir = True
        for path in glob.glob(os.path.join(root, "*", "*.jsonl")):
            sid = os.path.basename(path)[:-len(".jsonl")]
            try:
                mt = os.path.getmtime(path)
            except OSError:
                continue
            if sid not in idx or mt > idx[sid][0]:
                idx[sid] = (mt, path, label)
    if not any_dir:
        return None                      # UNMEASURABLE, distinctly from empty
    return idx


# ─── The classification ──────────────────────────────────────────────────────
def classify(sid, seat, reg_epoch, procs, transcripts, now,
             active_window, stale_after):
    tr_age = None
    tr_path = None
    tr_account = None
    if transcripts is not None and sid in transcripts:
        mt, tr_path, tr_account = transcripts[sid]
        tr_age = max(0, int(now - mt))

    proc_pid = procs.resumed.get(sid)
    # ⚠ TWO DIFFERENT SETS, AND COLLAPSING THEM WAS A REAL BUG CAUGHT BY THE
    #   SELFTEST'S OWN ORPHAN ARM. `own_all` is every poller process carrying
    #   this session's id; `own` is only those that still descend from a live
    #   claude process and can therefore actually wake somebody. A poller in the
    #   first set but not the second is precisely an ORPHAN — and judging
    #   "armed" off `own_all` would report a dead session as reachable.
    own_all = [p for p in procs.pollers() if p["sid"] == sid]
    own = [p for p in own_all if p["tracked"]]
    armed = bool(own)
    fresh = tr_age is not None and tr_age <= active_window

    if proc_pid is not None or fresh:
        if armed:
            state = "ARMED"
            detail = "session process alive; poller pid %s armed for '%s'" % (
                own[0]["pid"], own[0]["seat"])
        elif fresh:
            state = "WORKING"
            detail = ("transcript written %ss ago — the session is mid-turn. "
                      "A pollerless moment is NORMAL: the poller exits on "
                      "delivery." % tr_age)
        else:
            state = "UNARMED"
            detail = ("claude process %s is alive but the transcript has been "
                       "quiet %s and no poller is armed — alive and DEAF"
                       % (proc_pid, _dur(tr_age)))
    elif own_all:
        # A poller with no live session behind it consumes a wake nobody
        # receives — the mail is delivered, marked delivered, and the seat it
        # was addressed to never learns of it.
        state = "ORPHANED"
        detail = ("poller pid %s is polling '%s' but its session has exited — "
                  "it will swallow a delivery and wake nobody"
                  % (own_all[0]["pid"], own_all[0]["seat"]))
    elif tr_age is None:
        age = None if not reg_epoch else int(now - reg_epoch)
        if age is not None and age > stale_after:
            state = "STALE"
            detail = ("no transcript on this box and the registration is %s "
                      "old — historical noise" % _dur(age))
        else:
            state = "UNKNOWN"
            detail = ("no transcript found for this session id and it is too "
                      "recent to call abandoned — NOT a claim that it is dead")
    elif tr_age > stale_after:
        state = "STALE"
        detail = "last transcript activity %s ago — historical noise" % _dur(tr_age)
    else:
        state = "DEAD"
        detail = ("no claude process, no poller, and nothing written to its "
                  "transcript for %s" % _dur(tr_age))

    return {
        "sid": sid,
        "seat": seat,
        "state": state,
        "detail": detail,
        "proc_pid": proc_pid,
        "transcript_age": tr_age,
        "transcript": tr_path,
        "account": tr_account,
        "registered_epoch": reg_epoch,
        "pollers": [{"pid": p["pid"], "seat": p["seat"]} for p in own],
        # A session registered to one seat while polling another is a real,
        # silent misconfiguration: its Stop guard checks seat A, its mail comes
        # from seat B. Surfaced rather than left for a reader to spot.
        "poller_seat_mismatch": bool(
            own and seat and own[0]["seat"] != seat),
    }


def _dur(secs):
    if secs is None:
        return "an unknown time"
    if secs < 90:
        return "%ds" % secs
    if secs < 90 * 60:
        return "%dm" % (secs // 60)
    if secs < 48 * 3600:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


# States in which the session is a REAL concurrent session of its seat. This is
# the set that answers "how many sessions of this seat exist", the number that
# was reported as 8 when it was 1.
LIVE_STATES = ("ARMED", "WORKING", "UNARMED")
# The only state the pruner may act on. DEAD is deliberately excluded: a human
# has to see a dead seat before its registration disappears, or the report that
# says "restart this" erases its own evidence.
#
# ⛔⛔ AND STALE ALONE IS NOT A LICENCE TO DELETE. A pruner must ALSO check that
#   `unattributed_claude` is empty — see the header. An idle, never-resumed
#   session is invisible to every signal here, so while any unbound claude
#   process exists on the box, ANY STALE row could be that session's, and
#   "which one" is exactly the question we cannot answer. Refuse the whole
#   operation rather than delete a set we know contains a possible live member.
#   ⇒ This is the module's own stated philosophy applied to the one caller that
#     acts destructively: unmeasurable never rounds to safe.
PRUNABLE_STATES = ("STALE",)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    ap.add_argument("--active-window", type=int,
                    default=int(os.environ.get("AIMAIL_SESSION_ACTIVE_WINDOW",
                                               DEFAULT_ACTIVE_WINDOW)))
    ap.add_argument("--stale-after", type=int,
                    default=int(os.environ.get("AIMAIL_SESSION_STALE_AFTER",
                                               DEFAULT_STALE_AFTER)))
    ap.add_argument("--projects-dir",
                    default=os.environ.get(
                        "AIMAIL_SESSION_PROJECTS_DIR",
                        os.path.join(os.environ.get(
                            "CLAUDE_CONFIG_DIR",
                            os.path.expanduser("~/.claude")), "projects")))
    ap.add_argument("--projects-dirs",
                    default=os.environ.get("AIMAIL_SESSION_PROJECTS_DIRS", ""),
                    help="colon-separated label=path roots, merged in ADDITION to "
                         "--projects-dir (one entry per fleet account's own projects/ tree)")
    ap.add_argument("--fake-procs",
                    default=os.environ.get("AIMAIL_SESSION_FAKE_PROCS"),
                    help="fixture seam: a TSV process table instead of /proc")
    ap.add_argument("--now", type=float,
                    default=float(os.environ.get("AIMAIL_SESSION_FAKE_NOW", 0)) or None)
    args = ap.parse_args(argv)

    now = args.now if args.now else time.time()
    procs = ProcTable(args.fake_procs)
    roots = []
    if args.projects_dir:
        roots.append(("", args.projects_dir))
    for entry in args.projects_dirs.split(":"):
        entry = entry.strip()
        if not entry:
            continue
        label, _, path = entry.partition("=")
        roots.append((label, path) if path else ("", label))
    transcripts = transcript_index(roots)

    regs = []
    seen = set()
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 3:
            parts.append("")
        sid = parts[0].strip()
        if not sid or sid in seen:
            continue
        seen.add(sid)
        try:
            reg = int(float(parts[2])) if parts[2].strip() else None
        except ValueError:
            reg = None
        regs.append((sid, parts[1].strip(), reg))

    sessions = [classify(sid, seat, reg, procs, transcripts, now,
                         args.active_window, args.stale_after)
                for sid, seat, reg in regs]
    sessions.sort(key=lambda s: (s["seat"], s["state"], s["sid"]))

    live_by_seat = {}
    # ⚠ AND THE FULL BREAKDOWN, NOT JUST THE TOTAL. `fleet.sh` has to gate an
    #   unattended alert on this, and "the seat has a live session" is too
    #   coarse for that: a WORKING session explains a down poller (it is
    #   mid-turn), whereas an UNARMED one is itself the problem being reported.
    #   A caller that can only read the total would have to suppress both or
    #   neither. Publishing the breakdown lets each caller name the exact
    #   population its own rule is about.
    by_seat_state = {}
    for s in sessions:
        by_seat_state.setdefault(s["seat"], {})
        by_seat_state[s["seat"]][s["state"]] = \
            by_seat_state[s["seat"]].get(s["state"], 0) + 1
        if s["state"] in LIVE_STATES:
            live_by_seat[s["seat"]] = live_by_seat.get(s["seat"], 0) + 1

    # A live session that never registered: its Stop hook fires
    # `allow-unregistered` forever and nothing about that state looks wrong.
    # This is the 2026-09-03 architect incident (see lib/session.sh's header),
    # detectable here for free because we enumerate sessions, not seats.
    registered = {s["sid"] for s in sessions}
    unregistered = []
    for sid, pid in sorted(procs.resumed.items()):
        if sid in registered:
            continue
        tr = transcripts.get(sid) if transcripts else None
        polls = sorted({p["seat"] for p in procs.pollers()
                        if p["sid"] == sid and p["tracked"]})
        unregistered.append({
            "sid": sid, "proc_pid": pid,
            "transcript_age": int(now - tr[0]) if tr else None,
            "polling": polls,
        })

    orphans = [{"pid": p["pid"], "seat": p["seat"], "sid": p["sid"]}
               for p in procs.pollers() if not p["tracked"]]

    # ⛔⛔ THE BLIND SPOT, NAMED IN THE OUTPUT so a destructive caller can refuse
    #   on it. Every claude CLI process we could NOT bind to a session id: no
    #   `--resume` in its cmdline and no child carrying CLAUDE_CODE_SESSION_ID
    #   whose ancestry reaches it. Each one MIGHT be a fresh idle session that
    #   owns one of the STALE registrations below, and nothing available from
    #   outside the process can say which. See the header for the measurement,
    #   and for why the /proc/<pid>/fd rescue does not exist.
    bound = set(procs.resumed.values())
    unattributed = [{"pid": p, "cmd": (procs.cmd.get(p) or "")[:120]}
                    for p in sorted(procs.claude_pids) if p not in bound]

    out = {
        "now": int(now),
        "measurable": procs.measurable,
        "transcripts_measurable": transcripts is not None,
        "projects_dir": args.projects_dir,
        "active_window": args.active_window,
        "stale_after": args.stale_after,
        "sessions": sessions,
        "live_by_seat": live_by_seat,
        "by_seat_state": by_seat_state,
        "unregistered_live": unregistered,
        "untracked_pollers": orphans,
        "unattributed_claude": unattributed,
        # Spelled out as its own boolean so no caller has to re-derive the rule.
        # A reader that only looked at `sessions[].state` would never see it.
        "prune_safe": not unattributed,
    }
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
