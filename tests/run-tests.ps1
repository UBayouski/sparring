# Smoke tests for the PowerShell scripts, using fake `codex` and `agy` CLIs on PATH.
# No network, no real models. Runs on Windows PowerShell 5.1 and pwsh:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts in the ANSI code page.
$ErrorActionPreference = 'Continue'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Review = Join-Path $Root 'plugins\sparring\skills\run\scripts\review.ps1'
$CheckPs = Join-Path $Root 'plugins\sparring\skills\check\scripts\check-prereqs.ps1'
$PsHost = (Get-Process -Id $PID).Path
$Utf8 = New-Object System.Text.UTF8Encoding $false
$T = Join-Path ([System.IO.Path]::GetTempPath()) ('sparring-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force "$T\bin", "$T\proj" | Out-Null
$script:pass = 0; $script:fail = 0
function Test-That([string] $Name, [bool] $Ok) {
  if ($Ok) { "  ok    $Name"; $script:pass++ } else { "  FAIL  $Name"; $script:fail++ }
}

$approve = '{"verdict":"approve","summary":"s","issues":[],"withdrawn":["R1"]}'
$changes = '{"verdict":"changes_requested","summary":"s","issues":[{"id":"R1","severity":"blocking","location":"a.py:1","comment":"c","suggestion":""}],"withdrawn":[]}'
$env:FAKE_ARGS = "$T\args.txt"

# Fake codex: records its arguments, writes a review to the -o file.
@"
`$a = @(`$args)
if (`$a[0] -eq '--version') { 'codex-cli 0.0.0-fake'; exit 0 }
if (`$a[0] -eq 'login') { 'Logged in using ChatGPT'; exit 0 }
`$a | Set-Content -Encoding utf8 `$env:FAKE_ARGS
if (`$env:FAKE_TOUCH) { Add-Content -Path `$env:FAKE_TOUCH -Value 'touched' }
if (`$env:FAKE_CREATE) { Set-Content -Path `$env:FAKE_CREATE -Value 'created' }
if (`$env:FAKE_DELETE) { Remove-Item -Force -LiteralPath `$env:FAKE_DELETE }
if (`$env:FAKE_SLEEP) { Start-Sleep -Seconds ([int] `$env:FAKE_SLEEP) }
for (`$i = 0; `$i -lt `$a.Count; `$i++) { if (`$a[`$i] -eq '-o') { `$out = `$a[`$i + 1] } }
if (`$env:FAKE_REVIEW) { `$json = `$env:FAKE_REVIEW }
elseif (`$out -like '*round-1.review*') { `$json = '$changes' } else { `$json = '$approve' }
[System.IO.File]::WriteAllText(`$out, `$json)
exit 0
"@ | Set-Content -Encoding ascii "$T\bin\codex.ps1"

# Fake agy: records its arguments, prints a JSON envelope with structured_output.
@"
`$a = @(`$args)
if (`$a[0] -eq '--version') { 'agy 1.2.4-fake'; exit 0 }
if (`$a[1] -like 'Reply with only the word ok.*') {
  if (`$null -ne `$env:FAKE_AGY_PROBE) { `$env:FAKE_AGY_PROBE } else { 'ok' }
  if (`$env:FAKE_AGY_PROBE_EXIT) { exit [int] `$env:FAKE_AGY_PROBE_EXIT } else { exit 0 }
}
`$a | Set-Content -Encoding utf8 `$env:FAKE_ARGS
'{"status":"SUCCESS","response":"...","structured_output":$approve,"usage":{"total_tokens":1}}'
exit 0
"@ | Set-Content -Encoding ascii "$T\bin\agy.ps1"

$env:PATH = "$T\bin;$env:PATH"

function Invoke-Rev {
  $o = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $Review @args 2>$null
  $script:code = $LASTEXITCODE
  ($o | Out-String)
}
function Get-FakeArgs { @(Get-Content $env:FAKE_ARGS) }
function Clear-Fakes { Remove-Item Env:FAKE_REVIEW, Env:FAKE_SLEEP, Env:FAKE_TOUCH, Env:FAKE_CREATE, Env:FAKE_DELETE -ErrorAction SilentlyContinue }
function Invoke-RevErr {
  $o = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $Review @args 2>&1
  $script:code = $LASTEXITCODE
  ($o | ForEach-Object { "$_" }) -join "`n"
}
function Get-RawHash([string] $Path) { (& git hash-object --no-filters -- $Path) }

Push-Location "$T\proj"
try {
  & git init -q; & git config user.email t@example.com; & git config user.name t; & git config core.autocrlf false
  [System.IO.File]::WriteAllText("$T\proj\a.py", "x = 1`n")
  [System.IO.File]::WriteAllText("$T\proj\b.py", "z = 0`n")
  & git add -A; & git commit -qm init

  'check-prereqs.ps1 -Deep'
  function Invoke-Check {
    $o = & $PsHost -NoProfile -ExecutionPolicy Bypass -File $CheckPs @args 2>&1
    $script:code = $LASTEXITCODE
    ($o | ForEach-Object { "$_" }) -join "`n"
  }
  $out = Invoke-Check -Deep
  Test-That 'deep: agy signed in' ($code -eq 0 -and $out -match 'signed in \(test prompt' -and $out -match 'READY_REVIEWERS: codex agy')
  $env:FAKE_AGY_PROBE = 'Error: authentication required'; $env:FAKE_AGY_PROBE_EXIT = '1'
  $out = Invoke-Check -Deep -Need agy
  Test-That 'deep: agy not signed in fails' ($code -eq 1 -and $out -match 'missing agy-login' -and $out -match 'authentication required')
  $env:FAKE_AGY_PROBE = 'no token'; Remove-Item Env:FAKE_AGY_PROBE_EXIT
  $out = Invoke-Check -Deep -Need agy
  Test-That 'deep: an answer other than ok fails' ($code -eq 1 -and $out -match 'missing agy-login')
  Remove-Item Env:FAKE_AGY_PROBE

  'review.ps1 with codex'
  $out = Invoke-Rev init codex,agy
  Test-That 'init records base' ((Test-Path .sparring\base) -and $out -match 'base:')
  Test-That 'state dir ignores itself' (-not (& git status --porcelain -- .sparring))
  [System.IO.File]::WriteAllText("$T\proj\.sparring\task.md", "Add y.`n")

  $uni = 'caf' + [char]0xE9 + ' ' + [char]0x2713
  $nonAsciiName = 'na' + [char]0xEF + 've.py'
  [System.IO.File]::AppendAllText("$T\proj\a.py", "s = '$uni'`n", $Utf8)
  [System.IO.File]::WriteAllText("$T\proj\$nonAsciiName", "print(1)`n")
  [System.IO.File]::WriteAllText("$T\proj\with space.py", "print(2)`n")

  $out = Invoke-Rev review 1 codex default medium
  Test-That 'round 1 returns JSON verdict' ($code -eq 0 -and $out -match 'changes_requested')
  $diff = [System.IO.File]::ReadAllText("$T\proj\.sparring\round-1.diff", $Utf8)
  Test-That 'diff keeps UTF-8 content' ($diff.Contains($uni))
  Test-That 'diff includes non-ASCII untracked file' ($diff.Contains("b/$nonAsciiName"))
  Test-That 'diff includes untracked file with space' ($diff.Contains('b/with space.py'))
  $fa = Get-FakeArgs
  Test-That 'read-only sandbox' ($fa -contains 'read-only')
  Test-That 'output schema passed' (($fa -join ' ') -match 'review\.schema\.json')
  Test-That 'effort passed' ($fa -contains 'model_reasoning_effort=medium')
  Test-That 'default model sends no -m' ($fa -notcontains '-m')

  [System.IO.File]::WriteAllText("$T\proj\.sparring\round-1.response.md", "R1: REBUTTED - not needed`n")
  $out = Invoke-Rev review 2 codex gpt-test high .sparring\round-1.response.md
  Test-That 'round 2 approves' ($code -eq 0 -and $out -match '"approve"')
  Test-That 'explicit model sends -m' ((Get-FakeArgs) -contains 'gpt-test')
  $prompt = [System.IO.File]::ReadAllText("$T\proj\.sparring\round-2.prompt.txt")
  Test-That 'round 2 sees previous review and response' ($prompt -match 'round-1\.review\.json' -and $prompt -match 'round-1\.response\.md')
  Test-That 'round 2 is told to keep ids' ($prompt -match 'keeps its old id')

  'review.ps1 with agy'
  $null = Invoke-Rev review 1 codex default medium
  $out = Invoke-Rev review --tiebreak 1 agy gemini-x minimal .sparring\round-1.response.md
  Test-That 'agy verdict unwrapped' ($code -eq 0 -and $out -match '"verdict"' -and $out -notmatch 'structured_output')
  $fa = Get-FakeArgs
  Test-That 'agy plan mode + sandbox' (($fa -contains 'plan') -and ($fa -contains '--sandbox'))
  Test-That 'minimal maps to low for agy' ($fa -contains 'low')
  Test-That 'agy timeout follows the driver' ($fa -contains '525s')
  Test-That 'tiebreak saved separately' (Test-Path .sparring\round-1.tiebreak.review.json)

  'verdict validation'
  $env:FAKE_REVIEW = '{"verdict":"approve","summary":"s","issues":[{"id":"R9","severity":"blocking","location":"x","comment":"c","suggestion":""}],"withdrawn":[]}'
  $out = Invoke-Rev review 3 codex default low
  Test-That 'approve with blocking is downgraded' ($code -eq 0 -and $out -match 'changes_requested' -and $out -match 'approve changed')
  $env:FAKE_REVIEW = '{"verdict":"approve","summary":"s","issues":[{"id":"N1","severity":"nit","location":"x","comment":"c","suggestion":""}],"withdrawn":[]}'
  $out = Invoke-Rev review 3 codex default low
  Test-That 'approve with only nits stays' ($code -eq 0 -and $out -match '"approve"' -and $out -notmatch 'changes_requested')
  $env:FAKE_REVIEW = '{"verdict":"maybe","issues":[],"withdrawn":[]}'
  $null = Invoke-Rev review 3 codex default low
  Test-That 'bad verdict value exits 4' ($code -eq 4)
  $env:FAKE_REVIEW = 'not json, but "verdict"'
  $null = Invoke-Rev review 3 codex default low
  Test-That 'non-JSON output exits 4' ($code -eq 4)
  Clear-Fakes

  'timeout'
  $env:FAKE_SLEEP = '30'
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $null = Invoke-Rev review --timeout 3 3 codex default low
  Test-That 'slow reviewer exits 7' ($code -eq 7)
  Test-That 'and is stopped promptly' ($sw.Elapsed.TotalSeconds -lt 20)
  Clear-Fakes
  $null = Invoke-Rev review --timeout abc 3 codex default low
  Test-That 'rejects a bad timeout' ($code -ne 0 -and $code -ne 7)

  'safety'
  New-Item -ItemType Directory -Force "$T\proj\sub dir" | Out-Null
  $crlfName = "sub dir\crlf " + [char]0xFC + ".txt"
  [System.IO.File]::WriteAllText("$T\proj\$crlfName", "one`r`ntwo`r`n")
  $sumA = Get-RawHash a.py; $sumCrlf = Get-RawHash $crlfName
  $env:FAKE_TOUCH = "$T\proj\a.py"; $env:FAKE_CREATE = "$T\proj\sub dir\junk.txt"; $env:FAKE_DELETE = "$T\proj\b.py"
  $err = Invoke-RevErr review 3 codex default low
  Test-That 'reviewer editing files exits 6' ($code -eq 6)
  Test-That 'exit 6 names the restore command' ($err -match 'restore 3')
  Test-That 'snapshot leaves the index alone' (-not (& git diff --cached --name-only))
  Clear-Fakes
  $null = Invoke-Rev restore 3
  Test-That 'restore succeeds' ($code -eq 0)
  Test-That 'restore undoes an edit' ((Get-RawHash a.py) -eq $sumA)
  # An untouched file comes back as git checkout writes it, so with core.autocrlf it may be CRLF.
  Test-That 'restore brings back an untouched file' ((Test-Path b.py) -and ([System.IO.File]::ReadAllText("$T\proj\b.py").Replace("`r", '') -eq "z = 0`n"))
  Test-That 'restore removes a created file' (-not (Test-Path "$T\proj\sub dir\junk.txt"))
  Test-That 'restore keeps CRLF bytes exactly' ((Get-RawHash $crlfName) -eq $sumCrlf)
  $env:FAKE_TOUCH = "$T\proj\$crlfName"
  $null = Invoke-Rev review 3 codex default low
  Clear-Fakes
  $null = Invoke-Rev restore 3
  Test-That 'restore of an edited CRLF file is exact' ($code -eq 0 -and (Get-RawHash $crlfName) -eq $sumCrlf)
  Remove-Item -Recurse -Force "$T\proj\sub dir"
  $null = Invoke-Rev restore 99
  Test-That 'restore without snapshot fails' ($code -eq 2)
  $null = Invoke-Rev review 3 nosuchtool default low
  Test-That 'rejects an unknown tool' ($code -ne 0)
  $null = Invoke-Rev review 3 codex default turbo
  Test-That 'rejects a bad effort' ($code -ne 0)
  & git checkout -q -- .
  Remove-Item -Force "$T\proj\$nonAsciiName", "$T\proj\with space.py"
  $null = Invoke-Rev review 3 codex default low
  Test-That 'no changes exits 3' ($code -eq 3)
  Test-That 'index left clean' (-not (& git status --porcelain))

  'new run'
  $out = Invoke-Rev init codex
  Test-That 'init moves the old run aside' ($out -match 'previous run moved' -and (Test-Path .sparring\previous\round-1.review.json))
  Test-That 'init leaves no stale rounds' (-not (Get-ChildItem .sparring -Filter 'round-*') -and -not (Test-Path .sparring\task.md))

  'status'
  # Round files are written by hand here; status only reads them.
  $env:SPARRING_DIR = '.st'
  function Write-Rv([string] $File) {
    $ids = @($args)
    $items = ($ids | ForEach-Object { '{"id":"' + $_ + '","severity":"blocking","location":"a","comment":"c","suggestion":""}' }) -join ','
    $v = if ($ids.Count) { 'changes_requested' } else { 'approve' }
    [System.IO.File]::WriteAllText("$T\proj\.st\$File", '{"verdict":"' + $v + '","summary":"s","issues":[' + $items + '],"withdrawn":[]}')
  }
  function Write-Resp([string] $File, [string[]] $Lines) { [System.IO.File]::WriteAllLines("$T\proj\.st\$File", $Lines) }
  function Get-Field([string] $Name) {
    $o = Invoke-Rev status
    foreach ($l in ($o -split "`r?`n")) { if ($l.StartsWith("${Name}: ")) { return $l.Substring($Name.Length + 2) } }
    ''
  }
  $null = Invoke-Rev init codex --rounds 2 --tiebreaker
  $cfg = @(Get-Content .st\config)
  Test-That 'init saves rounds and tiebreaker' ($cfg -contains 'rounds=2' -and $cfg -contains 'tiebreaker=1')
  Test-That 'fresh run: review 1' ((Get-Field next) -eq 'review 1')
  Write-Rv round-1.review.json R1 R2
  Test-That 'after review: respond' ((Get-Field next) -eq 'respond 1')
  Write-Resp round-1.response.md @('R1: FIXED - x', '- **R2**: REBUTTED - y')
  Test-That 'after response: next review' ((Get-Field next) -eq 'review 2' -and (Get-Field response_file) -eq '.st/round-1.response.md' -and (Get-Field tier) -eq 'same')
  Write-Rv round-2.review.json R2
  Write-Resp round-2.response.md @('R2: REBUTTED - still')
  Test-That 'round limit: escalation on deep' ((Get-Field next) -eq 'review 3' -and (Get-Field tier) -eq 'deep' -and (Get-Field stage) -eq 'escalation')
  Test-That 'kept rebuttal is disputed' ((Get-Field disputed) -eq 'R2')
  Write-Rv round-3.review.json R2 R3
  Test-That 'escalation: respond' ((Get-Field next) -eq 'respond 3')
  Write-Resp round-3.response.md @('R2: REBUTTED', 'R3: rebutted, no')
  Test-That 'rebuttal left: tiebreak' ((Get-Field next) -eq 'tiebreak 3')
  Write-Rv round-3.tiebreak.review.json R3
  Test-That 'tiebreak kept: fix it' ((Get-Field next) -eq 'fix-after-tiebreak 3' -and (Get-Field fix) -eq 'R3' -and (Get-Field closed) -eq 'R2')
  Write-Resp round-3.response.md @('R2: REBUTTED', 'R3: rebutted, no', 'R3: FIXED after tiebreak, z')
  Test-That 'fixed after tiebreak: final review' ((Get-Field next) -eq 'review 4' -and (Get-Field stage) -eq 'final')
  Write-Rv round-4.review.json R2
  Test-That 'closed issue raised again ignored' ((Get-Field next) -eq 'finish' -and (Get-Field result) -eq 'approved-after-tiebreak')
  Write-Rv round-4.review.json R5
  Test-That 'still open: ask the user' ((Get-Field next) -eq 'ask-user' -and (Get-Field open) -eq 'R5')
  Write-Resp round-4.response.md @('R5: user chose the reviewer fix')
  Test-That 'decisions recorded: last review' ((Get-Field next) -eq 'review 5')
  Write-Rv round-5.review.json R5
  Test-That 'after last review: finish' ((Get-Field next) -eq 'finish' -and (Get-Field result) -eq 'user-decided')

  $null = Invoke-Rev init codex
  Test-That 'default limit is 3, no tiebreaker' ((Get-Field limit) -eq '3' -and (@(Get-Content .st\config) -contains 'tiebreaker=0'))
  Write-Rv round-1.review.json R1; Write-Resp round-1.response.md @('R1: FIXED')
  Write-Rv round-2.review.json R1; Write-Resp round-2.response.md @('R1: FIXED, again')
  Test-That 'no progress: tier up' ((Get-Field next) -eq 'review 3' -and (Get-Field tier) -eq 'up')
  $null = Invoke-Rev init codex
  Write-Rv round-1.review.json R1; Write-Resp round-1.response.md @('R1: REBUTTED - wrong')
  Write-Rv round-2.review.json R4
  Test-That 'new id is a new issue' ((Get-Field next) -eq 'respond 2' -and (Get-Field disputed) -eq '')
  Write-Resp round-2.response.md @('R4: SAME AS R1', 'R4: REBUTTED - see round 1')
  Test-That 'SAME AS links ids' ((Get-Field open) -eq 'R1' -and (Get-Field disputed) -eq 'R1')
  Test-That 'all disputed: early deadlock' ((Get-Field next) -eq 'review 3' -and (Get-Field stage) -eq 'escalation' -and (Get-Field note) -like '*before the round limit*')
  Write-Rv round-3.review.json R1; Write-Resp round-3.response.md @('R1: REBUTTED')
  Test-That 'no tiebreaker: final review' ((Get-Field next) -eq 'review 4')
  $null = Invoke-Rev init codex
  Write-Rv round-1.review.json
  Test-That 'approve: finish' ((Get-Field next) -eq 'finish' -and (Get-Field result) -eq 'approved')
  Remove-Item Env:SPARRING_DIR
} finally {
  Remove-Item Env:SPARRING_DIR -ErrorAction SilentlyContinue
  Pop-Location
  Clear-Fakes
  Remove-Item -Recurse -Force $T -ErrorAction SilentlyContinue
}

''
"$script:pass passed, $script:fail failed"
if ($script:fail -ne 0) { exit 1 }
