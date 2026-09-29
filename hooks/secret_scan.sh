#!/usr/bin/env bash
# secret_scan.sh — daily secret-on-disk scan (C7, second net). Given a running
# process's own environment as the value source, checks whether any of its real
# secret VALUES are already sitting in plain text anywhere under the given repo
# roots. Never prints a value or a matching line -- only a count and the file paths.
# Exits non-zero when the count is above 0, so its own exit code is the alert for a
# cron wrapper.
#
# Usage: secret_scan.sh <pid> <root> [<root> ...]
#   <pid>   a running process whose environment holds the secrets to check for, via
#           /proc/<pid>/environ. Must be readable (same user, or root).
#
# Value source: environment variables matching *(SECRET|PASSWORD|KEY|TOKEN|DSN)*
# whose value is 12+ characters (short values are far more likely to collide with
# ordinary text and produce noise, not signal). Held in a 0600 file under /dev/shm
# (tmpfs, never touches persistent disk) and shredded on exit -- including on an
# early error, via `trap ... EXIT`, so a crash never leaves values behind.
set -uo pipefail

pid="${1:?usage: secret_scan.sh <pid> <root> [<root> ...]}"
shift
roots=("$@")
if [[ ${#roots[@]} -eq 0 ]]; then
  echo "usage: secret_scan.sh <pid> <root> [<root> ...]" >&2
  exit 2
fi

envfile="/proc/$pid/environ"
if [[ ! -r "$envfile" ]]; then
  echo "cannot read $envfile (wrong pid, or not readable by this user)" >&2
  exit 2
fi

valfile="$(mktemp /dev/shm/secret_scan.XXXXXX)"
chmod 600 "$valfile"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "$valfile" 2>/dev/null || rm -f "$valfile"
  else
    rm -f "$valfile"
  fi
}
trap cleanup EXIT

tr '\0' '\n' < "$envfile" \
  | grep -E '^[A-Z0-9_]*(SECRET|PASSWORD|KEY|TOKEN|DSN)[A-Z0-9_]*=' \
  | while IFS='=' read -r _name rest; do
      # rest may itself contain '=' (base64, URLs); rejoin everything after the
      # first '=' as the value.
      [[ ${#rest} -ge 12 ]] && printf '%s\n' "$rest"
    done > "$valfile"

n_values=$(wc -l < "$valfile")
if [[ "$n_values" -eq 0 ]]; then
  echo "0 candidate secret value(s) found in pid $pid's environment -- nothing to scan for"
  exit 0
fi

declare -A seen_files=()
# One pass over the tree with the values read from a file (-f): a value on the command
# line would be visible to other users in the process list.
while IFS= read -r f; do
  seen_files["$f"]=1
done < <(grep -rlF --exclude-dir=.git -f "$valfile" -- "${roots[@]}" 2>/dev/null || true)

count=${#seen_files[@]}
echo "$count file(s) contain a secret value from pid $pid's environment:"
if [[ "$count" -gt 0 ]]; then
  printf '%s\n' "${!seen_files[@]}" | sort
fi

[[ "$count" -gt 0 ]] && exit 1
exit 0
