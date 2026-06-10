# INTERACT Talk

Standalone communications app — voice + video calls, group meetings (Phase B),
screen share, IM, contacts. Inherits the WebRTC stack already in production
behind `signal.interactpak.com` + `turn.interactpak.com`.

**Decision context:** scaffold lifted from sahulat-app's #186 Phase A (1-to-1
meetings shipped 2026-05-21). Architecture is identical — same MeetingService
+ MeetingRoomScreen — with the animal/contract/chat-thread anchor removed and
replaced by:

- **Invite-code rooms** — `general:<code>` instead of `sahulat:animal:<uuid>`.
- **Self-serve account** — same INTERACT_AUTH_SECRET / phone-OTP path, but
  scope claim is `"talk"` instead of `"buyer"`/`"seller"`.
- **Contacts** — server-side `/api/v1/talk/contacts` returning every
  cross-app user the signed-in account has ever messaged or called.

## What ships in Phase 1 (tonight)

- `pubspec.yaml` with flutter_webrtc + web_socket_channel + sahulat_common
  (path dep — for theme, ApiClient, TtsService)
- Sign-in via phone OTP (delegates to qurbanisahulat's `/api/v1/auth/phone-otp/*`)
- Home: New meeting / Join with code / Recent calls
- Invite screen: generate a code (6 digits) and a wss://signal.interactpak.com
  share link; or paste a code received over WhatsApp/SMS
- MeetingRoomScreen ported verbatim from sahulat-app — same controls
  (video, voice, mic mute, camera toggle, flip, hangup, in-call chat overlay)
- ContactsScreen — list of recent peers; tap → call directly

## What ships in Phase 2

- **Group meetings (>4 participants)** — mediasoup SFU. Same MeetingService
  surface; only the room joining logic changes.
- **Screen share** — flutter_webrtc supports it natively; ~2 days UI work.
- **Scheduled meetings + calendar invites** — wraps Comms Hub for the
  WhatsApp/SMS/email invite send.
- **Waiting room + host controls + recording** — recording uses the SFU
  egress; the longest single item, deferred to Phase 3.

## Backend extension (new in qurbanisahulat)

A new `/api/v1/talk/*` namespace lives alongside the existing `/meetings/*`:

| Route | Purpose |
|---|---|
| `POST /api/v1/talk/rooms` | Mint a `general:<code>` room + JWT for the host |
| `POST /api/v1/talk/rooms/:code/join` | Join token for an invitee |
| `GET /api/v1/talk/contacts` | Recent + frequent contacts across INTERACT apps |
| `GET /api/v1/talk/history` | Call log (reuses CallLog from #186 Phase A) |

These routes are 90% boilerplate around the existing `src/lib/meetings.ts`
helpers — mostly authz changes (drop the animal/contract checks, add
invite-code validation).

## Run

```bash
cd /Users/muzafar/Documents/INTERACT/interact-talk-app
flutter create . --project-name interact_talk --org com.interactpak \
  --platforms=android,ios --description "INTERACT Talk"
flutter pub get
flutter run -d <device-id>
```

## Build APK

```bash
flutter build apk --release
adb -s R68T304FX1F install -r build/app/outputs/flutter-apk/app-release.apk
```

## Distribution

Same channel as the other 12 INTERACT binaries:
- Signed with the INTERACT release certificate (CN=Shazia Muzaffar, OU=INTERACT)
- Mirrored at `downloads.interactpak.com/talk/InteractTalk.apk`
- Manifest update at `pro.interactpak.com/api/version` extended with a `talk`
  channel

## How it differs from Zoom / Botim

- **No data leaves INTERACT infra** — every byte of media is relayed by the
  TURN server we own (`turn.interactpak.com`). Botim and Zoom both proxy
  through their own clouds.
- **Cross-app identity** — one phone-OTP signs you into Talk + Sahulat + Pro +
  FleetOps. Talk shows your existing contacts from the moment you install.
- **Comms Hub for invites** — when you generate an invite code, Talk can fan
  it out via the same `/api/comms/send` endpoint the rest of the fleet uses,
  reaching anyone on WhatsApp / SMS / email without leaving the app.
- **Sahulat-grade reliability for a feature-phone audience** — phone-OTP via
  capcom6 + Baileys + Dexatel triple-fallback, USSD presence for rural
  recipients who can't install an APK.
