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
#       tool:   codex | agy             (adapters live in reviewers/<tool>.sh); add +run (agy+run)
#               to review in a disposable copy of the project where the reviewer may run tests
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
#   review.sh challenge init [tools]
#   review.sh challenge ask [--timeout SECONDS] [--only N,M] <1|2> <tool/model:effort>...
#       For the challenge skill: no code is changed. init checks the tools and starts a clean
#       .sparring/challenge/ (the last one moves to .sparring/challenge-previous/). ask runs
#       every reviewer at once on challenge/brief.md (round 1), or on the orchestrator's
#       challenge/reply.md (round 2), and prints each answer. --only reruns some of them.
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

# Run the check for the reviewer tools in $1 (comma list; empty: any reviewer). Its output is
# kept in CHECK_OUT. Exits 5 if something is missing.
CHECK_OUT=""
check_prereqs() {
  local need="${1//+run/}"   # agy+run needs the same CLI as agy
  # Run through bash so a lost executable bit cannot skip the check.
  [[ -f "$CHECK" ]] || return 0
  # agy has no sign-in status command, so when it is one of this run's reviewers, the check
  # sends it one tiny test prompt (a few seconds) instead of failing on the first review.
  # With no tools named ($2 = any), it checks agy that way too, so READY_REVIEWERS leaves out
  # an agy that is not signed in.
  local deep=""; [[ ",$need," == *,agy,* || ( -z "$need" && "${2:-}" == any ) ]] && deep=--deep
  if ! CHECK_OUT="$(bash "$CHECK" $deep ${need:+--need "$need"} 2>&1)"; then
    echo "$CHECK_OUT"; die "prerequisites missing; run /sparring:check" 5
  fi
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
  check_prereqs "$need"
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "repository has no commits yet; make an initial commit first" 2
  mkdir -p "$STATE_DIR"
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  printf '*\n' > "$STATE_DIR/.gitignore"
  # A new run starts clean, so stale rounds can never be read as this run's. The last run's
  # files are kept in previous/ (replacing the run before it).
  if compgen -G "$STATE_DIR/round-*" >/dev/null || [[ -f "$STATE_DIR/reviews.tsv" ]]; then
    rm -rf "$STATE_DIR/previous"
    mkdir -p "$STATE_DIR/previous"
    if compgen -G "$STATE_DIR/round-*" >/dev/null; then mv "$STATE_DIR"/round-* "$STATE_DIR/previous/"; fi
    for f in task.md base config reviews.tsv; do if [[ -f "$STATE_DIR/$f" ]]; then mv "$STATE_DIR/$f" "$STATE_DIR/previous/"; fi; done
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

# A disposable copy of the project for reviewers that may run commands (tool+run): a shared
# clone at HEAD (its own refs and config, so nothing done there reaches this repo), with the
# developer's changed, new and deleted files applied byte for byte, plus the state files the
# prompt names. Ignored files (node_modules, virtualenvs, .env) are not copied.
make_copy() {
  local dir c f
  dir="$(mktemp -d "${TMPDIR:-/tmp}/sparring-copy.XXXXXX")" || return 1
  c="$dir/project"
  if ! git clone --quiet --shared --no-checkout "$PWD" "$c" >/dev/null 2>&1 ||
     ! git -C "$c" -c advice.detachedHead=false checkout --quiet --detach "$(git rev-parse HEAD)" >/dev/null 2>&1; then
    rm -rf "$dir"; return 1
  fi
  git ls-files -z -d -- . ":(exclude)$STATE_DIR" | while IFS= read -r -d '' f; do rm -f -- "$c/$f"; done
  if ! git ls-files -z -m -o --exclude-standard -- . ":(exclude)$STATE_DIR" | while IFS= read -r -d '' f; do
      [[ -f "$f" ]] || continue
      mkdir -p -- "$c/$(dirname -- "$f")" && cp -p -- "$f" "$c/$f" || exit 1
    done; then
    rm -rf "$dir"; return 1
  fi
  mkdir -p "$c/$STATE_DIR" && find "$STATE_DIR" -maxdepth 1 -type f -exec cp -p {} "$c/$STATE_DIR/" \;
  if [[ -d "$STATE_DIR/challenge" ]]; then
    mkdir -p "$c/$STATE_DIR/challenge" &&
      find "$STATE_DIR/challenge" -maxdepth 1 -type f -exec cp -p {} "$c/$STATE_DIR/challenge/" \;
  fi
  echo "$dir"
}

# One line per reviewer call (retries and failures too) in reviews.tsv, so the final report
# can say which model really ran, for how long and at what cost. Reads cmd_review's locals.
# The adapter's --meta mode reads its own log for what the CLI reported (model=, tokens=).
record_review() {
  local result="$1" secs=$(( ${finished:-$SECONDS} - started )) meta ran="$model" tokens="" attempts=1 m t a
  local tsv="${TSV:-$STATE_DIR/reviews.tsv}"
  meta="$(bash "$SCRIPT_DIR/reviewers/$tool.sh" --meta "$log_file" 2>/dev/null | tr -d '\r')" || meta=""
  m="$(sed -n 's/^model=//p' <<< "$meta" | head -n 1)"
  t="$(sed -n 's/^tokens=//p' <<< "$meta" | tail -n 1)"
  a="$(sed -n 's/^attempts=//p' <<< "$meta" | tail -n 1)"
  [[ "$m" =~ ^[A-Za-z0-9._:/-]+$ ]] && ran="$m"
  [[ "$t" =~ ^[0-9]+$ ]] && tokens="$t"
  [[ "$a" =~ ^[1-9]$ ]] && attempts="$a"
  [[ -f "$tsv" ]] || printf 'round\tkind\ttool\tmodel\teffort\tseconds\ttokens\tattempts\tresult\n' > "$tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$round" "$kind" "$label" "$ran" "$effort" "$secs" "${tokens:--}" "$attempts" "$result" \
    >> "$tsv"
  local tries=""; ((attempts > 1)) && tries=", $attempts attempts"
  echo "reviewer: $label, model $ran, effort $effort, ${secs}s, tokens ${tokens:-not reported}$tries, $result" >&2
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
  [[ $# -ge 4 ]] || die "usage: review [--tiebreak] [--timeout SECONDS] <round> <tool>[+run] <model|default> <effort> [response-file]"
  local round="$1" tool="$2" model="$3" effort="$4" response_file="${5:-}" run_mode=0
  # tool+run: review in a disposable copy where the reviewer may run tests and other commands.
  [[ "$tool" == *+run ]] && { run_mode=1; tool="${tool%+run}"; }
  local label="$tool"; ((run_mode)) && label="$tool+run"
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
    if ((run_mode)); then
      echo
      echo "You are working in a disposable copy of the project with the developer's changes applied. You may run tests, builds and linters there; whatever they change in the copy is thrown away. Files ignored by git, such as installed dependencies, are not in the copy; if a test cannot run for that reason, say so in summary."
    fi
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
  local kind=review started=$SECONDS
  ((tiebreak)) && kind=tiebreak
  # Run the adapter through bash (no executable bit needed) under a watchdog, so a slow
  # reviewer ends with exit 7 instead of being cut off by the caller's tool timeout.
  export SPARRING_REVIEW_TIMEOUT="$limit"
  local run_dir="$PWD"
  if ((run_mode)); then
    COPY_DIR="$(make_copy)" || die "could not make a disposable copy of the project for $label" 4
    trap 'rm -rf "$COPY_DIR"' EXIT   # global: the trap runs after this function returns
    run_dir="$COPY_DIR/project"
  fi
  (cd "$run_dir" && SPARRING_ALLOW_COMMANDS="$run_mode" exec bash "$SCRIPT_DIR/reviewers/$tool.sh" \
     "$model" "$effort" "$SCHEMA" "$OLDPWD/$out_file" "$OLDPWD/$prompt_file") \
    >"$log_file" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if ((waited >= limit)); then
      kill_tree "$pid"
      wait "$pid" 2>/dev/null || true
      echo "error: $tool review timed out after ${limit}s; last lines of $log_file:" >&2
      tail -n 20 "$log_file" >&2
      record_review timeout
      exit 7
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || rc=$?
  if ((rc != 0)); then
    echo "error: $tool review failed (exit $rc); last lines of $log_file:" >&2
    tail -n 20 "$log_file" >&2
    record_review failed
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
    record_review rejected
    exit 6
  fi
  [[ -s "$out_file" ]] || { record_review invalid; die "$tool produced no review output (see $log_file)" 4; }
  local v=0
  validate_verdict "$out_file" || v=$?
  case "$v" in
    0) ;;
    1) record_review invalid; die "$tool output is not a valid verdict (see $out_file and $log_file)" 4 ;;
    *) echo "warning: no JSON tool (jq, python3 or node) found; verdict not validated" >&2
       grep -q '"verdict"' "$out_file" || { record_review invalid; die "$tool output is not a verdict (see $out_file and $log_file)" 4; } ;;
  esac
  record_review ok
  cat "$out_file"
  echo
}

