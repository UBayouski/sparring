# Reviewer adapter: OpenAI Codex CLI (PowerShell). Same contract as codex.sh:
#   codex.ps1 <model|default> <effort> <schema-file> <out-file> <prompt-file>
param([string] $Model, [string] $Effort, [string] $Schema, [string] $Out, [string] $PromptFile)
$ErrorActionPreference = 'Continue'

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('codex CLI not found; run /sparring:check'); exit 127 }
if ($Effort -eq 'max') { $Effort = 'xhigh' }

# The prompt holds no double quotes, so Windows PowerShell 5.1 passes it to codex unchanged.
$prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile))
$codexArgs = @('exec', '--sandbox', 'read-only', '--output-schema', $Schema, '-o', $Out, '-c', "model_reasoning_effort=$Effort")
if ($Model -ne 'default') { $codexArgs += @('-m', $Model) }
$codexArgs += $prompt

& codex @codexArgs | Out-Null
exit $LASTEXITCODE
