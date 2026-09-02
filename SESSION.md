# INTERACT Talk — session log

**Repo:** `~/dev/INTERACT/apps/interact-app`  
**Last updated:** 2026-09-02 (UTC+5) — social UI committed + lab deploy  
**Current build:** `0.5.25+6069`  
**Git branch:** `feat/talk-offline-mesh-camera`  
**Latest commit:** `034eccd` — social status/reels/media share  
**Fable (committed):** `a2f81fa` — Gateway Console in-app embed  
**Lab deploy:** A23 ✅ + iPhone Paksaf ✅ (6069 + social UI)

Read this file first when resuming Claude/Cursor work on Talk.

### Board (2026-09-02 afternoon)

| Lane | Owner | Status |
|------|-------|--------|
| **Gateway Console in-app** | Fable | ✅ **a2f81fa** — Menu → Gateway Console → WebView |
| **E2E pre-keys** | Cursor | 🟨 Coded; migration applied **local**; prod deploy **frozen** |
| **Field Wave 1+2** | Hardware | 🟨 A23 + iPhone on 6069 — run Me → Field validation |
| **Social status UI** | Cursor | ✅ **034eccd** — stories row + reels + media share |
| **UAE WhatsApp** | Ops | 🟨 Console ready; **`pm2 start sahulat-baileys-ae`** before UAE QR link |
| **PK SMS OTP** | Phone | 🟨 capcom6 SIM/carrier — physical phone fix |

**Vitest OTPK fixture:** `tests/lib/talk-e2e-prekeys.test.ts` uses ≥8-char `publicKey` (matches server validator). Re-run: `npx vitest run tests/lib/talk-e2e-prekeys.test.ts`

---

## Where we are (6069)

| Area | Status |
|------|--------|
| **Lab deploy — Samsung A23** | ✅ `0.5.25+6069` via `bash build-and-install.sh a23` / `deploy-devices.sh a23` |
| **Lab deploy — iPad (USB)** | ✅ `6069` via `bash build-and-install-ios.sh ipad` → `flutter install` |
| **Lab deploy — iPhone Paksaf (USB)** | ✅ `6069` via `bash build-and-install-ios.sh iphone` → `flutter install` |
| **Lab deploy — car HU** | 🟨 Scripts ready; `CAR_HOST` not set — use `deploy-devices.sh car-wifi` until wireless adb paired |
| **flutter analyze** | ✅ No issues found (2026-09-02 post-audit) |
| **Unit tests** | ✅ **48** passed (full suite — not just the 5-file smoke subset) |
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

1. **Field validation** — Wave 1–2 on A23 + Paksaf/iPad (`docs/FIELD_TEST_WAVE1_WAVE2_2026-09-02.md`)
2. **Deploy E2E pre-key API** — qurbanisahulat migration `20260902100000` + routes
3. **E2E Phase 1.5 client** — SessionBuilder/Cipher (encrypt still OFF until E2E-1)
4. **Car HU** — set `CAR_HOST`, run `deploy-devices.sh car` or browser sideload

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

---

## Field + polish pass (2026-09-02, Fable)

**Walkie-talkie field test: PASS ✅** — LAN walkie confirmed working device-to-device
(in-app Wi-Fi relay, no cloud, no LiveKit). The earlier `/live/token` errno-7 screen was
the *cloud* LiveKit walkie failing offline; §22 auto-fallback now routes PTT to the LAN
walkie when cloud is unreachable. Real path validated on hardware.

**5 analyze infos cleared (all `prefer_const`, no behavior change):**
- `core/offline/message_delivery_state.dart` — `const MessageDeliveryVisual(...)` (cloudRead)
- `screens/iot/iot_comms_screen.dart` — `const TabBar(...)`
- `services/push_service.dart` — dropped redundant `foundation.dart` import (widgets re-exports)
- `test/iot_frame_test.dart` — two `const IotFrame(...)`

`flutter analyze` expected clean (No issues found). `flutter test` still 48 passing.

