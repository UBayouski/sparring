#!/usr/bin/env bash
# Reviewer driver for the sparring run skill.
#
#   review.sh init [tools] [--rounds N] [--tiebreaker]
#       Check prerequisites (tools: comma list of reviewer CLIs to require, e.g. codex,agy),
#       create .sparring/, record the base commit, warn about uncommitted changes.
#       Files from an earlier run are moved to .sparring/previous/. The round limit
#       (default 3) and whether a tiebreaker is set are saved for "status".
#
#   review.sh status
#       Read the round files and print where the loop stands and what to do next: stage,
#       next action, response file to pass, tier change, open/disputed/closed issues.
#       Changes nothing. Needs jq, python3 or node (or hands over to review.ps1 status).
#
#   review.sh review [--tiebreak] [--timeout SECONDS] <round> <tool> <model> <effort> [response-file]
#       Run one review round with a reviewer adapter and print the JSON verdict on stdout.
#       tool:   codex | agy             (adapters live in reviewers/<tool>.sh)
#       model:  a model name for that tool, or "default" for the tool's configured default
#       effort: minimal | low | medium | high | xhigh | max   (adapters map what their CLI supports)
#       --tiebreak: act as an independent third reviewer on the issues still disputed
#       --timeout:  stop the reviewer after this many seconds (default $SPARRING_REVIEW_TIMEOUT,
#                   or 540, which fits inside Claude Code's 10-minute tool limit)
#
#       The verdict is checked against the schema. An "approve" that still lists blocking
#       issues is changed to "changes_requested". Before the reviewer runs, the working tree
#       is saved as a git tree object (nothing is committed, the index is not touched).
#
#   review.sh restore [--tiebreak] <round>
#       Put the working tree back exactly as it was before that review round's reviewer ran:
#       files it changed or deleted come back, and files it created are removed.
#
# Exit codes: 2 setup, 3 nothing to review, 4 reviewer failed or gave an invalid verdict,
#             5 prerequisites missing, 6 reviewer changed files (changes are kept for you to
#             inspect; undo them with "restore"), 7 reviewer timed out.
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

# Save the working tree as a git tree object and print its id: HEAD, plus every changed or
# untracked (not ignored) file stored byte for byte (--no-filters, so no line-ending
# conversion), minus deleted files. A private index is used; the real index is never touched.
snapshot_tree() {
  local idx="$STATE_DIR/snapshot.index" f sha mode tree
  rm -f "$idx"
  GIT_INDEX_FILE="$idx" git read-tree HEAD || return 1
  while IFS= read -r -d '' f; do
    if [[ -L "$f" ]]; then
      mode=120000; sha="$(printf '%s' "$(readlink -- "$f")" | git hash-object -w --stdin)" || return 1
    elif [[ -f "$f" ]]; then
      mode=100644; [[ -x "$f" ]] && mode=100755
      sha="$(git hash-object -w --no-filters -- "$f")" || return 1
    elif [[ -e "$f" ]]; then
      continue   # a submodule or other non-file: not snapshotted
    else
      GIT_INDEX_FILE="$idx" git update-index --force-remove -- "$f" || return 1
      continue
    fi
    GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "$mode" "$sha" "$f" || return 1
  done < <(git diff --name-only -z HEAD -- . ":(exclude)$STATE_DIR"
           git ls-files --others --exclude-standard -z -- . ":(exclude)$STATE_DIR")
  tree="$(GIT_INDEX_FILE="$idx" git write-tree)" || return 1
  rm -f "$idx"
  echo "$tree"
}

round_tag() {  # [--tiebreak] <round>
  local suffix=""
  [[ "${1:-}" == --tiebreak ]] && { suffix=.tiebreak; shift; }
  [[ "${1:-}" =~ ^[0-9]+$ ]] || die "round must be a number"
  echo "round-$1$suffix"
}

