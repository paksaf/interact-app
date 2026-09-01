# Communication bearers — full scan, oldest principle to newest

**Date:** 2026-09-01 · **Companion to:** `OFFLINE_BEARERS_AUDIT_2026-09-01.md`
**Purpose:** the complete menu of ways a modern phone can move a bit to another
device with no internet — every antenna and every sensor — each rated for
INTERACT's actual market (rural/'off-grid Pakistan, no new hardware preferred).

A phone is not one radio. It is a bundle of transceivers and sensors, most of
which can be *bent into a communication channel*. The oldest ideas in signalling
— light you can see, sound you can hear, a compass needle that twitches near a
magnet — all have a modern sensor on the phone that can read them. This scan
lists them beside the modern antenna radios so the choice is made on merit, not
on what happened to be wired first.

Two honest framing rules carried from the RF ADR:
- **BLE and Wi-Fi are RF.** They are radio. They are simply not *long-range*
  radio. "Add real RF" does not mean "add LoRa"; it means use every antenna well.
- **No phone ships a LoRa or ham radio.** Kilometre-range always needs an
  external node. Everything in the "phone-native" tables below needs nothing but
  the handset already in the user's hand.

---

## A · Antenna bearers (true radios)

| Bearer | First principle / era | Phone antenna | Range | Payload | New dep? | INTERACT verdict |
|---|---|---|---|---|---|---|
| **Cellular voice/data** | 1G 1979 → 5G | modem | national | unlimited | no | Primary when data exists. Not "offline". |
| **SMS** | GSM 1992 | modem | national | 160 ch | Dexatel/capcom6 (have) | **Missing bearer, highest real value.** Works on signal-but-no-data — the actual rural failure. Ship it (audit step 7). |
| **Wi-Fi infra (same AP)** | 802.11 1997 | Wi-Fi | building | unlimited | no | **Live** (`lan_service`). Best offline path when any AP exists. |
| **Wi-Fi Direct / MPC** | Wi-Fi Direct 2010 / Multipeer 2013 | Wi-Fi+BT | ~100 m | unlimited | no | **Live** (`p2p_service`). Router-free. Same-OS only — the real limit. |
| **Wi-Fi Aware (NAN)** | 2015 | Wi-Fi | ~100 m | unlimited | plugin | **Planned.** Android's true serverless neighbour-discovery + data path; no AP, no pairing. iOS exposes only a slice. The modern answer to "Direct is same-OS only". |
| **BLE advertising/GATT** | Bluetooth LE 2010 | BT | ~10–100 m/hop | ~24 B/chunk | no | **Live** (`sahl_mesh` gossip, TTL+Bloom, multi-hop). Text forever — never promise media. |
| **BLE + extended adv** | BT 5.0 2016 | BT | ~200 m LOS | ~250 B | no (already 5.x) | **Tune, don't add.** Larger single-frame payload = fewer chunks for `sahl_mesh`. A parameter change, not a new bearer. |
| **UWB** | 802.15.4z 2020 (U1 chip) | UWB | ~10 m | low-rate + **cm ranging** | plugin, HW-gated | **Planned/niche.** iPhone 11+/some Android. Its gift is *precise distance/direction* — a hardware upgrade to `sahl_radar`, more than a message pipe. |
| **NFC** | ISO 14443 2004 | NFC coil | touch (<4 cm) | ~1–4 KB | plugin | **Planned, high value for identity.** Tap-to-exchange the MeshIdentity↔phone binding (audit step 6). Deliberate, physical, unspoofable-at-range. |
| **LoRa (via bridge)** | Semtech 2015 | *external* | 1–10 km | ~200 B | firmware (have) | **Gated** on Wave-1 field tests passing (ADR). Phone↔BLE↔LoRa node. |
| **Meshtastic (via bridge)** | 2020 | *external* | km, self-healing | ~200 B | RX done, TX todo | **Half-live.** `meshtastic_bridge_service` reads; `MeshPacket` TX unbuilt. |
| **Ham / APRS (via bridge)** | AX.25 1982 | *external* + **licence** | very long | tiny | HW + operator licence | **Documented, not product.** Needs a licensed operator; regulatory, not just technical. Keep as ADR only. |
| **Satellite (Emergency SOS)** | 2022 | sat modem | anywhere | tiny, OS-gated | **none exposed** | **Unavailable to apps.** iOS and Android keep it OS-only. Cannot build on it. State plainly so nobody plans around it. |

