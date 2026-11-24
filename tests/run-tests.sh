#!/usr/bin/env bash
# Smoke tests for the bash scripts, using fake `codex` and `agy` CLIs on PATH.
# No network, no real models.
#   bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/plugins/sparring/skills"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()    { echo "  ok    $1"; pass=$((pass + 1)); }
bad()   { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

APPROVE='{"verdict":"approve","summary":"s","issues":[],"withdrawn":["R1"]}'
CHANGES='{"verdict":"changes_requested","summary":"s","issues":[{"id":"R1","severity":"blocking","location":"a.py:1","comment":"c","suggestion":""}],"withdrawn":[]}'
mkdir -p "$T/bin" "$T/proj"

# Fake codex: records its arguments, writes a review to the -o file.
cat > "$T/bin/codex" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] && { echo "codex-cli 0.0.0-fake"; exit 0; }
[[ "\${1:-} \${2:-}" == "login status" ]] && { echo "Logged in using ChatGPT"; exit "\${FAKE_LOGIN_EXIT:-0}"; }
printf '%s\n' "\$@" > "\$FAKE_ARGS"
[[ -n "\${FAKE_TOUCH:-}" ]] && echo touched >> "\$FAKE_TOUCH"
[[ -n "\${FAKE_CREATE:-}" ]] && echo created > "\$FAKE_CREATE"
[[ -n "\${FAKE_DELETE:-}" ]] && rm -f "\$FAKE_DELETE"
[[ -n "\${FAKE_SLEEP:-}" ]] && sleep "\$FAKE_SLEEP"
echo "model: gpt-fake" >&2; printf 'tokens used\n1,234\n' >&2   # what codex exec logs
out=""; while ((\$#)); do [[ "\$1" == -o ]] && out="\$2"; shift; done
if [[ -n "\${FAKE_REVIEW:-}" ]]; then printf '%s\n' "\$FAKE_REVIEW" > "\$out"
elif [[ "\$out" == *round-1.review* ]]; then echo '$CHANGES' > "\$out"; else echo '$APPROVE' > "\$out"; fi
EOF
# Fake agy: records its arguments, prints a JSON envelope with structured_output.
cat > "$T/bin/agy" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] && { echo "agy 1.2.4-fake"; exit 0; }
[[ "\${2:-}" == "Reply with only the word ok."* ]] && { echo "\${FAKE_AGY_PROBE-ok}"; exit "\${FAKE_AGY_PROBE_EXIT:-0}"; }
printf '%s\n' "\$@" > "\$FAKE_ARGS"
# Where it ran, and what that folder held: a.py's last line, new_file.py, b.py (for +run).
pwd -P > "\$FAKE_ARGS.cwd"
printf '%s|%s|%s' "\$(tail -n 1 a.py 2>/dev/null)" "\$([[ -f new_file.py ]] && echo new)" "\$([[ -f b.py ]] && echo b)" > "\$FAKE_ARGS.copy"
[[ -n "\${FAKE_AGY_TOUCH:-}" ]] && echo touched >> "\$FAKE_AGY_TOUCH"
# FAKE_AGY_DENY=<counter file>: the first FAKE_AGY_DENY_TIMES calls (default 1) ask for a
# shell command, which plan mode denies, so they return no verdict.
if [[ -n "\${FAKE_AGY_DENY:-}" ]]; then
  n="\$(cat "\$FAKE_AGY_DENY" 2>/dev/null || echo 0)"; echo "\$((n + 1))" > "\$FAKE_AGY_DENY"
  if ((n < \${FAKE_AGY_DENY_TIMES:-1})); then
    echo '{"status":"SUCCESS","response":"","usage":{"total_tokens":5},"denied_actions":[{"action":"command","display_name":"Bash"}]}'
    exit 0
  fi
fi
echo '{"status":"SUCCESS","response":"...","structured_output":$APPROVE,"usage":{"total_tokens":1}}'
EOF
chmod +x "$T/bin/codex" "$T/bin/agy"
export PATH="$T/bin:$PATH" FAKE_ARGS="$T/args"
REVIEW="$S/run/scripts/review.sh"
CHECK="$S/check/scripts/check-prereqs.sh"

cd "$T/proj"
git init -q && git config user.email t@example.com && git config user.name t
echo "x = 1" > a.py && echo "z = 0" > b.py && git add -A && git commit -qm init
git remote add origin git@gitlab.com:me/proj.git

echo "check-prereqs.sh"
out="$("$CHECK" </dev/null)"; code=$?
check "reports ready"                      '[[ $code -eq 0 && "$out" == *"RESULT: ready"* ]]'
check "lists both reviewers"               '[[ "$out" == *"READY_REVIEWERS: codex agy"* ]]'
check "suggests glab for a GitLab remote"  '[[ "$out" == *glab* ]]'
out="$(FAKE_LOGIN_EXIT=1 "$CHECK" --need codex </dev/null)"; code=$?
check "needed codex not signed in fails"   '[[ $code -eq 1 && "$out" == *"missing codex-login"* ]]'
out="$(FAKE_LOGIN_EXIT=1 "$CHECK" </dev/null)"; code=$?
check "any one reviewer is enough"         '[[ $code -eq 0 && "$out" == *"READY_REVIEWERS: agy"* ]]'
out="$("$CHECK" --deep </dev/null)"; code=$?
check "deep: agy signed in"                '[[ $code -eq 0 && "$out" == *"signed in (test prompt"* && "$out" == *"READY_REVIEWERS: codex agy"* ]]'
out="$(FAKE_AGY_PROBE="Error: authentication required" FAKE_AGY_PROBE_EXIT=1 "$CHECK" --deep --need agy </dev/null)"; code=$?
check "deep: agy not signed in fails"      '[[ $code -eq 1 && "$out" == *"missing agy-login"* && "$out" == *"authentication required"* ]]'
out="$(FAKE_AGY_PROBE="no token" "$CHECK" --deep --need agy </dev/null)"; code=$?
check "deep: an answer other than ok fails" '[[ $code -eq 1 && "$out" == *"missing agy-login"* ]]'
check "ready says only the user starts run" '[[ "$("$CHECK" </dev/null)" == *"NEXT: only the user"* ]]'
out="$(FAKE_AGY_PROBE_EXIT=1 FAKE_AGY_PROBE="auth required" "$REVIEW" init codex,agy </dev/null 2>&1)"; code=$?
check "init with agy checks its sign-in"   '[[ $code -eq 5 && "$out" == *"missing agy-login"* ]]'
out="$(FAKE_AGY_PROBE_EXIT=1 "$REVIEW" init codex </dev/null 2>&1)"; code=$?
check "init without agy skips that check"  '[[ $code -eq 0 ]]'

echo "review.sh with codex"
out="$("$REVIEW" init codex,agy </dev/null 2>&1)"
check "init records base"                  '[[ -s .sparring/base && "$out" == *base:* ]]'
check "state dir ignores itself"           '[[ -z "$(git status --porcelain -- .sparring)" ]]'
echo "Add y." > .sparring/task.md
echo "y = 2" >> a.py && echo "print(1)" > new_file.py

out="$("$REVIEW" review 1 codex default medium </dev/null)"
check "round 1 returns JSON verdict"       '[[ "$out" == *changes_requested* ]]'
check "diff includes untracked files"      'grep -q new_file.py .sparring/round-1.diff'
check "read-only sandbox"                  'grep -qx read-only "$FAKE_ARGS"'
check "output schema passed"               'grep -q review.schema.json "$FAKE_ARGS"'
check "effort passed"                      'grep -qx model_reasoning_effort=medium "$FAKE_ARGS"'
check "default model sends no -m"          '! grep -qx -- -m "$FAKE_ARGS"'
"$REVIEW" review 1 codex default max </dev/null >/dev/null
check "max maps to xhigh for codex"        'grep -qx model_reasoning_effort=xhigh "$FAKE_ARGS"'

echo "R1: REBUTTED - not needed" > .sparring/round-1.response.md
out="$("$REVIEW" review 2 codex gpt-test high .sparring/round-1.response.md </dev/null)"
check "round 2 approves"                   '[[ "$out" == *approve* ]]'
check "explicit model sends -m"            'grep -qx gpt-test "$FAKE_ARGS"'
check "round 2 sees previous review"       'grep -q "previous review is in .sparring/round-1.review.json" "$FAKE_ARGS"'
check "round 2 sees the response"          'grep -q "round-1.response.md" "$FAKE_ARGS"'
check "round 2 is told to keep ids"        'grep -q "keeps its old id" "$FAKE_ARGS"'

echo "review.sh with agy"
"$REVIEW" review 1 codex default medium </dev/null >/dev/null   # restore a round-1 review to tiebreak on
out="$("$REVIEW" review --tiebreak 1 agy gemini-x minimal .sparring/round-1.response.md </dev/null)"
check "agy verdict unwrapped"              '[[ "$out" == *"\"verdict\""* && "$out" != *structured_output* ]]'
check "agy plan mode + sandbox"            'grep -qx plan "$FAKE_ARGS" && grep -qx -- --sandbox "$FAKE_ARGS"'
check "agy json schema passed"             'grep -qx -- --json-schema "$FAKE_ARGS"'
check "minimal maps to low for agy"        'grep -qx low "$FAKE_ARGS"'
check "agy model passed"                   'grep -qx gemini-x "$FAKE_ARGS"'
check "tiebreak prompt"                    'grep -q "independent THIRD reviewer" .sparring/round-1.tiebreak.prompt.txt'
check "tiebreak sees the rebuttals"        'grep -q "rebuttals, by issue id, are in .sparring/round-1.response.md" .sparring/round-1.tiebreak.prompt.txt'
check "tiebreak saved separately"          '[[ -s .sparring/round-1.tiebreak.review.json ]]'
check "agy is told not to run commands"    'grep -q "shell commands are not available here" "$FAKE_ARGS"'

echo "reviews.tsv"
check "has a header"                       '[[ "$(head -n 1 .sparring/reviews.tsv)" == $'"'"'round\tkind\ttool\tmodel\teffort\tseconds\ttokens\tattempts\tresult'"'"' ]]'
check "codex: model and tokens from its log" 'grep -qP "^1\treview\tcodex\tgpt-fake\tmedium\t[0-9]+\t1234\t1\tok$" .sparring/reviews.tsv'
check "every call is a line"               '[[ $(grep -c . .sparring/reviews.tsv) -eq 6 ]]'
check "agy: requested model, its tokens"   'grep -qP "^1\ttiebreak\tagy\tgemini-x\tminimal\t[0-9]+\t1\t1\tok$" .sparring/reviews.tsv'
out="$("$REVIEW" review 2 codex default medium .sparring/round-1.response.md 2>&1 >/dev/null </dev/null)"
check "prints a reviewer line"             '[[ "$out" == *"reviewer: codex, model gpt-fake, effort medium"*"tokens 1234, ok"* ]]'

echo "agy asking for a shell command"
rm -f "$T/deny"
out="$(FAKE_AGY_DENY="$T/deny" "$REVIEW" review --tiebreak 1 agy default low .sparring/round-1.response.md 2>&1 </dev/null)"; code=$?
check "retried once, then a verdict"       '[[ $code -eq 0 && "$(cat "$T/deny")" == 2 ]] && grep -q "retrying once without commands" .sparring/round-1.tiebreak.agy.log'
check "the retry is told why"              'grep -q "previous attempt asked for a shell command" "$FAKE_ARGS"'
check "attempts and summed tokens recorded" 'tail -n 1 .sparring/reviews.tsv | grep -qP "\tagy\tdefault\tlow\t[0-9]+\t6\t2\tok$"'
check "reviewer line shows the retry"      '[[ "$out" == *"tokens 6, 2 attempts, ok"* ]]'
rm -f "$T/deny"
out="$(FAKE_AGY_DENY="$T/deny" FAKE_AGY_DENY_TIMES=9 "$REVIEW" review --tiebreak 1 agy default low .sparring/round-1.response.md 2>&1 </dev/null)"; code=$?
check "denied twice: fails, no third try"  '[[ $code -eq 4 && "$(cat "$T/deny")" == 2 ]]'
check "the failure is recorded"            'tail -n 1 .sparring/reviews.tsv | grep -qP "\t2\tfailed$"'
"$REVIEW" review --tiebreak 1 agy gemini-x minimal .sparring/round-1.response.md </dev/null >/dev/null   # put the tiebreak back

echo "agy+run (disposable copy)"
rm b.py   # a deleted tracked file must be missing in the copy too
out="$(FAKE_AGY_TOUCH=a.py "$REVIEW" review --tiebreak 1 agy+run default low .sparring/round-1.response.md 2>&1 </dev/null)"; code=$?
git checkout -q -- b.py
copy_dir="$(cat "$FAKE_ARGS.cwd")"
check "+run: verdict, real tree untouched" '[[ $code -eq 0 && "$(tail -n 1 a.py)" != touched ]]'
check "+run: ran in a copy, not the project" '[[ "$copy_dir" != "$(pwd -P)" && "$copy_dir" == */sparring-copy.*/project ]]'
check "+run: copy had the developer's files" '[[ "$(cat "$FAKE_ARGS.copy")" == "y = 2|new|" ]]'
check "+run: no plan mode, no no-commands note" '! grep -qx plan "$FAKE_ARGS" && ! grep -q "shell commands are not available" "$FAKE_ARGS"'
check "+run: prompt says it is a copy"     'grep -q "disposable copy of the project" .sparring/round-1.tiebreak.prompt.txt'
check "+run: copy removed afterwards"      '[[ -n "$copy_dir" && ! -d "$copy_dir" ]]'
check "+run: recorded as agy+run"          'tail -n 1 .sparring/reviews.tsv | grep -qP "^1\ttiebreak\tagy\+run\tdefault\tlow\t"'
"$REVIEW" review 1 agy default low </dev/null >/dev/null
check "plain agy still in the project, plan mode" '[[ "$(cat "$FAKE_ARGS.cwd")" == "$(pwd -P)" ]] && grep -qx plan "$FAKE_ARGS"'
"$REVIEW" review 1 codex default medium </dev/null >/dev/null   # put round 1 back

echo "safety"
before_a="$(cat a.py)"
FAKE_TOUCH=a.py FAKE_CREATE=junk.txt FAKE_DELETE=new_file.py "$REVIEW" review 3 codex default low </dev/null >/dev/null 2>"$T/err"; code=$?
check "reviewer editing files exits 6"     '[[ $code -eq 6 ]]'
check "exit 6 names the restore command"   'grep -q "restore 3" "$T/err"'
check "snapshot leaves the index alone"    '[[ -z "$(git diff --cached --name-only)" ]]'
"$REVIEW" restore 3 </dev/null >/dev/null 2>&1; code=$?
check "restore succeeds"                   '[[ $code -eq 0 ]]'
check "restore undoes an edit"             '[[ "$(cat a.py)" == "$before_a" ]]'
check "restore brings back a deleted file" '[[ -f new_file.py ]]'
check "restore removes a created file"     '[[ ! -e junk.txt ]]'
"$REVIEW" restore 99 </dev/null >/dev/null 2>&1; code=$?
check "restore without snapshot fails"     '[[ $code -eq 2 ]]'
mkdir -p "sub dir" && printf 'one\r\ntwo\r\n' > "sub dir/crlf ü.txt"
crlf_sum="$(git hash-object --no-filters "sub dir/crlf ü.txt")"
FAKE_TOUCH="sub dir/crlf ü.txt" FAKE_DELETE=b.py FAKE_CREATE="sub dir/junk.txt" \
  "$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "second reviewer edit exits 6"       '[[ $code -eq 6 ]]'
"$REVIEW" restore 3 </dev/null >"$T/rout" 2>&1; code=$?
check "restore keeps CRLF bytes exactly"   '[[ $code -eq 0 && "$(git hash-object --no-filters "sub dir/crlf ü.txt")" == "$crlf_sum" ]]'
check "restore brings back an untouched file" '[[ "$(cat b.py)" == "z = 0" ]]'
check "restore removes a file in a subdir" '[[ ! -e "sub dir/junk.txt" ]]'
rm -rf "sub dir"
"$REVIEW" review 3 nosuchtool default low </dev/null >/dev/null 2>&1; code=$?
check "rejects an unknown tool"            '[[ $code -ne 0 ]]'
"$REVIEW" review 3 codex default turbo </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad effort"               '[[ $code -ne 0 ]]'
"$REVIEW" review 3 codex "bad model;rm" low </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad model name"           '[[ $code -ne 0 ]]'

echo "verdict validation"
out="$(FAKE_REVIEW='{"verdict":"approve","summary":"s","issues":[{"id":"R9","severity":"blocking","location":"x","comment":"c","suggestion":""}],"withdrawn":[]}' "$REVIEW" review 3 codex default low </dev/null 2>/dev/null)"
check "approve with blocking is downgraded" '[[ "$out" == *changes_requested* && "$out" == *"approve changed"* ]]'
FAKE_REVIEW='{"verdict":"maybe","issues":[],"withdrawn":[]}' "$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "bad verdict value exits 4"          '[[ $code -eq 4 ]]'
FAKE_REVIEW='not json, but "verdict"' "$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "non-JSON output exits 4"            '[[ $code -eq 4 ]]'
out="$(FAKE_REVIEW='{"verdict":"approve","summary":"s","issues":[{"id":"N1","severity":"nit","location":"x","comment":"c","suggestion":""}],"withdrawn":[]}' "$REVIEW" review 3 codex default low </dev/null 2>/dev/null)"
check "approve with only nits stays"       '[[ "$out" == *approve* && "$out" != *changes_requested* ]]'

echo "timeout"
start=$SECONDS
FAKE_SLEEP=30 "$REVIEW" review --timeout 2 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "slow reviewer exits 7"              '[[ $code -eq 7 ]]'
check "and is stopped promptly"            '(( SECONDS - start < 15 ))'
"$REVIEW" review --timeout abc 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad timeout"              '[[ $code -ne 0 && $code -ne 7 ]]'

echo "file names and modes"
printf 'print(3)\n' > "naïve file.py"
"$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1
check "non-ASCII untracked name in diff"   'grep -q "b/naïve file.py" .sparring/round-3.diff'
rm -f "naïve file.py"
cp -r "$ROOT/plugins" "$T/plugins-noexec"
find "$T/plugins-noexec" -name '*.sh' -exec chmod -x {} +
NOEXEC="$T/plugins-noexec/sparring/skills/run/scripts/review.sh"
out="$(FAKE_LOGIN_EXIT=1 bash "$NOEXEC" init codex </dev/null 2>&1)"; code=$?
check "check runs without exec bit"        '[[ $code -eq 5 ]]'
bash "$NOEXEC" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "adapter runs without exec bit"      '[[ $code -eq 0 ]]'

git checkout -q -- . && rm -f new_file.py
"$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "no changes exits 3"                 '[[ $code -eq 3 ]]'
check "index left clean"                   '[[ -z "$(git status --porcelain)" ]]'

echo "new run"
out="$("$REVIEW" init codex,agy+run </dev/null 2>&1)"; code=$?
check "init accepts agy+run"               '[[ $code -eq 0 ]]'
check "init moves the old run aside"       '[[ "$out" == *"previous run moved"* && -f .sparring/previous/round-1.review.json ]]'
check "init moves reviews.tsv aside too"   '[[ -f .sparring/previous/reviews.tsv && ! -f .sparring/reviews.tsv ]]'
check "init leaves no stale rounds"        '! compgen -G ".sparring/round-*" >/dev/null && [[ ! -f .sparring/task.md ]]'

echo "status"
# Round files are written by hand here; status only reads them.
ST=.st
rv() {  # rv <file> [blocking ids...]
  local f="$1" items="" id v=changes_requested; shift
  for id in "$@"; do items="${items:+$items,}{\"id\":\"$id\",\"severity\":\"blocking\",\"location\":\"a\",\"comment\":\"c\",\"suggestion\":\"\"}"; done
  [[ -z "$items" ]] && v=approve
  echo "{\"verdict\":\"$v\",\"summary\":\"s\",\"issues\":[$items],\"withdrawn\":[]}" > "$ST/$f"
}
st() { SPARRING_DIR=$ST "$REVIEW" status </dev/null 2>&1; }
field() { st | sed -n "s/^$1: //p"; }
SPARRING_DIR=$ST "$REVIEW" init codex --rounds 2 --tiebreaker </dev/null >/dev/null 2>&1
check "init saves rounds and tiebreaker"   'grep -qx rounds=2 $ST/config && grep -qx tiebreaker=1 $ST/config'
check "fresh run: review 1"                '[[ "$(field next)" == "review 1" ]]'
rv round-1.review.json R1 R2
check "after review: respond"              '[[ "$(field next)" == "respond 1" ]]'
printf 'R1: FIXED - x\n- **R2**: REBUTTED - y\n' > $ST/round-1.response.md
check "after response: next review"        '[[ "$(field next)" == "review 2" && "$(field response_file)" == "$ST/round-1.response.md" && "$(field tier)" == same ]]'
rv round-2.review.json R2
echo 'R2: REBUTTED - still' > $ST/round-2.response.md
check "round limit: escalation on deep"    '[[ "$(field next)" == "review 3" && "$(field tier)" == deep && "$(field stage)" == escalation ]]'
check "kept rebuttal is disputed"          '[[ "$(field disputed)" == R2 ]]'
rv round-3.review.json R2 R3
check "escalation: respond"                '[[ "$(field next)" == "respond 3" ]]'
printf 'R2: REBUTTED\nR3: rebutted, no\n' > $ST/round-3.response.md
check "rebuttal left: tiebreak"            '[[ "$(field next)" == "tiebreak 3" ]]'
rv round-3.tiebreak.review.json R3
check "tiebreak kept: fix it"              '[[ "$(field next)" == "fix-after-tiebreak 3" && "$(field fix)" == R3 && "$(field closed)" == R2 ]]'
echo 'R3: FIXED after tiebreak, z' >> $ST/round-3.response.md
check "fixed after tiebreak: final review" '[[ "$(field next)" == "review 4" && "$(field stage)" == final ]]'
rv round-4.review.json R2
check "closed issue raised again ignored"  '[[ "$(field next)" == finish && "$(field result)" == approved-after-tiebreak ]]'
rv round-4.review.json R5
check "still open: ask the user"           '[[ "$(field next)" == ask-user && "$(field open)" == R5 ]]'
echo 'R5: user chose the reviewer fix' > $ST/round-4.response.md
check "decisions recorded: last review"    '[[ "$(field next)" == "review 5" ]]'
rv round-5.review.json R5
check "after last review: finish"          '[[ "$(field next)" == finish && "$(field result)" == user-decided ]]'

SPARRING_DIR=$ST "$REVIEW" init codex </dev/null >/dev/null 2>&1
check "default limit is 3, no tiebreaker"  '[[ "$(field limit)" == 3 ]] && grep -qx tiebreaker=0 $ST/config'
rv round-1.review.json R1; echo 'R1: FIXED' > $ST/round-1.response.md
rv round-2.review.json R1; echo 'R1: FIXED, again' > $ST/round-2.response.md
check "no progress: tier up"               '[[ "$(field next)" == "review 3" && "$(field tier)" == up ]]'
SPARRING_DIR=$ST "$REVIEW" init codex </dev/null >/dev/null 2>&1
rv round-1.review.json R1; echo 'R1: REBUTTED - wrong' > $ST/round-1.response.md
rv round-2.review.json R4
check "new id is a new issue"              '[[ "$(field next)" == "respond 2" && "$(field disputed)" == "" ]]'
printf 'R4: SAME AS R1\nR4: REBUTTED - see round 1\n' > $ST/round-2.response.md
check "SAME AS links ids"                  '[[ "$(field open)" == R1 && "$(field disputed)" == R1 ]]'
check "all disputed: early deadlock"       '[[ "$(field next)" == "review 3" && "$(field stage)" == escalation && "$(field note)" == *"before the round limit"* ]]'
rv round-3.review.json R1; echo 'R1: REBUTTED' > $ST/round-3.response.md
check "no tiebreaker: final review"        '[[ "$(field next)" == "review 4" ]]'
SPARRING_DIR=$ST "$REVIEW" init codex </dev/null >/dev/null 2>&1
rv round-1.review.json
check "approve: finish"                    '[[ "$(field next)" == finish && "$(field result)" == approved ]]'
rm -rf $ST

echo "launcher"
mkdir -p "$T/bin2"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/bin2/claude"; chmod +x "$T/bin2/claude"
out="$(PATH="$T/bin2:$PATH" "$ROOT/bin/sparring" --orchestrator fable --dev sonnet,opus --tiebreaker agy/default:high --rounds 4 add rate limiting)"
expected=$'--model\nfable\n/sparring:run orchestrator=fable dev=sonnet,opus tiebreaker=agy/default:high rounds=4 add rate limiting'
check "passes --model and options"         '[[ "$out" == "$expected" ]]'

echo
echo "$pass passed, $fail failed"
((fail == 0))
