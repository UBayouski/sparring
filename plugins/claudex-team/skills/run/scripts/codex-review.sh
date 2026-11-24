#!/usr/bin/env bash
# Codex reviewer wrapper for the claudex-team run skill.
#
#   codex-review.sh init
#       Check prerequisites, create .review/, record the base commit,
#       and warn about uncommitted changes.
#
#   codex-review.sh review <round> <model> <effort> [response-file]
#       Run one Codex review round and print the JSON verdict on stdout.
#       model:  a Codex model name, or "default" for Codex's configured default
#       effort: minimal | low | medium | high | xhigh
#       response-file: the developer's fixes and rebuttals for the previous round
#
#   CLAUDEX_DIR overrides the state directory (default: .review)
set -euo pipefail

die() { echo "error: $*" >&2; exit "${2:-1}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../review.schema.json"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository" 2
cd "$(git rev-parse --show-toplevel)"
STATE_DIR="${CLAUDEX_DIR:-.review}"
CHECK="$SCRIPT_DIR/../../check/scripts/check-prereqs.sh"

cmd_init() {
  if [[ -x "$CHECK" ]] && ! "$CHECK" >"${TMPDIR:-/tmp}/claudex-check.$$" 2>&1; then
    cat "${TMPDIR:-/tmp}/claudex-check.$$"; rm -f "${TMPDIR:-/tmp}/claudex-check.$$"
    die "prerequisites missing; run /claudex-team:check" 5
  fi
  rm -f "${TMPDIR:-/tmp}/claudex-check.$$"
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "repository has no commits yet; make an initial commit first" 2
  mkdir -p "$STATE_DIR"
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  printf '*\n' > "$STATE_DIR/.gitignore"
  git rev-parse HEAD > "$STATE_DIR/base"
  echo "base: $(cat "$STATE_DIR/base")"
  if [[ -n "$(git status --porcelain -- . ":(exclude)$STATE_DIR")" ]]; then
    echo "warning: uncommitted changes exist; they will be included in the review"
    git status --short -- . ":(exclude)$STATE_DIR"
  fi
}

cmd_review() {
  local usage="usage: review <round> <model|default> <effort> [response-file]"
  [[ $# -ge 3 ]] || die "$usage"
  local round="$1" model="$2" effort="$3"
  local response_file="${4:-}"
  [[ "$round" =~ ^[0-9]+$ ]] || die "round must be a number"
  [[ "$effort" =~ ^(minimal|low|medium|high|xhigh)$ ]] || die "effort must be minimal, low, medium, high or xhigh"
  [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "invalid model name: $model"

  command -v codex >/dev/null 2>&1 || die "codex CLI not found; run /claudex-team:check" 127
  [[ -f "$STATE_DIR/base" ]] || die "run '$0 init' first" 2
  [[ -f "$STATE_DIR/task.md" ]] || die "$STATE_DIR/task.md is missing; write the task there first" 2
  [[ -z "$response_file" || -f "$response_file" ]] || die "response file not found: $response_file" 2

  local base diff_file out_file log_file prev_file
  base="$(cat "$STATE_DIR/base")"
  diff_file="$STATE_DIR/round-$round.diff"
  out_file="$STATE_DIR/round-$round.review.json"
  log_file="$STATE_DIR/round-$round.codex.log"
  prev_file="$STATE_DIR/round-$((round - 1)).review.json"

  # Tracked changes, then each new untracked file as an addition. The git index is not touched.
  git diff "$base" -- . ":(exclude)$STATE_DIR" > "$diff_file"
  while IFS= read -r -d '' f; do
    git diff --no-index -- /dev/null "$f" >> "$diff_file" || true
  done < <(git ls-files --others --exclude-standard -z -- . ":(exclude)$STATE_DIR")
  [[ -s "$diff_file" ]] || die "no changes against $base to review" 3

  local prompt
  # The prompt holds no user text (task and diff are read from files), so it is safe to
  # pass as one argument on every platform, including Windows PowerShell 5.1.
  prompt="You are the code REVIEWER in an automated developer/reviewer loop. Do not edit any files.

The task the developer was given is in the file $STATE_DIR/task.md.
The developer's changes, as a diff against commit $base, are in the file $diff_file.
Read both, and read any surrounding code you need. You may run read-only commands such as tests or linters.

Review rules:
- Judge the change against the task: correctness, bugs, security, error handling, missing tests for new behavior, breaking changes.
- severity blocking means it must be fixed before merge. nit means optional style or preference. Never mark a preference as blocking.
- Give every issue a stable id like R1, R2. Reuse the same id for the same issue in later rounds; new issues get new ids.
- verdict approve only when no blocking issues remain. Nits alone do not block approval.
- Be specific: point to the file and line, and say what to change."

  if [[ -f "$prev_file" ]]; then
    prompt+="

This is round $round. Your previous review is in $prev_file."
    if [[ -n "$response_file" ]]; then
      prompt+=" The developer's response (fixes and rebuttals, by issue id) is in $response_file."
    fi
    prompt+="
For each earlier issue: if it is fixed, or the developer's rebuttal convinces you, put its id in withdrawn.
Otherwise keep it in issues with the same id, and say in comment why the rebuttal does not convince you.
Change your mind when the argument is good; do not drop real bugs to be agreeable."
  fi

  local args=(exec --sandbox read-only --output-schema "$SCHEMA" -o "$out_file" -c "model_reasoning_effort=$effort")
  [[ "$model" != default ]] && args+=(-m "$model")

  if ! codex "${args[@]}" "$prompt" >/dev/null 2>"$log_file"; then
    echo "error: codex exec failed; last lines of $log_file:" >&2
    tail -n 20 "$log_file" >&2
    exit 4
  fi
  [[ -s "$out_file" ]] || die "codex produced no review output (see $log_file)" 4
  cat "$out_file"
}

case "${1:-}" in
  init)   shift; cmd_init "$@" ;;
  review) shift; cmd_review "$@" ;;
  *) die "usage: $0 init | review <round> <model|default> <effort> [response-file]" ;;
esac
