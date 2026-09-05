#!/usr/bin/env bash
# Builds ClaudeFleetBar.app. SwiftPM produces a bare executable; a menu bar
# app needs a real bundle (for LSUIElement and for notification identity),
# so we assemble one around it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/dist/ClaudeFleetBar.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/ClaudeFleetBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeFleetBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature: enough for the Keychain to recognise a stable identity
# across launches, so it does not re-prompt on every start.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
  echo "warning: ad-hoc codesign failed; the Keychain may prompt on each launch" >&2

echo "built $APP"
