# Reviewer adapter: Google Antigravity CLI (agy), PowerShell. Beta. Same contract as agy.sh:
#   agy.ps1 <model|default> <effort> <schema-file> <out-file> <prompt-file>
# Runs in plan mode with the terminal sandbox on; the driver rejects the review if any file changed.
param([string] $Model, [string] $Effort, [string] $Schema, [string] $Out, [string] $PromptFile)
$ErrorActionPreference = 'Continue'

if (-not (Get-Command agy -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('agy CLI not found; run /sparring:check'); exit 127 }
if ($Effort -eq 'minimal') { $Effort = 'low' }
$timeout = if ($env:SPARRING_AGY_TIMEOUT) { $env:SPARRING_AGY_TIMEOUT } else { '15m' }

$prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile))
$agyArgs = @('-p', $prompt, '--output-format', 'json', '--json-schema', $Schema,
             '--mode', 'plan', '--sandbox', '--effort', $Effort, '--print-timeout', $timeout)
if ($Model -ne 'default') { $agyArgs += @('--model', $Model) }

$envelope = (& agy @agyArgs) -join "`n"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not $envelope) { [Console]::Error.WriteLine('agy returned no output (older agy versions drop output when not run in a terminal; update agy)'); exit 4 }

try { $data = $envelope | ConvertFrom-Json } catch { [Console]::Error.WriteLine("agy output is not JSON: $envelope"); exit 4 }
if ($null -eq $data.structured_output) { [Console]::Error.WriteLine("agy envelope has no structured_output: $envelope"); exit 4 }
$json = $data.structured_output | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false))
