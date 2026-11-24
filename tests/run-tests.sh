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
out=""; while ((\$#)); do [[ "\$1" == -o ]] && out="\$2"; shift; done
if [[ "\$out" == *round-1.review* ]]; then echo '$CHANGES' > "\$out"; else echo '$APPROVE' > "\$out"; fi
EOF
# Fake agy: records its arguments, prints a JSON envelope with structured_output.
cat > "$T/bin/agy" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == --version ]] && { echo "agy 1.2.4-fake"; exit 0; }
printf '%s\n' "\$@" > "\$FAKE_ARGS"
echo '{"status":"SUCCESS","response":"...","structured_output":$APPROVE,"usage":{"total_tokens":1}}'
EOF
chmod +x "$T/bin/codex" "$T/bin/agy"
export PATH="$T/bin:$PATH" FAKE_ARGS="$T/args"
REVIEW="$S/run/scripts/review.sh"
CHECK="$S/check/scripts/check-prereqs.sh"

cd "$T/proj"
git init -q && git config user.email t@example.com && git config user.name t
echo "x = 1" > a.py && git add -A && git commit -qm init
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

echo "safety"
FAKE_TOUCH=a.py "$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "reviewer editing files exits 6"     '[[ $code -eq 6 ]]'
git checkout -q -- a.py && echo "y = 2" >> a.py
"$REVIEW" review 3 nosuchtool default low </dev/null >/dev/null 2>&1; code=$?
check "rejects an unknown tool"            '[[ $code -ne 0 ]]'
"$REVIEW" review 3 codex default turbo </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad effort"               '[[ $code -ne 0 ]]'
"$REVIEW" review 3 codex "bad model;rm" low </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad model name"           '[[ $code -ne 0 ]]'
git checkout -q -- . && rm -f new_file.py
"$REVIEW" review 3 codex default low </dev/null >/dev/null 2>&1; code=$?
check "no changes exits 3"                 '[[ $code -eq 3 ]]'
check "index left clean"                   '[[ -z "$(git status --porcelain)" ]]'

echo "launcher"
mkdir -p "$T/bin2"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/bin2/claude"; chmod +x "$T/bin2/claude"
out="$(PATH="$T/bin2:$PATH" "$ROOT/bin/sparring" --orchestrator fable --dev sonnet,opus --tiebreaker agy/default:high --rounds 4 add rate limiting)"
expected=$'--model\nfable\n/sparring:run orchestrator=fable dev=sonnet,opus tiebreaker=agy/default:high rounds=4 add rate limiting'
check "passes --model and options"         '[[ "$out" == "$expected" ]]'

echo
echo "$pass passed, $fail failed"
((fail == 0))
