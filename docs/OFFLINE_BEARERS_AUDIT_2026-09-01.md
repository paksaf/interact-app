# INTERACT offline bearers — audit, one security finding, and the missing router

**Date:** 2026-09-01 · **Scope:** interact-app + sahl_mesh + sahl_radar
**Read first:** [`OFFLINE_MESH_LORA_BRIDGE_2026-07-26.md`](./OFFLINE_MESH_LORA_BRIDGE_2026-07-26.md)

That ADR is still correct and this document does **not** reopen it. Nothing here
proposes a new transport, a second discovery stack, a GATT mesh rewrite, or
moving the LoRa gate. Every rejection in its "Phone-only scope" table stands.
This is about the layer **above** the transports, which does not exist yet.

---

## 1 · What actually ships today

| Bearer | Code | Lines | Real? | Terminates in |
|---|---|---:|---|---|
| BLE gossip | `sahl_mesh` (adv/scan, CBOR, Ed25519, TTL, Bloom, chunked) | 2142 + 7 test files | **Yes** — chunking implemented, RSSI → `sahl_radar` | `nearby_mesh_screen` |
| Wi-Fi LAN text | `lan_service` (Bonsoir mDNS + TCP newline JSON) | 204 | **Yes** | `offline_lan_screen` |
| Wi-Fi Direct / MPC | `p2p_service` (`nearby_service`) | 197 | **Yes**, same-OS only | `offline_lan_screen` (Direct mode) |
| LAN walkie voice | `lan_walkie_service` (in-app WS relay + WebRTC) | 442 | **Yes** — manual IP join + host IP display (6056); field test pending | `lan_walkie_screen` |
| LoRa bridge | `lora_bridge_service` + `firmware/lora_ble_bridge/` | 276 + firmware | **Yes**, needs hardware | `lora_bridge_screen` |
| Meshtastic | `meshtastic_bridge_service` (official GATT) | 198 | **RX only** — `MeshPacket` TX not implemented | — |
| BLE device scan | `nearby_ble_devices_service` | 151 | **Yes** | `iot/nearby_ble_devices_screen` |
| Cloud queue | `outbox_service` | 218 | **Yes** — but cloud-only | `ChatApi` |

That is a genuinely strong radio layer. Five working phone-native paths, a
signed gossip protocol with duplicate suppression and multi-hop TTL, RSSI
trilateration, and firmware for the long-range hop. Very little of it needs
building.

## 2 · The finding: five radios, no router

**Not one of these bearers can carry a message typed in the Chats tab.**

The chat path is `ChatApi` → HTTPS → Sahulat, full stop. `outbox_service`
queues for the **cloud** only — it has no concept of an alternative bearer.
`mesh_cloud_bridge` runs one direction (mesh → cloud) and needs uplink to do
anything.

So with no internet, a user in a chat thread has no way to send. To reach
someone standing next to them they must know to leave chat, open a different
screen, and type into a different box that talks to a different set of people
with no thread, no history, no delivery state. Each transport is a working
demo of itself.

**The gap is not radio. It is routing.** Roadmap §10 already says this
("mesh transport not wired into chat flow"); this document is what it costs
to close it.

## 3 · 🔴 SECURITY — inbound mesh/LAN frames can send messages AS YOU

Found while tracing the receive path. This is pre-existing (July mesh wave),
not from the §14 walkie work.

**Chain:**

1. `app_shell.dart:100` calls `MeshCloudBridge.instance.bind(chatApi)` at
   startup — the bridge is armed **app-wide**, not per-screen.
2. `lan_service.dart:167` calls `MeshCloudBridge.ingestLanBody(body)` on
   **every inbound TCP frame**, with no authentication of the sender.
3. `ingestTalkFrame` parses `talk:0|<phone>|<text>` and calls
   `api.createDirectThread(peerPhone:)` then `api.sendText(...)` —
   **using the local user's own credentials**.

**Impact:** anyone on the same Wi-Fi can discover the listener over mDNS
(`_interact-lan._tcp` is broadcast), open a TCP socket, and cause the victim's
phone to send an attacker-chosen message to an attacker-chosen number, from
the victim's account. Same reachable over BLE via `nearby_mesh_screen:68`.
Ed25519 signing in `sahl_mesh` does **not** prevent it — signatures prove
frame integrity, not authorisation, and any node can mint its own identity.

