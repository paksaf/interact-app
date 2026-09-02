# Field test runbook — Wave 1 + Wave 2 (2026-09-02)

**Build:** `0.5.25+6069+` · **Devices:** Samsung A23 + iPhone Paksaf (or iPad)  
**In-app:** Me → Offline Connectivity → **Field validation**

Probe log tags TX/RX with the active case when you tap **Open** on a row.

---

## Before you start

1. Both phones on **6069+** (`bash deploy-devices.sh a23` / `iphone`)
2. Same lab Wi‑Fi for LAN cases (internet optional for Wave 1 RF)
3. Sign in on both with different INTERACT accounts
4. Open **Field validation** on the phone you use as primary tester

---

## Wave 1 — Phone RF (gate for LoRa)

| Case | Steps | Pass when |
|------|-------|-----------|
| **RF-BLE-1** | Both: Nearby mesh → start → send `ping` @ ~1 m | B sees A's frame; probe shows BLE tx/rx |
| **RF-BLE-2** | Same @ ~50 m line-of-sight | Frame arrives within ~30 s |
| **RF-BLE-3** | Add 3rd phone OR relay via gossip | All three see the gossip frame |
| **RF-LAN-1** | Offline LAN → bind port → send on same Wi‑Fi, **airplane + Wi‑Fi** | Peer receives without internet |
| **RF-LAN-2** | Three phones on LAN screen | All peers listed, message fan-out |
| **RF-P2P-1** | Offline LAN → P2P pair (2 Android) | Direct payload (optional) |
| **RF-OFFLINE-1** | Offline hub → LAN text + **LAN walkie** | No cloud; walkie PTT works |

**Gate:** mark Wave 1 PASS before LoRa E2E (RF-LORA-E2E-1).

---

## Wave 2 — Chats router

| Case | Steps | Pass when |
|------|-------|-----------|
| **RF-UNIFIED-1** | Chats → 1:1 thread → send with cloud off | Offline banner; message queues or uses LAN/BLE |
| **RF-BLE-CHAT-1** | Cloud off, BLE mesh running, send in thread | Delivery tick = **sensors** (handed to bearer) |
| **RF-LAN-CHAT-1** | Cloud off, LAN running, send in thread | Peer gets message on LAN |
| **RF-THREAD-PEER-1** | LAN chat between two signed-in users | Correct peer attribution (not self) |
| **RF-OUTBOX-ROUTER-1** | Send offline → restore cloud/LAN → flush outbox | Pending message delivers once |
| **RF-SMS-FALLBACK-1** | Stuck queue → user sheet → confirm SMS | Only after `delivered: true` from API |
| **RF-MESH-BIND-1** | Mesh identity → scan/bind QR | Mesh pubkey maps to Talk user in inbound |

---

## Recording results

1. Tap **Open** on the case (sets active probe `caseId`)
2. Run the steps on hardware
3. Mark **PASS / FAIL / SKIP** + notes (latency, OEM quirks)
4. **Refresh** probe log — confirm tx/rx rows show your case id

Export: copy wave summary from the Field validation screen (Wave header shows `n/total PASS`).

---

## E2E backend smoke (dev builds only)

After Sahulat deploys `POST/GET /api/v1/talk/e2e/prekeys`:

```bash
flutter run --release -d <UDID> --dart-define=INTERACT_E2E=true
```

1. Sign in → bootstrap uploads public pre-keys (fail-soft if route 404)
2. On second device, `GET …/e2e/prekeys/<peerUserId>` returns bundle + consumes one OTPK
3. **E2E-1** (future): SessionBuilder encrypt — wire body must be `e2e:v1:…` only

Production builds: **encrypt stays OFF** until E2E-1 passes.

---

## Next after Wave 1+2 PASS

- Wave 3: IoT-ACK-1, RF-IOT-CHAT-1, LoRa (only if Wave 1 PASS)
- E2E Phase 1.5: SessionBuilder + decrypt in `message_repository`
- Car HU: `bash deploy-devices.sh car-wifi`
