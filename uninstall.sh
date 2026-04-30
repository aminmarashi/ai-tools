#!/usr/bin/env bash
# uninstall.sh - Remove aminmarashi/ai-tools from ~/bin and clean up PATH.
#
# Usage:
#   ai-tools-uninstall
#   curl -fsSL https://raw.githubusercontent.com/aminmarashi/ai-tools/main/uninstall.sh | bash
#
# Env:
#   AI_TOOLS_REF    git ref to read manifest from (default: main)
#   AI_TOOLS_DEST   install directory             (default: $HOME/bin)

set -uo pipefail

REPO="aminmarashi/ai-tools"
REF="${AI_TOOLS_REF:-main}"
DEST="${AI_TOOLS_DEST:-$HOME/bin}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"

say() { printf '==> %s\n' "$*"; }

# Best-effort: fetch the manifest to know which binaries to remove.
TOOLS=""
if command -v curl >/dev/null 2>&1; then
  TOOLS=$(curl -fsSL "$BASE/tools.txt" 2>/dev/null || true)
fi

# Fallback to a built-in list if the manifest can't be fetched.
if [[ -z "$TOOLS" ]]; then
  TOOLS="tai
plan2pdf"
fi

while IFS= read -r tool; do
  tool="${tool%%#*}"
  tool="${tool//[$'\t\r ']/}"
  [[ -z "$tool" ]] && continue
  if [[ -f "$DEST/$tool" ]]; then
    rm -f "$DEST/$tool" && say "removed $DEST/$tool"
  fi
done <<< "$TOOLS"

if [[ -f "$DEST/ai-tools-uninstall" ]]; then
  # Remove the uninstaller last; safe because we're already running from memory.
  rm -f "$DEST/ai-tools-uninstall" && say "removed $DEST/ai-tools-uninstall"
fi

MARK_OPEN="# >>> ai-tools (aminmarashi) >>>"
MARK_CLOSE="# <<< ai-tools (aminmarashi) <<<"

for rc in \
  "$HOME/.zshrc" \
  "$HOME/.bashrc" \
  "$HOME/.bash_profile" \
  "$HOME/.profile" \
  "$HOME/.config/fish/config.fish"
do
  [[ -f "$rc" ]] || continue
  if grep -qF "$MARK_OPEN" "$rc"; then
    tmp="$(mktemp)"
    awk -v open="$MARK_OPEN" -v close="$MARK_CLOSE" '
      index($0, open)   { skip=1; next }
      index($0, close)  { skip=0; next }
      !skip
    ' "$rc" > "$tmp" && mv "$tmp" "$rc"
    say "cleaned PATH block from $rc"
  fi
done

say "Done."
