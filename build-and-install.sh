#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# INTERACT — build the release APK and (optionally) install it.
#
# Usage:
#   bash build-and-install.sh             # build only
#   bash build-and-install.sh a23         # build + install on A23 (USB)
#   bash build-and-install.sh tv          # build + install on Bravia TV (LAN)
#   bash build-and-install.sh all         # build + install on both
#   bash build-and-install.sh wifi        # build a UNIVERSAL apk + serve over Wi-Fi
#                                         #   (for phones where USB ADB won't work,
#                                         #    e.g. MIUI). Installs on ANY ABI.
#
# 2026-05-21 — adds Private AI toggle + ✨ AI menu wiring. Cloud AI
# tier routes through interactpak.com/api/zeka/ai; on-device tier
# stays stubbed pending Phase 3 llama_cpp_dart binding.

set -euo pipefail
cd "$(dirname "$0")"

# Devices (per memory: dev_lan_setup.md)
A23_SERIAL="R68T304FX1F"
TV_HOST="192.168.100.4:5555"

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
  echo "==> [3/4] flutter build apk --release  (universal — all ABIs)"
  # Clear any stale generic artefact first so nothing old can be served.
  rm -f "$APK_DIR/app-release.apk"
  flutter build apk --release
  UNIVERSAL="$APK_DIR/app-release.apk"
  [[ -f "$UNIVERSAL" ]] || { echo "❌ universal APK not found at $UNIVERSAL"; exit 1; }
  SIDELOAD="$APK_DIR/InteractTalk-${VER}.apk"
  cp "$UNIVERSAL" "$SIDELOAD"
  echo "✅ universal APK: $SIDELOAD ($(du -h "$SIDELOAD" | cut -f1))"

  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  echo ""
  echo "==> [4/4] Serving over Wi-Fi on :8765"
  echo "    On the phone (same Wi-Fi) open:"
  echo "      http://${LAN_IP:-<your-mac-ip>}:8765/InteractTalk-${VER}.apk"
  echo "    (Ctrl+C to stop the server when the download completes.)"
  cd "$APK_DIR"
  # Bind IPv4 explicitly (Pattern 11) — default [::] confuses some MIUI browsers.
  exec python3 -c "
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
class H(SimpleHTTPRequestHandler):
    extensions_map = {**getattr(SimpleHTTPRequestHandler, 'extensions_map', {}),
                      '.apk': 'application/vnd.android.package-archive'}
ThreadingHTTPServer(('0.0.0.0', 8765), H).serve_forever()
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
    echo "==> [4/4] Build only — no install. Pass a23, tv, or all to install."
    ;;
  a23)
    echo ""
    echo "==> [4/4] adb install on A23 (USB, serial $A23_SERIAL)"
    adb -s "$A23_SERIAL" install -r "$ARM64"
    ;;
  tv)
    echo ""
    echo "==> [4/4] adb install on Bravia TV ($TV_HOST)"
    adb connect "$TV_HOST" || true
    adb -s "$TV_HOST" install -r "$ARMV7"
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
    echo "❌ Unknown target '$target' — use: build | a23 | tv | all | wifi"
    exit 1
    ;;
esac

echo ""
echo "✅ Done."
