#!/usr/bin/env bash
# tests/c7_replay.sh — REPLAY proof for hooks/secret_read_guard.sh: run the guard over
# every real Bash tool_use command actually issued in the last N days of Claude Code
# transcripts, and report how many it would have denied. Required proof before gating
# the guard (a guard that blocks the whole fleet's Bash tool on a false positive is
# worse than the leak it's meant to catch): target is ZERO false denies.
#
# Usage: tests/c7_replay.sh [days] [account-glob-root]
#   days: how many days back to scan transcripts for (default 7).
#   account-glob-root: parent dir whose */projects/**/*.jsonl to scan
#                       (default: the real HOME, i.e. every ~/.claude-*/projects).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
GUARD="$REPO/hooks/secret_read_guard.sh"
DAYS="${1:-7}"
ROOT="${2:-$HOME}"

[[ -x "$GUARD" ]] || { echo "✖ guard not found or not executable: $GUARD" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/c7_replay.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cmds_file="$WORK/commands.jsonl"   # one JSON string per line (still JSON-encoded, so
                                    # embedded newlines/quotes survive a plain read)

echo "▶ scanning for *.jsonl transcripts modified in the last $DAYS day(s) under $ROOT/.claude-*/projects"
find "$ROOT"/.claude-*/projects -name '*.jsonl' -mtime "-$DAYS" 2>/dev/null > "$WORK/files.txt"
n_files=$(wc -l < "$WORK/files.txt")
echo "  $n_files transcript file(s) found"

: > "$cmds_file"
while IFS= read -r f; do
  jq -c 'select(.message.content != null) | .message.content[]?
         | select(.type=="tool_use" and .name=="Bash") | .input.command // empty
         | select(. != "")' "$f" 2>/dev/null >> "$cmds_file" || true
done < "$WORK/files.txt"

if [[ "${C7_REPLAY_ONLY_MULTILINE:-0}" == "1" ]]; then
  grep -F '\n' "$cmds_file" > "$cmds_file.ml" || true
  mv "$cmds_file.ml" "$cmds_file"
fi

if [[ -n "${C7_REPLAY_FILTER:-}" ]]; then
  grep -E "$C7_REPLAY_FILTER" "$cmds_file" > "$cmds_file.f" || true
  mv "$cmds_file.f" "$cmds_file"
fi

total=$(wc -l < "$cmds_file")
echo "  $total real Bash command(s) extracted"
echo

denied_file="$WORK/denied.txt"
: > "$denied_file"
denied=0
i=0
while IFS= read -r json_cmd; do
  i=$((i+1))
  (( i % 10000 == 0 )) && echo "  ...${i}/${total}" >&2
  # json_cmd is already a JSON string (quoted); wrap it directly, no re-escaping needed.
  out="$(jq -cn --argjson c "$json_cmd" '{tool_name:"Bash",tool_input:{command:$c}}' 2>/dev/null | "$GUARD" 2>>"$WORK/stderr.log")"
  if [[ -n "$out" ]]; then
    decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
    if [[ "$decision" == "deny" ]]; then
      denied=$((denied+1))
      printf '%s\n' "$json_cmd" >> "$denied_file"
    fi
  fi
done < "$cmds_file"

echo
echo "═══════════════════════════════════════════"
echo "REPLAY RESULT: $total total, $denied denied"
if [[ "$denied" -gt 0 ]]; then
  echo
  echo "sample of denied commands (up to 20, JSON-escaped as extracted):"
  head -20 "$denied_file" | nl -ba
  cp "$denied_file" "$REPO/tests/.c7_replay_denied.jsonl.last"
  echo
  echo "full list saved to: $REPO/tests/.c7_replay_denied.jsonl.last (gitignored, for review only)"
fi
echo "TARGET: 0 false denies. Every denied command above must be independently confirmed"
echo "as a REAL leak (or intentionally left denied) before this guard gates -- a false"
echo "deny is a bug in the guard, not evidence it works."
