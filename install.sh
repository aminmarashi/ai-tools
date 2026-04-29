#!/usr/bin/env bash
# install.sh - Install aminmarashi/ai-tools into ~/bin and ensure it is on PATH.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/aminmarashi/ai-tools/main/install.sh | bash
#
# Env:
#   AI_TOOLS_REF    git ref to install from (default: main)
#   AI_TOOLS_DEST   install directory       (default: $HOME/bin)

set -euo pipefail

REPO="aminmarashi/ai-tools"
REF="${AI_TOOLS_REF:-main}"
DEST="${AI_TOOLS_DEST:-$HOME/bin}"
BASE="https://raw.githubusercontent.com/$REPO/$REF"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is required"

mkdir -p "$DEST"

say "Fetching tool manifest from $BASE/tools.txt"
TOOLS=$(curl -fsSL "$BASE/tools.txt") || die "could not fetch tools.txt"

installed=()
while IFS= read -r tool; do
  tool="${tool%%#*}"
  tool="${tool//[$'\t\r ']/}"
  [[ -z "$tool" ]] && continue
  say "Installing $tool -> $DEST/$tool"
  curl -fsSL "$BASE/bin/$tool" -o "$DEST/$tool.tmp"
  chmod +x "$DEST/$tool.tmp"
  mv "$DEST/$tool.tmp" "$DEST/$tool"
  installed+=("$tool")
done <<< "$TOOLS"

say "Installing uninstaller -> $DEST/ai-tools-uninstall"
curl -fsSL "$BASE/uninstall.sh" -o "$DEST/ai-tools-uninstall.tmp"
chmod +x "$DEST/ai-tools-uninstall.tmp"
mv "$DEST/ai-tools-uninstall.tmp" "$DEST/ai-tools-uninstall"

# Ensure DEST is on PATH by appending a guarded block to the user's shell rc.
detect_rc() {
  local sh="${SHELL##*/}"
  case "$sh" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      if [[ -f "$HOME/.bashrc" ]]; then echo "$HOME/.bashrc"
      else echo "$HOME/.bash_profile"; fi ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

RC="$(detect_rc)"
MARK_OPEN="# >>> ai-tools (aminmarashi) >>>"
MARK_CLOSE="# <<< ai-tools (aminmarashi) <<<"

case ":${PATH:-}:" in
  *":$DEST:"*) say "$DEST already on PATH" ;;
  *)
    if [[ -f "$RC" ]] && grep -qF "$MARK_OPEN" "$RC"; then
      say "PATH block already present in $RC"
    else
      mkdir -p "$(dirname "$RC")"
      {
        printf '\n%s\n' "$MARK_OPEN"
        if [[ "$RC" == *config/fish/config.fish ]]; then
          printf 'set -gx PATH %s $PATH\n' "$DEST"
        else
          printf 'export PATH="%s:$PATH"\n' "$DEST"
        fi
        printf '%s\n' "$MARK_CLOSE"
      } >> "$RC"
      say "Added $DEST to PATH in $RC"
      say "Open a new shell, or run: source \"$RC\""
    fi ;;
esac

say "Done. Installed:"
for t in "${installed[@]}"; do printf '    - %s\n' "$t"; done
printf '    - ai-tools-uninstall (run to remove)\n'
