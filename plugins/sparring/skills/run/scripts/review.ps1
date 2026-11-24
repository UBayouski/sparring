# Reviewer driver for the sparring run skill (Windows PowerShell 5.1+ and pwsh).
# Same commands, arguments and exit codes as review.sh:
#
#   review.ps1 init [tools]
#   review.ps1 review [--tiebreak] <round> <tool> <model|default> <effort> [response-file]
#
# SPARRING_DIR overrides the state directory (default: .sparring)

# Continue, not Stop: Windows PowerShell 5.1 turns native stderr into terminating errors
# under Stop. Every native call checks $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Utf8 = New-Object System.Text.UTF8Encoding $false

function Die([string] $Message, [int] $Code = 1) { [Console]::Error.WriteLine("error: $Message"); exit $Code }
function Have([string] $Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Schema = Join-Path (Split-Path -Parent $ScriptDir) 'review.schema.json'
$Check = Join-Path $ScriptDir '..\..\check\scripts\check-prereqs.ps1'
$PsHost = (Get-Process -Id $PID).Path

if (-not (Have git)) { Die 'git not found; run /sparring:check' 2 }
$top = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $top) { Die 'not inside a git repository' 2 }
Set-Location $top
$StateDir = if ($env:SPARRING_DIR) { $env:SPARRING_DIR } else { '.sparring' }
$Exclude = ":(exclude)$StateDir"

function Get-TreeState {
  $parts = @()
  $parts += & git status --porcelain=v1 -uall -- . $Exclude
  $parts += & git diff HEAD -- . $Exclude
  foreach ($f in (& git ls-files --others --exclude-standard -- . $Exclude)) {
    if ($f) { $parts += "$f $(& git hash-object -- $f)" }
  }
  $bytes = $Utf8.GetBytes(($parts -join "`n"))
  $sha = [System.Security.Cryptography.SHA256]::Create()
  [BitConverter]::ToString($sha.ComputeHash($bytes))
}

function Invoke-Init([string] $Need) {
  if (Test-Path $Check) {
    $checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Check)
    if ($Need) { $checkArgs += @('-Need', $Need) }
    $out = & $PsHost @checkArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $out | Write-Output; Die 'prerequisites missing; run /sparring:check' 5 }
  }
  & git rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) { Die 'repository has no commits yet; make an initial commit first' 2 }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  Set-Content -Path (Join-Path $StateDir '.gitignore') -Value '*' -Encoding ascii
  $base = (& git rev-parse HEAD)
  Set-Content -Path (Join-Path $StateDir 'base') -Value $base -Encoding ascii
  Write-Output "base: $base"
  if (& git status --porcelain -- . $Exclude) {
    Write-Output 'warning: uncommitted changes exist; they will be included in the review'
    & git status --short -- . $Exclude
  }
}