## B · Sensor / line-of-sight bearers (the old ideas, read by modern sensors)

These need no radio licence, no pairing, and often work when RF is jammed,
denied by permission, or simply off. They are short-range and slow — but they
are the fallbacks that have worked for a century.

| Bearer | Oldest form | Modern sensor that reads it | Range | Rate | New dep? | INTERACT verdict |
|---|---|---|---|---|---|---|
| **Visible light (screen/torch)** | Heliograph 1810s; Aldis lamp | camera / ambient-light | LOS, ~10 m | ~bytes/s | torch: none · camera-decode: DSP | **Best "old" proof.** Torch/screen blink a short **channel code** in Morse or on-off-keying; the far phone reads it by eye or camera. Zero pairing, works when BT is denied. |
| **QR / colour blocks** | 2D barcode 1994 (optical telegraphy lineage) | camera | LOS | ~KB one-shot | camera (have) | **Live principle** (already used for call invites). Extend to an **offline contact/channel card** — the safe, instant identity handoff. |
| **Acoustic (audible FSK/DTMF)** | Telephone DTMF 1963; acoustic-coupler modems | mic / speaker | room, ~10 m | ~10–40 B/s | DSP (no dep needed — `record`+`audioplayers` present) | **Planned, buildable with shipped deps.** "Chirp" a channel code across a room. Survives when every radio is off. Noisy, slow, charming, reliable. |
| **Ultrasonic (near-inaudible)** | ~19–21 kHz data-over-sound | mic / speaker | room | ~10 B/s | DSP | **Planned.** Same as above but silent; range shorter, phone-speaker limited. |
| **Infrared** | TV remote 1980s | IR blaster (some Android) *or* camera sees IR | LOS | low | HW-gated | **Niche.** Few phones still ship IR blasters. Where present, a genuine private LOS channel. Document, don't prioritise. |
| **Magnetometer signalling** | Telegraph/compass 1830s | magnetometer (compass) | ~cm–10 cm | very low | none | **Curiosity/covert.** A modulated electromagnet (or another phone's speaker coil) twitches the compass. Real, tiny bandwidth. Fun proof, not a product. |
| **Vibration / accelerometer** | Knock codes; Morse tapping | accelerometer | touching | very low | none | **Curiosity.** Two stacked phones pass taps. Novelty; note and move on. |
| **Screen↔camera (VLC framing)** | Semaphore/flag telegraph | camera | LOS | ~KB/s | camera + DSP | **Planned upgrade of QR.** Animated frames = a short *stream*, not one snapshot. The modern semaphore. |

---

## C · What "improve further" actually means here

Not "add ten radios." The phone already has strong ones. Improvement is three moves:

1. **Route across the antennas we already have** (the audit's `OfflineRouter`) so a
   Chats message picks LAN → Direct → BLE → SMS by itself. This is the multiplier.
2. **Add the two missing high-value bearers**, in order: **SMS** (antenna, national,
   trivial with Dexatel) and **NFC identity tap** (solves attribution/step 6).
3. **Keep one "old-school" line-of-sight fallback** — torch/QR channel-code — for
   the case every radio is off or denied. It costs almost nothing and it is the
   story that makes the offline claim believable to a field user.

Everything else in table B is a labelled experiment: real, correct, and honestly
ranked below these — so nobody spends a sprint modulating a compass while SMS is
still unbuilt.

## D · Dependency discipline (why most of this is "Planned", not "added today")

The interact-app toolchain is pinned (Flutter 3.41.6 / flutter_webrtc 1.4.0 /
livekit 2.8.1) and a build is in flight. Wi-Fi Aware, UWB and NFC each need a new
plugin, and a new plugin is exactly the kind of change the pin rules (§7 of the
Talk roadmap) say to make deliberately, with a full call-matrix retest — **never
casually before a test build**. SMS (backend), acoustic and torch/QR need **no
new dependency** (`record`, `audioplayers`, `camera` already ship). So the honest
build order respects the pin: backend/DSP bearers first, plugin-gated radios in a
dedicated toolchain session.

The in-app **Offline Comms Hub** (this session) introduces **zero new
dependencies** — it is pure Flutter that gathers the live bearers into one place
and shows the rest as labelled, correctly-described "Planned" tiles, so the whole
menu above is visible to the operator inside the app without touching the pin.
