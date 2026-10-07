#!/bin/bash
# launch-android.sh
#
# Builds the Android app for every phone or emulator connected (adb
# devices), installs it on each of them and starts it. The engine bridge is
# cross-compiled with the NDK for just the ABIs those devices need
# (arm64-v8a phones, x86_64 emulators).
#
# The game files from BROOD_DATA (default ~/box/media/games/BROOD) go into
# the APK and are copied into the app's storage on first start. Without
# them the app asks for the StarCraft folder, or copy it over USB to
# Android/data/dev.x1watt.brood/files/BROOD.

set -euo pipefail
cd "$(dirname "$0")"

APP_ID="dev.x1watt.brood"
APK="build/app/outputs/flutter-apk/app-release.apk"
LOCK="${BUILD_LOCK:-$HOME/temp/bin/android-build-locked}"
run_build() { if [ -x "$LOCK" ]; then "$LOCK" "$@"; else "$@"; fi; }

command -v adb >/dev/null || { echo "adb not found (Android SDK platform-tools)."; exit 1; }
mapfile -t devices < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
if [ ${#devices[@]} -eq 0 ]; then
	echo "No Android device connected (check USB debugging and 'adb devices')."
	adb devices | awk 'NR > 1 && NF && $2 != "device" { print "  " $1 ": " $2 }'
	exit 1
fi

# The ABIs the connected devices run.
abis=()
platforms=()
for d in "${devices[@]}"; do
	abi="$(adb -s "$d" shell getprop ro.product.cpu.abi | tr -d '\r')"
	case "$abi" in
		arm64-v8a) platform=android-arm64 ;;
		x86_64) platform=android-x64 ;;
		*) echo "$d: ABI $abi is not supported (arm64-v8a or x86_64 only), skipping."; continue ;;
	esac
	if [[ ! " ${abis[*]} " =~ " $abi " ]]; then
		abis+=("$abi")
		platforms+=("$platform")
	fi
done
[ ${#abis[@]} -gt 0 ] || { echo "No supported device connected."; exit 1; }

echo "Building for: ${abis[*]}"
# The browser version the app carries, for sharing the game on the network.
tool/build_web.sh
ABIS="${abis[*]}" tool/build_android_bridge.sh
run_build flutter build apk --release --target-platform "$(IFS=,; echo "${platforms[*]}")"

status=0
for d in "${devices[@]}"; do
	model="$(adb -s "$d" shell getprop ro.product.model | tr -d '\r')"
	echo "Installing on $model ($d)"
	if adb -s "$d" install -r "$APK"; then
		adb -s "$d" shell am start -n "$APP_ID/.MainActivity" >/dev/null && echo "  started"
	else
		echo "  install failed on $d"
		status=1
	fi
done
exit $status
