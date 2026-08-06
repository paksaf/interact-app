# Phase 3 — CRM contacts resolve endpoint (written plan)

**App:** interact-app "INTERACT Talk" + qurbanisahulat backend · **Status:** planned, not built · **Date:** 2026-07-31

## Goal (the approved hybrid design)
Let Talk show a real name for an incoming/known number by matching it against the 49K+ INTERACT
CRM — **without** shipping the CRM to the device. The client sends only **hashed** phone numbers
to a **JWT-authorized backend proxy**, which returns **role-scoped** matches. No CRM API key on the
client, no bulk dump, device contacts remain the fallback.

## What already exists (reuse, don't reinvent)
- **Auth gate:** `qurbanisahulat/src/lib/api-auth.ts` `requireSession(allowedRoles?)` → verifies the SSO JWT (HS256, **`AUTH_SECRET`** — note: backend var is `AUTH_SECRET`, not `INTERACT_AUTH_SECRET`) via `src/lib/auth.ts` `getSession()`. Accepts `Authorization: Bearer <token>` (Flutter) or `qs-session` cookie. Token claims available: `sub, email, name, role/roles, phone`. `gate.userId` is a resolved local uuid; `gate.roles` for scoping.
- **Response envelope:** `src/lib/api-response.ts` `ok(data)` → `{success,data,meta,error:null}`, `err(code,msg)`. (Talk client `talk_api.dart` already unwraps `{data:[...]}`.)
- **Rate limiter:** `src/lib/rate-limit.ts` `checkRateLimit(key,cfg)` + `rateLimitPresets` + `getClientIp()`. **No Talk route uses it yet** — this endpoint is the first.
- **Phone normalize:** `src/lib/phone-normalize.ts` `normalizePkPhone(raw)` (permissive, handles 03…/3…/92…/+92…/+CC…; returns null if unmatched) — use this.
- **Peppered SHA-256 template:** `src/lib/otp-code-crypto.ts` `hashPhoneOtp()` (`createHash("sha256")` + `AUTH_SECRET` pepper, `timingSafeEqual`).
- **Route template:** `src/app/api/v1/talk/contacts/route.ts` (`runtime="nodejs"`, `dynamic="force-dynamic"`, `requireSession()`, `ok(rows)`).
- **CRM read pattern:** FleetOps `scripts/sync-from-crm.ts` + `src/lib/crm-cache.ts` (`CrmCache`, stale-while-revalidate, 3s timeout, disk cache). CRM endpoint: `GET https://app.interactpak.com/api/crm/shared?key=<INTERACT_CRM_KEY>&…` → `{data:CrmContact[],pagination,source}`. `CrmContact` has `fullName, urduName, organization, jobTitle, phone1..phone4, city, tags`, etc. **qurbanisahulat has no CRM caller today — build new**, porting `CrmCache` for resilience.

## Design

### Endpoint
`POST /api/v1/talk/contacts/resolve` (new), `runtime="nodejs"`, `dynamic="force-dynamic"`.

Request body:
```json
{ "hashes": ["<sha256hex>", "..."], "algo": "sha256-e164-pepper-v1" }
```
- Client normalizes each candidate number to E.164, then `sha256(pepper + e164)` and sends only hashes (cap ~200/request). `algo` version lets the pepper/scheme rotate.

Response (`ok()` envelope):
```json
{ "success": true, "data": { "matches": [
  { "hash": "<sha256hex>", "name": "Ahmed Raza", "urduName": "احمد رضا",
    "org": "…", "title": "…", "source": "crm" }
] }, "meta": {}, "error": null }
```
- Only hashes with a match are returned (unmatched omitted). No raw phone echoed back.

### Backend flow
1. `requireSession()` — reject unauthenticated. Capture `gate.userId`, `gate.roles`.
2. `checkRateLimit("crm-resolve:"+gate.userId, {limit:20, windowMs:60_000})` (or a new preset) — fail closed on this route (it touches CRM), and also cap total hashes/request.
3. **Pepper + scheme:** server holds the same pepper the client uses (shipped via `--dart-define` to the client, held in `AUTH_SECRET`-derived pepper on server). Reject unknown `algo`.
4. Pull CRM via the ported `CrmCache` (server-side, key `INTERACT_CRM_KEY` never leaves the VPS). For each CRM contact, compute the same `sha256(pepper+e164)` over its `phone1..phone4` (normalized with `normalizePkPhone`) → build a `hash→contact` index (cached, refreshed on the SWR interval).
5. Intersect request hashes with the index. **Role-scope** the result: e.g. field roles only see contacts tagged to their territory/assignment; admins see all. Start conservative — return name/org/title only, never full CRM rows, addresses, or extra phones.
6. Return matches. Log count + userId for the audit trail (no numbers).

### Client (interact-app)
- New `resolveCrmNames(List<String> e164)` in `talk_api.dart`: normalize → hash locally (Dart `crypto` sha256 + shared pepper from `--dart-define`) → POST → cache `hash→name` in a small local store (TTL). Bearer via existing `_headers()`.
- Name resolution order becomes: device contact name → **CRM resolve** → backend display name → phone → generic → Unknown (extends `lib/utils/display_name.dart` `resolveDisplayName`).
- **"Suggest to CRM"** affordance for unmatched numbers the user labels — queued, admin-reviewed (do not auto-write CRM).