**Remaining open items — both need operator input / server access (not code-blind):**
1. **E2E encryption completion (§ pre-key API)** — blocked on: (a) Sahulat pre-key
   publish/fetch endpoint on the frozen backend, (b) PreKeyStore + SessionBuilder impl,
   (c) on-device session test, (d) security review. Scaffold stays OFF (`INTERACT_E2E=false`).
2. **LiveKit API key rotation (§9)** — the old key pair was printed to a terminal and is
   burned. Rotate on the VPS: `livekit-server generate-keys` → update `/etc/livekit/server.yaml`
   + hub `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` env → `systemctl restart livekit-server`
   + `pm2 restart interact-connect --update-env`. Needs SSH to the VPS.

---

## LiveKit key rotation — COMPLETED server-side (2026-09-02, Fable)

The burned LiveKit key (`APIGHn3VxZqB6ba`, exposed to a terminal earlier) is now
**dead everywhere**. Rotated to a new pair (`APIDL6tsttNr7hK` / 44-char secret).

**Key finding — the server does NOT read keys from `server.yaml`.** Its systemd unit
carries `EnvironmentFiles=/etc/interact/secrets/livekit-keys.env`, whose `LIVEKIT_KEYS`
var **overrides** the config-file `keys:` block. Editing `server.yaml` + restart did
nothing (proved: server booted 04:09:36 with `server.yaml` holding the new key at
04:09:20, yet still accepted only the old key). The authoritative key source is
`/etc/interact/secrets/livekit-keys.env` — edit there and restart `livekit-server`.

**Three token minters (not one)** all had to be synced to the new pair:
- `interact-connect` — `/srv/interact-connect/interact-connect/.env.production` **and**
  its `.next/standalone/.env.production` (standalone bundle reads the copy; `pm2 env`
  shows nothing because it's dotenv-loaded, not pm2-injected).
- `interact-caption-agent` — `/srv/interact-caption-agent/.env`.
- `il-api` — `/opt/interact-lifestyle-api/.env` (`IL_LIVEKIT_API_KEY/SECRET`, IL_ prefix).

**pm2-cache gotcha (il-api):** its ecosystem injects the `.env` values as `env:`, so pm2
kept the OLD key in its dump. `pm2 restart --update-env` did NOT clear it — needed
`pm2 delete il-api && pm2 start ecosystem.config.cjs --only il-api && pm2 save`.

**Verified server-side** with the livekit-server-sdk (`RoomServiceClient.listRooms`):
new key → SERVER-OK; old key → `invalid API key` (DEAD). il-api env confirms `APIDL…`.

**Still to confirm:** live Townhall / cloud Walkie join from the app (end-to-end proof).
**Note:** the new secret appeared unmasked in the Cowork transcript — if that's treated
as sensitive, do one more clean `generate-keys` rotation using the same 3-minter +
env-file procedure above.

---

## Cursor spot-check (2026-09-02) — re-audit not required

Fable's risk audit + fixes are **verified in tree**. No full re-audit needed unless
new commits land on crypto/router/inbound paths.

| Check | Result |
|-------|--------|
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 48 passed |
| E2E fail-closed | ✅ `encryptOutbound` throws when gate+active; `decryptInbound` placeholder |
| BLE dedupe | ✅ `inbound_funnel.dart:78` — `ble-${evt.from}-${evt.raw.hashCode}` |
| §21 injection | ✅ `mesh_cloud_bridge` send-free; LAN uses `plainBody` only |
| SMS auto-send | ✅ Not in `OfflineRouter` adapters — `sendConfirmed()` only |
| Pre-key gap | 🟡 Flagged in `e2e_identity_manager.dart` — do not enable E2E yet |

**Minor future note (not blocking while E2E off):** `message_repository.upsertInbound`
does not call `decryptInbound` — wire that when SessionCipher lands.

**Working tree:** `SESSION.md` may be dirty; branch was **ahead 2** of remote at spot-check.

---

## Login OTP delivery — WhatsApp restored, SMS SIM flagged (2026-09-02, Fable)

**Root cause of the login failure:** both OTP channels were down at the gateway —
`baileys_wa: not_ready` and `twilio_disabled` (seen in interact-connect out.log).

**WhatsApp (Baileys) — FIXED.** Worker `sahulat-baileys` (pm2 id 1),
`/srv/qurbanisahulat/scripts/baileys-worker/index.cjs`, HTTP health on
127.0.0.1:7100. `/health` reported `{"ready":false,"error":"connection closed
(code=401)"}` → **401 = the linked device was removed**, session dead, restart
can't fix. Re-linked by: `pm2 stop sahulat-baileys` → move `auth/` aside +
`mkdir auth` → run the **worker's own** `node index.cjs` in the foreground (it
fetches the current WA version and prints its own QR; a hand-rolled minimal
Baileys script 405s) → scan QR from the gateway line **+92 330 3570463** (WhatsApp
→ Linked Devices) → Ctrl+C → `pm2 start sahulat-baileys --update-env` → `pm2 save`.
Now `/health` = `{"ready":true,"error":null}`. Gateway phone number: +92 330 3570463.

