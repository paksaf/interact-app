# INTERACT — AI Model Decisions

**Decided:** 2026-05-21 · **Author:** INTERACT team

Three-tier on-device AI strategy for INTERACT. License-clean (no
Llama / Gemma / Stable LM restrictive terms), Urdu-aware, sized for
the Pakistan device floor (2 GB RAM Android).

## Hybrid architecture — why on-device matters even with DeepSeek

The default chat tier hits DeepSeek API. That's fast and cheap. But four
cases break the API-only model:

1. **Compliance / regulated orgs** — healthcare, finance, legal:
   prompts cannot leave the device. On-device is the only legal path.
2. **Voice latency** — full-duplex conversation needs <300 ms roundtrip.
   DeepSeek + network = 600-1200 ms. On-device Phi-3.5-mini = 50-150 ms.
3. **Offline / failover** — VPS down, DeepSeek down, ISP outage. On-device
   keeps voice + chat working.
4. **Federation** — INTERACT-to-INTERACT cross-org messaging stays
   E2E-encrypted only if the model runs inside the encryption boundary,
   i.e. on-device. Sending to a third-party API breaks E2E.

Net: **default → DeepSeek API, opt-in tier → on-device, voice → on-device required.**

## The three picks

### Tier 1 — Voice (latency-critical, on-device REQUIRED)

| Component | Model | License | Size (4-bit) | Why |
|---|---|---|---:|---|
| LLM | **Phi-3.5-mini 3.8B Q4** | MIT | ~1.8 GB | Best quality-per-size in the 3-4B class. Microsoft tested it on Snapdragon Hexagon DSP. 50-150 ms/token on Snapdragon 450. |
| STT | **whisper.cpp tiny-ur INT8** | MIT | ~35 MB | Already in `sahulat_common`. WER ~15% on Pakistani Urdu (Common Voice). |
| TTS | **XTTS-v2 Urdu Q8** | MPL-2.0 | ~120 MB | Pre-trained Urdu fine-tune (`suhaibrashid17`). Quantized 8-bit = 600 ms latency on 2 GB RAM. |
| Wake-phrase | **Porcupine** (non-commercial free) or **OpenWakeWord** (Apache 2.0) | mixed | ~5 MB | "Bolo INTERACT" wake-phrase. Use OpenWakeWord for clean commercial path. |

**Total on-disk after lazy-load:** ~2 GB. Phi + Whisper + XTTS, all
gated behind a "Download voice assistant (1.8 GB)" toggle in Settings
the first time the user invokes voice.

### Tier 2 — Chat AI assistant (Urdu quality, on-device for compliance tier)

| Model | License | Size (4-bit) | Why |
|---|---|---|---:|
| **Qwen2.5 7B Q4** | Apache 2.0 | ~4 GB | The killer choice. Alibaba trained Qwen on heavy multilingual data; **Urdu is natively well-represented** unlike most Western models. 128K context for long-thread context. |
| **Qwen2.5 3B Q4** | Apache 2.0 | ~1.8 GB | Fallback for 2-3 GB RAM devices. Same Urdu quality, less context. |

Used for: thread summarization, translate Urdu↔English↔Punjabi,
suggested replies, AI-drafted responses, "explain this voice
message" expand-and-clarify.

**Routing logic:**

```dart
// pseudocode
if (settings.privateAiEnabled || isFederationContext || offline) {
  return onDeviceAi.complete(prompt);   // Qwen2.5 7B or 3B
}
return deepseekApi.complete(prompt);     // default path
```

### Tier 3 — Server-side (Mac dev stack now, VPS later)

| Model | License | Size (4-bit) | Why |
|---|---|---|---:|
| **Granite-4.0-Tiny 7B MoE** | Apache 2.0 | ~3.5 GB (MoE — only 2 GB active) | IBM hybrid MoE, 128K context. Runs in the `ai-server` Docker container in `interact-backend/docker-compose.yml`. |

Used for: enterprise audit layer (scan an org's chat history against
configurable rules), server-side full-text search assistant,
long-document summarization (>32K tokens where Tier 2 wraps).

## License compatibility with INTERACT (AGPLv3)

INTERACT is AGPLv3. Models bundled or downloaded by INTERACT must be
AGPLv3-compatible or distributed under permissive terms.

- **MIT (Phi, Whisper)** — compatible. INTERACT redistributes them
  under AGPLv3 in the combined work, but per MIT they can also be
  pulled separately under MIT for other uses.
- **Apache 2.0 (Qwen, Granite, OpenWakeWord)** — compatible.
- **MPL-2.0 (XTTS-v2)** — compatible. File-level copyleft only,
  doesn't infect AGPLv3.
- **Llama Community / Gemma Terms / Stable LM License** — NOT used.
  Their acceptable-use policies and clauses like "must not use to
  improve other LLMs" conflict with AGPLv3's "no further restrictions"
  rule. Hard rejection.

## Audit-log layer (for the compliance tier)

Every on-device inference call writes a Drift row:

