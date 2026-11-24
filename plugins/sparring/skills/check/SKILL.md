---
name: check
description: Check the sparring prerequisites (git, Claude Code, and the reviewer CLIs Codex and Antigravity with their sign-in), show real install commands for anything missing, and install them with the user's permission.
allowed-tools: Bash("${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh") Bash("${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh" --need *) Bash(${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh) Bash(${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh --need *) Bash("${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh" --deep) Bash("${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh" --deep *) Bash(${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh --deep) Bash(${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh --deep *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1") PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1" -Need *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1" -Deep) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1" -Deep *) Read
---

# Sparring: prerequisites check

Arguments (optional): $ARGUMENTS. If they name reviewer tools (`codex`, `agy`), pass them as
`--need codex,agy`. Without them, at least one reviewer must be ready. If they include `deep`,
pass `--deep` (PowerShell: `-Deep`) first, before any `--need`: it sends `agy` one tiny test
prompt to confirm it is signed in, because `agy` has no sign-in status command. It takes a few
seconds and one model request, so use it only when asked or when an `agy` review failed.

## 1. Run the check for this platform

Your environment info gives the platform.
- **macOS, Linux, WSL**, or **Windows with the Bash tool** (Git Bash):
  `"${CLAUDE_SKILL_DIR}/scripts/check-prereqs.sh" [--deep] [--need <tools>]` (keep the double
  quotes: the path can contain spaces, or backslashes on Windows)
- **Windows without the Bash tool** (PowerShell tool only):
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/check-prereqs.ps1" [-Deep] [-Need <tools>]`
  (use `pwsh` in place of `powershell` if it is installed)

The output ends with `RESULT: ready` or `RESULT: missing <items>`, then `READY_REVIEWERS:`.
For each missing item it shows the real install commands for this machine.

## 2. Report

If the result is ready, say so in one line, listing the versions found and which reviewers
are ready, and stop. Mention optional items (`OPTIONAL`, `REVIEWER`) and any `NOTE` only in a
short second line. End with the `NEXT:` line's point: only the user can start the loop, by
typing `/sparring:run <task>`; you cannot start it yourself.

Otherwise show the user each missing item with its install commands, exactly as printed.

## 3. Offer to install

Ask once with AskUserQuestion (multiSelect) which items to install now. Offer only what can be
installed safely without a password:

| Item | How you install it |
|---|---|
| `codex` | the check script with `install codex` (Homebrew on macOS if present, otherwise npm; never sudo) |
| `agy` | the check script with `install agy` (Google's official installer). Mark it beta |
| `claude` | the check script with `install claude` (official installer). Only relevant when this check was run outside Claude Code |
| `codex-login` | **The user does this themselves.** Sign-in opens a browser or needs a secret. Tell them to type `! codex login` in this prompt, or `! codex login --device-auth` on a remote machine. With `OPENAI_API_KEY` set, they can run `! printenv OPENAI_API_KEY \| codex login --with-api-key` |
| `agy-login` (or agy sign-in) | **The user does this themselves**: run `agy` once interactively in a terminal (not with `!`, it needs a real terminal). Without `deep`, the check cannot tell whether agy is signed in; if they are unsure, offer to re-run it with `deep` |
| `git`, `gh`, `glab` | **The user does this themselves**, with the printed command, because it needs sudo or a system installer |

Run the install command only for items the user selected: `<check script> install <item>`
(on PowerShell: `... check-prereqs.ps1 install <item>`). Claude Code also shows its own
permission prompt for the command, and that prompt is the user's final say.

If an install fails, show the last lines of its output and the manual command, and do not
retry with sudo, a different package manager or a workaround the user did not choose.

## 4. Re-check

Run the check again and report the final result in one line.
