// SPDX-License-Identifier: AGPL-3.0
//
// CallRoomLiveKitScreen — Phase 2c Option A. A 1:1 call rendered as a
// TWO-person LiveKit room instead of the peer-to-peer /room mesh. This is the
// ONLY difference from the classic call: the media surface. Everything around
// it — the ring, CallKit accept, invite/remote-cancel — is reused unchanged;
// this screen is only ever reached when the `TALK_LK_CALLS` feature flag is on
// (see TalkFlags.callRoomPath()); the default build never routes here.
//
// Why LiveKit for 1:1: the caption-agent is a hidden LiveKit participant that
// transcribes every audio track and republishes captions on the "captions"
// data topic. flutter_webrtc's P2P mesh has no media server to tap, so captions
// are impossible there. By joining a LiveKit room we get Townhall-grade
// multilingual captions "for free" — this screen composes the SAME
// LiveRoomController + caption overlay + LiveApi.toggleCaptions used by
// LiveRoomScreen, just laid out for two people (remote fills, local PIP).
//
// Both legs mint their token with asHost=true: whoever arrives first CREATES
// the room, the second gets the hub's 409 → rejoin path — so the caller/callee
// join ORDER can never 404 the second leg (a real risk with a strict host/guest
// split for a call that rings and answers near-simultaneously).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../services/call_signaling.dart';
import '../../services/callkit_service.dart';
import '../../services/live_api.dart';
import '../../services/livekit_service.dart';
import '../../services/talk_api.dart';
import '../../widgets/in_call_busy_banner.dart';

class CallRoomLiveKitScreen extends ConsumerStatefulWidget {
  const CallRoomLiveKitScreen({
    super.key,
    required this.roomCode,
    this.isHost = false,
    this.mode = 'video',
    this.threadId,
    this.peerName,
    this.peerAvatar,
    this.inviteId,
  });

  /// Invite-code room (bare code) — used only when there is no [threadId].
  final String roomCode;
  final bool isHost;
  final String mode; // 'video' | 'voice'
  final String? threadId;
  final String? peerName;
  final String? peerAvatar;

  /// Ring invite id — lets a host who bails BEFORE the peer joins remote-cancel
  /// the callee's ring (identical semantics to the P2P MeetingRoomScreen).
  final String? inviteId;

  @override
  ConsumerState<CallRoomLiveKitScreen> createState() =>
      _CallRoomLiveKitScreenState();
}

