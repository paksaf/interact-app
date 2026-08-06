# Commercial deps (OSS-first) + Pakistan RF notes

**Date:** 2026-07-26

## Pakistan RF / product position (not legal advice)

### BLE (2.4 GHz)

If a sensor talks to a phone over Bluetooth Low Energy:

- BLE is in the **licence-exempt 2.4 GHz ISM** band → you generally **do not buy radio spectrum**.
- **PTA type approval** may apply when **manufacturing or importing a finished wireless product** for commercial sale in Pakistan.
- **Internal R&D / prototypes** are usually not the immediate blocker.

Talk phone↔phone Nearby mesh and Maps/workshop BLE sensors fit this model.

### Wi‑Fi LAN

Same pattern: licence-exempt consumer Wi‑Fi; PTA matters mainly for **import/sale of finished equipment**, not for apps joining normal Wi‑Fi.

### LoRa — postpone until km-range is a product requirement

Uncertainty remains on national LoRa frequency plans (433 vs 868/915). Relevant only for long-range farm / fuel / workshop nodes.

**If first products only use BLE + Wi‑Fi (+ NFC):** ignore LoRa for now.  
Talk: DIY `InteractLoRaBridge` / Meshtastic stay **optional backlog** until architecture needs kilometre range.

### Example (motorcycle fuel sensor) — simplest route

```
Fuel Sensor ──BLE──> Rider's phone ──Internet──> Interact Cloud
```

No LoRa. No RF spectrum purchase. Ensure hardware compliance **before mass import/sale**.

---

## OSS-first rule

For every paid/restrictive dependency: **try open-source / already-licensed INTERACT stack first**. Buy only if still required — one item at a time below.

---

## 1) `flutter_blue_plus` → **migrated** (do not buy)

| | |
|--|--|
| Status | **Done:** Talk + `sahl_mesh` use **`flutter_reactive_ble` (BSD-3)**; FBP removed from pubspecs |
| Why not buy | Interact is commercial; FBP licence can apply in **dev/test**, not only after publish. Portfolio is Flutter **Android/iOS** + BLE sensors — **no production need for Windows/Linux/macOS/Web BLE** |
| If migrate regresses | Buy via official portal only: [jamcorder FBP commercial license](https://jamcorder.myshopify.com/products/flutterblueplus-commercial-license) (employee tier). Ignore fake €200/app/year links. |

**Decision question (answered No):** Will any Interact app use BLE on desktop as a production platform? → **No** → little reason to pay for FBP’s wider platforms.
---

## 2) Deepgram (captions)

| | |
|--|--|
| Status | Pay-as-you-go STT — key is **admin/ops only** (never in Talk app) |
| Access | QS `POST …/talk/live/captions` requires Sahulat role **`admin`** to start/stop |
| Users | Once admin starts agent, all room participants **see** captions (LiveKit data topic) |
| Where key lives | `interact-realtime/caption-agent/.env` (gitignored) + VPS PM2 env `DEEPGRAM_API_KEY` |

Ops:

1. Set `DEEPGRAM_API_KEY` on caption-agent (local `.env` or Hetzner).
2. Restart PM2 `interact-caption-agent`; `GET /health` → `configured: true`.
3. Only accounts with Sahulat **admin** role can toggle captions from Talk.

---

## 3) LiveKit

| | |
|--|--|
| Status | **Already on INTERACT stack** — self-host / existing cloud; no new buy for Talk townhall |
| Link | [livekit.io/pricing](https://livekit.io/pricing) only if leaving self-host |

---

## 4) Meshtastic / Bonsoir / LoRa DIY

| Component | License | Buy? |
|-----------|---------|------|
| Meshtastic firmware / protocol | Open (project licenses) | No |
| Bonsoir | MIT | No |
| DIY `InteractLoRaBridge` firmware | AGPL in-tree | No |

---

## Remaining eng (accurate)

| Item | Code status | Human gate |
|------|-------------|------------|
| Field RF matrix | UI ready | Pakistan QA PASS/FAIL |
| Harden FAIL rows | Mesh FGS + LAN wakelock ready | After FAIL |
| FBP compliance | **Migrate (OSS)** | Re-prove BLE after migrate |
| LoRa E2E | Firmware + Talk attach | Hardware + PTA counsel for freq/import |
| Meshtastic text TX | GATT connect done | MeshPacket encode next |
| Disappearing | API + UI + banner | Deploy QS |
| Captions | Health proxy | Deepgram key on agent |
| FCM kill-app | Client + field token UI | 2-device prove |
| Townhall TV | Speaker + DSP | Soft polish |
