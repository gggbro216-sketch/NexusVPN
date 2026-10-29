#!/usr/bin/env bash
# Builds the NexusVpnBridge Android plugin AAR and installs it, together with
# libbox.aar, into addons/android_vpn_bridge/bin/.
#
# Inputs:
#   LIBBOX_AAR      path to libbox.aar (default: build/libbox/libbox.aar, see build_libbox.sh)
#   GODOT_LIB_AAR   godot-lib template AAR (default: extracted from the installed
#                   Godot 4.7.2 export templates' android_source.zip)
#   ANDROID_HOME    Android SDK (platform 36, build-tools 36.1.0)
#   JAVA_HOME       JDK 17
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

GODOT_VERSION="${GODOT_VERSION:-4.7.2.stable}"
LIBBOX_AAR="${LIBBOX_AAR:-$ROOT/build/libbox/libbox.aar}"
TEMPLATES="${GODOT_TEMPLATES:-$HOME/.local/share/godot/export_templates/$GODOT_VERSION}"
OUT="$ROOT/addons/android_vpn_bridge/bin"
LIBS="$ROOT/android_plugin/nexus_vpn_bridge/libs"
WORK="$ROOT/build/plugin_tmp"

[ -f "$LIBBOX_AAR" ] || { echo "libbox.aar not found at $LIBBOX_AAR (run tools/build_libbox.sh)"; exit 1; }
mkdir -p "$LIBS" "$OUT" "$WORK"
touch "$ROOT/build/.gdignore"   # keep Godot from scanning build outputs

if [ -z "${GODOT_LIB_AAR:-}" ]; then
  [ -f "$TEMPLATES/android_source.zip" ] || { echo "Godot export templates not found in $TEMPLATES"; exit 1; }
  rm -rf "$WORK/godot"; mkdir -p "$WORK/godot"
  unzip -q -o "$TEMPLATES/android_source.zip" "libs/release/*" -d "$WORK/godot"
  GODOT_LIB_AAR=$(ls "$WORK"/godot/libs/release/*.aar | head -1)
fi

extract_classes() { # aar out.jar
  rm -rf "$WORK/x"; mkdir -p "$WORK/x"
  unzip -q -o "$1" classes.jar -d "$WORK/x"
  cp "$WORK/x/classes.jar" "$2"
}
extract_classes "$GODOT_LIB_AAR" "$LIBS/godot-lib-classes.jar"
extract_classes "$LIBBOX_AAR" "$LIBS/libbox-classes.jar"

cd "$ROOT/android_plugin"
if [ -x ./gradlew ]; then GRADLE=./gradlew; else GRADLE=gradle; fi
$GRADLE --no-daemon -q :nexus_vpn_bridge:assembleRelease

cp nexus_vpn_bridge/build/outputs/aar/nexus_vpn_bridge-release.aar "$OUT/nexus_vpn_bridge-release.aar"
cp "$LIBBOX_AAR" "$OUT/libbox.aar"
( cd "$OUT" && sha256sum nexus_vpn_bridge-release.aar libbox.aar > SHA256SUMS )
echo "Installed plugin into $OUT:"
cat "$OUT/SHA256SUMS"
