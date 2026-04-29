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

## Adding a tool

1. Drop the script into `bin/` and `chmod +x` it.
2. Add its filename to `tools.txt`.
3. Document it in this README.

The installer reads `tools.txt`, so anything listed there is picked up
automatically on the next install.