# ---- challenge: independent reviewers answer one question; no code is changed ---------------

CH_DIR="$STATE_DIR/challenge"

# Split a reviewer entry tool[+run]/model:effort into E_TOOL, E_MODEL and E_EFFORT. A bare tool
# name (agy, agy+run:high) means its default model; without a tool, codex. Effort defaults to high.
parse_entry() {
  local e="$1" rest head
  E_TOOL=codex E_MODEL=default E_EFFORT=high
  if [[ "$e" == */* ]]; then
    E_TOOL="${e%%/*}"; rest="${e#*/}"
  else
    head="${e%%:*}"
    if [[ "${head%+run}" =~ ^[a-z0-9-]+$ && -f "$SCRIPT_DIR/reviewers/${head%+run}.sh" ]]; then
      E_TOOL="$head"; rest="default${e:${#head}}"
    else
      rest="$e"
    fi
  fi
  if [[ "$rest" =~ ^(.*):(minimal|low|medium|high|xhigh|max)$ ]]; then
    rest="${BASH_REMATCH[1]}"; E_EFFORT="${BASH_REMATCH[2]}"
  fi
  [[ -n "$rest" ]] && E_MODEL="$rest"
  [[ "${E_TOOL%+run}" =~ ^[a-z0-9-]+$ && -f "$SCRIPT_DIR/reviewers/${E_TOOL%+run}.sh" ]] ||
    die "unknown reviewer tool in $e: ${E_TOOL%+run}"
  [[ "$E_MODEL" =~ ^[A-Za-z0-9._:/-]+$ ]] || die "invalid model name in $e: $E_MODEL"
  return 0
}

# Check a round 1 answer or a round 2 reply in file $1 (round $2) and unwrap an agy envelope in
# place. Returns 0 valid, 1 invalid, 2 no JSON tool available.
validate_answer() {
  local f="$1" r="$2" tmp="$1.tmp"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg r "$r" '
      (if type == "object" and has("structured_output") and (has("answer") or has("verdict") | not) then .structured_output else . end)
      | if type != "object" then error("invalid")
        elif $r == "1" then
          (if (.answer | type) == "string" and (.findings | type) == "array" and (.unchecked | type) == "array"
              and all(.findings[]; type == "object" and (.id | type) == "string") then . else error("invalid") end)
        else
          (if (.verdict == "agree" or .verdict == "disagree" or .verdict == "partly") and (.points | type) == "array"
              and all(.points[]; type == "object" and (.id | type) == "string" and (.status == "stands" or .status == "withdrawn"))
           then . else error("invalid") end)
        end' "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  elif python3 -c '' >/dev/null 2>&1; then
    python3 - "$f" "$tmp" "$r" <<'PY' || { rm -f "$tmp"; return 1; }
import json, sys
src, dst, r = sys.argv[1:4]
try:
    d = json.load(open(src, encoding="utf-8"))
except ValueError:
    sys.exit(1)
if isinstance(d, dict) and "structured_output" in d and "answer" not in d and "verdict" not in d:
    d = d["structured_output"]
if not isinstance(d, dict):
    sys.exit(1)
if r == "1":
    ok = (isinstance(d.get("answer"), str) and isinstance(d.get("findings"), list)
          and isinstance(d.get("unchecked"), list)
          and all(isinstance(i, dict) and isinstance(i.get("id"), str) for i in d["findings"]))
else:
    ok = (d.get("verdict") in ("agree", "disagree", "partly") and isinstance(d.get("points"), list)
          and all(isinstance(i, dict) and isinstance(i.get("id"), str) and i.get("status") in ("stands", "withdrawn")
                  for i in d["points"]))
if not ok:
    sys.exit(1)
json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False)
PY
  elif node -e '' >/dev/null 2>&1; then
    node -e '
      const fs = require("fs"); const [src, dst, r] = process.argv.slice(1);
      let d; try { d = JSON.parse(fs.readFileSync(src, "utf8")); } catch { process.exit(1); }
      if (d && typeof d === "object" && "structured_output" in d && !("answer" in d) && !("verdict" in d)) d = d.structured_output;
      if (!d || typeof d !== "object") process.exit(1);
      const ok = r === "1"
        ? typeof d.answer === "string" && Array.isArray(d.findings) && Array.isArray(d.unchecked)
          && d.findings.every(i => i && typeof i.id === "string")
        : ["agree", "disagree", "partly"].includes(d.verdict) && Array.isArray(d.points)
          && d.points.every(i => i && typeof i.id === "string" && ["stands", "withdrawn"].includes(i.status));
      if (!ok) process.exit(1);
      fs.writeFileSync(dst, JSON.stringify(d));' "$f" "$tmp" "$r" || { rm -f "$tmp"; return 1; }
  else
    return 2
  fi
  mv -f "$tmp" "$f"
}

