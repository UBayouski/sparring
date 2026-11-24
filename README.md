# sparring

**Claude Code writes the code. A reviewer from another vendor (OpenAI Codex, or Google
Antigravity in beta) reviews it. They spar until the reviewer approves, and ask you only when
they cannot agree.**

```
 you ──task──▶ orchestrator (Claude Code session)
                 │
                 ├─▶ developer subagent (Claude: haiku / sonnet / opus)   implements, fixes or rebuts
                 │
                 ├─▶ reviewer adapter: codex | agy                         reviews, JSON verdict
                 │        ▲                               │
                 │        └──── fixes / rebuttals ◀───────┘   up to N rounds, escalating models
                 │
                 └─▶ deadlock? deep round → optional tiebreaker (2 of 3 decide) → you decide
```

Works on macOS, Linux, WSL and Windows. Each script has a bash (`.sh`) and a PowerShell
(`.ps1`) version, and the skill picks one based on the platform.

## Requirements

| Tool | Needed | Install |
|---|---|---|
| git | yes | macOS `xcode-select --install` · Debian/Ubuntu `sudo apt install git` · Windows `winget install Git.Git` |
| Claude Code | yes | macOS/Linux/WSL `curl -fsSL https://claude.ai/install.sh \| bash` · Windows `irm https://claude.ai/install.ps1 \| iex` · or `brew install --cask claude-code` |
| Codex CLI | one reviewer | `npm install -g @openai/codex` · or `brew install --cask codex` · sign in with `codex login` |
| Antigravity CLI (`agy`) | one reviewer (beta) | macOS/Linux `curl -fsSL https://antigravity.google/cli/install.sh \| bash` · Windows `irm https://antigravity.google/cli/install.ps1 \| iex` · sign in by running `agy` once |
| `gh` or `glab` | no | Only for opening or reviewing pull/merge requests. The check suggests the one that matches your `origin` remote. Bitbucket needs nothing extra |

You need at least one reviewer CLI. The review loop only uses local git, so it works the same
with GitHub, GitLab, Bitbucket or a repo with no remote at all.

Check everything at once, even before Claude Code is installed:

