#!/usr/bin/env bash
# Build a fat dual-ABI release APK, verify ABIs, upload to downloads.interactpak.com.
#
# Usage (from interact-app/):
#   bash scripts/publish-ota.sh
#   SKIP_BUILD=1 bash scripts/publish-ota.sh   # re-upload existing app-release.apk
#
# Requires: flutter, unzip, scp/ssh to `interact`, write access to
# /var/www/downloads/interact/ on the VPS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HOST="${HETZNER_HOST:-interact}"
REMOTE_DIR="${REMOTE_DIR:-/var/www/downloads/interact}"
APK_DIR="build/app/outputs/flutter-apk"
VER_LINE="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}')"
VER_NAME="${VER_LINE%%+*}"
VER_CODE="${VER_LINE##*+}"
FAT_NAME="interact-${VER_NAME}-${VER_CODE}.apk"
FAT_PATH="$APK_DIR/app-release.apk"
V7A_PATH="$APK_DIR/app-armeabi-v7a-release.apk"
ARM64_PATH="$APK_DIR/app-arm64-v8a-release.apk"

# --dart-define values baked into EVERY build below (fat + splits) so the
# released APKs carry the CRM pepper etc. Values are hex/flags (no spaces),
# so unquoted word-splitting of $DEFINES is safe on macOS bash 3.2.
DEFINES=""
[[ -n "${CRM_RESOLVE_PEPPER:-}" ]] && DEFINES="$DEFINES --dart-define=CRM_RESOLVE_PEPPER=$CRM_RESOLVE_PEPPER"
[[ "${TALK_LK_CALLS:-0}" == "1" ]] && DEFINES="$DEFINES --dart-define=TALK_LK_CALLS=1"
echo "==> dart-defines:${DEFINES:- (none)}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> flutter build apk --release (fat: v7a+arm64 via abiFilters)"
  rm -f "$FAT_PATH"
  flutter build apk --release $DEFINES
fi

[[ -f "$FAT_PATH" ]] || { echo "❌ missing $FAT_PATH"; exit 1; }
bash scripts/verify-apk-abis.sh "$FAT_PATH" --require-fat

# Also build splits for explicit Phone B / A23 USB installs.
# SPLIT_PER_ABI=1 clears ndk.abiFilters (Gradle conflict with ABI splits).
# app/build.gradle.kts forces versionCodeOverride = pubspec +N on splits so
# OTA isn't poisoned by Flutter's default abi*1000+N (arm64→8xxx).
echo "==> flutter build apk --release --split-per-abi"
SPLIT_PER_ABI=1 flutter build apk --release --split-per-abi $DEFINES
bash scripts/verify-apk-abis.sh "$V7A_PATH"
bash scripts/verify-apk-abis.sh "$ARM64_PATH"
# Guard: split versionCode must match fat / pubspec (Gotcha #67b).
AAPT_BIN="$(ls "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1 || true)"
if [[ -n "$AAPT_BIN" ]]; then
  code_of() { "$AAPT_BIN" dump badging "$1" | sed -n "s/.*versionCode='\\([^']*\\)'.*/\\1/p" | head -1; }
  FAT_CODE="$(code_of "$FAT_PATH")"
  ARM64_CODE="$(code_of "$ARM64_PATH")"
  V7A_CODE="$(code_of "$V7A_PATH")"
  echo "==> versionCode check: fat=$FAT_CODE arm64=$ARM64_CODE v7a=$V7A_CODE (expect ${VER_CODE})"
  if [[ "$FAT_CODE" != "$VER_CODE" || "$ARM64_CODE" != "$VER_CODE" || "$V7A_CODE" != "$VER_CODE" ]]; then
    echo "❌ Split/fat versionCode mismatch — refusing to publish (OTA would break)."
    exit 1
  fi
fi

SHA="$(shasum -a 256 "$FAT_PATH" | awk '{print $1}')"
BYTES="$(stat -f%z "$FAT_PATH" 2>/dev/null || stat -c%s "$FAT_PATH")"
RELEASED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
CHANGELOG="${OTA_CHANGELOG:-Talk ${VER_NAME}+${VER_CODE}: in-app auto-update (default ON) + fat dual-ABI.}"

echo "==> Upload to ${HOST}:${REMOTE_DIR}/"
scp "$FAT_PATH" "${HOST}:${REMOTE_DIR}/${FAT_NAME}"
scp "$FAT_PATH" "${HOST}:${REMOTE_DIR}/InteractTalk.apk"
scp "$V7A_PATH" "${HOST}:${REMOTE_DIR}/interact-${VER_NAME}-${VER_CODE}-armeabi-v7a.apk"
scp "$ARM64_PATH" "${HOST}:${REMOTE_DIR}/interact-${VER_NAME}-${VER_CODE}-arm64-v8a.apk"

ssh "$HOST" "cat > ${REMOTE_DIR}/latest.json <<EOF
{
  \"version_name\": \"${VER_NAME}\",
  \"version\": \"${VER_NAME}\",
  \"version_code\": ${VER_CODE},
  \"apk_url\": \"https://downloads.interactpak.com/interact/${FAT_NAME}\",
  \"apk_url_armeabi_v7a\": \"https://downloads.interactpak.com/interact/interact-${VER_NAME}-${VER_CODE}-armeabi-v7a.apk\",
  \"apk_url_arm64_v8a\": \"https://downloads.interactpak.com/interact/interact-${VER_NAME}-${VER_CODE}-arm64-v8a.apk\",
  \"sha256\": \"${SHA}\",
  \"size_bytes\": ${BYTES},
  \"required_abis\": [\"armeabi-v7a\", \"arm64-v8a\"],
  \"released_at\": \"${RELEASED_AT}\",
  \"changelog\": \"${CHANGELOG}\",
  \"notes\": \"${CHANGELOG}\",
  \"force_update\": false
}
EOF"

echo "==> Verify CDN"
curl -sS https://downloads.interactpak.com/interact/latest.json
echo ""
echo "✅ OTA published: ${FAT_NAME} (${BYTES} bytes) sha256=${SHA}"
echo "   Phone B (32-bit): use apk_url (fat) OR apk_url_armeabi_v7a"
