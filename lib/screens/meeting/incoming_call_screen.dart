// SPDX-License-Identifier: AGPL-3.0
//
// IncomingCallScreen — full-screen FaceTime-style incoming call. Plays the
// device ringtone on a loop + periodic haptics, shows the caller, and offers
// Accept / Decline. Accept joins the SAME threadId-anchored room the caller
// created (host=false); Decline tells the server and dismisses.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:go_router/go_router.dart';

import '../../services/call_signaling.dart';
import '../../services/talk_flags.dart';

class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({super.key, required this.call});
  final IncomingCall call;

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  Timer? _buzz;
  Timer? _cancelWatch;
  Timer? _ringTimeout;
  bool _answered = false;

  /// Hard cap on how long the ring may buzz. A real phone gives up after
  /// ~45s; without this bound a stale/unresolved invite that `/calls/incoming`
  /// keeps returning as "ringing" (so `isRinging()` never flips false) would
  /// keep this screen mounted and re-buzz HapticFeedback every 2s FOREVER —
  /// the "phantom vibration every ~2s, no visible caller" bug. Matches
  /// CallKitService's native `duration: 45000`.
  static const _maxRingDuration = Duration(seconds: 45);

  @override
  void initState() {
    super.initState();
    // Loop the system ringtone + buzz every 2s until answered.
    try {
      FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false);
    } catch (_) {/* ringtone is best-effort */}
    HapticFeedback.heavyImpact();
    _buzz = Timer.periodic(const Duration(seconds: 2), (_) {
      HapticFeedback.heavyImpact();
    });
    // Remote-cancel watch: if the caller hangs up / cancels before we answer,
    // the server flips this invite off "ringing"; poll and auto-dismiss so the
    // ring doesn't keep going after the caller has gone (WhatsApp behaviour).
    _cancelWatch = Timer.periodic(const Duration(seconds: 3), (_) => _watchCancel());
    // Belt-and-suspenders: even if `isRinging()` never reports the invite gone
    // (stale server row, or every poll returns a network blip → true), give up
    // after [_maxRingDuration] so the buzz can NEVER loop indefinitely.
    _ringTimeout = Timer(_maxRingDuration, _onRingTimeout);
  }

  /// Ring exceeded its max duration with no answer — treat as a missed call:
  /// stop the ring, clear the shared invite (the poll's `_handled` set already
  /// holds this id, so it won't immediately re-ring), and dismiss.
  Future<void> _onRingTimeout() async {
    if (_answered || !mounted) return;
    _answered = true; // terminal — accept/decline/cancel-watch all no-op now
    _stopRing();
    ref.read(callSignalingProvider).clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Missed call'), duration: Duration(seconds: 2)),
    );
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/calls');
    }
  }

  Future<void> _watchCancel() async {
    if (_answered || !mounted) return;
    final stillRinging =
        await ref.read(callSignalingProvider).isRinging(widget.call.id);
    if (!mounted || _answered || stillRinging) return;
    _answered = true; // treat as terminal so accept/decline no-op
    _stopRing();
    // Clear the shared ring state so the incoming notifier fires null: this
    // resets AppShell's per-invite guard and un-blocks CallSignaling._poll
    // (which skips while incoming.value != null) — without it, no future
    // call would ever ring again after a cancelled one.
    ref.read(callSignalingProvider).clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Call cancelled'), duration: Duration(seconds: 2)),
      );
      if (context.canPop()) {
        context.pop();
      } else {
        context.go('/calls');
      }
    }
  }

  @override
  void dispose() {
    _stopRing();
    super.dispose();
  }

  void _stopRing() {
    _buzz?.cancel();
    _buzz = null;
    _cancelWatch?.cancel();
    _cancelWatch = null;
    _ringTimeout?.cancel();
    _ringTimeout = null;
    try {
      FlutterRingtonePlayer().stop();
    } catch (_) {}
  }

  Future<void> _accept() async {
    if (_answered) return;
    _answered = true;
    _stopRing();
    await ref.read(callSignalingProvider).respond(widget.call.id, 'accept');
    if (!mounted) return;
    // Join the caller's room (host=false) — same threadId anchor. Carry the
    // caller name/avatar so the in-room UI can identify the peer. The media
    // surface is flag-gated: '/call-lk' (LiveKit + captions) when TALK_LK_CALLS
    // is on, else the unchanged P2P '/room'. Accept semantics above are the
    // same either way (respond 'accept' + stop ring).
    final roomUri = Uri(
      path: TalkFlags.callRoomPath(),
      queryParameters: {
        'mode': widget.call.mode,
        'threadId': widget.call.threadId,
        if (widget.call.callerName.trim().isNotEmpty)
          'peerName': widget.call.callerName.trim(),
        if (widget.call.callerAvatar != null &&
            widget.call.callerAvatar!.trim().isNotEmpty)
          'peerAvatar': widget.call.callerAvatar!.trim(),
      },
    ).toString();
    context.pushReplacement(roomUri);
  }

  Future<void> _decline() async {
    if (_answered) return;
    _answered = true;
    _stopRing();
    await ref.read(callSignalingProvider).respond(widget.call.id, 'decline');
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/calls');
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final isVideo = call.mode == 'video';
    final initial =
        call.callerName.trim().isEmpty ? '?' : call.callerName.trim()[0].toUpperCase();
    return PopScope(
      canPop: false, // must Accept or Decline
      child: Scaffold(
        backgroundColor: const Color(0xFF0D2A33),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
            child: Column(
              children: [
                const Spacer(),
                CircleAvatar(
                  radius: 56,
                  backgroundColor: const Color(0xFF0D4A5C),
                  backgroundImage: (call.callerAvatar != null &&
                          call.callerAvatar!.trim().isNotEmpty)
                      ? NetworkImage(call.callerAvatar!.trim())
                      : null,
                  child: (call.callerAvatar != null &&
                          call.callerAvatar!.trim().isNotEmpty)
                      ? null
                      : Text(
                          initial,
                          style: const TextStyle(
                              fontSize: 48,
                              color: Colors.white,
                              fontWeight: FontWeight.w700),
                        ),
                ),
                const SizedBox(height: 24),
                Text(
                  call.callerName,
                  style: const TextStyle(
                      fontSize: 24, color: Colors.white, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(isVideo ? Icons.videocam : Icons.call,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text(
                      'Incoming ${isVideo ? "video" : "voice"} call…',
                      style: const TextStyle(fontSize: 15, color: Colors.white70),
                    ),
                  ],
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallButton(
                      color: const Color(0xFFE53935),
                      icon: Icons.call_end,
                      label: 'Decline',
                      onTap: _decline,
                    ),
                    _CallButton(
                      color: const Color(0xFF2E7D32),
                      icon: isVideo ? Icons.videocam : Icons.call,
                      label: 'Accept',
                      onTap: _accept,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}
