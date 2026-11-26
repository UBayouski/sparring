#!/usr/bin/env bash
# Reviewer adapter: Google Antigravity CLI (agy). Beta.
# Contract: <adapter> <model|default> <effort> <schema-file> <out-file> <prompt-file>
#
# agy has no read-only sandbox like Codex, so this runs in plan mode (read-only) with the terminal
# sandbox on, and the driver rejects the review if any file changed. With
# SPARRING_ALLOW_COMMANDS=1 (reviewer agy+run) the driver has started it inside a disposable
# copy of the project, so it runs in agy's default mode and may run tests there.
set -euo pipefail

# --meta <log-file>: print what this adapter logged about the run (see codex.sh). agy's
# envelope reports tokens but not the model; the model is read from agy's own log of the
# conversation (brain/<conversation_id>/), when that file exists.
if [[ "${1:-}" == --meta ]]; then
  sed -n 's/^sparring-meta: //p' "$2" | tr -d '\r'
  exit 0
fi

model="$1" effort="$2" schema="$3" out="$4" prompt_file="$5"

# The Windows agy installer only updates PATH for new terminals; find a fresh install anyway.
if ! command -v agy >/dev/null 2>&1 && [[ -n "${LOCALAPPDATA:-}" ]]; then
  agy_bin="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")/agy/bin"
  [[ -x "$agy_bin/agy.exe" ]] && export PATH="$agy_bin:$PATH"
fi
command -v agy >/dev/null 2>&1 || { echo "agy CLI not found; run /sparring:check" >&2; exit 127; }

# agy efforts: low, medium, high, xhigh, max (model dependent). Map "minimal" to low.
[[ "$effort" == minimal ]] && effort=low

# Plan mode keeps agy read-only, but in agy 1.5 it also denies every shell command (allow
# rules are ignored there), and a denied command ends the turn with no verdict. So agy is
# told up front to work from the files only. If it asks for a command anyway, it gets one
# retry with a stricter note. Outside plan mode agy can write files, so that is not an option.
NO_COMMANDS='Important for this reviewer: shell commands are not available here, so ignore the earlier permission to run tests or linters. Asking for any command ends the review with no result. Use only your file reading tools, and say in summary what you could not verify without running code.'
RETRY_NOTE='Your previous attempt asked for a shell command and was stopped. Do not request any command or tool that runs code. Read the files and return the verdict.'

# Stop agy a little before the driver's watchdog does, so it can exit cleanly.
limit="${SPARRING_REVIEW_TIMEOUT:-540}"
((limit > 60)) && limit=$((limit - 15))
started=$SECONDS

allow_commands=0; [[ "${SPARRING_ALLOW_COMMANDS:-0}" == 1 ]] && allow_commands=1

run_agy() {  # <prompt> <timeout-seconds>
  local a=(-p "$1" --output-format json --json-schema "$schema"
           --sandbox --effort "$effort" --print-timeout "${SPARRING_AGY_TIMEOUT:-${2}s}")
  ((allow_commands)) || a+=(--mode plan)
  [[ "$model" != default ]] && a+=(--model "$model")
  agy "${a[@]}" </dev/null
}
tokens_of() { grep -o '"total_tokens": *[0-9]*' <<< "$1" | head -n 1 | grep -o '[0-9]*$' || true; }
# The model that answered, from agy's transcript of the conversation (an internal file: if it
# moves in a later agy version, nothing is printed and the driver records the requested model).
model_of() {
  local id f
  id="$(grep -o '"conversation_id": *"[A-Za-z0-9-]*"' <<< "$1" | head -n 1 | sed 's/.*"\([A-Za-z0-9-]*\)"$/\1/')" || true
  [[ -n "$id" ]] || return 0
  f="${SPARRING_AGY_HOME:-$HOME/.gemini/antigravity-cli}/brain/$id/.system_generated/logs/transcript_full.jsonl"
  [[ -f "$f" ]] || return 0
  grep -o '"model": *"[A-Za-z0-9._:/-]*"' "$f" | tail -n 1 | sed 's/.*"\([^"]*\)"$/\1/' || true
}

prompt="$(cat "$prompt_file")"
((allow_commands)) || prompt+=$'\n\n'"$NO_COMMANDS"
envelope="$(run_agy "$prompt" "$limit")"
[[ -n "$envelope" ]] || { echo "agy returned no output (older agy versions drop output when not run in a terminal; update agy)" >&2; exit 4; }
attempts=1 total="$(tokens_of "$envelope")"

left=$((limit - (SECONDS - started)))
if ((!allow_commands)) && ! grep -q '"structured_output"' <<< "$envelope" && grep -q '"denied_actions":.*"command"' <<< "$envelope" && ((left >= 60)); then
  echo "agy asked for a shell command, which plan mode denies; retrying once without commands" >&2
  envelope="$(run_agy "$prompt"$'\n\n'"$RETRY_NOTE" "$left")" || true
  attempts=2
  t="$(tokens_of "$envelope")"; [[ -n "$t" ]] && total=$(( ${total:-0} + t ))
fi
[[ -n "$total" ]] && echo "sparring-meta: tokens=$total" >&2
ran="$(model_of "$envelope")"; [[ -n "$ran" ]] && echo "sparring-meta: model=$ran" >&2
echo "sparring-meta: attempts=$attempts" >&2

# The verdict is in the envelope's structured_output field. Use whichever JSON tool exists.
extract() {
  if command -v jq >/dev/null 2>&1; then
    jq -e '.structured_output // empty'
  elif python3 -c '' >/dev/null 2>&1; then   # probe: Windows may have a python3 stub
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("structured_output"); sys.exit(1) if s is None else print(json.dumps(s))'
  elif command -v node >/dev/null 2>&1; then
    node -e 'let t="";process.stdin.on("data",c=>t+=c).on("end",()=>{const s=JSON.parse(t).structured_output;if(s==null)process.exit(1);console.log(JSON.stringify(s))})'
  else
    cat   # no JSON tool: keep the whole envelope; the orchestrator reads structured_output itself
  fi
}
if [[ -z "$envelope" ]] || ! printf '%s' "$envelope" | extract > "$out"; then
  echo "agy envelope has no structured_output:" >&2
  printf '%s\n' "$envelope" >&2
  exit 4
fi
