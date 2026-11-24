#!/usr/bin/env bash
# Reviewer adapter: Google Antigravity CLI (agy). Beta.
# Contract: <adapter> <model|default> <effort> <schema-file> <out-file> <prompt-file>
#
# agy has no read-only sandbox like Codex, so this runs in plan mode with the terminal
# sandbox on, and the driver rejects the review if any file changed.
set -euo pipefail
model="$1" effort="$2" schema="$3" out="$4" prompt_file="$5"

command -v agy >/dev/null 2>&1 || { echo "agy CLI not found; run /sparring:check" >&2; exit 127; }

# agy efforts: low, medium, high, xhigh, max (model dependent). Map "minimal" to low.
[[ "$effort" == minimal ]] && effort=low

args=(-p "$(cat "$prompt_file")" --output-format json --json-schema "$schema"
      --mode plan --sandbox --effort "$effort" --print-timeout "${SPARRING_AGY_TIMEOUT:-15m}")
[[ "$model" != default ]] && args+=(--model "$model")

envelope="$(agy "${args[@]}" </dev/null)"
[[ -n "$envelope" ]] || { echo "agy returned no output (older agy versions drop output when not run in a terminal; update agy)" >&2; exit 4; }

# The verdict is in the envelope's structured_output field. Use whichever JSON tool exists.
extract() {
  if command -v jq >/dev/null 2>&1; then
    jq -e '.structured_output // empty'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(sys.stdin); s=d.get("structured_output"); sys.exit(1) if s is None else print(json.dumps(s))'
  elif command -v node >/dev/null 2>&1; then
    node -e 'let t="";process.stdin.on("data",c=>t+=c).on("end",()=>{const s=JSON.parse(t).structured_output;if(s==null)process.exit(1);console.log(JSON.stringify(s))})'
  else
    cat   # no JSON tool: keep the whole envelope; the orchestrator reads structured_output itself
  fi
}
if ! printf '%s' "$envelope" | extract > "$out"; then
  echo "agy envelope has no structured_output:" >&2
  printf '%s\n' "$envelope" >&2
  exit 4
fi
