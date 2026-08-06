# INTERACT Talk — Consolidated Roadmap

**Date:** 2026-08-01 · **Live version:** `0.5.4+6042` · **Owner:** Muzaffar Hussain
**North star:** an **AI-first, multipurpose, offline + online communication app** with a distinct INTERACT identity (forest/gold palette, offline mesh/LoRa, privacy-first, open-source) — NOT a WhatsApp clone. This is the single source of truth; the four detailed docs (below) are referenced, not duplicated.

## Stack ground-truth (applies to every plan; corrects recurring PRD assumptions)
- **Backend = qurbanisahulat, Next.js App Router.** New routes = `src/app/api/v1/talk/**/route.ts` with `runtime="nodejs"`, `dynamic="force-dynamic"`, a `requireSession()` gate, and the `ok()/err()` envelope. **NOT** `pages/api/*`, `req.session.userId`, or raw `res.status().json()` (Pages Router — won't compile). User id = `gate.userId`.
- **Prisma 5 pinned.** New models need a migration file OR a hand-written `CREATE TABLE` on the VPS (`ssh interact 'sudo -u postgres psql -d qurbanos'`), matching Prisma index/constraint names. **Never `prisma db push`** (gotcha #68 — drops the unmanaged `talk_message_index`). Models are PascalCase mapped to snake_case tables via `@@map` (e.g. `TalkCrmSuggestion` → `talk_crm_suggestions`), not `CRM_Suggestion`.
- **Admin/email notifications → interact-connect Comms Hub** (`POST connect.interactpak.com/api/comms/send`, header `X-Hub-Token`, WhatsApp/Resend), to the canonical inbox **`interact@paksaf.com`**. NOT Nodemailer/FCM/Slack. The hub token must be in the app's REAL `.env` (gotcha #59). Fire-and-forget — never block the response.
- **AI engines:** ASR = `whisper.cpp` (on-device, later) or **Deepgram** (cloud, `DEEPGRAM_API_KEY`). Summaries = caption transcript → **ai-client** (DeepSeek→Mistral). `llama.cpp` is for summaries only (it can't transcribe). CRM is **read-only**; suggestions are admin-reviewed, never client-side writes.
- **Palette:** forest `#0d3b2c`, gold `#c9a227`, sand `#f4efe4`, red `#DC3545`. Never WhatsApp green.

## DONE this session (`0.5.4+6042`, live on both phones + CDN)
Durable offline auth (short access + revocable refresh; never logs out offline) · CRM resolve v2 (HMAC dual-algo, rate-limited, field-whitelisted) · voice-command assistant · LiveKit captions (flag-OFF) · Me-tab + update-on-launch fixes · voice commands · `interact_pro` OAuth secret pulled from source + build-wired · OTA manifest cache 60s · `db push` guard · gotchas #68/#69.

---

## ROADMAP — Now / Next / Later

### 🔴 NOW — unblock + validate what's shipped (owner: you; no new build unless noted)
1. **Rotate `interact_pro` OAuth secret** in Google Console (`interact-pro-496115`), update `_shared/config/google_credentials.json`, rebuild `interact_pro`, close GitHub alert #2 as Revoked. *(High — only open security item.)*
2. **On-device confirm on `6042`:** (a) a known-CRM number resolves to a real name; (b) durable auth — airplane-mode past 8h, reopen → still logged in, silent refresh on reconnect; (c) captions — build with `--dart-define=TALK_LK_CALLS=1`, place a 1:1 call, toggle CC, verify EN/UR/AR + Deepgram stops on hangup.
3. *(optional)* `rollback-ota.sh` — repoint `latest.json` to a previous `version_code`.

### 🟡 NEXT — Phase 1 UX + first AI feature (small, shippable, high-leverage)
4. **4-tab nav + collapsible "Me"** (redesign Phase 1). Remove the `Menu` tab; redistribute: Invite → Contacts FAB, Walkie/Townhall → Calls segmented tabs, Camera FX → chat attachment menu, Login QR/codes/approve → Me › Security. Collapsible Me sections (Profile / Security / AI & Voice / Offline Connectivity / App Settings) + status badges; keep offline features labeled-but-tucked (don't bury the differentiators). Flag-free, incremental. **Ref:** `INTERACT_REDESIGN_AND_DEPLOY_PLAN_2026-08-01.md`.
5. **Voice-note transcription (cloud/Deepgram first).** Extend `/api/v1/talk/transcribe` (App Router + Deepgram, `DEEPGRAM_API_KEY`); chat voice-note player gets a "Transcribe" button + result view + 👍/👎 → new `/api/v1/talk/feedback` route (+ `talk_feedback` table). No on-device yet. **Ref:** `AI_TRANSCRIPTION_SUMMARIES_PRD_2026-08-01.md` + the Flutter widget scaffolds in chat (correct the base URL to `qurbanisahulat.com`, reuse `talk_api.dart` bearer/`_headers()`).

### 🟢 LATER — depends on the above
6. **Captioned-call summaries.** New `POST /api/v1/talk/calls/[id]/summarize` — input is the **caption transcript** (400 `NO_TRANSCRIPT` if none) → ai-client (DeepSeek→Mistral) → `{summary, keyPoints[]}`; store in `talk_call_summaries`; Calls-tab summary card (edit/delete/share). Depends on Phase 2c captions being usable. **Ref:** `PHASE_2C_LIVE_CAPTIONS_PLAN.md` (captions-on-demand follow-up) + AI PRD.
7. **CRM suggestion flow + admin email** (detailed below).
8. **On-device `whisper.cpp`** transcription (privacy/offline milestone) → then **`llama.cpp`** on-device summaries.
9. **Captions on-demand** (2c follow-up: only route a call through LiveKit when a user taps CC, keep free P2P as default) + **role-scope tightening** (Phase 3 `scopeMatch` seam, once the role→CRM-tag map is confirmed).
10. Redesign Phases 2–4 (smart replies, contact ranking, offline-mode suggestion banner, usability testing).

---

## CRM Suggestion Flow — with admin email (corrected to INTERACT stack)

**Purpose:** let users suggest linking a call summary / transcription to a CRM contact, admin-reviewed. Enables organic CRM growth without violating the read-only posture.

**Client (interact-app):** a "Suggest to CRM" action on a summary/transcription → `POST /api/v1/talk/crm/suggest` `{contactName, contactOrg?, note?, summaryId?|callId?, summaryText}` via the existing bearer `_headers()`. Pre-fill contactName from the CRM-resolve match when present.

**Backend (App Router route, `requireSession()`, `ok()/err()`):**
1. Store a `TalkCrmSuggestion` row (`@@map("talk_crm_suggestions")`): `id, userId(gate.userId), callId?, summaryId?, contactName, contactOrg?, summaryText, note?, status="pending", reviewedBy?, reviewedAt?, createdAt`. Add via migration or hand-written `CREATE TABLE` on the VPS (never `db push`).
2. **Notify admins via the Comms Hub** (fire-and-forget, never block): `POST https://connect.interactpak.com/api/comms/send` header `X-Hub-Token: $INTERACT_HUB_TOKEN`, body `{channel:"email", to:"interact@paksaf.com", subject:"New CRM suggestion #<id>", text:"<user> suggested linking <contactName>. Review: https://<admin>/crm/suggestions", app:"talk"}`. (Hub token must be in the real `.env` — gotcha #59.) Optionally also `channel:"whatsapp"` to the ops number.
3. Return `ok({suggestionId, status:"pending"})`.

**Admin review UI** (interactpak or qurbanisahulat admin area): list pending (filter by status), Preview modal, **Approve / Reject** → `POST .../crm/suggestions/[id]/approve|reject` (admin-gated `requireSession(["admin"])`): update `status` + `reviewedBy/reviewedAt` + audit-log; notify the submitter via the Talk inbox. **Approve does NOT auto-write CRM** (CRM is read-only) — it marks the suggestion accepted for a human to enter into the CRM, or feeds an admin-only CRM-write path if/when one is built. Metrics: pending count <10, approval time <24h, rejection rate <20%.

**Guardrails:** no client-side CRM writes; no bulk; every suggestion carries `userId` for audit; sanitize obvious PII from `summaryText` before it's emailed.

---

## Review refinements (folded in 2026-08-01)
Accepted from the roadmap review; apply when the relevant phase is built:
1. **Comms-Hub notify is not fire-and-forget-only — add durability.** `talk_crm_suggestions` gets a `notifyStatus` (`sent|pending_retry|failed`) + `retryCount` (max 3). A small scheduled task (systemd timer / the app's cron pattern) re-sends `pending_retry`; after 3 fails → `failed` and the admin list shows a red "Notification failed" badge so a human still sees the suggestion. Never lose a suggestion just because the hub/`X-Hub-Token` (gotcha #59) was down.
2. **Define the hybrid AI strategy up front (even though cloud ships first).** Architect the transcription module as `preferOnDevice → whisper.cpp if available, else Deepgram` from day one, so flipping on-device on later needs no front-end audio-handling rewrite. Same shape for summaries (on-device `llama.cpp` → cloud ai-client).
3. **Generate migration SQL, don't hand-type it.** For a new model, run `./node_modules/.bin/prisma migrate dev --create-only --name <desc>` **locally against a scratch DB** to emit the official SQL (correct `@@map` + index/constraint names), then paste *that exact SQL* onto the VPS (`sudo -u postgres psql -d qurbanos`). Guarantees schema↔DB parity; still never `db push` (gotcha #68).
4. **CRM suggestion: add user Revoke.** `PATCH /api/v1/talk/crm/suggest/[id]/revoke` → `status="revoked"` within a 10-min grace window (owner-only), so a mistyped suggestion doesn't clutter the admin queue.
5. **Rename the summary error** `NO_TRANSCRIPT` → `NO_CAPTIONS_AVAILABLE` (precise about the data source = captions).
6. **Base-URL by env, not hardcoded.** `talk_api.dart` should resolve its base (`qurbanisahulat.com` prod vs a dev IP) via `--dart-define`/build config, not a literal — matches how `CRM_RESOLVE_PEPPER`/`TALK_LK_CALLS` are already passed.

## Success metrics (rolled up, review-adjusted)
Transcription try-rate >50% · captioned-call summary usage (where transcript exists) >40% · feedback rate >20% · **CRM-suggestion rate >5%** (deliberate secondary action) **+ admin-approval rate >30%** (quality signal) · durable-auth: zero unexpected logouts while online · app rating ≥4.5.

## Document index (`interact-app/docs/`)
- `PHASE_2C_LIVE_CAPTIONS_PLAN.md` — LiveKit captioned 1:1 calls (flag-gated) + on-demand follow-up.
- `PHASE_3_CRM_RESOLVE_PLAN.md` — CRM resolve endpoint + v2 hardening.
- `INTERACT_REDESIGN_AND_DEPLOY_PLAN_2026-08-01.md` — 4-tab redesign + critical-fix checklist.
- `AI_TRANSCRIPTION_SUMMARIES_PRD_2026-08-01.md` — transcription + summaries (architecture-corrected).
- **`INTERACT_TALK_ROADMAP_2026-08-01.md`** — this file (source of truth / sequencing).
