// SPDX-License-Identifier: AGPL-3.0
//
// Platform bridge for peer-visible virtual backgrounds.
// Android attaches an ExternalVideoFrameProcessing compositor to the LiveKit
// camera LocalVideoTrack (via FlutterWebRTCPlugin.getLocalTrack). iOS/web are
// stubs for now — preview still works via camera_effects_screen.dart.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'camera_effects.dart';

class VirtualBgNative {
  VirtualBgNative._();

  static const _ch = MethodChannel('interact/virtual_bg');

  /// True when this platform can composite into the published WebRTC track.
  static bool get supportsPeerPublish =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> attach({
    required String trackId,
    required CameraEffect effect,
  }) async {
    if (!supportsPeerPublish) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('attach', {
        'trackId': trackId,
        'mode': _mode(effect),
        'asset': effect.asset,
      });
      return ok == true;
    } on PlatformException catch (e) {
      debugPrint('VirtualBgNative.attach failed: $e');
      return false;
    }
  }

  static Future<void> update(CameraEffect effect) async {
    if (!supportsPeerPublish) return;
    try {
      await _ch.invokeMethod<void>('update', {
        'mode': _mode(effect),
        'asset': effect.asset,
      });
    } on PlatformException catch (e) {
      debugPrint('VirtualBgNative.update failed: $e');
    }
  }

  static Future<void> detach() async {
    if (!supportsPeerPublish) return;
    try {
      await _ch.invokeMethod<void>('detach');
    } on PlatformException catch (e) {
      debugPrint('VirtualBgNative.detach failed: $e');
    }
  }

  static String _mode(CameraEffect e) => switch (e) {
        CameraEffect.none => 'none',
        CameraEffect.blur => 'blur',
        CameraEffect.officeBg ||
        CameraEffect.brandBg ||
        CameraEffect.warmBg =>
          'image',
      };
}
