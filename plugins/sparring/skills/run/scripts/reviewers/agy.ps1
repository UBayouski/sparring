# Reviewer adapter: Google Antigravity CLI (agy), PowerShell. Beta. Same contract as agy.sh:
#   agy.ps1 <model|default> <effort> <schema-file> <out-file> <prompt-file>
# Runs in plan mode with the terminal sandbox on; the driver rejects the review if any file changed.
#   agy.ps1 --meta <log-file>   print what this adapter logged about the run (tokens=, and
#   model= read from agy's own log of the conversation, since its envelope does not report it)
param([string] $Model, [string] $Effort, [string] $Schema, [string] $Out, [string] $PromptFile)
$ErrorActionPreference = 'Continue'

if ($Model -eq '--meta') {
  Get-Content -LiteralPath $Effort -ErrorAction SilentlyContinue |
    Where-Object { $_ -like 'sparring-meta: *' } | ForEach-Object { $_.Substring(15) }
  exit 0
}
# Decode agy's output as UTF-8, not the console code page, so non-ASCII review text survives.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}

# The agy installer only updates PATH for new terminals; find a fresh install anyway.
$agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
if (-not (Get-Command agy -ErrorAction SilentlyContinue) -and (Test-Path (Join-Path $agyBin 'agy.exe'))) { $env:PATH = "$agyBin;$env:PATH" }
if (-not (Get-Command agy -ErrorAction SilentlyContinue)) { [Console]::Error.WriteLine('agy CLI not found; run /sparring:check'); exit 127 }
if ($Effort -eq 'minimal') { $Effort = 'low' }
# Plan mode keeps agy read-only, but in agy 1.5 it also denies every shell command (allow
# rules are ignored there), and a denied command ends the turn with no verdict. So agy is
# told up front to work from the files only. If it asks for a command anyway, it gets one
# retry with a stricter note. Outside plan mode agy can write files, so that is not an option.
$noCommands = 'Important for this reviewer: shell commands are not available here, so ignore the earlier permission to run tests or linters. Asking for any command ends the review with no result. Use only your file reading tools, and say in summary what you could not verify without running code.'
$retryNote = 'Your previous attempt asked for a shell command and was stopped. Do not request any command or tool that runs code. Read the files and return the verdict.'

# Stop agy a little before the driver's watchdog does, so it can exit cleanly.
$limit = if ($env:SPARRING_REVIEW_TIMEOUT) { [int] $env:SPARRING_REVIEW_TIMEOUT } else { 540 }
if ($limit -gt 60) { $limit -= 15 }
$started = Get-Date
# SPARRING_ALLOW_COMMANDS=1 (reviewer agy+run): the driver started this inside a disposable
# copy of the project, so agy runs in its default mode and may run tests there.
$allowCommands = $env:SPARRING_ALLOW_COMMANDS -eq '1'

function Invoke-Agy([string] $Text, [int] $Seconds) {
  $timeout = if ($env:SPARRING_AGY_TIMEOUT) { $env:SPARRING_AGY_TIMEOUT } else { "${Seconds}s" }
  $agyArgs = @('-p', $Text, '--output-format', 'json', '--json-schema', $Schema,
               '--sandbox', '--effort', $Effort, '--print-timeout', $timeout)
  if (-not $allowCommands) { $agyArgs += @('--mode', 'plan') }
  if ($Model -ne 'default') { $agyArgs += @('--model', $Model) }
  $script:agyExit = 0
  $o = ($null | & agy @agyArgs) -join "`n"
  $script:agyExit = $LASTEXITCODE
  $o
}
function Read-Envelope([string] $Text) { try { $Text | ConvertFrom-Json } catch { $null } }

$prompt = [System.IO.File]::ReadAllText((Resolve-Path $PromptFile))
if (-not $allowCommands) { $prompt += "`n`n" + $noCommands }
$envelope = Invoke-Agy $prompt $limit
if ($agyExit -ne 0) { exit $agyExit }
if (-not $envelope) { [Console]::Error.WriteLine('agy returned no output (older agy versions drop output when not run in a terminal; update agy)'); exit 4 }
$data = Read-Envelope $envelope
if ($null -eq $data) { [Console]::Error.WriteLine("agy output is not JSON: $envelope"); exit 4 }
$attempts = 1
$total = if ($data.usage -and $data.usage.total_tokens) { [long] $data.usage.total_tokens } else { $null }

$left = $limit - [int] ((Get-Date) - $started).TotalSeconds
$denied = @($data.denied_actions | Where-Object { $_.action -eq 'command' }).Count -gt 0
if (-not $allowCommands -and $null -eq $data.structured_output -and $denied -and $left -ge 60) {
  [Console]::Error.WriteLine('agy asked for a shell command, which plan mode denies; retrying once without commands')
  $envelope = Invoke-Agy ($prompt + "`n`n" + $retryNote) $left
  $attempts = 2
  $data = Read-Envelope $envelope
  if ($data -and $data.usage -and $data.usage.total_tokens) { $total = [long] $total + [long] $data.usage.total_tokens }
}
if ($null -ne $total) { [Console]::Error.WriteLine("sparring-meta: tokens=$total") }
# The model that answered, from agy's transcript of the conversation (an internal file: if it
# moves in a later agy version, nothing is printed and the driver records the requested model).
if ($data -and $data.conversation_id -match '^[A-Za-z0-9-]+$') {
  $agyHome = if ($env:SPARRING_AGY_HOME) { $env:SPARRING_AGY_HOME } else { Join-Path $HOME '.gemini\antigravity-cli' }
  $tr = Join-Path $agyHome "brain\$($data.conversation_id)\.system_generated\logs\transcript_full.jsonl"
  if (Test-Path -LiteralPath $tr) {
    $hits = @([regex]::Matches([System.IO.File]::ReadAllText($tr), '"model": *"([A-Za-z0-9._:/-]+)"'))
    if ($hits.Count -gt 0) { [Console]::Error.WriteLine("sparring-meta: model=$($hits[-1].Groups[1].Value)") }
  }
}
[Console]::Error.WriteLine("sparring-meta: attempts=$attempts")

if ($null -eq $data -or $null -eq $data.structured_output) { [Console]::Error.WriteLine("agy envelope has no structured_output: $envelope"); exit 4 }
$json = $data.structured_output | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($Out, $json, (New-Object System.Text.UTF8Encoding $false))
