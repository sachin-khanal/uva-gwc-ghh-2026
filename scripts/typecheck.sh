#!/usr/bin/env bash
# File:    scripts/typecheck.sh
# Purpose: Type-check the whole iOS app (ARKit, CoreHaptics, Multipeer, SwiftUI code) against the
#          real iOS SDK WITHOUT xcodebuild, signing, a phone, or the Simulator.
# Why:     `xcodebuild` needs Xcode's Simulator plugin (CoreSimulator). On a Mac where that is not
#          installed, `xcodebuild` aborts before compiling anything. This script bypasses it:
#            1. builds the WaypointCore package for the iOS SDK (produces WaypointCore.swiftmodule)
#            2. runs `swiftc -typecheck` over every file in /Waypoint against that module.
# Catches:  compile errors and API misuse. Does NOT catch runtime/AR behaviour (needs a phone).
# Also checks the UI tests in /WaypointUITests.
# Run via:  make typecheck      Output: nothing on success, compiler diagnostics on failure.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SCRATCH="$HOME/Library/Caches/Waypoint/spm-ios"   # outside the repo: see Makefile note on iCloud/codesign

( cd Package/WaypointCore && swift build --scratch-path "$SCRATCH" --triple arm64-apple-ios17.0 --sdk "$SDK" 2>&1 | tail -3 )

MOD="$SCRATCH/out/Products/Debug-iphoneos"
xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 -target arm64-apple-ios17.0 \
  -sdk "$SDK" -I "$MOD" $(find Waypoint -name '*.swift')

# UI tests need XCTest, which lives in the platform's Developer/Library/Frameworks (not in the SDK itself).
PLATFORM_FRAMEWORKS="$SDK/../../Library/Frameworks"
xcrun --sdk iphoneos swiftc -typecheck -swift-version 5 -target arm64-apple-ios17.0 \
  -sdk "$SDK" -F "$PLATFORM_FRAMEWORKS" -I "$SDK/../../usr/lib" $(find WaypointUITests -name '*.swift')

echo "typecheck OK ($(find Waypoint -name '*.swift' | wc -l | tr -d ' ') app files, $(find WaypointUITests -name '*.swift' | wc -l | tr -d ' ') UI test file)"
