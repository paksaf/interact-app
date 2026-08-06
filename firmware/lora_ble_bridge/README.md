# LoRa ↔ BLE bridge firmware (optional long-range RF)

**Status:** Scaffold for when phone-only BLE/LAN is field-proven and a user accepts carrying a node.  
**Not required for Talk v1 phone↔phone** (use Offline LAN Same Wi‑Fi / Direct, or Nearby mesh).

## Architecture

```
Phone A ──BLE──> ESP32+LoRa ──LoRa RF──> ESP32+LoRa ──BLE──> Phone B
```

Talk stays on **`sahl_mesh` / BLE GATT** to the bridge; the bridge forwards UTF-8 payloads over LoRa (Meshtastic or raw SX127x/SX1262).

## Recommended hardware

| Option | Notes |
|--------|--------|
| **Meshtastic T-Echo / T-Beam** | Prefer for field trials — flash Meshtastic, pair phone via official app or BLE UART; map Talk `talk:` frames later |
| **DIY ESP32 + RA-02 (SX1278)** | Use `lora_ble_bridge.ino` below (Arduino + LoRa library) |

Regional frequency: **915 MHz** (Pakistan / many Americas) or **868 MHz** (EU) — set in sketch / Meshtastic channel.

## Build (DIY Arduino)

1. Board: ESP32 Dev Module.
2. Libraries: `LoRa` (Sandeep Mistry), ESP32 BLE Arduino (bundled).
3. Wire RA-02: NSS→5, RST→14, DIO0→2, SCK/MISO/MOSI → VSPI (adjust pins in sketch).
4. Flash `lora_ble_bridge.ino`, power via USB or LiPo.
5. Phone: connect to BLE name `InteractLoRaBridge`, write UTF-8 to RX characteristic; subscribe to TX for inbound LoRa.

## Talk integration (shipped)

1. Flash this sketch (or Meshtastic with a future adapter).
2. In Talk: **Me → LoRa bridge** (`/lora-bridge`).
3. App scans for advertised name `InteractLoRaBridge`, connects GATT, writes UTF-8 to RX, listens on TX notify.
4. Needs **two** bridges (or one bridge + another LoRa node) for phone↔phone over the air.
5. Never invent a second chat backend — payloads are plain UTF-8 lines (same spirit as LAN/mesh).

**E2E runbook / reject wrong UUIDs:** [`docs/FIELD_VALIDATION_AND_BACKLOG_2026-07-26.md`](../../docs/FIELD_VALIDATION_AND_BACKLOG_2026-07-26.md) § P1 LoRa. Do **not** flash sketches named `LoRa_Bridge` or UUIDs `12345678-…`.

## Safety / legal

- Respect local ISM power and duty-cycle rules.
- Do not put secrets in clear LoRa hello frames; use Meshtastic channel keys when available.

## Power + collisions (open questions)

| Topic | Guidance for DIY sketch |
|-------|-------------------------|
| **Portable power** | Sketch uses `setTxPower(17)` (not max 20). Prefer deep-sleep between bursts if battery-powered; keep BLE advertising interval modest; USB/LiPo for field LoRa-1. |
| **Collisions** | DIY path is ALOHA (no CSMA). Keep payloads &lt;200 B; add random backoff before extended multi-bridge trials. For multi-node mesh prefer **Meshtastic** firmware over DIY multi-hop. |

## E2E LoRa-1 checklist

1. Flash **both** ESP32 with this sketch (same `LORA_FREQ`).
2. Phone A + B: Me → LoRa bridge → connect each to its bridge.
3. Tap **ping** (speed icon) on A; B should see notify &lt;10 s @ ~1 km open.
