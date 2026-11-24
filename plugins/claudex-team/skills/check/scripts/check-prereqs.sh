#!/usr/bin/env bash
# Prerequisite checker and installer for claudex-team.
#
#   check-prereqs.sh            Check everything; print install commands for anything missing.
#   check-prereqs.sh install claude|codex
#                               Install one tool with the recommended method for this machine.
#
# Exit codes for the check: 0 = ready, 1 = a required tool is missing or Codex is not signed in.
# The script can also be run on its own, before Claude Code is installed:
#   bash plugins/claudex-team/skills/check/scripts/check-prereqs.sh
set -uo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM=wsl; else PLATFORM=linux; fi ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) PLATFORM=unknown ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }
ver()  { "$@" 2>/dev/null | head -n 1; }

# ---------- install hints (real commands, per platform) ----------

hint_git() {
  case "$PLATFORM" in
    macos)   echo "    xcode-select --install        # or: brew install git" ;;
    linux|wsl)
      echo "    sudo apt install git          # Debian / Ubuntu"
      echo "    sudo dnf install git          # Fedora / RHEL" ;;
    windows) echo "    winget install Git.Git" ;;
    *)       echo "    see https://git-scm.com/downloads" ;;
  esac
}

hint_claude() {
  case "$PLATFORM" in
    windows) echo "    irm https://claude.ai/install.ps1 | iex      # PowerShell" ;;
    *)
      echo "    curl -fsSL https://claude.ai/install.sh | bash   # recommended, auto-updates"
      [[ "$PLATFORM" == macos ]] && echo "    brew install --cask claude-code                  # Homebrew alternative"
      echo "    npm install -g @anthropic-ai/claude-code         # npm alternative (no sudo)" ;;
  esac
  echo "    then run 'claude' once to sign in (needs a Pro, Max, Team, Enterprise or Console account)"
}

hint_codex() {
  echo "    npm install -g @openai/codex          # needs Node.js; never use sudo"
  [[ "$PLATFORM" == macos ]] && echo "    brew install --cask codex             # Homebrew alternative"
  have npm || echo "    (npm not found: install Node.js 22+ from https://nodejs.org, or use Homebrew)"
}

hint_forge_cli() {  # gh | glab
  case "$1:$PLATFORM" in
    gh:macos)        echo "    brew install gh" ;;
    gh:linux|gh:wsl) echo "    sudo apt install gh           # Debian / Ubuntu (GitHub's own apt repo has newer)"
                     echo "    sudo dnf install gh           # Fedora / RHEL" ;;
    gh:windows)      echo "    winget install --id GitHub.cli" ;;
    glab:windows)    echo "    winget install glab.glab" ;;
    glab:*)          echo "    brew install glab             # officially supported on macOS and Linux"
                     echo "    or a binary from https://gitlab.com/gitlab-org/cli/-/releases" ;;
    *)               echo "    see https://cli.github.com or https://gitlab.com/gitlab-org/cli" ;;
  esac
  echo "    then: $1 auth login"
}

hint_codex_login() {
  echo "    codex login                                        # browser sign-in with ChatGPT"
  echo "    codex login --device-auth                          # headless / remote machines"
  echo "    printenv OPENAI_API_KEY | codex login --with-api-key   # API key instead"
  echo "    (inside Claude Code you can type:  ! codex login)"
}

# ---------- install ----------

npm_global_writable() {
  local prefix dir
  prefix="$(npm prefix -g 2>/dev/null)" || return 1
  dir="$prefix/lib/node_modules"
  [[ "$PLATFORM" == windows ]] && dir="$prefix/node_modules"
  [[ -d "$dir" ]] || dir="$prefix"
  [[ -w "$dir" ]]
}

