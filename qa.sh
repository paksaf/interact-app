#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0
#
# QA bridge — lets the (remote) agent "see" Phone A by capturing screenshots +
# logcat into $HOME/dev/INTERACT (a folder the agent can read). Run on the Mac
# with Phone A on cable.
#
# Usage:
#   bash qa.sh setup                 # grant runtime perms + (re)launch app, clear log
#   bash qa.sh cap <label>           # screenshot + logcat snapshot → _qa/<label>.{png,log}
#   bash qa.sh log <label>           # logcat snapshot only (for ring/call/attach repros)
#   bash qa.sh watch                 # stream live logcat to the terminal (Ctrl+C to stop)
#
# Typical run:
#   bash qa.sh setup
#   # …do a step on the phone (e.g. open a chat)…
#   bash qa.sh cap chat-open
#   # …tap the 📎 attach + pick a photo…
#   bash qa.sh cap attach-photo
#   …then tell the agent: "captured chat-open, attach-photo" — it reads _qa/*.
set -euo pipefail
cd "$(dirname "$0")"

SERIAL="${A23_SERIAL:-R68T304FX1F}"     # Phone A (cable). Override: A23_SERIAL=xxx bash qa.sh …
APPID="com.interactpak.interact_talk"
OUT="_qa"
mkdir -p "$OUT"
ADB=(adb -s "$SERIAL")

cmd="${1:-}"; label="${2:-snap}"
ts() { date +%H%M%S; }

case "$cmd" in
  setup)
    echo "==> device:"; "${ADB[@]}" get-state || { echo "Phone A not found ($SERIAL). Check cable / adb devices."; exit 1; }
    echo "==> granting runtime permissions (ignore any 'not a changeable perm')"
    for p in \
      android.permission.CAMERA \
      android.permission.RECORD_AUDIO \
      android.permission.POST_NOTIFICATIONS \
      android.permission.READ_MEDIA_IMAGES \
      android.permission.READ_MEDIA_VIDEO \
      android.permission.READ_MEDIA_AUDIO \
      android.permission.ACCESS_FINE_LOCATION \
      android.permission.READ_CONTACTS ; do
      "${ADB[@]}" shell pm grant "$APPID" "$p" 2>/dev/null || true
    done
    "${ADB[@]}" logcat -c || true
    "${ADB[@]}" shell monkey -p "$APPID" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
    echo "==> launched $APPID, log cleared. Now drive the phone + use 'cap <label>'."
    ;;
  cap)
    png="$OUT/${label}.png"
    "${ADB[@]}" exec-out screencap -p > "$png"
    "${ADB[@]}" logcat -d 2>/dev/null | grep -iE "flutter|interact|fatal|exception|baileys|otp|permission|mediaupload|room|livekit|webrtc|fcm|notif" | tail -160 > "$OUT/${label}.log" || true
    echo "saved $png + $OUT/${label}.log  ($(date))"
    ;;
  log)
    "${ADB[@]}" logcat -d 2>/dev/null | grep -iE "flutter|interact|fatal|exception|baileys|otp|room|livekit|webrtc|fcm|notif|call" | tail -200 > "$OUT/${label}.log" || true
    echo "saved $OUT/${label}.log"
    ;;
  watch)
    "${ADB[@]}" logcat | grep -iE "flutter|interact|fatal|exception|room|livekit|webrtc|fcm|notif|call|otp"
    ;;
  *)
    echo "usage: bash qa.sh {setup|cap <label>|log <label>|watch}"; exit 1;;
esac
