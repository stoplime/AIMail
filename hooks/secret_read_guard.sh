#!/usr/bin/env bash
# secret_read_guard.sh — Claude Code PreToolUse(Bash) hook: denies a command that would
# print secret VALUES from a .env-style file, /proc/<pid>/environ, or a bare shell/env
# dump (env, printenv, set, export -p) into the transcript. Names-only reads (which
# variable is set, not what it is) and sourcing (which prints nothing) are allowed.
#
# WHY (C7, 2026-09-28): on 09-25/26 three real commands printed real secret values into
# transcripts, all by keyword-grepping zignore/.env or piping a bare `env` through a
# keyword grep -- a keyword grep still prints the whole matched line, value included. A
# sed redactor doesn't fix this either: it missed variable names it wasn't told about.
#
# Denies via {"hookSpecificOutput":{"permissionDecision":"deny", ...}} on stdout with
# exit 0 -- never "ask", never a popup -- the same mechanism this fleet's other Bash
# guards already use (claude_block_git_push.sh, claude_linear_write_guard.sh, wired the
# same way in each account's settings.json) and that is proven to work in this harness;
# it is not the literal exit-2 form floated when this was proposed.
#
# Deliberately NOT a full shell parser: this is heuristic pattern matching over the
# command string, validated by tests/c7_secret_guard.sh (the specified leak/allow cases)
# and a REPLAY of every real Bash command in the last 7 days of transcripts
# (tests/c7_replay.sh), targeting zero false denies on real fleet traffic. Ambiguous
# shapes not covered by either resolve to ALLOW, not DENY -- a guard that blocks the
# whole fleet's Bash tool on a false positive is a bigger problem than a rare missed
# leak, and the daily scan (secret_scan.sh) is the second, independent net for whatever
# this one lets through.
#
# All matching uses bash's own [[ =~ ]] (no `grep`/`awk` subprocess per check) --
# ~95k real commands (7 days of fleet transcripts) need to replay in minutes, not hours,
# and this is the only correctness-preserving way to get there (same POSIX-ERE engine
# `grep -E` uses, glibc regexec, so the patterns below behave identically to how they
# were first written and tested against `grep -E`).
set -uo pipefail

in="$(cat)"
tool="$(printf '%s' "$in" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[[ "$tool" != "Bash" ]] && exit 0
cmd="$(printf '%s' "$in" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[[ -z "$cmd" ]] && exit 0

# Human-only escape, never a persistent env var, never wired into any fleet-seat
# instruction set: a real person at a real terminal can prefix a single command with
# this when they specifically need to look at a value. Deliberately undocumented in
# any seat-facing text so a fleet seat cannot be told to reach for it "just this once".
if [[ "$cmd" =~ (^|[[:space:];\&\|\(])AIMAIL_SECRET_GUARD_BYPASS=1([[:space:];\&\|\)]|$) ]]; then
  exit 0
fi

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

MSG_ENVFILE="Reading a .env-style file for VALUES is blocked (C7, 2026-09-28): a keyword grep or cat prints the value too, and a sed redactor misses names it wasn't told about. Names-only forms are allowed: grep -oE '^[A-Z0-9_]+=' <file>, grep -oE '^[A-Z0-9_]+=' <file> | cut -d= -f1, grep -c/-q <pattern> <file>, [ -n \"\$VAR\" ], test -f <file>, ls -la <file>, or source <file> (prints nothing). If a value is genuinely needed, source the file into a subshell and use the variable without printing it."
MSG_PROC="Reading /proc/<pid>/environ for VALUES is blocked (C7, 2026-09-28) -- same rule as a .env file: names only, e.g. tr '\\0' '\\n' < /proc/<pid>/environ | cut -d= -f1."
MSG_ENVDUMP="A bare env / printenv / set / export -p dump prints every value currently in scope. Blocked (C7, 2026-09-28) unless piped through a names-only filter: cut -d= -f1, grep -oE '^[A-Z0-9_]+=', grep -c/-q."

# Any path whose basename is exactly ".env", ends in ".env" (e.g. "app.env"), or starts
# with ".env." (e.g. ".env.local") -- bounded so it doesn't match "environment.txt" or a
# word that merely contains "env".
ENV_PATH_RE='(^|[^A-Za-z0-9_./-])([A-Za-z0-9_./-]*/)?([A-Za-z0-9_-]+\.env(\.[A-Za-z0-9_-]+)?|\.env(\.[A-Za-z0-9_-]+)?)([^A-Za-z0-9_./-]|$)'
PROC_ENVIRON_RE='/proc/([0-9]+|self|\$\$)/environ\b'

