#!/bin/bash

set -eu

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd -P)
INSTALL_DIR="${APPOFFLOAD_INSTALL_DIR:-$HOME/.local/share/appoffload}"
BIN_DIR="${APPOFFLOAD_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$BIN_DIR"
cp "$SOURCE_DIR/bin/appoffload" "$INSTALL_DIR/bin/appoffload"
cp "$SOURCE_DIR/lib/core.sh" "$INSTALL_DIR/lib/core.sh"
cp "$SOURCE_DIR/lib/migration.sh" "$INSTALL_DIR/lib/migration.sh"
cp "$SOURCE_DIR/lib/tui.sh" "$INSTALL_DIR/lib/tui.sh"
cp "$SOURCE_DIR/VERSION" "$INSTALL_DIR/VERSION"
chmod 755 "$INSTALL_DIR/bin/appoffload"
ln -sfn "$INSTALL_DIR/bin/appoffload" "$BIN_DIR/appoffload"

echo "Installed appoffload to $BIN_DIR/appoffload"
case ":$PATH:" in
    *":$BIN_DIR:"*) echo "Run: appoffload" ;;
    *)
        echo "Add this line to ~/.zshrc, then open a new terminal:"
        echo "  export PATH=\"$BIN_DIR:\$PATH\""
        ;;
esac
