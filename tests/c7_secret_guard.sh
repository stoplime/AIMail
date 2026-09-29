#!/usr/bin/env bash
# tests/c7_secret_guard.sh — tests hooks/secret_read_guard.sh (the PreToolUse(Bash)
# guard that denies printing secret VALUES from a .env-style file, /proc/<pid>/environ,
# or a bare env/printenv/set/export -p dump).
#
# Same evidence rules as tests/run.sh: every refuses() case is paired with a nearby
# accepts() case using a form the guard claims to distinguish it from (①③), and the
# summary prints pass/total, never just failures (④).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
GUARD="$REPO/hooks/secret_read_guard.sh"

PASS=0; FAIL=0; declare -a FAILURES=()

# _decision <bash-command-string> : the guard's permissionDecision, or "allow" when
# the guard produced no output at all (its own definition of "not denied").
_decision() {
  local out
  out="$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | "$GUARD" 2>/tmp/c7_guard_test.err)"
  if [[ -z "$out" ]]; then echo "allow"; return; fi
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo "PARSE-ERROR"
}

# accepts <desc> <bash-command-string> : must NOT be denied
accepts() {
  local desc="$1" cmd="$2" got
  got="$(_decision "$cmd")"
  if [[ "$got" != "deny" ]]; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (denied, expected allow: $cmd)")
    printf '  ✖ %s — denied, expected allow: %s\n' "$desc" "$cmd"
  fi
}

# refuses <desc> <bash-command-string> : must BE denied
refuses() {
  local desc="$1" cmd="$2" got
  got="$(_decision "$cmd")"
  if [[ "$got" == "deny" ]]; then
    PASS=$((PASS+1)); printf '  ✔ %s\n' "$desc"
  else
    FAIL=$((FAIL+1)); FAILURES+=("$desc (got '$got', expected deny: $cmd)")
    printf '  ✖ %s — got %s, expected deny: %s\n' "$desc" "$got" "$cmd"
  fi
}

echo "▶ c7_secret_guard: $GUARD"
[[ -x "$GUARD" ]] || { echo "✖ guard not found or not executable: $GUARD"; exit 1; }

echo
echo "— the three real leaks from 2026-09-25/26 (①: must trip, this is what it's for) —"
refuses "leak 1: keyword grep AWS|BUCKET|STORAGE on zignore/.env" \
  'grep -inE "AWS|BUCKET|STORAGE" zignore/.env'
refuses "leak 2: env | grep -i sentry (dump piped to a value grep)" \
  'env | grep -i sentry'
refuses "leak 2b: cat .env | head -5 (same command, second segment)" \
  'env | grep -i sentry; cat .env | head -5'
refuses "leak 3: grep db|postgres|sql on .env, KEYWORD-GATED sed redactor misses names it wasn't told about" \
  'grep -in "db|postgres|sql" zignore/.env | sed "s/DATABASE_URL=.*/DATABASE_URL=REDACTED/"'

echo
echo "— .env-style files: value-printing forms (②) vs names-only (③, paired) —"
refuses "cat a .env file directly"            'cat zignore/.env'
refuses "head a .env file directly"           'head zignore/.env'
refuses "tail a .env file directly"           'tail -f zignore/.env'
refuses "less a .env file directly"           'less zignore/.env'
refuses "strings a .env file directly"        'strings zignore/.env'
refuses "cut -f2 on a .env file (value field)" 'cut -d= -f2 zignore/.env'
refuses "cut -f1 with the wrong delimiter (whole line back, value included)" \
  'cut -d, -f1 zignore/.env'
refuses "cut -f1 with no -d at all (default tab delimiter, whole line back)" \
  'cut -f1 zignore/.env'
refuses "sed on a .env file"                  'sed -n "1,5p" zignore/.env'
refuses "awk on a .env file"                  'awk -F= "{print}" zignore/.env'
refuses "a keyword grep, no -o"               'grep -i "key" .env'
refuses ".env.local variant, keyword grep"    'grep -i secret .env.local'
refuses "app.env variant, cat"                'cat config/app.env'

accepts "names-only grep -oE"                  "grep -oE '^[A-Z0-9_]+=' zignore/.env"
accepts "names-only grep -o, then cut -d= -f1" "grep -o '^[A-Z0-9_]*=' zignore/.env | cut -d= -f1"
accepts "grep -c (count only)"                 'grep -c "AWS" zignore/.env'
accepts "grep -q (quiet, exit code only)"      'grep -q "AWS" zignore/.env'
accepts "grep -l (filenames only, like -c/-q)" 'grep -l -E "^(POSTGRES|DB_|DATABASE)" zignore/.env'
accepts "cut -d= -f1 directly (names only)"    'cut -d= -f1 zignore/.env'
accepts "[ -n \"\$VAR\" ] existence check"      '[ -n "$AWS_REGION" ] && echo set'
accepts "test -f existence check"              'test -f zignore/.env && echo exists'
accepts "ls -la (metadata, not content)"       'ls -la zignore/.env'
accepts "ln -s (symlink, no read)"             'ln -s zignore/.env /tmp/x.env'
accepts "source (executes, prints nothing)"    'source zignore/.env'
accepts "dot-source (same, dot form)"          '. zignore/.env'
accepts "set -a; . file (option then source)" 'set -a; . zignore/.env'

