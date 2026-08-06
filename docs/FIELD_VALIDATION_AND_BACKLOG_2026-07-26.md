# InteractTalk — Field validation + backlog (corrected)

**Date:** 2026-07-26  
**Purpose:** Executable plan for Pakistan field validation and backlog — aligned with **shipped** Talk code.  
**Supersedes:** Generic “Cursor AI prompt” snippets that invent APIs, wrong LoRa UUIDs, or rewrite `sahl_mesh` / `lan_service.dart`.

---

## Reality check (do not re-implement)

| Prompt idea | Talk truth | Action |
|-------------|------------|--------|
| Fake `sahlMesh.connectToNearbyDevice()` | Mesh is **adv/scan gossip** via `sahl_mesh` + Me → **Nearby mesh** | Test via UI; no greenfield GATT mesh |
| Fake `lanService.discoverServices()` API | `lan_service.dart` Bonsoir `_interact-lan._tcp` + TCP; Me → **Offline LAN** | Test via UI |
| “No Wi‑Fi Direct for v1” | **Already shipped:** Offline LAN → **Direct** (`p2p_service.dart`) | Optional field case; same-OS only |
| New LoRa UUIDs `12345678-…` / name `LoRa_Bridge` | Firmware + Talk use Nordic UART + **`InteractLoRaBridge`** | **Do not** flash conflicting sketches |
| Put LoRaBridge in `sahl_mesh` + `flutter_reactive_ble` | Talk has `lora_bridge_service.dart` + Me → **LoRa bridge** | Extend attach only if Meshtastic later; don’t fork mesh |
| Rewrite `sahl_mesh` / `lan_service` | Explicit non-goal | Harden **only** after field failures |

**Phone-only v1** = BLE mesh + Same Wi‑Fi LAN (+ optional Direct). **LoRa** = optional hardware path after phone RF proves out.

---

## P0 — Field-test Wave-1 (BLE / LAN)

### Entry points (real)

| Transport | Screen | Route / path |
|-----------|--------|----------------|
| BLE gossip | Me → Nearby mesh | `/nearby-mesh` |
| Same Wi‑Fi LAN | Me → Offline LAN → Same Wi‑Fi | `/offline-lan` |
| Direct (optional) | Me → Offline LAN → Direct | same screen, Direct tab |
| Nearby devices (status) | Me → Nearby devices | `/nearby-devices` |

### Test matrix

| ID | Transport | Scenario | Devices | Success | Result |
|----|-----------|----------|---------|---------|--------|
| RF-BLE-1 | BLE mesh | 2 Android, ~1 m | 2 phones | Text arrives &lt;3 s, no crash | ☐ |
| RF-BLE-2 | BLE mesh | 2 Android, ~50 m LOS | 2 phones | Arrives &lt;10 s or document fail | ☐ |
| RF-BLE-3 | BLE mesh | 3 Android gossip | 3 phones | All see message &lt;15 s; note dupes | ☐ |
| RF-LAN-1 | Same Wi‑Fi | 2 phones, AP only (no internet) | 2 phones | Text &lt;1–2 s | ☐ |
| RF-LAN-2 | Same Wi‑Fi | 3 phones broadcast | 3 phones | All receive; note dupes | ☐ |
| RF-P2P-1 | Direct | 2 Android only | 2 phones | Optional; same-OS | ☐ |
| RF-IOT-1 | Nearby devices | Scan 30 s | 1 phone | Names/RSSI/last-seen populate | ☐ |

### Manual script (QA — no fake Dart)

**BLE (RF-BLE-1)**

1. Install same Talk build on Phone A + B; grant Bluetooth / Nearby / Location.
2. Both: Me → **Nearby mesh** → wait until status shows started (not “starting…”).
3. A: send short text (e.g. `ping-ble-1`).
4. B: confirm row appears with payload (app prefixes `talk:` on wire).
5. Record wall-clock and any permission / background kills.

**LAN (RF-LAN-1)**

1. Both on same SSID; disable mobile data if needed.
2. Me → **Offline LAN** → Same Wi‑Fi → start/advertise.
3. Confirm peer appears; send text both ways.
4. Record latency and Bonsoir discovery failures.

**Do not** “fix” Bloom/TTL or Bonsoir before a failing row is filled above.

### Expected issues → only after reproduce

