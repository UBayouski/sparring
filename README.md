# claudex-team

**Claude Code writes the code. Codex CLI reviews it. They loop until Codex approves, and ask
you only when they cannot agree.**

```
 you ──task──▶ orchestrator (Claude Code session)
                 │
                 ├─▶ developer subagent (Claude: haiku / sonnet / opus)   implements, fixes or rebuts
                 │
                 ├─▶ codex exec --sandbox read-only                        reviews, JSON verdict
                 │        ▲                                   │
                 │        └──── fixes / rebuttals ◀───────────┘   up to N rounds, escalating models
                 │
                 └─▶ deadlock? one deep round, then AskUserQuestion (you decide)
```

Works on macOS, Linux, WSL and Windows. Each script has a bash (`.sh`) and a PowerShell
(`.ps1`) version, and the skill picks one based on the platform.

## Requirements

| Tool | Install |
|---|---|
| git | macOS `xcode-select --install` · Debian/Ubuntu `sudo apt install git` · Windows `winget install Git.Git` |
| Claude Code | macOS/Linux/WSL `curl -fsSL https://claude.ai/install.sh \| bash` · Windows `irm https://claude.ai/install.ps1 \| iex` · or `brew install --cask claude-code` |
| Codex CLI | `npm install -g @openai/codex` · or `brew install --cask codex` |
| Codex sign-in | `codex login` (ChatGPT), `codex login --device-auth` (headless), or `printenv OPENAI_API_KEY \| codex login --with-api-key` |
| *Optional:* `gh` or `glab` | Only for opening or reviewing pull/merge requests. The check suggests the one that matches your `origin` remote. Bitbucket needs nothing extra |

The review loop only uses local git, so it works the same with GitHub, GitLab, Bitbucket or a
repo with no remote at all.

Check everything at once, even before Claude Code is installed:

```bash
bash plugins/claudex-team/skills/check/scripts/check-prereqs.sh            # macOS / Linux / WSL / Git Bash
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\claudex-team\skills\check\scripts\check-prereqs.ps1   # Windows
```

## Install

Push this repo to any git host, then:

```bash
claude plugin marketplace add <github-user>/claudex-team                     # GitHub shorthand
claude plugin marketplace add https://gitlab.com/<user>/claudex-team.git     # GitLab
claude plugin marketplace add https://bitbucket.org/<user>/claudex-team.git  # Bitbucket
claude plugin install claudex-team@claudex-team
```

Private repos work as long as your `git` can clone them (SSH key or credential helper).

Or inside a Claude Code session: `/plugin marketplace add <github-user>/claudex-team`, then
`/plugin install claudex-team@claudex-team`.

## Use

In a Claude Code session, in your project folder (a git repo with at least one commit):

```
/claudex-team:check
/claudex-team:run add rate limiting to the public API
```

`check` reports what is missing, prints the real install commands for your OS, and offers to
install Codex (or Claude Code) for you. Each install runs only after you approve it. You do
the Codex sign-in yourself, by typing `! codex login` in the prompt.

### Choosing models

```
/claudex-team:run dev=sonnet,opus reviewer=default:medium,default:high rounds=4 migrate the user table to UUIDs
```

| Option | Meaning | Default |
|---|---|---|
| `orchestrator=` | Model that runs the loop | current session model |
| `dev=` | Allowed Claude models for the developer, weakest → strongest | `haiku,sonnet,opus` |
| `reviewer=` | Allowed Codex models, weakest → strongest, as `model` or `model:effort`. `default` is your Codex default model | `default:low,default:medium,default:high` |
| `rounds=` | Review rounds before deadlock handling | `3` |

The orchestrator rates each task as fast, standard or deep, and maps that onto your lists:
the first entry for fast, the middle one for standard, the last one for deep. It escalates a
tier when a round makes no progress, and never uses a model outside your lists.

A running session can't switch its own model, so to pick the orchestrator use the launcher.
It starts a new session on that model and passes your options through:

```bash
bin/claudex --orchestrator fable --dev sonnet,opus "add rate limiting to the public API"
```
```powershell
.\bin\claudex.ps1 -Orchestrator fable -Dev sonnet,opus "add rate limiting to the public API"
```

To use it from anywhere, put it on your PATH, e.g.
`ln -s "$PWD/bin/claudex" ~/.local/bin/claudex`.

## What happens in a run

1. `init` checks the prerequisites, records the base commit in `.review/base`, and warns about
   uncommitted changes. `.review/` ignores itself, so your `.gitignore` is not touched.
2. The developer subagent implements the task and runs the tests.
3. Codex reviews the diff in a **read-only sandbox** and returns JSON that matches
   `review.schema.json`: a verdict, plus issues marked `blocking` or `nit`, with stable ids.
4. The developer fixes each blocking issue or rebuts it with a technical reason. Codex then
   re-reviews with the rebuttals in hand and withdraws issues it is convinced on.
5. Deadlock (round limit reached, or issues disputed): one escalation round on the strongest
   models. If anything is still open, you get one question per issue, with both positions.
6. Nothing is committed or pushed. You get a summary, and every round is saved in `.review/`
   (`round-N.diff`, `round-N.review.json`, `round-N.response.md`, `round-N.codex.log`).

## Layout

```
.claude-plugin/marketplace.json          marketplace catalog (this repo)
bin/claudex, bin/claudex.ps1             launchers that set the orchestrator model
tests/run-tests.sh                       smoke tests
plugins/claudex-team/
  .claude-plugin/plugin.json
  agents/developer.md                    developer subagent (model chosen per call)
  skills/run/SKILL.md                    the orchestration loop
  skills/run/review.schema.json          Codex output schema
  skills/run/scripts/codex-review.{sh,ps1}
  skills/check/SKILL.md                  prerequisites check and guided install
  skills/check/scripts/check-prereqs.{sh,ps1}
```

## Develop

```bash
bash tests/run-tests.sh                          # smoke tests with a fake codex (no network)
claude plugin validate .                         # check the marketplace and plugin
claude --plugin-dir ./plugins/claudex-team       # try local changes without installing
```

## License

MIT
