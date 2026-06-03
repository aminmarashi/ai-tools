# ai-tools

Small command-line utilities for working with AI coding agents.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/ai-tools/main/install.sh | bash
```

This places each tool in `~/bin` and ensures `~/bin` is on your `PATH`
(by appending a guarded block to your shell rc — `~/.zshrc`, `~/.bashrc`,
`~/.bash_profile`, `~/.profile`, or `~/.config/fish/config.fish` depending
on `$SHELL`). Open a new shell afterwards, or `source` the file shown.

Override the install location with `AI_TOOLS_DEST=/some/dir`, or pin a
ref with `AI_TOOLS_REF=<branch-or-tag>`.

## Uninstall

```bash
ai-tools-uninstall
```

Or, if that script is gone:

```bash
curl -fsSL https://raw.githubusercontent.com/aminmarashi/ai-tools/main/uninstall.sh | bash
```

## Tools

### `tai`

Tail an AI agent log and narrate what's happening, one short sentence at
a time, using a fast model.

```bash
tai /path/to/agent.log
tai --mute /path/to/agent.log   # skip TTS even if tts-read is installed
```

Currently understands Claude Code stream-json logs (assistant text,
tool calls, tool results). Buffers events and flushes after a short
idle window, then asks `claude -p --model claude-haiku-4-5` to write a
single sentence describing what the agent is doing right now.

While events are buffered or the model is being called, a small
braille spinner is drawn on stderr (`buffering new log events…` →
`narrating (N new)`) so you can tell the tool is alive between
narration lines. The spinner is suppressed when stderr isn't a TTY.

If [`tts-read`](https://github.com/aminmarashi/tts-read) is on `PATH`,
each narration line is also piped to it (`echo "..." | tts-read`) so
you hear the description aloud. Pass `--mute` to disable.

Requirements: `jq`, the `claude` CLI on `PATH`. Optional: `tts-read`.

If `claude -p` doesn't return within `TAI_TIMEOUT` seconds (default
`45`), the call is killed and a warning is logged; the events stay in
the rolling context window so the next batch can still describe them.
The spinner shows elapsed seconds (`narrating (3 new) [12s]`) so a
slow model call doesn't look like a hang.

Env: `TAI_MODEL`, `TAI_IDLE`, `TAI_MAX_BUF`, `TAI_TIMEOUT`.

### `plan2pdf`

Convert an implementation plan into a self-contained PDF sized for a
Kindle Scribe (or comparable e-ink reader). The plan is rewritten by
`claude -p --model haiku --effort low` so it reads well **away from
the codebase**: file paths, line numbers, and copy-pasted hunks are
stripped and replaced with prose informed by what the code actually
does.

The rewrite is also tuned to be **text-to-speech friendly** — flowing
prose rather than telegraphic bullets, English where a code identifier
would otherwise live, transition sentences between phases, no
arrow/slash punctuation, and Mermaid diagrams only as visual
supplements (TTS skips them, so the surrounding prose stands alone).
The result reads aloud like a chapter of a technical audiobook.

```bash
plan2pdf plan.md                       # -> plan.pdf
plan2pdf plan.md -o ~/kindle/plan.pdf
plan2pdf plan.md -o pdfs/              # -> pdfs/plan.pdf (dir target)
cat plan.md | plan2pdf - -o plan.pdf   # read plan from stdin
plan2pdf plan.md -k                    # also keep the rewritten .md
```

Run `plan2pdf` from inside the repo whose code the plan refers to.
Claude inherits read access to the current directory (limited to
`Read`, `Grep`, `Glob`) and runs with claude's auto permission mode,
so it decides on its own which files to inspect.

Mermaid diagrams in the plan (or in claude's rewrite) are rendered as
images in the PDF by `mermaid.js`, which headless Chrome loads from
jsDelivr at print time. An internet connection is required (`claude`
needs one too).

Requirements: `claude`, `pandoc`, `python3`, and a Chromium-based
browser — Google Chrome / Chromium / Brave / Microsoft Edge.

Env: `PLAN2PDF_MODEL`, `PLAN2PDF_EFFORT`, `PLAN2PDF_KEEP_MD`,
`PLAN2PDF_PAGE`, `PLAN2PDF_FONT`, `PLAN2PDF_FONTSIZE`,
`PLAN2PDF_TIMEOUT`, `PLAN2PDF_CHROME_TIMEOUT`,
`PLAN2PDF_ALLOWED_TOOLS`, `PLAN2PDF_DEBUG`.

### `diff2plan`

The inverse of `plan2pdf`: turn an existing `git diff` into the
Markdown implementation plan that would have produced it. Useful for
documenting a change after the fact, recovering a plan for a stash or
WIP branch, or feeding a clean prose description of a diff into a
follow-up conversation.

Arguments after `diff2plan`'s own options are forwarded verbatim to
`git diff`, so anything `git diff` accepts works here too.

```bash
diff2plan                          # working tree diff -> stdout
diff2plan --staged                 # staged diff -> stdout
diff2plan HEAD~3                   # diff vs 3 commits ago -> stdout
diff2plan main..feature            # range diff -> stdout
diff2plan -o plan.md HEAD~3        # write to plan.md
diff2plan HEAD~5 -- src/           # path filter forwarded to git
```

`diff2plan` runs `git diff <YOUR-ARGS>` against the current working
tree, then pipes the unified diff through `claude -p` with read access
to the local code (limited to `Read`, `Grep`, `Glob`) and claude's
auto permission mode. Claude looks up the affected files so the plan
names things by their actual roles, groups hunks by engineering intent
(not file order), and keeps file paths and function names in the
output — this is a working plan, not an offline-reading rewrite.

Run `diff2plan` from inside the working tree whose changes the diff
describes. The default output is stdout; pass `-o plan.md` (or `-o
some/dir/`) to write to a file. Status messages and the live tool-call
log are written to stderr, so `diff2plan ... > plan.md` keeps the
plan clean.

Requirements: `claude`, `git`, `python3`.

Env: `DIFF2PLAN_MODEL`, `DIFF2PLAN_EFFORT`, `DIFF2PLAN_TIMEOUT`,
`DIFF2PLAN_ALLOWED_TOOLS`, `DIFF2PLAN_DEBUG`.

### `review`

Generate a code-review prompt for the current branch and hand it to
`claude`, which inspects the diff itself and reports prioritized,
actionable findings. It follows the same house harness as `diff2plan`
and `plan2pdf`: `claude -p` with stream-json output, one stderr line per
tool call behind a braille spinner, a timeout wrapper, and `REVIEW_*`
environment overrides. GitHub is the forge — pull-request checkouts and
`--comment` posting go through the `gh` CLI.

```bash
review                         # review current branch vs main -> stdout
review --base feat/parent      # diff against a parent branch (stacked PRs)
review 123                     # check out PR #123, then review it
review https://github.com/o/r/pull/123
review feature/child           # fetch that remote branch, switch, review
review --comment               # review the branch's PR, post inline findings
review --print                 # print the review prompt without invoking claude
```

Run `review` from inside the repository whose changes you want
reviewed. By default it compares the current branch against `main`
using the merge base and writes findings to stdout. A positional
argument selects what to review: a remote branch name is fetched and
checked out to match the remote exactly, while a PR number (`123` /
`#123`) or PR URL is checked out with `gh pr checkout`. Both require a
clean working tree.

