// SPDX-License-Identifier: AGPL-3.0
//
// Cloud-side AI — proxies through interactpak.com's /api/zeka/assist
// endpoint. The API key for DeepSeek (or whichever upstream the proxy
// talks to) lives ONLY on the server; INTERACT never ships keys in the
// APK.
//
// FIX 2026-06-10 (REUSE_DEDUPE_AUDIT 2026-06-01 §6.1): this used to POST
// {tier,prompt} to /api/zeka/ai and read {text}/{response}. But that
// endpoint is a scoped maths solver: body {question} → {ok,answer,steps},
// "= UNSUPPORTED" for everything else — so Summarise / Suggest-reply /
// Translate silently returned empty strings. Now targets the
// general-purpose /api/zeka/assist ({prompt,...} → {ok,text,provider,
// model}) added the same day in interactpak-nextjs.
//
// This is the DEFAULT chat tier per the hybrid PRD. On-device kicks
// in only when Settings → Privacy → "Private AI" is on, or the
// context is federation (cross-org E2E), or the device is offline.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'auth_service.dart';

const _kBase = 'https://www.interactpak.com';
const _kPath = '/api/zeka/assist'; // general AI proxy (NOT /api/zeka/ai — that's the maths solver)

final aiCloudServiceProvider = Provider<AiCloudService>((ref) {
  return AiCloudService(ref.read(authServiceProvider));
});

class AiCloudService implements AiService {
  AiCloudService(this._auth);
  final AuthService _auth;

  @override
  Future<AiResponse> complete(AiRequest req) async {
    final t = await _auth.token();
    final start = DateTime.now();

    final body = <String, dynamic>{
      'prompt': req.prompt,
      if (req.systemPrompt != null) 'systemPrompt': req.systemPrompt,
      'maxTokens': req.maxTokens,
      'temperature': req.temperature,
      // Hint to the proxy on which upstream model to prefer. The
      // proxy can override based on its own load-balancing / cost
      // policy; we just suggest.
      'modelHint': _modelHintForTier(req.tier),
    };

    final res = await http.post(
      Uri.parse('$_kBase$_kPath'),
      headers: {
        'Content-Type': 'application/json',
        if (t != null) 'Authorization': 'Bearer $t',
      },
      body: jsonEncode(body),
    );

    if (res.statusCode >= 400) {
      throw Exception('AI cloud call failed: ${res.statusCode} ${res.body}');
    }

    final latencyMs = DateTime.now().difference(start).inMilliseconds;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    // /api/zeka/assist contract: {ok, text, provider, model} on success,
    // {ok:false, error} on failure. Surface failures loudly instead of
    // the old silent-empty-string behaviour.
    if (j['ok'] != true) {
      throw Exception('AI cloud call failed: ${j['error'] ?? 'unknown error'}');
    }
    return AiResponse(
      text: (j['text'] as String?) ?? '',
      modelUsed: (j['model'] as String?) ?? (j['provider'] as String?) ?? 'cloud:unknown',
      tierUsed: req.tier,
      networkUsed: true,
      latencyMs: latencyMs,
      inputTokens: (j['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (j['outputTokens'] as num?)?.toInt() ?? 0,
    );
  }

  String _modelHintForTier(AiTier tier) {
    switch (tier) {
      case AiTier.voice:
        return 'fast'; // proxy picks the fastest cloud model
      case AiTier.chat:
        return 'balanced';
      case AiTier.audit:
        return 'long-context';
    }
  }

  @override
  Future<OnDeviceCapability> onDeviceCapability() async {
    // Cloud service doesn't know about on-device — return empty.
    return OnDeviceCapability(
      deviceRamMb: 0,
      canRunVoice: false,
      canRunChat3B: false,
      canRunChat7B: false,
      downloadedModels: const <String>{},
    );
  }
}