# Write the prompt for one reviewer: <round> <reviewer number> <run mode 0|1> <prompt file>.
# Like the review prompt, it holds no user text and no double quotes.
challenge_prompt() {
  local r="$1" s="$2" run="$3"
  {
    echo "You are an independent REVIEWER, asked to check a question with fresh eyes. Do not edit any files."
    echo
    echo "The question and the evidence are in the file $CH_DIR/brief.md. Read it, then read the code and files it names, and anything else in the project you need. You may run read-only commands such as tests or linters."
    if ((run)); then
      echo
      echo "You are working in a disposable copy of the project, with its uncommitted changes applied. You may run tests, builds and linters there; whatever they change in the copy is thrown away. Files ignored by git, such as installed dependencies, are not in the copy; if a check cannot run for that reason, say so."
    fi
    if ((r == 1)); then
      cat <<'EOF'

Rules:
- Reach your own answer from the evidence. Do not take the brief's framing on trust: if the question rests on a wrong premise, say so in answer.
- If the brief states a claim to test, try hard to refute it before you accept it.
- Every finding needs evidence: a file and line, a command and its output, or a quoted passage. Say when something is inferred rather than checked.
- Give every finding an id like C1, C2.
- Put what you could not verify, and why, in unchecked.
- confidence high only when you checked the key facts yourself.
EOF
    else
      cat <<EOF

This is round 2. Your earlier answer is in the file $CH_DIR/round-1.$s.answer.json.
The orchestrator's own conclusion, and its reply to your findings under the heading Reviewer $s, are in the file $CH_DIR/reply.md.

Rules:
- Judge the orchestrator's conclusion on the merits: verdict agree, disagree or partly.
- For each of your earlier findings: status stands if it still holds after the reply, withdrawn if the reply answers it. Say why in comment.
- Change your mind when the argument is good; do not drop a real problem to be agreeable.
- You may add an important new point, with a new id and status stands.
EOF
    fi
  } > "$4"
}

