# INTERACT Talk — Application Audit Dossier

**Classification:** INTERNAL  
**App:** INTERACT Talk (`interact-app`, package `com.interactpak.interact_talk`)  
**Audit date:** 2026-07-30  
**Last updated:** 2026-07-30 (attachment outbox · nav badges · CallKit inviteId · mesh bridge · Talk-as-login)  
**Ship build:** `0.5.1+4031` · APK `builds/InteractTalk-0.5.1-4031-arm64.apk` (after rebuild)  
**Backend:** `https://qurbanisahulat.com` Talk stack (`/api/v1/chat/*`, `/api/v1/talk/*`)  
**Device matrix:** Samsung A23 USB `R68T304FX1F` · Redmi Wi‑Fi sideload · Bravia TV (armeabi-v7a)

**Related:** [`SESSION_2026-07-26_MESH_WAVES.md`](SESSION_2026-07-26_MESH_WAVES.md) · [`BACKGROUND_RING_AND_CAPTIONS_2026-07-24.md`](BACKGROUND_RING_AND_CAPTIONS_2026-07-24.md) · [`OFFLINE_MESH_LORA_BRIDGE_2026-07-26.md`](OFFLINE_MESH_LORA_BRIDGE_2026-07-26.md) · [`PRD_PHASE_NEXT.md`](../PRD_PHASE_NEXT.md) · `_shared/knowledge-hub/APP_TASKS/interact-app.md`

---

## 1. Executive summary

Talk is the **voice/video-first** INTERACT communicator: Calls landing tab, Chats (1:1 + group + channel), Contacts, Me, Menu. Auth is OTP (WhatsApp-first fail-safe). Messaging and calls share the qurbanisahulat Talk APIs; offline text uses a local **outbox**; mesh/LAN/LoRa remain experimental side surfaces.

**Health (2026-07-30):** Phone A smoke OK after CallKit zombie fix. Chat list merges general/group/channel. Message load errors show Retry. Polish pass **4030** covers list previews, call-history errors, native accept→server respond, outbox UI + resume flush, PK phone normalize on group flows, channel read-only race, deep-link `/chat/:id` loader.

---

## 2. Capability matrix

| Area | Status | Notes |
|------|--------|-------|
| OTP auth + profile setup | **F** | Decoy/`delivered` gated; PK normalize |
| 1:1 chat send/receive | **F** | Poll 2s in thread; watcher 12s for banners |
| Groups create / add / leave | **F** | Phone normalize on create + add |
| Channels broadcast | **F** | Owner-only composer; list merge; channel badge |
| Reactions / reply / pin / edit | **F** | P1 overlay on thread |
| Voice notes | **F** | Upload + optional on-device transcript |
| Attachments | **F** | Local-file outbox (`chat_attach_local`) + post-upload send queue |
| Calls (WebRTC 1:1) | **F** | 45s connect deadline; CallKit clear on hangup |
| CallKit cold start | **F** | Consume accepted entry; respond(`accept`) when invite known |
| Missed-call callback | **F** | History prefers `threadId` re-ring |
| Offline text outbox | **F** | 15s flush; shell + thread banners; resume flush |
| Nav unread badges | **F** | Server `unreadCount` + Chats tab Badge |
| Mesh / LAN → cloud | **P** | `talk:0|phone|` / `talk:1|threadId|` frames bridge when online |
| FCM killed-app ring | **P** | **inviteId now in FCM data** (per-callee); field E2E after deploy |
| Talk-as-login (QR/OTP) | **F** | `/api/v1/talk/auth/device/*` + OTP deliver + Talk UI |

Legend: **F** shipped · **P** partial · **M** missing

---

## 3. Changes this session (2026-07-30)

### 3.1 Reliability (pre-polish)
- Message load: `_firstLoadDone` + error/Retry UI (`chat_thread_screen.dart`)
- `createChannel` envelope peel (match `createGroup`)
- `listAllThreads()` merge general + group + channel
- Typing indicator uses `_myId`
- CallKit teardown on hangup + cold-start consume

