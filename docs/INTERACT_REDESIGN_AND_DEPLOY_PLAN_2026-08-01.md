# INTERACT Talk — Redesign + Critical-Fix Deployment Plan

**Date:** 2026-08-01 · **App version at authoring:** `0.5.4+6042` · Status: planning north-star (not yet built)

> ⚠️ **Reality-check vs the source prompts (read first).** Several assumptions in the original three deliverables were written before the 2026-08-01 session and are now STALE. Corrections:
> - **CRM resolve backend is v2, deployed.** The dual-algo (`hmac-sha256-pepper-v1` + v1) route is LIVE; the `talk_refresh_tokens` table exists; `6042` clients resolve names. Checklist "Deploy Phase 3 v2" + "Verify CRM resolve v2" are DONE — only on-device confirmation remains.
> - **Design tokens:** `#25D366`/`#075E54` are **WhatsApp**, not INTERACT. Use INTERACT's own palette: **forest `#0d3b2c`**, **gold `#c9a227`**, **sand `#f4efe4`**, red `#DC3545` for destructive.
> - **"Me" tab is partly reorganized already** (real About dialog; placeholder tiles now show "coming soon" instead of dead taps). Collapsible sections + badges is the next increment.
> - **"Session expired" is solved** — durable offline auth (short access + revocable refresh token) shipped in `6042`; the app no longer logs out at 8h or while offline. Reflect this in onboarding copy.
> - **OTA rollback:** accurate gap — reverting is manual (`latest.json` → prior version). Worth a scripted `rollback-ota.sh`.

---

## PART A — Product Redesign (north-star)

### Core principles
1. **User-centric:** hide complexity by default (BLE mesh / LoRa tucked away, discoverable for power users); one primary purpose per screen; AI as a helper, not a gimmick.
2. **Visual hierarchy:** bold headers, subdued gray descriptions, consistent unique icons; group related features under collapsible sections; status badges ("Beta", "Offline", "AI", "Coming soon").
3. **Navigation simplicity:** **4-tab bottom nav** (Chats, Calls, Contacts, Me); remove the `Menu` tab and redistribute; progressive disclosure (long-press a chat for Walkie/Townhall).
4. **AI & offline-first:** surface AI in a dedicated section; describe offline features in plain language ("Send messages without internet", not "sahl_mesh gossip").

### Information architecture — 4 tabs
- **Chats 💬** — messaging; attachment menu (Camera, Gallery, Camera FX, File, Location); long-press → Walkie/Townhall where relevant.
- **Calls 📞** — segmented top tabs `Call / Townhall / Walkie`; recent-calls list with optional AI summaries.
- **Contacts 👥** — floating "+" to Invite; groups: Frequent (AI-ranked by interaction), INTERACT Users, Device Contacts; search with CRM resolve (now live).
- **Me 👤** — profile card + collapsible sections (below) + red Sign out.

### "Me" restructure (collapsible sections)
- **👤 Profile** — avatar + @username + phone (editable); "Set your @username".
- **🔒 Security & Privacy** — E2E encryption (Phase 1.5), Backup & Restore (passphrase), Call history, Blocked contacts, Login QR, Login codes, Approve login.
- **🤖 AI & Voice** — Voice-note transcription (cloud Whisper when key set), AI audit log, Private AI (→ "Join waitlist" until ready), On-device capability (show download progress when applicable).
- **🌐 Offline Connectivity** (collapsed) — Offline LAN, Nearby mesh (BLE), LoRa bridge, Nearby devices; plain-language descriptions.
- **⚙️ App Settings** — Languages (EN/UR/AR/TR/RU/PA), Check for updates, Auto-update, Source/License/Dependencies.
- Tweaks: unique icon per row; technical detail in small gray text; only real toggles shown (placeholders → badge, not a dead switch); status badges.

### Design system (corrected to INTERACT identity)
| Element | Guide |
|---|---|
| Colors | Primary **forest `#0d3b2c`**, accent **gold `#c9a227`**, surface **sand `#f4efe4`**, destructive `#DC3545`. (NOT WhatsApp green.) |
| Type | Headers bold 18pt, body 16pt, descriptions 12pt gray. |
| Icons | Material Icons or custom INTERACT set, consistent. |
| Cards | 8pt radius, subtle shadow, surface bg. |
| Toggles | Gold/forest when active, gray inactive; hide if placeholder. |
| Badges | Small rounded pills: Beta / AI / Offline / Coming soon. |

