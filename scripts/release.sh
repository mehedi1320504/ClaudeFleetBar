#!/usr/bin/env bash
# Cuts a release: build → Developer ID sign → notarize → staple → EdDSA-sign
# for Sparkle → update appcast.xml → tag → publish to GitHub Releases.
#
#   ./scripts/release.sh 1.0.1
#
# Required in the environment (never committed, never echoed):
#   DEVELOPER_ID_APP · APPLE_ID · APPLE_APP_PASSWORD · APPLE_TEAM_ID
# The Sparkle EdDSA private key is read from the login Keychain by sign_update,
# where generate_keys put it. It is never a file and never an env var.
set -euo pipefail

VERSION="${1:?usage: release.sh <version>   e.g. 1.0.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="mehedi1320504/ClaudeFleetBar"
APP="$ROOT/dist/ClaudeFleetBar.app"
ZIP="$ROOT/dist/ClaudeFleetBar.zip"
cd "$ROOT"

[ -z "$(git status --porcelain)" ] || { echo "✗ working tree is dirty" >&2; exit 1; }

SIGN_UPDATE="$(find "$ROOT/.build/artifacts" -type f -name sign_update 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update not found — swift package resolve first" >&2; exit 1; }

# CFBundleVersion must increase monotonically: Sparkle compares THIS, not the
# display string, when deciding whether an update is newer.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist
echo "▸ version $VERSION (build $BUILD)"

echo "▸ build, notarize, staple"
"$ROOT/scripts/notarize.sh"

echo "▸ EdDSA-sign the artifact for Sparkle"
# sign_update prints: sparkle:edSignature="..." length="..."
SIGNED="$("$SIGN_UPDATE" "$ZIP")"
ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED")"
LENGTH="$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<<"$SIGNED")"
[ -n "$ED_SIG" ] && [ -n "$LENGTH" ] || { echo "✗ could not read signature from: $SIGNED" >&2; exit 1; }
echo "  ✓ signed (${#ED_SIG} chars, $LENGTH bytes)"

echo "▸ update appcast.xml"
VERSION="$VERSION" BUILD="$BUILD" ED_SIG="$ED_SIG" LENGTH="$LENGTH" REPO="$REPO" \
  python3 "$ROOT/scripts/update-appcast.py"

echo "▸ commit, tag, publish"
git add appcast.xml Resources/Info.plist
git commit -q -m "release: v$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"
git push -q origin HEAD "v$VERSION"

# The appcast points at this asset, so the release must exist before the feed
# that advertises it is live. It already is — the push above published the
# appcast — so create the release immediately and verify the asset resolves.
gh release create "v$VERSION" "$ZIP" --repo "$REPO" \
  --title "v$VERSION — Claude Fleet Bar" --generate-notes --verify-tag

URL="https://github.com/$REPO/releases/download/v$VERSION/ClaudeFleetBar.zip"
CODE="$(curl -sSL -o /dev/null -w '%{http_code}' "$URL" || true)"
[ "$CODE" = "200" ] && echo "  ✓ asset reachable at $URL" \
  || { echo "✗ asset not reachable (HTTP $CODE) — the appcast advertises a broken download" >&2; exit 1; }

echo "done: v$VERSION published and advertised"
