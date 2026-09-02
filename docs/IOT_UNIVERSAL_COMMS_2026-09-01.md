# Universal IoT comms — envelope, screens, build roadmap

**Build:** `0.5.19+6063` · **Screen:** Me → Offline hub → **IoT gateway** (`/iot-comms`)

One phone runs Talk; any IoT gateway attaches over **BLE (LoRa ESP32)** or **HTTP (433/868 RF bridge on Pi / AutoSense edge)**. Replies use a **single JSON envelope** and **one-tap ACK** chips.

---

## Architecture

```
┌─────────────┐     BLE GATT      ┌──────────────────┐     LoRa/433    ┌─────────┐
│  Talk app   │ ◄──────────────► │ InteractLoRaBridge│ ◄────────────► │ Remote  │
│  /iot-comms │                   │ (ESP32 firmware)  │                │ node/IoT│
└──────┬──────┘                   └──────────────────┘                └─────────┘
       │
       │  HTTP GET poll / POST ack
       ▼
┌──────────────────┐     rtl_433 / GPIO     ┌──────────────┐
│ Pi / AutoSense   │ ◄────────────────────► │ 433 MHz sensor│
│ :8765/json       │                        │ gate, TPMS…  │
└──────────────────┘                        └──────────────┘
```

| IoT type | Phone link | Talk screen | ACK path |
|----------|------------|-------------|----------|
| **LoRa ESP32** | BLE → `InteractLoRaBridge` | IoT gateway → Connect → tap bridge | JSON line → BLE → LoRa |
| **433 MHz relay** | Wi‑Fi/LAN HTTP to Pi | IoT gateway → RF HTTP poll URL | POST `/ack` (or GET fallback) |
| **Meshtastic** | BLE GATT (official) | LoRa bridge expansion | UTF-8 MeshPacket TX via ToRadio GATT (6063) |
| **AutoSense car module** | Car Pi HTTP or future BLE | RF HTTP `http://car-pi:8765/json` | POST `/ack` with `ARM`/`DISARM`/`HONK` |
| **Plain legacy** | Any | Wrapped as telemetry on ingest | Plain `ACK`/`OK` body |

---

## Payload format (`IotFrame`)

Single-line JSON, **≤200 bytes** on LoRa paths (short keys):

```json
{"v":1,"id":"a1b2c3d4","k":"l","b":"rh","body":"gate_open","af":null,"m":{"device":"433-001"}}
```

| Key | Meaning | Values |
|-----|---------|--------|
| `v` | Version | `1` |
| `id` | Message id (8 hex) | correlate ACKs |
| `k` | Kind | `t` telemetry · `c` command · `a` ack · `p` ping · `l` alert |
| `b` | Bearer | `lb` LoRa BLE · `rh` RF HTTP · `ms` Meshtastic · `bm` BLE mesh · `as` AutoSense · `pl` plain |
| `body` | Human text or opcode | `ACK`, `OPEN`, `gate_open`, … |
| `af` | ACK-for id | set on replies |
| `m` | Optional meta | device id, RSSI, raw JSON |

**Legacy plain UTF-8** from DIY LoRa firmware (`LoRa-1 ping …`) is auto-wrapped on ingest.

**ACK example:**

```json
{"v":1,"id":"f9e8d7c6","k":"a","b":"lb","body":"ACK","af":"a1b2c3d4"}
```

---

## One-tap ACK presets

| Button | `body` | Typical use |
|--------|--------|-------------|
| ACK | `ACK` | Generic received |
| OK | `OK` | Confirm |
| NACK | `NACK` | Reject |
| OPEN / CLOSE | gate, barrier |
| ARM / DISARM | AutoSense alarm |
| HONK | locate car |
| STOP | estop |
| PING | link probe |

Code: `lib/core/iot/iot_ack_presets.dart`

---

## Screen flow

1. **Me → Offline hub → IoT gateway**
2. **Connect** tab:
   - Tap **InteractLoRaBridge** BLE chip, or
   - Enter **Poll URL** + optional **ACK URL** → Start RF HTTP gateway
3. **Inbox** tab: tap inbound signal
4. Tap **ACK / OK / OPEN / …** chip → outbound frame sent
5. Or type custom command in bottom field

Field test: **IoT-ACK-1** in Me → Field validation.

---

## RF HTTP bridge contract (for Pi / AutoSense)

**Poll (GET)** — any JSON; examples:

```json
{"alert":"gate_open","device":"433-gate-1","at":"2026-09-01T12:00:00Z"}
```

```json
{"v":1,"id":"evt42","k":"l","b":"rh","body":"motion_front"}
```

**ACK (POST)** — body = `IotFrame.encodeLine()`  
Default ACK URL: poll URL with `/ack` suffix (`/tpms` → `/ack` for Steelmate-style bridges).

GET fallback: `?ack=OK&af=<inbound-id>&id=<new-id>`

---

## Scenario map

| Scenario | Network | Path |
|----------|---------|------|
| Field, BT only, phone ↔ phone | None | **Nearby mesh** (not IoT gateway) |
| Field, LoRa kit | None on phone | **IoT gateway → LoRa bridge** |
| Car HU + phone, Pi on LAN | Wi‑Fi LAN, no internet | **RF HTTP** to Pi on car/hotspot |
| 433 sensor fires | Pi hears rtl_433 | Poll JSON → tap **ACK** |
| AutoSense alarm ping | Edge HTTP | Poll → **ARM/DISARM/HONK** |

---

## Build next (priority)

| P | Item |
|---|------|
| **P0** | Field-test **IoT-ACK-1** with real ESP32 + optional Pi rtl_433 |
| **P1** | Meshtastic **MeshPacket** UTF-8 send | **Done** build 6063 — `meshtastic_packet_codec.dart` + LoRa bridge UI |
| **P1** | SMS user-confirmed fallback (audit step 7) | **Done** build 6063 — Talk API + confirm sheet |
| **P1** | AutoSense Pi **reference bridge** script (`/json` + `/ack` → CAN/GPIO) |
| **P2** | Firmware: parse JSON ACK on ESP32, blink GPIO / LoRa relay |
| **P2** | Wire **OfflineRouter** — IoT alerts → Chats thread | **Done** build 6062 — `iot_chat_bridge.dart` |
| **P3** | BLE direct to AutoSense GATT (skip Pi) |
| **P3** | GPS location trace (phone + IoT) | **Done** build 6066 — `LOCATION_TRACE_2026-09-01.md` |

---

## Files

| Path | Role |
|------|------|
| `lib/core/iot/iot_frame.dart` | Envelope encode/decode |
| `lib/core/iot/iot_ack_presets.dart` | One-tap codes |
| `lib/services/iot/iot_comms_service.dart` | LoRa + RF HTTP hub |
| `lib/screens/iot/iot_comms_screen.dart` | UI |
| `firmware/lora_ble_bridge/` | ESP32 BLE↔LoRa |
