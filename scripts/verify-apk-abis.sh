#!/usr/bin/env bash
# Fail if an APK is missing a required native ABI (Phone B / 32-bit guard).
#
# Usage:
#   bash scripts/verify-apk-abis.sh path/to.apk
#   bash scripts/verify-apk-abis.sh path/to.apk --require-fat   # both phone ABIs
#
# Exit 0 = OK, 1 = missing ABI / bad file.
set -euo pipefail

APK="${1:-}"
MODE="${2:-}"
[[ -n "$APK" && -f "$APK" ]] || { echo "usage: $0 <apk> [--require-fat]"; exit 1; }

LIST="$(unzip -l "$APK" 2>/dev/null | awk '{print $4}' || true)"
has() { echo "$LIST" | grep -q "$1"; }

echo "==> ABI check: $APK ($(du -h "$APK" | cut -f1))"
ABIS="$(echo "$LIST" | grep '^lib/' | cut -d/ -f2 | sort -u | tr '\n' ' ')"
echo "    present: ${ABIS:-"(none)"}"

if [[ "$MODE" == "--require-fat" ]]; then
  ok=1
  has 'lib/armeabi-v7a/libflutter.so' || { echo "❌ missing lib/armeabi-v7a/libflutter.so (32-bit Phone B will crash)"; ok=0; }
  has 'lib/arm64-v8a/libflutter.so' || { echo "❌ missing lib/arm64-v8a/libflutter.so"; ok=0; }
  [[ "$ok" == "1" ]] || exit 1
  # Heuristic: arm64-only "universal" was ~127–133 MB; fat phone dual-ABI is larger.
  BYTES="$(stat -f%z "$APK" 2>/dev/null || stat -c%s "$APK")"
  if [[ "$BYTES" -lt 140000000 ]]; then
    echo "⚠️  size ${BYTES} bytes looks small for a fat dual-ABI APK (<140 MB)."
    echo "    Double-check before publishing to downloads.interactpak.com."
  fi
  echo "✅ fat phone APK OK (armeabi-v7a + arm64-v8a)"
  exit 0
fi

# Single-ABI splits: must contain exactly one of the phone ABIs' libflutter.
if has 'lib/armeabi-v7a/libflutter.so'; then
  echo "✅ armeabi-v7a split OK"
  exit 0
fi
if has 'lib/arm64-v8a/libflutter.so'; then
  echo "✅ arm64-v8a split OK"
  exit 0
fi
echo "❌ no libflutter.so for armeabi-v7a or arm64-v8a"
exit 1
