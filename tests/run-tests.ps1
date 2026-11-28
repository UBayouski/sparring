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
$answer = '{"answer":"x is never reassigned","confidence":"high","findings":[{"id":"C1","location":"a.py:1","claim":"c","evidence":"e"}],"unchecked":[]}'
$reply = '{"verdict":"agree","comment":"c","points":[{"id":"C1","status":"stands","comment":"c"}]}'
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
# Where it ran, and what it saw there: a.py's last line, .sparring's entries, branch count.
(Get-Location).Path | Set-Content -Encoding utf8 "`$env:FAKE_ARGS.ccwd"
`$last = if (Test-Path a.py) { @(Get-Content a.py)[-1] } else { '' }
`$sp = (@(Get-ChildItem -Force -Name .sparring -ErrorAction SilentlyContinue) -join ' ')
`$refs = @(& git for-each-ref refs/heads refs/remotes 2>`$null).Count
"`$last|`$sp|`$refs" | Set-Content -Encoding utf8 "`$env:FAKE_ARGS.ccopy"
# What codex exec logs: the model in its header, then the token count.
[Console]::Error.WriteLine('model: gpt-fake'); [Console]::Error.WriteLine('tokens used'); [Console]::Error.WriteLine('1,234')
for (`$i = 0; `$i -lt `$a.Count; `$i++) { if (`$a[`$i] -eq '-o') { `$out = `$a[`$i + 1] } }
if (`$out -like '*answer.json') {   # challenge
  if (`$env:FAKE_ANSWER) { `$json = `$env:FAKE_ANSWER } elseif (`$out -like '*round-2.*') { `$json = '$reply' } else { `$json = '$answer' }
}
elseif (`$env:FAKE_REVIEW) { `$json = `$env:FAKE_REVIEW }
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
if (`$env:FAKE_AGY_ARGS) { `$env:FAKE_ARGS = `$env:FAKE_AGY_ARGS }   # its own file when it runs next to codex
`$a | Set-Content -Encoding utf8 `$env:FAKE_ARGS
# Where it ran, and what that folder held (for +run): a.py's bytes, with space.py, b.py.
(Get-Location).Path | Set-Content -Encoding utf8 "`$env:FAKE_ARGS.cwd"
`$aHash = if (Test-Path a.py) { (Get-FileHash a.py).Hash } else { '' }
"`$aHash|`$(Test-Path 'with space.py')|`$(Test-Path b.py)" | Set-Content -Encoding utf8 "`$env:FAKE_ARGS.copy"
if (`$env:FAKE_AGY_TOUCH) { Add-Content -Path `$env:FAKE_AGY_TOUCH -Value 'touched' }
# FAKE_AGY_DENY=<counter file>: the first FAKE_AGY_DENY_TIMES calls (default 1) ask for a
# shell command, which plan mode denies, so they return no verdict.
if (`$env:FAKE_AGY_DENY) {
  `$n = if (Test-Path `$env:FAKE_AGY_DENY) { [int] (Get-Content `$env:FAKE_AGY_DENY) } else { 0 }
  Set-Content -Path `$env:FAKE_AGY_DENY -Value (`$n + 1)
  `$times = if (`$env:FAKE_AGY_DENY_TIMES) { [int] `$env:FAKE_AGY_DENY_TIMES } else { 1 }
  if (`$n -lt `$times) {
    '{"status":"SUCCESS","response":"","usage":{"total_tokens":5},"denied_actions":[{"action":"command","display_name":"Bash"}]}'
    exit 0
  }
}
`$so = '$approve'
if (`$a[1] -like '*check a question*') { `$so = '$answer' }
if (`$a[1] -like '*check a question*This is round 2*') { `$so = '$reply' }
'{"conversation_id":"fake-conv-1","status":"SUCCESS","response":"...","structured_output":' + `$so + ',"usage":{"total_tokens":1}}'
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
  $env:FAKE_AGY_PROBE_EXIT = '1'
  $out = Invoke-RevErr init codex,agy
  Test-That 'init with agy checks its sign-in' ($code -eq 5 -and $out -match 'missing agy-login')
  $null = Invoke-RevErr init codex
  Test-That 'init without agy skips that check' ($code -eq 0)
  Remove-Item Env:FAKE_AGY_PROBE, Env:FAKE_AGY_PROBE_EXIT
  $out = Invoke-Check
  Test-That 'ready says only the user starts run' ($out -match 'NEXT: only the user')

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

  'reviews.tsv'
  $tsv = @(Get-Content .sparring\reviews.tsv)
  Test-That 'has a header' ($tsv[0] -eq "round`tkind`ttool`tmodel`teffort`tseconds`ttokens`tattempts`tresult")
  Test-That 'codex: model and tokens from its log' ($tsv[1] -match "^1`treview`tcodex`tgpt-fake`tmedium`t\d+`t1234`t1`tok$")
  Test-That 'every call is a line' ($tsv.Count -eq 5)
  Test-That 'agy: requested model, its tokens' ($tsv[4] -match "^1`ttiebreak`tagy`tgemini-x`tminimal`t\d+`t1`t1`tok$")
  $out = Invoke-RevErr review 2 codex default medium .sparring\round-1.response.md
  Test-That 'prints a reviewer line' ($out -match 'reviewer: codex, model gpt-fake, effort medium, \d+s, tokens 1234, ok')

  'agy asking for a shell command'
  $deny = "$T\deny.txt"
  Remove-Item -Force -ErrorAction SilentlyContinue $deny
  $env:FAKE_AGY_DENY = $deny
  $out = Invoke-RevErr review --tiebreak 1 agy default low .sparring\round-1.response.md
  $log = Get-Content -Raw .sparring\round-1.tiebreak.agy.log
  Test-That 'agy is told not to run commands' ((Get-FakeArgs) -join ' ' -match 'shell commands are not available here')
  Test-That 'retried once, then a verdict' ($code -eq 0 -and (Get-Content $deny) -eq '2' -and $log -match 'retrying once without commands')
  Test-That 'the retry is told why' ((Get-FakeArgs) -join ' ' -match 'previous attempt asked for a shell command')
  Test-That 'attempts and summed tokens recorded' ((Get-Content .sparring\reviews.tsv)[-1] -match "`tagy`tdefault`tlow`t\d+`t6`t2`tok$")
  Test-That 'reviewer line shows the retry' ($out -match 'tokens 6, 2 attempts, ok')
  Remove-Item -Force $deny
  $env:FAKE_AGY_DENY_TIMES = '9'
  $out = Invoke-RevErr review --tiebreak 1 agy default low .sparring\round-1.response.md
  Test-That 'denied twice: fails, no third try' ($code -eq 4 -and (Get-Content $deny) -eq '2')
  Test-That 'the failure is recorded' ((Get-Content .sparring\reviews.tsv)[-1] -match "`t2`tfailed$")
  Remove-Item Env:FAKE_AGY_DENY, Env:FAKE_AGY_DENY_TIMES
  $null = Invoke-Rev review --tiebreak 1 agy gemini-x minimal .sparring\round-1.response.md   # put the tiebreak back

  'agy+run (disposable copy)'
  $aBefore = (Get-FileHash a.py).Hash
  Remove-Item b.py   # a deleted tracked file must be missing in the copy too
  $env:FAKE_AGY_TOUCH = 'a.py'
  $out = Invoke-RevErr review --tiebreak 1 agy+run default low .sparring\round-1.response.md
  Remove-Item Env:FAKE_AGY_TOUCH
  & git checkout -q -- b.py
  $copyDir = (Get-Content "$env:FAKE_ARGS.cwd" | Select-Object -First 1).Trim()
  Test-That '+run: verdict, real tree untouched' ($code -eq 0 -and (Get-FileHash a.py).Hash -eq $aBefore)
  Test-That '+run: ran in a copy, not the project' ($copyDir -ne (Get-Location).Path -and $copyDir -match 'sparring-copy\.[0-9a-f]+\\project$')
  Test-That "+run: copy had the developer's files" ((Get-Content "$env:FAKE_ARGS.copy" | Select-Object -First 1).Trim() -eq "$aBefore|True|False")
  $fa = Get-FakeArgs
  Test-That '+run: no plan mode, no no-commands note' ($fa -notcontains 'plan' -and -not (($fa -join ' ') -match 'shell commands are not available'))
  Test-That '+run: prompt says it is a copy' ((Get-Content -Raw .sparring\round-1.tiebreak.prompt.txt) -match 'disposable copy of the project')
  Test-That '+run: copy removed afterwards' ($copyDir -and -not (Test-Path -LiteralPath $copyDir))
  Test-That '+run: recorded as agy+run' ((Get-Content .sparring\reviews.tsv)[-1] -match "^1`ttiebreak`tagy\+run`tdefault`tlow`t")
  Remove-Item "$env:FAKE_ARGS.cwd" -ErrorAction SilentlyContinue   # so a review that fails early cannot pass on the copy's folder
  $out = Invoke-RevErr review 1 agy default low
  if ($code -ne 0) { [Console]::Error.WriteLine("exit ${code}: " + (($out -split "`n") | Select-Object -Last 5) -join "`n") }
  Test-That 'plain agy: review ok' ($code -eq 0)
  $cwd = if (Test-Path "$env:FAKE_ARGS.cwd") { (Get-Content "$env:FAKE_ARGS.cwd" | Select-Object -First 1).Trim() } else { '' }
  Test-That 'plain agy still in the project, plan mode' ($cwd -eq (Get-Location).Path -and (Get-FakeArgs) -contains 'plan')
  $null = Invoke-Rev review 1 codex default medium   # put round 1 back

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
  $out = Invoke-Rev init codex,agy+run
  Test-That 'init accepts agy+run' ($code -eq 0)
  Test-That 'init moves the old run aside' ($out -match 'previous run moved' -and (Test-Path .sparring\previous\round-1.review.json))
  Test-That 'init moves reviews.tsv aside too' ((Test-Path .sparring\previous\reviews.tsv) -and -not (Test-Path .sparring\reviews.tsv))
  Test-That 'init leaves no stale rounds' (-not (Get-ChildItem .sparring -Filter 'round-*') -and -not (Test-Path .sparring\task.md))

  'challenge'
  $out = Invoke-Rev challenge init codex,agy+run
  Test-That 'init starts a challenge' ($code -eq 0 -and (Test-Path .sparring\challenge\reviews.tsv) -and $out -match 'READY_REVIEWERS: codex agy')
  $null = Invoke-Rev challenge ask 1 codex
  Test-That 'ask needs a brief' ($code -eq 2)
  Set-Content -Encoding ascii .sparring\challenge\brief.md 'Why does x stay 1?'
  Add-Content -Path a.py -Value 'y = 3'   # uncommitted: the +run copy must have it
  $aNow = (Get-FileHash a.py).Hash
  $env:FAKE_AGY_ARGS = "$T\agyargs.txt"
  $out = Invoke-Rev challenge ask 1 codex/default agy+run
  Test-That 'both reviewers answer' ($code -eq 0 -and $out -match '(?s)== reviewer 1: codex/default:high, ok ==.*"answer".*== reviewer 2: agy\+run/default:high, ok ==')
  Test-That 'answers saved by number' ((Test-Path .sparring\challenge\round-1.1.answer.json) -and (Test-Path .sparring\challenge\round-1.2.answer.json))
  Test-That 'agy answer unwrapped' ((Get-Content -Raw .sparring\challenge\round-1.2.answer.json) -notmatch 'structured_output')
  $fa = (Get-FakeArgs) -join ' '; $ga = (Get-Content "$T\agyargs.txt") -join ' '
  Test-That 'challenge schema passed' ($fa -match 'challenge\.schema\.json' -and $ga -match 'challenge\.schema\.json')
  Test-That 'prompt: brief and evidence rules' ($fa -match 'challenge/brief\.md' -and $fa -match 'Every finding needs evidence')
  Test-That 'effort defaults to high' ((Get-FakeArgs) -contains 'model_reasoning_effort=high')
  $cwd = (Get-Content "$T\agyargs.txt.cwd" | Select-Object -First 1).Trim()
  Test-That 'agy+run: in a copy, removed after' ($cwd -match 'sparring-copy\.[0-9a-f]+\\project$' -and -not (Test-Path -LiteralPath $cwd))
  Test-That 'agy+run: copy has uncommitted work' (((Get-Content "$T\agyargs.txt.copy" | Select-Object -First 1) -split '\|')[0] -eq $aNow)
  Test-That 'agy+run: may run commands' ((Get-Content "$T\agyargs.txt") -notcontains 'plan')
  $tsv = Get-Content .sparring\challenge\reviews.tsv
  Test-That 'recorded per reviewer' (($tsv -match "^1`tchallenge-1`tcodex`tgpt-fake`thigh`t[0-9]+`t1234`t1`tok$").Count -eq 1 -and ($tsv -match "^1`tchallenge-2`tagy\+run`tdefault`thigh`t").Count -eq 1)
  Test-That "the run's files are left alone" (-not (Test-Path .sparring\reviews.tsv))
  $null = Invoke-Rev challenge ask 2 codex agy+run
  Test-That 'round 2 needs a reply' ($code -eq 2)
  Set-Content -Encoding ascii .sparring\challenge\reply.md @('# My conclusion', 'x is never reassigned.', '## Reviewer 1', 'C1: agreed', '## Reviewer 2', 'C1: agreed')
  $out = Invoke-Rev challenge ask 2 codex agy+run:low
  Test-That 'round 2 gives verdicts' ($code -eq 0 -and $out -match '(?s)reviewer 2: agy\+run/default:low, ok.*"verdict"')
  $fa = (Get-FakeArgs) -join ' '; $ga = (Get-Content "$T\agyargs.txt") -join ' '
  Test-That 'round 2 sees its answer and reply' ($fa -match 'round-1\.1\.answer\.json' -and $ga -match 'heading Reviewer 2' -and $ga -match 'challenge/reply\.md')
  Test-That 'reply schema passed' ($fa -match 'challenge-reply\.schema\.json')
  $out = Invoke-RevErr challenge ask 2 codex agy agy
  Test-That 'round 2 skips a reviewer without an answer' ($code -eq 0 -and $out -match 'reviewer 3 \(agy\) has no round 1 answer')
  $out = Invoke-Rev challenge ask --only 2 1 codex agy
  Test-That '--only runs just those' ($code -eq 0 -and $out -match 'reviewer 2: agy' -and $out -notmatch 'reviewer 1')
  $env:FAKE_ANSWER = '{"answer":1}'
  $out = Invoke-Rev challenge ask 1 codex agy
  Test-That 'one bad answer: the rest still count' ($code -eq 0 -and $out -match 'reviewer 1: codex/default:high, invalid' -and $out -match 'reviewer 2: agy/default:high, ok')
  $null = Invoke-Rev challenge ask 1 codex
  Test-That 'no valid answer exits 4' ($code -eq 4)
  Remove-Item Env:FAKE_ANSWER
  $env:FAKE_SLEEP = '30'
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $null = Invoke-Rev challenge ask --timeout 3 1 codex
  Test-That 'all timed out: exit 7, promptly' ($code -eq 7 -and $sw.Elapsed.TotalSeconds -lt 20)
  Clear-Fakes
  $env:FAKE_TOUCH = "$T\proj\a.py"
  $null = Invoke-Rev challenge ask 1 codex
  Clear-Fakes
  Test-That 'a changed tree rejects the answers' ($code -eq 6 -and (Get-Content .sparring\challenge\reviews.tsv)[-1] -match "`trejected$")
  $null = Invoke-Rev challenge ask 1 nosuch/x
  Test-That 'rejects an unknown tool' ($code -ne 0)
  $out = Invoke-Rev challenge init codex
  Test-That 'init keeps the last challenge' ($out -match 'previous challenge moved' -and (Test-Path .sparring\challenge-previous\brief.md) -and -not (Test-Path .sparring\challenge\brief.md))
  Remove-Item Env:FAKE_AGY_ARGS
  $env:FAKE_AGY_PROBE = 'auth required'; $env:FAKE_AGY_PROBE_EXIT = '1'
  $out = Invoke-Rev challenge init
  Remove-Item Env:FAKE_AGY_PROBE, Env:FAKE_AGY_PROBE_EXIT
  Test-That 'no tools: a signed-out agy is left out' ($code -eq 0 -and $out -match 'READY_REVIEWERS: codex' -and $out -notmatch 'READY_REVIEWERS: codex agy')

  'challenge --at (clean copy of a commit)'
  $headSha = (& git rev-parse HEAD).Trim()
  $out = Invoke-Rev challenge init --at HEAD codex,agy
  Test-That '--at: commit saved' ($code -eq 0 -and (Get-Content .sparring\challenge\at).Trim() -eq $headSha -and $out -match "clean copy of commit $($headSha.Substring(0, 12))")
  $null = Invoke-Rev challenge init --at nosuchrev codex
  Test-That '--at: a bad commit is refused' ($code -eq 2)
  $null = Invoke-Rev challenge init --at HEAD codex,agy
  Set-Content -Encoding ascii .sparring\challenge\brief.md 'Why does x stay 1?'
  Add-Content -Path a.py -Value 'a dirty line'   # an uncommitted change the reviewers must not see
  Remove-Item "$env:FAKE_ARGS.ccwd", "$T\agyargs.txt.cwd" -ErrorAction SilentlyContinue
  $env:FAKE_AGY_ARGS = "$T\agyargs.txt"
  $out = Invoke-Rev challenge ask 1 codex agy
  $ccwd = if (Test-Path "$env:FAKE_ARGS.ccwd") { (Get-Content "$env:FAKE_ARGS.ccwd" | Select-Object -First 1).Trim() } else { '' }
  $acwd = if (Test-Path "$T\agyargs.txt.cwd") { (Get-Content "$T\agyargs.txt.cwd" | Select-Object -First 1).Trim() } else { '' }
  Test-That '--at: both answered' ($code -eq 0 -and $out -match 'reviewer 1: codex/default:high, ok' -and $out -match 'reviewer 2: agy/default:high, ok')
  Test-That '--at: codex ran in a copy too' ($ccwd -match 'sparring-copy\.[0-9a-f]+\\project$' -and $acwd -match 'sparring-copy\.[0-9a-f]+\\project$' -and $ccwd -ne $acwd)
  $want = "$(@(& git show HEAD:a.py)[-1])|challenge|0"
  $got = (Get-Content "$env:FAKE_ARGS.ccopy" | Select-Object -First 1).Trim()
  Test-That '--at: copy is the commit alone' ($got -eq $want)
  Test-That '--at: plain agy still in plan mode' ((Get-Content "$T\agyargs.txt") -contains 'plan')
  Test-That '--at: prompt names the commit' ((Get-Content -Raw .sparring\challenge\round-1.1.prompt.txt) -match "at commit $headSha, with no uncommitted changes")
  Test-That '--at: copies removed afterwards' ($ccwd -and -not (Test-Path -LiteralPath (Split-Path -Parent $ccwd)) -and -not (Test-Path -LiteralPath (Split-Path -Parent $acwd)))
  $tr = "$T\agyhome\brain\fake-conv-1\.system_generated\logs"
  New-Item -ItemType Directory -Force -Path $tr | Out-Null
  Set-Content -Encoding ascii "$tr\transcript_full.jsonl" @('{"model":"gemini-fake-low"}', '{"model":"gemini-fake-high"}')
  $env:SPARRING_AGY_HOME = "$T\agyhome"
  $null = Invoke-Rev challenge ask --only 2 1 codex agy
  Remove-Item Env:SPARRING_AGY_HOME, Env:FAKE_AGY_ARGS
  Test-That 'agy: model read from its transcript' ((Get-Content .sparring\challenge\reviews.tsv)[-1] -match "^1`tchallenge-2`tagy`tgemini-fake-high`thigh`t")
  # a.py dirty with LF endings only, and autocrlf on: plain git would warn about CRLF.
  [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'a.py'), ((@(& git show HEAD:a.py) + 'a dirty line') -join "`n") + "`n")
  & git config core.autocrlf true
  $out = Invoke-RevErr challenge ask --only 1 1 codex agy
  & git config --unset core.autocrlf
  Test-That 'no CRLF warnings in the output' ($code -eq 0 -and $out -notmatch 'LF will be replaced')
  & git checkout -q -- a.py

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