## Guardrails
- No CRM key, pepper-as-secret only, on the client; the pepper obscures numbers in transit but is **not** a strong secret — the real protection is JWT + rate limit + role-scope + returning only names.
- No bulk enumeration: rate-limited, per-request hash cap, per-user audit; CRM index lives server-side only.
- `/api/crm/shared` is currently unquota'd upstream — the SWR cache + this route's own limiter prevent hammering it.
- Privacy note in-app: "Names may be matched from your INTERACT CRM."

## v2 hardening (2026-07-31)

Post-launch review pass. The Phase 3 feature was already live (build ≤6040 clients use v1). These are the ACCEPTED tightenings and the explicitly DEFERRED items.

### Accepted (implemented this pass)
1. **HMAC instead of plain SHA-256, dual-algo.** New algo `hmac-sha256-pepper-v1` (v2) = `HMAC-SHA256(key=pepper, msg=e164)` → lowercase hex, alongside the retained v1 `sha256-e164-pepper-v1` = `sha256(pepper + e164)`. The route accepts BOTH (live 6040 clients keep working); the index is built lazily per algo from one shared CRM fetch and cached. Rationale: HMAC is the correct keyed-hash construction; dual-algo = zero-downtime rollout. **No user-specific salt** — it would break the shared precomputed index.
2. **Hash cap 200 → 50 per request** (`TOO_MANY_HASHES`), client chunk size matched to 50. Rationale: smaller enumeration surface per call; the per-user/IP limits already bound total volume.
3. **IP rate-limit as a second layer.** `crm-resolve-ip:<ip>` at 100/min in addition to the existing `crm-resolve:<userId>` at 20/min; both fail CLOSED. Rationale: caps a shared egress / token-rotating scripted client that a per-user limit alone misses.
4. **Explicit field whitelist.** `ALLOWED = ['name','urduName','org','title']`; each returned match is projected onto ONLY those keys, so a future CRM field can never leak. Never returns address/phone/email/tags/full rows.
5. **Role-scope seam.** Single `scopeMatch(gate, contact)` function — admins → all; non-admins → same as today (name/org/title/urduName for any matched hash) with a `TODO(role-scope)` to tighten per tag/territory once the role→tag map is confirmed with the operator. Rationale: the tightening is one function away without inventing rules now.
6. **Explicit error codes** via `err(code,msg)`: `UNKNOWN_ALGO`, `TOO_MANY_HASHES`, `RATE_LIMITED`, `INVALID_HASH` (non-hex / ≠64 chars), `INVALID_BODY`.
7. **Cache freshness.** The CRM payload's `lastUpdated`/`updatedAt` (else fetch timestamp) is captured into the SWR index identity, so a CRM content change is reflected on the next refresh; the 15-min fresh / 24-h stale-while-revalidate cadence is unchanged.
8. **Client default → v2.** `talk_api.dart resolveCrmNames` now hashes with `Hmac(sha256, utf8(pepper)).convert(utf8(e164))`, chunks at ≤50, keeps fail-soft (empty map on 4xx/error), and documents both algo constants.

### Deferred (with rationale)
- **User-specific salt** — would break the shared precomputed hash index (every user would need their own index). Not worth it for a transit-obscuring pepper.
- **CRM push webhook to invalidate on write** — SWR already bounds staleness to ≤15 min; a webhook is an optimization, not a correctness fix.
- **Client-cache HMAC signing / encryption at rest** — the cache is in-memory only and holds names (not numbers); low value now.
- **`fields` request param** (client asks for a subset) — the server already returns a fixed minimal whitelist; no caller needs less.
- **"Suggest to CRM" feedback loop** — the local stub stays local; an admin-reviewed suggestion endpoint is out of scope until the review flow is designed. Never auto-writes the CRM.

### Test list (negative / role / perf)
- **Algo:** v1 hash resolves; v2 hash resolves; unknown algo → 400 `UNKNOWN_ALGO`; missing/empty algo → 400 `UNKNOWN_ALGO`.
- **Hash validation:** 64-char lowercase hex passes; uppercase / 63 / 65 chars / non-hex → 400 `INVALID_HASH`; non-array `hashes` → 400 `INVALID_BODY`; malformed JSON → 400 `INVALID_BODY`.
- **Caps:** 50 hashes OK; 51 → 400 `TOO_MANY_HASHES`.
- **Rate limits:** >20 req/min per user → 429 `RATE_LIMITED`; >100 req/min per IP → 429 `RATE_LIMITED`; limiter throwing → 429 (fail-closed).
- **Whitelist:** response contains only `hash,name,urduName,org,title,source`; never address/phone/email/tags.
- **Role scope:** admin sees matches; non-admin sees the same conservative set today (seam verified — flip point is `scopeMatch`).
- **Perf:** cold index build under load; SWR serves stale during background refresh; empty index (pepper unset / CRM down) → 200 with `matches:[]` (fail-soft, never 5xx).
- **Cross-impl parity:** a Dart v2 hash of a known number equals the Node `createHmac('sha256',pepper).update(e164).digest('hex')` byte-for-byte.

## Deliverables when built
1. `resolve` route (auth + rate limit + normalize + hash-index + role-scope + `ok()` envelope).
2. Ported `CrmCache` in qurbanisahulat (server-side, `INTERACT_CRM_KEY` in `/srv/qurbanisahulat/.env`).
3. Client `resolveCrmNames()` + local cache + `resolveDisplayName` wiring + "Suggest to CRM".
4. Shared pepper provisioned (client `--dart-define`, server env); `algo` versioned.
5. Fat rebuild + on-device test: a known-CRM number resolves to a name; an unknown one falls back to device/phone; rate limit + role-scope verified.
