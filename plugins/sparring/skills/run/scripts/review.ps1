# Reviewer driver for the sparring run skill (Windows PowerShell 5.1+ and pwsh).
# Same commands, arguments and exit codes as review.sh:
#
#   review.ps1 init [tools] [--rounds N] [--tiebreaker]
#   review.ps1 status
#   review.ps1 review [--tiebreak] [--timeout SECONDS] <round> <tool>[+run] <model|default> <effort> [response-file]
#   review.ps1 restore [--tiebreak] <round>
#
# Exit codes: 2 setup, 3 nothing to review, 4 reviewer failed or gave an invalid verdict,
#             5 prerequisites missing, 6 reviewer changed files (undo with restore),
#             7 reviewer timed out.
# SPARRING_DIR overrides the state directory (default: .sparring)
# SPARRING_REVIEW_TIMEOUT sets the default timeout in seconds (default: 540)

# Continue, not Stop: Windows PowerShell 5.1 turns native stderr into terminating errors
# under Stop. Every native call checks $LASTEXITCODE instead.
$ErrorActionPreference = 'Continue'
$Utf8 = New-Object System.Text.UTF8Encoding $false
$OutputEncoding = $Utf8
# Decode git's output as UTF-8, not the console code page, so non-ASCII file names survive.
try { [Console]::OutputEncoding = $Utf8 } catch {}

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

# Run git with -z style output and return the NUL-separated items, never quoted or escaped.
function Get-ZList([string[]] $GitArgs) {
  $raw = (& git @GitArgs) -join "`n"
  @($raw -split "`0" | Where-Object { $_ })
}

# Untracked, not ignored files.
function Get-Untracked { Get-ZList @('ls-files', '--others', '--exclude-standard', '-z', '--', '.', $Exclude) }

# Copy a blob's exact bytes to a file. PowerShell pipes would re-encode them, so the bytes go
# straight from git's stdout stream to the file.
function Save-Blob([string] $Sha, [string] $Path) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command git -CommandType Application | Select-Object -First 1).Source
  $psi.Arguments = "cat-file blob $Sha"
  $psi.WorkingDirectory = $top
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  $fs = [System.IO.File]::Create($Path)
  try { $p.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Close() }
  $p.WaitForExit()
  $p.ExitCode -eq 0
}

# Save the working tree as a git tree object and return its id: HEAD, plus every changed or
# untracked (not ignored) file stored byte for byte (--no-filters, so no line-ending
# conversion), minus deleted files. A private index is used; the real index is never touched.
function Get-Snapshot {
  $paths = @(Get-ZList @('diff', '--name-only', '-z', 'HEAD', '--', '.', $Exclude)) + @(Get-Untracked)
  $headModes = @{}
  foreach ($line in (Get-ZList @('ls-tree', '-r', '-z', 'HEAD'))) {
    $meta, $name = $line -split "`t", 2
    $headModes[$name] = ($meta -split ' ')[0]
  }
  $idx = Join-Path $top "$StateDir/snapshot.index"
  Remove-Item -Force -ErrorAction SilentlyContinue $idx
  $saved = $env:GIT_INDEX_FILE
  try {
    $env:GIT_INDEX_FILE = $idx
    & git read-tree HEAD
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($f in $paths) {
      $item = Get-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
      if ($null -eq $item) {
        & git update-index --force-remove -- $f
        if ($LASTEXITCODE -ne 0) { return $null }
        continue
      }
      if ($item.PSIsContainer) { continue }   # a submodule or other non-file: not snapshotted
      $sha = (& git hash-object -w --no-filters -- $f)
      if ($LASTEXITCODE -ne 0) { return $null }
      $mode = if ($headModes.ContainsKey($f)) { $headModes[$f] } else { '100644' }
      if ($mode -eq '120000' -or $mode -eq '160000') { $mode = '100644' }
      & git update-index --add --cacheinfo $mode $sha $f
      if ($LASTEXITCODE -ne 0) { return $null }
    }
    $tree = (& git write-tree)
    if ($LASTEXITCODE -ne 0) { return $null }
    $tree
  } finally {
    if ($saved) { $env:GIT_INDEX_FILE = $saved } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    Remove-Item -Force -ErrorAction SilentlyContinue $idx
  }
}