### 3.2 UI polish
- Chat previews: kind-aware labels; “Video”/“Voice” → call labels; empty → “Tap to open”
- Channel campaign icon on list tiles
- Calls history `hasError` + Retry
- BrandedAppBar subtitle ellipsis
- Empty thread / channel empty copy
- Offline queue banner on shell + open thread

### 3.3 Calls
- Native accept posts `respond('accept')` when `inviteId` available (CallKit `extra` + poll fallback)
- Connecting overlay: peer avatar + “Waiting for the other side…”
- Call-back uses `threadId` when present
- `withOpacity` → `withValues` on connecting scrim

### 3.4 Groups / data / offline
- PK phone normalize: new chat, new group, add member
- Channel read-only until `_myId` resolves (no composer flash)
- Channel management entry in app bar
- Outbox flush every **15s**; flush on app resume; tap-to-retry banners
- Outbox drain refreshes open thread (clears pending clocks)
- `/chat/:id` without `extra` → `ChatThreadLoader`
- Attachment failure → Retry (re-upload + send)

---

## 4. Talk-as-login API (for other apps)

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `POST /api/v1/talk/auth/device/start` | none | `{appId,appName?}` → `{challengeId,displayCode,qrPayload,expiresAt}` |
| `POST /api/v1/talk/auth/device/approve` | Talk JWT | User approves code/QR |
| `GET /api/v1/talk/auth/device/status/:id` | none | Poll → `approved` + JWT + user |
| `POST /api/v1/talk/auth/otp/deliver` | `INTERACT_HUB_TOKEN` | Deliver OTP into Talk, or install invite if not on Talk |
| `GET /api/v1/talk/auth/inbox` | Talk JWT | Recent codes for this user |

Body: `{ phone? \| email?, code, appId, appName? }`

- **On Talk:** WhatsApp-style OTP (code-first) → push + Login codes inbox. `qrPayload` in response/push for TV/camera (not required for phones).
- **Not on Talk:** PK → WhatsApp **and** SMS install invite; other countries → WhatsApp; email path → email with download + short INTERACT summary.

QR payload: `interact://talk/approve-login?code=NNNNNN&c=<challengeId>`

Talk UI: Menu → **Approve login** · **Login codes** · **Login QR**

Migration: `qurbanisahulat/prisma/migrations/20260730120000_talk_device_auth/` (applied on VPS 2026-07-30)

---

## 5. Known gaps / next

1. Field E2E: killed-app CallKit A→B after QS deploy (verify `inviteId` in FCM)
2. Server `lastMessageKind` consistently (client already reads it)
3. Phone storage nearly full on A23
4. Richer unread counts (v1 is 0/1 from lastReadAt)
5. WhatsApp install invites outside 24h session may need an approved template SID

---

## 6. Manual smoke (Phone A)

- [x] Launch lands on Calls (not stuck Connecting after End)
- [x] Chats list shows threads; open thread shows history
- [x] New menu: chat / group / channel / community
- [ ] Airplane mode → send text/attach → banner → online → pending clears
- [ ] Create group with `03xx` phone → member resolves
- [ ] CallKit accept while killed → room + invite accept (needs deploy)
- [ ] Menu → Login QR → Approve login on second device / status poll
- [ ] OTP deliver via hub token → Login codes inbox

---

## 7. Install / ship

```bash
# API (VPS)
cd qurbanisahulat && npx prisma migrate deploy
# Client
cd interact-app
# NEVER use --target-platform android-arm64 alone for OTA/Wi‑Fi — 32-bit phones crash.
# Prefer: bash build-and-install.sh wifi   OR   bash scripts/publish-ota.sh
flutter build apk --release \

  --build-number=4031 --build-name=0.5.1
adb -s R68T304FX1F install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## 8. Doc sync

| Doc | Action |
|-----|--------|
| This dossier | Updated 4031 |
| `APP_TASKS/interact-app.md` | Mark outbox/badges/auth DONE |
| Ring route FCM | Per-callee `inviteId` shipped in code — deploy QS |
