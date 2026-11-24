#!/usr/bin/env bash
# Smoke tests for the bash scripts, using a fake `codex` on PATH. No network, no real models.
#   bash tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/plugins/claudex-team/skills"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok()   { echo "  ok    $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fake codex: records its arguments, writes a review to the -o file.
mkdir -p "$T/bin" "$T/proj"
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo "codex-cli 0.0.0-fake"; exit 0; }
[[ "${1:-} ${2:-}" == "login status" ]] && { echo "Logged in using ChatGPT"; exit "${FAKE_LOGIN_EXIT:-0}"; }
printf '%s\n' "$@" > "$FAKE_ARGS"
out=""; while (($#)); do [[ "$1" == -o ]] && out="$2"; shift; done
if [[ "$out" == *round-1.* ]]; then
  echo '{"verdict":"changes_requested","summary":"s","issues":[{"id":"R1","severity":"blocking","location":"a.py:1","comment":"c","suggestion":""}],"withdrawn":[]}' > "$out"
else
  echo '{"verdict":"approve","summary":"s","issues":[],"withdrawn":["R1"]}' > "$out"
fi
EOF
chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH" FAKE_ARGS="$T/args"
REVIEW="$S/run/scripts/codex-review.sh"
CHECK="$S/check/scripts/check-prereqs.sh"

cd "$T/proj"
git init -q && git config user.email t@example.com && git config user.name t
echo "x = 1" > a.py && git add -A && git commit -qm init
git remote add origin git@gitlab.com:me/proj.git

echo "check-prereqs.sh"
out="$("$CHECK" </dev/null)"; code=$?
check "reports ready"                    '[[ $code -eq 0 && "$out" == *"RESULT: ready"* ]]'
check "suggests glab for a GitLab remote" '[[ "$out" == *glab* ]]'
out="$(FAKE_LOGIN_EXIT=1 "$CHECK" </dev/null)"; code=$?
check "flags a missing Codex sign-in"     '[[ $code -eq 1 && "$out" == *"missing codex-login"* ]]'

echo "codex-review.sh"
out="$("$REVIEW" init </dev/null 2>&1)"
check "init records base"                 '[[ -s .review/base && "$out" == *base:* ]]'
check "state dir ignores itself"          '[[ -z "$(git status --porcelain -- .review)" ]]'
echo "Add y." > .review/task.md
echo "y = 2" >> a.py && echo "print(1)" > new_file.py

out="$("$REVIEW" review 1 default medium </dev/null)"
check "round 1 returns JSON verdict"      '[[ "$out" == *changes_requested* ]]'
check "diff includes untracked files"     'grep -q new_file.py .review/round-1.diff'
check "read-only sandbox"                 'grep -qx read-only "$FAKE_ARGS"'
check "output schema passed"              'grep -q review.schema.json "$FAKE_ARGS"'
check "effort passed"                     'grep -qx model_reasoning_effort=medium "$FAKE_ARGS"'
check "default model sends no -m"         '! grep -qx -- -m "$FAKE_ARGS"'

echo "R1: FIXED - added a test" > .review/round-1.response.md
out="$("$REVIEW" review 2 gpt-test high .review/round-1.response.md </dev/null)"
check "round 2 approves"                  '[[ "$out" == *approve* ]]'
check "explicit model sends -m"           'grep -qx gpt-test "$FAKE_ARGS"'
check "round 2 sees previous review"      'grep -q "previous review is in .review/round-1.review.json" "$FAKE_ARGS"'
check "round 2 sees the response"         'grep -q "round-1.response.md" "$FAKE_ARGS"'

"$REVIEW" review 3 default turbo </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad effort"              '[[ $code -ne 0 ]]'
"$REVIEW" review 3 "bad model;rm" low </dev/null >/dev/null 2>&1; code=$?
check "rejects a bad model name"          '[[ $code -ne 0 ]]'
git checkout -q -- . && rm -f new_file.py
"$REVIEW" review 3 default low </dev/null >/dev/null 2>&1; code=$?
check "no changes exits 3"                '[[ $code -eq 3 ]]'
git status --porcelain | grep -q . && bad "index left clean" || ok "index left clean"

echo "launcher"
mkdir -p "$T/bin2"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@"\n' > "$T/bin2/claude"; chmod +x "$T/bin2/claude"
out="$(PATH="$T/bin2:$PATH" "$ROOT/bin/claudex" --orchestrator fable --dev sonnet,opus --rounds 4 add rate limiting)"
check "passes --model and options"        '[[ "$out" == $'"'"'--model\nfable\n/claudex-team:run orchestrator=fable dev=sonnet,opus rounds=4 add rate limiting'"'"' ]]'

echo
echo "$pass passed, $fail failed"
((fail == 0))