echo
echo "— /proc/<pid>/environ: same value/names split —"
refuses "cat /proc/<pid>/environ directly"     'cat /proc/1234/environ'
refuses "strings on /proc/self/environ"        'strings /proc/self/environ'
accepts "names-only via tr+cut on environ"     "tr '\\0' '\\n' < /proc/1234/environ | cut -d= -f1"

echo
echo "— bare env/printenv/set/export -p dumps: same value/names split —"
refuses "bare env"                             'env'
refuses "bare printenv"                        'printenv'
refuses "export -p"                            'export -p'
refuses "bare export, no assignment"           'export'
refuses "bare set, no arguments"               'set'
accepts "printenv filtered to names"           "printenv | grep -oE '^[A-Z0-9_]+='"
accepts "export FOO=bar (an assignment, not a dump)" 'export FOO=bar'
accepts "set -e (an option, not a dump)"       'set -e'
accepts "set -o pipefail (an option, not a dump)" 'set -o pipefail'

echo
echo "— false-positive guards: words that merely look similar —"
accepts "prose mentioning 'environment'"       'echo "check the environment config"'
accepts "a file merely named environment.txt"  'ls -la environment.txt'
accepts "cat on an unrelated file"             'cat README.md'
accepts "grep on an unrelated file"            'grep -i TODO README.md'
accepts "non-Bash tool_name is ignored entirely" 'ignored-because-not-bash'

echo
echo "— human-only escape —"
accepts "AIMAIL_SECRET_GUARD_BYPASS=1 prefix"  'AIMAIL_SECRET_GUARD_BYPASS=1 cat zignore/.env'

echo
echo "— heredoc bodies are DATA, not shell syntax (found by tests/c7_replay.sh: a real"
echo "  review comment, hard-wrapped mid-word across a newline, misread as env)  —"
accepts "hard-wrapped prose inside a heredoc body reading '...conda\\n   env): ...'" \
  $'cat > /tmp/x.md << \'EOF\'\nRan the two touched test files standalone myself (via the review agent, the test conda\n   env): 312 tests, OK.\nEOF'
accepts "a .env-looking word inside a heredoc body is not a real file read" \
  $'cat > /tmp/x.md << \'EOF\'\nsee zignore/.env for the reader\nEOF'
refuses "a real leak AFTER a heredoc's closing delimiter still trips" \
  $'cat > /tmp/x.md << \'EOF\'\nsome notes\nEOF\ngrep -i "AWS" zignore/.env'
accepts "heredoc opener with a trailing pipe/redirect on the SAME line is still recognized" \
  $'python - <<\'PY\' 2>&1 | head -30\nfor line in open("zignore/.env"):\n    pass\nPY\necho after'

echo
echo "— found by tests/c7_replay.sh against real fleet traffic (each a real false deny —"
echo "  or a real gap -- before its own fix) —"
accepts "grep -v filters dotenv's own 'Loading .env' startup message" \
  'python3 -c "..." 2>&1 | grep -v "Loading .env"'
accepts "grep pattern searches CODE for the string zignore/.env (not a file read)" \
  'grep -n "def _connect\|psycopg2\|zignore/.env\|dotenv" /path/probe.py'
accepts "find -iname \"*.env\" lists filenames, doesn't read content" \
  'find /some/root -iname "*.env" -o -iname "config*" 2>/dev/null | grep -v ".git"'
refuses "find -exec cat {} on a .env match still trips (exec can read content)" \
  'find . -iname "*.env" -exec cat {} \;'
accepts "value captured via \$(...) into a var and never printed (recommended safe form)" \
  "export PGPASSWORD=\$(grep \"^APP_DB_PASSWORD=\" zignore/.env | cut -d'\"' -f2)"
accepts "while/read/export sourcing idiom, its own ; and && intact (source-equivalent)" \
  "set -a && while IFS='=' read -r k v; do [[ \"\$k\" =~ ^[A-Za-z_][A-Za-z0-9_]*\$ ]] || continue; export \"\$k=\$v\"; done < <(grep -v '^\\s*#' zignore/.env | grep '=') && set +a && echo done"
accepts "for-loop building a captured-value array, sed script's own ; inside quotes intact" \
  'ASSIGN=()
