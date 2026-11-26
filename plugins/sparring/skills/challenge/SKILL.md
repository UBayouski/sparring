---
name: challenge
description: Sparring, review only. Have other vendors' CLIs (Codex, Antigravity in beta) check a question, diagnosis, analysis or decision independently, from the evidence alone, and report where they agree with Claude and where they don't. Changes no code.
argument-hint: "[reviewer=tool/model:effort,...] [rounds=1|2] <question or claim to check>"
disable-model-invocation: true
allowed-tools: Bash("${CLAUDE_SKILL_DIR}/../run/scripts/review.sh" challenge *) Bash(${CLAUDE_SKILL_DIR}/../run/scripts/review.sh challenge *) PowerShell(powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/../run/scripts/review.ps1" challenge *) PowerShell(pwsh -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/../run/scripts/review.ps1" challenge *) Bash(git status *) Bash(git diff *) Bash(git log *) Bash(git show *) Read Write Grep Glob
---

# Sparring challenge: independent reviewers check one question

Arguments: $ARGUMENTS

You are the **orchestrator**. Nobody writes code here. You prepare a brief with the evidence,
reviewer CLIs from other vendors answer it independently, and you report where they agree with
your own conclusion and where they don't. Work without asking the user, except for setup
problems.

**Do not change project files.** You write only inside `.sparring/challenge/`.

## 0. Parse the arguments

Read leading `key=value` options; everything else is the question.

| Option | Meaning | Default |
|---|---|---|
| `reviewer=` | Reviewers, comma-separated. Each entry is `tool/model:effort`; `tool/` defaults to `codex/`, model `default` means the tool's own default, `:effort` defaults to `high`. A bare tool name works too: `agy`, `agy+run:medium` | one entry per ready tool: `codex/default:high,agy/default:high` |
| `rounds=` | `2` allows one follow-up round in which the reviewers see your conclusion and reply; `1` stops after the first answers | `2` |

Reviewer tools: `codex` (OpenAI Codex CLI, runs read-only commands in its own sandbox), `agy`
(Google Antigravity CLI, beta: reads files only) and `agy+run` (agy in a disposable copy of
the project, where it may run tests). Two reviewers from different vendors are worth more
than one: their findings and verdicts often differ.

## 1. Pick the script for this platform

Your environment info gives the platform.
- **macOS, Linux, WSL**, or **Windows with the Bash tool** (Git Bash): run
  `"${CLAUDE_SKILL_DIR}/../run/scripts/review.sh" challenge <args>`. Keep the double quotes.
- **Windows without the Bash tool**: run
  `powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_SKILL_DIR}/../run/scripts/review.ps1" challenge <args>`
  (`pwsh` in place of `powershell` if it is installed).

Below, `CHALLENGE <args>` means that command.

**Timeouts.** All reviewers run at once and can take several minutes. Run every
`CHALLENGE ask ...` call with the tool's `timeout` set to `600000`. The script stops them
after 540 seconds. If a reviewer timed out (its line says `timeout`), run it alone once more
with `--timeout 1800 --only <its number>` added right after `ask`, the same reviewer list,
and `run_in_background: true`; wait for the completion notification and read its output.

## 2. Set up

1. Run `CHALLENGE init <tools>`, where `<tools>` is the comma-separated set of tools in
   `reviewer=` (for example `codex,agy`). Without `reviewer=`, run `CHALLENGE init` with no
   tools, and use one `<tool>/default:high` entry for each tool on its `READY_REVIEWERS:`
   line. If only one is ready, use it, and say in the report that only one reviewer was
   available. When answering needs something run (tests at a commit, a reproduction), use
   `agy+run` in place of `agy`; if the user's `reviewer=` has plain `agy` for such a question,
   keep it, and say in the report that `agy+run` could have run it.
   - If it reports missing prerequisites, run the `sparring:check` skill to fix them, then
     run `CHALLENGE init` again. Stop if they are still missing.
   - If it reports no commits, tell the user and stop.