# Put back the working tree saved by snapshot_tree. Only paths that differ from HEAD now, or
# differed before the review, are touched; the index is never touched.
cmd_restore() {
  local tag snap f entry mode sha
  tag="$(round_tag "$@")"
  [[ -s "$STATE_DIR/$tag.snapshot" ]] || die "no snapshot for $tag" 2
  snap="$(cat "$STATE_DIR/$tag.snapshot")"
  while IFS= read -r -d '' f; do
    entry="$(git ls-tree "$snap" -- ":(literal)$f")"
    if [[ -z "$entry" ]]; then
      rm -f -- "$f"                                         # created by the reviewer, or deleted before
    elif git diff --quiet HEAD "$snap" -- ":(literal)$f"; then
      git restore --source=HEAD --worktree -- ":(literal)$f"   # was unchanged: normal checkout
    else
      mode="${entry%% *}"; sha="${entry#* blob }"; sha="${sha%%$'\t'*}"
      mkdir -p -- "$(dirname -- "$f")"
      rm -f -- "$f"
      if [[ "$mode" == 120000 ]]; then
        ln -s -- "$(git cat-file blob "$sha")" "$f"
      else
        git cat-file blob "$sha" > "$f"                       # exact bytes, as saved
        [[ "$mode" == 100755 ]] && chmod +x -- "$f"
      fi
    fi
  done < <({ git diff --name-only -z HEAD "$snap" -- . ":(exclude)$STATE_DIR"
             git diff --name-only -z HEAD -- . ":(exclude)$STATE_DIR"
             git ls-files --others --exclude-standard -z -- . ":(exclude)$STATE_DIR"
           } | sort -z -u)
  # Compare content, not git status: with core.autocrlf an untouched file restored from HEAD
  # can look modified to status while its content is unchanged.
  if [[ "$(snapshot_tree)" != "$snap" ]]; then
    die "files restored, but the tree still differs from before the review; inspect with: git status"
  fi
  echo "restored the working tree to its state before the $tag review"
}

cmd_init() {
  local need="" rounds=3 tiebreaker=0
  while (($#)); do
    case "$1" in
      --rounds)     [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "--rounds needs a positive number"; rounds="$2"; shift 2 ;;
      --tiebreaker) tiebreaker=1; shift ;;
      --*)          die "unknown option: $1" ;;
      *)            need="$1"; shift ;;
    esac
  done
  # Run through bash so a lost executable bit cannot skip the check.
  if [[ -f "$CHECK" ]]; then
    local out
    if ! out="$(bash "$CHECK" ${need:+--need "$need"} 2>&1)"; then
      echo "$out"; die "prerequisites missing; run /sparring:check" 5
    fi
  fi
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "repository has no commits yet; make an initial commit first" 2
  mkdir -p "$STATE_DIR"
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  printf '*\n' > "$STATE_DIR/.gitignore"
  # A new run starts clean, so stale rounds can never be read as this run's. The last run's
  # files are kept in previous/ (replacing the run before it).
  if compgen -G "$STATE_DIR/round-*" >/dev/null; then
    rm -rf "$STATE_DIR/previous"
    mkdir -p "$STATE_DIR/previous"
    mv "$STATE_DIR"/round-* "$STATE_DIR/previous/"
    for f in task.md base config; do if [[ -f "$STATE_DIR/$f" ]]; then mv "$STATE_DIR/$f" "$STATE_DIR/previous/"; fi; done
    echo "previous run moved to $STATE_DIR/previous/"
  fi
  git rev-parse HEAD > "$STATE_DIR/base"
  printf 'rounds=%s\ntiebreaker=%s\n' "$rounds" "$tiebreaker" > "$STATE_DIR/config"
  echo "base: $(cat "$STATE_DIR/base")"
  echo "rounds: $rounds, tiebreaker: $( ((tiebreaker)) && echo yes || echo no)"
  if ! json_tool >/dev/null && ! command -v powershell.exe >/dev/null 2>&1; then
    echo "warning: no jq, python3 or node found; verdicts are not validated and 'status' is unavailable"
  fi
  if [[ -n "$(git status --porcelain -- . ":(exclude)$STATE_DIR")" ]]; then
    echo "warning: uncommitted changes exist; they will be included in the review"
    git status --short -- . ":(exclude)$STATE_DIR"
  fi
}

