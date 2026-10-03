#!/bin/bash
# tool/build_android_bridge.sh
#
# Cross-compiles the bridge (engine/bridge/CMakeLists.txt, the same as the
# desktop build) for Android with the NDK, into
# android/app/src/main/jniLibs/<abi>/libbwbridge.so, which the APK packages.
# ABIs: arm64-v8a (phones) and x86_64 (emulators); pass ABIS="arm64-v8a" to
# build fewer. The C++ runtime is linked statically.

set -euo pipefail
cd "$(dirname "$0")/.."

NDK="${ANDROID_NDK:-$HOME/Android/Sdk/ndk/27.0.12077973}"
ABIS="${ABIS:-arm64-v8a x86_64}"
MIN_SDK="${MIN_SDK:-24}"

for abi in $ABIS; do
	out="build/android-bridge/$abi"
	cmake -S engine/bridge -B "$out" \
		-DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
		-DANDROID_ABI="$abi" -DANDROID_PLATFORM="android-$MIN_SDK" -DANDROID_STL=c++_static \
		-DCMAKE_BUILD_TYPE=Release > /dev/null
	cmake --build "$out" --target bwbridge -j4 > /dev/null
	mkdir -p "android/app/src/main/jniLibs/$abi"
	cp "$out/libbwbridge.so" "android/app/src/main/jniLibs/$abi/"
	"$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" "android/app/src/main/jniLibs/$abi/libbwbridge.so"
	ls -la "android/app/src/main/jniLibs/$abi/libbwbridge.so"
done