**SMS (capcom6 Android gateway) — server-side OK, phone SIM is the blocker.**
`src/lib/messaging/capcom6-sms.ts`, cloud mode `https://api.sms-gate.app/3rdparty/v1`,
basic auth `ANDROID_SMS_GATEWAY_USER/PASSWORD`. Auth verified (`auth_http=200`),
device `rwfRSotKCE6PxUeL1EWLl` registered, delivered fine Aug 30–31. Recent sends
(Sep 1) fail with `RESULT_ERROR_GENERIC_FAILURE` (and a few SMSC 69/70 from
+923330005150) — an **Android/SIM-level** failure on the gateway phone, not the
server: likely SIM balance/signal/SMS-permission, or carrier bulk-SMS throttling.
Fix is on the physical phone; server needs no change. Twilio is fully configured
but off (`TWILIO_ENABLED` != 1) — flip that for a cloud SMS fallback if the SIM
can't be restored.

**Still to verify:** trigger a real login OTP to confirm WhatsApp delivery
end-to-end.

---

## Gateway Console — Phase 1 shipped (2026-09-02, Fable)

Built a self-service **Interact Gateway Console** so admins re-link WhatsApp /
read OTP-gateway health without SSH — because SMS/WhatsApp login breaks recur.
Lives in repo at `_shared/gateway-console/` (html + `gateway-console-server.cjs`
orchestrator + `install-on-vps.sh`). Runs on the VPS under pm2
`interact-gateway-console` on 127.0.0.1:7110, beside the Baileys worker, NO
frozen-backend change. Reached now via `ssh -L 7110:127.0.0.1:7110 interact`.
Token in pm2 env (id 16). **Verified live**: PK card shows WhatsApp ready +
capcom6 SMS "SIM failing" (17 ok/8 failed) + a Re-link button (QR + pairing
code) that automates the borrow-auth re-pair flow.
Companion handout: `_shared/docs/OTP_GATEWAY_FIX_RUNBOOK_2026-09-02.md` +
`gateway-doctor.sh`. Next: Caddy proxy behind admin auth (surface 2), panel +
chat-app embeds (surface 3), multi-country provisioning (needs backend).

**Update (same day):** Gateway Console Phase 2 done — live behind admin login at
https://gateways.interactpak.com (Caddy basic_auth + token injection; apply with
`caddy reload`, not `systemctl reload` — unit quirk). Multi-country PROVEN: 🇵🇰
(7100) + 🇦🇪 (7101, sahulat-baileys-ae) both live, each with its own worker/auth
and self-service QR/pairing-code re-link. Full deploy notes in
`_shared/gateway-console/README.md`.

---

## 2026-09-02 — Gateway Console QR fix redeploy + in-app embed