`claude` runs with read access plus `Bash` (auto permission mode) so it
can run `git diff <merge-base>` and inspect the surrounding code before
judging each hunk. With `--comment`, it posts substantive findings back
to the target pull request as inline review comments via `gh api`
(`gh` fills `{owner}/{repo}` from the current repo), falling back to a
general PR comment when a finding does not map to a changed line; the
prioritized findings are still printed to stdout afterward.

Requirements: `claude`, `git`. Pull-request features and `--comment`
also need `gh` (run `gh auth login` once). `python3` is used to parse
claude's stream-json, same as `diff2plan`.

Env: `REVIEW_MODEL` (default `sonnet`), `REVIEW_EFFORT` (default
`high`), `REVIEW_TIMEOUT` (default `1800`), `REVIEW_BASE` (default
`main`), `REVIEW_ALLOWED_TOOLS` (default `Read Grep Glob Bash`),
`REVIEW_DEBUG`.

### `cerebro`

Meta-harness for the plan → execute → review loop. Typing `cerebro` in
a shell drops you into a native interactive `claude` session configured
as an orchestrator: a restricted tool surface (Read, Grep, Glob, and
Bash limited to `cerebro:*`) plus a system prompt that catalogues a
small set of `cerebro <subcommand>` tools. The orchestrator spawns
short-lived sub-agents on your behalf — `claude -p` for planning and
code work, `codex exec` for review — while you stay in the chat.

