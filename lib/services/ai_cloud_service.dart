// SPDX-License-Identifier: AGPL-3.0
//
// Cloud-side AI — proxies through the Talk API host's /api/zeka/assist
// endpoint (qurbanisahulat.com / talk.interactpak.com via ApiBase failover).
// API keys live ONLY on the server.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'ai_service.dart';
import 'api_base.dart';
import 'auth_service.dart';

const _kPath = '/api/zeka/assist';

final aiCloudServiceProvider = Provider<AiCloudService>((ref) {
  return AiCloudService(ref.read(authServiceProvider));
});

class AiCloudService implements AiService {
  AiCloudService(this._auth);
  final AuthService _auth;

  @override
  Future<AiResponse> complete(AiRequest req) async {
    return ApiBase.runWithFailover(() => _completeOnce(req));
  }

  Future<AiResponse> _completeOnce(AiRequest req) async {
    final t = await _auth.token();
    final start = DateTime.now();
    final base = ApiBase.current;

    final body = <String, dynamic>{
      'prompt': req.prompt,
      if (req.systemPrompt != null) 'systemPrompt': req.systemPrompt,
      'maxTokens': req.maxTokens,
      'temperature': req.temperature,
      'modelHint': _modelHintForTier(req.tier),
    };

    final res = await http.post(
      Uri.parse('$base$_kPath'),
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
        return 'fast';
      case AiTier.chat:
        return 'balanced';
      case AiTier.audit:
        return 'long-context';
    }
  }

  @override
  Future<OnDeviceCapability> onDeviceCapability() async {
    return OnDeviceCapability(
      deviceRamMb: 0,
      canRunVoice: false,
      canRunChat3B: false,
      canRunChat7B: false,
      downloadedModels: const <String>{},
    );
  }
}
