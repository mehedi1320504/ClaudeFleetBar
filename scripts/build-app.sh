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
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/ClaudeFleetBar" "$APP/Contents/MacOS/ClaudeFleetBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# ── Sparkle ─────────────────────────────────────────────────────────────────
# SPM leaves the framework in the artifacts dir; a bundle has to carry its own
# copy, and the executable finds it via the @executable_path/../Frameworks
# rpath set in Package.swift.
SPARKLE_SRC="$(find "$ROOT/.build/artifacts" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
[ -z "$SPARKLE_SRC" ] && SPARKLE_SRC="$(find "$ROOT/.build" -type d -name 'Sparkle.framework' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_SRC" ]; then
  echo "✗ Sparkle.framework not found — run 'swift package resolve' first" >&2
  exit 1
fi
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
echo "embedded Sparkle from ${SPARKLE_SRC#$ROOT/}"

sign() {
  local identity="$1"; shift
  codesign --force --options runtime --timestamp --sign "$identity" "$@"
}

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  IDENTITY="$DEVELOPER_ID_APP"
else
  IDENTITY="-"
  echo "ad-hoc signing (set DEVELOPER_ID_APP for a stable signature)"
fi

# Sparkle ships helpers nested inside the framework. They must each be signed
# BEFORE the framework, and the framework before the app: signing an outer
# bundle seals whatever is inside it, so a helper signed afterwards invalidates
# the enclosing signature. --deep is not a substitute — Apple deprecates it and
# it applies the wrong identity/entitlements to nested code.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for nested in \
  "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
  "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
  "$SPARKLE/Versions/B/Autoupdate" \
  "$SPARKLE/Versions/B/Updater.app"
do
  [ -e "$nested" ] && sign "$IDENTITY" "$nested"
done
sign "$IDENTITY" "$SPARKLE"
sign "$IDENTITY" "$APP"

codesign --verify --strict --verbose=2 "$APP"
if [ "$IDENTITY" != "-" ]; then echo "signed with: $IDENTITY"; fi

echo "built $APP"
