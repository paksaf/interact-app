// SPDX-License-Identifier: AGPL-3.0
//
// On-device AI — Phase 3 implementation hook. This file ships TONIGHT
// as a contract-honouring stub so:
//   1. The router compiles + works (it tries on-device, falls back to
//      cloud when on-device throws AiOnDeviceNotReady).
//   2. The "Private AI" toggle in Settings has a real `OnDeviceCapability`
//      to read from (returns canRun* = false until Phase 3 wires llama.cpp).
//   3. The audit-log layer already records `networkUsed: false` for the
//      throw path, so we don't accidentally count on-device-failures
//      as cloud calls.
//
// Phase 3 build session swaps the stub for llama_cpp_dart FFI bindings
// against Phi-3.5-mini Q4 (voice tier) and Qwen2.5 7B / 3B Q4 (chat
// tier). See MODELS.md for the picks + rationale.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_service.dart';

/// Thrown when the on-device tier can't fulfill a request — used by the
/// router as the cue to fall back to cloud (or to surface "Download
/// the model" UI if the user opted into Private AI).
class AiOnDeviceNotReady implements Exception {
  AiOnDeviceNotReady(this.reason);
  final String reason;
  @override
  String toString() => 'AiOnDeviceNotReady: $reason';
}

final aiOnDeviceServiceProvider = Provider<AiOnDeviceService>((_) {
  return AiOnDeviceService();
});

class AiOnDeviceService implements AiService {
  @override
  Future<AiResponse> complete(AiRequest req) async {
    // Phase 3 — replace this with llama_cpp_dart inference.
    // Model selection: tier=voice → Phi-3.5-mini Q4, tier=chat → Qwen
    // (3B or 7B based on OnDeviceCapability), tier=audit → server.
    throw AiOnDeviceNotReady(
      'Phase 3 build session pending — llama_cpp_dart FFI binding + '
      'lazy-download from models.interactpak.com. See MODELS.md.',
    );
  }

  @override
  Future<OnDeviceCapability> onDeviceCapability() async {
    // Phase 3 — use `device_info_plus` to read total RAM, check
    // `path_provider`'s app-support dir for downloaded GGUF files,
    // then return the right caps.
    //
    // For now: report nothing's available so the router always falls
    // through to cloud. The Settings UI shows "Private AI requires a
    // future model download" until the Phase 3 binding lands.
    return OnDeviceCapability(
      deviceRamMb: 0,
      canRunVoice: false,
      canRunChat3B: false,
      canRunChat7B: false,
      downloadedModels: const <String>{},
    );
  }
}