function Invoke-Review([string[]] $A) {
  $tiebreak = $false
  if ($A.Count -gt 0 -and $A[0] -eq '--tiebreak') { $tiebreak = $true; $A = @($A | Select-Object -Skip 1) }
  if ($A.Count -lt 4) { Die 'usage: review [--tiebreak] <round> <tool> <model|default> <effort> [response-file]' }
  $round, $tool, $model, $effort = $A[0], $A[1], $A[2], $A[3]
  $responseFile = if ($A.Count -ge 5) { $A[4] } else { '' }
  $adapter = Join-Path $ScriptDir "reviewers\$tool.ps1"
  if ($round -notmatch '^[0-9]+$') { Die 'round must be a number' }
  if ($tool -notmatch '^[a-z0-9-]+$' -or -not (Test-Path $adapter)) { Die "unknown reviewer tool: $tool" }
  if ($model -notmatch '^[A-Za-z0-9._:/-]+$') { Die "invalid model name: $model" }
  if ($effort -notmatch '^(minimal|low|medium|high|xhigh|max)$') { Die 'effort must be minimal, low, medium, high, xhigh or max' }
  if (-not (Test-Path "$StateDir/base")) { Die "run 'review.ps1 init' first" 2 }
  if (-not (Test-Path "$StateDir/task.md")) { Die "$StateDir/task.md is missing; write the task there first" 2 }
  if ($responseFile -and -not (Test-Path $responseFile)) { Die "response file not found: $responseFile" 2 }

  $base = (Get-Content "$StateDir/base" -Raw).Trim()
  $n = [int] $round
  $tag = if ($tiebreak) { "round-$n.tiebreak" } else { "round-$n" }
  $diffFile = "$StateDir/$tag.diff"
  $outFile = "$StateDir/$tag.review.json"
  $logFile = "$StateDir/$tag.$tool.log"
  $promptFile = "$StateDir/$tag.prompt.txt"
  $prevFile = if ($tiebreak) { "$StateDir/round-$n.review.json" } else { "$StateDir/round-$($n - 1).review.json" }

  # Tracked changes, then each new untracked file as an addition. The git index is not touched.
  $diff = @(& git diff $base -- . $Exclude)
  if ($LASTEXITCODE -ne 0) { Die 'git diff failed' }
  foreach ($f in (& git ls-files --others --exclude-standard -- . $Exclude)) {
    if ($f) { $diff += @(& git diff --no-index -- /dev/null $f) }
  }
  [System.IO.File]::WriteAllText((Join-Path $top $diffFile), (($diff -join "`n") + "`n"), $Utf8)
  if (-not ($diff -join '')) { Die "no changes against $base to review" 3 }

  $lines = @()
  if ($tiebreak) { $lines += 'You are an independent THIRD reviewer. A developer agent and a reviewer agent disagree. Do not edit any files.' }
  else { $lines += 'You are the code REVIEWER in an automated developer/reviewer loop. Do not edit any files.' }
  $lines += @(
    '',
    "The task the developer was given is in the file $StateDir/task.md.",
    "The developer's changes, as a diff against commit $base, are in the file $diffFile.",
    'Read both, and read any surrounding code you need. You may run read-only commands such as tests or linters.',
    '',
    'Review rules:',
    '- Judge the change against the task: correctness, bugs, security, error handling, missing tests for new behavior, breaking changes.',
    '- severity blocking means it must be fixed before merge. nit means optional style or preference. Never mark a preference as blocking.',
    '- Give every issue a stable id like R1, R2. Reuse the same id for the same issue in later rounds; new issues get new ids.',
    '- verdict approve only when no blocking issues remain. Nits alone do not block approval.',
    '- Be specific: point to the file and line, and say what to change.'
  )
  if ($tiebreak) {
    if (-not (Test-Path $prevFile)) { Die "tiebreak needs $prevFile" 2 }
    $lines += @('', "The reviewer's latest review is in $prevFile.")
    if ($responseFile) { $lines += "The developer's rebuttals, by issue id, are in $responseFile." }
    $lines += @(
      'Judge ONLY the blocking issues in that review. For each one, decide on the merits who is right.',
      'If the issue is real, keep it in issues with the same id and explain why in comment.',
      'If the developer is right, put its id in withdrawn. Do not raise new issues unless they are serious bugs.'
    )
  } elseif (Test-Path $prevFile) {
    $lines += @('', "This is round $n. The previous review is in $prevFile.")
    if ($responseFile) { $lines += "The developer's response (fixes and rebuttals, by issue id) is in $responseFile." }
    $lines += @(
      'For each earlier issue: if it is fixed, or the developer''s rebuttal convinces you, put its id in withdrawn.',
      'Otherwise keep it in issues with the same id, and say in comment why the rebuttal does not convince you.',
      'Change your mind when the argument is good; do not drop real bugs to be agreeable.'
    )
  }
  [System.IO.File]::WriteAllText((Join-Path $top $promptFile), (($lines -join "`n") + "`n"), $Utf8)

  $before = Get-TreeState
  Remove-Item -Force -ErrorAction SilentlyContinue $outFile
  & $PsHost -NoProfile -ExecutionPolicy Bypass -File $adapter $model $effort $Schema $outFile $promptFile 2> $logFile
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("error: $tool review failed; last lines of ${logFile}:")
    Get-Content $logFile -Tail 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 4
  }
  if ((Get-TreeState) -ne $before) { Die "the $tool reviewer changed files in the working tree; review rejected. Inspect with: git status (if they are build or test artifacts, add them to .gitignore)" 6 }
  if (-not (Test-Path $outFile) -or (Get-Item $outFile).Length -eq 0) { Die "$tool produced no review output (see $logFile)" 4 }
  $json = Get-Content $outFile -Raw
  if ($json -notmatch '"verdict"') { Die "$tool output is not a verdict (see $outFile and $logFile)" 4 }
  $json
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { '' }
$rest = @($args | Select-Object -Skip 1)
switch ($cmd) {
  'init'   { Invoke-Init $(if ($rest.Count) { $rest[0] } else { '' }) }
  'review' { Invoke-Review $rest }
  default  { Die 'usage: review.ps1 init [tools] | review [--tiebreak] <round> <tool> <model|default> <effort> [response-file]' }
}
