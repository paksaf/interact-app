#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# INTERACT Talk — one-command deploy to lab devices (6069+).
#
# Usage:
#   bash deploy-devices.sh                    # print help + version
#   bash deploy-devices.sh ipad               # iPad USB (flutter install)
#   bash deploy-devices.sh iphone             # iPhone USB
#   bash deploy-devices.sh a23                # Samsung A23 USB arm64
#   bash deploy-devices.sh car                # Car HU WiFi adb (armeabi-v7a)
#   bash deploy-devices.sh car-wifi           # Car HU browser sideload :8766
#   bash deploy-devices.sh phone-wifi         # Phone fat APK sideload :8765
#   bash deploy-devices.sh tv                 # Bravia TV WiFi adb
#   bash deploy-devices.sh mobile             # a23 + ipad (phones/tablet cable)
#
# Device IDs: copy .device-env.example → .device-env (local overrides).

set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .device-env ]]; then
  # shellcheck disable=SC1091
  source .device-env
fi

VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
target="${1:-help}"

echo "INTERACT Talk $VER — deploy-devices.sh"

case "$target" in
  help|-h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    echo ""
    echo "Current version: $VER"
    echo "Configured: A23=${A23_SERIAL:-?} IPAD=${IPAD_UDID:-?} CAR=${CAR_HOST:-?}"
    ;;
  ipad)
    bash build-and-install-ios.sh ipad
    ;;
  iphone|ios)
    bash build-and-install-ios.sh iphone
    ;;
  a23|samsung)
    bash build-and-install.sh a23
    ;;
  car|headunit|hu)
    bash build-and-install.sh car
    ;;
  car-wifi)
    bash build-and-install.sh car-wifi
    ;;
  phone-wifi|wifi)
    bash build-and-install.sh wifi
    ;;
  tv|bravia)
    bash build-and-install.sh tv
    ;;
  mobile)
    bash build-and-install.sh a23
    bash build-and-install-ios.sh ipad
    ;;
  all-lab)
    bash build-and-install.sh a23
    bash build-and-install-ios.sh ipad
    bash build-and-install.sh car-wifi
    ;;
  *)
    echo "❌ Unknown target '$target'"
    bash "$0" help
    exit 1
    ;;
esac