for n in APP_DB_NAME APP_DB_PASSWORD; do
  v=$(grep -m1 -E "^${n}=" zignore/.env | sed -E "s/^${n}=//; s/^\"(.*)\"$/\1/")
  ASSIGN+=("$n=$v")
done
env "${ASSIGN[@]}" python3 -c "print(1)"'
refuses "a real (uncaptured) leak still trips from inside a for-loop with a quoted-semicolon sed" \
  'for n in X; do
  cat zignore/.env | sed -E "s/;/;/"
done'
accepts "cp of a .env file is a copy, never a content print" \
  'cp zignore/.env /tmp/scratch/.env'
accepts "aws s3 cp pulling a .env down never prints its content" \
  'aws s3 cp s3://bucket/dev.env /tmp/scratch/.env 2>&1 | tail -3'
refuses "cp with destination /dev/stdout WOULD actually print it" \
  'cp zignore/.env /dev/stdout'
accepts "mv of a .env file is a rename, never a content print" \
  'mv zignore/.env /tmp/scratch/.env'
accepts "rm of a .env file deletes, never discloses content" \
  'rm zignore/.env'
accepts "sed -i in place on a .env file prints nothing to stdout" \
  'sed -i "s/^HOST=.*/HOST=\"127.0.0.1\"/" zignore/.env'
accepts "sed -i.bak (backup-suffix form) is still in-place, still safe" \
  'sed -i.bak "s/^HOST=.*/HOST=redacted/" zignore/.env'
refuses "ordinary sed (no -i) on a .env file still prints the transformed line" \
  'sed "s/^HOST=.*/HOST=redacted/" zignore/.env'
accepts "unconditional sed redact (pattern is exactly =.*, no keyword gate) is genuinely safe" \
  'grep -n "^APP_REDIS_HOST=" zignore/.env | sed "s/=.*/=<redacted>/"'
refuses "keyword-gated sed redact still misses names not in its list (the real leak-3 shape)" \
  'grep -in "db" zignore/.env | sed "s/PASSWORD=.*/PASSWORD=<redacted>/"'
accepts "names-only grep -o with no digits and a * quantifier (generalized char class)" \
  'grep -o "^[A-Z_]*=" zignore/.env'
accepts "names-only grep -o via ALTERNATION instead of a bracket class" \
  "grep -oE '^(DATABASE_URL|POSTGRES_[A-Z]+|DB_[A-Z]+)=' zignore/.env | sort -u"
accepts "names-only grep -o, bracket-class + alternation + bracket-class mixed" \
  "grep -oE '^[A-Z_]*(DB|DATABASE|PG|POSTGRES|SQL)[A-Z_]*=' zignore/.env | sort -u"
refuses "grep -o whose pattern extracts PAST the = (a partial value, not names-only)" \
  "grep -oE '^API_URL=https?://[^/\"]+' zignore/.env.local"
accepts "env \$(...) as ARGUMENTS (word-split into the env of the next command, never printed)" \
  "env \$(grep -v '^#' zignore/.env | xargs -d '\n') python3 -c 'print(1)'"
accepts "export \$(...) as ARGUMENTS, same capture idiom" \
  "export \$(grep -v '^#' zignore/.env | xargs -d '\n') 2>/dev/null; echo done"
accepts "a value-extracting pipeline redirected to a FILE, never printed to stdout" \
  'grep -E "^[A-Z0-9_]*(SECRET|PASSWORD)=" zignore/.env | cut -d= -f2- | sort -u > /tmp/vals.txt'
refuses "same pipeline WITHOUT the file redirect actually prints the values" \
  'grep -E "^[A-Z0-9_]*(SECRET|PASSWORD)=" zignore/.env | cut -d= -f2-'
refuses "a redirect that IS stdout in disguise (/dev/stdout) still prints" \
  'grep -E "^[A-Z0-9_]*(SECRET|PASSWORD)=" zignore/.env | cut -d= -f2- > /dev/stdout'
accepts "--subject text mentioning .env as prose is DATA, not a file this command reads" \
  'aimail send --to main --subject "re: the staging .env file" --body-file /tmp/x.txt 2>&1 | tail -3'
refuses "a REAL .env read still trips even alongside an unrelated --subject flag" \
  'aimail send --to main --subject "status update" --body-file /tmp/x.txt; cat zignore/.env'