install_tool() {
  local tool="${1:-}"
  case "$tool" in
    claude)
      if have claude; then echo "claude is already installed: $(ver claude --version)"; return 0; fi
      [[ "$PLATFORM" == windows ]] && { echo "On Windows run in PowerShell:  irm https://claude.ai/install.ps1 | iex"; return 2; }
      have curl || { echo "curl is required for the native installer"; return 2; }
      echo "+ curl -fsSL https://claude.ai/install.sh | bash"
      curl -fsSL https://claude.ai/install.sh | bash || return 1
      echo "Installed. Open a new terminal if 'claude' is not on PATH yet, then run 'claude' to sign in."
      ;;
    codex)
      if have codex; then echo "codex is already installed: $(ver codex --version)"; return 0; fi
      if [[ "$PLATFORM" == macos ]] && have brew; then
        echo "+ brew install --cask codex"
        brew install --cask codex || return 1
      elif have npm; then
        if ! npm_global_writable; then
          echo "npm's global folder ($(npm prefix -g)) is not writable, and sudo must not be used."
          echo "Fix it once, then retry:"
          echo "    npm config set prefix ~/.npm-global && export PATH=\"\$HOME/.npm-global/bin:\$PATH\""
          echo "    (add that export line to your ~/.bashrc or ~/.zshrc)"
          return 2
        fi
        echo "+ npm install -g @openai/codex"
        npm install -g @openai/codex || return 1
      else
        echo "Neither npm nor Homebrew was found. Install Node.js 22+ from https://nodejs.org first."
        return 2
      fi
      echo "Installed: $(ver codex --version). Next: sign in with 'codex login'."
      ;;
    *)
      echo "usage: $0 install claude|codex"
      echo "git is not installed automatically because it needs sudo or a system installer:"
      hint_git
      return 2 ;;
  esac
}

if [[ "${1:-}" == install ]]; then
  install_tool "${2:-}"
  exit $?
fi

# ---------- check ----------

missing=()
report() { printf '%-9s %-14s %s\n' "$1" "$2" "$3"; }

echo "claudex-team prerequisites ($PLATFORM)"
echo

if have git; then report OK git "$(ver git --version)"
else report MISSING git "required"; hint_git; missing+=(git); fi

if have claude; then report OK claude "$(ver claude --version)"
else report MISSING claude "required (Claude Code, the developer)"; hint_claude; missing+=(claude); fi

if have codex; then
  report OK codex "$(ver codex --version)"
  if codex login status >/dev/null 2>&1; then
    report OK codex-login "$(ver codex login status)"
  else
    report MISSING codex-login "Codex is not signed in"; hint_codex_login; missing+=(codex-login)
  fi
else
  report MISSING codex "required (Codex CLI, the reviewer)"; hint_codex; missing+=(codex)
fi

# Optional: the CLI for wherever this project is hosted. The review loop itself only uses
# local git, so none of these is required.
remote="$(git remote get-url origin 2>/dev/null || true)"
case "$remote" in
  *github*)    forge=github;    cli=gh ;;
  *gitlab*)    forge=gitlab;    cli=glab ;;
  *bitbucket*) forge=bitbucket; cli="" ;;
  "")          forge=none;      cli="" ;;
  *)           forge=other;     cli="" ;;
esac
if [[ -n "$cli" ]]; then
  if have "$cli"; then
    if "$cli" auth status >/dev/null 2>&1; then report OK "$cli" "$(ver "$cli" --version) ($forge, optional, signed in)"
    else report OPTIONAL "$cli" "$(ver "$cli" --version), not signed in; run: $cli auth login"; fi
  else
    report OPTIONAL "$cli" "not found; origin is on $forge. Only needed for opening or reviewing merge/pull requests"
    hint_forge_cli "$cli"
  fi
else
  case "$forge" in
    bitbucket) report INFO forge "origin is on Bitbucket; there is no official CLI, git alone is enough" ;;
    none)      report INFO forge "no origin remote; local-only works fine" ;;
    *)         report INFO forge "origin is on another host; git alone is enough" ;;
  esac
fi

if have node; then report INFO node "$(ver node --version)"
else report INFO node "not found (only needed to install Codex with npm)"; fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git rev-parse --verify HEAD >/dev/null 2>&1; then report OK project "git repo with commits"
  else report WARN project "git repo has no commits yet; run: git add -A && git commit -m 'initial commit'"; fi
else
  report WARN project "current folder is not a git repo; run: git init && git add -A && git commit -m 'initial commit'"
fi

echo
if ((${#missing[@]})); then
  echo "RESULT: missing ${missing[*]}"
  exit 1
fi
echo "RESULT: ready"
