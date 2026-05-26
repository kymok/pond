#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/SmolTodo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Library/Helpers"

swift build -c release --package-path "$ROOT_DIR"

mkdir -p "$MACOS_DIR" "$HELPERS_DIR"

cp "$ROOT_DIR/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/.build/release/SmolTodo" "$MACOS_DIR/SmolTodo"
cp "$ROOT_DIR/.build/release/todo" "$HELPERS_DIR/todo"

chmod 755 "$MACOS_DIR/SmolTodo" "$HELPERS_DIR/todo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "$APP_DIR"
