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
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../services/auth_service.dart';
import '../../services/call_signaling.dart';
import '../../services/callkit_service.dart';
import '../../services/talk_api.dart';

class MeetingRoomScreen extends ConsumerStatefulWidget {
  const MeetingRoomScreen({
    super.key,
    required this.roomCode,
    this.isHost = false,
    this.mode = 'video',
    this.threadId,
    this.peerName,
    this.peerAvatar,
    this.inviteId,
  });
  final String roomCode;
  final bool isHost;
  final String mode; // 'video' | 'voice'
  /// Ring invite id (from callSignaling.ring). When the host hangs up or the
  /// call goes unanswered BEFORE the peer joins, we POST respond(inviteId,
  /// 'cancel') so the callee's ringing screen auto-dismisses (true remote-
  /// cancel). Null for invite-code rooms / the callee side.
  final String? inviteId;
  /// Optional chat thread anchor — passed through to createRoom() so the
  /// backend can authorise the call via thread participation and
  /// attach the CallLog to this thread. Null when the call is initiated
  /// from the /invite landing or a /j/CODE deep link (#145).
  final String? threadId;

  /// Peer display name / avatar for the WhatsApp-style outgoing "Calling…"
  /// overlay and the post-call "Call again" screen. Null for invite-code
  /// rooms with no known peer (falls back to a generic "Connecting…").
  final String? peerName;
  final String? peerAvatar;

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

  // Signaling robustness (2026-07-02 connectivity canon): carrier-grade
  // NAT drops idle WebSocket mappings in ~30-60 s, and a Wi-Fi↔LTE flap
  // used to kill signaling for the rest of the call. 20 s app-level ping
  // + exponential-backoff reconnect (cap 30 s, jittered) fix both.
  Timer? _keepalive;
  Timer? _reconnectTimer;
  int _wsRetry = 0;
  bool _hungUp = false;
  String? _wsUri; // remembered for reconnect

  bool _videoOn = true;
  bool _audioOn = true;
  bool _connecting = true;
  String? _error;

  /// Set once we've sent (offerer) or answered (answerer) — guards against a
  /// duplicate offer arriving post-connect and tearing down live media.
  bool _offerAnswered = false;

  // Open-relay signaling identity (matches the DEPLOYED /opt/signaling/
  // server.js). There is NO `welcome`; the client mints its OWN unique
  // _myUserId and sends `join` the instant the socket connects. _remoteUserId
  // is the single other party in this 1:1 room; _roomId is the minted token's
  // room, sent in the explicit `join` (roomId + userId are both required).
  String? _myUserId;
  String? _remoteUserId;
  String? _roomId;

  /// ICE candidates are gathered within ~1–2s of setLocalDescription, often
  /// BEFORE the peer's socket has joined the relay room. Candidates sent into
  /// an empty room are dropped, which can leave the connection half-open. So we
  /// buffer outgoing candidates until we've seen a peer-originated frame
  /// (ready/offer/answer/ice), then flush and send live thereafter.
  bool _peerPresent = false;
  // Buffered RAW candidate maps (cand.toMap()) — the `target` userId isn't
  // known until we've resolved _remoteUserId, so each is wrapped at flush time.
  final List<Map<String, dynamic>> _pendingIce = [];

  void _markPeerPresentAndFlush() {
    if (_peerPresent) return;
    _peerPresent = true;
    // Can only flush once we know WHO to relay to — the server routes by
    // userId. If _remoteUserId is still null, keep buffering (shouldn't happen
    // given callers set it first, but stay safe).
    if (_remoteUserId == null) {
      _peerPresent = false;
      return;
    }
    debugPrint('[call] peer present → flush ${_pendingIce.length} ice');
    for (final c in _pendingIce) {
      _wsSend({'type': 'ice-candidate', 'target': _remoteUserId, 'payload': c});
    }
    _pendingIce.clear();
  }

  // Post-call ("Call again" / "Back to chat") + teardown bookkeeping.
  // _ended flips the whole screen to the end-of-call panel; _torndown makes
  // _teardown idempotent so the dispose() path can't double-close renderers.
  bool _ended = false;
  bool _torndown = false;
  // Captured at initState so the remote-cancel in _teardown() never has to call
  // ref.read() — dispose() reaches _teardown() via _hangup(), and by then the
  // provider scope may already be gone (dispose() already try/catches its own
  // ref.read calls for exactly this reason). An unguarded ref.read there threw
  // away BOTH the cancel and the rest of teardown. See _sendCancelIfNeeded().
  CallSignaling? _signaling;
  bool _cancelSent = false;
  String _endReason = 'ended'; // 'ended' | 'no_answer'
  // Auto-give-up ring timer (host/outgoing only): if the peer never joins
  // within the window we surface the "No answer" panel instead of ringing
  // forever. Cancelled the moment the peer connects, or on teardown.
  Timer? _noAnswerTimer;
  static const Duration _noAnswerAfter = Duration(seconds: 45);

