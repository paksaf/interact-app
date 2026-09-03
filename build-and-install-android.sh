#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# INTERACT Talk — build Android release APK and install on USB device (Samsung, etc.).
#
# Usage:
#   bash build-and-install-android.sh          # build only
#   bash build-and-install-android.sh install  # first connected Android device
#
# Requires: Android SDK, USB debugging enabled, adb authorized.

set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .device-env ]]; then
  # shellcheck disable=SC1091
  source .device-env
fi

ANDROID_SERIAL="${ANDROID_SERIAL:-R68T304FX1F}"

target="${1:-build}"
VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"

echo "==> INTERACT Talk Android $VER"

echo "==> [1/3] flutter pub get"
flutter pub get

echo ""
echo "==> [2/3] flutter analyze"
if ! flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos; then
  echo "❌ flutter analyze reported errors"
  exit 1
fi

echo ""
echo "==> [3/3] flutter build apk --release"
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$APK" ]] || { echo "❌ $APK not found"; exit 1; }
echo "✅ APK: $APK ($(du -sh "$APK" | cut -f1))"

_install() {
  local serial="$1" label="$2"
  echo ""
  echo "==> Install on $label ($serial)"
  adb -s "$serial" install -r "$APK"
  echo "✅ Installed on $label"
}

case "$target" in
  build)
    echo "Pass: install"
    ;;
  install)
    DEV="$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')"
    [[ -n "$DEV" ]] || { echo "❌ No adb device — enable USB debugging"; exit 1; }
    _install "$DEV" "connected Android"
    ;;
  samsung|a23)
    _install "$ANDROID_SERIAL" "Samsung A23"
    ;;
  *)
    echo "❌ Unknown target '$target' — use: build | install | samsung"
    exit 1
    ;;
esac

echo ""
echo "✅ Done."
