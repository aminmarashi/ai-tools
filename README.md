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

## Adding a tool

1. Drop the script into `bin/` and `chmod +x` it.
2. Add its filename to `tools.txt`.
3. Document it in this README.

The installer reads `tools.txt`, so anything listed there is picked up
automatically on the next install.
