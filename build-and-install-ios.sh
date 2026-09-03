#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# INTERACT — build iOS release and install on iPhone or iPad (USB cable).
#
# Usage:
#   bash build-and-install-ios.sh          # build only
#   bash build-and-install-ios.sh install  # first connected iOS device
#   bash build-and-install-ios.sh ipad     # iPad by UDID (.device-env)
#   bash build-and-install-ios.sh iphone   # iPhone (Paksaf) by UDID
#
# Requires: Xcode signing team configured in ios/Runner.xcworkspace.
# Device IDs: copy .device-env.example → .device-env

set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .device-env ]]; then
  # shellcheck disable=SC1091
  source .device-env
fi

IPAD_UDID="${IPAD_UDID:-00008112-000609C611F9401E}"
IPHONE_UDID="${IPHONE_UDID:-00008101-001A3CE400E1401E}"

target="${1:-build}"
VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"

echo "==> INTERACT Talk iOS $VER"

echo "==> [1/4] flutter pub get"
flutter pub get

echo ""
echo "==> [2/4] flutter analyze (warnings ok, errors fail the build)"
if ! flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos; then
  echo "❌ flutter analyze reported errors — fix above before continuing"
  exit 1
fi

echo ""
echo "==> [3/4] pod install + flutter build ios --release (codesigned for device)"
if [[ -d ios ]]; then
  (cd ios && pod install)
fi
flutter build ios --release

APP="build/ios/iphoneos/Runner.app"
[[ -d "$APP" ]] || { echo "❌ $APP not found"; exit 1; }
echo "✅ iOS app: $APP ($(du -sh "$APP" | cut -f1))"

_install_to() {
  local udid="$1" label="$2"
  echo ""
  echo "==> [4/4] Install on $label ($udid)"
  echo "    (Unlock device, Trust this Mac, Developer Mode on)"

  if flutter install --release -d "$udid"; then
    echo "✅ Installed on $label via flutter install"
    return 0
  fi

  if command -v xcrun >/dev/null 2>&1 && xcrun devicectl help >/dev/null 2>&1; then
    echo "    flutter install failed — trying xcrun devicectl …"
    if xcrun devicectl device install app --device "$udid" "$APP" 2>/dev/null; then
      echo "✅ Installed on $label via devicectl"
      return 0
    fi
  fi

  if command -v ios-deploy >/dev/null 2>&1; then
    echo "    trying ios-deploy …"
    if ios-deploy --id "$udid" --bundle "$APP" --justlaunch; then
      echo "✅ Installed on $label via ios-deploy"
      return 0
    fi
  fi

  echo ""
  echo "❌ Automatic install failed. Manual options:"
  echo "   1. Xcode → open ios/Runner.xcworkspace → select $label → Run (▶)"
  echo "   2. brew install ios-deploy && bash build-and-install-ios.sh $target"
  echo "   3. flutter run --release -d $udid   (pick device if prompted)"
  open ios/Runner.xcworkspace
  return 1
}

case "$target" in
  build)
    echo ""
    echo "==> [4/4] Build only. Pass: install | ipad | iphone"
    ;;
  install)
    DEV="$(flutter devices 2>/dev/null | grep -iE 'iphone|ipad|ios' | grep -v simulator | head -1 | sed -E 's/.*• ([A-Za-z0-9-]+) •.*/\1/' || true)"
    [[ -n "$DEV" ]] || { echo "❌ No USB iOS device — Trust + Developer Mode"; exit 1; }
    _install_to "$DEV" "connected device"
    ;;
  ipad|tablet)
    _install_to "$IPAD_UDID" "iPad"
    ;;
  iphone|ios|paksaf)
    _install_to "$IPHONE_UDID" "iPhone (Paksaf)"
    ;;
  *)
    echo "❌ Unknown target '$target' — use: build | install | ipad | iphone"
    exit 1
    ;;
esac

echo ""
echo "✅ Done."
