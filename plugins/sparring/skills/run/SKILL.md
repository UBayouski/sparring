---
name: run
description: Sparring. Implement a coding task with Claude as developer and another vendor's CLI (Codex, or Antigravity in beta) as reviewer, looping on its own until the reviewer approves. Asks the user only when they cannot agree.
argument-hint: "[orchestrator=MODEL] [dev=M1,M2,M3] [reviewer=tool/model:effort,...] [tiebreaker=tool/model:effort] [rounds=N] <task>"
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_SKILL_DIR}/scripts/review.sh" *) Bash(${CLAUDE_SKILL_DIR}/scripts/review.sh *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/review.ps1" *) PowerShell(pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/review.ps1" *) Bash(git status *) Bash(git diff *) Bash(git log *) Read Write Edit Grep Glob
---

# Sparring: developer / reviewer loop

Arguments: $ARGUMENTS

You are the **orchestrator**. The `developer` subagent writes the code. A reviewer CLI from
another vendor reviews it through this skill's review script. Work without asking the user,
except in the situations named below (setup problems and deadlock).

## 0. Parse the arguments

Read leading `key=value` options; everything else is the task.

| Option | Meaning | Default |
|---|---|---|
| `orchestrator=` | Model that runs this loop (you) | the current session model |
| `dev=` | Allowed developer models, comma-separated, weakest → strongest | `haiku,sonnet,opus` |
| `reviewer=` | Allowed reviewers, weakest → strongest. Each entry is `tool/model:effort`; `tool/` defaults to `codex/`, `:effort` is optional, and model `default` means the tool's own default | `codex/default:low,codex/default:medium,codex/default:high` |
| `tiebreaker=` | Optional third reviewer used on deadlock, same format, ideally a different tool from the reviewers, e.g. `agy/default:high` | none |
| `rounds=` | Review rounds before deadlock handling | `3` |

Reviewer tools: `codex` (OpenAI Codex CLI) and `agy` (Google Antigravity CLI, beta).
**Use only models and tools from these lists**, including in escalation.

**Orchestrator.** If `orchestrator=` is set and you are not that model, you cannot switch
yourself. Tell the user in one short message to either run `/model <MODEL>` and send the same
command again, or start a session with the launcher (`sparring --orchestrator <MODEL> "<task>"`,
or `sparring.ps1` on Windows). Then stop.

**Tiers** map onto the `dev` and `reviewer` lists by position (n = list length):
- fast = first entry
- standard = entry number ceil(n/2), so the middle one of 3, or the first of 2
- deep = last entry

For a reviewer entry without `:effort`, use `low` for fast, `medium` for standard and `high`
for deep.

## 1. Pick the script for this platform

Your environment info gives the platform.
- **macOS, Linux, WSL**, or **Windows with the Bash tool** (Git Bash): run
  `"${CLAUDE_SKILL_DIR}/scripts/review.sh" <args>`. Keep the double quotes: the path can
  contain spaces, or backslashes on Windows, and unquoted bash would break it.
- **Windows without the Bash tool** (PowerShell tool only): run
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/scripts/review.ps1" <args>`
  (use `pwsh` in place of `powershell` if it is installed). The arguments are the same.

Below, `REVIEW <args>` means the command for this platform.

**Timeouts.** Reviews can take several minutes. Run every `REVIEW review ...` call with the
Bash or PowerShell tool's `timeout` set to `600000` (10 minutes, the maximum). The script
stops the reviewer itself after 540 seconds and exits 7, so the tool never cuts it off
silently. On exit 7, run the same command once more with `--timeout 1800` added right after
`review` and with `run_in_background: true`, then wait for its completion notification and
read its output. If it times out again, tell the user and stop.

## 2. Set up

1. Run `REVIEW init <tools> --rounds <rounds>`, adding `--tiebreaker` when `tiebreaker=` is
   set. `<tools>` is the comma-separated set of reviewer tools in `reviewer=` and
   `tiebreaker=` (for example `codex` or `codex,agy`). It checks those are ready, and saves
   the round limit and the tiebreaker setting for `REVIEW status`.
   - If it reports missing prerequisites, run the `sparring:check` skill to fix them, then
     run the same `REVIEW init` again. Stop if they are still missing.
   - If it reports no commits, tell the user and stop.
   - If it warns about uncommitted changes, ask the user once with AskUserQuestion:
     include them in the review, or stop so they can commit or stash first.
2. Write the task, with any acceptance criteria you can infer, to `.sparring/task.md`.

## 3. Pick a tier

| Tier | When |
|---|---|
| fast | Typo, small fix, config, test tweak, one file |
| standard | Normal feature or bug fix |
| deep | Architecture, concurrency, security, data migrations, large refactor |

When unsure, pick standard. The tier picks both the developer model and the reviewer entry.

## 4. Implement

Start the `developer` subagent (it may be listed as `sparring:developer`), and **always set
the Agent tool's model parameter** to the developer model for the current tier. Give it the
task, the relevant context you know, and this instruction: implement it, run the relevant
tests, and report the files changed and the test results.

**Keep that developer.** Note the agent's id. For every later response, continue the same
agent with SendMessage, so it keeps what it learned about the code and its earlier answers.
Start a new developer only when the tier's developer model changes, or SendMessage is not
available. Then brief it fully: the task, the files changed so far, and every
`.sparring/round-*.response.md` written so far.

## 5. Review loop, driven by `REVIEW status`

You make the judgment calls. The script keeps the books: round numbers, which issues are
open, disputed or closed, when to escalate, and which step comes next. **After the
implementation, and after every review and every response file, run `REVIEW status`** and
do what its `next:` line says. It only reads `.sparring/`, so you can run it at any time.

```
stage: normal | escalation | tiebreak | final | user | done
next: review N | respond N | tiebreak N | fix-after-tiebreak N | ask-user | finish
response_file: .sparring/round-<N-1>.response.md   (pass it to the review)
tier: same | up | deep
result: approved | approved-after-tiebreak | user-decided   (with next: finish)
open: R1 R3        disputed: R3        closed: R2        fix: R4        note: ...
```

**Tier.** `same`: keep the current tier. `up`: the last round made no progress (the same
blocking issues are still open), so move up one tier for both the developer and the
reviewer, unless you are on deep. `deep`: use the deep tier for both.

| `next:` | What you do |
|---|---|
| `review N` | Run `REVIEW review N <tool> <model> <effort> [response_file]` with the tier's reviewer entry. In stage `user`, run it only if the user's decisions changed code; otherwise go to step 7. |
| `respond N` | Send review N's blocking issues, as JSON, to the developer. For each one it must **fix** it, or **rebut** it with a concrete technical reason (not preference). It may also apply nits that are cheap and clearly right. In stage `escalation`, tell it to re-examine only the open issues, with fresh eyes on both sides' arguments. Write its answer to `.sparring/round-N.response.md`. |
| `tiebreak N` | Run `REVIEW review --tiebreak N <tool> <model> <effort> .sparring/round-N.response.md` with the `tiebreaker=` entry. It judges each open issue on the merits. |
| `fix-after-tiebreak N` | The tiebreaker kept the issues in `fix:`. The developer must fix them, with no second rebuttal. Append one line per issue to `round-N.response.md`: `R4: FIXED after tiebreak, what changed`. Issues in `closed:` stay closed even if a later review raises them again. |
| `ask-user` | Ask with AskUserQuestion, one question per issue in `open:` (up to 4 per call; make more calls if needed). State the reviewer's position and the developer's (and the tiebreaker's, if any) in one or two sentences each. Options: "Apply the reviewer's fix", "Keep developer's version", and a compromise where one makes sense. Apply the decisions with the developer, then write them to `.sparring/round-N.response.md`, one line per issue (`R5: user chose the reviewer's fix`). |
| `finish` | Go to step 7, reporting `result:`. |

**Response files** are read by `status`, so start each line with the issue id and one of
these words:

```
R1: FIXED - what changed
R2: REBUTTED - why, with the evidence
R7: SAME AS R2
R4: FIXED after tiebreak - what changed
```

**Matching issues across rounds.** Every reviewer run starts fresh, and a tier change also
changes the model, so ids can drift. If a review raises an issue under a new id but its
location and problem match an earlier issue, add a line `R7: SAME AS R2` to that round's
response file, then answer it as R2. Status then counts it as the same issue for disputes,
progress and closing. Deciding that two issues are the same is your call; the script cannot
make it.

**Errors from `REVIEW review`:**
- Exit 6 means the reviewer changed files, and the review is rejected. The script saved the
  tree just before the reviewer ran. Show the user which files changed (`git status`), then
  ask once with AskUserQuestion: "Undo the reviewer's changes and continue" (run
  `REVIEW restore N`, or `REVIEW restore --tiebreak N` for a tiebreak, then run the same
  review again once) or "Stop so I can inspect them". If the restore fails, or the reviewer
  changes files again, stop.
- Exit 4 means the reviewer failed or gave an invalid verdict. Run the same command once more;
  if it fails again, show the error and stop.
- If `REVIEW status` fails, show its error and stop.

## 6. The rules `status` applies

You don't need to apply these yourself. They're here so you can explain a decision to the
user.

- Rounds N = 1, 2, … run up to the limit L (`rounds=`). A round is review N, then response N.
- An open issue is **disputed** when the developer rebutted it in response N-1 and review N
  kept it anyway. When every open issue is disputed, the deadlock starts early, at round N.
- **Deadlock:** one escalation round E = L+1 on deep. If response E still rebuts something and
  a tiebreaker is set, the tiebreaker judges review E. Issues it keeps must be fixed; issues
  it drops are closed. Then a final review F = E+1. Whatever is still open goes to the user,
  and one last review F+1 follows only if the user's decisions changed code.
- Any review with no open blocking issues (closed ones don't count) ends the loop as approved.

## 7. Finish

Do not commit or push unless the task asked for it. Report briefly:
- Result: approved, approved after tiebreak or user decisions, or stopped (and why)
- Orchestrator model, and each round's developer model and reviewer tool/model/effort
- Files changed and test status
- Nits left unaddressed (one line each)
- Any tiebreaker or user decisions, and where the round files are (`.sparring/`; the run
  before this one is in `.sparring/previous/`)