  // Gestures: my raised hand, the peer's raised hand, and a transient
  // emoji "flash" shown center-screen when either side reacts.
  bool _handRaised = false;
  bool _peerHand = false;
  String? _flashEmoji;
  Timer? _flashTimer;

  /// Code resolved from the minted token — for the HOST, widget.roomCode is
  /// empty (the code is generated server-side / in createRoom), so QR + share
  /// must read this. Joiners already have widget.roomCode.
  String? _resolvedCode;

  /// The code to display / share / encode — joiner's passed code, else the
  /// host's resolved code, else empty while connecting.
  String get _code =>
      widget.roomCode.isNotEmpty ? widget.roomCode : (_resolvedCode ?? '');

  /// True only for human 6-char invite codes (not thread UUIDs). UUID chips
  /// leaked into the live-call header and confused users.
  bool get _isShareableCode {
    final c = _code.trim().toUpperCase();
    return RegExp(r'^[A-Z2-9]{6}$').hasMatch(c);
  }

  /// Label in the top-left chip — short code, peer name, or generic "Invite".
  String get _headerLabel {
    if (_isShareableCode) return _code.trim().toUpperCase();
    final peer = widget.peerName?.trim();
    if (peer != null && peer.isNotEmpty) return peer;
    return 'Invite';
  }

  /// The join deep-link the QR encodes; InviteScreen's scanner accepts either
  /// this link or a bare code.
  String get _joinLink => 'https://talk.interactpak.com/j/$_code';

  Timer? _inviteStatusTimer;
  String? _busyBanner; // in-call: "Name tried to call — marked busy"

  @override
  void initState() {
    super.initState();
    _videoOn = widget.mode == 'video';
    WakelockPlus.enable();
    // Ad-hoc host: mint the 6-char code *before* the network round-trip so the
    // header never sits on "······" while createRoom is in flight.
    if (widget.isHost &&
        widget.roomCode.isEmpty &&
        widget.threadId == null &&
        (widget.peerName == null || widget.peerName!.trim().isEmpty)) {
      _resolvedCode = TalkApi.generateRoomCode();
    }
    // Mark on-call so a second ringer gets `busy` instead of a stacked ring UI.
    _signaling = ref.read(callSignalingProvider);
    ref.read(callSignalingProvider).setInCall(true);
    ref
        .read(callSignalingProvider)
        .missedWhileBusy
        .addListener(_onMissedWhileBusy);
    _startInviteStatusPoll();
    _bootstrap();
  }

