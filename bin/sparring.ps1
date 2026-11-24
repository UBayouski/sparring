# Launch a Claude Code session that runs the sparring loop, with the orchestrator model
# chosen up front (a running session cannot switch its own model from inside a skill).
#
#   sparring.ps1 [-Orchestrator MODEL] [-Dev M1,M2,M3] [-Reviewer tool/model:effort,...]
#                [-Tiebreaker tool/model:effort] [-Rounds N] "task"
#
# Example:
#   .\sparring.ps1 -Orchestrator fable -Dev sonnet,opus -Reviewer codex/default:medium,codex/default:high -Tiebreaker agy/default:high "add rate limiting to the API"
param(
  [string] $Orchestrator,
  [string[]] $Dev,
  [string[]] $Reviewer,
  [string] $Tiebreaker,
  [int] $Rounds,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)] [string[]] $Task
)
if (-not $Task) { Write-Error 'no task given'; exit 1 }
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Error "Claude Code not found; see the README's install section"; exit 127 }

$opts = @()
if ($Orchestrator) { $opts += "orchestrator=$Orchestrator" }
if ($Dev)          { $opts += "dev=$($Dev -join ',')" }
if ($Reviewer)     { $opts += "reviewer=$($Reviewer -join ',')" }
if ($Tiebreaker)   { $opts += "tiebreaker=$Tiebreaker" }
if ($Rounds)       { $opts += "rounds=$Rounds" }
$prompt = (@('/sparring:run') + $opts + $Task) -join ' '
# Windows PowerShell before 7 drops embedded double quotes when calling native programs.
if ($PSVersionTable.PSVersion.Major -lt 7) { $prompt = $prompt -replace '"', "'" }

if ($Orchestrator) { & claude --model $Orchestrator $prompt } else { & claude $prompt }
exit $LASTEXITCODE
