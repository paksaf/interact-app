#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# INTERACT — build the release APK and (optionally) install it.
#
# Usage:
#   bash build-and-install.sh             # build only (split ABIs)
#   bash build-and-install.sh a23         # build + install arm64 on A23 (USB)
#   bash build-and-install.sh phoneb      # build + install armeabi-v7a on USB device
#                                         #   (32-bit Redmi / Phone B — NEVER give it arm64)
#   bash build-and-install.sh tv          # build + install on Bravia TV (LAN)
#   bash build-and-install.sh car         # build + install on car HU (WiFi adb, v7a)
#   bash build-and-install.sh car-wifi    # build v7a APK + HTTP serve :8766 for car browser
#   bash build-and-install.sh all         # build + install on A23 + TV
#   bash build-and-install.sh wifi        # build a TRUE fat universal apk + serve Wi-Fi :8765
#                                         #   (must include armeabi-v7a — see gotcha #67)
#
# Device IDs: copy .device-env.example → .device-env (local overrides).

set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .device-env ]]; then
  # shellcheck disable=SC1091
  source .device-env
fi

# Devices (see docs/DEV_LAN_SETUP.md)
A23_SERIAL="${A23_SERIAL:-R68T304FX1F}"
TV_HOST="${TV_HOST:-192.168.100.4:5555}"
CAR_HOST="${CAR_HOST:-}"
WIFI_PORT_PHONE="${WIFI_PORT_PHONE:-8765}"
WIFI_PORT_CAR="${WIFI_PORT_CAR:-8766}"

target="${1:-build}"

echo "==> [1/4] flutter pub get"
flutter pub get

echo ""
echo "==> [2/4] flutter analyze (warnings ok, errors fail the build)"
# Fail only on real errors; warnings/infos are surfaced but don't block.
if ! flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos; then
  echo "❌ flutter analyze reported errors — fix above before continuing"
  exit 1
fi

APK_DIR="build/app/outputs/flutter-apk"
# Version tag (e.g. 0.5.1+2027) → used to name the sideload APK so a phone
# never installs a stale build with the same generic filename again.
VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | tr '+' '-')"

# ── Wi-Fi sideload path builds a UNIVERSAL apk (works on every ABI) ─────────
# Do NOT sideload the stale `app-release.apk` a --split build leaves behind:
# --split-per-abi does NOT refresh app-release.apk, so serving it installs an
# OLD build. We build a fresh universal apk under a versioned name instead.
if [[ "$target" == "wifi" ]]; then
  echo ""
  echo "==> [3/4] flutter build apk --release  (TRUE fat universal — all ABIs)"
  # Clear any stale generic artefact first so nothing old can be served.
  rm -f "$APK_DIR/app-release.apk"
  flutter build apk --release
  UNIVERSAL="$APK_DIR/app-release.apk"
  [[ -f "$UNIVERSAL" ]] || { echo "❌ universal APK not found at $UNIVERSAL"; exit 1; }
  bash scripts/verify-apk-abis.sh "$UNIVERSAL" --require-fat
  SIDELOAD="$APK_DIR/InteractTalk-${VER}.apk"
  cp "$UNIVERSAL" "$SIDELOAD"
  echo "✅ fat universal APK: $SIDELOAD ($(du -h "$SIDELOAD" | cut -f1)) — includes v7a+arm64"

  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  echo ""
  echo "==> [4/4] Serving over Wi-Fi on :${WIFI_PORT_PHONE}"
  echo "    On the phone (same Wi-Fi) open:"
  echo "      http://${LAN_IP:-<your-mac-ip>}:${WIFI_PORT_PHONE}/InteractTalk-${VER}.apk"
  echo "    Wait for 100% download (~150–180 MB). Partial → splash then close."
  echo "    (Ctrl+C to stop the server when the download completes.)"
  cd "$APK_DIR"
  # Bind IPv4 explicitly (Pattern 11) — default [::] confuses some MIUI browsers.
  exec python3 -c "
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
class H(SimpleHTTPRequestHandler):
    extensions_map = {**getattr(SimpleHTTPRequestHandler, 'extensions_map', {}),
                      '.apk': 'application/vnd.android.package-archive'}
ThreadingHTTPServer(('0.0.0.0', ${WIFI_PORT_PHONE}), H).serve_forever()
"
fi

# ── Car HU Wi-Fi sideload — v7a-only APK on :8766 (lighter for 2 GB HU) ─────
if [[ "$target" == "car-wifi" ]]; then
  echo ""
  echo "==> [3/4] flutter build apk --release --target-platform android-arm"
  flutter build apk --release --target-platform android-arm
  V7_ONLY="$APK_DIR/app-release.apk"
  [[ -f "$V7_ONLY" ]] || { echo "❌ v7a APK not found at $V7_ONLY"; exit 1; }
  CAR_APK="$APK_DIR/InteractTalk-car-v7a-${VER}.apk"
  cp "$V7_ONLY" "$CAR_APK"
  mkdir -p "$HOME/dev/INTERACT/_car-hu-install"
  cp "$CAR_APK" "$HOME/dev/INTERACT/_car-hu-install/"
  echo "✅ car v7a APK: $CAR_APK ($(du -h "$CAR_APK" | cut -f1))"
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  echo ""
  echo "==> [4/4] Serving car APK over Wi-Fi on :${WIFI_PORT_CAR}"
  echo "    On the head-unit browser (same Wi-Fi) open:"
  echo "      http://${LAN_IP:-<your-mac-ip>}:${WIFI_PORT_CAR}/$(basename "$CAR_APK")"
  echo "    Enable Install unknown apps for the browser. Prefer adb once CAR_HOST is set."
  cd "$APK_DIR"
  ln -sf "$(basename "$CAR_APK")" "InteractTalk-car-latest.apk" 2>/dev/null || cp "$CAR_APK" InteractTalk-car-latest.apk
  exec python3 -c "
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
os.chdir('${APK_DIR}')
class H(SimpleHTTPRequestHandler):
    extensions_map = {**getattr(SimpleHTTPRequestHandler, 'extensions_map', {}),
                      '.apk': 'application/vnd.android.package-archive'}