function Get-RoundTag([string[]] $A) {
  $suffix = ''
  if ($A.Count -gt 0 -and $A[0] -eq '--tiebreak') { $suffix = '.tiebreak'; $A = @($A | Select-Object -Skip 1) }
  if ($A.Count -lt 1 -or $A[0] -notmatch '^[0-9]+$') { Die 'round must be a number' }
  "round-$($A[0])$suffix"
}

# Put back the working tree saved by Get-Snapshot. Only paths that differ from HEAD now, or
# differed before the review, are touched; the index is never touched.
function Invoke-Restore([string[]] $A) {
  $tag = Get-RoundTag $A
  $snapFile = "$StateDir/$tag.snapshot"
  if (-not (Test-Path $snapFile) -or (Get-Item $snapFile).Length -eq 0) { Die "no snapshot for $tag" 2 }
  $snap = (Get-Content $snapFile -Raw).Trim()
  $paths = @(Get-ZList @('diff', '--name-only', '-z', 'HEAD', $snap, '--', '.', $Exclude)) +
           @(Get-ZList @('diff', '--name-only', '-z', 'HEAD', '--', '.', $Exclude)) +
           @(Get-Untracked) | Sort-Object -Unique
  foreach ($f in $paths) {
    $entry = (& git ls-tree $snap -- ":(literal)$f")
    if (-not $entry) {
      Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue   # created by the reviewer, or deleted before
      continue
    }
    & git diff --quiet HEAD $snap -- ":(literal)$f"
    if ($LASTEXITCODE -eq 0) {
      & git restore --source=HEAD --worktree -- ":(literal)$f"   # was unchanged: normal checkout
      continue
    }
    $sha = (($entry -split "`t", 2)[0] -split ' ')[2]
    $full = Join-Path $top $f
    $dir = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if (-not (Save-Blob $sha $full)) { Die "could not restore $f" }
  }
  # Compare content, not git status: with core.autocrlf an untouched file restored from HEAD
  # can look modified to status while its content is unchanged.
  if ((Get-Snapshot) -ne $snap) { Die 'files restored, but the tree still differs from before the review; inspect with: git status' }
  Write-Output "restored the working tree to its state before the $tag review"
}

function Get-TreeState {
  $parts = @()
  $parts += & git status --porcelain=v1 -uall -- . $Exclude
  $parts += & git diff HEAD -- . $Exclude
  foreach ($f in (Get-Untracked)) { $parts += "$f $(& git hash-object -- $f)" }
  $bytes = $Utf8.GetBytes(($parts -join "`n"))
  $sha = [System.Security.Cryptography.SHA256]::Create()
  [BitConverter]::ToString($sha.ComputeHash($bytes))
}

