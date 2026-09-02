# Offline dual-device test — iPhone + Samsung (no internet)

**Build:** `0.5.16+6056` · **Branch:** `feat/talk-offline-mesh-camera`  
**Devices:** Paksaf `00008101-001A3CE400E1401E` · Samsung `R68T304FX1F`

## What changed in 6056

| Area | Change |
|------|--------|
| LAN walkie | Host shows **IP:port** + copy button; **Join by IP** when mDNS fails |
| LAN text | Offline LAN screen shows **broadcast address** while scanning |
| Field validation | Added **RF-WALKIE-1/2**, **RF-OFFLINE-1** checklist rows |
| Core | `lib/core/net/local_lan_ip.dart` — shared LAN IPv4 helper |

## Build + install

```bash
cd ~/dev/INTERACT/apps/interact-app
bash scripts/offline-dual-device-test.sh install
```

Or separately:

```bash
# Samsung
bash build-and-install.sh a23

# iPhone
flutter build ios --release
flutter install --release -d 00008101-001A3CE400E1401E
```

## Go fully offline (both devices)

1. Connect both to **same Wi‑Fi** (e.g. home router).
2. **Airplane mode ON** on both.
3. **Wi‑Fi ON** on both (cellular stays off).
4. iPhone: **Settings → INTERACT → Local Network → ON**.
5. Optional: disable router WAN / unplug uplink to prove no leak.

Cloud chat and LiveKit **should fail** — that is correct. Offline bearers must still work.

## Test matrix

Open **Me → Field validation** on one device; mark PASS/FAIL.

| ID | Steps | Pass criteria |
|----|-------|---------------|
| **RF-LAN-1** | Me → Offline hub → Same Wi‑Fi. Both open Offline LAN. Select peer, send text both ways. | Round-trip each way ≤ 5s |
| **RF-WALKIE-1** | Samsung hosts WALKIE1 → Open channel. iPhone joins (list or **Join by IP**). Push-to-talk both ways. | Audio both directions; log shows `(2 in room)` |
| **RF-WALKIE-2** | iPhone hosts; Samsung joins | Same as above |
| **RF-OFFLINE-1** | Airplane+Wi‑Fi only. Run RF-LAN-1 + RF-WALKIE-1 | Cloud dead; LAN text + walkie OK |
| RF-BLE-* | Me → Nearby mesh (optional; keep screens open) | Gossip at 1m — separate from Wi‑Fi path |

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Empty peer list (LAN text) | Same SSID; wait 30s; check Local Network on iPhone |
| Empty walkie channels | Host first on Samsung; iPhone use **Join by IP** with host IP:port |
| Walkie connects, no audio | Grant mic; ignore permission_handler false negative on iOS |
| AP isolation | Router blocks client-to-client — use phone hotspot as AP instead |

## Manual IP join (walkie)

1. **Host** taps **Host this channel** → note **Join manually: 192.168.x.x:port**.
2. **Joiner** expands **Join by IP (mDNS blocked)** → enter IP, port, same channel code → **Join with IP**.

## Not in scope (6056)

- Chats tab still cloud-only (OfflineRouter not built)
- BLE mesh voice (Phase 2)
- LoRa hardware gate

See `docs/OFFLINE_BEARERS_AUDIT_2026-09-01.md` for architecture.