```bash
cerebro                       # mint a new session, drop into the chat
cerebro --resume <id>         # resume a specific session
cerebro --resume              # claude's session picker
cerebro list                  # list sessions, newest first
```

You talk only to the orchestrator. It decides when to call `cerebro
plan`, `cerebro execute`, `cerebro review`, `cerebro apply-review`,
`cerebro doc-write`, `cerebro recall`, `cerebro status`, or the
preference-learning subcommands (`cerebro learnings`, `learn-note`,
`learn-set`) based on the conversation. A typical feature loop: describe the change → the
orchestrator drafts a plan and tells you where it landed → you read
the plan and say "go" → orchestrator executes it on a feature branch,
pushes, opens a PR via `gh` → orchestrator runs codex against the
diff, summarises the findings, and applies the ones that matter → loop
until codex is quiet → optionally `doc-write` at the end.

**AGENTS.md bootstrap.** The first time `cerebro execute` runs against
a repo that lacks `AGENTS.md` / `CLAUDE.md` at the root, it adds them
from the templates at `~/.cerebro/templates/` as a separate first
commit on the PR. The defaults set Conventional Commits with ≤ 80-char
subjects, Angular-style branch prefixes (`feat/`, `fix/`, `chore/`,
`refactor/`, …), no commits without an explicit ask, and no DB/infra
changes without an explicit ask. Edit
`~/.cerebro/templates/AGENTS.md` to customize what new repos get;
cerebro never overwrites an existing AGENTS.md in a user repo.

**Scope-filtered review forwarding.** When summarising a `cerebro
review`, the orchestrator forwards only findings clearly within the
plan's scope to `cerebro apply-review`. Out-of-scope improvements
(unrelated refactors, nits in untouched files) are named to you but
not acted on; ambiguous findings prompt a clarifying question first.
`cerebro apply-review` with no findings path (and no `--prompt`)
defaults to the last review's findings file for the current
repo+branch; an explicit path that doesn't exist is rejected with the
correct last-review path named.

**Learned preferences.** cerebro builds a small, durable record of how
you like work done, so future sessions start already tuned to you. When
you reveal a general preference — directly ("always keep diffs small")
or indirectly (you keep asking it to simplify, or reject
over-engineered solutions) — the orchestrator logs a signal with
`cerebro learn-note` into a global `pending-learnings.md`. Once the
evidence is clear (one explicit directive, or the same signal seen on
two or more occasions) it consolidates the confirmed preferences into a
small `learnings.md` via `cerebro learn-set`; when a signal is
ambiguous it asks you first. `learnings.md` is injected into the
orchestrator's system prompt on every launch/resume, capped (~1600
chars) so it stays system-message-sized. Both files are global under
`~/.cerebro/` and persist across sessions and repos; `cerebro
learnings` prints the active set plus a pending-signal count.

**Incremental re-reviews.** After an `apply-review`, the next
`cerebro review` defaults to diffing against the SHA that was HEAD at
the time of the previous review, not `main`. Codex only re-evaluates
the new changes, so the review loop stays cheap. State lives under
`sessions/<id>/review-state/`; pass `--base` to override and force a
wider review.

