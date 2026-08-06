# INTERACT Talk — AI Voice Transcription & Call Summaries (PRD, architecture-corrected)

**Date:** 2026-08-01 · **Owner:** Muzaffar Hussain · Status: planning (not built)

> This condenses a longer source PRD and **corrects its technical premises** to match INTERACT's real stack. The product thinking (user stories, edge cases, recovery flows, wireframes, metrics) is preserved; the wrong tech foundations are replaced. Full verbose source lives in chat history.

## ⚠️ Architecture reality-check (read before building)
1. **`llama.cpp` ≠ transcription.** ASR (audio→text) needs **`whisper.cpp`** on-device (or cloud Whisper/Deepgram). `llama.cpp` is an LLM — it belongs to the **summary** step (text→summary), NOT transcription. Split the two engines cleanly.
2. **Calls are not recorded.** 1:1 is P2P WebRTC (no server media); LiveKit doesn't record by default. So "summarize call audio" has **no input**. Correct path: **summaries consume the caption-agent's live transcript** (Deepgram) when captions were on. No captions = nothing to summarize unless you add explicit opt-in recording (consent + storage + privacy — a separate, heavy feature). Voice-NOTE transcription (audio messages) is the simpler, real near-term win.
3. **Providers:** cloud ASR = Deepgram (`DEEPGRAM_API_KEY`, already wired in `interact-realtime/caption-agent`) or OpenAI Whisper (`OPENAI_API_KEY`). Don't conflate the two keys.
4. **Backend is qurbanisahulat (Next.js), not a new FastAPI service.** `/api/v1/talk/transcribe` and `/api/v1/talk/live/captions` already exist — extend them. Do NOT stand up a parallel Python backend with its own Postgres.
5. **CRM stays read-only.** No client-side "Save to CRM" writes; keep the admin-reviewed "Suggest to CRM" model (Phase 3 posture). Summaries may *display* a resolved CRM name (via the existing resolve endpoint) but must not write back.
6. **Right-size scale.** Single Hetzner VPS — targets like "10K concurrent transcriptions" are unrealistic; design for tens, queue the rest.

## Scope (corrected)
**Near-term (buildable now):**
- **Voice-note transcription** — transcribe audio *messages* (not calls). On-device `whisper.cpp` when a model is present + permitted, else cloud (Deepgram/Whisper) when a key is set, else a clear "AI not configured" state. Languages EN/UR/AR/TR/RU/PA (accuracy varies; UR/AR weaker). Endpoint: extend `qurbanisahulat /api/v1/talk/transcribe`.
- **Captioned-call summary** — when a call used captions, summarize the **caption transcript** with an LLM (cloud DeepSeek/Mistral per the fleet ai-client policy, or on-device `llama.cpp` when ready). Store a short summary + key points linked to the call log. Display a resolved CRM name if available.

**Deferred:** recording non-captioned calls (needs consent/storage design); speaker diarization; multi-speaker attribution; CRM write-back; on-device LLM summaries until a `llama.cpp` binding exists.

## User stories (kept, retargeted)
- Doctor: transcribe a voice **note** to review later (<5s on-device; stored in chat). 
- Field staff: transcribe a voice **note** offline (on-device, no internet; cloud fallback only when online + user opts in).
- User: pick transcription language (EN/UR/AR/TR/RU/PA); see a confidence indicator; low confidence (<0.7) shows a "may be inaccurate" hint.
- Doctor: after a **captioned** call, get a summary + bulleted key points from the transcript; edit/delete/share it (share = plain text).
- User: rate a transcription/summary (👍/👎) → feedback endpoint; opt out of analytics in Me › Privacy.
- User: a summary may show a CRM-resolved name ("Call with Dr. Shazia") — display only, never written to CRM.

## Wireframes (kept, condensed)
- **Voice note in chat:** player + "🎤 Transcribe"; dialog shows progress + language + on-device/cloud source; result shows text + confidence + 👍/👎 + Copy/Delete.
- **Calls tab:** recent-calls row with "📝 Summarize" (only enabled if the call had captions/transcript); summary card = Summary + Key Points + Participants + Time + Edit/Delete/Share.
- **Me › AI & Voice:** toggles for Voice-note transcription (on-device-first + language), Call summaries (+ auto-summarize off by default), AI analytics (opt-in), On-device capability (status/needs model).

## Edge cases & recovery (kept — the strongest part of the source)
Preserve the source's matrices; the load-bearing ones, retargeted:
- **Long audio:** chunk voice notes >~5 min, process sequentially, merge; show per-chunk progress.
- **On-device model missing/fails:** fall back to cloud (if key + online + consent), else a clear "AI not configured / offline" state. Never hard-fail silently.
- **Network loss mid-cloud:** cache the audio locally, retry on reconnect (reuse the app's existing offline outbox pattern), never lose the note.
- **No transcript for a call:** disable "Summarize" with a tooltip ("Turn on captions during a call to enable summaries"), or offer a metadata-only line (participants + duration).
- **Feedback/analytics offline:** queue locally, sync on reconnect; analytics opt-out respected (only aggregate/anonymous if on).
- **Sensitive content in summaries:** redact obvious PII before share; warn before sharing.
- Full test checklist + recovery flows: see source; a `RecoveryManager`-style queue + exponential backoff + connectivity listener is the right client pattern (INTERACT already has an offline outbox to reuse rather than build anew).

## API shape (corrected — extend qurbanisahulat, `ok()`/`err()` envelope, `requireSession`)
- `POST /api/v1/talk/transcribe` (exists) — body `{ audioUrl|audioId, language, preferOnDevice }` → `{ text, language, confidence, source }`. On-device done in the Flutter client (whisper.cpp) when available; the route is the cloud path.
- `POST /api/v1/talk/calls/[id]/summarize` (new) — input is the **caption transcript** for that call (or 400 `NO_TRANSCRIPT`); LLM via the shared `ai-client` policy (DeepSeek→Mistral) or on-device later → `{ summary, keyPoints[], source }`. Rate-limited per user; store in a `talk_call_summaries` table (add via migration or hand-written CREATE TABLE on the VPS — gotcha #68, never `db push`).
- `POST /api/v1/talk/feedback` + `/analytics` (new, optional) — thumbs + usage; both fail-soft, both respect the analytics opt-out.
- **No** separate FastAPI service; **no** CRM write endpoint.

## Non-functional (right-sized)
- On-device voice-note transcription target <~5s for ~1 min audio on a mid-range device; cloud <~10s.
- On-device data never leaves the phone; cloud calls over TLS; Deepgram is per-minute — gate summaries behind an explicit toggle (default off), like captions.
- Privacy: transcription/summarize are opt-in per action; analytics opt-out honored.

## Success metrics (kept)
Transcription try-rate >60%; captioned-call summary usage where transcript exists >50%; on-device share of transcriptions >70% (once whisper.cpp ships); transcription failure <5%; recovery success >90%.

## Phasing (corrected order)
1. **Voice-note transcription (cloud first)** — extend `/talk/transcribe`, add the chat UI + 👍/👎; ship without on-device. Lowest risk, real value.
2. **Captioned-call summaries** — summarize the caption transcript via `ai-client`; Calls-tab summary card. Depends on captions (Phase 2c) being usable.
3. **On-device `whisper.cpp`** transcription (privacy/offline) — the real "on-device AI" milestone; needs a Flutter binding.
4. **On-device `llama.cpp` summaries** + feedback/analytics polish + edge/recovery hardening.
