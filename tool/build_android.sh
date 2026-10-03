#!/bin/bash
# tool/build_android.sh
#
# Builds the Android app: the bridge with the NDK (tool/build_android_bridge.sh),
# then the APK through the machine-wide build lock (see ~/.claude/CLAUDE.md).
# Output: build/app/outputs/flutter-apk/app-release.apk
# Install on a connected phone with:  adb install -r build/app/outputs/flutter-apk/app-release.apk

set -euo pipefail
cd "$(dirname "$0")/.."
ABIS="${ABIS:-arm64-v8a}" tool/build_android_bridge.sh
LOCK="${BUILD_LOCK:-$HOME/temp/bin/android-build-locked}"
"$LOCK" flutter build apk --release --target-platform android-arm64
