#!/usr/bin/env bash
# Builds libbox.aar (sing-box core for Android) from the official sing-box
# source at a pinned tag with gomobile (SagerNet fork).
#
# Requirements: Go >= 1.25 (GOTOOLCHAIN=auto downloads it), JDK 17,
# Android SDK with NDK 28.0.13004108 (the version sing-box pins), git.
# Output: build/libbox/libbox.aar (+ .sha256)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

SING_BOX_TAG="${SING_BOX_TAG:-v1.14.4}"
SING_BOX_COMMIT="c005f35300ce76427dc285481ec5695f5b179cd2"   # commit of v1.14.4
GOMOBILE_VERSION="v0.1.12"                                     # from sing-box go.mod
# arm64 + armv7 covers real devices; add android/amd64 for x86_64 emulators.
TARGETS="${LIBBOX_TARGETS:-android/arm64,android/arm}"
# Same feature set as the official Android client minus Tailscale/OpenVPN/
# OpenConnect/USB-IP/Naive (keeps the AAR small).
TAGS="with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api,badlinkname,tfogo_checklinkname0"

SRC="$ROOT/build/sing-box-src"
OUT="$ROOT/build/libbox"
mkdir -p "$OUT"

export ANDROID_HOME="${ANDROID_HOME:?set ANDROID_HOME}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/28.0.13004108}"
export GOTOOLCHAIN=auto
export PATH="$PATH:$(go env GOPATH)/bin"

if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$SING_BOX_TAG" https://github.com/SagerNet/sing-box.git "$SRC"
fi
ACTUAL=$(git -C "$SRC" rev-parse HEAD)
if [ "$ACTUAL" != "$SING_BOX_COMMIT" ]; then
  echo "sing-box source commit mismatch: $ACTUAL != $SING_BOX_COMMIT"; exit 1
fi

go install "github.com/sagernet/gomobile/cmd/gomobile@$GOMOBILE_VERSION" "github.com/sagernet/gomobile/cmd/gobind@$GOMOBILE_VERSION"

VERSION="${SING_BOX_TAG#v}"
LDFLAGS="-X github.com/sagernet/sing-box/constant.Version=$VERSION -X runtime.godebugDefault=multipathtcp=0,tlssha1=1 -checklinkname=0 -s -w -buildid="
cd "$SRC"
gomobile bind -v -o "$OUT/libbox.aar" -target "$TARGETS" -androidapi 24 \
  -javapkg=io.nekohasekai -libname=box -trimpath -buildvcs=false \
  -ldflags "$LDFLAGS" -tags "$TAGS" ./experimental/libbox
cd "$OUT" && sha256sum libbox.aar | tee libbox.aar.sha256
