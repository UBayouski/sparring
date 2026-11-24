# Reviewer adapter: OpenAI Codex CLI (PowerShell). Same contract as codex.sh:
#   codex.ps1 <model|default> <effort> <schema-file> <out-file> <prompt-file>
#   codex.ps1 --meta <log-file>   print model=<name> and tokens=<count> from that log (either may be missing)
param([string] $Model, [string] $Effort, [string] $Schema, [string] $Out, [string] $PromptFile)
$ErrorActionPreference = 'Continue'

if ($Model -eq '--meta') {
  # codex exec prints a header with "model: <name>", and "tokens used" then the count.
  $log = @(Get-Content -LiteralPath $Effort -ErrorAction SilentlyContinue)
  $m = $log | Where-Object { $_ -match '^model:\s*(\S+)' } | Select-Object -First 1
  if ($m -match '^model:\s*(\S+)') { "model=$($Matches[1])" }
  for ($i = $log.Count - 2; $i -ge 0; $i--) {
    if ($log[$i] -match '^tokens used') { "tokens=$($log[$i + 1] -replace '[,\s]', '')"; break }
  }
  exit 0
}

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('codex CLI not found; run /sparring:check'); exit 127 }
if ($Effort -eq 'max') { $Effort = 'xhigh' }

# The prompt holds no double quotes, so Windows PowerShell 5.1 passes it to codex unchanged.
$prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile))
$codexArgs = @('exec', '--sandbox', 'read-only', '--output-schema', $Schema, '-o', $Out, '-c', "model_reasoning_effort=$Effort")
if ($Model -ne 'default') { $codexArgs += @('-m', $Model) }
$codexArgs += $prompt

# Empty stdin, so codex never waits on it.
$null | & codex @codexArgs | Out-Null
exit $LASTEXITCODE
