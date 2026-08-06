# Phase 2c — Live captions for 1:1 calls (written plan)

**App:** interact-app "INTERACT Talk" · **Status:** planned, not built · **Date:** 2026-07-31

## Goal
Show real-time, multilingual captions during a 1:1 call, reusing the existing fleet
**caption-agent** (Deepgram nova-2/nova-3, languages `multi/en/ar/ur/tr/ru/es`) rather than
building a new STT path.

## The blocking fact (read first)
The caption-agent does **not** accept audio from a client. It is a hidden **LiveKit**
participant: it joins the LiveKit room, auto-subscribes to every audio track server-side,
streams PCM to Deepgram, and republishes `{participant,text,final}` back over the LiveKit
**data channel** on topic `"captions"`. Clients only *render* that topic — they never send audio.

- Agent code: `interact-realtime/caption-agent/src/index.ts` (Express control on `:8097`, LiveKit for media). Audio it expects from LiveKit: linear16 / 48 kHz / mono.
- Control API (loopback only, no Caddy host): `POST /start {room,language}`, `POST /stop {room}`, `GET /health`; header `x-agent-token`.
- Backend proxy (admin-only, "Deepgram billed per minute"): `qurbanisahulat/src/app/api/v1/talk/live/captions/route.ts` + `/health`.
- Reference client already wired: **Townhall** — `lib/screens/meeting/live_room_screen.dart` (`_captionOverlay()`), caption parsing in `lib/services/livekit_service.dart` `LiveRoomController._onData` (filters `event.topic=='captions'`), toggle client `lib/services/live_api.dart` `toggleCaptions()/captionsHealth()`.

**But** `lib/screens/meeting/meeting_room_screen.dart` is **raw peer-to-peer `flutter_webrtc` 1.4.0** with a bespoke `/ws` signaling server — there is **no media server to tap**, and flutter_webrtc exposes no PCM sample buffers (only `MediaStream` + `track.enabled`). So captions cannot be added to the current 1:1 screen without changing where the media flows.

## Options (pick one — this is the real decision)

### Option A — Route 1:1 calls through LiveKit (recommended long-term)
Replace the bespoke P2P path for 1:1 with a 2-person LiveKit room (Townhall already proves the client stack: `livekit_client: 2.8.1`, caption overlay, data-channel parsing all exist).
- **Reuse verbatim:** `LiveRoomController` (incl. `_onData` caption handling + `captionSpeaker/Text/IsFinal`), `_captionOverlay()`, `LiveApi.toggleCaptions/captionsHealth`. Captions become "free" — the exact Townhall behaviour.
- **Work:** make a 1:1 call open a LiveKit room instead of the P2P `/room`; mint a LiveKit token for the callee too (backend `live/token` route already exists); keep the ring/CallKit/invite flow unchanged (only the media surface changes). Retire or keep the P2P path behind a flag.
- **Pros:** one media stack, captions + recording + SFU scale for free, no PCM plumbing. **Cons:** larger change to the call screen + a second token mint; adds LiveKit server load per 1:1 (was P2P/free).
- **Verify:** two devices, `multi` language, Arabic + Urdu speech → interim then final lines; check LiveKit egress/cost is acceptable for 1:1.

### Option B — On-device STT captions (no server, local-only)
Caption **only the local speaker** on each device using the Phase-2a `speech_to_text` engine, and send the finalized caption text to the peer over the existing `/ws` signaling data path (the same channel already carrying `reaction`/`hand` frames).
- **Reuse:** `lib/services/voice/talk_stt_service.dart`, `voice_locale.dart`; `_wsSend` in `meeting_room_screen.dart`; a caption overlay modeled on Townhall's `_captionOverlay()`.
- **Hard problem — mic contention:** WebRTC holds the mic via `getUserMedia`; `speech_to_text` wants the same mic. On Android this is unreliable (one owner at a time). Mitigations, all imperfect: (a) push-to-caption (STT only while a "CC" button is held, WebRTC audio briefly muted) — clunky; (b) accept that STT may fail to start mid-call and fail-soft to "captions unavailable". **Validate mic-sharing on the A23 + Redmi before committing** — if it can't share, Option B is dead for continuous captions.
- **Pros:** zero server/Deepgram cost, no LiveKit, works P2P. **Cons:** mic contention, no true multilingual code-switch (device engine only), each side captions itself.

### Option C — Tap P2P audio → stream to a new caption socket (not recommended)
Add a raw-audio tap to the P2P stream and stream PCM to a *new* caption endpoint. flutter_webrtc 1.4.0 gives no sample access, so this needs a native plugin / fork or an `AudioSink` — high effort, fragile across plugin versions, and duplicates the agent's LiveKit ingestion. Rejected unless A and B both fail.

## Recommendation
Ship **Option A** (calls over LiveKit) as the durable answer — it collapses two media stacks into one and gets Townhall-grade multilingual captions for 1:1 with almost no new caption code. Keep the P2P path behind a feature flag as fallback during rollout. Use **Option B** only if per-minute Deepgram/LiveKit cost for casual 1:1 calls is unacceptable and mic-sharing tests pass.

## Cost / privacy guardrails (either server-backed path)
- Captions are **opt-in per call** (a CC toggle), off by default — Deepgram is per-minute.
- The proxy is currently `requireSession(["admin"])`. For 1:1 user calls, relax to any authed participant **but** gate with `checkRateLimit` (see Phase 3 plan for the util) keyed by `userId`, and stop the agent on call end (`POST /stop`) so no room bills idle.
- Surface a small "Captions on • Deepgram" indicator so users know audio is transcribed.

## Follow-up (preferred long-term shape) — captions on-demand, NOT default LiveKit routing
Making LiveKit the default media path for **all** 1:1 calls means every call pays for LiveKit
(paid infra, always) even when nobody wants captions. Better end state: keep **free P2P as the
norm** and only route a call through LiveKit **when a user actually taps CC** — i.e. captions
become an in-call opt-in that upgrades the media path just for that call, rather than a global
flag that re-routes everything.

Two ways to get there (evaluate after the flag-on test passes):
- **Mid-call upgrade:** start P2P; on first CC tap, transparently migrate that call to a LiveKit
  room (renegotiate both peers into the room), enable captions, and tear down the P2P leg.
  Best UX, most engineering (a live media-path handoff + both-sides renegotiation).
- **Pre-call choice:** if either party enables "Captions" before dialing, that call is placed
  over LiveKit; otherwise P2P. Simpler; no live handoff; the cost only hits caption-wanted calls.

Either keeps the `TALK_LK_CALLS` global flag as the coarse kill-switch but changes the default
so cost is proportional to caption usage, not call volume. Recommended over a fleet-wide flag flip.

## Deliverables when built
1. Decision recorded (A/B) + feature flag.
2. If A: 1:1-over-LiveKit call path + callee token mint; caption overlay reused from Townhall.
3. Proxy auth relaxed to authed participants + rate limit + auto-stop on hangup.
4. Fat rebuild (both ABIs) + on-device test on A23 (`R68T304FX1F`) and Redmi (`N7VGJFDIWW49LVJJ`): Arabic/Urdu/English interim→final, cost check, auto-stop verified.
