// SPDX-License-Identifier: AGPL-3.0
//
// LiveKit room controller — the realtime engine behind INTERACT Talk's
// conferences / townhalls. Wraps livekit_client's [Room] in a
// [ChangeNotifier] the TV UI can rebuild from.
//
// Why LiveKit (not the mesh in meeting_room_screen.dart): an SFU scales to
// many participants (townhalls), which P2P mesh cannot. The same LiveKit
// server ExecOS uses (wss://livekit.interactpak.com) hosts these rooms, so
// a TV can join the very meeting an ExecOS user started.
//
// Full two-way by default: on connect we publish the TV camera + mic (unless
// the join role is listener). Host/moderator get mute-all + end-for-all,
// broadcast over the LiveKit data channel (peers act on receipt). True
// server-side force-mute is a follow-up via interact-connect RoomService.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import 'live_api.dart';

/// One renderable participant cell in the grid.
class LiveTile {
  LiveTile({
    required this.identity,
    required this.label,
    required this.isLocal,
    required this.isSpeaking,
    required this.audioMuted,
    required this.handRaised,
    this.videoTrack,
  });

  final String identity;
  final String label;
  final bool isLocal;
  final bool isSpeaking;
  final bool audioMuted;
  final bool handRaised;
  final VideoTrack? videoTrack;

  bool get hasVideo => videoTrack != null;
}

/// Data-channel message kinds (JSON over the LiveKit reliable channel).
class _Msg {
  static const hand = 'hand';
  static const muteAll = 'mute-all';
  static const end = 'end';
  static const role = 'role'; // promote/demote signal to a target identity
}

class LiveRoomController extends ChangeNotifier {
  LiveRoomController();

  Room? _room;
  EventsListener<RoomEvent>? _listener;

  bool _connecting = false;
  bool _connected = false;
  bool _leaving = false;
  bool _dropped = false;
  String? _error;
  bool _micOn = false;
  bool _camOn = false;
  bool _handRaised = false;
  bool _frontCamera = true;
  bool _isHost = false;
  String _role = 'speaker';
  String _roomCode = '';

  /// Identities of remote participants whose hand is currently raised.
  final Set<String> _remoteHands = <String>{};

  // ── Public state ───────────────────────────────────────────────────
  bool get connecting => _connecting;
  bool get connected => _connected;
  /// True when the SFU connection dropped without the user leaving — the UI
  /// should offer a reconnect. (LiveKit auto-retries transient blips; this
  /// fires only on a full disconnect.)
  bool get dropped => _dropped;
  String? get error => _error;
  bool get micOn => _micOn;
  bool get camOn => _camOn;
  bool get handRaised => _handRaised;
  bool get isHost => _isHost;
  String get role => _role;
  String get roomCode => _roomCode;
  int get raisedHandCount =>
      _remoteHands.length + (_handRaised ? 1 : 0);

  /// All tiles (local first), ready to render.
  List<LiveTile> get tiles {
    final room = _room;
    if (room == null) return const [];
    final out = <LiveTile>[];

    final lp = room.localParticipant;
    if (lp != null) {
      out.add(LiveTile(
        identity: lp.identity,
        label: '${_displayName(lp)} (You)',
        isLocal: true,
        isSpeaking: lp.isSpeaking,
        audioMuted: !_micOn,
        handRaised: _handRaised,
        videoTrack: _videoOf(lp),
      ));
    }
    for (final p in room.remoteParticipants.values) {
      out.add(LiveTile(
        identity: p.identity,
        label: _displayName(p),
        isLocal: false,
        isSpeaking: p.isSpeaking,
        audioMuted: _isAudioMuted(p),
        handRaised: _remoteHands.contains(p.identity),
        videoTrack: _videoOf(p),
      ));
    }
    return out;
  }

  // ── Lifecycle ──────────────────────────────────────────────────────
  Future<void> connect(LiveJoin join) async {
    _connecting = true;
    _error = null;
    _dropped = false;
    _leaving = false;
    _isHost = join.isHost;
    _role = join.role;
    _roomCode = join.roomCode;
    notifyListeners();

    try {
      final room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
        ),
      );
      _room = room;