# The real invariant for "this grep is names-only" is not any one char-class spelling --
# it's `-o` (print ONLY the match) on a pattern that (a) is anchored at line-start (`^`)
# and (b) ends, as its very LAST literal character, in an unrepeated `=` immediately
# before the closing quote. Together those two guarantee the match can never extend past
# the `=` into the value, no matter what sits in between: a bracket class
# (`^[A-Z0-9_]+=`), an alternation (`^(POSTGRES_[A-Z]+|DB_[A-Z]+|DATABASE_URL)=`), or a
# mix of both (`^[A-Z_]*(DB|SQL)[A-Z_]*=`) are all equally safe under this rule, and all
# three were real false denies found live via tests/c7_replay.sh before this
# generalization from the original single bracket-class-only spelling. The character
# right before the `=` is required to be a name-token closer (`]`, `)`, or a word char),
# optionally followed by one quantifier -- `^AWS_SECRET_KEY=.*` still does NOT match,
# since its literal `=` is followed by more pattern (`.*`), not the closing quote.
SAFE_GREP_NAMES_RE="grep([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*o[a-zA-Z]*([[:space:]]+-[a-zA-Z]+)*[[:space:]]+['\"]\\^[^'\"]*(\\]|\\)|[A-Za-z0-9_])[*+?]?=['\"]"
SAFE_GREP_COUNT_RE='grep[[:space:]]+-[a-zA-Z]*c[a-zA-Z]*\b'
SAFE_GREP_QUIET_RE='grep[[:space:]]+-[a-zA-Z]*q[a-zA-Z]*\b'
# grep -l: prints matching FILENAMES only, same metadata-not-content guarantee as -c/-q.
SAFE_GREP_LIST_RE='grep[[:space:]]+-[a-zA-Z]*l[a-zA-Z]*\b'
CUT_PRESENT_RE='\bcut\b'
CUT_DELIM_EQ_RE="-d[[:space:]]*['\"]?=['\"]?"
CUT_FIELD1_RE='-f[[:space:]]*1\b'
# sed 's/=.*/<replacement>/' -- the PATTERN half is literally "=.*" (nothing before the
# `=`), so this unconditionally strips everything from the first `=` onward on every
# matched line regardless of variable name. Genuinely safe: unlike a KEYWORD-gated
# redaction (`sed 's/PASSWORD=.*/.../''`, which misses any name not in its list -- exactly
# the failure mode leak #3 was), there is no name to miss here. Only the `/`-delimited
# spelling is recognized (the one seen live via tests/c7_replay.sh); `|`/`#`-delimited
# equivalents are not, which is a conservative gap (resolves to still-denied), not a hole.
SED_UNCONDITIONAL_REDACT_RE='s/=\.\*/'

# The `-exec`/`-ok` boundary is included so `find ... -exec cat {} \;` is still caught
# as a content read even though `find` itself (see is_safe_read below) is otherwise
# treated like `ls` -- metadata only.
CONTENT_READER_RE='(^|[;\&\|\(]|\$\(|-exec[[:space:]]|-ok[[:space:]])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=\S*[[:space:]]+)*(cat|head|tail|less|more|tac|strings|xxd|od|hexdump|nl|vim?|nano|emacs)\b'
GREP_SED_AWK_RE='\b(grep|sed|awk)\b'
SAFE_READ_RE='(^|[;\&\|\(])[[:space:]]*(test[[:space:]]+-[ef][[:space:]]|\[[[:space:]]+-[ne][[:space:]]|ls[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*|ln[[:space:]]+-s|source[[:space:]]|\.[[:space:]])'
SUBST_ENV_RE='(\$\(|`)[[:space:]]*(env|printenv)[[:space:]]*(\)|`)'
BARE_ENV_RE='(^|[;\&\|\(]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=\S*[[:space:]]+)*(env|printenv)\b[[:space:]]*($|[;\&\|\)])'
BARE_SET_RE='(^|[;\&\|\(])[[:space:]]*set[[:space:]]*($|[;\&\|\)])'
BARE_EXPORT_RE='(^|[;\&\|\(])[[:space:]]*export([[:space:]]+-p)?[[:space:]]*($|[;\&\|\)])'

