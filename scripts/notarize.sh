#!/usr/bin/env bash
# Developer-ID-signs, notarizes and staples ClaudeFleetBar.app.
#
# Required in the environment (never committed, never echoed):
#   DEVELOPER_ID_APP    e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_TEAM_ID       the team the Developer ID belongs to
#
# Plus ONE notary credential, tried in this order:
#   1. APP_STORE_CONNECT_KEY_PATH + APP_STORE_CONNECT_KEY_ID + APP_STORE_CONNECT_ISSUER_ID
#      An App Store Connect API key. The secret is the .p8 FILE, and only its path rides argv.
#   2. NOTARY_KEYCHAIN_PROFILE
#      A profile saved once with `xcrun notarytool store-credentials <name>`. Only its name rides argv.
#   3. APPLE_ID + APPLE_APP_PASSWORD (legacy)
#      notarytool takes the password as an ARGUMENT, so it shows in `ps` for the whole
#      `--wait`, and on a machine where agents run `ps -axww` it lands in transcripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ClaudeFleetBar.app"
ZIP="$ROOT/dist/ClaudeFleetBar.zip"

: "${DEVELOPER_ID_APP:?set DEVELOPER_ID_APP}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

# Chosen BEFORE the build, so a missing credential fails in a second rather
# than after a release build that then cannot be notarized.
if [ -n "${APP_STORE_CONNECT_KEY_PATH:-}${APP_STORE_CONNECT_KEY_ID:-}${APP_STORE_CONNECT_ISSUER_ID:-}" ]; then
  # Any one of the three set means this route was meant, so a partial set is an
  # error, never a quiet fall-through to the password route.
  : "${APP_STORE_CONNECT_KEY_PATH:?set APP_STORE_CONNECT_KEY_PATH (the AuthKey_<id>.p8)}"
  : "${APP_STORE_CONNECT_KEY_ID:?set APP_STORE_CONNECT_KEY_ID}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?set APP_STORE_CONNECT_ISSUER_ID}"
  [ -f "$APP_STORE_CONNECT_KEY_PATH" ] || { echo "✗ no API key at APP_STORE_CONNECT_KEY_PATH" >&2; exit 1; }
  NOTARY_AUTH=(--key "$APP_STORE_CONNECT_KEY_PATH" --key-id "$APP_STORE_CONNECT_KEY_ID"
               --issuer "$APP_STORE_CONNECT_ISSUER_ID")
  NOTARY_ROUTE="App Store Connect API key"
elif [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  NOTARY_ROUTE="keychain profile"
elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
  NOTARY_ROUTE="Apple ID (password on argv)"
else
  echo "✗ no notary credential: set the App Store Connect key, NOTARY_KEYCHAIN_PROFILE," >&2
  echo "  or APPLE_ID + APPLE_APP_PASSWORD (see the header of this script)" >&2
  exit 1
fi
echo "▸ notary credential: $NOTARY_ROUTE"

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
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait

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
