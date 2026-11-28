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

There is also a review-only mode, `challenge`: the reviewers check a question, a diagnosis or
a decision independently, from the evidence alone, and no code is changed.

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

```bash
claude plugin marketplace add UBayouski/sparring
claude plugin install sparring@sparring
```

To host your own copy, push this repo to any git host and add it by URL instead, for example
`claude plugin marketplace add https://gitlab.com/<you>/sparring.git` (Bitbucket works the
same way). Private repos work as long as your `git` can clone them (SSH key or credential
helper).

## Use

In a Claude Code session, in your project folder (a git repo with at least one commit):

```
/sparring:check
/sparring:run add rate limiting to the public API
/sparring:challenge why does the nightly export sometimes skip the last batch?
```

`check` reports what is missing, prints the real install commands for your OS, and offers to
install Codex, Antigravity or Claude Code for you. Each install runs only after you approve
it. You sign in to the reviewers yourself (`! codex login`, or run `agy` once). Codex reports
its sign-in status, but `agy` has no such command: `/sparring:check deep` sends `agy` one tiny
test prompt to confirm it is signed in.

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

### Reviewers that run your tests

| Reviewer | Reads the code | Runs tests | How it stays out of your files |
|---|---|---|---|
| `codex` | yes | yes | Codex's own read-only sandbox |
| `agy` | yes | no | `agy`'s plan mode, which is read-only but also blocks every command |
| `agy+run` | yes | yes | It works in a throwaway copy of the project, deleted afterwards |

`agy+run` (for example `tiebreaker=agy+run/default:high`) runs `agy` in its normal mode, where
it can run commands, inside a copy made for each review: a `git clone --shared` of your repo
at HEAD with your uncommitted changes applied. Nothing it changes there reaches your working
tree, branches or git config, and your real tree is still checked after the review.
Know the limits before you use it:

- **Not a sandbox.** `agy`'s `--sandbox` flag did not stop writes outside the folder it runs
  in when we tested `agy` 1.5. Code it runs, including your tests, can touch anything your
  user account can. Use it on projects whose tests you trust.
- **Ignored files are not copied.** `node_modules`, virtualenvs, build output and `.env` files
  stay behind, so tests that need them may not run; the review then says so. Submodules are
  not checked out.
- **Slower.** Each review makes a fresh copy first.
- **Your machine's tools.** It runs what `agy` can start. On Windows, the Microsoft Store
  `python` alias could not be started from `agy` in our tests; a regular Python install avoids
  that.

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

### Checking a question: `challenge`

```
/sparring:challenge reviewer=codex/default:high,agy+run/default:high is it safe to run this migration twice?
```

`challenge` is for days when there is nothing to implement, only something to get right: a
diagnosis, an analysis, a design decision, "is this safe". Nobody changes code.

1. Claude gathers the evidence and writes a brief to `.sparring/challenge/brief.md`: the
   question, phrased openly, plus file and line references, command output, logs and the
   code the evidence depends on. **Claude's own conclusion stays out of the brief.** Claude
   tells you its conclusion before the reviewers start, so you can see it was not adjusted
   afterwards.
2. All reviewers answer at the same time, each on its own: an answer, a confidence, findings
   that each cite evidence, and what it could not verify.
3. Claude compares their answers with its conclusion and checks every finding that goes
   against it. If a reviewer disagrees, or Claude thinks a finding is wrong, there is one
   follow-up round: Claude writes its conclusion and its replies to
   `.sparring/challenge/reply.md`, and each reviewer says whether it agrees and whether each
   of its findings stands or is withdrawn.
4. Claude reports where the reviewers agree, where they split, the strongest point against
   its conclusion, what nobody could verify, and each reviewer's time and tokens.

| Option | Meaning | Default |
|---|---|---|
| `reviewer=` | Reviewers, as `tool/model:effort`; a bare tool name such as `agy` or `agy+run:medium` works too | one `<tool>/default:high` per ready tool, e.g. `codex/default:high,agy/default:high` |
| `rounds=` | `2` allows the follow-up round, `1` stops after the first answers | `2` |
| `at=` | A commit: every reviewer works in a clean throwaway copy of it, without uncommitted changes, notes or later commits. Claude also sets it on its own when the question is about a past commit or the working tree could lead the reviewers | none: reviewers read the live project |