# Stop a process and its children (codex and agy may run their own subprocesses).
kill_tree() {
  local pid="$1"
  if [[ -r "/proc/$pid/winpid" ]] && command -v taskkill >/dev/null 2>&1; then
    taskkill //F //T //PID "$(cat "/proc/$pid/winpid")" >/dev/null 2>&1 || true   # Git Bash
  fi
  if command -v pkill >/dev/null 2>&1; then pkill -TERM -P "$pid" 2>/dev/null || true; fi
  kill -TERM "$pid" 2>/dev/null || true
}

# Check the verdict in file $1 against the schema and normalize it in place:
# unwrap an agy envelope, and turn "approve" with blocking issues into "changes_requested".
# Returns 0 valid, 1 invalid, 2 no JSON tool available.
validate_verdict() {
  local f="$1" tmp="$1.tmp" note=' [sparring: approve changed to changes_requested because blocking issues remain]'
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg note "$note" '
      (if type == "object" and has("structured_output") and (has("verdict") | not) then .structured_output else . end)
      | if type == "object" and (.verdict == "approve" or .verdict == "changes_requested")
           and (.issues | type) == "array" and (.withdrawn | type) == "array"
           and all(.issues[]; type == "object" and (.id | type) == "string" and (.severity == "blocking" or .severity == "nit"))
        then (if .verdict == "approve" and any(.issues[]; .severity == "blocking")
              then .verdict = "changes_requested" | .summary = ((.summary // "") + $note) else . end)
        else error("invalid verdict") end' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  elif python3 -c '' >/dev/null 2>&1; then   # probe: Windows may have a python3 stub that only prints a hint
    python3 - "$f" "$tmp" "$note" <<'PY' || { rm -f "$tmp"; return 1; }
import json, sys
src, dst, note = sys.argv[1:4]
try:
    d = json.load(open(src, encoding="utf-8"))
except ValueError:
    sys.exit(1)
if isinstance(d, dict) and "structured_output" in d and "verdict" not in d:
    d = d["structured_output"]
ok = (isinstance(d, dict) and d.get("verdict") in ("approve", "changes_requested")
      and isinstance(d.get("issues"), list) and isinstance(d.get("withdrawn"), list)
      and all(isinstance(i, dict) and isinstance(i.get("id"), str) and i.get("severity") in ("blocking", "nit")
              for i in d["issues"]))
if not ok:
    sys.exit(1)
if d["verdict"] == "approve" and any(i["severity"] == "blocking" for i in d["issues"]):
    d["verdict"] = "changes_requested"
    d["summary"] = str(d.get("summary") or "") + note
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
PY
  elif node -e '' >/dev/null 2>&1; then
    node -e '
      const fs = require("fs"); const [src, dst, note] = process.argv.slice(1);
      let d; try { d = JSON.parse(fs.readFileSync(src, "utf8")); } catch { process.exit(1); }
      if (d && typeof d === "object" && "structured_output" in d && !("verdict" in d)) d = d.structured_output;
      const ok = d && typeof d === "object" && ["approve", "changes_requested"].includes(d.verdict)
        && Array.isArray(d.issues) && Array.isArray(d.withdrawn)
        && d.issues.every(i => i && typeof i.id === "string" && ["blocking", "nit"].includes(i.severity));
      if (!ok) process.exit(1);
      if (d.verdict === "approve" && d.issues.some(i => i.severity === "blocking")) {
        d.verdict = "changes_requested"; d.summary = String(d.summary || "") + note;
      }
      fs.writeFileSync(dst, JSON.stringify(d));' "$f" "$tmp" "$note" || { rm -f "$tmp"; return 1; }
  else
    return 2
  fi
  mv -f "$tmp" "$f"
}

# ---- status: the loop's bookkeeping, computed from the round files -------------------------

# Print the first JSON tool found (jq, python3 or node), or fail.
json_tool() {
  if command -v jq >/dev/null 2>&1; then echo jq
  elif python3 -c '' >/dev/null 2>&1; then echo python3
  elif node -e '' >/dev/null 2>&1; then echo node
  else return 1; fi
}

# Ids are reduced to [A-Za-z0-9._-], so they are safe as words in a space-separated set.
clean_id() { local id="${1//[^A-Za-z0-9._-]/_}"; echo "${id:-_}"; }

# Print a (validated) review file as lines "verdict V", "blocking ID", "nit ID", "withdrawn ID".
verdict_ids() {
  local f="$1" raw
  case "$(json_tool)" in
    jq) raw="$(jq -r '"verdict \(.verdict)", (.issues[] | "\(.severity) \(.id)"), (.withdrawn[] | "withdrawn \(.)")' "$f")" ;;
    python3) raw="$(python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("verdict", d["verdict"])
for i in d["issues"]: print(i["severity"], i["id"])
for w in d["withdrawn"]: print("withdrawn", w)
PY
)" ;;
    node) raw="$(node -e '
      const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      console.log("verdict " + d.verdict);
      for (const i of d.issues) console.log(i.severity + " " + i.id);
      for (const w of d.withdrawn) console.log("withdrawn " + w);' "$f")" ;;
    *) return 1 ;;
  esac || return 1
  local kind id
  while IFS=' ' read -r kind id; do
    id="${id%$'\r'}"; if [[ -n "$kind" ]]; then echo "$kind $(clean_id "$id")"; fi
  done <<< "$raw"
}