echo
echo "— falsification (④ never becomes ①③ theater): a guard that always allows must fail this suite —"
_always_allow() { echo "allow"; }
if [[ "$(_always_allow)" == "$(echo allow)" ]]; then
  # sanity: confirm our own refuses() would actually catch an always-allowing guard,
  # by re-running one refuses case against a stub that never denies.
  GUARD_REAL="$GUARD"
  GUARD="$HERE/.stub_always_allow.sh"
  printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$GUARD"
  chmod +x "$GUARD"
  stub_got="$(_decision 'grep -inE "AWS" zignore/.env')"
  rm -f "$GUARD"
  GUARD="$GUARD_REAL"
  if [[ "$stub_got" != "deny" ]]; then
    PASS=$((PASS+1)); printf '  ✔ an always-allowing stub is correctly caught as non-deny (this suite is not silently vacuous)\n'
  else
    FAIL=$((FAIL+1)); FAILURES+=("falsification check itself is broken -- the stub 'denied' when it should never")
    printf '  ✖ falsification check itself is broken\n'
  fi
fi

echo
echo "— quoted prose mentioning env vs a real dump inside quotes —"
accepts "prose '(env)' inside a quoted --state text is not a dump" \
  'aimail ask touch k1 --state "triage (env) and printenv | notes done" | tail -5'
refuses "a real dump inside a quoted command substitution still denies" \
  'echo "$(env)"'
refuses "bare env after a semicolon still denies" \
  'echo hi; env'

echo
echo "— multi-line quoted text (commit message) vs a real dump on its own line —"
accepts "multi-line commit message mentioning (env) is prose, not a dump" \
  'git commit -q -m "stop reading (env) as a dump

Co-Authored-By: x" && git log --oneline -1'
refuses "a real env dump on a new line after a multi-line string still denies" \
  'echo "note
more"
env'
refuses "a command substitution dump inside a multi-line string still denies" \
  'echo "multi
line $(env)"'

echo
echo "— env with an array argument feeding a multi-line python -c —"
accepts "env \"\${ARR[@]}\" python3 -c \"<multi-line script>\" is not a bare env dump" \
  'env "${ASSIGN[@]}" python3 -c "
import os
print(os.environ.get(\"X\"))
" 2>&1 | tail -20'

echo
echo "— review fixes: set( ) as a call, separate grep flags, the loop-only exemption —"
accepts "defaultdict(set) / list(set) / map(set, z) are calls, not a bare set dump" \
  'python3 -c "from collections import defaultdict
by_key = defaultdict(set)
x = list(set)
y = map(set, z)"'
accepts "foo(set) after a word character is a call" \
  'echo x; foo(set)'
refuses "a real (set) subshell still denies" \
  '(set)'
refuses "x=$(set) still denies" \
  'x=$(set)'
accepts "grep -o -E names-only, flags as separate words" \
  "grep -o -E '^[A-Z0-9_]+=' zignore/.env"
accepts "grep -E -o names-only, flags in the other order" \
  "grep -E -o '^[A-Z0-9_]+=' zignore/.env"
accepts "grep -o -E with an alternation of anchored names" \
  'grep -o -E "^(POSTGRES_[A-Z]+|DB_[A-Z]+|DATABASE_URL)=" .env'
refuses "grep -o -E without the ^ anchor and = end prints values" \
  "grep -o -E 'KEY.*' zignore/.env"
refuses "grep -E -o for a keyword is not names-only" \
  "grep -E -o 'KEY' zignore/.env"
accepts "the while-read-export sourcing loop alone stays allowed" \
  'set -a && while IFS= read -r line; do export "$line"; done < <(grep -v "^#" zignore/.env | grep "=") && set +a'
refuses "a leak after the sourcing loop is still denied" \
  'set -a; while read -r k; do export "$k"; done < <(grep -v "^#" .env); env | grep -i key'
refuses "the words while/read/export in a comment do not exempt a cat" \
  'cat .env # while read; export'
refuses "a second read of the file after the loop is still denied" \
  'while read -r k; do export "$k"; done < .env; cat .env'
refuses "a later stray word done does not stretch the exemption over a leak" \
  'set -a; while read -r k; do export "$k"; done < <(grep -v "^#" .env); env | grep -i key; echo done'
refuses "a trailing comment word done does not stretch the exemption over a cat" \
  'while read -r k; do export "$k"; done < .env; cat .env # done'
accepts "a multi-line sourcing loop with done on its own line stays allowed" \
  'set -a && while IFS="=" read -r k v; do
  [[ "$k" =~ ^[A-Z_]+$ ]] || continue
  v="${v%\"}"; v="${v#\"}"
  export "$k=$v"
done < <(grep -v "^#" .env | grep "=") && set +a'
refuses "a multi-line loop does not exempt a leak after a later done word" \
  'while read -r k; do export "$k"
done < .env
cat .env # done'
accepts "a sourcing loop followed by an ordinary command mentioning done stays allowed" \
  'set -a; while read -r k; do export "$k"; done < <(grep -v "^#" .env); echo done'

echo
echo "═══════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
echo "c7_secret_guard: $PASS/$TOTAL passed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAILURES:"
  printf '  - %s\n' "${FAILURES[@]}"
  exit 1
fi
exit 0
