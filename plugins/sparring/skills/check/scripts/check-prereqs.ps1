# Prerequisite checker and installer for sparring (Windows PowerShell 5.1+ and pwsh).
#
#   check-prereqs.ps1 [-Need codex,agy]  Check everything; print install commands for anything missing.
#                                        -Need: reviewer CLIs that must be ready (default: at least one)
#   check-prereqs.ps1 -Deep              Also send agy one tiny test prompt to confirm it is signed in
#                                        (agy has no sign-in status command; takes a few seconds)
#   check-prereqs.ps1 install claude|codex|agy
#                                        Install one tool with the recommended method.
#
# Exit codes for the check: 0 = ready, 1 = something required is missing or not signed in.
# Run it on its own, before Claude Code is installed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugins\sparring\skills\check\scripts\check-prereqs.ps1
param(
  [Parameter(Position = 0)] [string] $Command,
  [Parameter(Position = 1)] [string] $Tool,
  [string] $Need,
  [switch] $Deep
)
$ErrorActionPreference = 'Continue'

function Have([string] $Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# The agy installer only updates PATH for new terminals; find a fresh install anyway.
$agyBin = Join-Path $env:LOCALAPPDATA 'agy\bin'
if (-not (Have agy) -and (Test-Path (Join-Path $agyBin 'agy.exe'))) { $env:PATH = "$agyBin;$env:PATH" }
function FirstLine { param([scriptblock] $Block) $o = & $Block 2>$null; if ($o) { "$(@($o)[0])".Trim() } }
function Report([string] $Status, [string] $Name, [string] $Detail) { Write-Output ('{0,-9} {1,-14} {2}' -f $Status, $Name, $Detail) }

function Hint-Git   { Write-Output '    winget install Git.Git        # also gives Claude Code its Bash tool (Git Bash)' }
function Hint-Claude {
  Write-Output '    irm https://claude.ai/install.ps1 | iex       # recommended, auto-updates'
  Write-Output '    winget install Anthropic.ClaudeCode           # WinGet alternative'
  Write-Output "    then run 'claude' once to sign in (needs a Pro, Max, Team, Enterprise or Console account)"
}
function Hint-Codex {
  Write-Output '    npm install -g @openai/codex       # needs Node.js'
  if (-not (Have npm)) { Write-Output '    (npm not found: install Node.js 22+ first:  winget install OpenJS.NodeJS.LTS)' }
}
function Hint-ForgeCli([string] $Cli) {
  if ($Cli -eq 'gh') { Write-Output '    winget install --id GitHub.cli' }
  else { Write-Output '    winget install glab.glab' }
  Write-Output "    then: $Cli auth login"
}
function Hint-Agy {
  Write-Output '    irm https://antigravity.google/cli/install.ps1 | iex'
  Write-Output "    then run 'agy' once to sign in (or use a Gemini API key, see the agy docs)"
}
function Hint-AgyLogin {
  Write-Output '    agy                                           # run once in a terminal and sign in'
  Write-Output '    (or use a Gemini API key, see the agy docs)'
}
function Hint-CodexLogin {
  Write-Output '    codex login                                   # browser sign-in with ChatGPT'
  Write-Output '    codex login --device-auth                     # headless / remote machines'
  Write-Output '    $env:OPENAI_API_KEY | codex login --with-api-key   # API key instead'
  Write-Output '    (inside Claude Code you can type:  ! codex login)'
}

if ($Command -eq 'install') {
  switch ($Tool) {
    'claude' {
      if (Have claude) { Write-Output "claude is already installed: $(FirstLine { claude --version })"; exit 0 }
      Write-Output '+ irm https://claude.ai/install.ps1 | iex'
      try { Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression } catch { Write-Output $_; exit 1 }
      Write-Output "Installed. Open a new terminal if 'claude' is not on PATH yet, then run 'claude' to sign in."
      exit 0
    }
    'codex' {
      if (Have codex) { Write-Output "codex is already installed: $(FirstLine { codex --version })"; exit 0 }
      if (-not (Have npm)) {
        Write-Output 'npm was not found. Install Node.js 22+ first:  winget install OpenJS.NodeJS.LTS'
        exit 2
      }
      Write-Output '+ npm install -g @openai/codex'
      & npm install -g '@openai/codex'
      if ($LASTEXITCODE -ne 0) { exit 1 }
      Write-Output "Installed: $(FirstLine { codex --version }). Next: sign in with 'codex login'."
      exit 0
    }
    'agy' {
      if (Have agy) { Write-Output "agy is already installed: $(FirstLine { agy --version })"; exit 0 }
      Write-Output '+ irm https://antigravity.google/cli/install.ps1 | iex'
      try { Invoke-RestMethod https://antigravity.google/cli/install.ps1 | Invoke-Expression } catch { Write-Output $_; exit 1 }
      Write-Output "Installed. Open a new terminal if 'agy' is not on PATH yet, then run 'agy' once to sign in."
      exit 0
    }
    default {
      Write-Output 'usage: check-prereqs.ps1 install claude|codex|agy'
      Write-Output 'git is not installed automatically; install it with:'
      Hint-Git
      exit 2
    }
  }
}

$missing = @()
Write-Output 'sparring prerequisites (windows)'
Write-Output ''

if (Have git) { Report OK git (FirstLine { git --version }) }
else { Report MISSING git 'required'; Hint-Git; $missing += 'git' }

if (Have claude) { Report OK claude (FirstLine { claude --version }) }
else { Report MISSING claude 'required (Claude Code, the developer)'; Hint-Claude; $missing += 'claude' }

# Reviewers: each one is ready when installed (and, for codex, signed in).
$ready = @(); $codexUnready = $false; $agyUnready = $false
if (Have codex) {
  $status = & codex login status 2>&1
  if ($LASTEXITCODE -eq 0) { Report OK codex ((FirstLine { codex --version }) + ', ' + "$(@($status)[0])".Trim()); $ready += 'codex' }
  else { Report MISSING codex-login 'Codex is installed but not signed in'; Hint-CodexLogin; $codexUnready = $true }
} else { Report REVIEWER codex 'not installed (OpenAI Codex CLI)'; Hint-Codex }
if (Have agy) {
  # agy has no sign-in status command. -Deep sends one tiny prompt (outside plan mode, which
  # would answer with a plan file) and expects "ok" back.
  if ($Deep) {
    Push-Location ([System.IO.Path]::GetTempPath())
    $probe = ($null | & agy -p 'Reply with only the word ok. Do not use any tools.' --sandbox --effort low --print-timeout 90s 2>&1) -join "`n"
    $probeCode = $LASTEXITCODE
    Pop-Location
    if ($probeCode -eq 0 -and $probe.Trim() -match '^ok[.!]?$') {
      Report OK agy ((FirstLine { agy --version }) + ', signed in (test prompt answered; beta reviewer)'); $ready += 'agy'
    } else {
      $last = @($probe -split "`n" | Where-Object { $_.Trim() })[-1]
      Report MISSING agy-login "agy is installed but the test prompt failed (exit $probeCode): $last"; Hint-AgyLogin; $agyUnready = $true
    }
  } else {
    Report OK agy ((FirstLine { agy --version }) + ' (beta reviewer; sign-in not verified, run the check with -Deep)'); $ready += 'agy'
  }
} else { Report REVIEWER agy 'not installed (Google Antigravity CLI, beta reviewer)'; Hint-Agy }

if ($Need) {
  foreach ($r in ($Need -split ',')) {
    if ($ready -contains $r) { continue }
    if ($r -eq 'codex' -and $codexUnready) { $missing += 'codex-login' }
    elseif ($r -eq 'agy' -and $agyUnready) { $missing += 'agy-login' }
    else { $missing += $r }
  }
} elseif ($ready.Count -eq 0) {
  if ($codexUnready) { $missing += 'codex-login' }
  if ($agyUnready) { $missing += 'agy-login' }
  if (-not ($codexUnready -or $agyUnready)) { $missing += 'reviewer(codex or agy)' }
}

# Optional: the CLI for wherever this project is hosted. The review loop only uses local git.
$remote = ''
if (Have git) { $remote = "$(& git remote get-url origin 2>$null)" }
$forge = 'other'; $cli = ''
if (-not $remote) { $forge = 'none' }
elseif ($remote -match 'github') { $forge = 'github'; $cli = 'gh' }
elseif ($remote -match 'gitlab') { $forge = 'gitlab'; $cli = 'glab' }
elseif ($remote -match 'bitbucket') { $forge = 'bitbucket' }
if ($cli) {
  if (Have $cli) {
    & $cli auth status *> $null
    $signedIn = ($LASTEXITCODE -eq 0)
    $v = FirstLine { & $cli --version }
    if ($signedIn) { Report OK $cli "$v ($forge, optional, signed in)" }
    else { Report OPTIONAL $cli "$v, not signed in; run: $cli auth login" }
  } else {
    Report OPTIONAL $cli "not found; origin is on $forge. Only needed for opening or reviewing merge/pull requests"
    Hint-ForgeCli $cli
  }
} elseif ($forge -eq 'bitbucket') { Report INFO forge 'origin is on Bitbucket; there is no official CLI, git alone is enough' }
elseif ($forge -eq 'none') { Report INFO forge 'no origin remote; local-only works fine' }
else { Report INFO forge 'origin is on another host; git alone is enough' }

if (Have node) { Report INFO node (FirstLine { node --version }) }
else { Report INFO node 'not found (only needed to install Codex with npm)' }

if (Have git) {
  & git rev-parse --is-inside-work-tree *> $null
  if ($LASTEXITCODE -eq 0) {
    & git rev-parse --verify HEAD *> $null
    if ($LASTEXITCODE -eq 0) { Report OK project 'git repo with commits' }
    else { Report WARN project "git repo has no commits yet; run: git add -A; git commit -m 'initial commit'" }
  } else {
    Report WARN project "current folder is not a git repo; run: git init; git add -A; git commit -m 'initial commit'"
  }
}

Write-Output ''
$readyText = if ($ready.Count) { $ready -join ' ' } else { 'none' }
if ($missing.Count -gt 0) { Write-Output "RESULT: missing $($missing -join ' ')"; Write-Output "READY_REVIEWERS: $readyText"; exit 1 }
Write-Output 'RESULT: ready'
Write-Output "READY_REVIEWERS: $readyText"
