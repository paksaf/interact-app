# INTERACT Talk — feature completion roadmap (2026-08-27)

Requested by operator after the 1:1 video fix: walkie-talkie, group chat,
townhall meetings, IoT device communication, offline↔online communication,
plus the @username error. Surveyed against the actual code the same night.

## 0 · Foundation shipped today (prerequisite for everything below)

1:1 calls fixed end-to-end (root cause: busy-banner Stack collapse — see
`docs/runbooks/CASE_TALK_BLACK_VIDEO_2026-08-27.md`). Flutter 3.47.1,
flutter_webrtc 1.6.0, livekit_client 2.11.0, iOS PlatformView renderer,
pre-call preview, speaker routing, DNS failover, TURN auto-relay.
**Pending:** sound re-test on the clean build → then commit everything via
`scripts/safe-commit.sh` (branch feat/talk-offline-mesh-camera).

## 1 · Walkie-talkie + Townhall (same backend — LiveKit SFU via the hub)

Architecture (already coded, end to end): app → Sahulat
`/api/v1/talk/live/token` → interact-connect `/api/rooms/*` (hub-token
auth, channel **"rooms"**) → LiveKit server `wss://livekit.interactpak.com`.

Blockers found, in order:
1. **`channel_not_allowed`** — Sahulat's scoped hub token (minted for
   messaging during INC-020) lacks the `rooms` channel. Fix = one SQL row
   update on the hub DB, no deploy, no restart (checked per request):
   ```sql
   -- on the VPS, in interact-connect's database:
   SELECT id, app, "allowChannels" FROM ic_app_tokens WHERE enabled;
   UPDATE ic_app_tokens SET "allowChannels" = "allowChannels" || ',rooms'
    WHERE app = 'sahulat' AND "allowChannels" NOT LIKE '%rooms%';
   ```
   (DB name: read from interact-connect's DATABASE_URL. Also decide whether
   fleetops/ussd-rewards tokens should get `rooms` while there.)
2. **LiveKit server not deployed** — `livekit.interactpak.com` DNS exists
   (flagged stale in DNS_MAP) but nothing serves it → the client's
   `Room.connect` TimeoutException. Needs: livekit-server (single Go
   binary) as a systemd unit on the VPS, config with API key/secret,
   Caddy block for wss, UDP port range in ufw, and the same key/secret in
   interact-connect's env (`livekit-token.ts` mints with it). Check
   `src/lib/vendor/_shared/services/realtime-room/SPRINT_A_OPERATOR_RUNBOOK.md`
   first — a deploy runbook likely already exists from the Sprint-A era.
3. Note: CLAUDE.md marks LiveKit "anti-portable #1" — that rule bars
   promoting it to _shared/other apps; Talk's townhall/walkie were built on
   it deliberately (TalkFlags, live token route). Confirm against
   DECISION_LOG before treating as settled.

## 2 · Group chat

