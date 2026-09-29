#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 ]]; then echo "Usage: $0 video.mov image.png" >&2; exit 1; fi
BUILD="$ROOT/.build/tests"
mkdir -p "$BUILD"
xcrun swiftc -swift-version 6 -parse-as-library -framework AppKit -framework AVFoundation -framework QuartzCore \
 "$ROOT/Extension/VideoRenderer.swift" "$ROOT/Extension/StillFrame.swift" \
 "$ROOT/Extension/MediaLoopTiming.swift" "$ROOT/Extension/RampMath.swift" \
 "$ROOT/Extension/PlaybackPolicy.swift" "$ROOT/Tests/Support/RendererLogging.swift" \
 "$ROOT/Tests/PowerImageTests.swift" -o "$BUILD/PowerImageTests"
"$BUILD/PowerImageTests" "$1" "$2"
