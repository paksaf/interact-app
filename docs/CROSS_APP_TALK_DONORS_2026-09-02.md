# INTERACT Talk → Maps & Lifestyle — cross-app donor matrix

**Date:** 2026-09-02 · **Donor:** `interact-app` (`0.5.25+6069`, branch `feat/talk-offline-mesh-camera`)  
**Targets:** `interact-maps/interact-maps-flutter`, `interact-lifestyle/mobile`

Talk is the integration hub for offline mesh, social status, E2E, friends map, and field validation. Maps and Lifestyle already share Firebase (`interact-lifestyle` project), IL weather client (Maps), and comms patterns — this doc lists **what to port next**, in priority order.

---

## Already in Talk (6069) — reference implementations

| Capability | Talk paths | Notes |
|------------|------------|-------|
| **Social status / reels** | `lib/widgets/social/*`, `social_panel_screen.dart`, `social_feed_service.dart` | Local-first; 24h story window; photo/video compose |
| **Friends map** | `lib/screens/location/friends_map_screen.dart`, `offline_maps_service.dart` | Ported *from* Maps donor |
| **Offline router** | `lib/services/offline_router.dart`, outbox, bearers | LAN + BLE + cloud fallback |
| **E2E Phase 1.5** | `lib/services/e2e/*`, `e2e_crypto_service.dart` | libsignal; encrypt OFF prod; pre-key upload |
| **Field validation** | `lib/screens/debug/field_validation_screen.dart`, `field_probe_service.dart` | Wave 1+2 caseIds |
| **Device deploy** | `deploy-devices.sh`, `build-and-install*.sh` | A23 / iPad / iPhone lab |
| **Gateway Console** | `lib/screens/admin/gateway_console_screen.dart` | Fable `a2f81fa` — manager WebView |
| **Find friends** | `find_friends_screen.dart`, `@username` lookup | CRM-backed |
| **Camera effects** | `camera_effects_screen.dart` | ML Kit selfie segmenter |
| **Location trace** | `location_trace_service.dart`, live share | Offline-capable fixes |

---

## → Interact Maps (priority after Talk lab gate)

Maps already has: friends list, groups, chat, media library, incoming media, live cam, trek, geofences, OBD, dashcam. **Gap vs Talk:**

| # | Feature from Talk | Maps target | Effort | Why |
|---|-------------------|-------------|--------|-----|
| 1 | **Family status UI** | `/family-status` (started) | S | Same local-first feed; maps night theme |
| 2 | **Offline outbox router** | `chat_service.dart` + mesh | M | Unified LAN/BLE when API down |
| 3 | **Field validation screen** | New debug route under Settings | S | Reuse Wave 1 RF cases for maps mesh QA |
| 4 | **Friends map (reverse port)** | Enhance `friends_screen` mini-map | M | Talk has full-screen FMTC map — merge |
| 5 | **E2E envelope (read-only)** | Chat thread decrypt when flag on | L | After Sahulat pre-key API prod |
| 6 | **Find friends / invite** | Extend `/invite` with @username | S | Talk CRM lookup pattern |
| 7 | **Deploy scripts** | `deploy-devices.sh` pattern | S | Same A23/iPhone lab |
| 8 | **Gateway Console** | Manager menu (if maps admins link WA) | S | Copy WebView + Basic auth dialog |

**Maps → Talk (already donated):** FMTC offline tiles, BackgroundGpsService pattern, camera→InputImage pipeline.

---

## → Interact Lifestyle (after Maps status ships)

IL already has: schedule/coach, guardian, escrow sessions, media library (bookmarks), maps/trek hub, comms messages, LAN media share, LiveKit rooms, Zeka voice.

| # | Feature from Talk | IL target | Effort | Why |
|---|-------------------|-----------|--------|-----|
| 1 | **Family status UI** | `/family-status` (started) | S | Guardian/family circle UX |
| 2 | **Find friends hub** | More → Family section | S | @username + contacts + invite |
| 3 | **Offline mesh / LAN chat** | Extend `messages_hub_page` | L | Coach/guardian offline |
| 4 | **Field validation** | Debug overlay (dev builds) | S | BLE/LAN regression |
| 5 | **E2E client** | Comms threads when IL API adds keys | L | Shared libsignal module candidate: `_shared/packages/` |
| 6 | **Friends map** | `maps_hub_page` link | M | Talk FMTC + trace overlay |
| 7 | **Location live share** | Guardian dashboard | M | Talk `location_share_service` |
| 8 | **OTP delivery guard** | Login + comms OTP | S | Require `delivered === true` (Pattern 10) |
| 9 | **Device deploy scripts** | `mobile/scripts/` | S | IL lab parity |
| 10 | **Social circles** | Guardian wards + family chips | M | `family_circle_store.dart` |

**IL → Talk (already donated):** Weather client (`il_lifestyle_client`), Firebase project, OTP backend patterns.

---

## Shared package candidates (`~/dev/INTERACT/_shared/packages/`)

Extract when **third app** needs the same code:

| Package | Contents | Consumers |
|---------|----------|-----------|
| `social-status` | `SocialPost`, feed service interface, stories/reels widgets (themed) | Talk ✅, Maps, IL |
| `talk-e2e-client` | libsignal store, envelope, pre-key upload | Talk, IL comms |
| `field-probe` | Case IDs, probe log format | Talk, Maps mesh QA |
| `offline-bearer` | Outbox + bearer selection interface | Talk, Maps chat |

Until then, **copy-adapt** from Talk (AGPL) with SPDX headers — matches current fleet practice.

---

## Recommended sequence (user order 2026-09-02)

1. ✅ **Commit Talk social UI** — `034eccd`
2. ✅ **Deploy A23** — 6069 + social
3. 🟨 **Deploy iPhone** — fix `LANG=en_US.UTF-8` for CocoaPods; USB or `flutter install -d <UDID>`
4. 🟨 **Field Wave 1+2** — two phones, Me → Field validation (`docs/FIELD_TEST_WAVE1_WAVE2_2026-09-02.md`)
5. **Maps:** finish `/family-status` route + wire (paused until step 4 PASS)
6. **IL:** finish `/family-status` route + More tile + router
7. **E2E prod:** deploy qurbanisahulat pre-key migration when freeze lifts

---

## Field Wave 1+2 quick checklist (hardware)

**Phones:** A23 (`R68T304FX1F`) + iPhone Paksaf (`00008101-001A3CE400E1401E`)  
**Build:** `0.5.25+6069+` with commit `034eccd` social UI

1. Both signed in, same lab Wi‑Fi  
2. Me → **Field validation**  
3. Wave 1: RF-BLE-1, RF-LAN-1, RF-OFFLINE-1 (minimum gate)  
4. Wave 2: RF-UNIFIED-1, RF-LAN-CHAT-1, RF-OUTBOX-ROUTER-1  
5. **Social smoke:** Me → Friends & Family → Share photo → status ring → tap → reels viewer

Mark PASS/FAIL in-app per case; export wave summary from Field validation header.
