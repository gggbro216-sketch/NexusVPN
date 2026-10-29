#!/usr/bin/env bash
# Exports the Android APK with Godot (Gradle build).
#
#   tools/build_apk.sh debug            -> build/NexusVPN-debug.apk (debug keystore from editor settings)
#   tools/build_apk.sh release          -> build/NexusVPN-release.apk
#     release signing via environment (never commit keystores):
#       GODOT_ANDROID_KEYSTORE_RELEASE_PATH, GODOT_ANDROID_KEYSTORE_RELEASE_USER,
#       GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD
#
# Requirements: Godot 4.7.2 + export templates, Android SDK (platform 36,
# build-tools 36.1.0), JDK 17; editor settings export/android/android_sdk_path
# and java_sdk_path must point to them (see docs/BUILD_ANDROID.md).
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-debug}"
GODOT="${GODOT:-godot}"
mkdir -p build
touch build/.gdignore

for f in addons/android_vpn_bridge/bin/nexus_vpn_bridge-release.aar addons/android_vpn_bridge/bin/libbox.aar; do
  [ -f "$f" ] || { echo "missing $f — run tools/build_libbox.sh and tools/build_android_plugin.sh"; exit 1; }
done
( cd addons/android_vpn_bridge/bin && sha256sum -c SHA256SUMS )

# Refresh the import/class cache, install the Gradle template if needed, export.
"$GODOT" --headless --path . --editor --quit >/dev/null 2>&1 || true
case "$MODE" in
  debug)   "$GODOT" --headless --path . --install-android-build-template --export-debug "Android" build/NexusVPN-debug.apk ;;
  release) "$GODOT" --headless --path . --install-android-build-template --export-release "Android" build/NexusVPN-release.apk ;;
  *) echo "usage: $0 debug|release"; exit 2 ;;
esac
ls -la build/*.apk