      final listener = room.createListener();
      _listener = listener;
      _wireEvents(listener);
      // Room is itself a ChangeNotifier (participant/track/speaker changes).
      room.addListener(_onRoomChanged);

      await room.connect(join.url, join.token);

      // Full two-way: publish camera + mic unless we joined as a listener.
      if (join.canPublish) {
        final lp = room.localParticipant;
        if (lp != null) {
          await lp.setCameraEnabled(true);
          await lp.setMicrophoneEnabled(true);
          _camOn = true;
          _micOn = true;
        }
      }

      _connected = true;
      _connecting = false;
      notifyListeners();
    } catch (e) {
      _error = _friendly(e);
      _connecting = false;
      _connected = false;
      notifyListeners();
    }
  }

  Future<void> leave() async {
    _leaving = true; // distinguishes intentional leave from a dropped link
    try {
      await _room?.localParticipant?.setCameraEnabled(false);
      await _room?.localParticipant?.setMicrophoneEnabled(false);
    } catch (_) {/* best effort */}
    await _teardown();
  }

  Future<void> _teardown() async {
    try {
      _room?.removeListener(_onRoomChanged);
      await _listener?.dispose();
      await _room?.disconnect();
      await _room?.dispose();
    } catch (_) {/* ignore */} finally {
      _listener = null;
      _room = null;
      _connected = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    // Fire-and-forget; the screen already awaits leave() before pop.
    _teardown();
    super.dispose();
  }

  // ── Local controls ─────────────────────────────────────────────────
  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    _micOn = !_micOn;
    await lp.setMicrophoneEnabled(_micOn);
    notifyListeners();
  }

  Future<void> toggleCamera() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    _camOn = !_camOn;
    await lp.setCameraEnabled(_camOn);
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final track = _localVideoTrack();
    if (track == null) return;
    _frontCamera = !_frontCamera;
    try {
      await track.setCameraPosition(
        _frontCamera ? CameraPosition.front : CameraPosition.back,
      );
    } catch (_) {/* some TVs have a single camera */}
    notifyListeners();
  }

  Future<void> raiseHand() => _setHand(true);
  Future<void> lowerHand() => _setHand(false);

  Future<void> _setHand(bool up) async {
    _handRaised = up;
    await _send({'t': _Msg.hand, 'up': up});
    notifyListeners();
  }

  // ── Host / moderator controls ──────────────────────────────────────
  /// Ask every non-host peer to mute. (Soft mute — peers self-mute on
  /// receipt. Hard server mute is a follow-up via interact-connect.)
  Future<void> muteAll() async {
    if (!_canModerate) return;
    await _send({'t': _Msg.muteAll});
  }

  /// End the session for everyone — broadcast then leave.
  Future<void> endForAll() async {
    if (!_canModerate) return;
    await _send({'t': _Msg.end});
    await leave();
  }

  bool get _canModerate => _isHost || _role == 'moderator' || _role == 'host';

  /// Tell a participant their publish grant changed (the server already
  /// flipped it via /moderate). The target client starts/stops publishing
  /// on receipt — this avoids relying on the LiveKit permission-event API.
  Future<void> broadcastRole(String targetIdentity, bool canPublish) async {
    await _send({'t': _Msg.role, 'target': targetIdentity, 'pub': canPublish});
  }

  // ── Data channel ───────────────────────────────────────────────────
  Future<void> _send(Map<String, dynamic> msg) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      await lp.publishData(
        utf8.encode(jsonEncode(msg)),
        reliable: true,
        topic: 'talk',
      );
    } catch (_) {/* non-fatal */}
  }

  void _onData(DataReceivedEvent event) {
    final from = event.participant?.identity;
    Map<String, dynamic> m;
    try {
      m = Map<String, dynamic>.from(jsonDecode(utf8.decode(event.data)) as Map);
    } catch (_) {
      return;
    }
    switch (m['t']) {
      case _Msg.hand:
        if (from == null) return;
        if (m['up'] == true) {
          _remoteHands.add(from);
        } else {
          _remoteHands.remove(from);
        }
        notifyListeners();
        break;
      case _Msg.muteAll:
        // A moderator asked everyone to mute. Honour it unless we moderate.
        if (!_canModerate && _micOn) {
          toggleMic();
        }
        break;
      case _Msg.end:
        leave();
        break;
      case _Msg.role:
        // A moderator promoted/demoted someone. If it's us, reflect it: the
        // server already changed our SFU grant, so start/stop publishing.
        final lp = _room?.localParticipant;
        if (lp != null && m['target'] == lp.identity) {
          _applyPublishGrant(m['pub'] == true);
        }
        break;
    }
  }

  Future<void> _applyPublishGrant(bool canPublish) async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    try {
      if (canPublish) {
        await lp.setMicrophoneEnabled(true);
        await lp.setCameraEnabled(true);
        _micOn = true;
        _camOn = true;
        _role = 'speaker';
      } else {
        await lp.setMicrophoneEnabled(false);
        await lp.setCameraEnabled(false);
        _micOn = false;
        _camOn = false;
        _role = 'listener';
      }
    } catch (_) {/* grant not yet propagated; user can retry mic manually */}
    notifyListeners();
  }

  // ── Event wiring ───────────────────────────────────────────────────
  void _wireEvents(EventsListener<RoomEvent> l) {
    l
      ..on<RoomDisconnectedEvent>((_) {
        _connected = false;
        _dropped = !_leaving; // unexpected drop → UI offers reconnect
        notifyListeners();
      })
      ..on<ParticipantConnectedEvent>((_) => notifyListeners())
      ..on<ParticipantDisconnectedEvent>((e) {
        _remoteHands.remove(e.participant.identity);
        notifyListeners();
      })
      ..on<TrackSubscribedEvent>((_) => notifyListeners())
      ..on<TrackUnsubscribedEvent>((_) => notifyListeners())
      ..on<TrackMutedEvent>((_) => notifyListeners())
      ..on<TrackUnmutedEvent>((_) => notifyListeners())
      ..on<ActiveSpeakersChangedEvent>((_) => notifyListeners())
      ..on<DataReceivedEvent>(_onData);
  }

  void _onRoomChanged() => notifyListeners();

  // ── Helpers ────────────────────────────────────────────────────────
  String _displayName(Participant p) {
    if (p.name.isNotEmpty) return p.name;
    // identity is "<userId>__<deviceSuffix>" — strip the suffix.
    final id = p.identity.split('__').first;
    return id.isEmpty ? 'Guest' : id;
  }

  /// Camera video (excludes screen-share so the grid shows faces, not the
  /// shared screen — that gets the dedicated [screenShareTile] presentation).
  VideoTrack? _videoOf(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source == TrackSource.screenShareVideo) continue;
      final t = pub.track;
      if (t is VideoTrack) return t;
    }
    return null;
  }

  VideoTrack? _screenShareOf(Participant p) {
    for (final pub in p.videoTrackPublications) {
      if (pub.source != TrackSource.screenShareVideo) continue;
      final t = pub.track;
      if (t is VideoTrack) return t;
    }
    return null;
  }

  /// The single active screen-share, if any participant is presenting. Used
  /// for the pinned presentation layout.
  LiveTile? get screenShareTile {
    final room = _room;
    if (room == null) return null;
    final all = <Participant>[
      if (room.localParticipant != null) room.localParticipant!,
      ...room.remoteParticipants.values,
    ];
    for (final p in all) {
      final ss = _screenShareOf(p);
      if (ss != null) {
        return LiveTile(
          identity: p.identity,
          label: '${_displayName(p)} — screen',
          isLocal: p == room.localParticipant,
          isSpeaking: false,
          audioMuted: true,
          handRaised: false,
          videoTrack: ss,
        );
      }
    }
    return null;
  }

  LocalVideoTrack? _localVideoTrack() {
    final lp = _room?.localParticipant;
    if (lp == null) return null;
    for (final pub in lp.videoTrackPublications) {
      final t = pub.track;
      if (t is LocalVideoTrack) return t;
    }
    return null;
  }

  bool _isAudioMuted(Participant p) {
    final pubs = p.audioTrackPublications;
    if (pubs.isEmpty) return true;
    return pubs.every((a) => a.muted);
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('Could not establish') || s.contains('Connect')) {
      return 'Couldn’t reach the live server. Check this device’s internet/DNS.';
    }
    return 'Live error: $s';
  }
}
