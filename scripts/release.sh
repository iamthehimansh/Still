#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-Still-notary}"
: "${STILL_SIGN_IDENTITY:?Set STILL_SIGN_IDENTITY to your Developer ID Application certificate name}"
case "$STILL_SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "A Developer ID Application identity is required." >&2; exit 1 ;;
esac
BUILD="$ROOT/.build/release"
APP="$BUILD/Still.app"
mkdir -p "$BUILD"
# Never overwrite or publish a developer's currently running copy.
STILL_APP_PATH="$APP" STILL_STARTER_VIDEO="" "$ROOT/build.sh"
SAVER="$APP/Contents/Resources/Still.saver"
EXT="$APP/Contents/Extensions/StillWallpaper.appex"
codesign --force --sign "$STILL_SIGN_IDENTITY" --options runtime --timestamp "$SAVER"
codesign --force --sign "$STILL_SIGN_IDENTITY" --options runtime --timestamp --entitlements "$ROOT/Extension/Extension.entitlements" "$EXT"
codesign --force --sign "$STILL_SIGN_IDENTITY" --options runtime --timestamp "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$BUILD/notarization.zip"
xcrun notarytool submit "$BUILD/notarization.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$BUILD/notarization.json"
STATUS=$(/usr/bin/plutil -extract status raw -o - "$BUILD/notarization.json")
if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization was not accepted; inspect $BUILD/notarization.json. No public archive produced." >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ditto -c -k --keepParent "$APP" "$BUILD/Still-macOS.zip"
(cd "$BUILD" && shasum -a 256 Still-macOS.zip > SHA256SUMS)
echo "Verified release: $BUILD/Still-macOS.zip"
