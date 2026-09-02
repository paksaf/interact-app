# Offline mesh phase 4 P2 — build 6064

Follows P1 (`OFFLINE_PHASE4_2026-09-01.md`). Implements audit steps **2–3** and **6**.

## Formal bearer adapters (audit step 2)

`OfflineRouter` now iterates `TalkBearerAdapter` implementations instead of calling transports inline.

| File | Role |
|------|------|
| `lib/core/offline/talk_bearer_adapter.dart` | `TalkBearerAdapter`, `BearerSendResult`, default preference |
| `lib/services/bearer_adapters.dart` | Cloud, LAN, BLE mesh adapters |
| `lib/services/offline_router.dart` | Adapter chain: cloud → LAN → BLE → queue |

**Cloud bypass fix:** `ChatApi.sendText(..., queueOnFailure: false)` from the cloud adapter so a soft network failure falls through to LAN/BLE instead of stopping at a pending cloud bubble.

## Outbox frame enrichment (audit step 3)

Queued chat rows now store the full `OfflineFrame` JSON + `bearerPreference` wire list.

| File | Role |
|------|------|
| `lib/services/outbox_service.dart` | `enqueueFrame()` |
| `test/outbox_frame_test.dart` | Frame blob persistence |

Legacy rows (`url` + `body` only) still replay via `OfflineRouter.replayOutboxItem`.

## MeshIdentity ↔ Talk binding (audit step 6)

Persist mesh Ed25519 identity; QR-signed contact cards; on-device trust registry.

| File | Role |
|------|------|
| `lib/services/mesh_identity_store.dart` | Load-or-create seed in secure storage |
| `lib/core/offline/mesh_identity_card.dart` | Signed QR JSON + verify |
| `lib/services/mesh_peer_registry.dart` | pubkey ↔ talkUserId |
| `lib/screens/mesh/mesh_identity_bind_screen.dart` | Show QR / scan peer |
| `lib/services/inbound_funnel.dart` | Resolve BLE sender via registry |
| `lib/services/ble_mesh_transport_service.dart` | Stable identity per install |

Field test: **RF-MESH-BIND-1** — two phones scan each other's QR, then BLE mesh shows real names.

NFC tap binding remains planned (toolchain pin).

## Next (phase 4 backlog)

| P | Item |
|---|------|
| P3 | Wave-1 field tests (RF-BLE-1/2/3, RF-LAN-1/2) | **Done** build 6065 — see `OFFLINE_PHASE4_P3_2026-09-01.md` |
| P3 | LoRa E2E (gated on field tests) | **Scaffold** build 6065 — RF-LORA-E2E-1; hardware prove pending |
| P2+ | Backend mesh-identity sync (when Sahulat unfrozen) |

---

**Build:** `0.5.20+6064`
