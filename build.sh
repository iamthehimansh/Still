#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${STILL_BUILD_DIR:-$ROOT/.build}"
APP="${STILL_APP_PATH:-$ROOT/Still.app}"
mkdir -p "$BUILD/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
COMMON=(-swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macos26.0" -module-cache-path "$BUILD/module-cache" -O)

SAVER="$APP/Contents/Resources/Still.saver"
mkdir -p "$SAVER/Contents/MacOS"
xcrun swiftc "${COMMON[@]}" -emit-library -module-name StillScreenSaver \
  -framework AppKit -framework AVFoundation -framework ScreenSaver \
  "$ROOT/Source/StillScreenSaver.swift" -o "$SAVER/Contents/MacOS/StillScreenSaver"
cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.still.screensaver</string>
<key>CFBundleName</key><string>Still</string>
<key>CFBundleExecutable</key><string>StillScreenSaver</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>NSPrincipalClass</key><string>StillScreenSaverView</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$SAVER"

if [[ -x "$ROOT/Extension/build-extension.sh" ]]; then
  STILL_MODULE_CACHE="$BUILD/extension-cache" "$ROOT/Extension/build-extension.sh" "$APP/Contents/Extensions/StillWallpaper.appex"
fi
xcrun swiftc "${COMMON[@]}" -parse-as-library -module-name Still \
  -framework SwiftUI -framework AppKit -framework AVKit -framework AVFoundation \
  -framework QuartzCore -framework UniformTypeIdentifiers \
  "$ROOT/Source/Settings.swift" "$ROOT/Source/NativeWallpaperBridge.swift" \
  "$ROOT/Source/DesktopPlayer.swift" "$ROOT/Source/StillApp.swift" \
  -o "$APP/Contents/MacOS/Still"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.still.wallpaper</string>
<key>CFBundleName</key><string>Still</string>
<key>CFBundleDisplayName</key><string>Still</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>CFBundleExecutable</key><string>Still</string>
<key>CFBundleIconFile</key><string>Still</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>Still. Includes MIT-licensed Phosphene extension code; see THIRD-PARTY-NOTICES.</string>
</dict></plist>
PLIST
if [[ -f "$ROOT/Still.icns" ]]; then cp "$ROOT/Still.icns" "$APP/Contents/Resources/Still.icns"; fi
# Public builds contain no imported media. A local developer may explicitly opt in.
if [[ -n "${STILL_STARTER_VIDEO:-}" ]]; then
  cp "$STILL_STARTER_VIDEO" "$APP/Contents/Resources/Starter.mov"
else
  rm -f "$APP/Contents/Resources/Starter.mov"
fi
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
