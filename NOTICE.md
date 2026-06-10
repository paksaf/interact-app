# NOTICE — Open-Source Dependencies

INTERACT is distributed under **AGPLv3** (see `LICENSE`). It incorporates the
following open-source components, each under its own license. All dependencies
listed here are AGPLv3-compatible.

## Core runtime

| Component | License | Purpose | Project |
|---|---|---|---|
| Flutter SDK | BSD-3-Clause | App framework | https://flutter.dev |
| Dart | BSD-3-Clause | Language runtime | https://dart.dev |

## Direct dependencies (see `pubspec.yaml`)

| Package | License | Purpose |
|---|---|---|
| flutter_riverpod | MIT | State management |
| go_router | BSD-3-Clause | Declarative routing |
| shared_preferences | BSD-3-Clause | Persistent prefs |
| path_provider | BSD-3-Clause | Filesystem paths |
| flutter_secure_storage | BSD-3-Clause | Encrypted token store |
| http | BSD-3-Clause | HTTP client |
| flutter_webrtc | MIT | WebRTC native bindings |
| web_socket_channel | BSD-3-Clause | WebSocket signaling |
| pin_code_fields | MIT | OTP input UI |
| wakelock_plus | BSD-3-Clause | Keep screen on during calls |
| mobile_scanner | BSD-3-Clause | QR-code scanner for invite codes |
| qr_flutter | BSD-3-Clause | QR-code display |
| record | BSD-3-Clause | Audio recording (voice messages) |
| audioplayers | MIT | Audio playback |
| bonsoir | MIT | mDNS LAN discovery (offline mode) |
| sahulat_common | AGPLv3 (sibling) | Shared INTERACT primitives — theme, ApiClient, Whisper STT, TTS |

## Self-hosted backend services

| Service | License | Purpose | Endpoint |
|---|---|---|---|
| Custom Go signaling server | AGPLv3 | WebRTC signaling | `signal.interactpak.com:8765` |
| coturn | BSD-3-Clause | STUN/TURN for NAT traversal | `turn.interactpak.com:3478` |
| mediasoup (Phase 2) | ISC | SFU for group calls | self-hosted Docker |
| PostgreSQL | PostgreSQL License | Message + thread persistence | self-hosted |
| Redis | BSD-3-Clause | Presence pub/sub | self-hosted |
| ntfy or UnifiedPush | Apache-2.0 / AGPLv3 | Push notifications (Phase 1) | self-hosted |

## On-device AI models (Phase 1.5, lazy-loaded)

| Model | License | Purpose | Size |
|---|---|---|---|
| whisper.cpp (tiny INT8, Urdu fine-tune) | MIT | On-device STT | ~35 MB |
| XTTS-v2 (quantized, Urdu fine-tune) | MPL-2.0 | On-device TTS | ~120 MB |
| Mistral-7B (4-bit GGUF) — optional | Apache-2.0 | On-device AI assistant | ~4 GB |

These models are downloaded on first use of the corresponding feature.
INTERACT's base APK does NOT bundle them — keeps install size under ~15 MB
per the research-backed PRD.

## Why AGPLv3

INTERACT is a **communication app**, which means the server side is
unavoidably user-facing infrastructure. AGPLv3 (vs MIT/Apache) ensures
that anyone running a modified INTERACT *server* must publish their
modifications back to the community. This is the same model Signal,
Element/Matrix, and Mastodon use for the same reason.

The mobile/desktop client is also AGPLv3. Combined source is available
at `hub.interactpak.com/interact/interact-app` (Forgejo, self-hosted).
GitHub mirror at `github.com/paksaf/interact-app` is read-only.

## Contact

- **Maintainer:** INTERACT Group (Karachi · Dubai · Istanbul · Moscow)
- **Forgejo:** https://hub.interactpak.com/interact/interact-app
- **Issues:** https://hub.interactpak.com/interact/interact-app/issues
- **Email:** interact@paksaf.com