```sql
CREATE TABLE ai_audit_log (
  id              TEXT PRIMARY KEY,
  ts              INTEGER NOT NULL,          -- unix ms
  tier            TEXT NOT NULL,             -- 'voice' | 'chat' | 'server'
  model_name      TEXT NOT NULL,             -- 'phi-3.5-mini-q4' | 'qwen2.5-7b-q4' | ...
  prompt_hash     TEXT NOT NULL,             -- SHA-256 of redacted prompt
  response_hash   TEXT NOT NULL,             -- SHA-256 of response
  input_tokens    INTEGER,
  output_tokens   INTEGER,
  latency_ms      INTEGER,
  network_used    INTEGER NOT NULL DEFAULT 0  -- 0 = pure on-device, 1 = network round-trip
);
```

In Settings → Privacy → "Export audit log":

```json
{
  "exportedAt": "2026-05-21T10:30:00Z",
  "deviceId": "<opaque>",
  "userId": "<opaque>",
  "totalInferences": 1234,
  "byTier": { "voice": 987, "chat": 200, "server": 47 },
  "byModel": { "phi-3.5-mini-q4": 987, "qwen2.5-7b-q4": 200, "granite-4-tiny-q4": 47 },
  "networkCalls": 0,
  "entries": [
    { "ts": 1716290000000, "tier": "voice", "model": "phi-3.5-mini-q4",
      "promptHash": "a3f8...", "responseHash": "9c1e...",
      "inputTokens": 23, "outputTokens": 41, "latencyMs": 120, "networkUsed": 0 },
    ...
  ]
}
```

Compliance reviewer can verify:
- `networkUsed = 0` for every entry → no data left the device
- Hash chain matches the user's claim about what they asked
- Latency distribution matches on-device performance profile (catches
  bad-faith claims of "I never sent it to OpenAI" when timestamps say
  otherwise)

This is the proof-of-on-device-only layer that healthcare / finance /
legal need.

## Model distribution

Models are NOT bundled with the APK. Lazy-downloaded from
`models.interactpak.com` (a sub-path on the Hetzner VPS, AGPLv3'd
binaries with SHA-256 manifest). User sees:

```
[Voice assistant requires ~1.8 GB download]
Phi-3.5-mini (1.8 GB)   ⓘ MIT — Microsoft
whisper-tiny-ur (35 MB) ⓘ MIT — OpenAI
XTTS-v2-ur (120 MB)     ⓘ MPL-2.0 — Coqui
                      [ Download all ]
```

Wi-Fi-only by default. Resume on flake. SHA verification on save.

## Implementation order

1. **Phase 1.5** (immediate next session)
   - Verify Whisper tiny-ur loads via existing `sahulat_common`
     `whisper_flutter_new` binding on the A23. Latency must be <800 ms
     for a 5-second clip. If yes, on-device STT for voice messages.
     If no, fall back to the Tier 3 server.

2. **Phase 2** (next sprint)
   - Pull `llama_cpp_dart` (Dart FFI for llama.cpp) into pubspec.
   - Lazy-download Phi-3.5-mini Q4 GGUF on first voice-assistant use.
   - Wire wake-phrase via OpenWakeWord (Apache 2.0).
   - Audit log Drift table + Settings → Privacy export.

3. **Phase 3** (later sprint)
   - Lazy-download Qwen2.5 3B Q4 (smaller default) + 7B Q4 (compliance tier).
   - DeepSeek API path remains default; "Private AI" toggle routes through
     on-device.
   - Granite 4.0 Tiny runs in `interact-backend/docker-compose.yml` under
     the `--profile ai` profile.

## What if the user is on a 2 GB RAM phone and turns on Private AI?

Graceful degrade. Settings → Privacy shows three "Private AI" states:

| User device RAM | On-device tier available | UX |
|---|---|---|
| 8 GB+ | Qwen2.5 7B Q4 — full quality | "Private AI is ON. Full quality." |
| 4-6 GB | Qwen2.5 3B Q4 — smaller, still good | "Private AI is ON. Optimised for your device." |
| 2-3 GB | Phi-3.5-mini Q4 — voice-only quality | "Private AI is ON. Lighter assistant. For complex tasks, you may need DeepSeek." |
| < 2 GB | Disabled | "Your device can't run Private AI. Default chat AI uses DeepSeek (network)." |

Device-RAM detection at first launch; lazy-download the right tier.

## References

- Phi-3.5-mini — Microsoft AI Research, MIT, https://huggingface.co/microsoft/Phi-3.5-mini-instruct
- Qwen2.5 — Alibaba, Apache 2.0, https://huggingface.co/Qwen/Qwen2.5-7B-Instruct
- Granite 4.0 Tiny — IBM, Apache 2.0, https://huggingface.co/ibm-granite
- llama.cpp Dart FFI — https://github.com/Maton/llama_cpp_dart
- OpenWakeWord — Apache 2.0, https://github.com/dscripka/openWakeWord
- whisper.cpp — MIT, https://github.com/ggerganov/whisper.cpp
- XTTS-v2 Urdu fine-tune — MPL-2.0, `suhaibrashid17/XTTS-v2-Urdu-FT`
