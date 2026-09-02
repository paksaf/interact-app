# Offline mesh phase 2 — build 6060

## Thread ↔ peer mapping

1:1 chat sends no longer pick the **first** LAN peer. `ThreadPeerRegistry` binds:

- `threadId` → `peerUserId` (from server `ChatThread.peerUserId` or participants)
- `peerUserId` → `threadId` (reverse, learned from inbound `talk:1|threadId|…` envelopes)
- Optional manual `{host, port}` per thread when mDNS is blocked

`OfflineRouter` resolves `LanPeer` where `peer.peerId == peerUserId`.

| File | Role |
|------|------|
| `lib/services/thread_peer_registry.dart` | Persist + resolve mappings |
| `lib/models/offline_frame.dart` | `targetPeerUserId` on frames |
| `lib/services/offline_router.dart` | Async `_pickLanPeer` |
| `lib/screens/chat/chat_thread_screen.dart` | Binds peer on open; passes on send |

Field test: **RF-THREAD-PEER-1**

## Outbox flush via OfflineRouter

`OutboxService.flush()` routes `chat_text` rows through `OfflineRouter.replayOutboxItem` (cloud → LAN → mesh) instead of raw HTTP only.

Wired in `app_shell.dart` on boot + resume flush.

Field test: **RF-OUTBOX-ROUTER-1**

## BLE peripheral advertising (walkie)

`BleWalkieService.startSession()` advertises the Nordic-style walkie GATT service via `ble_peripheral` while `flutter_reactive_ble` scans. Both phones open `/ble-walkie`.

Field test: **RF-BLE-VOICE-1** (unchanged route, now discovers without dongle)

## Hive local message cache

`LocalMessageStore` (`talk_msgs_hive_v1` Hive box) replaces SharedPreferences for per-thread JSON. Legacy `talk_local_msgs_v1_*` keys migrate on first boot.

Initialized in `main.dart` before `runApp`.

---

**Build:** `0.5.17+6060`

**Deploy reminder:** qurbanisahulat townhall analytics migration was applied on **localhost** only — production still needs `prisma migrate deploy` + redeploy for host viewer counts.