| Symptom | Likely cause | Next step |
|---------|--------------|-----------|
| Scan empty | Runtime BT permissions | Confirm Android 12+ `BLUETOOTH_SCAN/CONNECT` + location |
| Stops in background | OEM power save | Document OEM; consider FG service **only if** field proves need |
| LAN no peers | Different VLAN / AP isolation | Test on open guest AP; check Bonsoir logs |
| Duplicate mesh lines | Normal gossip / Bloom edge | Note rate; harden in `sahl_mesh` only if noisy |

---

## P0 — `flutter_blue_plus` license

### Evidence of commercial use

Talk (`interact-app`) path-depends / declares:

- `sahl_mesh` → `flutter_blue_plus`
- Direct deps: Nearby devices + LoRa bridge services also import FBP

INTERACT Talk is a **for-profit** product → upstream commercial license terms apply unless nonprofit exception is negotiated.

### Decision (owner: Legal / product — due **2026-07-28**)

| Option | When | Work |
|--------|------|------|
| **A. Buy** commercial license | Prefer if budget OK; keeps current gossip stack | Purchase; record invoice path in this doc |
| **B. Migrate scan/central** | If buy refused | In **`sahl_mesh` only**: swap central/scan to `flutter_reactive_ble`; keep `flutter_ble_peripheral` advertise. Talk UI unchanged. **Not** a GATT connect/write mesh rewrite |
| **C. Defer** | Ship internal-only builds | Document risk; do not publish Play store until A or B |

**Recommendation:** Decide **A vs B by 2026-07-28**. Do **not** start migrate mid field-test unless Legal refuses buy. Talk LoRa/Nearby can stay on FBP until `sahl_mesh` migration lands (then align those two services).

**Parity tests if migrating:** RF-BLE-1…3 must pass on migrated branch vs current.

---

## P1 — LoRa E2E (optional hardware)

### Use shipped stack only

```
Phone A ──BLE──> InteractLoRaBridge ──LoRa──> InteractLoRaBridge ──BLE──> Phone B
```

| Item | Value |
|------|--------|
| Adv name | `InteractLoRaBridge` |
| Service | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| RX (phone write) | `6e400002-…` |
| TX (notify) | `6e400003-…` |
| Firmware | `firmware/lora_ble_bridge/lora_ble_bridge.ino` |
| Talk UI | Me → **LoRa bridge** `/lora-bridge` |

**Reject** any sketch named `LoRa_Bridge` or UUIDs `12345678-1234-…`.

### Hardware BOM (DIY)

| Part | Qty | Notes |
|------|-----|--------|
| ESP32 Dev | 2 | BLE + SPI |
| RA-02 / SX127x | 2 | Match freq both boards (`LORA_FREQ` 915E6 PK) |
| Antenna | 2 | Improves range |
| USB power / bank | 2 | Portable |

Alt: 2× Meshtastic T-Echo/T-Beam — adapter is **P2 backlog** (not required for DIY E2E).

### Runbook

1. Flash both ESP32 with `lora_ble_bridge.ino` (same `LORA_FREQ`).
2. Phone A + B: Me → LoRa bridge → Scan → connect to each bridge.
3. A: send UTF-8 line; B: see notify log within **10 s** at ~1 km open (LoRa-1).
4. Fill results below; do **not** multi-hop firmware until LoRa-1 passes.

| ID | Scenario | Success | Result |
|----|----------|---------|--------|
| LoRa-1 | A→bridge→RF→bridge→B @ ~1 km | &lt;10 s, usable loss | ☐ |
| LoRa-2 | 3 bridges multi-hop | Deferred until LoRa-1 green | ☐ |

### Open tech notes (answer when building, not blockers)

- **Power:** duty-cycle LoRa RX; lower `setTxPower` (sketch uses 17); deep-sleep between bursts if battery node.
- **Collisions:** DIY sketch is ALOHA — short payloads, backoff; Meshtastic handles CSMA-ish mesh better for multi-node.

---

## P1 — FCM kill-app ring (2-device prove)

Ops notes: `docs/BACKGROUND_RING_AND_CAPTIONS_2026-07-24.md`.

| Step | Check | ☐ |
|------|--------|---|
| QS env | `SAHULAT_FCM_SERVICE_ACCOUNT_PATH` set; push mode `fcm` not stub | ☐ |
| Client | `google-services.json` for `com.interactpak.interact_talk` | ☐ |
| Token | Device registers via push token API after login | ☐ |
| Prove | A calls B with B **force-stopped / killed** → ringtone + UI | ☐ |

Debug if fail: log FCM token, QS push send result, notification channel `interact_calls`, OEM battery restrictions.

---

## P2 — Backlog (do not start before P0 field rows)

