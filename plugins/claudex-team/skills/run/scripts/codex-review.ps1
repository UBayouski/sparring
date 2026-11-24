# Codex reviewer wrapper for the claudex-team run skill (Windows PowerShell 5.1+ and pwsh).
# Same commands and arguments as codex-review.sh:
#
#   codex-review.ps1 init
#   codex-review.ps1 review <round> <model|default> <effort> [response-file]
#
# CLAUDEX_DIR overrides the state directory (default: .review)
param(
  [Parameter(Position = 0)] [string] $Command,
  [Parameter(Position = 1)] [string] $Round,
  [Parameter(Position = 2)] [string] $Model,
  [Parameter(Position = 3)] [string] $Effort,
  [Parameter(Position = 4)] [string] $ResponseFile
)
# Continue, not Stop: Windows PowerShell 5.1 turns native stderr into terminating errors
# under Stop. Every native call checks `$LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Die([string] $Message, [int] $Code = 1) {
  [Console]::Error.WriteLine("error: $Message")
  exit $Code
}
function Have([string] $Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function GitOk { & git @args; if ($LASTEXITCODE -ne 0) { Die "git $($args -join ' ') failed" } }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Schema = Join-Path (Split-Path -Parent $ScriptDir) 'review.schema.json'
$Check = Join-Path $ScriptDir '..\..\check\scripts\check-prereqs.ps1'

if (-not (Have git)) { Die 'git not found; run /claudex-team:check' 2 }
$top = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $top) { Die 'not inside a git repository' 2 }
Set-Location $top
$StateDir = if ($env:CLAUDEX_DIR) { $env:CLAUDEX_DIR } else { '.review' }

function Invoke-Init {
  if (Test-Path $Check) {
    $psHost = (Get-Process -Id $PID).Path
    $out = & $psHost -NoProfile -ExecutionPolicy Bypass -File $Check 2>&1
    if ($LASTEXITCODE -ne 0) { $out | Write-Output; Die 'prerequisites missing; run /claudex-team:check' 5 }
  }
  & git rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) { Die 'repository has no commits yet; make an initial commit first' 2 }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  Set-Content -Path (Join-Path $StateDir '.gitignore') -Value '*' -Encoding ascii
  $base = (GitOk rev-parse HEAD)
  Set-Content -Path (Join-Path $StateDir 'base') -Value $base -Encoding ascii
  Write-Output "base: $base"
  $dirty = & git status --porcelain -- . ":(exclude)$StateDir"
  if ($dirty) {
    Write-Output 'warning: uncommitted changes exist; they will be included in the review'
    & git status --short -- . ":(exclude)$StateDir"
  }
}

function Invoke-Review {
  if ($Round -notmatch '^[0-9]+$') { Die 'usage: review <round> <model|default> <effort> [response-file]' }
  if (-not $Model) { Die 'model required (use "default" for the Codex default model)' }
  if ($Model -notmatch '^[A-Za-z0-9._:/-]+$') { Die "invalid model name: $Model" }
  if ($Effort -notmatch '^(minimal|low|medium|high|xhigh)$') { Die 'effort must be minimal, low, medium, high or xhigh' }
  if (-not (Have codex)) { Die 'codex CLI not found; run /claudex-team:check' 127 }
  $baseFile = Join-Path $StateDir 'base'
  $taskFile = Join-Path $StateDir 'task.md'
  if (-not (Test-Path $baseFile)) { Die "run 'codex-review.ps1 init' first" 2 }
  if (-not (Test-Path $taskFile)) { Die "$taskFile is missing; write the task there first" 2 }
  if ($ResponseFile -and -not (Test-Path $ResponseFile)) { Die "response file not found: $ResponseFile" 2 }

  $base = (Get-Content $baseFile -Raw).Trim()
  $n = [int] $Round
  $diffFile = "$StateDir/round-$n.diff"
  $outFile = "$StateDir/round-$n.review.json"
  $logFile = "$StateDir/round-$n.codex.log"
  $prevFile = "$StateDir/round-$($n - 1).review.json"

  # Tracked changes, then each new untracked file as an addition. The git index is not touched.
  $diff = @(& git diff $base -- . ":(exclude)$StateDir")
  if ($LASTEXITCODE -ne 0) { Die 'git diff failed' }
  $untracked = & git ls-files --others --exclude-standard -- . ":(exclude)$StateDir"
  foreach ($f in $untracked) { if ($f) { $diff += @(& git diff --no-index -- /dev/null $f) } }
  [System.IO.File]::WriteAllText((Join-Path $top $diffFile), (($diff -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
  if (-not ($diff -join '')) { Die "no changes against $base to review" 3 }

  # The prompt holds no user text and no double quotes, so Windows PowerShell 5.1
  # passes it to codex unchanged.
  $prompt = @"
You are the code REVIEWER in an automated developer/reviewer loop. Do not edit any files.

The task the developer was given is in the file $taskFile.
The developer's changes, as a diff against commit $base, are in the file $diffFile.
Read both, and read any surrounding code you need. You may run read-only commands such as tests or linters.

Review rules:
- Judge the change against the task: correctness, bugs, security, error handling, missing tests for new behavior, breaking changes.
- severity blocking means it must be fixed before merge. nit means optional style or preference. Never mark a preference as blocking.
- Give every issue a stable id like R1, R2. Reuse the same id for the same issue in later rounds; new issues get new ids.
- verdict approve only when no blocking issues remain. Nits alone do not block approval.
- Be specific: point to the file and line, and say what to change.
"@
  if (Test-Path $prevFile) {
    $prompt += "`n`nThis is round $n. Your previous review is in $prevFile."
    if ($ResponseFile) { $prompt += " The developer's response (fixes and rebuttals, by issue id) is in $ResponseFile." }
    $prompt += @"

For each earlier issue: if it is fixed, or the developer's rebuttal convinces you, put its id in withdrawn.
Otherwise keep it in issues with the same id, and say in comment why the rebuttal does not convince you.
Change your mind when the argument is good; do not drop real bugs to be agreeable.
"@
  }

  $codexArgs = @('exec', '--sandbox', 'read-only', '--output-schema', $Schema, '-o', $outFile, '-c', "model_reasoning_effort=$Effort")
  if ($Model -ne 'default') { $codexArgs += @('-m', $Model) }
  $codexArgs += $prompt

  & codex @codexArgs 2> $logFile | Out-Null
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("error: codex exec failed; last lines of ${logFile}:")
    Get-Content $logFile -Tail 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 4
  }
  if (-not (Test-Path $outFile) -or (Get-Item $outFile).Length -eq 0) { Die "codex produced no review output (see $logFile)" 4 }
  Get-Content $outFile -Raw
}

switch ($Command) {
  'init'   { Invoke-Init }
  'review' { Invoke-Review }
  default  { Die 'usage: codex-review.ps1 init | review <round> <model|default> <effort> [response-file]' }
}