cmd_challenge() {
  case "${1:-}" in
    init) shift; challenge_init "$@" ;;
    ask)  shift; challenge_ask "$@" ;;
    *)    die "usage: $0 challenge init [tools] | challenge ask [--timeout SECONDS] [--only N,M] <1|2> <tool/model:effort>..." ;;
  esac
}

challenge_init() {
  local a need=""
  for a in "$@"; do
    [[ "$a" != --* ]] || die "usage: $0 challenge init [tools]"
    need="${need:+$need,}$a"   # codex,agy as one argument or as several
  done
  check_prereqs "$need" any
  git rev-parse --verify HEAD >/dev/null 2>&1 || die "repository has no commits yet; make an initial commit first" 2
  mkdir -p "$STATE_DIR"
  printf '*\n' > "$STATE_DIR/.gitignore"
  # A new challenge starts clean; the last one is kept in challenge-previous/.
  if [[ -d "$CH_DIR" ]]; then
    rm -rf "$STATE_DIR/challenge-previous"
    # On Windows a folder cannot be renamed while a leftover process (say, from a reviewer
    # that timed out) holds a file in it open; copy it instead, and clear what can be cleared.
    if ! mv "$CH_DIR" "$STATE_DIR/challenge-previous" 2>/dev/null; then
      cp -rp "$CH_DIR" "$STATE_DIR/challenge-previous" || die "could not keep the previous challenge"
      rm -rf "$CH_DIR" 2>/dev/null || true
      if [[ -n "$(ls -A "$CH_DIR" 2>/dev/null)" ]]; then
        echo "warning: some files in $CH_DIR are in use and were left there: $(ls -A "$CH_DIR" | tr '\n' ' ')"
      fi
    fi
    echo "previous challenge moved to $STATE_DIR/challenge-previous/"
  fi
  mkdir -p "$CH_DIR"
  printf 'round\tkind\ttool\tmodel\teffort\tseconds\ttokens\tattempts\tresult\n' > "$CH_DIR/reviews.tsv"
  echo "challenge: write the question and the evidence to $CH_DIR/brief.md, then run: challenge ask 1 <reviewers>"
  grep '^READY_REVIEWERS:' <<< "$CHECK_OUT" || true
  json_tool >/dev/null || echo "warning: no jq, python3 or node found; answers are not validated"
  return 0
}

