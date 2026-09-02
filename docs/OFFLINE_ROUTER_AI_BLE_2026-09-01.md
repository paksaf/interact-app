# OfflineRouter + AI contact + BLE walkie — build 6059

## Prompt B — Unified offline chat

```
ChatThreadScreen._sendText
        ▼
MessageRepository.sendText
        ▼
OfflineRouter (Cloud → LAN → BLE mesh → Outbox)
        ▼
InboundFunnel ← LanService + BleMeshTransport
        ▼
MessageRepository.upsertInbound → local cache → UI stream
```

| File | Role |
|------|------|
| `lib/services/offline_router.dart` | Bearer selection |
| `lib/services/message_repository.dart` | Local cache + send entry |
| `lib/services/inbound_funnel.dart` | Dedupe inbound frames |
| `lib/services/ble_mesh_transport_service.dart` | App-wide sahl_mesh node |
| `lib/models/talk_bearer.dart` | bearer enum |
| `lib/models/offline_frame.dart` | wire envelope |

UI: message footer shows bearer label (`LAN`, `BLE mesh`, `Queued`).

## Prompt A — BLE walkie fallback

When LAN walkie discovery is empty → **Try BLE Walkie** on `lan_walkie_screen.dart`.

| File | Role |
|------|------|
| `lib/services/ble_walkie_service.dart` | PTT record → BLE GATT chunks → play |
| `lib/screens/lan/ble_walkie_screen.dart` | Scan, connect, hold-to-talk |
| Route | `/ble-walkie` |

No Opus dep — 8 kHz AAC chunks over `flutter_reactive_ble` (donor: `lora_bridge_service.dart`).

## Prompt C — INTERACT AI contact

| File | Role |
|------|------|
| `lib/services/ai_contact_service.dart` | Synthetic thread + AiRouter replies |
| `kAiThreadId` | `interact-ai-system` |
| Chats tab | Pinned AI row at top |
| `/chat/interact-ai-system` | Deep link |

Walkie: **Talk to AI** button on BLE walkie screen → AI thread.

## Field tests

- `RF-UNIFIED-1` — send offline → appears in Chats with bearer chip
- `RF-BLE-VOICE-1` — BLE walkie PTT between two phones
- `RF-AI-1` — message INTERACT AI → cloud reply in thread
