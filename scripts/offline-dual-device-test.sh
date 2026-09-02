#!/usr/bin/env bash
# Build Talk 6056+ on iPhone + Samsung and print offline dual-device test steps.
# Run in Terminal.app:
#   bash ~/dev/INTERACT/apps/interact-app/scripts/offline-dual-device-test.sh
#   bash ~/dev/INTERACT/apps/interact-app/scripts/offline-dual-device-test.sh install
set -euo pipefail
export PATH="$HOME/flutter/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IPHONE="${IPHONE_ID:-00008101-001A3CE400E1401E}"
SAMSUNG="${SAMSUNG_SERIAL:-R68T304FX1F}"
VER="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"

echo "════════════════════════════════════════════════════════"
echo "  INTERACT Talk offline RF test — build $VER"
echo "  Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
echo "════════════════════════════════════════════════════════"

echo ""
echo "==> flutter pub get + analyze"
flutter pub get
flutter analyze --no-pub --no-fatal-warnings --no-fatal-infos

if [[ "${1:-}" == "install" ]]; then
  echo ""
  echo "==> Android arm64 → Samsung ($SAMSUNG)"
  flutter build apk --release --target-platform android-arm64
  adb -s "$SAMSUNG" install -r build/app/outputs/flutter-apk/app-release.apk

  echo ""
  echo "==> iOS → Paksaf ($IPHONE)"
  (cd ios && pod install)
  flutter build ios --release
  flutter install --release -d "$IPHONE" || {
    echo "flutter install failed — try: flutter run --release -d $IPHONE"
  }
else
  echo ""
  echo "==> Android split APK (arm64 + v7a for car HU / Samsung)"
  flutter build apk --release --split-per-abi
  echo "    arm64: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
  echo "    v7a:   build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk"
  echo ""
  echo "Skip iOS build here (slow). For iPhone:"
  echo "  cd ios && pod install && cd .."
  echo "  flutter build ios --release && flutter install --release -d $IPHONE"
fi

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo '?')"

cat <<EOF

════════════════════════════════════════════════════════
  OFFLINE TEST — both devices (after install)
════════════════════════════════════════════════════════

Prep (both phones):
  1. Same Wi‑Fi SSID (this Mac LAN: $LAN_IP)
  2. Airplane mode ON → Wi‑Fi ON (no cellular data)
  3. iPhone: Settings → INTERACT → Local Network ON
  4. Me → Field validation — open checklist RF-* cases

A. LAN text (RF-LAN-1) — Android↔iPhone OK
  • Both: Me → Offline comms hub → Same Wi‑Fi (LAN)
  • Wait for peer chips (~10–30s)
  • Select peer → send "offline ping" both ways
  • PASS if round-trip < 5s each way

B. LAN walkie (RF-WALKIE-1) — Samsung hosts
  • Samsung: Me → Nearby Wi‑Fi walkie → Host WALKIE1 → Open channel
  • Note host IP:port on screen (Copy for joiner)
  • iPhone: join from list OR Join by IP (mDNS blocked)
  • Speak both ways — PASS if audio < 2s one-way

C. LAN walkie reverse (RF-WALKIE-2) — iPhone hosts
  • Swap roles; use manual IP if iPhone discovery empty

D. Full offline matrix (RF-OFFLINE-1)
  • Confirm cloud chat/calls fail (expected)
  • LAN text + walkie still work

Debug:
  • Xcode / adb logcat: filter lan-walkie, lan-walkie, Bonsoir
  • Host log: "[lan-walkie] (2 in room)" when 2nd peer joins

Doc: docs/OFFLINE_DUAL_DEVICE_TEST_2026-09-01.md
EOF