function Invoke-Init([string[]] $A) {
  $Need = ''; $rounds = 3; $tiebreaker = 0
  for ($i = 0; $i -lt $A.Count; $i++) {
    switch -regex ($A[$i]) {
      '^--rounds$' {
        if ($i + 1 -ge $A.Count -or $A[$i + 1] -notmatch '^[1-9][0-9]*$') { Die '--rounds needs a positive number' }
        $rounds = [int] $A[$i + 1]; $i++; break
      }
      '^--tiebreaker$' { $tiebreaker = 1; break }
      '^--' { Die "unknown option: $($A[$i])" }
      default { $Need = $A[$i] }
    }
  }
  $Need = $Need -replace '\+run', ''   # agy+run needs the same CLI as agy
  if (Test-Path $Check) {
    $checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Check)
    # agy has no sign-in status command, so when it is one of this run's reviewers, the check
    # sends it one tiny test prompt (a few seconds) instead of failing on the first review.
    if ($Need -and (($Need -split ',') -contains 'agy')) { $checkArgs += '-Deep' }
    if ($Need) { $checkArgs += @('-Need', $Need) }
    $out = & $PsHost @checkArgs 2>&1
    if ($LASTEXITCODE -ne 0) { $out | Write-Output; Die 'prerequisites missing; run /sparring:check' 5 }
  }
  & git rev-parse --verify HEAD *> $null
  if ($LASTEXITCODE -ne 0) { Die 'repository has no commits yet; make an initial commit first' 2 }
  New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
  # The state directory ignores itself, so the project's .gitignore stays untouched.
  Set-Content -Path (Join-Path $StateDir '.gitignore') -Value '*' -Encoding ascii
  # A new run starts clean, so stale rounds can never be read as this run's. The last run's
  # files are kept in previous/ (replacing the run before it).
  $old = @(Get-ChildItem -Path $StateDir -Filter 'round-*' -Force)
  if ($old.Count -gt 0 -or (Test-Path (Join-Path $StateDir 'reviews.tsv'))) {
    $prev = Join-Path $StateDir 'previous'
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $prev
    New-Item -ItemType Directory -Force -Path $prev | Out-Null
    if ($old.Count -gt 0) { $old | Move-Item -Destination $prev }
    foreach ($f in @('task.md', 'base', 'config', 'reviews.tsv')) {
      $p = Join-Path $StateDir $f
      if (Test-Path $p) { Move-Item -Path $p -Destination $prev }
    }
    Write-Output "previous run moved to $StateDir/previous/"
  }
  $base = (& git rev-parse HEAD)
  Set-Content -Path (Join-Path $StateDir 'base') -Value $base -Encoding ascii
  Set-Content -Path (Join-Path $StateDir 'config') -Value @("rounds=$rounds", "tiebreaker=$tiebreaker") -Encoding ascii
  Write-Output "base: $base"
  Write-Output "rounds: $rounds, tiebreaker: $(if ($tiebreaker) { 'yes' } else { 'no' })"
  if (& git status --porcelain -- . $Exclude) {
    Write-Output 'warning: uncommitted changes exist; they will be included in the review'
    & git status --short -- . $Exclude
  }
}

function Test-Prop($Obj, [string] $Name) { $null -ne $Obj -and $Obj.PSObject.Properties.Name -contains $Name }

# Check the verdict against the schema and normalize it: unwrap an agy envelope, and turn
# "approve" with blocking issues into "changes_requested". Returns the JSON text, or $null.
function Get-ValidVerdict([string] $Path) {
  $text = [System.IO.File]::ReadAllText($Path, $Utf8)
  try { $d = $text | ConvertFrom-Json } catch { return $null }
  $changed = $false
  if ((Test-Prop $d 'structured_output') -and -not (Test-Prop $d 'verdict')) { $d = $d.structured_output; $changed = $true }
  if (-not (Test-Prop $d 'verdict') -or $d.verdict -notin @('approve', 'changes_requested')) { return $null }
  if (-not (Test-Prop $d 'issues') -or -not (Test-Prop $d 'withdrawn')) { return $null }
  if ($null -ne $d.issues -and $d.issues -isnot [array]) { return $null }
  if ($null -ne $d.withdrawn -and $d.withdrawn -isnot [array]) { return $null }
  $issues = @($d.issues | Where-Object { $null -ne $_ })
  foreach ($i in $issues) {
    if (-not (Test-Prop $i 'id') -or $i.id -isnot [string]) { return $null }
    if ($i.severity -notin @('blocking', 'nit')) { return $null }
  }
  if ($d.verdict -eq 'approve' -and @($issues | Where-Object { $_.severity -eq 'blocking' }).Count -gt 0) {
    $d.verdict = 'changes_requested'
    $d.summary = "$($d.summary) [sparring: approve changed to changes_requested because blocking issues remain]"
    $changed = $true
  }
  if (-not $changed) { return $text }
  $json = $d | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($Path, $json, $Utf8)
  $json
}

# ---- status: the loop's bookkeeping, computed from the round files -------------------------

# Ids are reduced to [A-Za-z0-9._-], the same as in review.sh.
function Get-CleanId([string] $Id) { $c = $Id -replace '[^A-Za-z0-9._-]', '_'; if ($c) { $c } else { '_' } }

