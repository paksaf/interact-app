# INTERACT Talk — session log

**Repo:** `~/dev/INTERACT/apps/interact-app`  
**Last updated:** 2026-09-02 (UTC+5)  
**Current build:** `0.5.25+6069`

Read this file first when resuming Claude/Cursor work on Talk.

---

## Where we are (6069)

| Area | Status |
|------|--------|
| **Lab deploy — Samsung A23** | ✅ `0.5.25+6069` via `bash build-and-install.sh a23` / `deploy-devices.sh a23` |
| **Lab deploy — iPad (USB)** | ✅ `6069` via `bash build-and-install-ios.sh ipad` → `flutter install` |
| **Lab deploy — iPhone Paksaf (USB)** | ✅ `6069` via `bash build-and-install-ios.sh iphone` → `flutter install` |
| **Lab deploy — car HU** | 🟨 Scripts ready; `CAR_HOST` not set — use `deploy-devices.sh car-wifi` until wireless adb paired |
| **flutter analyze** | ✅ 0 errors (5 infos only — const constructors, unnecessary import) |
| **Unit tests (core)** | ✅ 8 passed: `chat_phase2`, `field_probe`, `family_circle`, `social_post`, `e2e_envelope` |
| **Friends & Family panel** | ✅ Shipped 6068 — feed, circles, track tab |
| **Find friends hub** | ✅ @username, phone, contacts, invite |
| **Location tracking** | 🟨 Partial — existing trace + live share; linked from social Track tab |
| **E2E encryption (libsignal)** | 🟨 Phase 1.5 scaffold only — **encrypt OFF for users** |

---

## What shipped in this sprint (6068 → 6069)

### 6068 — Social / Friends & Family
- Models: `social_post.dart`, `family_circle.dart`
- Services: `family_circle_store.dart`, `social_feed_service.dart` (local-first)
- Screens: `social_panel_screen.dart`, `find_friends_screen.dart`
- Routes: `/social-panel`, `/find-friends`
- Entry: Me → Friends & Family; Contacts feed icon
- Doc: `docs/SOCIAL_FAMILY_PANEL_2026-09-02.md`

### 6069 — Device deploy + E2E scaffold
- `deploy-devices.sh`, `build-and-install-ios.sh` (ipad/iphone targets, devicectl fallback)
- `.device-env.example` — A23, iPad, iPhone, TV, CAR_HOST
- Docs: `docs/DEV_LAN_SETUP.md`, `docs/DEVICE_DEPLOY_2026-09-02.md`
- E2E: `libsignal_protocol_dart`, `e2e_envelope.dart`, `e2e_identity_manager.dart`, `e2e_prekey_api.dart`
- Gate: `--dart-define=INTERACT_E2E=true` — default `shouldEncryptOutbound = false`
- Doc: `docs/E2E_PHASE1_5_2026-09-02.md`

### Bug fixes (6067–6069)
- `FieldProbeService.recent()` — newest-first ordering
- `E2eCryptoService` — renamed getter to `shouldEncryptOutbound` (collision with method)
- Social panel — audience `ChoiceChip` (removed deprecated `DropdownButtonFormField.value`)
- `test/social_post_test.dart` — removed unused import

---

## Device registry (lab)

