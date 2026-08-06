// SPDX-License-Identifier: AGPL-3.0
//
// LiveKit [TrackProcessor] for INTERACT Talk virtual backgrounds.
//
// On Android, [init] attaches a native ExternalVideoFrameProcessing compositor
// to the same MediaStreamTrack (in-place). Peers therefore receive the
// composited frames without a separate processedTrack. On other platforms the
// processor is a no-op hook so setProcessor() still succeeds after livekit
// 2.6.5+ VideoProcessorOptions wiring.

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:livekit_client/livekit_client.dart';

import 'camera_effects.dart';
import 'virtual_bg_native.dart';

class VirtualBgTrackProcessor
    implements TrackProcessor<VideoProcessorOptions> {
  VirtualBgTrackProcessor(this.effect);

  CameraEffect effect;
  String? _trackId;
  bool _attached = false;

  @override
  String get name => 'interact-virtual-bg';

  /// In-place native pipeline — no replacement track.
  @override
  MediaStreamTrack? get processedTrack => null;

  @override
  Future<void> init(VideoProcessorOptions options) async {
    _trackId = options.track.id;
    if (_trackId == null || _trackId!.isEmpty) {
      debugPrint('VirtualBgTrackProcessor: missing track id');
      return;
    }
    if (effect == CameraEffect.none) return;
    _attached = await VirtualBgNative.attach(
      trackId: _trackId!,
      effect: effect,
    );
    if (!_attached && VirtualBgNative.supportsPeerPublish) {
      debugPrint(
        'VirtualBgTrackProcessor: native attach failed for $_trackId',
      );
    }
  }

  @override
  Future<void> restart(VideoProcessorOptions options) async {
    await destroy();
    await init(options);
  }

  @override
  Future<void> destroy() async {
    if (_attached) {
      await VirtualBgNative.detach();
      _attached = false;
    }
    _trackId = null;
  }

  @override
  Future<void> onPublish(Room room) async {}

  @override
  Future<void> onUnpublish() async {}

  /// Hot-swap blur / image / none without recreating the LiveKit processor.
  Future<void> updateEffect(CameraEffect next) async {
    effect = next;
    if (next == CameraEffect.none) {
      if (_attached) {
        await VirtualBgNative.detach();
        _attached = false;
      }
      return;
    }
    if (_attached) {
      await VirtualBgNative.update(next);
      return;
    }
    final id = _trackId;
    if (id == null) return;
    _attached = await VirtualBgNative.attach(trackId: id, effect: next);
  }
}