This is a confused-deputy bug: the relay's authority is used for the sender's
intent. Exposure lasts as long as any offline transport is running.

**Recommended fix (v1, small):** an inbound frame must never cause an outbound
send as the local user. Render received mesh frames **locally**, attributed to
the mesh sender, and drop the auto-forward. Keep `encodeForThread` /
`encodeForPhone` as **outbound-only** helpers.

**If auto-relay is wanted later**, it needs all three of: (a) `talk:0|phone|`
dropped from the inbound path entirely — thread-scoped `talk:1|` only, and
only for threads the local user is already in; (b) the sending MeshIdentity
paired and trusted by the user beforehand; (c) a backend relay concept so the
message is attributed to the original sender rather than the relay. (c) is a
Sahulat change and therefore frozen.

## 4 · The missing layer: one router, many bearers

The shape, consuming the existing transports unchanged:

```
Chats tab / any send
        │
        ▼
   OfflineRouter ──── picks bearers in order, per message
        │
   ┌────┼────┬──────────┬──────────┬─────────┐
 cloud  LAN  Direct    BLE       LoRa      (SMS)
 HTTPS  TCP  nearby_   sahl_     bridge
             service   mesh
        │
        ▼
   durable queue (outbox_service, extended) + dedupe on receive
        │
        ▼
   reconcile with cloud on reconnect (MessageWatcher)
```

Four pieces, none of which is a new radio:

**`Bearer` interface** — each existing service gets a thin adapter declaring
`maxPayload`, `typicalLatency`, `isAvailable`, `reach` (peer / broadcast /
internet) and `send(frame)`. Adapters only; the services stay as they are.

**`OfflineRouter`** — given an outbound message, tries bearers in preference
order and records which one carried it. Cloud first when up; otherwise the
cheapest bearer that can reach the recipient.

**Durable queue** — `outbox_service` today hardcodes an HTTP POST. It needs to
hold a *frame plus a bearer preference* so a message queued offline flushes
over whatever comes back first — mesh now, cloud later.

**Inbound funnel + dedupe** — one entry point for frames from every bearer,
deduped by message id (`sahl_mesh`'s Bloom filter already does this per-bearer;
the router needs it across bearers so a message heard over both BLE and LAN
appears once), then rendered in the thread.

**Honest delivery state.** A message that left over BLE gossip is *"handed to
the mesh"*, not *"delivered to Ahmed"* — TTL gossip cannot confirm receipt.
This needs its own tick state in the UI. Getting this wrong is worse than not
shipping it: field users will trust a checkmark.

**Identity.** `sahl_mesh` has Ed25519 `MeshIdentity`; Talk has phone-based
users. Nothing binds them. Until it does, offline messages cannot be
attributed safely — which is also the root of §3.

## 5 · SMS — the bearer the RF taxonomy misses

The ADR's taxonomy covers *radios* and is right that no phone has LoRa. But it
omits the bearer that is already in every user's hand and already wired into
INTERACT infrastructure: **SMS over the cellular radio**.

Rural Pakistan's common failure is not "no signal" — it is **signal but no
usable data**. In that state BLE and LAN reach only what's in the room, LoRa
needs hardware nobody has, and SMS works. The portfolio already runs Dexatel
and the capcom6 gateway.

Cheap first slice: when the outbox has been failing for N minutes and the
device reports cellular but no data, offer *"send this as an SMS instead"* —
user-confirmed, never automatic, cost is visible. No new radio, no hardware,
no PTA question.

## 6 · Wave-1 field tests have never been run

The tracker in `OFFLINE_MESH_LORA_BRIDGE_2026-07-26.md` §"Field tests" is four
unchecked boxes, and the ADR gates LoRa implementation on them passing.

Today's session has three devices on one build for the first time. Closing
those four rows costs ~20 minutes on top of the walkie test and unlocks the
gate. See §7 step 0.

## 7 · Ordered plan

