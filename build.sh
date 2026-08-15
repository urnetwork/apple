#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Smoketest build for the apple app — the local equivalent of what
# build/all/run.sh does for apple:
#   1. regenerate Localizable.xcstrings from the localization store
#      (../localizations/keys), like the pipeline does before every build.
#   2. build the URnetwork scheme for iOS and macOS.
# The pipeline archives, signs and uploads; this builds unsigned, so it
# verifies compilation and linking only.
#
# Usage:
#   ./build.sh
#   BUILD_SDK=1 ./build.sh    also rebuild sdk/build/apple/URnetworkSdk.xcframework
#                             from the local sdk/connect/glog trees first
#   URNETWORK_ROOT=<dir>      sibling-repo root (default: parent of this repo)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${URNETWORK_ROOT:-$(dirname "$here")}"
derived_data="$here/app/build/DerivedData"

echo "== sync localizations (store -> Localizable.xcstrings)"
(cd "$root/localizations" &&
    { [ -d node_modules ] || npm ci --no-audit --no-fund; } &&
    npm run gen:apple)

if [ "${BUILD_SDK:-}" ]; then
    echo "== rebuild the apple xcframework from the local sdk/connect/glog trees"
    (cd "$root/sdk/build" && make init build_apple)
fi

echo "== xcodebuild URnetwork (iOS)"
(cd "$here/app" && xcodebuild -workspace app.xcodeproj/project.xcworkspace \
    -scheme URnetwork -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build)

"$root/sdk/build/check_apple_size.sh" \
    --sdk "$root/sdk/build/apple/URnetworkSdk.xcframework" \
    --extension-sdk "$root/sdk/build/apple/URnetworkExtensionSdk.xcframework" \
    --extension "$derived_data/Build/Products/Release-iphoneos/URnetworkVPN.appex"

echo "== xcodebuild URnetwork (macOS)"
(cd "$here/app" && xcodebuild -workspace app.xcodeproj/project.xcworkspace \
    -scheme URnetwork -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO build)

echo "== apple build OK"