### Captions E2E

- Agent + Deepgram path documented in `BACKGROUND_RING_AND_CAPTIONS_2026-07-24.md` (caption-agent on Hetzner).
- Prove: townhall Captions toggle → labeled lines when agent up.
- If keys missing: UI already best-effort; show operator “caption-agent / Deepgram required” — no second STT stack in Flutter.

### Disappearing messages

- Explicit product backlog (PRD). Not started.
- Design sketch: `expiryTimestamp` on message + client hide/delete; server GC optional; per-thread toggle.
- **No implementation until product schedules it.**

### Meshtastic-native adapter

- Optional after DIY LoRa-1 or instead of DIY.
- New adapter beside `lora_bridge_service.dart` (Meshtastic BLE API / protobuf) — **do not** fold into `sahl_mesh` gossip.
- Message format: Meshtastic mesh packets (see Meshtastic docs / Python client); map UTF-8 `talk:` lines into text port.

### Townhall TV polish

- Speaker/pin/pulse already on phone Live room (Wave 2).
- Remaining: TV layout polish, iOS VBG publish — soft backlog.

---

## Timeline (owners)

| Task | Owner | Target | Status |
|------|-------|--------|--------|
| RF-BLE / RF-LAN matrix | QA Pakistan | 2026-07-31 | ⏳ |
| Harden only failed rows | Flutter | 2026-08-02 | ⏳ after QA |
| FBP A/B decision | Legal / product | 2026-07-28 | ⏳ |
| FBP migrate (if B) | Flutter (`sahl_mesh`) | 2026-08-05 | ⏳ gated |
| FCM 2-device prove | Flutter + ops | 2026-08-02 | ⏳ |
| LoRa-1 DIY E2E | Hardware | 2026-08-09 | ⏳ optional |
| Meshtastic adapter | Flutter | 2026-08-16 | Backlog |
| Disappearing messages | Backend + Flutter | 2026-08-23 | Backlog |
| Captions prove | Flutter + ops | 2026-08-30 | Backlog |
| Townhall TV polish | UI | 2026-09-01 | Soft backlog |

---

## Eng progress (2026-07-26 code passes)

| Item | Shipped in tree |
|------|-----------------|
| P0 mesh harden | Runtime BT perms + wakelock + Maps-style FGS `connectedDevice` on Nearby mesh |
| P0 LAN harden | Wakelock on Offline LAN screen |
| P0 Field QA UI | Me → **Field validation** `/field-validation` (PASS/FAIL + FCM token) |
| P0 FBP | **Done — migrated** to `flutter_reactive_ble` (BSD-3); FBP removed from Talk + `sahl_mesh`. Re-prove RF-BLE on devices. |
| P1 FCM | `onBackgroundMessage` before `runApp` + token register logs + field screen |
| P1 LoRa | LoRa-1 **ping** + firmware power/collision notes (keep `InteractLoRaBridge` UUIDs) |
| P2 Meshtastic | Official GATT connect + want_config + FromRadio drain (text TX later) |
| P2 Disappearing | PATCH + menu + **banner** when timer on |
| P2 Captions | Health proxy `GET …/captions/health` + pre-toggle check |
| P2 Townhall TV | Exit speaker label + LiveKit echo/noise/AGC capture options |

**Still human-gated:** Pakistan RF matrix results, FCM 2-device prove, LoRa hardware E2E, caption-agent Deepgram keys on VPS, FBP migrate branch after QA.

## Cursor / eng scope now

**Do**

1. Keep this doc + SESSION as source of truth.
2. After QA files a failing row → minimal harden in the owning package.
3. After Legal picks B → migrate **scan side in `sahl_mesh` only** (plan doc ready).

**Do not**

1. Rewrite `lan_service.dart` or invent a second mesh.
2. Flash prompt-sample LoRa UUIDs.
3. Remove Offline LAN Direct (already shipped).

---

## Field report template (paste results)

```
Date / build:
RF-BLE-1: PASS|FAIL — notes:
RF-BLE-2: PASS|FAIL — notes:
RF-BLE-3: PASS|FAIL — notes:
RF-LAN-1: PASS|FAIL — notes:
RF-LAN-2: PASS|FAIL — notes:
RF-P2P-1: SKIP|PASS|FAIL — notes:
RF-IOT-1: PASS|FAIL — notes:
FCM kill-app: PASS|FAIL — notes:
LoRa-1: SKIP|PASS|FAIL — notes:
Blockers for Flutter:
```
