# Reviewer adapter: Google Antigravity CLI (agy), PowerShell. Beta. Same contract as agy.sh:
#   agy.ps1 <model|default> <effort> <schema-file> <out-file> <prompt-file>
# Runs in plan mode with the terminal sandbox on; the driver rejects the review if any file changed.
param([string] $Model, [string] $Effort, [string] $Schema, [string] $Out, [string] $PromptFile)
$ErrorActionPreference = 'Continue'
# Decode agy's output as UTF-8, not the console code page, so non-ASCII review text survives.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

# The agy installer only updates PATH for new terminals; find a fresh install anyway.
$agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $agyBin 'agy.exe'))) { $env:PATH = "$agyBin;$env:PATH" }
if (-not (Get-Command agy -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('agy CLI not found; run /sparring:check'); exit 127 }
if ($Effort -eq 'minimal') { $Effort = 'low' }
# Stop agy a little before the driver's watchdog does, so it can exit cleanly.
$limit = if ($env:SPARRING_REVIEW_TIMEOUT) { [int] $env:SPARRING_REVIEW_TIMEOUT } else { 540 }
if ($limit -gt 60) { $limit -= 15 }
$timeout = if ($env:SPARRING_AGY_TIMEOUT) { $env:SPARRING_AGY_TIMEOUT } else { "${limit}s" }

$prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile))
$agyArgs = @('-p', $prompt, '--output-format', 'json', '--json-schema', $Schema,
             '--mode', 'plan', '--sandbox', '--effort', $Effort, '--print-timeout', $timeout)
if ($Model -ne 'default') { $agyArgs += @('--model', $Model) }

$envelope = ($null | & agy @agyArgs) -join "`n"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not $envelope) { [Console]::Error.WriteLine('agy returned no output (older agy versions drop output when not run in a terminal; update agy)'); exit 4 }

try { $data = $envelope | ConvertFrom-Json } catch { [Console]::Error.WriteLine("agy output is not JSON: $envelope"); exit 4 }
if ($null -eq $data.structured_output) { [Console]::Error.WriteLine("agy envelope has no structured_output: $envelope"); exit 4 }
$json = $data.structured_output | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false))