### AI enhancements (roadmap)
- On-device voice transcription toggle (when `llama.cpp` binding ready) + language selection.
- AI call summaries in the Calls tab ("Called Dr. Shazia — 5 mins; follow up tomorrow").
- Smart replies in chats.
- Contact ranking by call/chat frequency.
- Offline-mode suggestion banner when no internet ("Try Nearby Mesh or LoRa Bridge").

### Redesign implementation phases (from source, ~5 weeks)
1. **UI/UX cleanup (1w):** collapsible Me sections; 4-tab nav; move Walkie/Townhall → Calls; Camera FX → chat attachments; "+" invite in Contacts; hide placeholder toggles.
2. **AI integration (2w):** call summaries; smart replies; on-device transcription; contact ranking.
3. **Offline UX (1w):** rename technical terms; tooltips; auto-suggest offline modes.
4. **Testing & polish (1w):** usability testing (5+); A/B the Me layout; fix feedback.

### Success metrics
7-day retention +20%; time-to-find-feature <10s; AI feature try-rate >50%; offline-mode adoption >30%; store rating ≥4.5.

---

## PART B — AI review prompt (for future validation runs)

Use for an assistant to review/validate INTERACT Talk delivery vs claims. Role: (1) validate feature delivery (security, functionality, UX) vs original claims; (2) prioritize risks (Critical/High/Medium/Low + deadlines); (3) actionable strengthening steps; (4) benchmark vs WhatsApp/Slack/Zoom; (5) markdown-table output + prioritized roadmap + success metrics; (6) sandboxed analysis only, security- and user-impact-first. **Update the "current state" context each run** — as of 2026-08-01: CRM resolve v2 is LIVE (not v1); durable auth shipped; LiveKit captions built but flag-OFF (untested in prod); `interact_pro` OAuth secret moved to env but NOT rotated; OTA cache 60s, no automated rollback.

---

## PART C — Critical-fix deployment checklist (updated for 2026-08-01 state)

### Already DONE this session (do not redo — confirm only)
- ✅ Phase 3 v2 backend deployed (dual-algo route + `talk_refresh_tokens` table).
- ✅ `interact_pro` secret removed from source → `--dart-define` from `_shared/config/google_credentials.json`; build scripts wired + guarded; `.gitignore` covers the file.
- ✅ `0.5.4+6042` built (fat + splits), OTA published, installed on both phones.
- ✅ OTA manifest cache 300s→60s.

### Still OPEN (owner: you)
| Task | Severity | Notes |
|---|---|---|
| **Rotate `interact_pro` OAuth secret** in Google Console (project `interact-pro-496115`), update `_shared/config/google_credentials.json`, rebuild `interact_pro`, close GitHub alert #2 as Revoked | **High** | Leaked `GOCSPX-…` still valid until rotated. Back up old value first. |
| **On-device confirm CRM names** resolve on `6042` (known-CRM number → real name; unknown → phone fallback) | Medium | Backend v2 live; just verify end-to-end. |
| **Test LiveKit captions** with `--dart-define=TALK_LK_CALLS=1` build (1:1 call, toggle CC, EN/UR/AR, Deepgram stops on hangup, cost acceptable) before enabling in prod | Medium | Keep prod flag-OFF until it passes; M5 = compile-time flag → roll out atomically. |
| **Durable-auth on-device test** — log in, airplane-mode past 8h, reopen → stays logged in, silently refreshes on reconnect | Medium | Proves the no-logout-offline rule. |
| **Scripted OTA rollback** (`rollback-ota.sh` → repoint `latest.json` to previous `version_code`) | Low | Currently manual. |

### Rollback fallbacks (already built-in)
- CRM resolve fails → phone numbers shown (fail-soft). LiveKit fails → "Use classic call" P2P fallback. OAuth fails → `interact_pro` can't reach Google Drive (device-flow only). Auth refresh fails offline → stays logged in (no logout).

### Post-deploy monitoring
- `journalctl`/PM2 logs for `qurbanisahulat` (CRM resolve errors, refresh 401s); client `UNKNOWN_ALGO` should be absent on `6042`. Verify manifest with cache-buster (`?t=$(date +%s)`), never a plain fetch.