  void _onMissedWhileBusy() {
    final call = ref.read(callSignalingProvider).missedWhileBusy.value;
    if (call == null || !mounted) return;
    setState(() {
      _busyBanner = '${call.callerName} tried to call — marked busy';
    });
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted) return;
      ref.read(callSignalingProvider).clearMissedWhileBusy();
      setState(() => _busyBanner = null);
    });
  }

  /// While host is still connecting, poll invite status so a remote `busy`
  /// ends "Ringing…" immediately (instead of waiting for TTL / no-answer).
  void _startInviteStatusPoll() {
    final id = widget.inviteId;
    if (!widget.isHost || id == null || id.isEmpty) return;
    _inviteStatusTimer?.cancel();
    _inviteStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_connecting) {
        _inviteStatusTimer?.cancel();
        return;
      }
      final status = await ref.read(callSignalingProvider).inviteStatus(id);
      if (!mounted || status == null) return;
      if (status == 'busy') {
        _inviteStatusTimer?.cancel();
        await _endCall(reason: 'busy');
      } else if (status == 'declined' || status == 'cancelled') {
        _inviteStatusTimer?.cancel();
        await _endCall(reason: status == 'declined' ? 'declined' : 'cancelled');
      }
    });
  }

  Future<void> _bootstrap() async {
    // Bounded connect deadline for BOTH sides. Previously only the host had a
    // timer; the callee had none, so a call that never connected kept the
    // camera + wakelock + the WS reconnect loop running FOREVER, which
    // overheated and HUNG the phone (had to hard-restart). Now every call
    // gives up and releases all resources after the window.
    _noAnswerTimer?.cancel();
    _noAnswerTimer = Timer(_noAnswerAfter, () {
      if (!mounted || !_connecting) return;
      _endCall(reason: widget.isHost ? 'no_answer' : 'ended');
    });
    try {
      await _localRenderer.initialize();
      await _remoteRenderer.initialize();

      // Mint / fetch the room token.
      // For a THREAD-anchored 1:1 call, BOTH sides mint by threadId — the
      // backend keys the signalling room off the thread, so caller + callee
      // land in the same room. The callee arrives from the incoming screen
      // with NO room code, so calling joinRoom('') 404s and the response
      // (non-JSON) blew up as `FormatException` on /talk/rooms/join. Only the
      // invite-code path (no threadId, real code) uses joinRoom.
      final tok = widget.threadId != null
          ? await ref.read(talkApiProvider).createRoom(
                threadId: widget.threadId,
                mode: widget.mode,
              )
          : widget.isHost
              ? await ref.read(talkApiProvider).createRoom(
                    mode: widget.mode,
                    // Reuse the code we already showed in the header.
                    roomId: _resolvedCode,
                  )
              : await ref.read(talkApiProvider).joinRoom(widget.roomCode);

      // Local media. Audio uses WebRTC's built-in DSP (P2 noise suppression):
      // echo cancellation + noise suppression + auto gain — huge for noisy
      // field/site calls. These are hints; the platform enables what it can.
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': _videoOn
            ? {'facingMode': 'user', 'width': 1280, 'height': 720}
            : false,
      });
      _localRenderer.srcObject = _localStream;

      // ICE servers: prefer a server-minted ephemeral TURN credential
      // (fetchEphemeralTurnIceServer — off by default, enabled via
      // --dart-define=INTERACT_TURN_CREDENTIAL_URL=...), falling back to
      // the token's iceServers exactly as before. 2026-07-02.
      var iceServers = tok.iceServers;
      final eph = await fetchEphemeralTurnIceServer();
      if (eph != null) {
        iceServers = [
          {
            'urls': ['stun:stun.l.google.com:19302'],
          },
          eph,
        ];
      }

      // Peer connection.
      _pc = await createPeerConnection({
        'iceServers': iceServers,
        'sdpSemantics': 'unified-plan',
      });

      _localStream!.getTracks().forEach((t) => _pc!.addTrack(t, _localStream!));

      _pc!.onTrack = (event) {
        if (event.streams.isNotEmpty) {
          setState(() => _remoteRenderer.srcObject = event.streams.first);
        }
      };

      _pc!.onIceCandidate = (cand) {
        final candMap = Map<String, dynamic>.from(cand.toMap());
        // Relay to the resolved peer once known + present; else buffer the RAW
        // candidate map (wrapped with `target` at flush time by _markPeer…).
        if (_remoteUserId != null && _peerPresent) {
          _wsSend({
            'type': 'ice-candidate',
            'target': _remoteUserId,
            'payload': candMap,
          });
        } else {
          _pendingIce.add(candMap);
        }
      };

      _pc!.onConnectionState = (s) {
        debugPrint('[call] pcState=$s');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _noAnswerTimer?.cancel(); // peer answered — stop the give-up timer
          setState(() => _connecting = false);
        }
      };

      // Remember the resolved room code (host has none from widget) so the
      // QR + share affordances have something to encode. Must setState —
      // otherwise the header stays on "······" for the whole Ringing phase
      // even after mint returns a real 6-char talk:CODE.
      final resolved = tok.roomId.split(':').last;
      if (mounted) setState(() => _resolvedCode = resolved);

      // Signaling. The backend already returns wsUrl WITH the auth token
      // embedded (`wss://signal.interactpak.com?token=<jwt>`), and the JWT
      // itself carries the room claim — so we must NOT re-append token/room
      // (doing so produced a malformed `?token=…?token=…` that the signaling
      // server rejected → immediate WS error → every call died on connect).
      // We only NORMALIZE the path to `/ws`, which is the path the signaling
      // server upgrades on (the minted URL omits it).
      _wsUri = _normalizeSignalUrl(tok.wsUrl);
      _roomId = tok.roomId; // sent in the explicit `join` (server proto)
      // Mint our OWN unique userId — the open relay assigns nothing; roomId +
      // userId are both required in `join`, and the id just needs to be
      // distinct per room. epoch-micros + a random suffix is plenty.
      _myUserId =
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
      debugPrint('[call] minted room=${tok.roomId} host=${widget.isHost} '
          'thread=${widget.threadId} wsUri=$_wsUri ice=${iceServers.length}');
      _connectSignaling();

      // No offer is created here anymore. Join order decides the offerer: the
      // peer that finds EXISTING members in `joined.peers` offers; the peer
      // already in the room waits for that offer (see _onSignal). This replaces
      // the old host-offers-on-connect flow that the relay server never spoke.
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _sendJoinWithLocalName() async {
    String localName = 'INTERACT';
    try {
      final n = await ref.read(authServiceProvider).displayName();
      final p = await ref.read(authServiceProvider).phone();
      final trimmed = n?.trim() ?? '';
      if (trimmed.isNotEmpty &&
          !RegExp(r'^Talk\s+\d{3,6}$', caseSensitive: false).hasMatch(trimmed)) {
        localName = trimmed;
      } else if (p != null && p.trim().isNotEmpty) {
        localName = p.trim();
      } else if (trimmed.isNotEmpty) {
        localName = trimmed;
      }
    } catch (_) {/* keep INTERACT */}
    if (_hungUp || _ws == null) return;
    _wsSend({
      'type': 'join',
      'roomId': _roomId,
      'userId': _myUserId,
      'name': localName,
      'role': 'user',
    });
  }

  /// Ensure the signaling URL targets the server's `/ws` upgrade path while
  /// preserving the embedded `?token=<jwt>` query. The minted URL comes as
  /// `wss://host?token=…` (no path); the signaling server only upgrades on
  /// `/ws`. Falls back to the raw string if parsing ever fails.
  String _normalizeSignalUrl(String raw) {
    try {
      final u = Uri.parse(raw);
      if (u.path.isEmpty || u.path == '/') {
        return u.replace(path: '/ws').toString();
      }
      return raw;
    } catch (_) {
      return raw;
    }
  }

  /// Connect (or re-connect) the signaling WebSocket. Reused by the
  /// backoff reconnect path — the peer connection is left untouched so an
  /// established ICE path keeps flowing while signaling heals.
  void _connectSignaling() {
    final uri = _wsUri;
    if (uri == null || _hungUp) return;
    _wsSub?.cancel();
    _ws = WebSocketChannel.connect(Uri.parse(uri));
    _wsSub = _ws!.stream.listen(
      (raw) {
        _wsRetry = 0; // any inbound frame proves the link is healthy
        _onSignal(raw);
      },
      onError: (e) {
        // Once CONNECTED the media is peer-to-peer and survives a brief
        // signaling blip (Wi-Fi flap / DNS flap) — don't flash a scary error
        // over live video; just reconnect quietly. Only surface an error while
        // we're still trying to establish the call.
        debugPrint('[call] ws error: $e');
        if (mounted && _connecting) setState(() => _error = 'Reconnecting…');
        _scheduleWsReconnect();
      },
      onDone: _scheduleWsReconnect,
    );
    // The deployed open relay sends NO `welcome` — the client must announce
    // itself by sending `join` the instant the socket is up. web_socket_channel
    // queues the frame until the connection opens, so this is safe to send
    // synchronously here. On a reconnect this re-joins automatically (the peer
    // list comes back in a fresh `joined`), so no separate `ready` is needed.
    // Announce OUR display name (not the peer's) — cosmetic on the open relay
    // peer list / "X joined" UI.
    unawaited(_sendJoinWithLocalName());
    debugPrint('[call] ws connect → join room=$_roomId user=$_myUserId');
    // 20 s application-level keepalive — keeps NAT mappings warm; the
    // signaling server replies {type:'pong'} (older deploys ignore it).
    _keepalive?.cancel();
    _keepalive = Timer.periodic(const Duration(seconds: 20), (_) {
      _wsSend({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
    });
  }

  void _scheduleWsReconnect() {
    if (_hungUp || !mounted) return;
    // Permanent-failure guard: a rejected token (HTTP 401 at the WS upgrade)
    // never recovers, so an unbounded reconnect loop kept the camera + wakelock
    // alive and HUNG the phone. After ~8 failed attempts, give up and release
    // everything via _endCall → _teardown (stops tracks, wakelock, WS, pc).
    if (_wsRetry >= 8) {
      if (mounted && _connecting) {
        setState(() => _error = 'Could not connect the call.');
        _endCall(reason: 'ended');
      }
      return;
    }
    _keepalive?.cancel();
    final capped = _wsRetry > 6 ? 6 : _wsRetry; // 2^6*500ms = 32s pre-cap
    _wsRetry += 1;
    final baseMs = (500 * (1 << capped)).clamp(500, 30000);
    // ±20% jitter so both call legs don't reconnect in lockstep.
    final delayMs =
        (baseMs * (0.8 + (DateTime.now().microsecond % 1000) / 2500)).round();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), _connectSignaling);
  }

  void _wsSend(Map<String, dynamic> msg) {
    _ws?.sink.add(jsonEncode(msg));
  }

  Future<void> _onSignal(dynamic raw) async {
    final m = jsonDecode(raw as String) as Map<String, dynamic>;
    final type = m['type'] as String?;
    if (type != 'ping' && type != 'pong') debugPrint('[call] ← $type');
    if (type == 'joined') {
      // We are IN the room. `peers` = members ALREADY here (excludes us). If any
      // exist, WE joined second → we are the OFFERER (1:1 → at most one peer).
      final peers = (m['peers'] as List?) ?? const [];
      debugPrint('[call] joined peers=${peers.length}');
      if (peers.isNotEmpty) {
        final peer = peers.first;
        _remoteUserId =
            (peer is Map ? peer['userId'] : null)?.toString();
        _markPeerPresentAndFlush();
        if (_remoteUserId != null && !_offerAnswered) {
          final offer = await _pc!.createOffer({});
          await _pc!.setLocalDescription(offer);
          debugPrint('[call] → offer to $_remoteUserId');
          _wsSend({
            'type': 'offer',
            'target': _remoteUserId,
            'payload': {'sdp': offer.sdp, 'type': offer.type},
          });
        }
      }
    } else if (type == 'peer-joined') {
      // Someone joined AFTER us → they will offer. We WAIT (ANSWERER); just
      // record who they are and flush any buffered ICE. Do NOT offer.
      final peer = m['peer'];
      _remoteUserId = (peer is Map ? peer['userId'] : null)?.toString();
      debugPrint('[call] peer-joined $_remoteUserId');
      _markPeerPresentAndFlush();
    } else if (type == 'peer-left') {
      // Our 1:1 counterpart dropped — end the call via the normal path.
      if (m['userId']?.toString() == _remoteUserId) {
        _endCall(reason: 'ended');
      }
    } else if (type == 'offer') {
      // Incoming offer (we are the ANSWERER). Ignore duplicate offers once we've
      // already answered and connected, so a resend can't tear down live media.
      if (_offerAnswered && !_connecting) return;
      _remoteUserId = m['from']?.toString() ?? _remoteUserId;
      debugPrint('[call] ← offer from $_remoteUserId');
      _markPeerPresentAndFlush();
      final p = m['payload'] as Map<String, dynamic>?;
      await _pc!.setRemoteDescription(
        RTCSessionDescription(p?['sdp'] as String?, p?['type'] as String?),
      );
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      _wsSend({
        'type': 'answer',
        'target': m['from'],
        'payload': {'sdp': answer.sdp, 'type': answer.type},
      });
      _offerAnswered = true; // answerer: handshake done from our side
    } else if (type == 'answer') {
      debugPrint('[call] ← answer');
      final p = m['payload'] as Map<String, dynamic>?;
      await _pc!.setRemoteDescription(
        RTCSessionDescription(p?['sdp'] as String?, p?['type'] as String?),
      );
      _offerAnswered = true; // offerer: peer answered
    } else if (type == 'ice-candidate') {
      final p = m['payload'] as Map<String, dynamic>?;
      if (p != null) {
        await _pc!.addCandidate(RTCIceCandidate(
          p['candidate'] as String?,
          p['sdpMid'] as String?,
          (p['sdpMLineIndex'] as num?)?.toInt(),
        ));
      }
    } else if (type == 'error') {
      // The open relay replies {type:error, error:'Unknown message type'} for
      // app-custom frames (reaction/hand) — harmless, just log it.
      debugPrint('[call] server error: ${m['error']}');
    } else if (type == 'reaction') {
      // Peer sent an emoji reaction — flash it big for ~1.6s. (App-custom; the
      // relay ignores/errors these — kept for local echo + future data-channel.)
      final e = m['emoji'] as String?;
      if (e != null) _flashReaction(e);
    } else if (type == 'hand') {
      if (!mounted) return;
      setState(() => _peerHand = m['up'] == true);
    }
    // `pong` (and anything else) falls through — ignored.
  }

  // ── Gestures (raise hand + emoji reactions) over the signaling WS ──────
  void _flashReaction(String emoji) {
    if (!mounted) return;
    _flashTimer?.cancel();
    setState(() => _flashEmoji = emoji);
    _flashTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _flashEmoji = null);
    });
  }

  void _sendReaction(String emoji) {
    _wsSend({'type': 'reaction', 'emoji': emoji});
    _flashReaction(emoji); // show locally too
  }

  void _toggleHand() {
    setState(() => _handRaised = !_handRaised);
    _wsSend({'type': 'hand', 'up': _handRaised});
  }

  void _showReactionPicker() {
    const emojis = ['👍', '❤️', '😂', '🎉', '👏', '🔥', '😮', '🙏'];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              for (final e in emojis)
                InkWell(
                  onTap: () {
                    _sendReaction(e);
                    Navigator.pop(ctx);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(e, style: const TextStyle(fontSize: 32)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tear down all call resources. Idempotent (guarded by [_torndown]) so
  /// the end-button path AND the dispose() path can both call it safely
  /// without double-closing renderers / peer connection.
  Future<void> _teardown() async {
    if (_torndown) return;
    _torndown = true;
    _hungUp = true; // deliberate close — suppress auto-reconnect
    // True remote-cancel: if WE started the ring and are bailing BEFORE the
    // peer answered (_connecting still true), tell the server to cancel the
    // invite so the callee's ringing screen auto-dismisses. If the peer had
    // already joined, this is a normal end — don't cancel.
    //
    // Kicked off HERE (first, so the POST is on the wire immediately) but
    // AWAITED at the end of teardown — the socket/pc/renderer shutdown below
    // takes real time, so the request overlaps with it and normally costs
    // nothing extra. It used to be plain `unawaited(...)`, which meant a fast
    // hang-up could pop the route with the request still queued behind the
    // token refresh inside respond()'s _headers().
    final Future<void>? cancelInFlight = _sendCancelIfNeeded();
    _noAnswerTimer?.cancel();
    _keepalive?.cancel();
    _reconnectTimer?.cancel();
    // Clear native CallKit / Telecom so a stale "accepted" entry can't
    // re-open /room on every cold start (seen on device as endless
    // "Connecting…" after force-stop / reinstall).
    final tid = widget.threadId;
    if (tid != null && tid.isNotEmpty) {
      unawaited(CallKitService.endCall(tid));
    }
    unawaited(CallKitService.endAllCalls());
    await _wsSub?.cancel();
    await _ws?.sink.close();
    await _pc?.close();
    _localStream?.getTracks().forEach((t) => t.stop());
    await _localRenderer.dispose();
    await _remoteRenderer.dispose();
    WakelockPlus.disable();
    // Last thing: make sure the callee actually learned we cancelled before we
    // let the caller's route pop. respond() already has its own 6s timeout and
    // swallows errors; the outer bound just stops a dead network from holding
    // the hang-up UI. Never rethrows — teardown must always complete.
    if (cancelInFlight != null) {
      try {
        await cancelInFlight.timeout(const Duration(seconds: 4));
      } catch (_) {/* best-effort — callee still expires on its own timeout */}
    }
  }

  /// POST the ring cancellation, at most once per call.
  ///
  /// Returns null when no cancel is warranted (we're the callee, there's no
  /// invite id, or the peer already answered — that's a normal end, not a
  /// cancel). Otherwise returns the in-flight future for the caller to await.
  ///
  /// Uses the [_signaling] captured in initState rather than ref.read(): this
  /// runs on the dispose() path too (back-press / swipe-away), where the
  /// provider scope may already be torn down.
  Future<void>? _sendCancelIfNeeded() {
    if (_cancelSent) return null;
    if (!widget.isHost) return null;
    if (!_connecting) return null; // peer answered → normal end
    final id = widget.inviteId;
    if (id == null || id.isEmpty) return null;
    final sig = _signaling;
    if (sig == null) return null;
    _cancelSent = true;
    return sig.respond(id, 'cancel').catchError((_) {});
  }

  Future<void> _hangup() async {
    await _teardown();
    if (mounted) context.pop();
  }

  /// Red end-call button: tears the call down and shows the WhatsApp-style
  /// end-of-call panel (Call again / Back to chat) instead of popping
  /// straight back to the chat.
  Future<void> _endCall({String reason = 'ended'}) async {
    await _teardown();
    if (mounted) {
      setState(() {
        _endReason = reason;
        _ended = true;
      });
    }
  }

  /// Re-invoke the same 1:1 call: re-ring the peer (thread-anchored calls
  /// only) and replace this screen with a fresh host room so all WebRTC
  /// resources are re-created cleanly.
  void _callAgain() {
    final threadId = widget.threadId;
    if (threadId == null) {
      _backToChat();
      return;
    }
    ref.read(callSignalingProvider).ring(threadId, widget.mode);
    final qp = <String, String>{
      'host': 'true',
      'mode': widget.mode,
      'threadId': threadId,
      if (widget.peerName != null && widget.peerName!.isNotEmpty)
        'peerName': widget.peerName!,
      if (widget.peerAvatar != null && widget.peerAvatar!.isNotEmpty)
        'peerAvatar': widget.peerAvatar!,
    };
    final uri = Uri(path: '/room', queryParameters: qp);
    context.pushReplacement(uri.toString());
  }

  void _backToChat() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/chats');
    }
  }

  /// Full-screen QR of the join link so someone across the table can scan to
  /// join instantly (InviteScreen's scanner reads this link or the bare code).
  void _showQr() {
    if (!_isShareableCode) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Invite others'),
          content: Text(
            widget.threadId != null
                ? 'This is a private 1:1 chat call. To invite someone else, '
                    'start a New meeting from Calls and share the 6-character '
                    'code or QR — or add them to this chat first and call from there.'
                : 'No shareable join code for this call yet. Start a New meeting '
                    'from the Calls tab to get a 6-character code and QR.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Scan to join',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF12253F))),
              const SizedBox(height: 4),
              const Text('Point the other phone’s INTERACT scanner here',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 16),
              QrImageView(
                data: _joinLink,
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square, color: Color(0xFF0D4A5C)),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF12253F)),
              ),
              const SizedBox(height: 16),
              Text(_code,
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 6,
                      color: Color(0xFF0D4A5C))),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      _shareCode();
                      Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share link'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _shareCode() async {
    if (!_isShareableCode) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No 6-character invite code on this 1:1 call. Use New meeting to share a QR.',
          ),
        ),
      );
      return;
    }
    final url = _joinLink;
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
    _flashTimer?.cancel();
    _noAnswerTimer?.cancel();
    _inviteStatusTimer?.cancel();
    try {
      ref
          .read(callSignalingProvider)
          .missedWhileBusy
          .removeListener(_onMissedWhileBusy);
      ref.read(callSignalingProvider).setInCall(false);
    } catch (_) {/* provider may already be disposed */}
    _hangup();
    super.dispose();
  }

  /// Peer avatar (network image or initial) reused by the calling overlay
  /// and the end-of-call panel.
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
          : Text(
              initial,
              style: TextStyle(
                fontSize: radius * 0.8,
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
    );
  }

  /// WhatsApp-style outgoing "Calling <peer>…" overlay shown until the peer
  /// joins. The persistent red end button in the bottom controls doubles as
  /// the cancel affordance while this is up.
  Widget _buildCallingOverlay() {
    final name = (widget.peerName ?? '').trim();
    final isCalling = widget.isHost;
    final label = isCalling
        ? (name.isEmpty ? 'Calling…' : 'Calling $name…')
        : (name.isEmpty ? 'Connecting…' : 'Connecting to $name…');
    final showAvatar =
        widget.peerName != null || widget.peerAvatar != null;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (showAvatar) ...[
          _peerAvatar(48),
          const SizedBox(height: 20),
        ],
        Text(
          label,
          style: const TextStyle(
              color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          isCalling ? 'Ringing…' : 'Waiting for the other side…',
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 24),
        const CircularProgressIndicator(color: Colors.white),
        const SizedBox(height: 32),
        // Always-visible cancel while connecting — independent of the bottom
        // controls row (which can be clipped on narrow screens). Host cancels
        // (remote-cancels the callee's ring via _teardown); callee just leaves.
        SizedBox(
          width: 200,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () => _endCall(reason: 'cancelled'),
            icon: const Icon(Icons.call_end),
            label: Text(isCalling ? 'Cancel' : 'End'),
          ),
        ),
      ],
    );
  }

  /// End-of-call panel: "Call again" (thread-anchored calls) + "Back to chat".
  Widget _buildEndedScreen(BuildContext context) {
    final name = (widget.peerName ?? '').trim();
    final canCallAgain = widget.threadId != null;
    final title = switch (_endReason) {
      'no_answer' => name.isEmpty ? 'No answer' : '$name didn’t answer',
      'busy' => name.isEmpty ? 'Busy' : '$name is on another call',
      'declined' => name.isEmpty ? 'Call declined' : '$name declined',
      'cancelled' => 'Call cancelled',
      _ => 'Call ended',
    };
    return Scaffold(
      backgroundColor: const Color(0xFF0D2A33),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: Column(
            children: [
              const Spacer(),
              _peerAvatar(56),
              const SizedBox(height: 24),
              Text(
                name.isEmpty ? 'INTERACT call' : name,
                style: const TextStyle(
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(title,
                  style: const TextStyle(fontSize: 15, color: Colors.white70)),
              const Spacer(),
              if (canCallAgain)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF2E7D32),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _callAgain,
                    icon: const Icon(Icons.call),
                    label: const Text('Call again'),
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _backToChat,
                  child: const Text('Back to chat'),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Post-call panel (Call again / Back to chat) — rendered as a fully
    // self-contained screen that never references the (now-disposed) video
    // renderers, so tapping End is always safe.
    if (_ended) return _buildEndedScreen(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Background: remote video once it arrives; otherwise, while still
            // connecting on a VIDEO call, show the caller's OWN camera preview
            // full-screen (mirrored) so they can see what they're about to
            // show — not a black screen. Falls back to black.
            Positioned.fill(
              child: _remoteRenderer.srcObject != null
                  ? RTCVideoView(_remoteRenderer,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                  : (_connecting &&
                          _videoOn &&
                          _localRenderer.srcObject != null)
                      ? RTCVideoView(_localRenderer,
                          mirror: true,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)
                      : Container(color: Colors.black),
            ),
            // Connecting overlay (label + spinner + cancel) on top of whatever
            // background is showing, with a scrim so the text stays legible
            // over the live camera preview.
            if (_error != null)
              Positioned.fill(
                child: Center(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.white)),
                ),
              )
            else if (_connecting)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: _buildCallingOverlay(),
                ),
              ),
            // Local PIP (top-right) — only once connected; while connecting the
            // preview is already shown full-screen above.
            if (_videoOn && !_connecting)
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
            // Peer raised-hand badge (top-center)
            if (_peerHand)
              Positioned(
                top: 84,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('✋', style: TextStyle(fontSize: 18)),
                        SizedBox(width: 8),
                        Text('raised a hand', style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  ),
                ),
              ),
            // Emoji reaction flash (center, non-interactive)
            if (_flashEmoji != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Text(_flashEmoji!, style: const TextStyle(fontSize: 110)),
                  ),
                ),
              ),
            // Room / peer chip (top-left) — never show raw thread UUIDs.
            Positioned(
              top: 16,
              left: 16,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _isShareableCode ? _shareCode : _showQr,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isShareableCode ? Icons.share : Icons.person_outline,
                          color: Colors.white70,
                          size: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _connecting && !_isShareableCode && (widget.peerName == null)
                              ? '······'
                              : _headerLabel,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            letterSpacing: _isShareableCode ? 2 : 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Second-caller busy banner (someone rang while we were already on a call)
            if (_busyBanner != null)
              Positioned(
                top: 56,
                left: 16,
                right: 16,
                child: Semantics(
                  liveRegion: true,
                  label: _busyBanner,
                  child: Material(
                    color: const Color(0xFFBE9A5F),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.phone_missed, color: Color(0xFF12253F), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _busyBanner!,
                              style: const TextStyle(
                                color: Color(0xFF12253F),
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
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
              // Scale the whole control row DOWN to fit narrow screens so the
              // red end-call button (last child) is never clipped off the
              // right edge — the "no cancel button" bug on the A23 (fixed).
              child: FittedBox(
                fit: BoxFit.scaleDown,
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
                    icon: Icons.front_hand,
                    color: _handRaised ? const Color(0xFFBE9A5F) : Colors.white,
                    bg: Colors.black54,
                    onTap: _toggleHand,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: Icons.emoji_emotions_outlined,
                    color: Colors.white,
                    bg: Colors.black54,
                    onTap: _showReactionPicker,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: Icons.person_add_alt_1,
                    color: Colors.white,
                    bg: Colors.black54,
                    onTap: _showQr,
                  ),
                  const SizedBox(width: 16),
                  _CtrlButton(
                    icon: Icons.call_end,
                    color: Colors.white,
                    bg: Colors.red,
                    onTap: () => _endCall(),
                  ),
                ],
                ),
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