# Run every reviewer at once on the brief (round 1) or on the orchestrator's reply (round 2).
# Prints each valid answer after a "== reviewer N: ..." line. Exit 0 when at least one answer
# is valid, 6 when the working tree changed (all answers rejected), 7 when every reviewer
# timed out, otherwise 4.
challenge_ask() {
  local limit="${SPARRING_REVIEW_TIMEOUT:-540}" only=""
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --timeout) [[ $# -ge 2 ]] || die "--timeout needs a number of seconds"; limit="$2"; shift 2 ;;
      --only)    [[ "${2:-}" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || die "--only needs reviewer numbers, e.g. 2 or 1,3"
                 only="$2"; shift 2 ;;
      *)         die "unknown option: $1" ;;
    esac
  done
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || die "timeout must be a positive number of seconds"
  [[ $# -ge 2 ]] || die "usage: challenge ask [--timeout SECONDS] [--only N,M] <1|2> <tool/model:effort>..."
  local round="$1"; shift
  [[ "$round" == 1 || "$round" == 2 ]] || die "challenge round must be 1 or 2"
  [[ -f "$CH_DIR/reviews.tsv" ]] || die "run '$0 challenge init' first" 2
  [[ -s "$CH_DIR/brief.md" ]] || die "$CH_DIR/brief.md is missing; write the question and the evidence there first" 2
  if ((round == 2)); then
    [[ -s "$CH_DIR/reply.md" ]] || die "$CH_DIR/reply.md is missing; write your conclusion and replies there first" 2
  fi
  local schema="$SCRIPT_DIR/../../challenge/challenge.schema.json"
  ((round == 2)) && schema="$SCRIPT_DIR/../../challenge/challenge-reply.schema.json"
  [[ -f "$schema" ]] || die "schema not found: $schema" 2

  # Reviewers are numbered from 1 in the order given, in both rounds.
  local -a S_TOOL S_LABEL S_MODEL S_EFFORT S_RUN S_PID S_END S_STATE S_RC
  local n=0 e slot
  for e in "$@"; do
    n=$((n + 1)); parse_entry "$e"
    S_RUN[n]=0; [[ "$E_TOOL" == *+run ]] && S_RUN[n]=1
    S_TOOL[n]="${E_TOOL%+run}"; S_LABEL[n]="$E_TOOL"; S_MODEL[n]="$E_MODEL"; S_EFFORT[n]="$E_EFFORT"
    S_STATE[n]=skip; S_RC[n]=0; S_END[n]=0
    if [[ -n "$only" && ",$only," != *",$n,"* ]]; then continue; fi
    if ((round == 2)) && [[ ! -s "$CH_DIR/round-1.$n.answer.json" ]]; then
      echo "note: reviewer $n (${S_LABEL[n]}) has no round 1 answer; skipped" >&2; continue
    fi
    S_STATE[n]=run
  done

  local before tag run_dir copy started=$SECONDS
  before="$(tree_state)"
  export SPARRING_REVIEW_TIMEOUT="$limit"
  COPY_DIRS=()
  trap 'rm -rf ${COPY_DIRS[@]+"${COPY_DIRS[@]}"}' EXIT
  for ((slot = 1; slot <= n; slot++)); do
    [[ "${S_STATE[slot]}" == run ]] || continue
    tag="$CH_DIR/round-$round.$slot"
    challenge_prompt "$round" "$slot" "${S_RUN[slot]}" "$tag.prompt.txt"
    rm -f "$tag.answer.json"
    run_dir="$PWD"
    if ((S_RUN[slot])); then
      if ! copy="$(make_copy)"; then
        echo "error: could not make a disposable copy of the project for reviewer $slot" >&2
        S_STATE[slot]=nocopy; continue
      fi
      COPY_DIRS+=("$copy"); run_dir="$copy/project"
    fi
    (cd "$run_dir" && SPARRING_ALLOW_COMMANDS="${S_RUN[slot]}" exec bash "$SCRIPT_DIR/reviewers/${S_TOOL[slot]}.sh" \
       "${S_MODEL[slot]}" "${S_EFFORT[slot]}" "$schema" "$OLDPWD/$tag.answer.json" "$OLDPWD/$tag.prompt.txt") \
      >"$tag.${S_TOOL[slot]}.log" 2>&1 </dev/null &
    S_PID[slot]=$!
  done

  # One watchdog for all of them.
  local waited=0 running rc
  while :; do
    running=0
    for ((slot = 1; slot <= n; slot++)); do
      [[ "${S_STATE[slot]}" == run ]] || continue
      if kill -0 "${S_PID[slot]}" 2>/dev/null; then
        running=1
      else
        rc=0; wait "${S_PID[slot]}" || rc=$?
        S_RC[slot]=$rc; S_END[slot]=$SECONDS; S_STATE[slot]=done
      fi
    done
    ((running)) || break
    if ((waited >= limit)); then
      for ((slot = 1; slot <= n; slot++)); do
        [[ "${S_STATE[slot]}" == run ]] || continue
        kill_tree "${S_PID[slot]}"; wait "${S_PID[slot]}" 2>/dev/null || true
        S_STATE[slot]=timeout; S_END[slot]=$SECONDS
      done
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  rm -rf ${COPY_DIRS[@]+"${COPY_DIRS[@]}"}; COPY_DIRS=()

  # A reviewer that changed the tree cannot be told apart from the others, so all are rejected.
  local changed=0
  [[ "$(tree_state)" != "$before" ]] && changed=1

  local TSV="$CH_DIR/reviews.tsv" tool label model effort kind finished log_file out result v
  local ok=0 timeouts=0 others=0 report=""
  for ((slot = 1; slot <= n; slot++)); do
    [[ "${S_STATE[slot]}" == skip ]] && continue
    tool="${S_TOOL[slot]}" label="${S_LABEL[slot]}" model="${S_MODEL[slot]}" effort="${S_EFFORT[slot]}"
    kind="challenge-$slot" finished="${S_END[slot]}"
    ((finished > 0)) || finished=$SECONDS
    log_file="$CH_DIR/round-$round.$slot.$tool.log" out="$CH_DIR/round-$round.$slot.answer.json"
    case "${S_STATE[slot]}" in
      timeout) result=timeout
               echo "error: reviewer $slot ($label) timed out after ${limit}s; last lines of $log_file:" >&2
               tail -n 20 "$log_file" >&2 ;;
      nocopy)  result=failed ;;
      *)
        if ((S_RC[slot] != 0)); then
          result=failed
          echo "error: reviewer $slot ($label) failed (exit ${S_RC[slot]}); last lines of $log_file:" >&2
          tail -n 20 "$log_file" >&2
        elif ((changed)); then
          result=rejected
        elif [[ ! -s "$out" ]]; then
          result=invalid; echo "error: reviewer $slot ($label) produced no answer (see $log_file)" >&2
        else
          v=0; validate_answer "$out" "$round" || v=$?
          case "$v" in
            0) result=ok ;;
            1) result=invalid; echo "error: reviewer $slot ($label) gave an invalid answer (see $out)" >&2 ;;
            *) if grep -q '"answer"\|"verdict"' "$out"; then
                 result=ok; echo "warning: no JSON tool (jq, python3 or node) found; answer not validated" >&2
               else
                 result=invalid; echo "error: reviewer $slot ($label) gave no answer (see $out)" >&2
               fi ;;
          esac
        fi ;;
    esac
    record_review "$result"
    case "$result" in
      ok)      ok=$((ok + 1)) ;;
      timeout) timeouts=$((timeouts + 1)) ;;
      *)       others=$((others + 1)) ;;
    esac
    report+="== reviewer $slot: $label/$model:$effort, $result =="$'\n'
    [[ "$result" == ok ]] && report+="$(cat "$out")"$'\n'
  done
  printf '%s' "$report"
  if ((changed)); then
    echo "error: the working tree changed while the reviewers ran; every answer is rejected. Inspect with: git status" >&2
    echo "(If they are build or test artifacts, add them to .gitignore.)" >&2
    exit 6
  fi
  ((ok > 0)) && return 0
  ((n > 0 && timeouts > 0 && others == 0)) && exit 7
  exit 4
}

case "${1:-}" in
  challenge) shift; cmd_challenge "$@" ;;
  init)    shift; cmd_init "$@" ;;
  status)  shift; cmd_status "$@" ;;
  review)  shift; cmd_review "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) die "usage: $0 init [tools] [--rounds N] [--tiebreaker] | status | review [--tiebreak] [--timeout SECONDS] <round> <tool>[+run] <model|default> <effort> [response-file] | restore [--tiebreak] <round> | challenge init [tools] | challenge ask [--timeout SECONDS] [--only N,M] <1|2> <tool/model:effort>..." ;;
esac
