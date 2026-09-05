#!/usr/bin/env bash
# Developer-ID-signs, notarizes and staples ClaudeFleetBar.app.
#
# Required in the environment (never committed, never echoed):
#   DEVELOPER_ID_APP    e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID            Apple ID email for notarytool
#   APPLE_APP_PASSWORD  app-specific password, or "@keychain:AC_PASSWORD"
#   APPLE_TEAM_ID       the team the Developer ID belongs to
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ClaudeFleetBar.app"
ZIP="$ROOT/dist/ClaudeFleetBar.zip"

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
: "${APPLE_ID:?set APPLE_ID (email) for notarytool}"
: "${APPLE_APP_PASSWORD:?set APPLE_APP_PASSWORD}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

echo "▸ build + Developer ID sign"
DEVELOPER_ID_APP="$DEVELOPER_ID_APP" "$ROOT/scripts/build-app.sh"

# An ad-hoc seal here would notarize and then fail Gatekeeper on the user's
# machine, so the team is asserted before anything is uploaded.
SEAL="$(codesign -dv "$APP" 2>&1 || true)"
case "$SEAL" in
  *"TeamIdentifier=$APPLE_TEAM_ID"*) echo "  ✓ sealed to team $APPLE_TEAM_ID" ;;
  *) echo "✗ app is not sealed to team $APPLE_TEAM_ID (ad-hoc?)" >&2; exit 1 ;;
esac

echo "▸ zip for submission"
rm -f "$ZIP"
# ditto preserves the bundle structure and symlinks; `zip` does not.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ notarytool submit --wait"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_APP_PASSWORD" --wait

# The ticket is stapled to the .app, not to the zip that carried it — an
# unstapled app fails Gatekeeper on a Mac that is offline.
echo "▸ staple ticket"
xcrun stapler staple "$APP"
xcrun stapler validate -v "$APP" >/dev/null && echo "  ✓ ticket stapled"

echo "▸ Gatekeeper verdict"
# Captured first, matched second — never `spctl … | grep -q`, which SIGPIPEs
# the producer under `set -o pipefail` and fails on success.
VERDICT="$(spctl -a -vvv -t exec "$APP" 2>&1 || true)"
printf '%s\n' "$VERDICT"
case "$VERDICT" in
  *accepted*) echo "  ✓ Gatekeeper accepts it" ;;
  *) echo "✗ Gatekeeper rejected the notarized app" >&2; exit 1 ;;
esac

# Re-zip AFTER stapling, so what ships carries the ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "done: $APP (and $ZIP for distribution)"
