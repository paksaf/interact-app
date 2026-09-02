# Offline mesh phase 3 — build 6062

Follows phase 2 (`OFFLINE_PHASE2_2026-09-01.md`). Implements audit §7 steps **5** (partial→done) and IoT doc **P2** (IoT → Chats).

## Honest mesh delivery ticks (audit step 5)

Cloud messages keep WhatsApp-style ticks (✓ sent, ✓✓ delivered, blue ✓✓ read).

Offline bearers (LAN, BLE mesh, LoRa, IoT) show a **broadcast icon** (`sensors`) with semantics *“Handed to &lt;bearer&gt; — delivery not confirmed”*. Gossip cannot prove peer receipt; double-blue ticks were removed for those paths.

| File | Role |
|------|------|
| `lib/core/offline/message_delivery_state.dart` | Tick resolver + `TalkBearer.confirmsEndToEndDelivery` |
| `lib/screens/chat/chat_thread_screen.dart` | Bubble footer uses resolver |
| `test/message_delivery_state_test.dart` | Unit tests |

Field test: send offline on LAN/BLE — bubble shows **sensors** tick, not ✓✓.

## IoT alerts → Chats thread (IoT P2)

Inbound `IotFrame` alerts/telemetry from `/iot-comms` gateways now mirror into a local **IoT alerts** chat thread (`iot-alerts-system`). ACK chips stay on the IoT gateway screen.

| File | Role |
|------|------|
| `lib/services/iot/iot_chat_bridge.dart` | Inbox listener → `MessageRepository.upsertInbound` |
| `lib/models/talk_bearer.dart` | New `TalkBearer.iot` wire code |
| `lib/screens/tabs/chats_tab.dart` | Synthetic thread in list |
| `lib/screens/chat/chat_thread_loader.dart` | Deep-link loader |
| `lib/screens/shell/app_shell.dart` | Bridge starts at boot |

Field test: **RF-IOT-CHAT-1** — RF HTTP or LoRa alert appears under Chats → IoT alerts.

## Next (phase 4 backlog)

| P | Item | Audit / IoT ref |
|---|------|-----------------|
| P1 | SMS bearer, user-confirmed | Audit step 7 |
| P1 | Meshtastic MeshPacket UTF-8 TX | IoT P1 |
| P2 | MeshIdentity ↔ Talk identity binding | Audit step 6 |
| P2 | Formal Bearer adapters + outbox frame enrichment | Audit steps 2–3 |

---

**Build:** `0.5.18+6062`
