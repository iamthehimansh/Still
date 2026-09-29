#!/bin/bash
set -euo pipefail
STILL_EXT_DIR="$(cd "$(dirname "$0")" && pwd)"
STILL_ROOT="$(dirname "$STILL_EXT_DIR")"
STILL_BUNDLE="${1:-$STILL_ROOT/Build/StillExtension.appex}"
STILL_CACHE="${STILL_MODULE_CACHE:-$STILL_ROOT/Build/ModuleCache}"
mkdir -p "$STILL_BUNDLE/Contents/MacOS" "$STILL_BUNDLE/Contents/Resources" "$STILL_CACHE"
cp "$STILL_EXT_DIR/Info.plist" "$STILL_BUNDLE/Contents/Info.plist"
cp "$STILL_ROOT/ThirdParty/Phosphene-LICENSE" "$STILL_BUNDLE/Contents/Resources/Phosphene-LICENSE"
xcrun swiftc -swift-version 6 -parse-as-library -whole-module-optimization -Onone \
  -target "$(uname -m)-apple-macos26.0" -module-name StillExtension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -import-objc-header "$STILL_EXT_DIR/WallpaperExtension-Bridging-Header.h" \
  "$STILL_EXT_DIR"/*.swift -o "$STILL_BUNDLE/Contents/MacOS/StillExtension" \
  -module-cache-path "$STILL_CACHE" \
  -framework AppKit -framework AVFoundation -framework ExtensionFoundation \
  -framework QuartzCore -framework IOKit -framework Security
codesign --force --sign - --entitlements "$STILL_EXT_DIR/Extension.entitlements" "$STILL_BUNDLE"
