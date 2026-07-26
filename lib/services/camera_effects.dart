// SPDX-License-Identifier: AGPL-3.0
//
// CameraEffects — the shared state for INTERACT Talk's Zoom/Meet-style camera
// backgrounds. A single source of truth (Riverpod) for the user's chosen
// effect so the pre-call effects picker and the in-call self-view agree.
//
// Honest scope (2026-07-26):
//   • Self-view / picker: ML Kit selfie segmentation composites blur/brand BG
//     in camera_effects_screen.dart (FPS-throttled).
//   • LiveKit publish: Flutter SDK still lacks web-style TrackProcessors, so
//     peers receive the raw camera track. Townhall control bar → BG opens the
//     picker and keeps [cameraEffectProvider] as the single source of truth;
//     when a native VideoProcessor lands, publish through this same enum.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The available background treatments. [asset] is null for none/blur (blur is
/// computed, not an image); the *Bg entries reference bundled brand art.
enum CameraEffect {
  none('None', null),
  blur('Blur', null),
  officeBg('Office', 'assets/backgrounds/bg_office.png'),
  brandBg('INTERACT', 'assets/backgrounds/bg_brand.png'),
  warmBg('Warm', 'assets/backgrounds/bg_warm.png');

  const CameraEffect(this.label, this.asset);
  final String label;
  final String? asset;

  bool get isImage => asset != null;
  /// True when the user wants a non-passthrough background (preview + future publish).
  bool get wantsVirtualBg => this != CameraEffect.none;
}

class CameraEffectsController extends Notifier<CameraEffect> {
  @override
  CameraEffect build() => CameraEffect.none;

  void select(CameraEffect e) => state = e;
  void clear() => state = CameraEffect.none;
}

final cameraEffectProvider =
    NotifierProvider<CameraEffectsController, CameraEffect>(
        CameraEffectsController.new);