# A names-only filter stage anywhere in the pipeline neutralizes an otherwise-flagged
# read of the same pipeline: extract-names-then-optionally-take-the-name-column, or a
# grep that only reports a count / yes-no. `cut` only counts as a names-only filter when
# BOTH the delimiter is '=' AND the field selected is 1 -- `cut -f1` with any other
# delimiter (e.g. a .env file split on ',' instead of '=') returns the whole un-split
# line, value included, which is exactly the bug this guard exists to catch.
has_safe_filter() {
  local p="$1"
  [[ "$p" =~ $SAFE_GREP_NAMES_RE ]] && return 0
  [[ "$p" =~ $SAFE_GREP_COUNT_RE ]] && return 0
  [[ "$p" =~ $SAFE_GREP_QUIET_RE ]] && return 0
  [[ "$p" =~ $SAFE_GREP_LIST_RE ]] && return 0
  if [[ "$p" =~ $CUT_PRESENT_RE ]] && [[ "$p" =~ $CUT_DELIM_EQ_RE ]] && [[ "$p" =~ $CUT_FIELD1_RE ]]; then
    return 0
  fi
  [[ "$p" =~ $SED_UNCONDITIONAL_REDACT_RE ]] && return 0
  return 1
}

# grep/sed/awk's own PATTERN argument (the first quoted argument after the command name
# and any flags) is a SEARCH TERM, not a file -- ".env" appearing inside it (searching
# code for the string "zignore/.env", or filtering `grep -v "Loading .env"`, dotenv's
# own startup message) is not a file read. Only a LATER, unquoted-or-separately-quoted
# argument is an actual file. Stripped out before touches_envfile() looks for a real
# path -- found live during development via tests/c7_replay.sh (both shapes above were
# real commands from real transcripts, both false denies before this fix).
GREP_PATTERN_ARG_DQ_RE='(grep|sed|awk)[[:space:]]+(-[a-zA-Z0-9]+[[:space:]]+)*"[^"]*"'
GREP_PATTERN_ARG_SQ_RE="(grep|sed|awk)[[:space:]]+(-[a-zA-Z0-9]+[[:space:]]+)*'[^']*'"
strip_grep_pattern_args() {
  local s="$1" m
  while [[ "$s" =~ $GREP_PATTERN_ARG_DQ_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  while [[ "$s" =~ $GREP_PATTERN_ARG_SQ_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  printf '%s' "$s"
}

# A long-form flag's own quoted text argument (a mail subject/body, a commit-style
# message) is prose being carried as DATA, not a file path -- ".env" appearing inside it
# (e.g. --subject "... + staging .env) and report pass/fail") is someone describing a
# file, not a command touching one. Found live via tests/c7_replay.sh: this combined
# with an unrelated `| tail -N`/`| tail -1` elsewhere in the SAME pipeline (checking the
# aimail send confirmation, not any .env content) to produce a false deny -- the
# content-reader check and the envfile check are independent regex scans over the whole
# segment, with nothing tying `tail` to what it's actually reading.
FLAG_TEXT_ARG_DQ_RE='--(subject|body|desc|description|message|reason|why|state)[[:space:]]+"[^"]*"'
FLAG_TEXT_ARG_SQ_RE="--(subject|body|desc|description|message|reason|why|state)[[:space:]]+'[^']*'"
strip_flag_text_args() {
  local s="$1" m
  while [[ "$s" =~ $FLAG_TEXT_ARG_DQ_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  while [[ "$s" =~ $FLAG_TEXT_ARG_SQ_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  printf '%s' "$s"
}

touches_envfile() {
  local stripped
  stripped="$(strip_flag_text_args "$(strip_grep_pattern_args "$1")")"
  [[ "$stripped" =~ $ENV_PATH_RE ]]
}
touches_proc_environ() { [[ "$1" =~ $PROC_ENVIRON_RE ]]; }

# A stage in the pipeline that is a plain-content reader (would print the whole line,
# value included, if pointed at a secret source).
is_content_reader() { [[ "$1" =~ $CONTENT_READER_RE ]]; }
# cp/mv are otherwise treated as safe (see CP_MV_SAFE_RE) since a plain file copy or
# rename doesn't print content -- but a destination that IS stdout is the one shape
# where it actually would, so that specific combination still counts as a discloser.
is_cp_to_stdout() { [[ "$1" =~ $CP_MV_SAFE_RE ]] && [[ "$1" =~ $CP_MV_UNSAFE_DEST_RE ]]; }
# A grep/sed/awk stage that is NOT one of the names-only/count-only safe forms.
is_value_grep_sed_awk() { [[ "$1" =~ $GREP_SED_AWK_RE ]] && ! has_safe_filter "$1"; }
# A `cut` stage present, but not in the one safe shape (-d= paired with -f1).
is_value_cut() {
  [[ "$1" =~ $CUT_PRESENT_RE ]] || return 1
  if [[ "$1" =~ $CUT_DELIM_EQ_RE ]] && [[ "$1" =~ $CUT_FIELD1_RE ]]; then
    return 1
  fi
  return 0
}
# Forms that never disclose a value no matter what they're pointed at: presence/existence
# checks, symlinking, and sourcing (executes the file; sourcing itself prints nothing --
# a script that then goes on to echo a variable is caught the same way any other command
# printing that value would be, which is out of scope for a static command-string guard).
#
# `find` (without -exec/-ok, which could run an arbitrary reader on what it finds) only
# ever lists matching PATHS -- the same metadata-not-content guarantee as `ls` -- so
# `find ... -iname "*.env"` is a filename search, not a read, even though the pattern
# argument itself looks like an env path (found live via tests/c7_replay.sh).
FIND_SAFE_RE='(^|[;\&\|\(])[[:space:]]*find[[:space:]]'
FIND_EXEC_RE='-(exec|ok)\b'
# cp / aws s3 cp / mv -- a file copy or rename never prints the file's content, only
# metadata about the operation (found live via tests/c7_replay.sh: `aws s3 cp
# s3://.../dev.env /tmp/x/.env`, `cp a/.env b/.env`, pulling a shared .env into a scratch
# worktree). The one real risk is a destination that IS stdout (`cp .env /dev/stdout`
# would in fact print it) -- excluded explicitly rather than assumed away.
CP_MV_SAFE_RE='(^|[;\&\|\(])[[:space:]]*(aws[[:space:]]+s3[[:space:]]+)?(cp|mv)[[:space:]]+'
CP_MV_UNSAFE_DEST_RE='(/dev/stdout|/dev/fd/1|/dev/std(out|err))([[:space:]]|$)'
# rm -- deletion never discloses content either.
RM_SAFE_RE='(^|[;\&\|\(])[[:space:]]*rm[[:space:]]+'
# sed -i (in place) rewrites the file on disk and prints NOTHING to stdout, regardless of
# what its script matches -- a fundamentally different case from ordinary sed, which
# prints the transformed line. Found live via tests/c7_replay.sh: `sed -i
# 's/^HOST=.*/HOST="127.0.0.1"/' .env` editing a local scratch copy in place.
SED_INPLACE_RE='(^|[;\&\|\(])[[:space:]]*sed[[:space:]]+(-[A-Za-z]*[[:space:]]+)*-[A-Za-z]*i[A-Za-z]*(\.[A-Za-z0-9_-]+)?([[:space:]]|$)'
# A pipeline whose own visible stdout is redirected to a REGULAR FILE (`> path` /
# `>> path`), not to stdout/a terminal, never reaches this command's own output no
# matter what any earlier stage in it reads -- the same "capture, don't print" guarantee
# as `VAR=$(...)`, just via a file redirect instead of command substitution (found live
# via tests/c7_replay.sh: my own secret_scan.sh-shaped idiom, `tr '\0' '\n' < environ |
# grep -E '...(SECRET|PASSWORD|...)...' | cut -d= -f2- | awk '...' | sort -u > $F`,
# followed only by `wc -l < $F` and `ls -l $F | cut -c1-10` -- a count and permission
# bits, never a value). Excludes a redirect that IS stdout in disguise
# (/dev/stdout, /dev/fd/1, /dev/stderr) -- that shape genuinely still prints.
# The target charset is deliberately restricted to plain path characters -- NOT
# "anything but whitespace" -- so a literal `>` appearing inside ordinary quoted prose
# (e.g. a sed replacement string `<redacted>`, or any other `<tag>`-shaped text near the
# end of the command) can't be mistaken for a real shell redirect operator. Found live
# while adding this fix's own test: `sed "s/PASSWORD=.*/PASSWORD=<redacted>/"` was
# misread as ending in `> /"` (redirecting to a file literally named `/"`) because the
# old charset ([^[:space:]&]) allowed a bare `"` in the "path". A real path never
# contains a quote character, so excluding it costs nothing.
REDIRECT_TO_FILE_RE='>>?[[:space:]]*[A-Za-z0-9_./${}~-]+[[:space:]]*$'
REDIRECT_TO_STDOUT_EXCLUDE_RE='>>?[[:space:]]*(/dev/stdout|/dev/fd/1|/dev/stderr)[[:space:]]*$'
is_redirected_to_file() {
  [[ "$1" =~ $REDIRECT_TO_FILE_RE ]] && ! [[ "$1" =~ $REDIRECT_TO_STDOUT_EXCLUDE_RE ]]
}
# A `[export] VAR=$(...)` span -- wherever it appears, not just as a whole segment --
# never prints anything to this command's own stdout: command substitution's output is
# captured into the variable, not inherited by the outer command, regardless of what
# the substitution reads. This is the guard's own recommended safe form ("source the
# file ... and use the variable without printing it") in its command-substitution
# shape, not just its `source` shape (found live via tests/c7_replay.sh: both
# `export PGPASSWORD=$(grep "..." .env | cut ...)` used to feed a real psql connection,
# and a `for n in ...; do v=$(grep ... .env | sed ...); ASSIGN+=("$n=$v"); done` loop
# building an array of captured values for `env "${ASSIGN[@]}" cmd` -- neither ever
# printed). Handles one level of nested parens (a `sed` argument like `s/^\"(.*)\"$/.../`
# has its own paren pair inside the $(...) span).
CAPTURED_ASSIGNMENT_SPAN_RE='(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=\$\(([^()]|\([^()]*\))*\)'
strip_captured_assignments() {
  local s="$1" m
  while [[ "$s" =~ $CAPTURED_ASSIGNMENT_SPAN_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  while [[ "$s" =~ $ENV_EXPORT_ARG_CAPTURE_RE ]]; do
    m="${BASH_REMATCH[0]}"; [[ -z "$m" ]] && break
    s="${s/"$m"/}"
  done
  printf '%s' "$s"
}
# The `while IFS=... read ...; do ...; export "$k=$v"; done < <(...)` idiom is a
# source-equivalent: it assigns into shell variables via `export`, never prints. This is
# the standard way to source a file while skipping comment lines (`source`/`.` alone
# can't do that filtering), so it's excluded here the same way `source` itself is.
# The loop's own `done` must directly follow the export statement (`export ...; done`, or `export ... done` once a multi-line loop has been joined onto one line), so a
# later stray word `done` elsewhere in the command cannot stretch the exemption over it.
WHILE_READ_EXPORT_RE='\bwhile\b.*\bread\b.*\bexport\b[^;\&|'$'\n'']*;?[[:space:]]*\bdone\b([[:space:]]*<[[:space:]]*(<\([^)]*\)|[^;\&|[:space:]]+))?'
# `env $(...)` / `export $(...)` used as ARGUMENTS (not `VAR=$(...)` assignment) -- e.g.
# `env $(grep -v '^#' .env | xargs -d '\n') some_command`, or
# `export $(grep -v '^#' .env | xargs -d '\n')`. The substitution's output becomes
# argv/the environment for the command that follows, never this command's own stdout --
# the same "capture, don't print" guarantee as VAR=$(...), just via env/export's
# word-splitting instead of a variable assignment (found live via tests/c7_replay.sh: a
# real `for i in 1 2 3; do env $(grep -v '^#' zignore/.env | xargs -d '\n') conda run
# ... python -m unittest ...; done` re-running a test 3x under real env vars, and a
# `export $(grep -v '^#' zignore/.env | xargs -d '\n') 2>/dev/null; ... python -m
# unittest ...` sourcing-equivalent for the rest of the same line).
ENV_EXPORT_ARG_CAPTURE_RE='\b(env|export)[[:space:]]+\$\(([^()]|\([^()]*\))*\)'
is_safe_read() {
  [[ "$1" =~ $SAFE_READ_RE ]] && return 0
  [[ "$1" =~ $FIND_SAFE_RE ]] && ! [[ "$1" =~ $FIND_EXEC_RE ]] && return 0
  [[ "$1" =~ $WHILE_READ_EXPORT_RE ]] && return 0
  [[ "$1" =~ $CP_MV_SAFE_RE ]] && ! [[ "$1" =~ $CP_MV_UNSAFE_DEST_RE ]] && return 0
  [[ "$1" =~ $RM_SAFE_RE ]] && return 0
  [[ "$1" =~ $SED_INPLACE_RE ]] && return 0
  is_redirected_to_file "$1" && return 0
  return 1
}

# Bare env/printenv/set/export -p, evaluated on the FIRST stage of a pipeline only --
# these are dumps precisely because nothing yet stands between them and stdout.
# Blank out quoted prose ('...' always; "..." unless it holds a $( or backtick that
# would really run something) so `echo "triage (env) done"` is not read as a subshell
# running env.
strip_quoted_prose() {
  local s="$1" out="" m
  local sq="^([^\']*)'[^']*'(.*)$" dq='^([^"]*)"([^"]*)"(.*)$'
  while :; do
    if [[ "$s" =~ $dq ]]; then
      if [[ "${BASH_REMATCH[2]}" == *'$('* || "${BASH_REMATCH[2]}" == *'`'* ]]; then
        out+="${BASH_REMATCH[1]}\"${BASH_REMATCH[2]}\""
      else
        out+="${BASH_REMATCH[1]}\"\""
      fi
      s="${BASH_REMATCH[3]}"
    else
      break
    fi
  done
  printf '%s' "$out$s"
}

is_bare_dump() {
  local seg="$1" raw="$1"
  # "(" right after a word character is a call (defaultdict(set), list(set)), not a
  # subshell that runs the command in front of the closing ")".
  local _callparen='([A-Za-z0-9_])\('
  while [[ "$seg" =~ $_callparen ]]; do seg="${seg/"${BASH_REMATCH[0]}"/"${BASH_REMATCH[1]} "}"; done
  # A newline inside a quoted string cuts it into pieces, so one piece can carry a lone
  # quote; text on the far side of that quote is prose or code from the string, not a
  # command, so it is dropped before the check.
  # (balanced spans were already blanked to "" by the caller; drop those first so the
  # first quote left is the stray one)
  local envseg="$seg" unpaired="${seg//\"\"/}"
  if [[ "$unpaired" == *\"* ]]; then envseg="${unpaired%%\"*}"; fi
  # a command substitution running env/printenv is a dump wherever it sits
  [[ "$raw" =~ $SUBST_ENV_RE ]] && return 0
  [[ "$envseg" =~ $BARE_ENV_RE ]] && return 0
  # bare `set` with zero arguments -- `set -a`, `set -e`, `set -o pipefail` etc. are
  # option toggles, not dumps, and are excluded by requiring nothing follows.
  [[ "$seg" =~ $BARE_SET_RE ]] && return 0
  # export -p, or bare export with no assignment
  [[ "$seg" =~ $BARE_EXPORT_RE ]] && return 0
  return 1
}

# violation_kind <pipeline> — prints "proc" / "envfile" / "dump" and returns 0 if this
# one pipeline ("A | B | C", no top-level ; && || in it) is a violation; returns 1 (and
# prints nothing) if it's allowed.
violation_kind() {
  local pipeline="$1"
  is_safe_read "$pipeline" && return 1

  # Strip any `[export] VAR=$(...)` capture spans before looking for a violation: a
  # secret source read strictly inside one of these never reaches this command's own
  # stdout (see CAPTURED_ASSIGNMENT_SPAN_RE above). is_bare_dump's own first_stage is
  # computed from the ORIGINAL pipeline, not the sanitized one -- a capture span can't
  # look like a bare dump anyway (it always has a leading `VAR=`), so this only affects
  # the envfile/proc/reader checks below, not that classification.
  local sanitized
  sanitized="$(strip_captured_assignments "$pipeline")"

  local first_stage
  first_stage="$(strip_quoted_prose "$pipeline")"
  first_stage="${first_stage%%|*}"

  local touches_proc=0 touches_file=0 is_dump=0
  touches_proc_environ "$sanitized" && touches_proc=1
  touches_envfile "$sanitized" && touches_file=1
  is_bare_dump "$first_stage" && is_dump=1

  (( touches_proc == 0 && touches_file == 0 && is_dump == 0 )) && return 1

  # A names-only filter anywhere downstream in the SAME pipeline neutralizes it.
  has_safe_filter "$sanitized" && return 1

  if (( touches_proc == 1 || touches_file == 1 )); then
    if is_content_reader "$sanitized" || is_value_grep_sed_awk "$sanitized" || is_value_cut "$sanitized" || is_cp_to_stdout "$sanitized"; then
      if (( touches_proc == 1 )); then echo proc; else echo envfile; fi
      return 0
    fi
    return 1
  fi
  if (( is_dump == 1 )); then
    echo dump
    return 0
  fi
  return 1
}

# A heredoc BODY is literal data (e.g. a commit message, a review write-up), not shell
# syntax -- splitting it into "segments" below and pattern-matching it as commands is
# how ordinary hard-wrapped prose gets misread as shell syntax (found live during
# development: a review comment reading "...conda\n   env): 312 tests, OK." -- wrapped
# across a real newline -- was misread as a bare `env` command because the line after
# the wrap starts with "env)"). Heredoc body lines are swallowed here (their START and
# END delimiter lines are kept, since those can still legitimately be checked).
strip_heredocs() {
  local text="$1" line result="" in_heredoc=0 delim="" strip_tabs=0 check_line first=1
  while IFS= read -r line; do
    if [[ "$in_heredoc" -eq 1 ]]; then
      check_line="$line"
      if [[ "$strip_tabs" -eq 1 ]]; then
        while [[ "$check_line" == $'\t'* ]]; do check_line="${check_line#$'\t'}"; done
      fi
      if [[ "$check_line" == "$delim" ]]; then
        in_heredoc=0
        if [[ "$first" -eq 1 ]]; then result="$line"; first=0; else result+=$'\n'"$line"; fi
      fi
      continue
    fi
    if [[ "$first" -eq 1 ]]; then result="$line"; first=0; else result+=$'\n'"$line"; fi
    # The quoted forms allow trailing redirects/pipes on the SAME line as the opener
    # (`python - <<'PY' 2>&1 | head -30` is ordinary, valid shell -- the heredoc body
    # still starts on the next line regardless of what follows the delimiter here).
    # Found live via tests/c7_replay.sh: an end-of-line-anchored version of this regex
    # missed exactly that shape, so a heredoc's own Python body (reading zignore/.env
    # directly, never printing it) went unswallowed and got flagged. The bareword form
    # stays end-anchored -- unlike a quoted delimiter, a bare word is easily confused
    # with other `<<` uses (e.g. an arithmetic left-shift) if not anchored, and getting
    # that wrong risks swallowing real content for the rest of the command (a missed
    # leak), which is worse than the narrow case this relaxation targets.
    if [[ "$line" =~ \<\<(-)?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]] \
       || [[ "$line" =~ \<\<(-)?[[:space:]]*\'([A-Za-z_][A-Za-z0-9_]*)\'([[:space:]]|[\|\;\&\>\<\)]|$) ]] \
       || [[ "$line" =~ \<\<(-)?[[:space:]]*\"([A-Za-z_][A-Za-z0-9_]*)\"([[:space:]]|[\|\;\&\>\<\)]|$) ]]; then
      in_heredoc=1
      delim="${BASH_REMATCH[2]}"
      [[ "${BASH_REMATCH[1]}" == "-" ]] && strip_tabs=1 || strip_tabs=0
    fi
  done <<< "$text"
  printf '%s' "$result"
}

# A multi-line `while`/`for`/`if`/`case` block is ONE statement even though it spans
# several physical lines -- splitting on every embedded newline (below) tears its
# pieces into separate segments and loses the context that makes it recognizable as
# (for example) the while-read-export sourcing idiom. This is a coarse, per-line
# keyword count, not a real parser: it opens on a line starting a block keyword and
# closes on one starting fi/done/esac, joining every line in between with a space
# instead of a newline so the whole block survives as one segment.
join_control_blocks() {
  local text="$1" line result="" depth=0 first=1
  local open_re='(^|[;\&\|\(])[[:space:]]*(if|while|until|for|case)\b'
  local close_re='(^|[;\&\|\(])[[:space:]]*(fi|done|esac)\b'
  while IFS= read -r line; do
    if [[ "$first" -eq 1 ]]; then
      result="$line"; first=0
    elif (( depth > 0 )); then
      result+=" $line"
    else
      result+=$'\n'"$line"
    fi
    [[ "$line" =~ $open_re ]] && depth=$((depth+1))
    [[ "$line" =~ $close_re ]] && depth=$((depth>0 ? depth-1 : 0))
  done <<< "$text"
  printf '%s' "$result"
}

# A plain sed -E "s/../..; s/../.."` -- a normal, common way to run more than one sed
# expression in one quoted script -- has a LITERAL `;` inside its own quotes. The plain
# sed-based split below has no idea it's inside quotes and cuts there anyway, which (in
# a for/while loop whose body contains this) tears the pieces of a real safe idiom
# apart the same way unjoined newlines used to (found live via tests/c7_replay.sh: a
# `for n in ...; do v=$(grep ... | sed -E "s/^${n}=//; s/^\"(.*)\"$/\1/"); ...; done`
# loop). A fully quote-aware split of EVERY command would be the principled fix but is
# too slow to run 95k times per REPLAY; instead, the cheap common case (no block
# keyword, or no quoted `;`) keeps using the fast sed-based split below, and only a
# command that could actually be affected -- one with a block keyword AND something
# that looks like a `;` sitting inside quotes -- pays for the slower, correct,
# character-by-character quote_aware_split.
NEEDS_QUOTE_AWARE_RE='\b(if|while|until|for|case)\b'
QUOTED_SEMICOLON_RE='['"'"'"][^'"'"'"]*;[^'"'"'"]*['"'"'"]'

# quote_aware_split <text> -- splits on a top-level (outside any '...'/"..." quotes)
# ; && || or real newline; anything inside quotes, and any embedded newline, is kept
# literally (a newline inside quotes is exceedingly rare and left as-is; one outside
# quotes but that reached here was already turned into a space by join_control_blocks
# upstream or is a genuine top-level boundary). Writes one segment per output line.
quote_aware_split() {
  local text="$1"
  local -i i=0 n=${#text}
  local ch quote="" cur=""
  local -a out=()
  while (( i < n )); do
    ch="${text:i:1}"
    if [[ -n "$quote" ]]; then
      cur+="$ch"
      if [[ "$quote" == '"' && "$ch" == '\' && $((i+1)) -lt n ]]; then
        cur+="${text:i+1:1}"; i=$((i+2)); continue
      fi
      [[ "$ch" == "$quote" ]] && quote=""
      i=$((i+1)); continue
    fi
    if [[ "$ch" == "'" || "$ch" == '"' ]]; then
      quote="$ch"; cur+="$ch"; i=$((i+1)); continue
    fi
    if [[ "$ch" == ';' || "$ch" == $'\n' ]]; then
      out+=("$cur"); cur=""; i=$((i+1)); continue
    fi
    if [[ "$ch" == '&' && "${text:i:2}" == '&&' ]]; then
      out+=("$cur"); cur=""; i=$((i+2)); continue
    fi
    if [[ "$ch" == '|' && "${text:i:2}" == '||' ]]; then
      out+=("$cur"); cur=""; i=$((i+2)); continue
    fi
    cur+="$ch"; i=$((i+1))
  done
  out+=("$cur")
  printf '%s\n' "${out[@]}"
}

# merge_by_block_depth <piece...> -- quote_aware_split has no idea about if/while/
# until/for/case nesting, so it still cuts a real segment boundary at (for example) the
# `;` in `for n in ...; do` -- separating the loop's own opening keyword from its body.
# This re-merges consecutive pieces (space-joined) whenever a keyword count says we're
# still inside an open block, the same running-depth idea join_control_blocks already
# uses for raw lines, just applied to quote_aware_split's pieces instead.
merge_by_block_depth() {
  local -a pieces=("$@")
  local -a out=()
  local -i depth=0
  local cur="" first=1 p
  local open_re='\b(if|while|until|for|case)\b'
  local close_re='\b(fi|done|esac)\b'
  for p in "${pieces[@]}"; do
    if [[ "$first" -eq 1 ]]; then
      cur="$p"; first=0
    elif (( depth > 0 )); then
      cur+=" $p"
    else
      out+=("$cur"); cur="$p"
    fi
    [[ "$p" =~ $open_re ]] && depth=$((depth+1))
    [[ "$p" =~ $close_re ]] && depth=$((depth>0 ? depth-1 : 0))
  done
  out+=("$cur")
  printf '%s\n' "${out[@]}"
}

# Split on top-level ; && || (and real newlines, since a multi-statement Bash tool_input
# is one string with embedded \n between statements) -- deliberately naive, no full shell
# parse. Each resulting segment is itself one pipeline (its internal | stays intact) and
# is checked independently, so a single denied segment anywhere in a compound command
# denies the whole command (matches leak #2's own shape:
# `env | grep -i sentry; cat .env | head -5` -- the SECOND segment there is also
# independently a violation, but the first alone is enough to deny the line before
# either runs).
cmd_for_split="$(join_control_blocks "$(strip_heredocs "$cmd")")"

# The while-read-export sourcing idiom (see WHILE_READ_EXPORT_RE above) commonly has
# its own internal ; and && (between `do`, the body, and `done`) -- the plain ;/&&/||
# split below has no concept of while/do/done nesting and would tear the block's
# `export "$k=$v"` away from the `done < <(grep ... .env | ...)` that feeds it,
# destroying the very context that makes the idiom recognizable as source-equivalent
# (found live via tests/c7_replay.sh: a real `set -a && while ...; do ...; export
# "$k=$v"; done < <(grep -v '^#' zignore/.env | grep '=') && set +a && ...` was denied
# because its pieces were checked in isolation). Checked once, globally, before any
# splitting: a command containing this idiom anywhere is exempted whole, which is
# coarser than per-segment checking but correct for the narrow, specific shape this
# targets.
if [[ "$cmd_for_split" =~ $WHILE_READ_EXPORT_RE ]]; then
  # Only the loop itself is exempt (from `while` through `done` and the input it reads);
  # anything else in the command is still checked, so a leak after the loop is denied.
  cmd_for_split="${cmd_for_split/"${BASH_REMATCH[0]}"/}"
  [[ -z "${cmd_for_split//[[:space:];&|]/}" ]] && exit 0
fi

if [[ "$cmd_for_split" =~ $NEEDS_QUOTE_AWARE_RE ]] && [[ "$cmd_for_split" =~ $QUOTED_SEMICOLON_RE ]]; then
  mapfile -t _raw_pieces < <(quote_aware_split "$cmd_for_split")
  mapfile -t segments < <(merge_by_block_depth "${_raw_pieces[@]}")
else
  split_re='&&|\|\||;|[[:space:]]*\n[[:space:]]*'
  mapfile -t segments < <(printf '%s\n' "$cmd_for_split" | sed -E "s/${split_re}/\n/g")
fi

for seg in "${segments[@]}"; do
  [[ -z "${seg//[[:space:]]/}" ]] && continue
  kind="$(violation_kind "$seg" || true)"
  case "$kind" in
    proc)    deny "$MSG_PROC" ;;
    envfile) deny "$MSG_ENVFILE" ;;
    dump)    deny "$MSG_ENVDUMP" ;;
  esac
done

exit 0
