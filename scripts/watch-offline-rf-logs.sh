#!/usr/bin/env bash
# Watch Talk offline RF logs while you test on two phones (run in Terminal.app).
# Usage:
#   bash scripts/watch-offline-rf-logs.sh
# Then on phones: airplane+Wi‑Fi → Offline hub → LAN / walkie test.
set -euo pipefail

SAMSUNG="${SAMSUNG_SERIAL:-R68T304FX1F}"
IPHONE="${IPHONE_ID:-00008101-001A3CE400E1401E}"

echo "Watching lan-walkie / Bonsoir / flutter logs…"
echo "Samsung serial: $SAMSUNG"
echo "Tap through RF-LAN-1 and RF-WALKIE-1 on both phones."
echo "Ctrl+C to stop."
echo ""

if adb devices 2>/dev/null | grep -q "$SAMSUNG"; then
  echo "── Samsung logcat (filtered) ──"
  adb -s "$SAMSUNG" logcat -c 2>/dev/null || true
  adb -s "$SAMSUNG" logcat 2>/dev/null | grep -iE 'lan-walkie|bonsoir|flutter|interact' &
  SAM_PID=$!
else
  echo "Samsung not on USB — skip logcat"
  SAM_PID=
fi

if command -v idevicesyslog >/dev/null 2>&1; then
  echo "── iPhone syslog (filtered) ──"
  idevicesyslog 2>/dev/null | grep -iE 'lan-walkie|bonsoir|flutter|interact|Runner' &
  IOS_PID=$!
else
  echo "idevicesyslog not found — iPhone logs: Xcode → Window → Devices → Open Console"
  IOS_PID=
fi

trap '[[ -n "${SAM_PID:-}" ]] && kill $SAM_PID 2>/dev/null; [[ -n "${IOS_PID:-}" ]] && kill $IOS_PID 2>/dev/null; exit 0' INT TERM

wait