| Device | UDID / serial | Command |
|--------|---------------|---------|
| Samsung A23 | `R68T304FX1F` | `bash deploy-devices.sh a23` |
| iPad (muzafar's) | `00008112-000609C611F9401E` | `bash deploy-devices.sh ipad` |
| iPhone (Paksaf) | `00008101-001A3CE400E1401E` | `bash deploy-devices.sh iphone` |
| Bravia TV | `192.168.100.4:5555` | `bash deploy-devices.sh tv` |
| Car HU | set `CAR_HOST` in `.device-env` | `car` or `car-wifi` |

Copy `.device-env.example` → `.device-env` for local overrides.

---

## Verified terminal session (2026-09-02)

User ran on Mac:

```bash
cd ~/dev/INTERACT/apps/interact-app
bash build-and-install-ios.sh ipad    # ✅ Installed on iPad via flutter install
bash build-and-install-ios.sh iphone  # ✅ Installed on iPhone (Paksaf) via flutter install
```

Earlier same day: A23 arm64 APK install **Success** twice at 6069.

iOS build notes (non-blocking):
- CocoaPods MLKit `EXCLUDED_ARCHS` merge warnings — device builds succeed
- MLKit pods lack arm64 **simulator** slices — use **physical devices** for iOS lab
- Signing team: `7QU4S3Y4V2` (auto from Xcode project)
- Runner.app ~110 MB release

---

## Honest feature matrix (do not overclaim)

| Feature | User-visible today | Next step |
|---------|-------------------|-----------|
| Cloud chat (HTTPS) | ✅ | — |
| Offline bearers (BLE/LAN/outbox) | 🟩 Built, field proof open | Wave 1–2 field cases |
| Social feed | ✅ Local posts only | Sahulat `/api/v1/talk/social/*` |
| E2E 1:1 chat | 🟥 Off | Sahulat pre-key API + SessionBuilder |
| Groups E2E | 🟥 Not planned yet | Banner when E2E ships |
| Car HU deploy | 🟨 Script only | Pair wireless adb or `car-wifi` |

---

## Next work (priority order)

1. **Field validation** — Wave 1–2 on A23 + second device (`docs/CHAT_PHASES_ROADMAP_2026-09-01.md`)
2. **E2E Phase 1.5** — Sahulat `POST/GET /api/v1/talk/e2e/prekeys`, SessionBuilder/Cipher, upload on install
3. **Social smoke on iPad/iPhone** — SOCIAL-FEED-1, FIND-FRIENDS-1, RF-LOC-TRACE-1
4. **Car HU** — set `CAR_HOST`, run `deploy-devices.sh car` or browser sideload
5. **Lint cleanup** (optional) — const constructors, `push_service.dart` import

---

## Key commands

```bash
cd ~/dev/INTERACT/apps/interact-app

# Deploy (always specify -d when multiple iOS devices connected)
bash deploy-devices.sh a23
bash deploy-devices.sh ipad
bash deploy-devices.sh iphone

# Verify before commit
flutter analyze
flutter test test/chat_phase2_test.dart test/field_probe_test.dart \
  test/family_circle_test.dart test/social_post_test.dart test/e2e_envelope_test.dart

# E2E dev-only (does NOT enable encrypt for production)
flutter run --release -d 00008112-000609C611F9401E --dart-define=INTERACT_E2E=true
```

**Do not** paste shell commands into `flutter run` device picker — use `-d <UDID>` or type `1`/`2`.

---

## Doc index (Talk)

| Doc | Purpose |
|-----|---------|
| `SESSION.md` | **This file** — resume point |
| `docs/CHAT_PHASES_ROADMAP_2026-09-01.md` | Offline chat phases + field gates |
| `docs/SOCIAL_FAMILY_PANEL_2026-09-02.md` | Social panel spec |
| `docs/E2E_PHASE1_5_2026-09-02.md` | libsignal sprint |
| `docs/DEVICE_DEPLOY_2026-09-02.md` | Deploy commands + 6069 status |
| `docs/DEV_LAN_SETUP.md` | Device IDs + car HU first-time |
| `docs/IOT_UNIVERSAL_COMMS_2026-09-01.md` | IoT gateway / LoRa / RF |

---

## Handoff to Claude

- **All three mobile lab targets are on 6069** (A23, iPad, iPhone).
- Social panel is **local-first MVP** — not server-backed yet.
- E2E is **scaffold only** — `shouldEncryptOutbound` stays false until backend + field proof.
- iOS install path fixed: codesigned release + `flutter install -d UDID` works; no Xcode manual step needed when device is unlocked/trusted.
- Parallel workstream: offline chat field proof **before** investing in LoRa E2E or full E2E UX.

---

## Audit pass (2026-09-02, Fable) — Cursor 6056→6069 review

Risk-first audit of the uncommitted 6069 sprint (123 files). Deep-audited:
E2E crypto, offline router/bearers/inbound funnel, SMS, location. Skimmed:
IoT, social, docs.

**Prior fixes intact** (regression-checked): §21 mesh injection fix
(`mesh_cloud_bridge` send-free, `lan_service` renders via `plainBody` — NOT
reverted), §22 walkie LAN fallback, §23 auth OTP retry. ✅

**Architecture is sound.** The offline router faithfully implements the §19
design: outbound-only `send()` tries Cloud→LAN→P2P→BLE→LoRa; **SMS is
deliberately NOT an auto adapter** (only `SmsBearerService.sendConfirmed()`
behind the user sheet — money-safe); inbound funnel dedupes + stores locally,
sender-attributed, resolving mesh pubkeys to Talk identities. **No
confused-deputy inbound-send reintroduced.** Location share is user-initiated,
15-min time-bounded, revocable, foreground-only, local trace. ✅

**Fixed this pass:**
- 🔴 `E2eCryptoService.encryptOutbound` returned **plaintext** in the
  should-encrypt branch (silent downgrade breach). Now **fails closed**
  (throws) — dormant today (gate off), guards the future. Also
  `decryptInbound` no longer shows raw ciphertext (placeholder instead).
- 🔴 `inbound_funnel` keyed BLE frame ids by `DateTime.now()` → sahl_mesh TTL
  rebroadcasts made **duplicate messages in the UI**. Now keyed by stable
  `raw.hashCode`.
- 🟡 `E2eIdentityManager.install()` **discards** the pre-keys it generates (no
  PreKeyStore). Flagged in code — **do not enable E2E until pre-key
  persistence + session build/verify are added**; the scaffold is off.

**Not blocking, noted:** `_seenIds` eviction removes an arbitrary element
(Set.first), not the oldest — dedup window is approximate. Fine for now.

**Verdict:** the sprint is well-built and honest (SESSION feature matrix marks
E2E off, social local-only). Safe to commit after `flutter analyze` +
`flutter test`. E2E stays OFF.