# Print a response file as lines "FIXED ID", "FIXED_TB ID" (fixed after tiebreak),
# "REBUTTED ID" or "SAME ID OLD_ID". Lines look like "R1: FIXED - ...", "R2: REBUTTED, ...",
# "R1: FIXED after tiebreak, ..." or "R7: SAME AS R2"; markdown bullets and bold are ignored.
parse_response() {
  local line id rest up re='^[[:space:]#>-]*([^:[:space:]]+)[[:space:]]*:[[:space:]]*(.*)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"; line="${line//\*/}"; line="${line//\`/}"
    [[ "$line" =~ $re ]] || continue
    id="$(clean_id "${BASH_REMATCH[1]}")"; rest="${BASH_REMATCH[2]}"
    up="$(printf '%s' "$rest" | tr '[:lower:]' '[:upper:]')"
    case "$up" in
      "FIXED AFTER TIEBREAK"*) echo "FIXED_TB $id" ;;
      FIXED*)                  echo "FIXED $id" ;;
      REBUTTED*)               echo "REBUTTED $id" ;;
      "SAME AS "*)             rest="${rest:8}"; rest="${rest%%[[:space:],.;]*}"
                               echo "SAME $id $(clean_id "$rest")" ;;
    esac
  done < "$1"
}

# Sets are space-separated words.
set_has()   { [[ " $2 " == *" $1 "* ]]; }
set_add()   { if set_has "$1" "$2"; then echo "$2"; else echo "${2:+$2 }$1"; fi; }
set_and()   { local x r=""; for x in $1; do if set_has "$x" "$2"; then r="${r:+$r }$x"; fi; done; echo "$r"; }
set_minus() { local x r=""; for x in $1; do if ! set_has "$x" "$2"; then r="${r:+$r }$x"; fi; done; echo "$r"; }
set_eq()    { [[ -z "$(set_minus "$1" "$2")" && -z "$(set_minus "$2" "$1")" ]]; }

