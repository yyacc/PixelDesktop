#!/usr/bin/env bash
# Builds the disposable package used by the B4 Swift acceptance test.
#
# Why a hand-built APK and not a Gradle module: the worker's project must not gain a second
# application module just to test an uninstall, and a manifest-only APK needs no dex, so aapt2 +
# zipalign + apksigner from the already-installed build-tools are enough. Nothing in this script
# touches the worker build.
#
# The output is a *test fixture*. It is installed only by the acceptance test, and that test
# uninstalls it again. It is never a product artifact.
#
# Usage: ./build-disposable-apk.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="${1:-$PWD/out}"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-$(ls -d "$SDK/build-tools/"* 2>/dev/null | sort -V | tail -1)}"
PLATFORM_JAR="${ANDROID_JAR:-$(ls -d "$SDK/platforms/android-"* 2>/dev/null | sort -V | tail -1)/android.jar}"
KEYSTORE="${ANDROID_DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"

for tool in aapt2 zipalign apksigner; do
  [ -x "$BUILD_TOOLS/$tool" ] || { echo "missing $BUILD_TOOLS/$tool" >&2; exit 1; }
done
[ -f "$PLATFORM_JAR" ] || { echo "missing platform jar: $PLATFORM_JAR" >&2; exit 1; }
[ -f "$KEYSTORE" ] || { echo "missing debug keystore: $KEYSTORE" >&2; exit 1; }

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$BUILD_TOOLS/aapt2" link \
  --manifest AndroidManifest.xml \
  -I "$PLATFORM_JAR" \
  -o "$WORK/unsigned.apk"

"$BUILD_TOOLS/zipalign" -p -f 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"

APK="$OUT_DIR/com.pixeldesktop.disposable.probe.apk"
"$BUILD_TOOLS/apksigner" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$APK" \
  "$WORK/aligned.apk" >/dev/null

"$BUILD_TOOLS/apksigner" verify "$APK" >/dev/null

echo "built $APK"
echo "sha256 $(shasum -a 256 "$APK" | cut -d' ' -f1)"
echo "size   $(stat -f%z "$APK") bytes"
