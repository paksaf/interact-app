// SPDX-License-Identifier: AGPL-3.0
//
// Coordinates exclusive camera access — CameraController preview/effects vs
// LiveKit publish. Borrowed from interact-maps DashcamCameraGate.

/// Exclusive phone-camera coordination for Talk (effects, chat capture, LiveKit).
class TalkCameraGate {
  TalkCameraGate._();

  /// Registered by screens that hold a [CameraController] so LiveKit (or
  /// another capture surface) can release it before claiming the camera.
  static Future<void> Function()? releaseLocalCamera;

  /// True while LiveKit is publishing a camera track (optional diagnostics).
  static bool livekitCameraPublishing = false;

  /// Await any registered release, then clear the hook.
  static Future<void> releaseIfHeld() async {
    final release = releaseLocalCamera;
    releaseLocalCamera = null;
    if (release != null) {
      try {
        await release();
      } catch (_) {/* ignore teardown races */}
    }
  }
}