# Follow "SAME AS" links to the issue's first id.
ALIASES=""
canon() {
  local id="$1" a next hops=0
  while ((hops < 50)); do
    next=""
    for a in $ALIASES; do if [[ "${a%%=*}" == "$id" ]]; then next="${a#*=}"; break; fi; done
    if [[ -z "$next" || "$next" == "$id" ]]; then break; fi
    id="$next"; hops=$((hops + 1))
  done
  echo "$id"
}

# Read the round files and say where the loop stands and what to do next. Nothing is changed.
# See SKILL.md, step 5, for the rules this implements.
cmd_status() {
  [[ -f "$STATE_DIR/base" ]] || die "run '$0 init' first" 2
  if ! json_tool >/dev/null; then
    if command -v powershell.exe >/dev/null 2>&1; then   # Git Bash without jq/python/node
      local ps="$SCRIPT_DIR/review.ps1"
      command -v cygpath >/dev/null 2>&1 && ps="$(cygpath -w "$ps")"
      exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps" status
    fi
    die "status needs jq, python3 or node" 5
  fi
  local L=3 TB=0 n f st id tgt kind
  if [[ -f "$STATE_DIR/config" ]]; then
    L="$(sed -n 's/^rounds=//p' "$STATE_DIR/config" | tr -d '\r')"; [[ "$L" =~ ^[1-9][0-9]*$ ]] || L=3
    [[ "$(sed -n 's/^tiebreaker=//p' "$STATE_DIR/config" | tr -d '\r')" == 1 ]] && TB=1
  fi
  local M=0
  while [[ -f "$STATE_DIR/round-$((M + 1)).review.json" ]]; do M=$((M + 1)); done

  # Pass 1: "SAME AS" links from every response, so ids are canonical everywhere.
  ALIASES=""
  for ((n = 1; n <= M; n++)); do
    f="$STATE_DIR/round-$n.response.md"; [[ -f "$f" ]] || continue
    while read -r st id tgt; do if [[ "$st" == SAME ]]; then ALIASES="$ALIASES $id=$tgt"; fi; done < <(parse_response "$f")
  done

  # Pass 2: per round, the open blocking issues and the developer's answers.
  local -a OPEN RESP REB FTB
  local out
  for ((n = 1; n <= M; n++)); do
    OPEN[n]=""; RESP[n]=0; REB[n]=""; FTB[n]=""
    out="$(verdict_ids "$STATE_DIR/round-$n.review.json")" || die "cannot read $STATE_DIR/round-$n.review.json" 4
    while read -r kind id; do
      if [[ "$kind" == blocking ]]; then OPEN[n]="$(set_add "$(canon "$id")" "${OPEN[n]}")"; fi
    done <<< "$out"
    f="$STATE_DIR/round-$n.response.md"; [[ -f "$f" ]] || continue
    RESP[n]=1
    while read -r st id tgt; do
      id="$(canon "$id")"
      case "$st" in
        REBUTTED) REB[n]="$(set_add "$id" "${REB[n]}")" ;;
        FIXED_TB) FTB[n]="$(set_add "$id" "${FTB[n]}")" ;;
      esac
    done < <(parse_response "$f")
  done

  # Deadlock round D: the round limit, or earlier when every open issue is disputed
  # (rebutted in the response before, and kept open anyway).
  local D=0
  for ((n = 1; n <= M; n++)); do
    if ((n == L)) || { ((n >= 2)) && [[ -n "${OPEN[n]}" && -z "$(set_minus "${OPEN[n]}" "${REB[n-1]}")" ]]; }; then
      D=$n; break
    fi
  done
  local E=$((D + 1)) F=$((D + 2)) U=$((D + 3))

  # Tiebreak on E: issues it keeps must be fixed; issues it drops are closed for good.
  local tb_file="$STATE_DIR/round-$E.tiebreak.review.json" tb_ran=0 kept="" closed=""
  if ((D > 0 && M >= E)) && [[ -f "$tb_file" ]]; then
    tb_ran=1
    out="$(verdict_ids "$tb_file")" || die "cannot read $tb_file" 4
    local tb_open=""
    while read -r kind id; do
      if [[ "$kind" == blocking ]]; then tb_open="$(set_add "$(canon "$id")" "$tb_open")"; fi
    done <<< "$out"
    kept="$(set_and "${OPEN[E]}" "$tb_open")"
    closed="$(set_minus "${OPEN[E]}" "$kept")"
    for ((n = E + 1; n <= M; n++)); do OPEN[n]="$(set_minus "${OPEN[n]}" "$closed")"; done
  fi

  local open="" disputed="" stage next="" resp_file="" tier=same result="" note="" fix_needed=""
  if ((M > 0)); then
    open="${OPEN[M]}"
    ((M >= 2)) && disputed="$(set_and "$open" "${REB[M-1]}")"
  fi
  if ((M == 0)); then
    stage=normal; next="review 1"
  elif [[ -z "$open" ]]; then
    stage=done; next=finish
    if ((D == 0 || M <= E)); then result=approved
    elif ((M == F)); then result="$( ((tb_ran)) && echo approved-after-tiebreak || echo approved)"
    else result=user-decided; fi
  elif ((D == 0 || M <= D)); then
    stage=normal
    if ((RESP[M] == 0)); then
      next="respond $M"
    elif ((M == D)); then
      stage=escalation; next="review $E"; resp_file="$STATE_DIR/round-$D.response.md"; tier=deep
      if ((D < L)); then note="every open issue is disputed: deadlock before the round limit"
      else note="round limit reached"; fi
    else
      next="review $((M + 1))"; resp_file="$STATE_DIR/round-$M.response.md"
      if ((M >= 2)) && set_eq "$open" "${OPEN[M-1]}"; then
        tier=up; note="no progress: the same blocking issues are open as in round $((M - 1))"
      fi
    fi
  elif ((M == E)); then
    stage=escalation; tier=deep
    if ((RESP[E] == 0)); then
      next="respond $E"; note="re-examine only the open issues, with fresh eyes on both sides' arguments"
    elif ((TB && ! tb_ran)) && [[ -n "$(set_and "$open" "${REB[E]}")" ]]; then
      stage=tiebreak; next="tiebreak $E"; resp_file="$STATE_DIR/round-$E.response.md"
    elif ((tb_ran)) && fix_needed="$(set_minus "$kept" "${FTB[E]}")" && [[ -n "$fix_needed" ]]; then
      stage=tiebreak; next="fix-after-tiebreak $E"
      note="fix each kept issue, then add 'ID: FIXED after tiebreak, ...' to $STATE_DIR/round-$E.response.md"
    else
      stage=final; next="review $F"; resp_file="$STATE_DIR/round-$E.response.md"
    fi
  elif ((M == F)); then
    tier=deep
    if ((RESP[F] == 0)); then
      stage=user; next=ask-user
      note="one question per open issue; record the decisions in $STATE_DIR/round-$F.response.md"
    else
      stage=user; next="review $U"; resp_file="$STATE_DIR/round-$F.response.md"
      note="only if the decisions changed code; otherwise finish"
    fi
  else
    stage=done; next=finish; result=user-decided
    note="report what review $M still raised"
  fi

  echo "stage: $stage"
  echo "next: $next"
  [[ -n "$resp_file" ]] && echo "response_file: $resp_file"
  [[ "$stage" != done ]] && echo "tier: $tier"
  [[ -n "$result" ]] && echo "result: $result"
  echo "round: $M"
  echo "limit: $L"
  echo "open: $open"
  echo "disputed: $disputed"
  ((tb_ran)) && { echo "tiebreak_kept: $kept"; echo "closed: $closed"; }
  [[ -n "$fix_needed" ]] && echo "fix: $fix_needed"
  [[ -n "$note" ]] && echo "note: $note"
  return 0
}

