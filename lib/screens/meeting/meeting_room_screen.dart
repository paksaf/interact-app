// SPDX-License-Identifier: AGPL-3.0
//
// MeetingRoomScreen — lifted from sahulat-app/lib/screens/meeting/
// meeting_room_screen.dart and simplified for Talk's invite-code rooms.
// Same flutter_webrtc plumbing, same signaling protocol, same controls
// (video / voice / mute / camera toggle / flip / hangup / share-code).
//
// What's different from Sahulat's version:
//   - No animal/contract/chat-thread context — only a 6-char room code
//   - "Share code" affordance in the bottom bar that copies the wss
//     deep-link to clipboard so it can be sent over any channel
//   - In-call chat overlay disabled in Phase 1 (no thread to anchor to);
//     Phase 2 adds anonymous in-room messages via ws data channel
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/talk_api.dart';

class MeetingRoomScreen extends ConsumerStatefulWidget {
  const MeetingRoomScreen({
    super.key,
    required this.roomCode,
    this.isHost = false,
    this.mode = 'video',
    this.threadId,
  });
  final String roomCode;
  final bool isHost;
  final String mode; // 'video' | 'voice'
  /// Optional chat thread anchor — passed through to createRoom() so the
  /// backend can authorise the call via thread participation and
  /// attach the CallLog to this thread. Null when the call is initiated
  /// from the /invite landing or a /j/CODE deep link (#145).
  final String? threadId;

  @override
  ConsumerState<MeetingRoomScreen> createState() => _MeetingRoomScreenState();
}

class _MeetingRoomScreenState extends ConsumerState<MeetingRoomScreen> {
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;

  bool _videoOn = true;
  bool _audioOn = true;
  bool _connecting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _videoOn = widget.mode == 'video';
    WakelockPlus.enable();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      // Mint / fetch the room token.
      final tok = widget.isHost
          ? await ref.read(talkApiProvider).createRoom(
                threadId: widget.threadId,
                mode: widget.mode,
              )
          : await ref.read(talkApiProvider).joinRoom(widget.roomCode);

      // Local media.
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': _videoOn
            ? {'facingMode': 'user', 'width': 1280, 'height': 720}
            : false,
      });
      _localRenderer.srcObject = _localStream;

      // Peer connection.
      _pc = await createPeerConnection({
        'iceServers': tok.iceServers,
        'sdpSemantics': 'unified-plan',
      });

      _localStream!.getTracks().forEach((t) => _pc!.addTrack(t, _localStream!));

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          setState(() => _remoteRenderer.srcObject = event.streams.first);
        }
      };

      _pc!.onIceCandidate = (cand) {
        _wsSend({'type': 'ice', 'candidate': cand.toMap()});
      };

      _pc!.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          setState(() => _connecting = false);
        }
      };

      // Signaling.
      _ws = WebSocketChannel.connect(
        Uri.parse('${tok.wsUrl}?token=${tok.token}&room=${tok.roomId}'),
      );
      _wsSub = _ws!.stream.listen(_onSignal, onError: (e) {
        if (mounted) setState(() => _error = 'WS error: $e');
      });

      // Host creates the offer immediately.
      if (widget.isHost) {
        final offer = await _pc!.createOffer({});
        await _pc!.setLocalDescription(offer);
        _wsSend({'type': 'offer', 'sdp': offer.sdp, 'sdpType': offer.type});
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _wsSend(Map<String, dynamic> msg) {
    _ws?.sink.add(jsonEncode(msg));
  }

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = m['type'] as String?;
    if (type == 'offer') {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String, m['sdpType'] as String? ?? 'offer'),
      );
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      _wsSend({'type': 'answer', 'sdp': answer.sdp, 'sdpType': answer.type});
    } else if (type == 'answer') {
      await _pc!.setRemoteDescription(
        RTCSessionDescription(m['sdp'] as String, m['sdpType'] as String? ?? 'answer'),
      );
    } else if (type == 'ice' && m['candidate'] != null) {
      final c = Map<String, dynamic>.from(m['candidate'] as Map);
      await _pc!.addCandidate(RTCIceCandidate(
        c['candidate'] as String?,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      ));
    }
  }

  Future<void> _hangup() async {
    await _wsSub?.cancel();
    await _ws?.sink.close();
    await _pc?.close();
    _localStream?.getTracks().forEach((t) => t.stop());
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    WakelockPlus.disable();
    if (mounted) context.pop();
  }

  Future<void> _shareCode() async {
    final url = 'https://talk.interactpak.com/j/${widget.roomCode}';
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Invite link copied: $url')),
    );
  }

  Future<void> _toggleAudio() async {
    final t = _localStream?.getAudioTracks().firstOrNull;
    if (t == null) return;
    final next = !_audioOn;
    t.enabled = next;
    setState(() => _audioOn = next);
  }

  Future<void> _toggleVideo() async {
    final t = _localStream?.getVideoTracks().firstOrNull;
    if (t == null) return;
    final next = !_videoOn;
    t.enabled = next;
    setState(() => _videoOn = next);
  }

  Future<void> _flipCamera() async {
    final t = _localStream?.getVideoTracks().firstOrNull;
    if (t == null) return;
    await Helper.switchCamera(t);
  }

  @override
  void dispose() {
    _hangup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Remote (full-screen)
            Positioned.fill(
              child: _remoteRenderer.srcObject != null
                  ? RTCVideoView(_remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                  : Center(
                      child: _error != null
                          ? Text(_error!, style: const TextStyle(color: Colors.white))
                          : _connecting
                              ? const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    CircularProgressIndicator(),
                                    SizedBox(height: 16),
                                    Text('Connecting…', style: TextStyle(color: Colors.white70)),
                                  ],
                                )
                              : const SizedBox.shrink(),
                    ),
            ),
            // Local PIP (top-right)
            if (_videoOn)
              Positioned(
                top: 16,
                right: 16,
                width: 110,
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: RTCVideoView(
                    _localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
              ),
            // Room code chip (top-left)
            Positioned(
              top: 16,
              left: 16,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _shareCode,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.share, color: Colors.white70, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          widget.roomCode,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Bottom controls
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _CtrlButton(
                    icon: _audioOn ? Icons.mic : Icons.mic_off,
                    color: _audioOn ? Colors.white : Colors.red,
                    bg: Colors.black54,
                    onTap: _toggleAudio,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: _videoOn ? Icons.videocam : Icons.videocam_off,
                    color: _videoOn ? Colors.white : Colors.red,
                    bg: Colors.black54,
                    onTap: _toggleVideo,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: Icons.cameraswitch,
                    color: Colors.white,
                    bg: Colors.black54,
                    onTap: _flipCamera,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: Icons.call_end,
                    color: Colors.white,
                    bg: Colors.red,
                    onTap: _hangup,
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

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.color,
    required this.bg,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final Color bg;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: bg,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Icon(icon, color: color, size: 24),
        ),
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull => isEmpty ? null : first;
}
