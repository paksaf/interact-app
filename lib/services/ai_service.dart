// SPDX-License-Identifier: AGPL-3.0
//
// AI service — hybrid routing layer. Default tier hits DeepSeek API;
// on-device tier kicks in for compliance / federation / voice / offline.
// See MODELS.md for the three-tier model picks (Phi-3.5-mini, Qwen2.5,
// Granite 4.0 Tiny).
//
// Phase 3 implementation — this file is the contract; the on-device
// llama.cpp FFI binding lives in lib/services/ai_ondevice_service.dart
// (next session) and the DeepSeek client in lib/services/ai_cloud_service.dart.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hint to the router. Doesn't strictly force a tier — the router can
/// downgrade to on-device when network unavailable or the user has
/// "Private AI" toggled in Settings.
enum AiTier {
  /// Voice — latency-critical, on-device REQUIRED (Phi-3.5-mini Q4).
  voice,
  /// Chat assistant — default DeepSeek, on-device when private (Qwen2.5).
  chat,
  /// Audit / long-document — server-side Granite 4.0 Tiny.
  audit,
}

/// One inference, capped at maxTokens. The router decides which model
/// + which backend (on-device vs cloud) based on the tier + user
/// settings + network availability + device RAM.
class AiRequest {
  AiRequest({
    required this.tier,
    required this.prompt,
    this.systemPrompt,
    this.maxTokens = 512,
    this.temperature = 0.7,
    this.forceOnDevice = false,
  });

  final AiTier tier;
  final String prompt;
  final String? systemPrompt;
  final int maxTokens;
  final double temperature;

  /// Override the router. Used by federation paths where on-device is
  /// mandatory to preserve E2E (sending to DeepSeek would break E2E).
  final bool forceOnDevice;
}

class AiResponse {
  AiResponse({
    required this.text,
    required this.modelUsed,
    required this.tierUsed,
    required this.networkUsed,
    required this.latencyMs,
    required this.inputTokens,
    required this.outputTokens,
  });

  final String text;
  /// e.g. 'qwen2.5-7b-q4', 'phi-3.5-mini-q4', 'deepseek-chat'
  final String modelUsed;
  final AiTier tierUsed;
  /// True if the call left the device. Used by the audit layer to
  /// prove "on-device only" for compliance.
  final bool networkUsed;
  final int latencyMs;
  final int inputTokens;
  final int outputTokens;
}

abstract class AiService {
  Future<AiResponse> complete(AiRequest req);

  /// Returns the on-device model tier available based on this device's
  /// RAM and downloaded models. Caller uses this for the Settings →
  /// Privacy "what's available" indicator.
  Future<OnDeviceCapability> onDeviceCapability();
}

class OnDeviceCapability {
  OnDeviceCapability({
    required this.deviceRamMb,
    required this.canRunVoice,
    required this.canRunChat3B,
    required this.canRunChat7B,
    required this.downloadedModels,
  });
  final int deviceRamMb;
  final bool canRunVoice;     // Phi-3.5-mini Q4 fits
  final bool canRunChat3B;    // Qwen2.5 3B Q4 fits
  final bool canRunChat7B;    // Qwen2.5 7B Q4 fits
  final Set<String> downloadedModels;
}

/// Default-stub provider — wires up in Phase 3 to concrete on-device
/// + cloud implementations. For now, returns a NotImplementedError.
final aiServiceProvider = Provider<AiService>((_) => _StubAiService());

class _StubAiService implements AiService {
  @override
  Future<AiResponse> complete(AiRequest req) async {
    throw UnimplementedError(
      'AI tier not wired yet — Phase 3 implementation in '
      'lib/services/ai_ondevice_service.dart and ai_cloud_service.dart. '
      'See MODELS.md for the routing matrix.',
    );
  }

  @override
  Future<OnDeviceCapability> onDeviceCapability() async {
    return OnDeviceCapability(
      deviceRamMb: 0,
      canRunVoice: false,
      canRunChat3B: false,
      canRunChat7B: false,
      downloadedModels: <String>{},
    );
  }
}
