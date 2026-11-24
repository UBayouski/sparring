# Prerequisite checker and installer for claudex-team (Windows PowerShell 5.1+ and pwsh).
#
#   check-prereqs.ps1                    Check everything; print install commands for anything missing.
#   check-prereqs.ps1 install claude|codex
#                                        Install one tool with the recommended method.
#
# Exit codes for the check: 0 = ready, 1 = a required tool is missing or Codex is not signed in.
# Run it on its own, before Claude Code is installed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File plugins\claudex-team\skills\check\scripts\check-prereqs.ps1
param(
  [Parameter(Position = 0)] [string] $Command,
  [Parameter(Position = 1)] [string] $Tool
)
$ErrorActionPreference = 'Continue'

function Have([string] $Name) { [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
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
    default {
      Write-Output 'usage: check-prereqs.ps1 install claude|codex'
      Write-Output 'git is not installed automatically; install it with:'
      Hint-Git
      exit 2
    }
  }
}

$missing = @()
Write-Output 'claudex-team prerequisites (windows)'
Write-Output ''

if (Have git) { Report OK git (FirstLine { git --version }) }
else { Report MISSING git 'required'; Hint-Git; $missing += 'git' }

if (Have claude) { Report OK claude (FirstLine { claude --version }) }
else { Report MISSING claude 'required (Claude Code, the developer)'; Hint-Claude; $missing += 'claude' }

if (Have codex) {
  Report OK codex (FirstLine { codex --version })
  $status = & codex login status 2>&1
  if ($LASTEXITCODE -eq 0) { Report OK codex-login ("$(@($status)[0])".Trim()) }
  else { Report MISSING codex-login 'Codex is not signed in'; Hint-CodexLogin; $missing += 'codex-login' }
} else {
  Report MISSING codex 'required (Codex CLI, the reviewer)'; Hint-Codex; $missing += 'codex'
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
if ($missing.Count -gt 0) { Write-Output "RESULT: missing $($missing -join ' ')"; exit 1 }
Write-Output 'RESULT: ready'
