#!/usr/bin/env bash
# Reviewer driver for the sparring run skill.
#
#   review.sh init [tools]
#       Check prerequisites (tools: comma list of reviewer CLIs to require, e.g. codex,agy),
#       create .sparring/, record the base commit, warn about uncommitted changes.
#
#   review.sh review [--tiebreak] <round> <tool> <model> <effort> [response-file]
#       Run one review round with a reviewer adapter and print the JSON verdict on stdout.
#       tool:   codex | agy             (adapters live in reviewers/<tool>.sh)
#       model:  a model name for that tool, or "default" for the tool's configured default
#       effort: minimal | low | medium | high | xhigh | max   (adapters map what their CLI supports)
#       --tiebreak: act as an independent third reviewer on the issues still disputed
#
# Exit codes: 2 setup, 3 nothing to review, 4 reviewer failed, 5 prerequisites missing,
#             6 reviewer changed files (changes are kept for you to inspect).
# SPARRING_DIR overrides the state directory (default: .sparring)
set -euo pipefail

die() { echo "error: $*" >&2; exit "${2:-1}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/../review.schema.json"
CHECK="$SCRIPT_DIR/../../check/scripts/check-prereqs.sh"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository" 2
cd "$(git rev-parse --show-toplevel)"
STATE_DIR="${SPARRING_DIR:-.sparring}"

# Fingerprint of the working tree (tracked changes + untracked files), excluding our state.
tree_state() {
  { git status --porcelain=v1 -uall -- . ":(exclude)$STATE_DIR"
    git diff HEAD -- . ":(exclude)$STATE_DIR"
    git ls-files --others --exclude-standard -z -- . ":(exclude)$STATE_DIR" |
      while IFS= read -r -d '' f; do printf '%s ' "$f"; git hash-object -- "$f"; done
  } | git hash-object --stdin
}

cmd_init() {
  local need="${1:-}"
  if [[ -x "$CHECK" ]]; then
    local out
    if ! out="$("$CHECK" ${need:+--need "$need"} 2>&1)"; then
      echo "$out"; die "prerequisites missing; run /sparring:check" 5
    fi
  fi
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
  local tiebreak=0
  [[ "${1:-}" == --tiebreak ]] && { tiebreak=1; shift; }
  [[ $# -ge 4 ]] || die "usage: review [--tiebreak] <round> <tool> <model|default> <effort> [response-file]"
  local round="$1" tool="$2" model="$3" effort="$4" response_file="${5:-}"
  [[ "$round" =~ ^[0-9]+$ ]] || die "round must be a number"
  [[ "$tool" =~ ^[a-z0-9-]+$ && -f "$SCRIPT_DIR/reviewers/$tool.sh" ]] || die "unknown reviewer tool: $tool (have: $(cd "$SCRIPT_DIR/reviewers" && ls *.sh | sed 's/\.sh$//' | tr '\n' ' '))"
  [[ "$model" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "invalid model name: $model"
  [[ "$effort" =~ ^(minimal|low|medium|high|xhigh|max)$ ]] || die "effort must be minimal, low, medium, high, xhigh or max"
  [[ -f "$STATE_DIR/base" ]] || die "run '$0 init' first" 2
  [[ -f "$STATE_DIR/task.md" ]] || die "$STATE_DIR/task.md is missing; write the task there first" 2
  [[ -z "$response_file" || -f "$response_file" ]] || die "response file not found: $response_file" 2

  local base tag diff_file out_file log_file prompt_file prev_file
  base="$(cat "$STATE_DIR/base")"
  tag="round-$round"; ((tiebreak)) && tag="round-$round.tiebreak"
  diff_file="$STATE_DIR/$tag.diff"
  out_file="$STATE_DIR/$tag.review.json"
  log_file="$STATE_DIR/$tag.$tool.log"
  prompt_file="$STATE_DIR/$tag.prompt.txt"
  prev_file="$STATE_DIR/round-$((round - 1)).review.json"
  ((tiebreak)) && prev_file="$STATE_DIR/round-$round.review.json"

  # Tracked changes, then each new untracked file as an addition. The git index is not touched.
  git diff "$base" -- . ":(exclude)$STATE_DIR" > "$diff_file"
  while IFS= read -r -d '' f; do
    git diff --no-index -- /dev/null "$f" >> "$diff_file" || true
  done < <(git ls-files --others --exclude-standard -z -- . ":(exclude)$STATE_DIR")
  [[ -s "$diff_file" ]] || die "no changes against $base to review" 3

  # The prompt holds no user text (task and diff are read from files) and no double quotes,
  # so every adapter can pass it as one argument on every platform.
  {
    if ((tiebreak)); then
      echo "You are an independent THIRD reviewer. A developer agent and a reviewer agent disagree. Do not edit any files."
    else
      echo "You are the code REVIEWER in an automated developer/reviewer loop. Do not edit any files."
    fi
    cat <<EOF

The task the developer was given is in the file $STATE_DIR/task.md.
The developer's changes, as a diff against commit $base, are in the file $diff_file.
Read both, and read any surrounding code you need. You may run read-only commands such as tests or linters.

Review rules:
- Judge the change against the task: correctness, bugs, security, error handling, missing tests for new behavior, breaking changes.
- severity blocking means it must be fixed before merge. nit means optional style or preference. Never mark a preference as blocking.
- Give every issue a stable id like R1, R2. Reuse the same id for the same issue in later rounds; new issues get new ids.
- verdict approve only when no blocking issues remain. Nits alone do not block approval.
- Be specific: point to the file and line, and say what to change.
EOF
    if ((tiebreak)); then
      [[ -f "$prev_file" ]] || die "tiebreak needs $prev_file" 2
      echo
      echo "The reviewer's latest review is in $prev_file."
      [[ -n "$response_file" ]] && echo "The developer's rebuttals, by issue id, are in $response_file."
      echo "Judge ONLY the blocking issues in that review. For each one, decide on the merits who is right."
      echo "If the issue is real, keep it in issues with the same id and explain why in comment."
      echo "If the developer is right, put its id in withdrawn. Do not raise new issues unless they are serious bugs."
    elif [[ -f "$prev_file" ]]; then
      echo
      echo "This is round $round. The previous review is in $prev_file."
      [[ -n "$response_file" ]] && echo "The developer's response (fixes and rebuttals, by issue id) is in $response_file."
      echo "For each earlier issue: if it is fixed, or the developer's rebuttal convinces you, put its id in withdrawn."
      echo "Otherwise keep it in issues with the same id, and say in comment why the rebuttal does not convince you."
      echo "Change your mind when the argument is good; do not drop real bugs to be agreeable."
    fi
  } > "$prompt_file"

  local before after
  before="$(tree_state)"
  rm -f "$out_file"
  if ! "$SCRIPT_DIR/reviewers/$tool.sh" "$model" "$effort" "$SCHEMA" "$out_file" "$prompt_file" 2>"$log_file"; then
    echo "error: $tool review failed; last lines of $log_file:" >&2
    tail -n 20 "$log_file" >&2
    exit 4
  fi
  after="$(tree_state)"
  [[ "$before" == "$after" ]] || die "the $tool reviewer changed files in the working tree; review rejected. Inspect with: git status (if they are build or test artifacts, add them to .gitignore)" 6
  [[ -s "$out_file" ]] || die "$tool produced no review output (see $log_file)" 4
  grep -q '"verdict"' "$out_file" || die "$tool output is not a verdict (see $out_file and $log_file)" 4
  cat "$out_file"
}

case "${1:-}" in
  init)   shift; cmd_init "$@" ;;
  review) shift; cmd_review "$@" ;;
  *) die "usage: $0 init [tools] | review [--tiebreak] <round> <tool> <model|default> <effort> [response-file]" ;;
esac