ThreadingHTTPServer(('0.0.0.0', ${WIFI_PORT_CAR}), H).serve_forever()
"
fi

echo ""
echo "==> [3/4] flutter build apk --release --split-per-abi"
# split-per-abi gives us 3 smaller APKs (arm64-v8a, armeabi-v7a, x86_64)
# so the A23 (arm64) and Bravia (armv7) each get the right one.
flutter build apk --release --split-per-abi

ARM64="$APK_DIR/app-arm64-v8a-release.apk"
ARMV7="$APK_DIR/app-armeabi-v7a-release.apk"

if [[ ! -f "$ARM64" ]]; then
  echo "❌ arm64 APK not found at $ARM64"
  exit 1
fi
if [[ ! -f "$ARMV7" ]]; then
  echo "❌ armv7 APK not found at $ARMV7 (needed for Bravia)"
  exit 1
fi

SIZE_ARM64="$(du -h "$ARM64" | cut -f1)"
SIZE_ARMV7="$(du -h "$ARMV7" | cut -f1)"
echo "✅ arm64-v8a APK ($SIZE_ARM64): $ARM64"
echo "✅ armeabi-v7a APK ($SIZE_ARMV7): $ARMV7"

case "$target" in
  build)
    echo ""
    echo "==> [4/4] Build only — no install. Pass a23, phoneb, tv, or all to install."
    ;;
  a23)
    echo ""
    echo "==> [4/4] adb install on A23 (USB, serial $A23_SERIAL) — arm64"
    adb -s "$A23_SERIAL" install -r "$ARM64"
    ;;
  phoneb|v7a)
    # 32-bit Redmi / Phone B — install the FIRST USB device that reports
    # armeabi-v7a as primary (or any connected device if only one).
    echo ""
    echo "==> [4/4] adb install armeabi-v7a on USB device (32-bit Phone B)"
    SERIAL="$(adb devices | awk '/device$/{print $1; exit}')"
    [[ -n "$SERIAL" ]] || { echo "❌ no adb device — plug Phone B / enable Install via USB (MIUI)"; exit 1; }
    ABI="$(adb -s "$SERIAL" shell getprop ro.product.cpu.abilist | tr -d '\r')"
    echo "    device=$SERIAL abi=$ABI"
    if [[ "$ABI" == arm64-v8a* ]] && [[ "$ABI" != *armeabi-v7a* ]]; then
      echo "⚠️  device looks arm64-only — still installing v7a (won't run optimally)"
    fi
    if [[ "$ABI" == armeabi-v7a* ]] || [[ "$ABI" == *armeabi-v7a* && "$ABI" != arm64* ]]; then
      echo "    ✅ 32-bit device → using $ARMV7"
    elif [[ "$ABI" == arm64-v8a* ]]; then
      echo "    ℹ️  arm64 device detected — prefer 'a23' target; installing v7a anyway as requested"
    fi
    adb -s "$SERIAL" install -r "$ARMV7" || {
      echo "❌ install failed. MIUI: enable Developer options → Install via USB (Mi account online),"
      echo "   USB debugging (Security settings), disable MIUI optimization; then retry."
      exit 1
    }
    ;;
  tv)
    echo ""
    echo "==> [4/4] adb install on Bravia TV ($TV_HOST)"
    adb connect "$TV_HOST" || true
    adb -s "$TV_HOST" install -r "$ARMV7"
    ;;
  car|headunit|hu)
    echo ""
    if [[ -z "$CAR_HOST" ]]; then
      echo "❌ CAR_HOST not set. Copy .device-env.example → .device-env and set CAR_HOST=<ip>:5555"
      echo "   Or use: bash build-and-install.sh car-wifi"
      exit 1
    fi
    echo "==> [4/4] adb install on car head unit ($CAR_HOST) — armeabi-v7a"
    adb connect "$CAR_HOST" || true
    ABI="$(adb -s "$CAR_HOST" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || true)"
    echo "    abi=$ABI"
    adb -s "$CAR_HOST" install -r "$ARMV7"
    ;;
  all)
    echo ""
    echo "==> [4a/4] adb install on A23"
    adb -s "$A23_SERIAL" install -r "$ARM64"
    echo ""
    echo "==> [4b/4] adb install on Bravia TV"
    adb connect "$TV_HOST" || true
    adb -s "$TV_HOST" install -r "$ARMV7"
    ;;
  *)
    echo "❌ Unknown target '$target' — use: build | a23 | phoneb | tv | car | car-wifi | wifi | all"
    exit 1
    ;;
esac

echo ""
echo "✅ Done."