Server: Talk groups shipped 2026-07-23 (#132, `groups:401` verified live).
App: `new_group_screen.dart` exists; messaging pipeline now works (hub
scoped-token fix, Aug 27). **Action: functional test first** — create a
group on two devices, send/receive; fix what actually fails rather than
assuming. Likely small gaps (member management UI, group avatars).

## 3 · @username ("nickname") error in profile

Client: Me tab → Set @username → `chatApi.setUsername` → POST
`qurbanisahulat.com/api/v1/talk/profile/username`. Route exists in the
WORKING TREE; prod DB has `users.username` (unique index predates this).
Prime suspect: **route not present in the DEPLOYED Sahulat build** (frozen
since the 2026-08-22 standing order) → 404/HTML → client throws. Diagnose
without deploying:
```bash
ssh interact 'ls /srv/qurbanisahulat/.next/standalone/.next/server/app/api/v1/talk/profile/ 2>/dev/null'
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://qurbanisahulat.com/api/v1/talk/profile/username
# 401 = route deployed (auth gate) → bug is elsewhere; 404/405 = not deployed.
```
If not deployed: the fix waits on the qurbanisahulat parallel-writer
disposition (standing order) or an operator-approved scoped single-file
deploy per the R-SIGNAL (a′) pattern with before/after manifest.

## 4 · IoT devices + offline mesh (BLE / LAN / LoRa)

Already scaffolded in-app: `nearby_ble_devices_screen`, `offline_lan_screen`,
`lora_bridge_screen`, `nearby_mesh_screen`, `sahl_mesh` path package,
`mesh_foreground_service` (Android FGS), `flutter_ble_peripheral`,
`nearby_service`, `bonsoir` (mDNS). This is the branch's namesake
(feat/talk-offline-mesh-camera) and a workstream of its own:
1. Status audit per screen (what connects, what's stubbed) on A23 + iPhone.
2. Define the offline→online story: mesh chat store-and-forward → sync to
   Talk backend on reconnect (MessageWatcher already handles online).
3. BLE voice (walkie "BLE mesh voice is a later phase" per the walkie
   screen's own copy) after LiveKit PTT works online.
Related donor patterns: AutoSense device bridge strategy
(`AutoSenseAI/docs/CLOSED_LOOP_DEVICE_STRATEGY.md`), sahl_mesh.

## 5 · Notifications (carried forward)

- Android closed-app: designed to work; token re-registers post
  `fcm_project_id` fix — TEST on A23 (open app once, kill it, send message).
- iOS background ring/push: BLOCKED on Apple org membership renewal
  (`2NZD65G583`) for APNs/PushKit. Free-signing profiles expire ~Sep 2 —
  weekly rebuilds until renewed.
- App-side: guard `PushService.init` against missing Firebase app (the
  `[core/no-app]` unhandled exception at every launch).

## 6 · Operator feature requests (2026-08-27, after first working calls)

1. **Pre-call sound test** on the preview screen: play a test tone, show a
   mic level meter, and an **audio-output picker** (earpiece / speaker /
   Bluetooth / wired) — flutter_webrtc `Helper.audiooutputs` +
   `selectAudioOutput` cover enumeration/selection.
2. **Host controls in calls/meetings**: participant panel showing display
   name + join info, with per-participant mute, "allow to speak"
   (PTT-style floor control), and remove/kick. Natural fit for the
   LiveKit townhall path (server-side moderation already stubbed:
   Sahulat `/api/v1/talk/live/moderate` + hub `rooms/[id]/moderate`).
   ⚠️ Privacy: exposing visitor IP + geolocation to hosts needs a
   deliberate decision (show coarse city-level only? consent notice?) —
   flag to operator before building.
3. Hand-raise/reactions not arriving cross-device (1:1 room) — retest
   after the audio-session fix; gestures ride the same WS relay, may be a
   separate small bug.

## Current bug: NO SOUND in calls (post-1.6 upgrade) — fix in test

`AppleNativeAudioManagement.setAppleAudioConfiguration(playAndRecord +
videoChat/voiceChat + BT options)` now set before getUserMedia on iOS;
stats probe extended with audioBytes out/in to localize (capture vs
transport vs playout) if still silent.

## 7 · Toolchain pin (2026-08-27 night — binding until revisited)

**Flutter 3.41.6 + flutter_webrtc 1.4.0 + livekit_client 2.8.1.** The 3.47 /
webrtc-1.6 upgrade (made chasing the wrong black-screen theory) broke call
audio both ways on iOS (AVAudioEngine ADM, flutter-webrtc#1996 shape) and
livekit 2.8.1 doesn't compile on Dart 3.13. Renderer likewise reverted to
plain RTCVideoView on all platforms — webrtc 1.4's early iOS PlatformView
crashed at call connect. Upgrade path (future, deliberate session): wait for
livekit_client with Dart-3.13 support + a webrtc with the ADM fixed, then
move Flutter/webrtc/livekit together and re-run the full call test matrix.

## 8 · New operator requests + regressions (2026-08-27 night)

1. **WhatsApp + SMS OTP login broken on Samsung; email works.** Server-side:
   Sahulat OTP → hub → Baileys (WhatsApp, VPS worker — session can die,
   gotcha #60) / capcom6 (SMS — a physical PK-SIM Android gateway that must
   be on). Both were working ~Aug 23. Diagnose on VPS:
   `pm2 ls; pm2 logs sahulat-baileys --lines 25 --nostream` (WhatsApp:
   crash-loop/QR prompt = session lost → re-link per gotcha #60), and probe
   the hub `POST /api/comms/send channel=sms` → if not
   `{"ok":true,"provider":"capcom6_sms"}`, check the gateway phone.
2. **Meeting scheduling**: schedule a call/meeting for a specific time with
   invitees; reminder push + calendar row; "join" from the invite. Backend
   candidates: Talk thread invites + a `scheduled_calls` table + the
   existing invite/ring flow; aura's calendar/ICS work is a donor pattern.
3. **External devices for calls** (TV, projector, sound system, external
   mics): audio-output picker (`Helper.audiooutputs`/`selectAudioOutput`),
   AirPlay/Chromecast for video-out (the shared realtime-room service has a
   CastButton/AirPlay donor), Bluetooth mic selection. Pairs with the
   pre-call sound-test screen (item 6.1).

## 9 · Walkie/Townhall infra status (2026-08-27 close) + security follow-up

VERIFIED: LiveKit server RUNNING (systemd, 4d uptime), Caddy block OK,
hub `LIVEKIT_URL=wss://livekit.interactpak.com` (correct public URL),
ufw open for 7881/tcp + 50000:50100/udp, sahulat hub token has `rooms`.
No known blocker remains — functional PTT test is the next step.

🔐 **ROTATE the LiveKit API key/secret**: `cat /etc/livekit/server.yaml`
during diagnosis printed the key pair to a terminal + chat (burned per the
SECRETS-NEVER-TRANSIT-CHAT rule). Procedure: `livekit-server generate-keys`
→ update `keys:` in /etc/livekit/server.yaml AND the hub's
LIVEKIT_API_KEY/SECRET env → `systemctl restart livekit-server` +
`pm2 restart interact-connect --update-env`. Do right after walkie is
confirmed working (one change at a time).

## 10 · Gap analysis vs operator feature list (2026-08-27 night sweep)

| Feature | Exists today | Gap | Design / dependency |
|---|---|---|---|
| Speaker/mic/BT/TV audio | speakerphone default (new) | picker | ✅ **SHIPPED**: in-call audio-route button (volume icon) → Loudspeaker switch + `Helper.audiooutputs` list (BT headsets/speakers, wired; on iOS AirPlay devices = TV audio). Mic INPUT selection: iOS blocked upstream (flutter-webrtc#1041); Android later. |
| TV/projector VIDEO (cast) | CastButton/AirPlay donor in `_shared/services/realtime-room` (web) | native cast | AirPlay screen-mirroring works OS-side today (Control Center). In-app Chromecast/AirPlay video-out = dedicated feature (roadmap; donor exists). |
| Offline operation | `outbox_service` (queued sends), durable offline session (gotcha #69), mesh screens + `sahl_mesh`, `lan_service`, bonsoir mDNS | mesh transport not wired into chat flow; no offline→online sync tests | Workstream §4: audit each screen on-device, then wire mesh store-and-forward → MessageWatcher reconcile on reconnect. |
| Group calls | Townhall/walkie code paths complete app+server; LiveKit VERIFIED running; sahulat token has `rooms` | untested E2E | Run WALKIE1 + TOWN test; group VIDEO = `meeting` mode same stack. 1:1 mesh stays for calls; groups ride LiveKit. |
| Host: who/where (IP + plain-English area) | hub `ic_room_participants` rows; request-context/geo donor in ussd-rewards; live_room roster panel exists | join-info API + UI | REFINED DESIGN: no schema change — hub `joinRoom` embeds `{area}` (city-level geo-IP of the joiner) into the LiveKit participant METADATA at token mint; live_room roster reads participant metadata. Build AFTER walkie/townhall E2E test passes (don't stack on untested stack). ⚠️ privacy: coarse city default; full IP only behind an operator setting. |
| Message last seen | ✅ client parser ready (PresenceInfo.lastSeen, null-tolerant) | server: expose lastSeenAt in presence GET (Sahulat — frozen) + render "last seen …" in chat header once data flows | Blocked on freeze; client prepared. |
| Presence bubbles (active/busy/offline) | ✅ CLIENT HALF SHIPPED 2026-08-27: `PresenceInfo{online,busy,lastSeen}` + `PresenceStatus` tri-state in talk_api/presence_service, Contacts dots green/amber; forward-compatible parser means busy+lastSeen light up on a SERVER deploy with no app update | server: add busy+lastSeenAt to presence beat/GET (Sahulat — frozen); Chats-tab bubbles need peer-userId plumbing in _ThreadTile | Server half queued behind the freeze. |
| IoT devices | BLE peripheral+central, nearby_service, LAN, LoRa bridge screens, `nearby_ble_devices_service` (has lastSeen per device) | end-to-end flows untested; no device→chat bridge | Workstream §4 audit first; AutoSense device-bridge strategy is the donor. |

**Standing-order friction:** last-seen + busy-state + username fix + host-info
(if done on Sahulat rather than the hub) all touch qurbanisahulat — FROZEN
until the parallel-writer disposition. Hub-side implementations preferred
where possible (host-info via hub rooms = OK).

## Suggested order

1. Sound re-test → **commit today's work** (safe-commit).
2. Hub token `rooms` channel SQL (5 min) → retest walkie/townhall → hits
   the LiveKit-server wall → deploy LiveKit (runbook, ~1 session).
3. Group chat functional test (30 min) → fix findings.
4. @username diagnose (2 curl commands) → likely waits on Sahulat unfreeze.
5. Android closed-app notification test (10 min).
6. IoT/mesh audit → dedicated sessions.
7. Apple membership renewal (operator, unlocks iOS push + stable installs).

## §11 — WHO-JOINED PANEL: SHIPPED CLIENT+HUB (2026-08-27 late)

Implemented this session (uncommitted at time of writing):
- **Hub** `interact-connect/src/lib/livekit-token.ts`: `canUpdateOwnMetadata: true`
  added to the LiveKit grant. Deploy interact-connect for it to take effect —
  until then the app's setMetadata is a harmless timeout (caught).
- **App** `livekit_service.dart`: `deviceAreaString()` (locale country + timezone,
  NO GPS — "Pakistan · PKT (UTC+5)"); `_publishSelfInfo()` merges area/joinedAt
  into own participant metadata post-connect; `ParticipantMetadataUpdatedEvent`
  wired; `LiveTile.area/.role` parsed from metadata.
- **App** `live_room_screen.dart`: roster subtitle shows "role — area" per
  participant. Mute/remove/promote buttons were ALREADY wired end-to-end
  (roster → LiveApi.moderate → Sahulat /talk/live/moderate → hub /rooms/[id]/moderate
  → LiveKit RoomService). Only open question: is Sahulat's live/moderate route
  in the DEPLOYED build? Probe (expect 401 = deployed, 404 = waits on unfreeze):
  `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://qurbanisahulat.com/api/v1/talk/live/moderate`
- IP display: NOT included by design — user IP never reaches the hub (Sahulat
  calls it server-to-server) and exposing it needs a privacy decision + Sahulat
  change (frozen). City-level area covers the operator's "plain english area" ask.

## §12 — WALKIE AUDIO ROUTING: SHIPPED (2026-08-27 late)

"Audio" button added to live_room _controlBar OUTSIDE the !_isPtt guard (walkie
has it). Sheet uses `rtc.Helper.audiooutputs` + `rtc.Helper.selectAudioOutput`
(flutter_webrtc) for device selection — **LiveKit's Hardware.selectAudioOutput is
DESKTOP-ONLY (v2.8.1 hardware.dart logs a warning and returns on mobile); do not
"clean this up" to the Hardware API** — and `Hardware.instance.setSpeakerphoneOn`
only for the loudspeaker toggle (it handles iOS session config for LiveKit tracks).
Note: normal OS behavior already routes walkie audio to a CONNECTED Bluetooth
headset automatically; the picker is for choosing among multiple outputs.

## §13 — IN-APP TV/PROJECTOR CASTING (design, next feature build)

Today, zero-code: iPhone Control Center → Screen Mirroring (AirPlay); Samsung
Quick panel → Smart View (Miracast/Chromecast built-ins). Whole call mirrors.
In-app v1 (dedicated session — new plugins = toolchain risk, follow §7 pin rules):
1. iOS: native `AVRoutePickerView` via a small platform channel (no pub dep) —
   system AirPlay picker; video route follows for mirroring-capable devices.
   Audio-only AirPlay ALREADY appears in the audio picker sheets.
2. Android: `flutter_cast_framework` or platform-channel MediaRouter dialog →
   Chromecast. Requires Google Cast SDK gradle dep — test against gotcha #67 fat-ABI.
3. Web (interactpak /interact/web): CastButton donor in
   `_shared/services/realtime-room/components/CastButton.tsx` (AirPlay via
   webkitShowPlaybackTargetPicker on the remote <video>) — lowest-risk first slice.
Order: (3) web donor wire-up → (1) iOS route picker → (2) Chromecast.

## §14 — LAN-OFFLINE WALKIE (design, Phase 1 of offline comms)

Phase 1 — same-Wi-Fi, no internet (real field case: site router, no uplink):
1. Discovery: mDNS/NSD (bonsoir dep already in pubspec via lan/mesh work —
   verify) advertising `_interact-talk._tcp` with userName+channel code.
2. Signaling: tiny in-app WebSocket server on the HOST phone (shelf or raw
   ServerSocket, Dart stdlib) speaking the SAME join/offer/answer/ice-candidate
   protocol as the deployed relay (gotcha #61 shapes) → reuse meeting_room's
   existing client logic with a `ws://<host-ip>:PORT/ws` URL.
3. Media: existing WebRTC stack with host candidates only (no TURN) — LAN
   direct. PTT UX = walkie screen, transport switched.
4. Fallback order in walkie join: internet LiveKit → LAN host discovery → error.
Phase 2 — BLE mesh voice (no network at all): stays §4 (sahl_mesh); BLE
bandwidth fits only heavily-compressed voice (Codec2/Opus@6kbps custom GATT
streaming) — genuinely hard, do not promise until Phase 1 ships.

## §15 — "SOON" TILES GONE LIVE + @username handling (2026-08-28 early)

- **Call history (was Soon)**: full screen `lib/screens/call_history_screen.dart`
  (route /call-history; filters All/Missed/Video/Voice; same /meetings/log data).
  Wired from Me tile AND the Calls tab "All" button (was a Phase-1.5 stub).
  `_CallRow` extracted → shared `lib/widgets/call_row.dart` with the "Unknown"
  fix: ad-hoc talk:CODE rows now label "Video meeting · CODE" / "Walkie · CODE"
  (server rows carry no peer fields — enriching createCallLogBestEffort with the
  callee is a SAHULAT change, queued for unfreeze).
- **Blocked contacts (was Soon)**: fully client-side v1 — `services/block_service.dart`
  (SharedPreferences, keyed by THREAD id — the only peer identifier an incoming
  invite carries), screen at /blocked-contacts, block/unblock via chat long-press
  (1:1 only), "Blocked" tag on chat rows, and enforcement in CallSignaling._poll:
  blocked invites are swallowed (caller sees normal no-answer). Server-side block
  model = future Sahulat work.
- **@username**: route + users.username column exist in Sahulat SOURCE; failure is
  almost certainly the deployed build predating the route (probe:
  `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://qurbanisahulat.com/api/v1/talk/profile/username`
  → 404 = waits on unfreeze, 401 = deployed and the bug is elsewhere—reinvestigate).
  Client now shows "Handles need the next server update" on 404 instead of a raw error.
- Still Soon (honest): E2EE (libsignal Phase 1.5 — real workstream), AI audit log,
  voice-note transcription.

## §16 — LIVEKIT DNS FAILOVER (2026-08-28, shipped `interact-app@7906246`)

Back-filled: `livekit_service.dart` already cites "roadmap §16" in a comment,
but the section only existed in the session doc. Recording it here so the
pointer resolves.

Problem: iPhone hit `Failed host lookup: livekit.interactpak.com` (errno 8) —
the home router's resolver, same family as the API/signaling failures.
Fix, both halves live:
- **Caddy** on qurbanisahulat.com: `handle_path /livekit/* { reverse_proxy
  127.0.0.1:7880 }` at the top of the site block. Probe
  `https://qurbanisahulat.com/livekit/rtc/validate` → 401 = tunnel reaches
  LiveKit. Config-only; the Sahulat freeze is intact.
- **App**: on a lookup failure `Room.connect` retries via
  `wss://<ApiBase host>/livekit` — the host it resolved seconds earlier to
  mint the token — so the broken resolver is never asked twice. Mirrors the
  1:1 `/rtc-ws` fallback.

## §17 — TV / PROJECTOR CASTING: WEB SLICE SHIPPED (2026-08-28)

§13 ordered the work web → iOS → Chromecast. The web slice is done, with one
deliberate departure from the donor that the next two slices inherit:

- **New** `interactpak-nextjs/src/components/shared/CastToTvButton.tsx`,
  wired into the video call's bottom control bar in
  `src/components/staff/VoiceCallOverlay.tsx` (between screen-share and
  hang-up).
- **The donor's Presentation-API path is NOT used here.** PresentationRequest
  hands the receiver a *URL to load* — right for a public meeting page,
  wrong for a call: the TV would open interactpak.com unauthenticated and
  would not be in the call. We probe the REAL remote `<video>` instead, which
  also fixes the donor's documented failure ("Unable to connect to Living
  room TV" — it probed a hidden, source-less `<video>`).
- Three paths, in order: WebKit AirPlay
  (`webkitShowPlaybackTargetPicker` on the live element) → Remote Playback
  API (`video.remote.prompt()`) → platform-specific whole-tab mirroring
  guidance (iOS Control Center · macOS Screen Mirroring · Chrome ⋮ Cast tab ·
  Android Smart View).
- **Expect the guidance path to be the common one, and that is correct.**
  Browsers generally refuse to remote a MediaStream-backed element — both
  WebKit AirPlay and Chromium Remote Playback want a media *source* — so for
  a LIVE call, whole-screen/tab mirroring is usually the path that actually
  reaches the TV. The probes are honest: if a platform allows it, the button
  lights up; if not, the user gets steps that work rather than a dead button.
  ⚠ Carry this into slices (1) and (2): a native iOS `AVRoutePickerView`
  faces the same MediaStream limit for *video* (audio-only AirPlay already
  works via the audio picker), and Chromecast of a live WebRTC track needs
  the Cast SDK's own receiver, not a media URL.
- Verify: `npx tsc --noEmit` in `sites/interactpak-nextjs`. Device test is
  visual — start a web video call, tap the cast button, confirm the picker or
  the right platform steps appear.

## §18 — LAN-OFFLINE WALKIE PHASE 1: BUILT (2026-08-28)

§14's Phase-1 design, implemented. Untested on device — no Flutter toolchain
in this session's environment, so **`flutter analyze` must be run on the Mac
before safe-commit** (toolchain pin §7 applies: 3.41.6 / webrtc 1.4.0 /
livekit 2.8.1).

- **New** `lib/services/lan_walkie_service.dart` (~440 lines):
  - `LanWalkieService` singleton — host + discovery.
  - Host: `HttpServer.bind(anyIPv4, 0)` → upgrades `/ws`; advertises
    `_interact-talk._tcp` over Bonsoir with `{code, hostName, app, v}`.
    Deliberately a DIFFERENT service type from `LanService`'s
    `_interact-lan._tcp` (text transport) — a walkie host is a different
    capability and joiners must not conflate them.
  - `_LanSignalRelay` speaks the deployed relay's protocol **exactly**
    (gotcha #61): `join → joined{peers}` / `peer-joined` / `peer-left`,
    routed `offer`/`answer`/`ice-candidate` with `from` stamped on,
    `ping→pong`, and the same `error: "Unknown message type: X"` string the
    client logs. `joined.peers` is computed BEFORE the joiner is added —
    that list is what makes the second peer the offerer, so the ordering is
    load-bearing, not incidental.
  - `selfChannel` → the host joins its own relay over `127.0.0.1`, so the
    host side works even while iOS local-network permission is still pending.
- **`meeting_room_screen.dart`** gains `lanSignalUrl` + `lanRoomId`. When set:
  the cloud token mint is replaced by a synthesised `TalkRoomToken` (one code
  path with the cloud call), the ephemeral-TURN HTTPS fetch is skipped (it can
  only time out on a router with no uplink), the `/rtc-ws` cloud fallback is
  disabled, and `iceServers` is empty → host candidates only. No other line of
  the call path changes.
- **New** `lib/screens/lan/lan_walkie_screen.dart` — host-or-join UI, route
  `/lan-walkie?code=CODE` in `main.dart`.
- **Entry point:** walkie entry screen (`mode: 'ptt'`) now offers "No internet?
  Use nearby Wi-Fi" up front, rather than only after a failed LiveKit join —
  on a known-dead network the operator should not have to watch a timeout
  first. The design's "LiveKit → LAN → error" order is therefore offered, not
  automatic; auto-fallback on join failure is a follow-up.
- **Scope honesty:** voice only; one host holds the room (host leaves = channel
  ends); no auth beyond the channel code — being on the Wi-Fi is the
  credential, like a handset on a channel. A shared-secret handshake is
  Phase 1.5. Phase 2 (BLE mesh, no router at all) stays §4.

**Device tests to run (both phones on the same Wi-Fi, router uplink pulled):**
① host on A23, confirm the channel appears on iPhone within ~5s;
② join from iPhone → two-way audio;
③ host's own loopback join works;
④ kill the host app → joiner sees the call end, not a hang;
⑤ re-host with a different code → old entry disappears from the list.

### §18a — platform config the LAN walkie needs (2026-08-28)

Found while reviewing §18 against the platform rules; without these the
feature cannot work on device, and the failure mode is silence, not an error.

- **iOS `Info.plist` — `NSBonjourServices` now lists `_interact-talk._tcp`.**
  iOS 14+ browses ONLY declared service types and an undeclared one fails
  **silently** — which on screen is indistinguishable from "nobody is
  hosting". `_interact-lan._tcp` was already declared (LanService); the
  walkie's own type was not.
- **iOS ATS** — added `NSAppTransportSecurity { NSAllowsLocalNetworking }`.
  Apple-sanctioned local-only relaxation; ATS stays fully enforced for
  every public host, and the media is DTLS-SRTP either way.
- **Android** — added `res/xml/network_security_config.xml`, wired via
  `android:networkSecurityConfig`. Read the comment in that file before
  touching it: Android's NSC matches by hostname and has **no CIDR syntax**,
  so a "private ranges only" exemption is not expressible. It grants
  loopback + `.local` and nothing else; public hosts keep cleartext denied.
  Whether an IP-literal `ws://` needs more is an open question — dart:io
  sockets are believed not to consult this policy — and the §18 device test
  settles it. If Android does block it, choose deliberately between
  connecting by mDNS `.local` name and a blanket allow; do not widen the
  file silently.

Add to the §18 device tests: ⓪ on iPhone, confirm the local-network
permission prompt appears on first scan and the channel list populates —
that one prompt is the whole iOS Bonjour path in a single observation.

## §19 — OFFLINE BEARERS: audit + the missing router (2026-09-01)

Full doc: `apps/interact-app/docs/OFFLINE_BEARERS_AUDIT_2026-09-01.md`.
Does **not** reopen the `OFFLINE_MESH_LORA_BRIDGE_2026-07-26` ADR — no new
transport, no new discovery stack, no reordering of the LoRa gate.

**The finding.** Five working phone-native bearers ship today (BLE gossip via
`sahl_mesh` 2142 lines + 7 test files, LAN via Bonsoir+TCP, Wi-Fi Direct/MPC,
the new LAN walkie, and the LoRa BLE bridge with in-repo firmware) — and **not
one of them can carry a message typed in the Chats tab**. `outbox_service`
queues to the cloud only; `mesh_cloud_bridge` runs one direction and needs
uplink. Each transport is a working demo of itself in its own screen. The gap
is routing, not radio.

**🔴 Security, pre-existing, fix first.** `app_shell` binds `MeshCloudBridge`
app-wide; `lan_service` feeds it **every inbound TCP frame** unauthenticated;
`ingestTalkFrame` then sends `talk:0|<phone>|<text>` **using the local user's
credentials**. Anyone on the same Wi-Fi (mDNS advertises the listener) or in
BLE range can make a victim's phone message an arbitrary number as them.
Ed25519 signing does not help — it proves frame integrity, not authorisation.
Fix: inbound frames render locally and never trigger an outbound send as the
local user. Detail + the conditions any future auto-relay would need: §3 of
the audit doc.

**Missing bearer worth more than LoRa:** **SMS**. The common rural failure is
signal-but-no-data, where BLE/LAN reach only the room and LoRa needs hardware
nobody has. Dexatel + capcom6 are already in the portfolio. User-confirmed
fallback, never automatic.

**Wave-1 field tests have never been run** — four unchecked boxes in the ADR,
and it gates LoRa on them. Three devices are on one build today for the first
time; closing those rows costs ~20 min on top of the §18 walkie tests.

**Order:** (0) run Wave-1 rows now → (1) fix the injection path → (2) `Bearer`
adapters over the five existing services → (3) `outbox_service` holds frame +
bearer preference → (4) `OfflineRouter` + inbound funnel + cross-bearer dedupe
→ (5) honest mesh delivery state in the UI → (6) MeshIdentity ↔ Talk identity
→ (7) SMS bearer → (8) LoRa E2E. Steps 2–4 are what turn a drawer of working
radios into a product.

**Corrections:** `sahl_mesh/README.md` claimed Phase-1.5 chunking was pending
(it ships — `mesh_chunker.dart` + test + chunk cycling in `ble_transport`),
still named `flutter_blue_plus` post-migration, and carried a pre-reorg test
path. All three fixed. Also: `meshtastic_bridge_service` is **RX only**
(`MeshPacket` TX not implemented) — say so wherever Meshtastic is described.

**🔴 Also found (§10 of the audit doc): `apps/sahl_mesh` has NO git repository.**
2142 lines of signed mesh protocol + 7 test files, a **path dependency of
interact-app**, compiled into every shipped binary, unversioned. Three more
unversioned Dart packages alongside it (`sahl_radar`, `interact_mobile_common`,
`interact_media`). This is the third recurrence of the pattern that caught
`tanwrk-backend`/`sahl-v2` (2026-08-13) and TryOn (2026-08-12) — make it a
standing sweep. Init `sahl_mesh` first; review `.gitignore` before the first
commit.

## §20 — OFFLINE COMMS HUB shipped + full bearer scan (2026-09-01)

Scan: `apps/interact-app/docs/COMMS_BEARERS_SCAN_2026-09-01.md` — every antenna
and sensor bearer a phone can use, oldest signalling principle (heliograph,
acoustic coupler, telegraph/compass) to newest (Wi‑Fi Aware, UWB, NFC), each
rated for the rural‑PK offline‑first goal. Framing kept from the RF ADR: BLE/
Wi‑Fi ARE radio (just not long‑range); no phone ships LoRa/ham/satellite‑app
access. Top conclusions: (1) improvement is *routing across the antennas we
have* + (2) the two missing high‑value bearers are **SMS** (national, trivial
via Dexatel) and **NFC identity tap** (fixes attribution/audit‑step 6); (3)
keep one line‑of‑sight fallback (torch/QR channel code) for radios‑off/denied.

**The button — `OfflineHubScreen`** (`lib/screens/offline/offline_hub_screen.dart`,
route `/offline-hub`, entry at the TOP of Me → Offline Connectivity). One screen
that makes the "router" visible: every no‑internet channel in two groups
(Radios / Light & sound), each with a reach chip, a live/planned/hardware/
OS‑locked status, and a plain‑English blurb. Live bearers deep‑link to their
existing screens (LAN, walkie, Wi‑Fi Direct, BLE mesh, nearby devices, LoRa,
QR invite); planned ones (SMS, NFC, Wi‑Fi Aware, light signal, sound chirp,
ultrasonic, IR, compass pulse) open an info sheet — never a dead tap.

**Dependency discipline:** the hub adds **ZERO new packages** — pure Flutter +
go_router, safe under the pin. Real transports for the planned bearers are
deliberate future work; each needing a plugin (NFC, Wi‑Fi Aware, UWB) waits for
a dedicated toolchain session per §7 pin rules, never a casual pre‑build bump.
SMS/acoustic/torch need no new dep and come first.

**Files:** new `lib/screens/offline/offline_hub_screen.dart` (+~370 lines);
edits `lib/main.dart` (import + `/offline-hub` route) and
`lib/screens/tabs/me_tab.dart` (one entry tile). **Uncommitted. flutter analyze
not run** (no toolchain in the authoring session) — run it on the Mac before any
build. Additive, inert to the call/LAN/Bonjour paths, so it does not affect the
§18 walkie test on already‑installed 6054.

## §21 — SECURITY FIX: mesh/LAN inbound injection closed (2026-09-01)

Audit-step-1 (from §19 / OFFLINE_BEARERS_AUDIT §3). **The confused-deputy hole
is removed, not gated** — inbound LAN/BLE frames can no longer cause an
outbound send as the local user, and there is no flag to turn it back on.

**What changed (4 files, additive-safe, no new deps):**
- `mesh_cloud_bridge.dart` — rewritten to a **send-free static decoder**. All
  `ChatApi.sendText`/`createDirectThread` calls, `bind`/`_api`, the `talk:0|phone|`
  arbitrary-recipient path, and the `chat_api` import are **deleted**. Now exposes
  `plainBody(raw)` (strip the `talk:` envelope for local display) + `encodeForThread`
  (outbound helper). Loud header documents the fixed bug and that a proper
  attributed relay is future work (audit step 6, needs the frozen backend).
- `lan_service.dart` — inbound frame now renders locally with the envelope
  stripped (`plainBody(body) ?? body`); the `ingestLanBody` re-injection line is
  gone. Local `LanTextMessage` rendering was already independent, so nothing
  visible is lost.
- `nearby_mesh_screen.dart` — drops the app `bind` + the `←☁` cloud indicator;
  received BLE frames render `← <text>` locally only. `chat_api` import removed.
- `app_shell.dart` — the app-wide `MeshCloudBridge.bind(...)` and its two
  now-unused imports removed.

**Behaviour delta for a normal user:** none visible — nearby mesh / offline LAN
still show incoming messages, now as clean sender-attributed text instead of raw
`talk:1|id|…`. **Behaviour delta for an attacker:** the inject-as-you path is
gone.

Braces/parens balanced across all four files. **Uncommitted; flutter analyze
pending on the Mac.** Additive + inbound-only — does not touch the call/walkie
path, so it is safe to include in the next build alongside §20’s hub, or to ship
on its own.

## §22 — WALKIE auto-fallback to LAN on offline (2026-09-01)

The online (LiveKit) walkie mints a cloud token from `talk.interactpak.com/
api/v1/talk/live/token`; with no internet it dies on `_statusView` with a bare
"Try again / Leave". A field user then has to KNOW to back out and find the
"Nearby Wi‑Fi walkie" entry. Fix: in `live_room_screen`, when the room is a
walkie (`_isPtt`), the error view now also shows **"No internet? Use nearby
Wi‑Fi"** → `context.push('/lan-walkie?code=…')`. Scoped to walkie rooms only;
regular meetings/townhalls are unchanged. (Verified live: the operator's test
hit exactly this cloud-token DNS failure — the LiveKit walkie, not the §14 LAN
walkie, which never calls `/live/token`.)

## §23 — LOGIN FIX: OTP send/verify had no failover/retry (2026-09-01)

🔴 Root cause of "both SMS and WhatsApp login not working on Samsung". The OTP
routes are pinned to a single hardcoded host — `const _kBase =
'https://www.interactpak.com'` — with **no multi-host failover** (unlike chat,
which Cursor wrapped in `ApiBase.runWithFailover`) and **no retry**. Worse, a
DNS failure surfaces as `http.ClientException` ("ClientException with
SocketException: Failed host lookup"), which the old `_postJson` threw
IMMEDIATELY. So one resolver flap on the HS8145C5/ISP network killed BOTH
channels at once — they request through the same unprotected host.

Fix (`auth_service._postJson`, covers requestOtp + verifyOtp): retry transient
failures (TimeoutException OR `ApiBase.isDnsOrOffline(e)` — which now also
catches the ClientException/host-lookup form) up to 3× with 1.2 s backoff
before surfacing the error, so a flap self-heals. HandshakeException still
fails fast (TLS/clock, not transient). Retries only fire when the request
never reached the server, so no duplicate SMS/WhatsApp sends.

**Scope honesty:** this fixes CLIENT reachability. If the request reaches the
server (HTTP 200) but the code never arrives, that is server-side delivery —
capcom6 SMS gateway phone (power/signal/balance) or the Baileys WhatsApp
session — the recurring delivery-side issue in the CLAUDE.md handoff, fixed on
the VPS, not in a build. Operator should confirm which layer by watching for a
network error (client, now retried) vs "code sent" with nothing arriving
(server/gateway).

Version bumped 0.5.15+6054 → **0.5.16+6055** for the next build.
