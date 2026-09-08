#!/bin/bash
# Builds a Developer ID-signed, notarized, stapled app and packages it as a zip in dist/.
# One-time setup (prompts for an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials notary --apple-id you@example.com --team-id <TEAMID>
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-notary}"

scripts/build-app.sh
APP="build/GPTK Patcher Tool.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "Signing with ${IDENTITY}..."
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# The upload lives in a temporary folder; nothing lands in dist/ until it is notarized and stapled.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
UPLOAD="$WORK/upload.zip"
ditto -c -k --keepParent "$APP" "$UPLOAD"

echo "Submitting to Apple for notarization..."
xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait

echo "Stapling..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

mkdir -p dist
ZIP="dist/GPTK-Patcher-Tool-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Ready: $ZIP"