**QR fix redeployed.** `install-on-vps.sh` pushed the patched console
(`interact-gateway-console` pm2 id 20, online). The QR tab now polls
`/:id/health` and renders the `qrDataUrl` image instead of falling back to
the pairing code; server `startRelink` ends any prior session and creates a
fresh Baileys socket per call so switching QR↔code mode works. Token
unchanged: `7c49d1e75f65d05798cdb076ae520218`. Live behind Caddy admin login
at https://gateways.interactpak.com.

**Open item — UAE worker stopped.** `sahulat-baileys-ae` (pm2 id 18) shows
`stopped` / pid 0. Restart (`pm2 start sahulat-baileys-ae`) before/after the
UAE QR link so the line stays up once linked. Pairing-code link for UAE was
rejected by the phone ("Couldn't link device — check the number"); switched
to QR (no number matching).

**App embed (this session).** Managers can now open the Gateway Console
in-app, so a country can re-link WhatsApp (QR/pairing) or check SMS health
from the phone when Twilio/capcom6 fail — no SSH.
- `lib/screens/admin/gateway_console_screen.dart` — WebView embed of
  gateways.interactpak.com. `onHttpAuthRequest` forwards the Caddy Basic-auth
  challenge to a native dialog; creds optionally saved in
  flutter_secure_storage (type once per device). App-bar actions: reload,
  "Open in browser" (url_launcher fallback), "Clear saved login". Error state
  with retry.
- `pubspec.yaml` — added `webview_flutter: ^4.7.0` (needs ≥4.7 for
  onHttpAuthRequest; caret down-solves to newest release Flutter 3.27 allows).
- `lib/main.dart` — route `/gateway-console` + import.
- `lib/screens/tabs/menu_tab.dart` — "Gateway Console" tile (hub icon).
- INTERNET permission already declared; no other native config needed.
- **Security:** nothing hard-coded — the Caddy admin Basic-auth password is
  the gate, same as the web. VERIFY: run `flutter pub get` + `flutter analyze`
  (couldn't run from the bridge; Flutter not on that shell's PATH).

**Pakistan SMS still SIM-level.** capcom6 `RESULT_ERROR_GENERIC_FAILURE` on
the PK phone (17 ok / 8 failed = carrier A2P throttling signature). Fix is
physical: SMS bundle/balance, reboot radio, capcom6 battery-optimization
exempt + SEND_SMS granted. Real fix for scale = proper A2P route per country
(the console's fallback purpose).

---

## 2026-09-02 (cont.) — E2E SessionBuilder, Friends map, IoT auto-reconnect, iOS/DNS/permission fixes

**Commits on `feat/talk-offline-mesh-camera`:**
- `a2f81fa` — Gateway Console embedded in app (WebView, Menu tile).
- `8ba74b9` — Friends map + offline tiles; iOS location Info.plist keys; DNS failover fix (iPhone Recent-calls "no wifi"); sequential permission prompts.
- `5b54070` — Launch-time IoT RF-HTTP auto-reconnect; Friends map in Offline Hub; map empty-state hint.
- `8cdd56c` — E2E SessionBuilder + SessionCipher over a persistent Signal store.

**E2E SessionBuilder (8cdd56c) — encryption path EXISTS, gated OFF (INTERACT_E2E=false).**
- e2e_signal_store.dart: all four libsignal stores on secure storage; ratchet survives restarts.
- e2e_session_service.dart: ensureSession + encrypt/decrypt; payload <type>:<base64> inside e2e:v1:.
- e2e_crypto_service.dart: real encrypt/decrypt, status->active after key sync, fail-closed.
- message_repository.dart: inbound e2e:v1: decrypted before store/display.
- analyze clean. Two-device E2E-1 test IN PROGRESS: Samsung(A)+iPhone(B) both on the E2E build.
- Gotcha: SignedPreKeyRecord uses fromSerialized, PreKeyRecord uses fromBuffer.
- After test: reinstall A+B WITHOUT the define to return to shipping builds.