```bash
bash plugins/sparring/skills/check/scripts/check-prereqs.sh            # macOS / Linux / WSL / Git Bash
```
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File plugins\sparring\skills\check\scripts\check-prereqs.ps1   # Windows
```

## Install

Push this repo to any git host, then:

```bash
claude plugin marketplace add <github-user>/sparring                     # GitHub shorthand
claude plugin marketplace add https://gitlab.com/<user>/sparring.git     # GitLab
claude plugin marketplace add https://bitbucket.org/<user>/sparring.git  # Bitbucket
claude plugin install sparring@sparring
```

Private repos work as long as your `git` can clone them (SSH key or credential helper).

## Use

In a Claude Code session, in your project folder (a git repo with at least one commit):

```
/sparring:check
/sparring:run add rate limiting to the public API
```

`check` reports what is missing, prints the real install commands for your OS, and offers to
install Codex, Antigravity or Claude Code for you. Each install runs only after you approve
it. You sign in to the reviewers yourself (`! codex login`, or run `agy` once).

### Choosing models and reviewers

```
/sparring:run dev=sonnet,opus reviewer=codex/default:medium,codex/default:high tiebreaker=agy/default:high rounds=4 migrate the user table to UUIDs
```

| Option | Meaning | Default |
|---|---|---|
| `orchestrator=` | Model that runs the loop | current session model |
| `dev=` | Allowed Claude models for the developer, weakest → strongest | `haiku,sonnet,opus` |
| `reviewer=` | Allowed reviewers, weakest → strongest, as `tool/model:effort`. `tool/` defaults to `codex/`, `default` is the tool's default model | `codex/default:low,codex/default:medium,codex/default:high` |
| `tiebreaker=` | Third reviewer used on deadlock, ideally a different vendor | none |
| `rounds=` | Review rounds before deadlock handling | `3` |

The orchestrator rates each task as fast, standard or deep, and maps that onto your lists:
the first entry for fast, the middle one for standard, the last one for deep. It escalates a
tier when a round makes no progress, and never uses a model or tool outside your lists.
You can mix vendors in `reviewer=` too, for example `codex/default:medium,agy/default:high`.

A running session can't switch its own model, so to pick the orchestrator use the launcher.
It starts a new session on that model and passes your options through:

```bash
bin/sparring --orchestrator fable --dev sonnet,opus --tiebreaker agy/default:high "add rate limiting"
```
```powershell
.\bin\sparring.ps1 -Orchestrator fable -Dev sonnet,opus -Tiebreaker agy/default:high "add rate limiting"
```

To use it from anywhere, put it on your PATH, e.g.
`ln -s "$PWD/bin/sparring" ~/.local/bin/sparring`.

## What happens in a run

1. `init` checks the prerequisites for the reviewers you chose, records the base commit in
   `.sparring/base`, and warns about uncommitted changes. `.sparring/` ignores itself, so
   your `.gitignore` is not touched.
2. The developer subagent implements the task and runs the tests.
3. The reviewer reads the task and the diff and returns JSON that matches
   `review.schema.json`: a verdict, plus issues marked `blocking` or `nit`, with stable ids.
   - Codex runs in its **read-only sandbox**.
   - Antigravity runs in **plan mode with its terminal sandbox on**.
   - For both, the driver fingerprints the working tree before and after, and **rejects the
     review if any file changed**.
4. The developer fixes each blocking issue or rebuts it with a technical reason. The reviewer
   then re-reviews with the rebuttals in hand and withdraws issues it is convinced on.
5. Deadlock (round limit reached, or issues disputed): one escalation round on the strongest
   models. Then, if you set one, the tiebreaker judges each disputed issue and two of three
   decide. Anything still open comes to you as one question per issue, with every position.
6. Nothing is committed or pushed. You get a summary, and every round is saved in
   `.sparring/` (diff, prompt, review JSON, response, reviewer log).

## Adding a reviewer

Each reviewer is one adapter in `plugins/sparring/skills/run/scripts/reviewers/`, as
`<tool>.sh` plus `<tool>.ps1`. The contract is:

```
<adapter> <model|default> <effort> <schema-file> <out-file> <prompt-file>
```

The adapter writes a JSON verdict matching `<schema-file>` to `<out-file>`, sends logs to
stderr, and exits 0. The driver handles the diff, the prompt, the tree check and errors. Add
the tool to `check-prereqs` so `--need <tool>` works.

## Status

- **Codex reviewer:** stable.
- **Antigravity reviewer:** beta. Older `agy` versions printed nothing when not run in a real
  terminal; if a review comes back empty, update `agy`.
- **PowerShell scripts:** written for Windows PowerShell 5.1 and pwsh, but not yet tested on
  Windows. Reports welcome.

## Layout

```
.claude-plugin/marketplace.json          marketplace catalog (this repo)
bin/sparring, bin/sparring.ps1           launchers that set the orchestrator model
tests/run-tests.sh                       smoke tests (fake codex and agy, no network)
plugins/sparring/
  .claude-plugin/plugin.json
  agents/developer.md                    developer subagent (model chosen per call)
  skills/run/SKILL.md                    the orchestration loop
  skills/run/review.schema.json          verdict schema shared by all reviewers
  skills/run/scripts/review.{sh,ps1}     driver: diff, prompt, tree check
  skills/run/scripts/reviewers/          adapters: codex.{sh,ps1}, agy.{sh,ps1}
  skills/check/SKILL.md                  prerequisites check and guided install
  skills/check/scripts/check-prereqs.{sh,ps1}
```

## Develop

```bash
bash tests/run-tests.sh                          # smoke tests
claude plugin validate .                         # check the marketplace and plugin
claude --plugin-dir ./plugins/sparring           # try local changes without installing
```

## License

MIT