2. Gather the evidence yourself first: read the code, run read-only commands, collect logs.

## 3. Write the brief, without your conclusion

Write `.sparring/challenge/brief.md`. The reviewers start with nothing but this file and the
project, so make it complete and neutral:

- **The question**, phrased openly ("What causes X?", "Is this migration safe to run twice?"),
  not as the answer you expect. If the user asked to test a specific claim, state it as a
  claim to test; the reviewers are told to try to refute it.
- **The evidence**: file paths with line ranges, commands with their output, error messages,
  log excerpts. Save long outputs as extra files in `.sparring/challenge/` and name them.
  The reviewers have no network: Codex's sandbox blocks it and `agy` runs no commands. Save
  anything fetched online (CI logs, pull request or issue data, `gh` output) as files there
  too, and say where each one came from.
- **The code the evidence depends on**: helper functions, callers, config, the tests that
  cover it. A brief that leaves them out costs the reviewers a round of guessing.
- **Scope**: what is out of scope, and what you already ruled out, with how.
- **No conclusion.** Leave out your own answer, your hypothesis and any wording that leans
  toward it. Showing a reviewer your conclusion makes it likely to agree.

Then, **before** running the reviewers, tell the user your own conclusion in two or three
lines ("My answer, before the reviewers see anything: ..."). Do not write it to a file: the
reviewers can read the project, so the conversation is the only place they cannot see it.

## 4. Round 1

Run `CHALLENGE ask 1 <entry> <entry> ...`, one argument per reviewer entry. Every reviewer
runs at once. The output has one `== reviewer N: tool/model:effort, result ==` line per
reviewer, each followed by its answer when the result is `ok`:

```
answer       its own answer to the question
confidence   high | medium | low
findings     [{id, location, claim, evidence}]
unchecked    what it could not verify
```

**Results and exit codes.** Exit 0 means at least one answer is valid; others may say
`failed`, `invalid` or `timeout`. For `failed` or `invalid`, run that one reviewer again once
with `--only N`. Exit 4 means no answer was valid: run the same command once more, then show
the error and stop. Exit 7 means all of them timed out: see Timeouts. Exit 6 means the
working tree changed while they ran, and every answer was rejected: show the user
`git status` and stop.

## 5. Compare, then round 2 if it helps

For each answer, compare it with your conclusion: agrees, disagrees, or agrees for a
different reason. Check every finding that goes against you yourself, in the code. Do not
dismiss it because the other reviewer agreed with you.

Run round 2 only if `rounds=2` and at least one reviewer disagrees, or raised a finding you
think is wrong. Otherwise go to step 6.

Write `.sparring/challenge/reply.md`:

```
# Conclusion
Your conclusion now: the original one, or how a finding changed it.

## Reviewer 1
C1: accepted - what it changes
C2: disputed - why, with the evidence (file and line, command output)

## Reviewer 2
...
```

Then run `CHALLENGE ask 2 <same entries, same order>`. Each reviewer sees its own round 1
answer and the reply, and returns `verdict` (agree | disagree | partly), `comment`, and
`points` with each finding marked `stands` or `withdrawn`. Reviewers without a round 1
answer are skipped. There is no round 3.

## 6. Report

Report briefly:
- The question, and your conclusion (the one you stated before round 1, and the final one if
  it changed).
- **Verdict**: all reviewers agree, they split, or they disagree with you. For each reviewer:
  tool/model, its answer in one line, its confidence, and (after round 2) its verdict.
- **The strongest point against your conclusion**, with its evidence, and whether it stands.
  If there is none, say so.
- Findings that changed your mind, and findings you still dispute, with why.
- What nobody could verify (`unchecked`).
- From `.sparring/challenge/reviews.tsv`: each reviewer call with the model that ran,
  seconds, tokens and result, plus the total time and tokens.
- Where the files are: `.sparring/challenge/` (the challenge before this one is in
  `.sparring/challenge-previous/`).

Do not change code, and do not start the `run` skill. If the outcome calls for a change,
say what you would change and let the user decide.
