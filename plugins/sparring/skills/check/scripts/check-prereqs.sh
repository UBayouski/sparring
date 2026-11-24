#!/usr/bin/env bash
# Prerequisite checker and installer for sparring.
#
#   check-prereqs.sh [--need codex,agy] [--deep]
#                               Check everything; print install commands for anything missing.
#                               --need: reviewer CLIs that must be ready (default: at least one)
#                               --deep: send agy one tiny test prompt to confirm it is signed in
#                                       (agy has no sign-in status command; takes a few seconds)
#   check-prereqs.sh install claude|codex|agy
#                               Install one tool with the recommended method for this machine.
#
# Exit codes for the check: 0 = ready, 1 = something required is missing or not signed in.
# The script can also be run on its own, before Claude Code is installed:
#   bash plugins/sparring/skills/check/scripts/check-prereqs.sh
set -uo pipefail

OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Darwin) PLATFORM=macos ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then PLATFORM=wsl; else PLATFORM=linux; fi ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *) PLATFORM=unknown ;;
esac

have() { command -v "$1" >/dev/null 2>&1; }

# Windows: a PowerShell one-liner that also works when typed in bash (Claude Code's "!" runs bash).
ps_cmd() { echo "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$1\""; }

# Windows installers put agy here but only update PATH for new terminals.
add_agy_path() {
  [[ "$PLATFORM" == windows && -n "${LOCALAPPDATA:-}" ]] || return 0
  local d; d="$(cygpath -u "$LOCALAPPDATA" 2>/dev/null || echo "$LOCALAPPDATA")/agy/bin"
  [[ -x "$d/agy.exe" || -x "$d/agy" ]] && ! have agy && export PATH="$d:$PATH"
  return 0
}
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
    windows) echo "    $(ps_cmd 'irm https://claude.ai/install.ps1 | iex')" ;;
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

hint_agy() {
  case "$PLATFORM" in
    windows) echo "    $(ps_cmd 'irm https://antigravity.google/cli/install.ps1 | iex')" ;;
    *)       echo "    curl -fsSL https://antigravity.google/cli/install.sh | bash" ;;
  esac
  echo "    then run 'agy' once to sign in (or use a Gemini API key, see the agy docs)"
}

hint_agy_login() {
  echo "    agy                                                # run once in a terminal and sign in"
  echo "    (or use a Gemini API key, see the agy docs)"
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
      if [[ "$PLATFORM" == windows ]]; then
        echo "+ $(ps_cmd 'irm https://claude.ai/install.ps1 | iex')"
        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex" || return 1
        echo "Installed. Open a new terminal if 'claude' is not on PATH yet, then run 'claude' to sign in."
        return 0
      fi
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
    agy)
      add_agy_path
      if have agy; then echo "agy is already installed: $(ver agy --version)"; return 0; fi
      if [[ "$PLATFORM" == windows ]]; then
        echo "+ $(ps_cmd 'irm https://antigravity.google/cli/install.ps1 | iex')"
        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://antigravity.google/cli/install.ps1 | iex" || return 1
        echo "Installed. Open a new terminal if 'agy' is not on PATH yet, then run 'agy' once to sign in."
        return 0
      fi
      have curl || { echo "curl is required for the agy installer"; return 2; }
      echo "+ curl -fsSL https://antigravity.google/cli/install.sh | bash"
      curl -fsSL https://antigravity.google/cli/install.sh | bash || return 1
      echo "Installed. Open a new terminal if 'agy' is not on PATH yet, then run 'agy' once to sign in."
      ;;
    *)
      echo "usage: $0 install claude|codex|agy"
      echo "git is not installed automatically because it needs sudo or a system installer:"
      hint_git
      return 2 ;;
  esac
}

need="" deep=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --need) need="${2:-}"; shift; shift || true ;;
    --deep) deep=1; shift ;;
    *) break ;;
  esac
done

if [[ "${1:-}" == install ]]; then
  install_tool "${2:-}"
  exit $?
fi

# ---------- check ----------

add_agy_path

missing=()
report() { printf '%-9s %-14s %s\n' "$1" "$2" "$3"; }

echo "sparring prerequisites ($PLATFORM)"
echo

if have git; then report OK git "$(ver git --version)"
else report MISSING git "required"; hint_git; missing+=(git); fi

if have claude; then report OK claude "$(ver claude --version)"
else report MISSING claude "required (Claude Code, the developer)"; hint_claude; missing+=(claude); fi

# Reviewers: each one is "ready" when installed (and, for codex, signed in).
ready_reviewers=()
if have codex; then
  if codex login status >/dev/null 2>&1; then
    report OK codex "$(ver codex --version), $(codex login status 2>&1 | head -n 1)"; ready_reviewers+=(codex)
  else
    report MISSING codex-login "Codex is installed but not signed in"; hint_codex_login
    codex_unready=1
  fi
else
  report REVIEWER codex "not installed (OpenAI Codex CLI)"; hint_codex
fi
if have agy; then
  # agy has no sign-in status command. --deep sends one tiny prompt (outside plan mode, which
  # would answer with a plan file) and expects "ok" back.
  if [[ -n "$deep" ]]; then
    probe="$(cd "${TMPDIR:-/tmp}" && agy -p "Reply with only the word ok. Do not use any tools."              --sandbox --effort low --print-timeout 90s </dev/null 2>&1)"; probe_code=$?
    if ((probe_code == 0)) && [[ "$(printf '%s' "$probe" | tr -d '[:space:].!' | tr '[:upper:]' '[:lower:]')" == ok ]]; then
      report OK agy "$(ver agy --version), signed in (test prompt answered; beta reviewer)"
      ready_reviewers+=(agy)
    else
      report MISSING agy-login "agy is installed but the test prompt failed (exit $probe_code): $(printf '%s' "$probe" | tail -n 1)"
      hint_agy_login
      agy_unready=1
    fi
  else
    report OK agy "$(ver agy --version) (beta reviewer; sign-in not verified, run the check with --deep)"
    ready_reviewers+=(agy)
  fi
else
  report REVIEWER agy "not installed (Google Antigravity CLI, beta reviewer)"; hint_agy
fi

if [[ -n "$need" ]]; then
  IFS=, read -r -a needed <<< "$need"
  for r in "${needed[@]}"; do
    [[ " ${ready_reviewers[*]:-} " == *" $r "* ]] && continue
    if [[ "$r" == codex && -n "${codex_unready:-}" ]]; then missing+=(codex-login)
    elif [[ "$r" == agy && -n "${agy_unready:-}" ]]; then missing+=(agy-login)
    else missing+=("$r"); fi
  done
elif ((${#ready_reviewers[@]} == 0)); then
  [[ -n "${codex_unready:-}" ]] && missing+=(codex-login)
  [[ -n "${agy_unready:-}" ]] && missing+=(agy-login)
  [[ -n "${codex_unready:-}${agy_unready:-}" ]] || missing+=("reviewer(codex or agy)")
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
  echo "READY_REVIEWERS: ${ready_reviewers[*]:-none}"
  exit 1
fi
echo "RESULT: ready"
echo "READY_REVIEWERS: ${ready_reviewers[*]}"
