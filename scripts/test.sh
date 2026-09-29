#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/tests"
mkdir -p "$BUILD"
xcrun swiftc -swift-version 6 "$ROOT/Source/Settings.swift" "$ROOT/Extension/StillConfiguration.swift" "$ROOT/Tests/ControlsTests.swift" -o "$BUILD/ControlsTests"
"$BUILD/ControlsTests"
xcrun swiftc -swift-version 6 "$ROOT/Extension/StillConfiguration.swift" "$ROOT/Tests/ConfigurationTests.swift" -o "$BUILD/ConfigurationTests"
"$BUILD/ConfigurationTests"
xcrun swiftc -swift-version 6 "$ROOT/Extension/AudioRouting.swift" "$ROOT/Tests/AudioRoutingTests.swift" -o "$BUILD/AudioRoutingTests"
"$BUILD/AudioRoutingTests"
xcrun swiftc -swift-version 6 "$ROOT/Extension/RemoteSurfaceGeometry.swift" "$ROOT/Tests/RemoteSurfaceGeometryTests.swift" -o "$BUILD/GeometryTests"
"$BUILD/GeometryTests"