class _CallRoomLiveKitScreenState
    extends ConsumerState<CallRoomLiveKitScreen> {
  final LiveRoomController _ctrl = LiveRoomController();
  late final LiveApi _liveApi; // captured so dispose() can auto-stop captions
  late final TalkApi _talkApi;
  String? _callLogId;
  DateTime? _callStartedAt;
  bool _starting = true;
  String? _startError;
  bool _remoteEverJoined = false;
  Timer? _inviteStatusTimer;
  bool _peerInviteResolved = false;

  // Captions state (mirrors LiveRoomScreen).
  String _captionLanguage = 'multi';
  bool _captionsStarted = false; // agent running → issue stop on exit

  static const _captionLangChoices = <(String code, String label)>[
    ('multi', 'Auto (multilingual)'),
    ('en', 'English'),
    ('ar', 'العربية Arabic'),
    ('ur', 'اردو Urdu'),
    ('tr', 'Türkçe Turkish'),
    ('ru', 'Русский Russian'),
    ('es', 'Español Spanish'),
  ];

  /// Stable LiveKit room code shared by both legs. Thread-anchored calls derive
  /// it from the threadId (uuid without hyphens, ≤32 alnum — matches the group
  /// voice path). Invite-code calls reuse the passed code both sides already
  /// share.
  String get _roomCode {
    final tid = widget.threadId;
    if (tid != null && tid.isNotEmpty) {
      final c = tid.replaceAll('-', '');
      return c.length > 32 ? c.substring(0, 32) : c;
    }
    return widget.roomCode.isNotEmpty
        ? widget.roomCode
        : 'CALL${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  void initState() {
    super.initState();
    _liveApi = ref.read(liveApiProvider);
    _talkApi = ref.read(talkApiProvider);
    WakelockPlus.enable();
    _ctrl.addListener(_onCtrlChanged);
    _startInviteStatusPoll();
    _start();
  }

  void _startInviteStatusPoll() {
    final id = widget.inviteId;
    if (!widget.isHost || id == null || id.isEmpty) return;
    Future<void> tick() async {
      if (!mounted || _remoteEverJoined || _leaving) {
        _inviteStatusTimer?.cancel();
        return;
      }
      final status = await ref.read(callSignalingProvider).inviteStatus(id);
      if (!mounted || status == null) return;
      if (status == 'busy' || status == 'declined' || status == 'cancelled') {
        _inviteStatusTimer?.cancel();
        _peerInviteResolved = true;
        if (mounted) {
          final name = (widget.peerName ?? '').trim();
          final msg = switch (status) {
            'busy' => name.isEmpty ? 'Busy' : '$name is on another call',
            'declined' => name.isEmpty ? 'Call declined' : '$name declined',
            'cancelled' => 'Call cancelled',
            _ => 'Call ended',
          };
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
        await _leave();
      }
    }

    unawaited(tick());
    _inviteStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(tick());
    });
  }

  void _onCtrlChanged() {
    // Remember once the peer actually connected — a host who leaves before this
    // must remote-cancel the ring; after it, a leave is a normal hangup. The
    // UI itself rebuilds via the AnimatedBuilder(animation: _ctrl); this
    // listener only tracks the flag (no setState → no setState-during-notify).
    if (_ctrl.tiles.any((t) => !t.isLocal)) _remoteEverJoined = true;
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final join = (await _liveApi.token(
        code: _roomCode,
        asHost: true, // both legs host → first creates, second rejoins (409)
        role: LiveRole.speaker,
        mode: '1:1',
      ))
          .copyWith(voiceFirst: widget.mode != 'video');
      _callLogId = join.callLogId;
      _callStartedAt = DateTime.now();
      await _ctrl.connect(join);
      if (!mounted) return;
      setState(() => _starting = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = e is LiveApiException ? e.message : '$e';
      });
    }
  }

  /// Fail-soft escape hatch: drop back to the classic P2P call for the same
  /// call, so a LiveKit outage never blocks a user from talking.
  void _fallbackToP2p() {
    final qp = <String, String>{
      if (widget.isHost) 'host': 'true',
      'mode': widget.mode,
      if (widget.threadId != null) 'threadId': widget.threadId!,
      if (widget.roomCode.isNotEmpty) 'code': widget.roomCode,
      if (widget.peerName != null && widget.peerName!.isNotEmpty)
        'peerName': widget.peerName!,
      if (widget.peerAvatar != null && widget.peerAvatar!.isNotEmpty)
        'peerAvatar': widget.peerAvatar!,
      if (widget.inviteId != null) 'inviteId': widget.inviteId!,
    };
    context.pushReplacement(Uri(path: '/room', queryParameters: qp).toString());
  }

  /// Tear down: stop the caption agent (halt Deepgram billing), leave the room,
  /// remote-cancel the ring if we bailed before the peer joined, and clear any
  /// native CallKit entry — the SAME cleanup the P2P screen performs.
  bool _leaving = false;

  Future<void> _leave() async {
    if (_leaving) return; // guard: double-tap hangup would double-pop the stack
    _leaving = true;
    // Auto-stop captions so no room bills idle after hangup (fire-and-forget).
    if (_captionsStarted) {
      _captionsStarted = false;
      unawaited(
        _liveApi.toggleCaptions(_ctrl.roomName, false).catchError((_) => false),
      );
    }
    // Host bailed before the peer connected → cancel the invite so the callee's
    // ringing screen auto-dismisses (true remote-cancel).
    // Kicked off here so the POST is on the wire immediately, but awaited just
    // before the pop below — `unawaited(...)` alone could tear the route down
    // with the request still queued, leaving the callee ringing. Mirrors the
    // same fix in meeting_room_screen.dart (the default, non-flag-gated path).
    Future<void>? cancelInFlight;
    if (widget.isHost &&
        widget.inviteId != null &&
        widget.inviteId!.isNotEmpty &&
        !_remoteEverJoined &&
        !_peerInviteResolved) {
      cancelInFlight = ref
          .read(callSignalingProvider)
          .respond(widget.inviteId!, 'cancel')
          .catchError((_) {});
    }
    final tid = widget.threadId;
    if (tid != null && tid.isNotEmpty) {
      unawaited(CallKitService.endCall(tid));
    }
    unawaited(CallKitService.endAllCalls());
    Future<void>? logClose;
    final logId = _callLogId;
    _callLogId = null;
    if (logId != null && logId.isNotEmpty) {
      final started = _callStartedAt;
      final secs = started == null
          ? null
          : DateTime.now().difference(started).inSeconds.clamp(0, 86400).toInt();
      logClose = _talkApi
          .closeCallLog(logId, reason: 'ended', durationSecs: secs)
          .catchError((_) {});
    }
    await _ctrl.leave();
    WakelockPlus.disable();
    if (cancelInFlight != null) {
      try {
        await cancelInFlight.timeout(const Duration(seconds: 4));
      } catch (_) {/* best-effort — callee still expires on its own timeout */}
    }
    if (logClose != null) {
      try {
        await logClose.timeout(const Duration(seconds: 4));
      } catch (_) {/* audit only */}
    }
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    // Belt-and-suspenders: if we somehow exit without _leave(), still ask the
    // agent to stop (captured LiveApi, no ref/context needed post-unmount).
    if (_captionsStarted) {
      _captionsStarted = false;
      unawaited(
        _liveApi.toggleCaptions(_ctrl.roomName, false).catchError((_) => false),
      );
    }
    _inviteStatusTimer?.cancel();
    WakelockPlus.disable();
    _ctrl.removeListener(_onCtrlChanged);
    _ctrl.dispose();
    super.dispose();
  }

  // ── Captions (ported from LiveRoomScreen) ──────────────────────────
  Future<void> _toggleCaptions() async {
    final turnOn = !_ctrl.captionsOn;
    if (turnOn) {
      final health = await _liveApi.captionsHealth();
      if (!mounted) return;
      if (!health.unknown && (!health.agentOk || !health.configured)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Captions unavailable — caption-agent / Deepgram keys required.',
            ),
          ),
        );
        return;
      }
      final lang = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  'Caption language',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Speak in that language for best accuracy. Auto uses Deepgram multilingual.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              for (final (code, label) in _captionLangChoices)
                ListTile(
                  title: Text(label),
                  trailing:
                      code == _captionLanguage ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(ctx, code),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (!mounted || lang == null) return;
      _captionLanguage = lang;
    }
    _ctrl.setCaptionsOn(turnOn);
    try {
      final okDone = await _liveApi.toggleCaptions(
        _ctrl.roomName,
        turnOn,
        language: _captionLanguage,
      );
      if (!okDone && mounted) {
        _ctrl.setCaptionsOn(false);
        _captionsStarted = false;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context).captionsUnavailable)),
        );
      } else if (mounted) {
        _captionsStarted = turnOn;
        if (turnOn) {
          final label = _captionLangChoices
              .firstWhere((e) => e.$1 == _captionLanguage,
                  orElse: () => (_captionLanguage, _captionLanguage))
              .$2;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Captions on · Deepgram · $label')),
          );
        }
      }
    } on LiveApiException catch (e) {
      if (!mounted) return;
      _ctrl.setCaptionsOn(false);
      _captionsStarted = false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      _ctrl.setCaptionsOn(false);
      _captionsStarted = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context).captionsUnavailable)),
      );
    }
  }

  // ── Tiles ──────────────────────────────────────────────────────────
  LiveTile? get _remoteTile {
    for (final t in _ctrl.tiles) {
      if (!t.isLocal) return t;
    }
    return null;
  }

  LiveTile? get _localTile {
    for (final t in _ctrl.tiles) {
      if (t.isLocal) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) await _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              if (_starting) {
                return _statusView('Connecting…', spinner: true);
              }
              if (_startError != null) {
                return _statusView(_startError!, retry: true, fallback: true);
              }
              if (_ctrl.error != null) {
                return _statusView(_ctrl.error!, retry: true, fallback: true);
              }
              return _callStack();
            },
          ),
              const InCallBusyBanner(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _callStack() {
    final remote = _remoteTile;
    final local = _localTile;
    final connecting = remote == null;
    return Stack(
      children: [
        // Background: remote video once the peer joins; else, on a video call,
        // the local camera preview so the caller isn't staring at black.
        Positioned.fill(
          child: (remote != null && remote.hasVideo)
              ? VideoTrackRenderer(remote.videoTrack!)
              : (connecting && local != null && local.hasVideo)
                  ? VideoTrackRenderer(local.videoTrack!)
                  : Container(color: Colors.black),
        ),
        // "Calling…" overlay until the peer connects.
        if (connecting)
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: 0.35),
              child: _callingOverlay(),
            ),
          ),
        // Local PIP once connected + camera on.
        if (!connecting && _ctrl.camOn && local != null && local.hasVideo)
          Positioned(
            top: 16,
            right: 16,
            width: 110,
            height: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: VideoTrackRenderer(local.videoTrack!),
            ),
          ),
        // Caption indicator chip (top-left) so users know audio is transcribed.
        if (_ctrl.captionsOn)
          Positioned(
            top: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.closed_caption, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text('Captions on · Deepgram',
                    style: TextStyle(color: Colors.white, fontSize: 12)),
              ]),
            ),
          ),
        if (_ctrl.captionText.isNotEmpty) _captionOverlay(),
        _controlBar(),
      ],
    );
  }

  Widget _callingOverlay() {
    final name = (widget.peerName ?? '').trim();
    final label = widget.isHost
        ? (name.isEmpty ? 'Calling…' : 'Calling $name…')
        : (name.isEmpty ? 'Connecting…' : 'Connecting to $name…');
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _peerAvatar(48),
        const SizedBox(height: 20),
        Text(label,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(widget.isHost ? 'Ringing…' : 'Waiting for the other side…',
            style: const TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 24),
        const CircularProgressIndicator(color: Colors.white),
        const SizedBox(height: 32),
        SizedBox(
          width: 200,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _leave,
            icon: const Icon(Icons.call_end),
            label: Text(widget.isHost ? 'Cancel' : 'End'),
          ),
        ),
      ],
    );
  }

  Widget _peerAvatar(double radius) {
    final name = (widget.peerName ?? '').trim();
    final initial = name.isEmpty ? '?' : name[0].toUpperCase();
    final avatar = widget.peerAvatar?.trim();
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF0D4A5C),
      backgroundImage: hasAvatar ? NetworkImage(avatar) : null,
      child: hasAvatar
          ? null
          : Text(initial,
              style: TextStyle(
                  fontSize: radius * 0.8,
                  color: Colors.white,
                  fontWeight: FontWeight.w700)),
    );
  }

  // Caption overlay — same look as LiveRoomScreen._captionOverlay().
  Widget _captionOverlay() {
    final speaker = _ctrl.captionSpeaker;
    final text = _ctrl.captionText;
    final isFinal = _ctrl.captionIsFinal;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 104,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: isFinal ? 0.75 : 0.55),
              borderRadius: BorderRadius.circular(12),
              border:
                  isFinal ? null : Border.all(color: Colors.white24, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (speaker.isNotEmpty)
                  Text(speaker,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      )),
                Text(text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: isFinal ? 1 : 0.85),
                      fontSize: 16,
                      height: 1.3,
                      fontStyle: isFinal ? FontStyle.normal : FontStyle.italic,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Bottom controls (mic / cam / flip / captions / hangup) ─────────
  Widget _controlBar() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 24,
      // FittedBox so the row never clips the red end button on narrow phones
      // (the A23 "no cancel button" lesson).
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CtrlButton(
              icon: _ctrl.micOn ? Icons.mic : Icons.mic_off,
              color: _ctrl.micOn ? Colors.white : Colors.red,
              onTap: _ctrl.toggleMic,
            ),
            const SizedBox(width: 14),
            _CtrlButton(
              icon: _ctrl.camOn ? Icons.videocam : Icons.videocam_off,
              color: _ctrl.camOn ? Colors.white : Colors.red,
              onTap: _ctrl.toggleCamera,
            ),
            const SizedBox(width: 14),
            _CtrlButton(
              icon: Icons.cameraswitch,
              color: Colors.white,
              onTap: _ctrl.switchCamera,
            ),
            const SizedBox(width: 14),
            _CtrlButton(
              icon: _ctrl.captionsOn
                  ? Icons.closed_caption
                  : Icons.closed_caption_off,
              color:
                  _ctrl.captionsOn ? const Color(0xFFBE9A5F) : Colors.white,
              onTap: _toggleCaptions,
            ),
            const SizedBox(width: 14),
            _CtrlButton(
              icon: Icons.call_end,
              color: Colors.white,
              bg: Colors.red,
              onTap: _leave,
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusView(String message,
      {bool spinner = false, bool retry = false, bool fallback = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinner) ...[
            const CircularProgressIndicator(color: Colors.white),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ),
          if (retry) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
          if (fallback) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _fallbackToP2p,
              child: const Text('Use classic call instead'),
            ),
          ],
          const SizedBox(height: 8),
          TextButton(onPressed: _leave, child: const Text('Leave')),
        ],
      ),
    );
  }
}

class _CtrlButton extends StatelessWidget {
  const _CtrlButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.bg = Colors.black54,
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
