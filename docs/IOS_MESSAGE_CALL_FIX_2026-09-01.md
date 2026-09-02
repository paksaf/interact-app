# iOS Talk — messages & calls fix (2026-09-01)

**App:** interact-app `0.5.16+6055` · branch `feat/talk-offline-mesh-camera`  
**Device:** iPhone Paksaf (`00008101-001A3CE400E1401E`)

## Root cause

Two independent failures stacked on iPhone:

### 1. Incomplete ApiBase DNS failover (primary — breaks messages **and** calls)

The Aug 26 `ApiBase` / `runWithFailover` work only wired **chat list** (`listThreads`). Every other Talk REST path still hit `https://qurbanisahulat.com` directly:

| Path | Symptom when apex DNS fails |
|------|-----------------------------|
| `loadThreadAndMessages` | Thread opens but poll never loads/sends; composer looks dead |
| `TalkApi.createRoom` / `joinRoom` | Call stuck on "Connecting…" / immediate error — no WS token |
| `CallSignaling.ring` / `_poll` | Outgoing ring never reaches peer; no incoming ring |
| `AuthService._doRefresh` / `establishRefreshTokenIfNeeded` | Expired access token + failed refresh → silent **401** on all `/api/v1/*` while UI still shows signed-in |

Additionally, `ApiBase.init()` **fire-and-forgot** the health probe (`unawaited(checkAndMaybeSwitch())`), so cold-start requests raced the background probe and consistently lost on iPhone cellular DNS (often resolves `talk.interactpak.com` while `qurbanisahulat.com` errno-8 / `nodename nor servname`).

**Not an iOS-only bug** — but iPhone cellular + saved dead `talk_api_base` in SharedPreferences made it show up there first. Android on the same Wi‑Fi could still resolve the apex.

Auth OTP (`www.interactpak.com`) was **not** affected — only Sahulat/Talk hosts behind `ApiBase.current`.

### 2. iOS push / permission gaps (secondary — background call ring)

| Issue | Effect |
|-------|--------|
| `PushService._register` hardcoded `platform: 'android'` | Server stores iOS FCM tokens as Android → no background/killed call push on iPhone |
| Missing `ios/Runner/GoogleService-Info.plist` | `Firebase.initializeApp()` fails in `main()` (caught); FCM never starts on iOS until plist is added from Firebase console |
| Podfile lacked `permission_handler` `GCC_PREPROCESSOR_DEFINITIONS` | iOS stub returns "denied" for mic/camera even when Settings show ON; WebRTC can connect with no usable tracks |

WebRTC stack (`flutter_webrtc` 1.4.0), `Info.plist` mic/camera/background modes, and iOS audio session setup in `meeting_room_screen.dart` were already correct for this branch.

## Fixes applied (2026-09-01)

| File | Change |
|------|--------|
| `lib/services/api_base.dart` | `init()` **awaits** `checkAndMaybeSwitch()` before first API traffic |
| `lib/services/chat_api.dart` | `loadThreadAndMessages` wrapped in `runWithFailover` |
| `lib/services/talk_api.dart` | `createRoom` / `joinRoom` wrapped in `runWithFailover` |
| `lib/services/call_signaling.dart` | `_poll` / `ring` wrapped in `runWithFailover` |
| `lib/services/auth_service.dart` | `_doRefresh` + `establishRefreshTokenIfNeeded` use `runWithFailover`; iOS device label + correct `appId` |
| `lib/services/push_service.dart` | Register FCM as `platform: ios` on iPhone; fail-soft init when Firebase missing |
| `ios/Podfile` | Enable mic/camera/photos/speech/bluetooth permission_handler macros |

## Still manual (ops)

1. **Add `ios/Runner/GoogleService-Info.plist`** for bundle `com.interactpak.interactTalk` from the `interact-lifestyle` Firebase project (same as Android `google-services.json`). Rebuild iOS after adding.
2. Confirm Caddy serves `talk.interactpak.com` as alias of the Talk backend (`/api/v1/health` → 200).

## Verify on iPhone (Paksaf)

### Prep

```bash
cd /Users/muzafar/dev/INTERACT/apps/interact-app
flutter pub get
cd ios && pod install && cd ..
flutter run -d 00008101-001A3CE400E1401E
```

After Podfile change, a clean pod install is required once.

### Messages

1. Sign in (OTP) — should complete against `www.interactpak.com` (unchanged).
2. Open **Chats** → pull to refresh — thread list loads.
3. Open a thread — messages appear within ~2s poll; send a text — delivers (no endless spinner).
4. Optional: enable airplane mode briefly, restore network — outbox drains.

**Debug signal:** Xcode console should show requests to `talk.interactpak.com` (not only `qurbanisahulat.com`) when cellular DNS flakes.

### Calls (foreground — poll ring)

1. From a chat thread, tap voice/video call.
2. Host: "Ringing…" then connects or times out with a normal end panel (not a raw DNS exception).
3. Callee (second device): incoming ring within ~4s while app is open.

### Calls (WebRTC)

1. Accept call — mic works both ways (flutter_webrtc 1.4 + explicit AVAudioSession in `meeting_room_screen.dart`).
2. Video call — local preview while connecting; remote tile when peer joins.
3. Hang up — returns to chat without crash.

### Push (after GoogleService-Info.plist)

1. Register token: log line `FCM token register → 200` with `platform: ios`.
2. Kill app on callee; caller rings — CallKit / notification should appear (requires server push + APNs key in Firebase).

## Android vs iOS init (`main.dart`)

Both platforms share the same path: `ApiBase.init()` → optional Firebase → `_Gate` → `attemptSilentResume()` → `/calls` → background `PushService` / `CallKit` / `NotificationService`. No `Platform.isIOS` gate in `main.dart`; differences are native (Info.plist, Podfile macros, FCM plist).
