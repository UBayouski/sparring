#!/usr/bin/env bash
# Reviewer adapter: OpenAI Codex CLI.
# Contract (same for every adapter):
#   <adapter> <model|default> <effort> <schema-file> <out-file> <prompt-file>
#   Write a JSON verdict matching <schema-file> to <out-file>. Logs go to stderr. Exit 0 on success.
set -euo pipefail
model="$1" effort="$2" schema="$3" out="$4" prompt_file="$5"

command -v codex >/dev/null 2>&1 || { echo "codex CLI not found; run /sparring:check" >&2; exit 127; }

# Codex efforts: minimal, low, medium, high, xhigh. Map "max" to the highest.
[[ "$effort" == max ]] && effort=xhigh

args=(exec --sandbox read-only --output-schema "$schema" -o "$out" -c "model_reasoning_effort=$effort")
[[ "$model" != default ]] && args+=(-m "$model")
# exec, so the driver's timeout stops codex itself; stdin closed so codex never waits on it.
exec codex "${args[@]}" "$(cat "$prompt_file")" >/dev/null </dev/null
