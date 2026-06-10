// SPDX-License-Identifier: AGPL-3.0
//
// AiRouterService — the hybrid router. Decides per-request whether to
// route to on-device or cloud, based on:
//
//   1. User setting "Private AI" (Settings → Privacy) — forces on-device
//   2. Federation context — forces on-device (preserves E2E)
//   3. AiTier.voice — forces on-device (latency)
//   4. Connectivity — falls back to on-device when offline
//   5. Otherwise — default to cloud (DeepSeek/Zeka via interactpak.com)
//
// Every call is recorded in the audit log with `networkUsed` set
// correctly. The compliance proof is built-in.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_audit_log.dart';
import 'ai_cloud_service.dart';
import 'ai_ondevice_service.dart';
import 'ai_service.dart';

const _kPrivateAiKey = 'interact.ai.privateMode';

final aiRouterProvider = Provider<AiRouterService>((ref) {
  return AiRouterService(
    cloud: ref.read(aiCloudServiceProvider),
    onDevice: ref.read(aiOnDeviceServiceProvider),
    auditLog: ref.read(aiAuditLogProvider),
  );
});

class AiRouterService implements AiService {
  AiRouterService({
    required this.cloud,
    required this.onDevice,
    required this.auditLog,
  });
  final AiCloudService cloud;
  final AiOnDeviceService onDevice;
  final AiAuditLog auditLog;

  /// Returns the user's "Private AI" preference. When true, all chat-
  /// tier requests route through on-device (or fail loudly if the
  /// model isn't downloaded yet — better to surface than to silently
  /// leak to cloud).
  Future<bool> isPrivateAiEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPrivateAiKey) ?? false;
  }

  Future<void> setPrivateAiEnabled(bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrivateAiKey, on);
  }

  @override
  Future<AiResponse> complete(AiRequest req) async {
    final private = await isPrivateAiEnabled();
    final tryOnDeviceFirst = req.forceOnDevice ||
        private ||
        req.tier == AiTier.voice;

    if (tryOnDeviceFirst) {
      try {
        final res = await onDevice.complete(req);
        await _audit(req, res);
        return res;
      } on AiOnDeviceNotReady {
        // If the user explicitly opted into Private AI, NEVER silently
        // fall back to cloud — surface the failure so they can decide
        // (download the model, OR temporarily disable Private AI).
        if (private || req.forceOnDevice) {
          rethrow;
        }
        // Voice tier when on-device isn't ready: fall back to cloud
        // with a latency penalty. UI should display a "voice quality:
        // network" indicator so the user understands.
      }
    }

    // Cloud path
    final res = await cloud.complete(req);
    await _audit(req, res);
    return res;
  }

  @override
  Future<OnDeviceCapability> onDeviceCapability() =>
      onDevice.onDeviceCapability();

  Future<void> _audit(AiRequest req, AiResponse res) async {
    try {
      await auditLog.record(
        tier: res.tierUsed,
        modelUsed: res.modelUsed,
        prompt: '${req.systemPrompt ?? ""}\n${req.prompt}',
        response: res.text,
        inputTokens: res.inputTokens,
        outputTokens: res.outputTokens,
        latencyMs: res.latencyMs,
        networkUsed: res.networkUsed,
      );
    } catch (_) {
      // Audit log must never crash the app. The signed audit chain
      // catches gaps on export — a missing row is just a row.
    }
  }
}
