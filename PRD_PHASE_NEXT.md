# INTERACT Talk (interact-app) — PRD: Built State + Phase-Next (2026-07-24)

## 1. What INTERACT Talk is
A fleet-native comms **super-app** (Flutter) for the INTERACT business group — chat + voice/video + meetings, built on the **shared Talk backend** (`qurbanisahulat.com/api/v1/talk/*` + `/chat/*`), INTERACT SSO (`INTERACT_AUTH_SECRET`), the shared WebRTC mesh (`signal.interactpak.com` + coturn), and the interact-connect comms hub. It is NOT trying to out-scale WhatsApp; it is the **internal, identity-unified comms layer** every INTERACT app (FleetOps, progressive-farmer, exec-os) can plug into.

## 2. What's built (shipped)
**Identity & discovery:** INTERACT SSO login (phone-first, carries phone+email); peers discoverable by **number OR email**; shadow/native row adoption; QR connect; device-contacts import + invite (SMS/WhatsApp/email).
**Chat:** 1:1 (general) + **group** threads (create/manage, add/remove/leave); typing indicators; delivery/read **ticks**; **media attachments** (image/video/file ≤50MB); message-watcher notifications; **encrypted backup + restore** (client AES-GCM+PBKDF2, server stores opaque blob).
**Calls:** 1:1 **video/audio** over WebRTC (signal+coturn, NOT LiveKit); **townhall/group meetings** (LiveKit) with participant grid, join preview, participant count; **meeting gestures + host controls**; **incoming-call ring** (foreground poll + **FCM background push** — backend live fail-soft, client staged on creds).
**Presence:** online / last-seen dots on contacts + chats.
**Media/UX:** profile pictures/avatars across chats/contacts/calls; **camera virtual background** (blur + images via ML Kit segmentation); location personalization; branded launcher icon; **VPS auto-update**; web companion at `interactpak.com/interact/web`.

## 3. Competitive review (2026)
| App | Strengths worth matching | Not our game |
|---|---|---|
| **WhatsApp** | Usernames (connect without sharing number, rollout 2026), **Communities** (group-of-groups), **Channels** (broadcast), voice-message **transcripts**, voice chat in groups, disappearing messages, group history for new members, event reminders, 32-person calls, call filters/backgrounds (Talk already has bg) | Consumer-scale network effects |
| **Telegram** | 200k-member groups, channels, **bots + mini-apps**, message edit/delete/scheduled, reactions, folders, rich text | Public bot economy |
| **Zoom** | **AI summaries + action items**, **live translation/captions (46+ langs)**, real-time transcription, noise cancellation, recording (ZoomMate) | Enterprise webinar scale |
| **Google Meet** | AI notes, live captions/translation, calendar-native scheduling | — |

**Read:** Talk already matches the *transport* layer (calls, groups, presence, backgrounds, backup) and beats consumer apps on **fleet SSO + email/number discovery**. The visible gaps are (a) **message UX table-stakes** (reactions/reply/edit/voice notes/disappearing) and (b) the **AI meeting layer** (summaries + multilingual live captions) — the latter is the highest strategic lever because INTERACT operates across **EN/UR/AR/TR/RU (+PA)** and already ships `ai-client` (DeepSeek) + 5-language i18n. Zoom/Meet charge for exactly this; Talk can offer it fleet-wide.

## 4. Phase-Next (prioritized, borrow-first — logged in `_shared/knowledge-hub/APP_TASKS/interact-app.md`)

**P1 — message UX parity (table-stakes vs WhatsApp/Telegram)**
- Reactions (emoji), reply/quote, edit + delete-for-everyone, pin — extend the shared `/chat/threads/[id]/messages` contract (benefits every consuming app).
- Voice notes + **AI transcript** (record → upload → `ai-client` transcription, grounded; matches WhatsApp voice transcripts).
- Disappearing/auto-delete messages + "group history for new members" toggle.
  (**Not shipped** — remove from marketing/catalog status until built. Do not
  expose a chat-menu entry that implies the feature works.)
- Finish **FCM background ring** (creds-gated — see tasks book) + missed-call trail + unread badges.

**P2 — the AI meeting layer (the differentiator)**
- **Meeting recording (opt-in) → AI summary + action items** via `ai-client` (DeepSeek), stored per thread. This is the Zoom/Meet moat, fleet-wide.
- **Live captions + multilingual translation** across the 5–6 fleet languages (huge for PK/UAE/TR/RU ops) — start with post-call transcript translation, then live captions.
- Noise suppression on the WebRTC path.

**P2 — broadcast & org structure**
- **Channels** (one-way announcements — company/team broadcast; consume the group thread with a `broadcast` role).
- **Communities** (group-of-groups mapped to an INTERACT org/department) — reuse group threads + a parent link.

**P3 — privacy & convenience**
- **Usernames/handles** (connect without sharing a number — extends the existing phone/email discovery).
- Scheduled messages, message search, always-on group voice chat, event reminders.

## 5. Guardrails
Reuse the shared Talk backend + WebRTC mesh (no second stack, no LiveKit for 1:1); AI features go through `ai-client` (DeepSeek→Mistral cascade) and stay **grounded** (summaries cite the transcript, never invent). Every message-contract change is additive so FleetOps/farmer/exec-os consumers don't break. FCM is the one true blocker (operator Firebase creds).

Sources: WhatsApp 2026 ([Omnichat](https://blog.omnichat.ai/whatsapp-features/), [usernames/MEF](https://mobileecosystemforum.com/2025/11/11/whatsapp-usernames-2026-rollout-for-enhanced-privacy-business-branding/)); Telegram 2026 ([UKTU guide](https://uktu.org/technology/telegram-web-complete-guide-2026/), [Premium](https://durovscode.com/telegram-premium-features-worth-it-2026)); Zoom AI Companion 2026 ([review](https://anarlog.so/blog/zoom-ai-companion-review/), [translation](https://www.bluente.com/blog/zoom-ai-companion-transcript-translation-2026)).
