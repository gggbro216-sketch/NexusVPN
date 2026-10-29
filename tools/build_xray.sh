#!/usr/bin/env bash
# Builds Xray-core as an Android executable (PIE), packaged as libxray.so so the
# installer extracts it into the app's native library directory, where an app
# may execute files. It runs as a child process of the VPN service (a second Go
# runtime cannot share a process with libbox).
#
# Requirements: Go (GOTOOLCHAIN=auto fetches the version from go.mod), Android NDK.
# Output: android_plugin/nexus_vpn_bridge/src/main/jniLibs/<abi>/libxray.so (+ SHA256SUMS)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

XRAY_TAG="${XRAY_TAG:-v26.10.21}"
XRAY_COMMIT="1b1647cd9ddf0abc34b981d4611fc03bcac1ca74"   # commit of v26.10.21
SRC="$ROOT/build/xray-src"
OUT="$ROOT/android_plugin/nexus_vpn_bridge/src/main/jniLibs"
NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:?set ANDROID_HOME}/ndk/28.0.13004108}"
TC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
API=24
export GOTOOLCHAIN=auto
mkdir -p "$ROOT/build"
touch "$ROOT/build/.gdignore"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$XRAY_TAG" https://github.com/XTLS/Xray-core.git "$SRC"
fi
ACTUAL=$(git -C "$SRC" rev-parse HEAD)
[ "$ACTUAL" = "$XRAY_COMMIT" ] || { echo "Xray source commit mismatch: $ACTUAL != $XRAY_COMMIT"; exit 1; }

build() { # goarch goarm cc abi
  mkdir -p "$OUT/$4"
  ( cd "$SRC" && CGO_ENABLED=1 GOOS=android GOARCH="$1" GOARM="$2" CC="$TC/$3" \
      go build -trimpath -buildvcs=false -buildmode=pie -ldflags "-s -w -buildid= -checklinkname=0" -o "$OUT/$4/libxray.so" ./main )
}
build arm64 "" "aarch64-linux-android${API}-clang" arm64-v8a
build arm 7 "armv7a-linux-androideabi${API}-clang" armeabi-v7a
( cd "$OUT" && sha256sum */libxray.so ) | tee "$ROOT/android_plugin/nexus_vpn_bridge/xray/SHA256SUMS"