# A response file as objects @{ St = FIXED|FIXED_TB|REBUTTED|SAME; Id; To }.
function Get-ResponseEntries([string] $Path) {
  foreach ($line in [System.IO.File]::ReadAllLines($Path, $Utf8)) {
    $l = $line -replace '[*`\r]', ''
    if ($l -notmatch '^[\s#>-]*([^:\s]+)\s*:\s*(.*)$') { continue }
    $id = Get-CleanId $Matches[1]; $rest = $Matches[2]
    if ($rest -match '^(?i)FIXED AFTER TIEBREAK') { [pscustomobject]@{ St = 'FIXED_TB'; Id = $id; To = '' } }
    elseif ($rest -match '^(?i)FIXED') { [pscustomobject]@{ St = 'FIXED'; Id = $id; To = '' } }
    elseif ($rest -match '^(?i)REBUTTED') { [pscustomobject]@{ St = 'REBUTTED'; Id = $id; To = '' } }
    elseif ($rest -match '^(?i)SAME AS ([^\s,.;]+)') { [pscustomobject]@{ St = 'SAME'; Id = $id; To = (Get-CleanId $Matches[1]) } }
  }
}

# Blocking issue ids of a (validated) review file.
function Get-BlockingIds([string] $Path) {
  try { $d = [System.IO.File]::ReadAllText($Path, $Utf8) | ConvertFrom-Json } catch { Die "cannot read $Path" 4 }
  @($d.issues | Where-Object { $null -ne $_ -and $_.severity -eq 'blocking' } | ForEach-Object { Get-CleanId $_.id })
}

# Sets are ordered string arrays. PowerShell unrolls a returned array (one item becomes a
# string, none becomes $null), so every helper first drops $null and empty items.
function Get-Items($X) { @($X | Where-Object { $null -ne $_ -and "$_" -ne '' }) }
function Join-Set($A, $B) { $r = @(Get-Items $A); foreach ($x in (Get-Items $B)) { if ($r -notcontains $x) { $r += $x } }; $r }
function Get-SetAnd($A, $B) { $b = Get-Items $B; @(Get-Items $A | Where-Object { $b -contains $_ }) }
function Get-SetMinus($A, $B) { $b = Get-Items $B; @(Get-Items $A | Where-Object { $b -notcontains $_ }) }
function Test-SetEq($A, $B) { (Get-SetMinus $A $B).Count -eq 0 -and (Get-SetMinus $B $A).Count -eq 0 }