cmd_review() {
  local tiebreak=0 limit="${SPARRING_REVIEW_TIMEOUT:-540}"
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --tiebreak) tiebreak=1; shift ;;
      --timeout)  [[ $# -ge 2 ]] || die "--timeout needs a number of seconds"; limit="$2"; shift 2 ;;
      *)          die "unknown option: $1" ;;
    esac
  done
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive number of seconds"
  [[ $# -ge 4 ]] || die "usage: review [--tiebreak] [--timeout SECONDS] <round> <tool> <model|default> <effort> [response-file]"
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
  git -c core.quotePath=false diff "$base" -- . ":(exclude)$STATE_DIR" > "$diff_file"
  while IFS= read -r -d '' f; do
    git -c core.quotePath=false diff --no-index -- /dev/null "$f" >> "$diff_file" || true
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
      echo "Before you write issues, look at the ids in the previous review. An issue you raise again keeps its old id, even if you describe it differently."
    fi
  } > "$prompt_file"

  local before after pid rc=0 waited=0
  before="$(tree_state)"
  local snap
  if snap="$(snapshot_tree)"; then
    echo "$snap" > "$STATE_DIR/$tag.snapshot"
  else
    rm -f "$STATE_DIR/$tag.snapshot"
    echo "warning: could not snapshot the working tree; 'restore' will not be available for $tag" >&2
  fi
  rm -f "$out_file"
  # Run the adapter through bash (no executable bit needed) under a watchdog, so a slow
  # reviewer ends with exit 7 instead of being cut off by the caller's tool timeout.
  export SPARRING_REVIEW_TIMEOUT="$limit"
  bash "$SCRIPT_DIR/reviewers/$tool.sh" "$model" "$effort" "$SCHEMA" "$out_file" "$prompt_file" \
    >"$log_file" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= limit)); then
      kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
      echo "error: $tool review timed out after ${limit}s; last lines of $log_file:" >&2
      tail -n 20 "$log_file" >&2
      exit 7
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  if ((rc != 0)); then
    echo "error: $tool review failed (exit $rc); last lines of $log_file:" >&2
    tail -n 20 "$log_file" >&2
    exit 4
  fi
  after="$(tree_state)"
  if [[ "$before" != "$after" ]]; then
    echo "error: the $tool reviewer changed files in the working tree; review rejected." >&2
    local restore_args="$round"
    ((tiebreak)) && restore_args="--tiebreak $round"
    if [[ -s "$STATE_DIR/$tag.snapshot" ]]; then
      echo "Inspect with: git status. Undo the reviewer's changes with: $0 restore $restore_args" >&2
    else
      echo "Inspect with: git status. (No snapshot was saved, so 'restore' is not available.)" >&2
    fi
    echo "(If they are build or test artifacts, add them to .gitignore.)" >&2
    exit 6
  fi
  [[ -s "$out_file" ]] || die "$tool produced no review output (see $log_file)" 4
  local v=0
  validate_verdict "$out_file" || v=$?
  case "$v" in
    0) ;;
    1) die "$tool output is not a valid verdict (see $out_file and $log_file)" 4 ;;
    *) echo "warning: no JSON tool (jq, python3 or node) found; verdict not validated" >&2
       grep -q '"verdict"' "$out_file" || die "$tool output is not a verdict (see $out_file and $log_file)" 4 ;;
  esac
  cat "$out_file"
  echo
}

case "${1:-}" in
  init)    shift; cmd_init "$@" ;;
  status)  shift; cmd_status "$@" ;;
  review)  shift; cmd_review "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) die "usage: $0 init [tools] [--rounds N] [--tiebreaker] | status | review [--tiebreak] [--timeout SECONDS] <round> <tool> <model|default> <effort> [response-file] | restore [--tiebreak] <round>" ;;
esac
