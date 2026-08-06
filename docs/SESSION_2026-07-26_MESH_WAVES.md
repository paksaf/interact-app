# Session handoff — Talk mesh / phone E2E / voice-first (2026-07-26)

**Saved:** 2026-07-26 evening · **APK on Phone A:** `0.5.1+2020` · **Device:** SM-A235F (`R68T304FX1F`)

## Resume next session with

1. Open [`FIELD_VALIDATION_AND_BACKLOG_2026-07-26.md`](./FIELD_VALIDATION_AND_BACKLOG_2026-07-26.md) + [`PHONE_E2E_ADMIN_RUNSHEET_2026-07-26.md`](./PHONE_E2E_ADMIN_RUNSHEET_2026-07-26.md)
2. Phone B same build → mark RF-BLE / RF-LAN / FCM rows
3. Harden **only** FAIL rows — do **not** rewrite `sahl_mesh` / `lan_service`

Presentation: `/Users/muzafar/Documents/INTERACT/Presentations/InteractTalk_Feature_Catalog_2026-07-24.{html,pptx}`  
Rebuild: `Presentations/build_interact_talk_catalog_pptx.py`  
Release build tip: `bash scripts/patch-livekit-visualizer.sh` then `flutter build apk --release`

---

## Waves shipped (code)

| Wave | Scope | Entry |
|------|--------|--------|
| **1** | Outbox, Offline LAN, BLE mesh, camera gate, captions overlay, presence | Me → Offline LAN / Nearby mesh |
| **1b** | Offline LAN Direct (same-OS) | Offline LAN → Direct |
| **2** | Virtual BG Android publish, speaker/pin/pulse | Townhall live room |
| **3** | Nearby BLE devices status | Me → Nearby devices |
| **4** | LoRa ADR + firmware + Talk attach `InteractLoRaBridge` | Me → LoRa bridge |

## Engineering completed this session

| Item | Result |
|------|--------|
| FBP → OSS BLE | **Done** — Talk + `sahl_mesh` on `flutter_reactive_ble`; FBP removed |
| Mesh FGS keep-alive | **Done** — Maps-style `connectedDevice` FGS |
| LAN wakelock | **Done** — Offline LAN |
| Field validation UI | **Done** — Me → Field validation `/field-validation` |
| LoRa ping + Meshtastic GATT | **Done** — connect/handshake; MeshPacket text TX still open |
| Disappearing messages | **Done** — QS PATCH + thread banner |
| Captions ops | **Done** — Deepgram + agent on VPS; admin gate; health OK |
| WhatsApp/SMS/Email login tiles | **Done** — Weather-style channel UI |
| Voice-first LiveKit | **Done** — mic on / cam off on join (`LiveJoin.voiceFirst`) |
| LiveKit release compile | **Done** — `scripts/patch-livekit-visualizer.sh` (bands init) |
| Phone install | **Done** — release `0.5.1+2020` on SM-A235F; FCM register 201 |
| Feature catalog deck | **Done** — HTML + PPTX updated (equipment + voice-first + changelog) |
| RF/commercial docs | **Done** — `COMMERCIAL_DEPS_AND_RF_PK.md` (PTA/BLE/Wi‑Fi; LoRa postpone; no FBP buy) |

## Ops / equipment (verified)

| Item | Status |
|------|--------|
| LiveKit SFU `wss://livekit.interactpak.com` | **active** (`livekit-server`) |
| caption-agent `:8097` + Deepgram | **configured:true** (node under `/srv/interact-caption-agent`) |
| Voice-first client | **enabled** (townhall Speaker = “Mic first”) |
| Phone A admin | Talk `0.5.1+2020` · FCM token green |
| Phone B | **still needed** for RF / FCM prove |
| LoRa hardware | optional |
| LiveKit Cloud survey | not required for Talk (self-host) |

## Honest limits

- Direct P2P: same-OS only
- LoRa E2E: needs 2× `InteractLoRaBridge` (Nordic UART UUIDs — not fake UUIDs)
- Meshtastic: GATT OK; text TX not done
- Virtual BG peer publish: Android; iOS/web preview
- FCM kill-app 2-device: not yet proved in field
- Do not rewrite `sahl_mesh` gossip as GATT mesh; do not buy FBP unless migrate regresses

## Open (human / next eng)

| Priority | Task |
|----------|------|
| P0 | Field matrix RF-BLE-1…3 / RF-LAN with Phone B → PASS/FAIL in Field validation |
| P0 | Harden only FAIL rows |
| P1 | FCM kill-app ring A→B |
| P1 | Townhall captions prove as admin |
| P1 | LoRa-1 if hardware available |
| P2 | Meshtastic MeshPacket text TX |
| P2 | Publish OTA `latest.json` to `2019+` / `2020` if fleet should auto-update |

## Key paths

| Area | Path |
|------|------|
| Talk app | `/Users/muzafar/Documents/INTERACT/interact-app` |
| Mesh package | `/Users/muzafar/Documents/INTERACT/sahl_mesh` (reactive_ble) |
| Caption agent | VPS `/srv/interact-caption-agent` · QS captions admin |
| Field UI | `lib/screens/debug/field_validation_screen.dart` |
| Voice-first | `lib/services/livekit_service.dart` + `live_api.dart` (`voiceFirst`) |
| LoRa GATT | Service `6e400001-…` · name `InteractLoRaBridge` |
| Docs | `docs/FIELD_*` · `COMMERCIAL_*` · `PHONE_E2E_*` · this file |

## Explicit non-goals

- Greenfield mesh/LAN rewrite
- Wrong LoRa UUIDs / `LoRa_Bridge` rename
- Buying flutter_blue_plus unless field proves reactive_ble regression
- Treating LiveKit Cloud welcome survey as required for production Talk