# Read the round files and say where the loop stands and what to do next. Nothing is changed.
# The rules are the same as in review.sh (see SKILL.md, step 5).
function Invoke-Status {
  if (-not (Test-Path "$StateDir/base")) { Die "run 'review.ps1 init' first" 2 }
  $L = 3; $TB = $false
  $cfgPath = "$StateDir/config"
  if (Test-Path $cfgPath) {
    foreach ($line in (Get-Content $cfgPath)) {
      if ($line -match '^rounds=([1-9][0-9]*)\s*$') { $L = [int] $Matches[1] }
      if ($line -match '^tiebreaker=1\s*$') { $TB = $true }
    }
  }
  $M = 0
  while (Test-Path "$StateDir/round-$($M + 1).review.json") { $M++ }

  # Pass 1: "SAME AS" links from every response, so ids are canonical everywhere.
  $alias = @{}
  $entries = @{}
  for ($n = 1; $n -le $M; $n++) {
    $f = "$StateDir/round-$n.response.md"
    if (-not (Test-Path $f)) { continue }
    $entries[$n] = @(Get-ResponseEntries (Join-Path $top $f))
    foreach ($e in $entries[$n]) { if ($e.St -eq 'SAME') { $alias[$e.Id] = $e.To } }
  }
  $canon = {
    param($id)
    $hops = 0
    while ($alias.ContainsKey($id) -and $alias[$id] -ne $id -and $hops -lt 50) { $id = $alias[$id]; $hops++ }
    $id
  }

  # Pass 2: per round, the open blocking issues and the developer's answers.
  $OpenBy = @{}; $RespBy = @{}; $RebBy = @{}; $FtbBy = @{}
  for ($n = 1; $n -le $M; $n++) {
    $OpenBy[$n] = @(); $RebBy[$n] = @(); $FtbBy[$n] = @(); $RespBy[$n] = $entries.ContainsKey($n)
    foreach ($id in (Get-BlockingIds (Join-Path $top "$StateDir/round-$n.review.json"))) { $OpenBy[$n] = Join-Set $OpenBy[$n] (& $canon $id) }
    if ($RespBy[$n]) {
      foreach ($e in $entries[$n]) {
        $id = & $canon $e.Id
        if ($e.St -eq 'REBUTTED') { $RebBy[$n] = Join-Set $RebBy[$n] $id }
        if ($e.St -eq 'FIXED_TB') { $FtbBy[$n] = Join-Set $FtbBy[$n] $id }
      }
    }
  }

  # Deadlock round D: the round limit, or earlier when every open issue is disputed.
  $D = 0
  for ($n = 1; $n -le $M; $n++) {
    $allDisputed = $n -ge 2 -and $OpenBy[$n].Count -gt 0 -and (Get-SetMinus $OpenBy[$n] $RebBy[$n - 1]).Count -eq 0
    if ($n -eq $L -or $allDisputed) { $D = $n; break }
  }
  $E = $D + 1; $F = $D + 2; $U = $D + 3

  # Tiebreak on E: issues it keeps must be fixed; issues it drops are closed for good.
  $tbFile = "$StateDir/round-$E.tiebreak.review.json"
  $tbRan = $false; $kept = @(); $closed = @()
  if ($D -gt 0 -and $M -ge $E -and (Test-Path $tbFile)) {
    $tbRan = $true
    $tbOpen = @()
    foreach ($id in (Get-BlockingIds (Join-Path $top $tbFile))) { $tbOpen = Join-Set $tbOpen (& $canon $id) }
    $kept = Get-SetAnd $OpenBy[$E] $tbOpen
    $closed = Get-SetMinus $OpenBy[$E] $kept
    for ($n = $E + 1; $n -le $M; $n++) { $OpenBy[$n] = Get-SetMinus $OpenBy[$n] $closed }
  }

  $open = @(); $disputed = @(); $respFile = ''; $tier = 'same'; $result = ''; $note = ''; $fix = @()
  if ($M -gt 0) { $open = $OpenBy[$M] }
  if ($M -ge 2) { $disputed = Get-SetAnd $open $RebBy[$M - 1] }
  if ($M -eq 0) { $stage = 'normal'; $next = 'review 1' }
  elseif ($open.Count -eq 0) {
    $stage = 'done'; $next = 'finish'
    if ($D -eq 0 -or $M -le $E) { $result = 'approved' }
    elseif ($M -eq $F) { $result = if ($tbRan) { 'approved-after-tiebreak' } else { 'approved' } }
    else { $result = 'user-decided' }
  }
  elseif ($D -eq 0 -or $M -le $D) {
    $stage = 'normal'
    if (-not $RespBy[$M]) { $next = "respond $M" }
    elseif ($M -eq $D) {
      $stage = 'escalation'; $next = "review $E"; $respFile = "$StateDir/round-$D.response.md"; $tier = 'deep'
      $note = if ($D -lt $L) { 'every open issue is disputed: deadlock before the round limit' } else { 'round limit reached' }
    }
    else {
      $next = "review $($M + 1)"; $respFile = "$StateDir/round-$M.response.md"
      if ($M -ge 2 -and (Test-SetEq $open $OpenBy[$M - 1])) {
        $tier = 'up'; $note = "no progress: the same blocking issues are open as in round $($M - 1)"
      }
    }
  }
  elseif ($M -eq $E) {
    $stage = 'escalation'; $tier = 'deep'
    if ($tbRan) { $fix = Get-SetMinus $kept $FtbBy[$E] }
    if (-not $RespBy[$E]) {
      $next = "respond $E"; $note = "re-examine only the open issues, with fresh eyes on both sides' arguments"
    }
    elseif ($TB -and -not $tbRan -and (Get-SetAnd $open $RebBy[$E]).Count -gt 0) {
      $stage = 'tiebreak'; $next = "tiebreak $E"; $respFile = "$StateDir/round-$E.response.md"
    }
    elseif ($tbRan -and $fix.Count -gt 0) {
      $stage = 'tiebreak'; $next = "fix-after-tiebreak $E"
      $note = "fix each kept issue, then add 'ID: FIXED after tiebreak, ...' to $StateDir/round-$E.response.md"
    }
    else { $stage = 'final'; $next = "review $F"; $respFile = "$StateDir/round-$E.response.md" }
  }
  elseif ($M -eq $F) {
    $tier = 'deep'; $stage = 'user'
    if (-not $RespBy[$F]) {
      $next = 'ask-user'; $note = "one question per open issue; record the decisions in $StateDir/round-$F.response.md"
    }
    else {
      $next = "review $U"; $respFile = "$StateDir/round-$F.response.md"; $note = 'only if the decisions changed code; otherwise finish'
    }
  }
  else { $stage = 'done'; $next = 'finish'; $result = 'user-decided'; $note = "report what review $M still raised" }

  $o = @("stage: $stage", "next: $next")
  if ($respFile) { $o += "response_file: $respFile" }
  if ($stage -ne 'done') { $o += "tier: $tier" }
  if ($result) { $o += "result: $result" }
  $o += @("round: $M", "limit: $L", "open: $($open -join ' ')", "disputed: $($disputed -join ' ')")
  if ($tbRan) { $o += @("tiebreak_kept: $($kept -join ' ')", "closed: $($closed -join ' ')") }
  if ($fix.Count -gt 0) { $o += "fix: $($fix -join ' ')" }
  if ($note) { $o += "note: $note" }
  $o | ForEach-Object { Write-Output $_ }
}

