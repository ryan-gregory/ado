#!/usr/bin/env bash
# install.sh — symlink the ado script into ~/.local/bin/
#
# Idempotent. Re-run after a `git pull`; symlink stays valid automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${HOME}/.local/bin"
SOURCE="${SCRIPT_DIR}/ado"
LINK="${TARGET_DIR}/ado"

mkdir -p "$TARGET_DIR"
ln -sf "$SOURCE" "$LINK"

echo "✓ Linked $SOURCE → $LINK"

case ":$PATH:" in
  *":$TARGET_DIR:"*) ;;
  *) echo "⚠  $TARGET_DIR is not on your PATH. Add it:"
     echo "    echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc"
     ;;
esac
