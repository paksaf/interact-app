// SPDX-License-Identifier: AGPL-3.0
//
// PreCallPreviewScreen — "see yourself before the call" (requested
// 2026-08-27). Shown before ad-hoc video rooms: full-screen mirrored
// self-view, camera flip, Effects (existing /camera-effects screen for
// backgrounds), then Start → replaces itself with the real /room route.
//
// Historical note: this screen doubled as the minimal reproduction that
// cracked CASE_TALK_BLACK_VIDEO_2026-08-27 (it rendered while the call
// screen's Stack was collapsing to 0×0 via the busy-banner sizing bug).

import 'package:flutter/material.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';

class PreCallPreviewScreen extends StatefulWidget {
  const PreCallPreviewScreen({super.key, required this.roomQuery});

  /// The original /room query string (host, mode, code, threadId, …) —
  /// forwarded untouched when the user taps Start.
  final String roomQuery;

  @override
  State<PreCallPreviewScreen> createState() => _PreCallPreviewScreenState();
}

class _PreCallPreviewScreenState extends State<PreCallPreviewScreen> {
  final _renderer = RTCVideoRenderer();
  MediaStream? _stream;
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _renderer.initialize();
      // VIDEO ONLY — deliberately no audio: keeps the mic/audio-session out
      // of this screen (both for UX and for the black-screen isolation).
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user', 'width': 1280, 'height': 720},
      });
      debugPrint('[precall] tracks: '
          '${_stream!.getTracks().map((t) => '${t.kind}:${t.enabled}').join(', ')}');
      _renderer.srcObject = _stream;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('[precall] camera failed: $e');
      if (mounted) setState(() => _error = 'Camera unavailable: $e');
    }
  }

  Future<void> _flip() async {
    final tracks = _stream?.getVideoTracks() ?? const [];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> _releaseCamera() async {
    _stream?.getTracks().forEach((t) => t.stop());
    _stream = null;
    await _renderer.dispose();
  }

  void _start() async {
    if (_starting) return;
    _starting = true;
    // Release the preview camera BEFORE the room grabs it — two concurrent
    // capture sessions hang budget devices (chat_thread_screen comment).
    await _releaseCamera();
    if (!mounted) return;
    context.pushReplacement('/room?${widget.roomQuery}');
  }

  @override
  void dispose() {
    if (!_starting) {
      // Cancel path — _start() already released on the start path.
      _stream?.getTracks().forEach((t) => t.stop());
      _renderer.dispose();
    }
    super.dispose();
  }

  Widget _preview() {
    if (_stream == null) return const SizedBox.shrink();
    // Plain texture renderer on all platforms — see
    // MeetingRoomScreen._videoView for why the iOS PlatformView detour
    // was reverted (crashes on flutter_webrtc 1.4; renderer was never
    // the black-screen culprit).
    return RTCVideoView(_renderer,
        mirror: true,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D2A33),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
                key: const ValueKey('precall-slot-video'), child: _preview()),
            if (_error != null)
              Positioned.fill(
                key: const ValueKey('precall-slot-error'),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ),
              ),
            Positioned(
              key: const ValueKey('precall-slot-title'),
              top: 56,
              left: 0,
              right: 0,
              child: const Center(
                child: Text('Check how you look',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
              ),
            ),
            Positioned(
              key: const ValueKey('precall-slot-controls'),
              left: 0,
              right: 0,
              bottom: 24,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RoundBtn(
                          icon: Icons.cameraswitch,
                          label: 'Flip',
                          onTap: _flip),
                      const SizedBox(width: 20),
                      _RoundBtn(
                          icon: Icons.auto_awesome,
                          label: 'Effects',
                          onTap: () => context.push('/camera-effects')),
                      const SizedBox(width: 20),
                      // Pre-call sound test (operator request 2026-08-27):
                      // plays a short tone through the CURRENT audio route
                      // (speaker / Bluetooth / wired), so "no sound" gets
                      // caught before the call, not during it.
                      _RoundBtn(
                          icon: Icons.volume_up,
                          label: 'Test sound',
                          onTap: () =>
                              FlutterRingtonePlayer().playNotification()),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: _start,
                        icon: const Icon(Icons.videocam),
                        label: const Text('Start'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.pop(),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.label, this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: Colors.black38,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
