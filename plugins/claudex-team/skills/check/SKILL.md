---
name: check
description: Check the claudex-team prerequisites (git, Claude Code, Codex CLI and its sign-in), show real install commands for anything missing, and install them with the user's permission.
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh) Read
---

# Claudex team: prerequisites check

## 1. Run the check for this platform

Your environment info gives the platform.
- **macOS, Linux, WSL**, or **Windows with the Bash tool** (Git Bash):
  `${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh`
- **Windows without the Bash tool** (PowerShell tool only):
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1"`
  (use `pwsh` in place of `powershell` if it is installed)

The last line is `RESULT: ready` or `RESULT: missing <items>`. For each missing item, the
output shows the real install commands for this machine.

## 2. Report

If the result is ready, say so in one line, listing the versions found, and stop.

Otherwise show the user each missing item with its install commands, exactly as printed.

## 3. Offer to install

Ask once with AskUserQuestion (multiSelect) which of the missing items to install now.
Offer only what can be installed safely without a password:

| Item | How you install it |
|---|---|
| `codex` | the check script with `install codex` (Homebrew on macOS if present, otherwise npm; never sudo) |
| `claude` | the check script with `install claude` (official installer). Only relevant when this check was run outside Claude Code |
| `codex-login` | **The user does this themselves.** Sign-in opens a browser or needs a secret. Tell them to type `! codex login` in this prompt, or `! codex login --device-auth` on a remote machine. If `OPENAI_API_KEY` is already set and they would rather use the API key, they can run `! printenv OPENAI_API_KEY \| codex login --with-api-key` |
| `git` | **The user does this themselves**, with the printed command, because it needs sudo or a system installer |

Run the install command only for items the user selected: `<check script> install <item>`
(on PowerShell: `... check-prereqs.ps1 install <item>`). Claude Code also shows its own
permission prompt for the command, and that prompt is the user's final say.

If an install fails, show the last lines of its output and the manual command, and do not
retry with sudo, a different package manager or a workaround the user did not choose.

## 4. Re-check

Run the check again and report the final result in one line.
