# Talk phone E2E — admin run sheet (2026-07-27 morning retest)

**Device:** SM-A235F (`R68T304FX1F`) · **APK:** `0.5.1+2021`  
**Fix shipped in 2021:** `TalkRoomToken` unwraps Sahulat `ok({data})` (Voice-only Null cast).

## A — Install / launch

| Step | Result |
|------|--------|
| Install `+2021` + launch | **PASS** |
| Login (after unlock + OTP) | **PASS** |

## B — Single-phone (admin) — this run

| # | Feature | Result | Notes |
|---|---------|--------|-------|
| B1 | Login | **PASS** | |
| B2 | Field validation + FCM | **PASS** | Token green |
| B3 | Nearby devices | **PASS** | BLE scan lists devices |
| B4 | Camera effects | **PASS** | |
| B5 | Voice-only meeting | **PASS*** | Null cast **gone**. Mic on / cam off. Shows **Connecting…** until peer joins (solo host). |
| B6 | Captions admin | ☐ HUMAN | Use LiveKit townhall (not 1:1 mesh) |
| B7 | Captions non-admin | ☐ HUMAN | Second account |
| B8 | Disappearing | **PASS** | Timer UI in chat |
| B9 | LoRa UI | **PASS** | |
| B10 | Meshtastic UI | **PASS** | |

\*B5: improve later if host should show “Waiting for guest” instead of endless Connecting when alone.

## C / D — need Phone B

| Rows | Status |
|------|--------|
| C1–C6 RF-BLE / LAN / FCM / LoRa E2E | ☐ BLOCKED |
| D2–D4 call / townhall 2+ | ☐ HUMAN |

## Next on device

Phone left at **Me → Field validation** when possible.  
Bring **Phone B** (same APK) → RF-BLE-1 @1m → mark PASS/FAIL.

## After FAIL rows

Harden only those. Do not rewrite `sahl_mesh` / `lan_service` on PASS.
