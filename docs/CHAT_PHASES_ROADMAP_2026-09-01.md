# INTERACT Talk chat — phased roadmap (2026-09-01)

**Build:** `0.5.25+6069` · Canonical audit: `OFFLINE_BEARERS_AUDIT_2026-09-01.md`  
**Lab devices on 6069 (2026-09-02):** A23, iPad, iPhone — see `SESSION.md`

This doc is the **step-by-step order** for chat + offline bearers. E2E (Signal/libsignal) is a **parallel Phase 1.5 workstream** — not blocking earlier phases.

---

## Phase map (offline chat workstream)

| Phase | Name | Goal | Code | Field proof |
|-------|------|------|------|-------------|
| **0** | Wave 1 — Phone RF | BLE gossip + LAN work standalone | ✅ | ☐ RF-BLE/LAN-* |
| **1** | Security + chunking | No inject-as-you; sahl_mesh chunking | ✅ | ☐ |
| **2** | **Chats router** | Text in Chats → OfflineRouter → bearers | ✅ **6067 polish** | ☐ RF-UNIFIED-1 … |
| **3** | IoT + long-range | IoT→Chats, LoRa, Meshtastic | ✅ scaffold | ☐ Wave 3 cases |
| **4** | LoRa product | km-range after Wave 1 PASS | hardware | ☐ RF-LORA-E2E-1 |
| **1.5** | **E2E crypto** | libsignal 1:1 ciphertext | stub only | — |

---

## Step-by-step (do in order)

### Step 0 — Prove Wave 1 (gate for LoRa)

1. Me → Field validation → Wave 1: RF-BLE-1/2/3, RF-LAN-1/2, RF-P2P-1, RF-OFFLINE-1  
2. Mark PASS/FAIL; fix only failed rows (FGS, mDNS, manual LAN bind)  
3. **Do not** invest in LoRa E2E until Wave 1 has PASS rows  

### Step 1 — Phase 2 chat router (shipped; polish 6067)

| # | Item | Status |
|---|------|--------|
| 1 | Confused-deputy removed (`mesh_cloud_bridge` inbound-only) | ✅ |
| 2 | `TalkBearerAdapter` chain | ✅ |
| 3 | Outbox frame + bearer preference | ✅ |
| 4 | `OfflineRouter` + inbound funnel | ✅ |
| 5 | Honest delivery ticks (sensors ≠ delivered) | ✅ |
| 6 | MeshIdentity ↔ Talk QR bind | ✅ |
| 7 | SMS user-confirmed (not auto-routed) | ✅ |
| **8** | **Thread offline banner** (cloud/offline/outbox) | ✅ 6067 |
| **9** | **Media offline policy** (text+location only offline) | ✅ 6067 |
| **10** | **Pending/cloud merge reconcile** | ✅ 6067 |
| **11** | **E2E stub** (`e2e_crypto_service.dart`) | ✅ 6067 |

**Field:** Wave 2 — RF-UNIFIED-1, RF-BLE-CHAT-1, RF-LAN-CHAT-1, RF-THREAD-PEER-1, RF-OUTBOX-ROUTER-1, RF-SMS-FALLBACK-1, RF-MESH-BIND-1  

### Step 2 — Phase 3 IoT & location

1. IoT-ACK-1, RF-IOT-CHAT-1 with real gateway  
2. Location trace + live share (6066) — RF-LOC-TRACE-1  
3. Meshtastic TX field test — RF-MESHTASTIC-TX-1  
4. LoRa E2E after Step 0 PASS — RF-LORA-E2E-1  

### Step 3 — Phase 4 + product backlog

1. NFC mesh identity tap (plugin session)  
2. Wi‑Fi Aware bearer  
3. §14 BLE mesh voice (after LAN walkie proven)  
4. Server chat archive (Chats “Phase 2” — needs Sahulat deploy)  
5. Group chat 2-device regression  
6. FCM kill-app ring — FCM-1  

### Step 4 — E2E encryption (Phase 1.5 — when offline router field-proven)

1. Add `libsignal_protocol_dart` (toolchain session)  
2. Pre-key API on qurbanisahulat (coordinate Sahulat freeze)  
3. Ciphertext envelope in `OfflineFrame.body` + offline bearers  
4. UI: lock icon, safety number, “groups not E2E yet”  
5. Wire `E2eCryptoService.encryptOutbound` (hook exists in `message_repository.dart`)  

**Until Step 4:** HTTPS transit + honest “planned (libsignal Phase 1.5)” in thread banner.

---

## Phase 2 UX (6067)

| Surface | Path |
|---------|------|
| Offline banner | `lib/widgets/chat/offline_chat_banner.dart` |
| Connectivity probe | `lib/services/chat_connectivity_service.dart` |
| Media guard | `ChatMediaPolicy` |
| E2E stub | `lib/services/e2e_crypto_service.dart` |

---

## What is NOT E2E today

| Mechanism | Meaning |
|-----------|---------|
| HTTPS + JWT | Server sees plaintext on cloud path |
| Backup AES-GCM | At-rest export only |
| Mesh Ed25519 | Integrity, not encryption |
| `confirmsEndToEndDelivery` on cloud bearer | Read/delivered ticks — not Signal E2E |

---

**Next action:** Run Wave 1 + Wave 2 field matrix on A23 + Paksaf; harden FAIL rows only.
