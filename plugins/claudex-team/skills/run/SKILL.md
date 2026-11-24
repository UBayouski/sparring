---
name: run
description: Claudex team. Implement a coding task with Claude as developer and Codex CLI as reviewer, looping on its own until Codex approves. Asks the user only when the two cannot agree.
argument-hint: "[orchestrator=MODEL] [dev=M1,M2,M3] [reviewer=M[:effort],...] [rounds=N] <task>"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/codex-review.sh *) Bash(git status *) Bash(git diff *) Bash(git log *) Read Write Edit Grep Glob
---

# Claudex team: developer / reviewer loop

Arguments: $ARGUMENTS

You are the **orchestrator**. The `developer` subagent writes the code, and Codex reviews it
through this skill's review script. Work without asking the user, except in the situations
named below (setup problems and deadlock).

## 0. Parse the arguments

Read leading `key=value` options; everything else is the task.

| Option | Meaning | Default |
|---|---|---|
| `orchestrator=` | Model that runs this loop (you) | the current session model |
| `dev=` | Allowed developer models, comma-separated, weakest → strongest | `haiku,sonnet,opus` |
| `reviewer=` | Allowed Codex models, weakest → strongest, each `model` or `model:effort`. `default` means Codex's configured default model | `default:low,default:medium,default:high` |
| `rounds=` | Review rounds before deadlock handling | `3` |

**Use only models from these lists**, including in escalation. Never pick a model outside them.

**Orchestrator.** If `orchestrator=` is set and you are not that model, you cannot switch
yourself. Tell the user in one short message to either run `/model <MODEL>` and send the same
command again, or start a session with the launcher (`claudex --orchestrator <MODEL> "<task>"`,
or `claudex.ps1` on Windows). Then stop.

**Tiers** map onto each list by position (n = list length):
- fast = first entry
- standard = entry number ceil(n/2), so the middle one of 3, or the first of 2
- deep = last entry

For a reviewer entry without `:effort`, use effort `low` for fast, `medium` for standard and
`high` for deep.

## 1. Pick the script for this platform

Your environment info gives the platform.
- **macOS, Linux, WSL**, or **Windows with the Bash tool** (Git Bash): run
  `${CLAUDE_SKILL_DIR}/scripts/codex-review.sh <args>`
- **Windows without the Bash tool** (PowerShell tool only): run
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/codex-review.ps1" <args>`
  (use `pwsh` in place of `powershell` if it is installed). The arguments are the same.

Below, `REVIEW <args>` means the command for this platform.

## 2. Set up

1. Run `REVIEW init`. It checks the prerequisites first.
   - If it reports missing prerequisites, run the `claudex-team:check` skill to fix them,
     then run `REVIEW init` again. Stop if they are still missing.
   - If it reports no commits, tell the user and stop.
   - If it warns about uncommitted changes, ask the user once with AskUserQuestion:
     include them in the review, or stop so they can commit or stash first.
2. Write the task, with any acceptance criteria you can infer, to `.review/task.md`.

## 3. Pick a tier

| Tier | When |
|---|---|
| fast | Typo, small fix, config, test tweak, one file |
| standard | Normal feature or bug fix |
| deep | Architecture, concurrency, security, data migrations, large refactor |

When unsure, pick standard. The tier picks both the developer model and the reviewer model.

## 4. Implement

Start the `developer` subagent (it may be listed as `claudex-team:developer`), and **always set
the Agent tool's model parameter** to the developer model for the current tier. Give it the
task, the relevant context you know, and this instruction: implement it, run the relevant
tests, and report the files changed and the test results.

## 5. Review loop

For round = 1, 2, … up to the round limit:

1. Run `REVIEW review <round> <codex-model> <effort> [response-file]`, with the reviewer model
   and effort for the current tier. Pass the previous round's response file, if there is
   one. The script prints JSON: `verdict`, `summary`, `issues[]` (id, severity, location,
   comment, suggestion), `withdrawn[]`.
2. If `verdict` is `approve`, go to step 7.
3. Otherwise send the blocking issues, as JSON, to a developer subagent on the current tier's
   model. For each issue, it must either **fix** it, or **rebut** it with a concrete
   technical reason (not preference). It may also apply nits that are cheap and clearly
   right.
4. Write its answer to `.review/round-<round>.response.md`, one section per issue id:
   `R1: FIXED, what changed` or `R1: REBUTTED, why`.
5. Track disputes. An issue is **disputed** when the developer has rebutted it and Codex has
   kept it open after reading that rebuttal.

When a round makes no progress (the same blocking ids are open and none were fixed), move up
one tier for the next round, for both the developer and the reviewer, unless you are already
on deep.

## 6. Deadlock

When the round limit is reached with blocking issues still open, or only disputed issues
remain:

1. If you have not run one yet, run one **escalation round** on the deep tier. The developer
   re-examines only the open issues, with fresh eyes on both sides' arguments, and Codex then
   reviews again. If that resolves everything, go to step 7.
2. If issues are still open, ask the user with AskUserQuestion, one question per issue
   (up to 4; batch more if needed). In each question, state Codex's position and the
   developer's position in one or two sentences each. Options: "Apply Codex's fix",
   "Keep developer's version", and a third option where there is a sensible compromise.
3. Apply the user's decisions with the developer subagent. Run one last review only if the
   user's choice introduced new code. Then go to step 7 whatever that review says, and
   report anything it raised.

## 7. Finish

Do not commit or push unless the task asked for it. Report briefly:
- Result: approved, approved after user decisions, or stopped (and why)
- Orchestrator model, and each round's developer model and reviewer model/effort
- Files changed and test status
- Nits left unaddressed (one line each)
- Any user decisions, and where the round files are (`.review/`)