| # | Step | Why this order | Size |
|---|---|---|---|
| 0 | Run the Wave-1 BLE + LAN text rows alongside the §18 walkie tests | Three devices, one build, already in hand. Unblocks the LoRa gate the ADR set. | 20 min |
| 1 | **Fix §3** — stop auto-forwarding inbound frames as the local user | Live injection path; small, self-contained | ~1 h |
| 2 | `Bearer` adapters over the five existing services | Pure wrapping, no behaviour change, testable without radios via `InMemoryTransport` | 1 session |
| 3 | Extend `outbox_service` to hold frame + bearer preference | The one real change to shipped code | 1 session |
| 4 | `OfflineRouter` + inbound funnel + cross-bearer dedupe | The actual feature: chat works with no internet | 1–2 sessions |
| 5 | Mesh delivery state in chat UI (distinct from cloud ticks) | Ship 4 without it and users will misread it | ½ session |
| 6 | MeshIdentity ↔ Talk identity binding | Makes attribution safe; prerequisite for any relay | 1 session, partly Sahulat (frozen) |
| 7 | SMS bearer, user-confirmed | Highest real-world value per line of code once 2–4 exist | 1 session |
| 8 | LoRa E2E | Only after step 0 passes, per the ADR | hardware lead time |

Steps 2–4 are the ones that turn a drawer of working radios into a product.

## 8 · Candidate bearers, rated honestly

| Bearer | Range | Payload | Extra hardware | Verdict |
|---|---|---|---|---|
| Wi-Fi LAN (same AP) | building | unlimited | none | **Shipped.** Best offline path when an AP exists |
| Wi-Fi Direct / MPC | ~10–100 m | unlimited | none | **Shipped.** Same-OS only — the real limit |
| BLE gossip | ~10–100 m/hop, multi-hop | ~24 B/chunk | none | **Shipped.** Text only, forever. Don't promise media |
| LAN walkie (voice) | building | audio | none | **New, untested** |
| SMS | national | 160 chars | none | **Missing, highest value** for the actual market |
| LoRa / Meshtastic | 1–10 km | ~200 B | node per site | Firmware ready, gated on step 0 |
| Data-over-sound | same room | ~10 B/s | none | Curiosity. Only worth it for channel codes when BLE permission is denied |
| NFC | touching | small | none | Pairing / contact exchange only. Would serve step 6 well |
| Satellite | anywhere | tiny | — | No third-party API on iOS or Android. Not available |

## 9 · Corrections made while auditing

- `sahl_mesh/README.md` roadmap table said Phase 1.5 chunking was "pending" —
  `mesh_chunker.dart` (331 lines), `mesh_chunker_test.dart` and the chunk-cycling
  in `ble_transport.dart` all ship. It also still named `flutter_blue_plus`
  after the migration to `flutter_reactive_ble` + `flutter_ble_peripheral`.
  Both corrected.
- `meshtastic_bridge_service` is **RX only** — worth stating plainly wherever
  Meshtastic support is described, since "adapter exists" reads as two-way.

## 10 · 🔴 `sahl_mesh` has no git repository

`apps/sahl_mesh/.git` does not exist. A 2142-line signed mesh protocol with
7 test files, declared as a **path dependency of interact-app**, is therefore
compiled into every APK and IPA the project ships — and is not under version
control anywhere. No history, no remote, no backup beyond the weekly disk
snapshot.

Same sweep found three more unversioned Dart packages:

| Package | Dart files | Versioned |
|---|---:|---|
| `apps/sahl_mesh` | 20 | ✘ — **path dep of interact-app** |
| `apps/sahl_radar` | 10 | ✘ |
| `apps/interact_mobile_common` | 14 | ✘ |
| `apps/interact_media` | 6 | ✘ |
| `apps/sahulat_common` | — | ✔ (path dep, tracked) |

This is the **third recurrence** of a pattern already in the record —
`tanwrk-backend` and `sahl-v2` (2026-08-13), then TryOn (2026-08-12), each
found as live, unversioned production code. Worth treating as a standing
sweep rather than a one-off fix: `find ~/dev/INTERACT/apps ~/dev/INTERACT/services
-maxdepth 1 -type d '!' -exec test -d '{}/.git' ';' -print`.

Init `sahl_mesh` first — it is the one shipping inside a commercial binary.
Review `.gitignore` before the first commit (the sahl-v2 trap: its venv was
`.venv-python3.12`, which a plain `.venv/` rule does not match).

**Note:** the README corrections in §9 were written to a directory with no
version control, so they exist only on disk until this is fixed.
