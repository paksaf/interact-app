# Offline mesh phase 4 — build 6063

Follows phase 3 (`OFFLINE_PHASE3_2026-09-01.md`). Implements audit step **7** (SMS bearer) and IoT doc **P1** (Meshtastic MeshPacket UTF-8 TX).

## SMS bearer (audit step 7)

User-confirmed only — never automatic. Cost is visible before send.

| Layer | Path |
|-------|------|
| Backend | `qurbanisahulat` `POST /api/v1/talk/sms/send` → Comms Hub → capcom6 |
| Flutter service | `lib/services/sms_bearer_service.dart` |
| Confirm UI | `lib/widgets/sms_fallback_sheet.dart` |
| Entry points | Chat send failure → **SMS** snackbar action; outbox banner **SMS** (thread + app shell); Offline hub tile **live** |

Requires `delivered === true` from the API before treating as sent (same honesty pattern as OTP).

Field test: **RF-SMS-FALLBACK-1** — queue a message offline, tap SMS, confirm sheet, verify carrier delivery.

## Meshtastic MeshPacket TX (IoT P1)

Minimal protobuf encoder writes `ToRadio → MeshPacket → Data` (portnum 1, TEXT_MESSAGE_APP) to the official ToRadio GATT characteristic.

| File | Role |
|------|------|
| `lib/core/meshtastic/meshtastic_packet_codec.dart` | Protobuf encoder |
| `lib/services/meshtastic_bridge_service.dart` | `sendText()` BLE write |
| `lib/screens/lora/lora_bridge_screen.dart` | Connect + text field + send |
| `test/meshtastic_packet_codec_test.dart` | Unit tests |

Field test: **RF-MESHTASTIC-TX-1** — connect T-Beam / RAK4631, send short UTF-8, verify on peer node.

## Next (phase 4 backlog)

| P | Item |
|---|------|
| P2 | MeshIdentity ↔ Talk identity binding | **Done** build 6064 — QR + `mesh_peer_registry.dart` |
| P2 | Formal Bearer adapters + outbox frame enrichment | **Done** build 6064 — see `OFFLINE_PHASE4_P2_2026-09-01.md` |
| P3 | Wave-1 field tests (RF-BLE-1/2/3, RF-LAN-1/2) | **Done** build 6065 |
| P3 | LoRa E2E (gated on field tests) | **Scaffold** build 6065 |

---

**Build:** `0.5.20+6064`
