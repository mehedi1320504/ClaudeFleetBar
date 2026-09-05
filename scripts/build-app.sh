#!/usr/bin/env bash
# Builds ClaudeFleetBar.app. SwiftPM produces a bare executable; a menu bar
# app needs a real bundle (for LSUIElement and for notification identity),
# so we assemble one around it.
#
# Signing: set DEVELOPER_ID_APP to a "Developer ID Application" identity for a
# stable signature. Without it the bundle is ad-hoc signed, which works fine
# but changes its code hash on every build — and the login Keychain ties its
# access grants to that hash, so macOS re-asks for every account each time.
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

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  # --options runtime is required for notarization; --timestamp is required for
  # the signature to keep validating after the certificate expires.
  codesign --force --options runtime --timestamp \
           --sign "$DEVELOPER_ID_APP" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "signed with: $DEVELOPER_ID_APP"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 \
    || echo "warning: ad-hoc codesign failed; the Keychain may prompt on each launch" >&2
  echo "ad-hoc signed (set DEVELOPER_ID_APP for a stable signature)"
fi

echo "built $APP"
