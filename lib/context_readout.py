#!/usr/bin/env python3
# =============================================================================
#  context_readout.py — a session's own current CONTEXT SIZE, read from its
#  transcript, never estimated.
#
#  WHY THIS EXISTS (owner's ask, 2026-09-23, relayed by the assistant): fleet
#  cost is ~all cache reads -- every turn re-reads the whole context, so a
#  seat sitting at 800k+ tokens costs roughly double what one at 400k does,
#  every single turn, regardless of how much real work either is doing. The
#  fix (`/autocompact <tokens>` or the account's own settings.json
#  `autoCompactWindow`) already exists and applies live; what was missing is
#  simply SEEING which seats are large BEFORE the fleet decides who needs it.
#
#  ⛔⛔ THIS IS NOT A TOKEN COUNTER, IT IS A TRANSCRIPT READER. The number
#    Claude Code itself reports as remaining/used budget each turn -- the
#    same one a session sees printed as "<total_tokens>N tokens left</...>"
#    -- is DERIVED from exactly the fields this module reads off the LAST
#    real assistant turn's own `usage` block: `input_tokens` +
#    `cache_creation_input_tokens` + `cache_read_input_tokens`. Summing these
#    three (never `output_tokens`, which is what the turn PRODUCED, not what
#    it had to re-read to get there) is the same arithmetic the harness
#    itself uses for cache-cost accounting, not a separate estimate that
#    could disagree with it.
#
#  ⚠ "LAST REAL ASSISTANT TURN", NOT "LAST assistant-typed LINE": a
#    transcript line whose own `message.model` reads `"<synthetic>"` is a
#    system-injected marker (compaction boundary, tool-result echo, etc.),
#    never a real model turn, and ALWAYS carries all-zero usage — summing it
#    in would silently report a freshly-compacted session as still huge, or
#    a real session as empty, depending on where in the file it landed.
#    Skipped explicitly, not by the zero-sum happening to net out right.
#
#  ⚠ READ THE TAIL, NEVER THE WHOLE FILE. A working session's own transcript
#    accumulates one line per turn (tool calls, tool results, the full text
#    of every message) and can reach tens of megabytes over a long session;
#    loading it whole to find the LAST relevant line is real, avoidable I/O
#    on every fleet-wide dashboard read. `read_last_usage` seeks backward
#    from EOF in growing chunks (see `_TAIL_CHUNKS`) and stops at the first
#    chunk that contains a real usage line -- correct regardless of how long
#    any single line is, and cheap for the overwhelmingly common case where
#    the last turn is within the first chunk read.
# =============================================================================
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

# Chunks tried, growing, before giving up. 256KiB covers the overwhelming
# majority of single turns (even a large tool result rarely exceeds this);
# the later, larger chunks exist for the genuine outlier without paying their
# cost on every ordinary read.
_TAIL_CHUNKS = (256 * 1024, 2 * 1024 * 1024, 16 * 1024 * 1024)

_USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


def _real_usage_from_line(line: str):
    """The line's own `{"input_tokens", "cache_creation_input_tokens",
    "cache_read_input_tokens"}` dict if this line is a REAL (non-synthetic)
    assistant turn carrying a `usage` block, else `None`. Never raises on a
    malformed or partial line (a tail-chunk read can start mid-line) -- that
    is a normal, expected input here, not an error."""
    line = line.strip()
    if not line:
        return None
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict) or obj.get("type") != "assistant":
        return None
    message = obj.get("message")
    if not isinstance(message, dict):
        return None
    if message.get("model") == "<synthetic>":
        return None
    usage = message.get("usage")
    if not isinstance(usage, dict):
        return None
    out = {}
    for field in _USAGE_FIELDS:
        v = usage.get(field)
        if not isinstance(v, int):
            return None  # a real turn always carries all three as integers
        out[field] = v
    return out


