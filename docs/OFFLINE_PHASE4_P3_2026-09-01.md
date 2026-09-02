# Offline mesh phase 4 P3 — build 6065

Follows P2 (`OFFLINE_PHASE4_P2_2026-09-01.md`). Implements **all three P3 waves**: phone RF field prove, Chats router integration, IoT/LoRa E2E scaffolding.

## Wave 1 — Phone RF

Standalone transport screens with shared `FieldProbeService` TX/RX latency log.

| Case | Screen |
|------|--------|
| RF-BLE-1/2/3 | `/nearby-mesh` — shared `BleMeshTransportService` |
| RF-LAN-1/2 | `/offline-lan` |
| RF-P2P-1 | `/offline-lan` (P2P adapter) |
| RF-OFFLINE-1 | `/offline-hub` |

Probes: `ble_mesh_transport_service.dart`, `lan_service.dart`, `bearer_adapters.dart` (LAN/P2P TX).

## Wave 2 — Chats router

Chat tab sends via `OfflineRouter` adapter chain; manual LAN bind when mDNS fails.

| Case | How |
|------|-----|
| RF-UNIFIED-1 | Send in 1:1 thread offline → sensors tick on LAN/BLE |
| RF-BLE-CHAT-1 | Same, BLE mesh path |
| RF-LAN-CHAT-1 | Same + **LAN** icon in thread app bar → `offline_peer_sheet.dart` |
| RF-THREAD-PEER-1 | `ThreadPeerRegistry` maps thread ↔ peerUserId |
| RF-OUTBOX-ROUTER-1 | Outbox flush via router |
| RF-SMS-FALLBACK-1 | User-confirmed SMS (P1) |
| RF-MESH-BIND-1 | QR identity bind (P2) |

## Wave 3 — IoT & long-range

| Case | How |
|------|-----|
| IoT-ACK-1 / RF-IOT-CHAT-1 | `/iot-comms` |
| RF-IOT-1 | `/nearby-devices` |
| LoRa-1 / RF-LORA-E2E-1 | `/lora-bridge` + `LoraBearerAdapter` |
| RF-MESHTASTIC-TX-1 | Meshtastic GATT TX (P1) |

LoRa RX probes in `lora_bridge_service.dart`. **ADR gate:** Wave 3 LoRa E2E requires Wave 1 BLE/LAN PASS.

## Field validation UI

`lib/screens/debug/field_validation_screen.dart` — grouped by `kFieldTestWaves`, wave PASS counters, probe log panel (refresh/clear).

## New / changed files

| File | Role |
|------|------|
| `lib/services/field_probe_service.dart` | TX/RX log + wave definitions |
| `lib/widgets/chat/offline_peer_sheet.dart` | Manual IP:port bind per thread |
| `lib/services/bearer_adapters.dart` | P2P + LoRa adapters |
| `lib/services/offline_router.dart` | Full adapter chain |
| `lib/screens/mesh/nearby_mesh_screen.dart` | Shared BLE transport |
| `test/field_probe_test.dart` | Probe + wave unit tests |

---

**Build:** `0.5.21+6065`

**Field execution:** Run matrix on A23 + Paksaf; mark PASS/FAIL in Me → Field validation.
