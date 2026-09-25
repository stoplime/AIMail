#!/usr/bin/env bash
# tests/lib_env.sh — the ONE place a suite scrubs the operator's shell out of its fixture.
#
# ⛔⛔ THE OPERATOR'S SHELL IS NOT PART OF THE FIXTURE (2026-09-22). Every seat's shell exports
#   per-account knobs for the LIVE fleet (`AIMAIL_WEEKLY_CAP_research=99`, `AIMAIL_SEAT_CAP_*`,
#   one seat even `AIMAIL_ROOT=~/.aimail`), a real `CLAUDE_CONFIG_DIR` and a real
#   `CLAUDE_CODE_SESSION_ID`. Left in place they leak into every arm that reads a cap, an account
#   id or a session id: on a research-account seat run.sh's weekly-cap arms saw cap 99 and
#   "weekly 97% did NOT park" -- three arms red for one operator and green for the next, which
#   reads as flakiness and is not (fable, run.sh 423/435 vs code-review 433/435 on the SAME tree).
#
# Contract: source this right after the suite has minted and exported its own AIMAIL_ROOT, then
# call `test_env_sanitize`. It keeps exactly the four variables every suite sets on purpose
# (AIMAIL_ROOT, AIMAIL_CONFIG, AIMAIL_NO_NETWORK, AIMAIL_BLOCK_TTL) plus AIMAIL_STERILITY_TERMS --
# the sterility guard's own configuration, which the whole-tree self-check NEEDS (scrubbing it
# silently turned that arm into a skip in every worktree, 2026-09-23 01:3x) -- drops every other AIMAIL_*
# the shell brought in, drops the caller's session id; `test_env_pin_config_dir` (separate, run.sh only) pins
# CLAUDE_CONFIG_DIR to a stub INSIDE the root so `account_id()` is the same word on every box. Arms that
# need a specific account or session still set them per command, exactly as they do today.
test_env_sanitize() {
  [[ -n "${AIMAIL_ROOT:-}" ]] || { echo "test_env_sanitize: AIMAIL_ROOT must be set first" >&2; return 1; }
  local _v
  while IFS= read -r _v; do unset "$_v"; done \
    < <(compgen -v | grep -E '^AIMAIL_' | grep -vE '^AIMAIL_(ROOT|CONFIG|NO_NETWORK|BLOCK_TTL|STERILITY_TERMS)$')
  unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
  return 0
}

# test_env_pin_config_dir — CLAUDE_CONFIG_DIR -> a stub INSIDE the root, so `account_id()` reads
# `claude_config_stub` on every box. run.sh wants this (its arms derive the account through
# `aimail budget account` and compare per-account files by that word). The seat suites instead
# UNSET the variable on purpose (their arms assert the "not set" refusals and pass a fake account
# dir per command), so the pin is a separate call, not part of the scrub.
test_env_pin_config_dir() {
  [[ -n "${AIMAIL_ROOT:-}" ]] || { echo "test_env_pin_config_dir: AIMAIL_ROOT must be set first" >&2; return 1; }
  export CLAUDE_CONFIG_DIR="$AIMAIL_ROOT/claude_config_stub"; mkdir -p "$CLAUDE_CONFIG_DIR"
}