# A disposable copy of the project for reviewers that may run commands (tool+run): a shared
# clone at HEAD (its own refs and config, so nothing done there reaches this repo), with the
# developer's changed, new and deleted files applied byte for byte, plus the state files the
# prompt names. Ignored files (node_modules, virtualenvs, .env) are not copied.
function New-ReviewCopy {
  $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('sparring-copy.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $c = Join-Path $dir 'project'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  & git clone --quiet --shared --no-checkout $top $c *> $null
  if ($LASTEXITCODE -ne 0) { Remove-ReviewCopy $dir; return $null }
  $head = (& git rev-parse HEAD)
  & git -C $c -c advice.detachedHead=false checkout --quiet --detach $head *> $null
  if ($LASTEXITCODE -ne 0) { Remove-ReviewCopy $dir; return $null }
  try {
    foreach ($f in (Get-ZList @('ls-files', '-z', '-d', '--', '.', $Exclude))) {
      Remove-Item -Force -LiteralPath (Join-Path $c $f) -ErrorAction SilentlyContinue
    }
    foreach ($f in (Get-ZList @('ls-files', '-z', '-m', '-o', '--exclude-standard', '--', '.', $Exclude))) {
      $src = Join-Path $top $f
      if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
      $dst = Join-Path $c $f
      $parent = Split-Path -Parent $dst
      if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
      Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
    }
    $state = Join-Path $c $StateDir
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    Get-ChildItem -LiteralPath (Join-Path $top $StateDir) -File -Force | Copy-Item -Destination $state -Force -ErrorAction Stop
  } catch { Remove-ReviewCopy $dir; return $null }
  $dir
}
function Remove-ReviewCopy([string] $Dir) {
  if ($Dir -and (Test-Path -LiteralPath $Dir)) { Remove-Item -Recurse -Force -LiteralPath $Dir -ErrorAction SilentlyContinue }
}

# One line per reviewer call (retries and failures too) in reviews.tsv, so the final report
# can say which model really ran, for how long and at what cost. Reads Invoke-Review's
# variables. The adapter's --meta mode reads its own log for what the CLI reported.
function Write-ReviewRecord([string] $Result) {
  $secs = [int] ((Get-Date) - $started).TotalSeconds
  $ran = $model; $tokens = ''; $attempts = 1
  $meta = @(& $adapter '--meta' (Join-Path $top $logFile) 2>$null)
  foreach ($line in $meta) {
    $l = "$line".Trim()
    if ($l -match '^model=([A-Za-z0-9._:/-]+)$' -and $ran -eq $model) { $ran = $Matches[1] }
    elseif ($l -match '^tokens=([0-9]+)$') { $tokens = $Matches[1] }
    elseif ($l -match '^attempts=([1-9])$') { $attempts = [int] $Matches[1] }
  }
  $tsv = Join-Path $top "$StateDir/reviews.tsv"
  if (-not (Test-Path $tsv)) { [System.IO.File]::WriteAllText($tsv, "round`tkind`ttool`tmodel`teffort`tseconds`ttokens`tattempts`tresult`n", $Utf8) }
  $t = if ($tokens) { $tokens } else { '-' }
  [System.IO.File]::AppendAllText($tsv, "$n`t$kind`t$label`t$ran`t$effort`t$secs`t$t`t$attempts`t$Result`n", $Utf8)
  $shown = if ($tokens) { $tokens } else { 'not reported' }
  $tries = if ($attempts -gt 1) { ", $attempts attempts" } else { '' }
  [Console]::Error.WriteLine("reviewer: $label, model $ran, effort $effort, ${secs}s, tokens $shown$tries, $Result")
}

function Invoke-Review([string[]] $A) {
  $tiebreak = $false
  $limit = if ($env:SPARRING_REVIEW_TIMEOUT) { $env:SPARRING_REVIEW_TIMEOUT } else { '540' }
  while ($A.Count -gt 0 -and $A[0] -like '--*') {
    switch ($A[0]) {
      '--tiebreak' { $tiebreak = $true; $A = @($A | Select-Object -Skip 1) }
      '--timeout' {
        if ($A.Count -lt 2) { Die '--timeout needs a number of seconds' }
        $limit = $A[1]; $A = @($A | Select-Object -Skip 2)
      }
      default { Die "unknown option: $($A[0])" }
    }
  }
  if ("$limit" -notmatch '^[1-9][0-9]*$') { Die 'timeout must be a positive number of seconds' }
  $limit = [int] $limit
  if ($A.Count -lt 4) { Die 'usage: review [--tiebreak] [--timeout SECONDS] <round> <tool>[+run] <model|default> <effort> [response-file]' }
  $round, $tool, $model, $effort = $A[0], $A[1], $A[2], $A[3]
  # tool+run: review in a disposable copy where the reviewer may run tests and other commands.
  $runMode = $tool -like '*+run'
  if ($runMode) { $tool = $tool.Substring(0, $tool.Length - 4) }
  $label = if ($runMode) { "$tool+run" } else { $tool }
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
  $stdoutFile = "$StateDir/$tag.$tool.stdout.log"
  $promptFile = "$StateDir/$tag.prompt.txt"
  $prevFile = if ($tiebreak) { "$StateDir/round-$n.review.json" } else { "$StateDir/round-$($n - 1).review.json" }

  # Tracked changes, then each new untracked file as an addition. git writes the diff to the
  # file itself (--output), so PowerShell never re-decodes it and the bytes stay exact.
  # The git index is not touched.
  $diffPath = Join-Path $top $diffFile
  $partPath = "$diffPath.part"
  & git -c core.quotePath=false diff "--output=$diffPath" $base -- . $Exclude
  if ($LASTEXITCODE -ne 0) { Die 'git diff failed' }
  $stream = [System.IO.File]::Open($diffPath, [System.IO.FileMode]::Append)
  try {
    foreach ($f in (Get-Untracked)) {
      & git -c core.quotePath=false diff --no-index "--output=$partPath" -- /dev/null $f
      if (Test-Path $partPath) {
        $bytes = [System.IO.File]::ReadAllBytes($partPath)
        $stream.Write($bytes, 0, $bytes.Length)
        Remove-Item -Force $partPath
      }
    }
  } finally { $stream.Close() }
  if ((Get-Item $diffPath).Length -eq 0) { Die "no changes against $base to review" 3 }

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
  if ($runMode) {
    $lines += @('', "You are working in a disposable copy of the project with the developer's changes applied. You may run tests, builds and linters there; whatever they change in the copy is thrown away. Files ignored by git, such as installed dependencies, are not in the copy; if a test cannot run for that reason, say so in summary.")
  }
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
      'Change your mind when the argument is good; do not drop real bugs to be agreeable.',
      'Before you write issues, look at the ids in the previous review. An issue you raise again keeps its old id, even if you describe it differently.'
    )
  }
  [System.IO.File]::WriteAllText((Join-Path $top $promptFile), (($lines -join "`n") + "`n"), $Utf8)

  $before = Get-TreeState
  $snapFile = "$StateDir/$tag.snapshot"
  $snap = Get-Snapshot
  if ($snap) { Set-Content -Path $snapFile -Value $snap -Encoding ascii }
  else {
    Remove-Item -Force -ErrorAction SilentlyContinue $snapFile
    [Console]::Error.WriteLine("warning: could not snapshot the working tree; 'restore' will not be available for $tag")
  }
  Remove-Item -Force -ErrorAction SilentlyContinue $outFile
  $kind = if ($tiebreak) { 'tiebreak' } else { 'review' }
  $started = Get-Date
  # Run the adapter under a watchdog, so a slow reviewer ends with exit 7 instead of being
  # cut off by the caller's tool timeout. Start-Process joins arguments with spaces, so
  # each one is quoted (none of them can contain a double quote).
  $env:SPARRING_REVIEW_TIMEOUT = "$limit"
  $runDir = $top; $copyDir = $null
  if ($runMode) {
    $copyDir = New-ReviewCopy
    if (-not $copyDir) { Die "could not make a disposable copy of the project for $label" 4 }
    $runDir = Join-Path $copyDir 'project'
  }
  $env:SPARRING_ALLOW_COMMANDS = if ($runMode) { '1' } else { '0' }
  $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $adapter, $model, $effort, $Schema,
               (Join-Path $top $outFile), (Join-Path $top $promptFile)) |
    ForEach-Object { '"' + $_ + '"' }
  $p = Start-Process -FilePath $PsHost -ArgumentList $argList -WorkingDirectory $runDir -NoNewWindow -PassThru `
    -RedirectStandardError (Join-Path $top $logFile) -RedirectStandardOutput (Join-Path $top $stdoutFile)
  $null = $p.Handle   # keeps ExitCode readable after exit on Windows PowerShell 5.1
  if (-not $p.WaitForExit($limit * 1000)) {
    & taskkill /F /T /PID $p.Id *> $null
    Remove-ReviewCopy $copyDir
    [Console]::Error.WriteLine("error: $tool review timed out after ${limit}s; last lines of ${logFile}:")
    Get-Content $logFile -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { [Console]::Error.WriteLine($_) }
    Write-ReviewRecord timeout
    exit 7
  }
  $p.WaitForExit()
  Remove-ReviewCopy $copyDir   # the reviewer is done with it
  if ($p.ExitCode -ne 0) {
    [Console]::Error.WriteLine("error: $tool review failed (exit $($p.ExitCode)); last lines of ${logFile}:")
    Get-Content $logFile -Tail 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
    Write-ReviewRecord failed
    exit 4
  }
  if ((Get-TreeState) -ne $before) {
    [Console]::Error.WriteLine("error: the $tool reviewer changed files in the working tree; review rejected.")
    $restoreArgs = if ($tiebreak) { "--tiebreak $n" } else { "$n" }
    if ($snap) { [Console]::Error.WriteLine("Inspect with: git status. Undo the reviewer's changes with: review.ps1 restore $restoreArgs") }
    else { [Console]::Error.WriteLine("Inspect with: git status. (No snapshot was saved, so 'restore' is not available.)") }
    [Console]::Error.WriteLine('(If they are build or test artifacts, add them to .gitignore.)')
    Write-ReviewRecord rejected
    exit 6
  }
  if (-not (Test-Path $outFile) -or (Get-Item $outFile).Length -eq 0) { Write-ReviewRecord invalid; Die "$tool produced no review output (see $logFile)" 4 }
  $json = Get-ValidVerdict (Join-Path $top $outFile)
  if ($null -eq $json) { Write-ReviewRecord invalid; Die "$tool output is not a valid verdict (see $outFile and $logFile)" 4 }
  Write-ReviewRecord ok
  $json
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { '' }
$rest = @($args | Select-Object -Skip 1)
switch ($cmd) {
  'init'    { Invoke-Init $rest }
  'status'  { Invoke-Status }
  'review'  { Invoke-Review $rest }
  'restore' { Invoke-Restore $rest }
  default   { Die 'usage: review.ps1 init [tools] [--rounds N] [--tiebreaker] | status | review [--tiebreak] [--timeout SECONDS] <round> <tool>[+run] <model|default> <effort> [response-file] | restore [--tiebreak] <round>' }
}