Two reviewers from different vendors are worth more than one: their findings often differ,
and in follow-up rounds one may withdraw a point while the other keeps it, with evidence.
Use `agy+run` when an answer needs running code, such as tests or a quick probe script.
The reviewers have no network, so Claude saves anything it fetched online (CI logs, pull
request data) into the brief's folder for them. Two reviewers at `high` cost several times
one: for a question one log line already settles, `reviewer=codex/default:medium` is enough,
and the challenge is best kept for decisions that are open or costly to get wrong. Files are
in `.sparring/challenge/`, and the challenge before that in `.sparring/challenge-previous/`.
A challenge never touches the files of a `run`.

## What happens in a run

1. `init` checks the prerequisites for the reviewers you chose, records the base commit in
   `.sparring/base`, saves the round limit and tiebreaker setting in `.sparring/config`, and
   warns about uncommitted changes. `.sparring/` ignores itself, so your `.gitignore` is not
   touched. The files of the run before are moved to `.sparring/previous/`.
2. The developer subagent implements the task and runs the tests. The same developer is
   continued for every round while its model stays the same.
3. The reviewer reads the task and the diff and returns JSON that matches
   `review.schema.json`: a verdict, plus issues marked `blocking` or `nit`, with stable ids.
   - Codex runs in its **read-only sandbox**.
   - Antigravity runs in **plan mode with its terminal sandbox on**, told not to run
     commands, or, as `agy+run`, in a throwaway copy of the project (see above).
   - For both, the driver fingerprints the working tree before and after, and **rejects the
     review if any file changed**. Just before the reviewer runs, it also saves the tree as
     a git tree object (no commit, no ref, the index untouched). `review.sh restore <round>`
     undoes whatever the reviewer did: edits, deletions and new files. Files the developer
     changed come back byte for byte. Files nobody had touched come back as `git checkout`
     writes them.
   - The driver checks the verdict against the schema. An `approve` that still lists
     blocking issues counts as `changes_requested`.
   - A reviewer that runs past 540 seconds is stopped (exit 7), so a slow review never hits
     Claude Code's 10-minute tool limit unnoticed. The orchestrator retries it once in the
     background with a longer limit. Set `SPARRING_REVIEW_TIMEOUT` to change the default.
4. The developer fixes each blocking issue or rebuts it with a technical reason. The reviewer
   then re-reviews with the rebuttals in hand and withdraws issues it is convinced on.
5. Deadlock (round limit reached, or issues disputed): one escalation round on the strongest
   models. Then, if you set one, the tiebreaker judges each disputed issue and two of three
   decide. Anything still open comes to you as one question per issue, with every position.
6. Nothing is committed or pushed. You get a summary, and every round is saved in
   `.sparring/` (diff, prompt, review JSON, response, reviewer log). `.sparring/reviews.tsv`
   has one line per reviewer call, retries and failures included: the model that actually
   ran (when the CLI reports it), effort, seconds, tokens and the result.

Steps 3–5 are driven by `review.sh status` (see below), not by the orchestrator's memory.

## Loop bookkeeping: `status`

The loop has a lot of state: which round this is, which issues are open, which ones the
developer rebutted and the reviewer kept anyway, when to escalate a tier, when the deadlock
starts, what the tiebreaker closed. Asking the orchestrator model to track all of that from
prose instructions invites drift: a skipped step, a wrong round number, a tiebreak that
shouldn't run. So the script does it.

`review.sh status` (or `review.ps1 status`) reads the round files in `.sparring/` and prints
where the loop stands and what to do next. It never changes anything, so you can run it
yourself at any point of a run, or after one:

```
$ plugins/sparring/skills/run/scripts/review.sh status
stage: tiebreak
next: fix-after-tiebreak 3
tier: deep
round: 3
limit: 2
open: R2 R3
disputed: R2
tiebreak_kept: R3
closed: R2
fix: R3
note: fix each kept issue, then add 'ID: FIXED after tiebreak, ...' to .sparring/round-3.response.md
```

The orchestrator runs it after every review and every response, and does what `next:` says:

| `next:` | Meaning |
|---|---|
| `review N` | run review N, passing `response_file:` |
| `respond N` | the developer fixes or rebuts review N's blocking issues |
| `tiebreak N` | the tiebreaker judges review N's open issues |
| `fix-after-tiebreak N` | the developer fixes the issues the tiebreaker kept (`fix:`) |
| `ask-user` | you decide the issues in `open:` |
| `finish` | done; `result:` is `approved`, `approved-after-tiebreak` or `user-decided` |

`tier:` is `same`, `up` (the last round made no progress, so move up a tier) or `deep`.

The orchestrator still makes the judgment calls: picking the tier, briefing the developer,
deciding that a reviewer's new id is an old issue in other words. It records that last one
in the response file as `R7: SAME AS R2`, and `status` then treats them as one issue.
Response files use one line per issue, starting with the id:

```
R1: FIXED - what changed
R2: REBUTTED - why, with the evidence
R7: SAME AS R2
R4: FIXED after tiebreak - what changed
```

The rules it applies:
- A round is review N, then response N, for N up to the limit (`rounds=`).
- An issue is **disputed** when the developer rebutted it and the next review kept it. If
  every open issue is disputed, the deadlock starts early.
- Deadlock: an escalation round on deep models, then the tiebreaker if one is set and
  something is still rebutted. Issues the tiebreaker keeps must be fixed; issues it drops are
  closed for good, even if raised again. Then a final review, then you, then one last review
  only if your decisions changed code.

`status` needs jq, python3 or node in bash. On Windows without them, `review.sh status`
hands over to `review.ps1 status`, which needs nothing extra.

## Adding a reviewer

Each reviewer is one adapter in `plugins/sparring/skills/run/scripts/reviewers/`, as
`<tool>.sh` plus `<tool>.ps1`. The contract is:

```
<adapter> <model|default> <effort> <schema-file> <out-file> <prompt-file>
<adapter> --meta <log-file>
```

The adapter writes JSON matching `<schema-file>` to `<out-file>` (a review verdict, or a
challenge answer or reply; the adapter does not need to know which), sends logs to stderr,
and exits 0. The driver handles the diff, the prompt, the tree check and errors. With
`--meta`, it prints what its CLI reported in that log as `model=`, `tokens=` and `attempts=`
lines, any of which may be missing; the driver records them in `reviews.tsv`. When
`SPARRING_ALLOW_COMMANDS=1` is set, the driver has started it in a throwaway copy for
`<tool>+run`, so it may let its CLI run commands. Add the tool to `check-prereqs` so
`--need <tool>` works.

## Status

- **Codex reviewer:** stable.
- **Antigravity reviewer:** beta. It runs in `agy`'s plan mode, the only mode that keeps it
  read-only, and in `agy` 1.5 plan mode denies every shell command. So an `agy` review reads
  the diff and files but cannot run your tests, and its summary says what it could not
  verify. If it asks for a command anyway, it is retried once without commands. Codex reviews
  can run tests in its read-only sandbox, and `agy+run` runs them in a throwaway copy (see
  [Reviewers that run your tests](#reviewers-that-run-your-tests)). Older `agy` versions
  printed nothing when not run in a real terminal; if a review comes back empty, update `agy`.
- **Windows:** both drivers have reviewed real changes on Windows 11 with `agy` 1.5.16
  (plain and `+run`, from Git Bash and Windows PowerShell 5.1) and Codex 0.171.0 (from Git
  Bash). A two-round `challenge` with Codex and `agy+run` has run from both drivers. The smoke
  tests (`tests/run-tests.{sh,ps1}`) use fake reviewers and cover non-ASCII file names and
  content. Reports from macOS and Linux welcome.
  On Windows, Codex's sandbox can stop a test runner from starting child processes
  (`spawn EPERM`, seen with `node --test`). In that run Codex worked around it by turning
  the test runner's process isolation off, and said so in its answer. If your tests can only run
  with child processes, use `agy+run` for questions that need a test run.

## Layout

```
.claude-plugin/marketplace.json          marketplace catalog (this repo)
bin/sparring, bin/sparring.ps1           launchers that set the orchestrator model
tests/run-tests.{sh,ps1}                 smoke tests (fake codex and agy, no network)
plugins/sparring/
  .claude-plugin/plugin.json
  agents/developer.md                    developer subagent (model chosen per call)
  skills/run/SKILL.md                    the orchestration loop
  skills/run/review.schema.json          verdict schema shared by all reviewers
  skills/run/scripts/review.{sh,ps1}     driver: diff, prompt, tree check, loop status, challenge
  skills/run/scripts/reviewers/          adapters: codex.{sh,ps1}, agy.{sh,ps1}
  skills/challenge/SKILL.md              review-only mode: independent answers to one question
  skills/challenge/*.schema.json         answer (round 1) and reply (round 2) schemas
  skills/check/SKILL.md                  prerequisites check and guided install
  skills/check/scripts/check-prereqs.{sh,ps1}
```

## Develop

```bash
bash tests/run-tests.sh                          # smoke tests (bash scripts)
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1   # PowerShell scripts
claude plugin validate .                         # check the marketplace and plugin
claude --plugin-dir ./plugins/sparring           # try local changes without installing
```

## License

MIT