**Interactive-only.** `cerebro` refuses to run under a non-terminal
parent (pipes, scripts, cron). Sub-agents are exempt via the
`CEREBRO_SESSION_ID` environment variable that the orchestrator inherits.

**Concurrency.** cerebro has no concurrency control. It will not stop
you from running two mutating subcommands (`execute`, `apply-review`,
`doc-write`) against the same repo at the same time, whether within a
single session or across sessions — sequence your own mutating work.

**No chat/PR/repo-specific flags are ever passed to `claude` or
`codex`.** The orchestrator addresses repos by absolute path as the
first positional argument to its sub-agent tools, and `cerebro` sets
each spawned child's `cwd` to that path. The orchestrator itself only
ever runs in `$CEREBRO_HOME`.

Session state lives under `$CEREBRO_HOME` (default `~/.cerebro/`):

```
~/.cerebro/
  hook.sh                            # UserPromptSubmit hook, routes by session id
  system-prompt.md                   # orchestrator system prompt
  learnings.md                       # confirmed user preferences (injected into the prompt)
  pending-learnings.md               # append-only journal of preference signals
  .claude/settings.local.json        # registers the hook
  templates/
    AGENTS.md                        # default dropped into repos that lack one
    CLAUDE.md                        # default stub that links to AGENTS.md
  sessions/<claude-session-uuid>/
    metadata.json
    transcript.jsonl                 # user prompts + cerebro milestone events
    plans/                           # plan markdown files
    children/                        # stream-json logs of every sub-agent
    review-state/                    # per-repo last-reviewed SHA + last findings path
```

The `UserPromptSubmit` hook routes each user message to the matching
session's `transcript.jsonl` by `session_id`, so memory survives
resume and concurrent sessions never bleed into each other. The hook
no-ops for non-cerebro claude sessions, so it is safe even though
`.claude/settings.local.json` lives in a directory claude visits any
time you `cd` into `~/.cerebro`.

Requirements: `claude`, `codex`, `jq`, `python3`. The orchestrator also
calls `git`/`gh`/`rg` directly through read-only bridge subcommands
(`cerebro git`, `cerebro gh`, `cerebro grep`, `cerebro read`,
`cerebro ls`) so it can inspect a user repo without spawning a planning
child; `git` and `gh` are needed for those bridges, and `rg` (ripgrep)
is recommended for `cerebro grep`. Child claudes additionally need
`git` and `gh` for `execute` / `apply-review` / `doc-write` to function.

For the read-only exploration bridges (`cerebro read`, `cerebro ls`,
`cerebro grep`), a benign in-bounds "target not found / wrong type"
(and, for `grep`, zero matches) is treated as a successful empty
result rather than an error: the bridge prints a `(not found: <path>)`
(or `(no matches)`) marker line to stdout and exits 0. This keeps a
missing probe target during the orchestrator's parallel fan-out from
cancelling sibling tool calls in the same batch. Pass `--strict-missing`
to restore the old hard behavior (exit 3 for a missing/wrong-type
target; rg-native exit 1 for zero matches). Path-escape and
special-path refusals (`/dev`, `/proc`, `/sys`) remain hard errors
(exit 6), and the `cerebro git` / `cerebro gh` bridges are unchanged.
The authoritative exit-code contract lives in the embedded
`cerebro_system_prompt()` heredoc, which regenerates
`~/.cerebro/system-prompt.md` on next launch.

Env: `CEREBRO_HOME`, `CEREBRO_MODEL`, `CEREBRO_REVIEW_MODEL`,
`CEREBRO_TIMEOUT`, `CEREBRO_CODEX_CMD`, `CEREBRO_DEBUG`.

`CEREBRO_TIMEOUT` is the wall-clock cap (seconds) on each child agent call. It defaults to `0` (no cap) so long-running children — Playwright login/browser driving, waiting on the build pipeline — are never killed. Set it to a positive integer to re-enable a cap.

## Adding a tool

1. Drop the script into `bin/` and `chmod +x` it.
2. Add its filename to `tools.txt`.
3. Document it in this README.

The installer reads `tools.txt`, so anything listed there is picked up
automatically on the next install.