def read_last_usage(path: str):
    """The last REAL assistant turn's own usage in the transcript at `path`,
    as `{"input_tokens", "cache_creation_input_tokens",
    "cache_read_input_tokens", "context_tokens"}` (the last field is the sum
    of the first three -- the number that actually drives cache cost), or
    `None` if the file is missing, empty, or carries no real assistant turn
    at all (e.g. a session that has only ever seen synthetic/system lines).

    `None` is a genuine, distinct answer from "some real reading of zero" --
    a caller must not treat it as 0, the same discipline `session_liveness.
    py`'s own UNKNOWN/DEAD distinction already applies one layer up.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    if size == 0:
        return None

    for chunk_size in _TAIL_CHUNKS:
        read_from = max(0, size - chunk_size)
        try:
            with open(path, "rb") as f:
                f.seek(read_from)
                data = f.read()
        except OSError:
            return None
        text = data.decode("utf-8", errors="replace")
        lines = text.splitlines()
        # The chunk may start mid-line (we seeked into the middle of the
        # file) -- drop a possibly-truncated first fragment UNLESS this
        # chunk covers the whole file (read_from == 0), in which case the
        # first line is complete and must be kept.
        if read_from > 0 and lines:
            lines = lines[1:]
        for line in reversed(lines):
            usage = _real_usage_from_line(line)
            if usage is not None:
                usage["context_tokens"] = sum(usage[f] for f in _USAGE_FIELDS)
                return usage
        if read_from == 0:
            break  # already read the whole file; growing further is pointless
    return None


def selftest():
    failures = []

    def check(name, cond):
        if cond:
            print("  ✔ %s" % name)
        else:
            failures.append(name)
            print("  ✖ %s" % name)

    with tempfile.TemporaryDirectory() as d:
        # ── the ordinary case: last real turn wins, synthetic ones ignored ──
        p = os.path.join(d, "a.jsonl")
        with open(p, "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {
                "model": "claude-x", "usage": {
                    "input_tokens": 2, "cache_creation_input_tokens": 100,
                    "cache_read_input_tokens": 900, "output_tokens": 50}}}) + "\n")
            f.write(json.dumps({"type": "assistant", "message": {
                "model": "<synthetic>", "usage": {
                    "input_tokens": 0, "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0, "output_tokens": 0}}}) + "\n")
            f.write(json.dumps({"type": "user", "message": {"content": "hi"}}) + "\n")
        got = read_last_usage(p)
        check("the last REAL (non-synthetic) usage wins, trailing non-assistant lines skipped",
              got is not None and got["context_tokens"] == 2 + 100 + 900)

        # ── only-synthetic transcript: None, not a fabricated zero ──
        p2 = os.path.join(d, "b.jsonl")
        with open(p2, "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {
                "model": "<synthetic>", "usage": {
                    "input_tokens": 0, "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0}}}) + "\n")
        check("an only-synthetic transcript reads None, never a fabricated 0",
              read_last_usage(p2) is None)

        # ── missing file: None, no exception ──
        check("a missing file reads None without raising",
              read_last_usage(os.path.join(d, "does-not-exist.jsonl")) is None)

        # ── empty file: None ──
        p3 = os.path.join(d, "empty.jsonl")
        open(p3, "w").close()
        check("an empty file reads None", read_last_usage(p3) is None)

        # ── malformed trailing line (a tail read starting mid-line) is
        #    tolerated, and the real line before it is still found ──
        p4 = os.path.join(d, "c.jsonl")
        with open(p4, "w") as f:
            f.write(json.dumps({"type": "assistant", "message": {
                "model": "claude-x", "usage": {
                    "input_tokens": 5, "cache_creation_input_tokens": 10,
                    "cache_read_input_tokens": 20}}}) + "\n")
        with open(p4, "rb") as f:
            whole = f.read()
        # Simulate a chunk-boundary landing mid-line by reading from a byte
        # offset partway through the (only) line, exactly as the real tail
        # read does when the file is larger than the smallest chunk.
        got4 = None
        try:
            orig_chunks = list(_TAIL_CHUNKS)
            globals()["_TAIL_CHUNKS"] = (max(1, len(whole) - 10),) + tuple(orig_chunks)
            got4 = read_last_usage(p4)
        finally:
            globals()["_TAIL_CHUNKS"] = tuple(orig_chunks)
        check("a chunk read starting mid-line does not crash and still finds the "
              "next real line on a wider retry", got4 is not None)

    return failures


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--selftest", action="store_true",
                    help="run the synthetic-fixture self-test and exit")
    ap.add_argument("--transcript", help="read exactly one transcript path, print its usage JSON")
    args = ap.parse_args(argv)

    if args.selftest:
        failures = selftest()
        if failures:
            print("%d FAILED" % len(failures), file=sys.stderr)
            return 1
        print("0 FAILED", file=sys.stderr)
        return 0

    if args.transcript:
        got = read_last_usage(args.transcript)
        json.dump(got, sys.stdout)
        print()
        return 0

    # Default: stdin is `sid \t seat \t transcript_path [\t account \t age_s]`
    # per line (mirrors session_liveness.py's own registration TSV contract, so
    # a caller that already has that shape from `aimail sessions --json` can
    # pipe it straight through without reshaping it first). The trailing
    # account/age columns are optional -- a 3-field line still works exactly as
    # before. Emits one JSON object, keyed by sid,
    # `{sid: {seat, account, age_s, ...usage-or-null}}`.
    out = {}
    for line in sys.stdin.read().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 5:
            parts.append("")
        sid, seat, path, account, age_s = (p.strip() for p in parts[:5])
        if not sid:
            continue
        usage = read_last_usage(path) if path else None
        entry = {"sid": sid, "seat": seat, "account": account or None,
                  "age_s": int(age_s) if age_s.isdigit() else None}
        entry.update(usage or {})
        out[sid] = entry
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
