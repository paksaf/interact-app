// SPDX-License-Identifier: AGPL-3.0
//
// LAN-offline walkie — Phase 1 of the offline-comms workstream.
// Design: docs/changes-plans/TALK_FEATURES_ROADMAP_2026-08-27.md §14.
//
// The real field case: everyone is on the site router's Wi-Fi and the router
// has NO uplink. LiveKit is unreachable, the cloud signaling relay is
// unreachable, TURN is unreachable — but the phones can all see each other.
//
// Phase 1 makes ONE phone the host. It runs a tiny in-app WebSocket relay
// and advertises itself over mDNS; the others discover it and connect. The
// relay speaks the EXACT SAME protocol as the deployed cloud relay (the
// gotcha-#61 shapes below), so the existing WebRTC client in
// meeting_room_screen.dart works against it unchanged — only the URL differs.
//
//   client → relay : join {roomId,userId,name,role}
//                    offer  {target, payload:{sdp,type}}
//                    answer {target, payload:{sdp,type}}
//                    ice-candidate {target, payload:{candidate,sdpMid,sdpMLineIndex}}
//                    ping
//   relay → client : joined      {peers:[{userId,name}]}   ← members ALREADY in
//                    peer-joined {peer:{userId,name}}
//                    peer-left   {userId}
//                    offer/answer/ice-candidate {from, payload}   (routed)
//                    pong
//                    error {error}
//
// Join order decides who offers — the peer that finds a non-empty
// `joined.peers` is the offerer. That rule lives in the client and is why the
// relay MUST report existing members and MUST NOT reorder joins.
//
// Media is plain WebRTC with host candidates only: same subnet, no STUN, no
// TURN, no internet. Phase 2 (BLE mesh voice, no network at all) stays in §4.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

/// mDNS service type. Distinct from `_interact-lan._tcp` (LanService's
/// text transport) — a walkie host is a different capability and joiners
/// must not confuse the two.
const String kLanWalkieServiceType = '_interact-talk._tcp';

/// mDNS attribute keys. Values are always strings (Bonsoir contract).
const String _kAttrCode = 'code';
const String _kAttrHost = 'hostName';
const String _kAttrApp = 'app';
const String _kAttrVersion = 'v';
const String _kAppTag = 'interact-talk';

/// A walkie channel someone on this Wi-Fi is hosting.
@immutable
class LanWalkieChannel {
  const LanWalkieChannel({
    required this.code,
    required this.hostName,
    required this.host,
    required this.port,
  });

  /// Channel code the host typed ("WALKIE1"). Upper-cased for display.
  final String code;

  /// Display name of the hosting device's owner.
  final String hostName;

  /// LAN address of the host phone (IPv4 literal from mDNS resolution).
  final String host;
  final int port;

  /// Signaling URL for [MeetingRoomScreen]'s client. Plain `ws://` — this
  /// is a same-subnet hop with no CA on the network to issue a cert for a
  /// phone's DHCP address, and the media itself is DTLS-SRTP regardless.
  String get wsUrl => 'ws://$host:$port/ws';

  /// Room id used in the `join` frame. Namespaced so a LAN room can never
  /// be mistaken for a cloud `talk:CODE` room in logs.
  String get roomId => 'lan:$code';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LanWalkieChannel &&
          other.host == host &&
          other.port == port &&
          other.code == code);

  @override
  int get hashCode => Object.hash(code, host, port);
}

/// Host + discovery for same-Wi-Fi walkie channels.
///
/// One instance per app (singleton): mDNS broadcast and the relay socket are
/// process-wide resources, and hosting twice would advertise two ports for
/// one device.
class LanWalkieService {
  LanWalkieService._();
  static final LanWalkieService instance = LanWalkieService._();

  // ── Host side ──────────────────────────────────────────────────────
  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  final _LanSignalRelay _relay = _LanSignalRelay();
  String _hostedCode = '';

  bool get isHosting => _server != null;
  String get hostedCode => _hostedCode;
  int? get hostedPort => _server?.port;

  /// Number of devices currently connected to our relay (excludes nobody —
  /// the host's own client connects over loopback like any other peer).
  int get connectedPeers => _relay.memberCount;

  /// Fires whenever the relay's membership changes, so a hosting UI can show
  /// "2 devices connected" without polling.
  Stream<int> get peerCount => _relay.peerCount;

  /// Start the relay + advertise it. Idempotent for the same [code]; a
  /// different code restarts the broadcast so joiners see the new name.
  ///
  /// Returns the port the relay bound to. Throws [SocketException] if the
  /// platform refuses the bind (rare — port 0 is an ephemeral pick).
  Future<int> startHost({
    required String code,
    required String hostName,
  }) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      throw ArgumentError.value(code, 'code', 'channel code must not be empty');
    }
    if (isHosting && _hostedCode == normalized) return _server!.port;
    if (isHosting) await stopHost();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _hostedCode = normalized;
    server.listen(_onRequest, onError: (Object e) {
      debugPrint('[lan-walkie] server error: $e');
    });

    // Advertise. Name must be unique on the network or the OS appends " (2)";
    // code + a short random suffix keeps two hosts of the same channel apart.
    final suffix = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    final service = BonsoirService(
      name: 'INTERACT $normalized $suffix',
      type: kLanWalkieServiceType,
      port: server.port,
      attributes: {
        _kAttrCode: normalized,
        _kAttrHost: hostName,
        _kAttrApp: _kAppTag,
        _kAttrVersion: '1',
      },
    );
    final broadcast = BonsoirBroadcast(service: service);
    _broadcast = broadcast;
    await broadcast.ready;
    await broadcast.start();

    debugPrint('[lan-walkie] hosting $normalized on port ${server.port}');
    return server.port;
  }

  Future<void> stopHost() async {
    try {
      await _broadcast?.stop();
    } catch (e) {
      debugPrint('[lan-walkie] broadcast stop failed: $e');
    }
    _broadcast = null;
    await _relay.closeAll();
    try {
      await _server?.close(force: true);
    } catch (e) {
      debugPrint('[lan-walkie] server close failed: $e');
    }
    _server = null;
    _hostedCode = '';
  }

  /// The channel record for our OWN hosted room, so the host's client can
  /// join its own relay through the same code path a joiner uses.
  /// Loopback — never leaves the device, so it works even with Wi-Fi's
  /// local-network permission still pending on iOS.
  LanWalkieChannel? get selfChannel {
    final s = _server;
    if (s == null) return null;
    return LanWalkieChannel(
      code: _hostedCode,
      hostName: 'This device',
      host: '127.0.0.1',
      port: s.port,
    );
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path != '/ws' ||
        !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..statusCode = HttpStatus.notFound
        ..write('interact-lan-walkie');
      await req.response.close();
      return;
    }
    try {
      final socket = await WebSocketTransformer.upgrade(req);
      _relay.accept(socket);
    } catch (e) {
      debugPrint('[lan-walkie] upgrade failed: $e');
    }
  }

  // ── Discovery side ─────────────────────────────────────────────────
  BonsoirDiscovery? _discovery;
  final Map<String, LanWalkieChannel> _found = {};
  final StreamController<List<LanWalkieChannel>> _channelsCtrl =
      StreamController<List<LanWalkieChannel>>.broadcast();

  /// Walkie channels seen on this Wi-Fi. Emits the full list on every change.
  Stream<List<LanWalkieChannel>> get channels => _channelsCtrl.stream;

  List<LanWalkieChannel> get discovered => _found.values.toList(growable: false);

  Future<void> startDiscovery() async {
    if (_discovery != null) return;
    final d = BonsoirDiscovery(type: kLanWalkieServiceType);
    _discovery = d;
    await d.ready;
    d.eventStream?.listen(_onDiscoveryEvent);
    await d.start();
  }

  Future<void> stopDiscovery() async {
    try {
      await _discovery?.stop();
    } catch (e) {
      debugPrint('[lan-walkie] discovery stop failed: $e');
    }
    _discovery = null;
    _found.clear();
    if (!_channelsCtrl.isClosed) _channelsCtrl.add(const []);
  }

  void _onDiscoveryEvent(BonsoirDiscoveryEvent event) {
    final s = event.service;
    if (s == null) return;
    switch (event.type) {
      case BonsoirDiscoveryEventType.discoveryServiceFound:
        s.resolve(_discovery!.serviceResolver);
        break;
      case BonsoirDiscoveryEventType.discoveryServiceResolved:
        final attrs = s.attributes;
        if (attrs[_kAttrApp] != _kAppTag) return; // not ours
        final code = attrs[_kAttrCode];
        if (code == null || code.isEmpty) return;
        final host = (s as ResolvedBonsoirService).host ?? '';
        if (host.isEmpty) return;
        // Our own broadcast comes back through discovery on most platforms.
        // Filter it: the host joins via [selfChannel] over loopback.
        if (isHosting && s.port == _server?.port) return;
        _found['${s.name}|$host|${s.port}'] = LanWalkieChannel(
          code: code,
          hostName: attrs[_kAttrHost] ?? 'Nearby device',
          host: host,
          port: s.port,
        );
        _emit();
        break;
      case BonsoirDiscoveryEventType.discoveryServiceLost:
        _found.removeWhere((_, c) => c.code == s.attributes[_kAttrCode]);
        _emit();
        break;
      default:
        break;
    }
  }

  void _emit() {
    if (_channelsCtrl.isClosed) return;
    _channelsCtrl.add(discovered);
  }

  Future<void> dispose() async {
    await stopHost();
    await stopDiscovery();
    await _channelsCtrl.close();
  }
}

// ── The relay ────────────────────────────────────────────────────────

class _Member {
  _Member(this.userId, this.name, this.socket);
  final String userId;
  final String name;
  final WebSocket socket;
}

/// In-app twin of the deployed signaling relay. Rooms live only as long as
/// someone is in them; nothing is persisted and nothing is authenticated —
/// being on the Wi-Fi IS the credential in Phase 1, exactly like a physical
/// walkie-talkie handset on a channel. (An out-of-band channel code keeps
/// honest neighbours out; it is not a security boundary, and the §14 note
/// about a shared-secret handshake stays open for Phase 1.5.)
class _LanSignalRelay {
  final Map<String, Map<String, _Member>> _rooms = {};
  final Map<WebSocket, _Member> _bySocket = {};
  final Map<WebSocket, String> _roomOf = {};
  final StreamController<int> _peerCountCtrl =
      StreamController<int>.broadcast();

  Stream<int> get peerCount => _peerCountCtrl.stream;
  int get memberCount => _bySocket.length;

  void accept(WebSocket socket) {
    socket.listen(
      (dynamic raw) => _onFrame(socket, raw),
      onDone: () => _onGone(socket),
      onError: (Object e) {
        debugPrint('[lan-walkie] socket error: $e');
        _onGone(socket);
      },
      cancelOnError: true,
    );
  }

  void _send(WebSocket s, Map<String, dynamic> msg) {
    try {
      s.add(jsonEncode(msg));
    } catch (e) {
      debugPrint('[lan-walkie] send failed: $e');
    }
  }

  void _onFrame(WebSocket socket, dynamic raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      _send(socket, {'type': 'error', 'error': 'Malformed frame'});
      return;
    }
    final type = m['type'] as String?;

    switch (type) {
      case 'ping':
        _send(socket, {'type': 'pong'});
        return;

      case 'join':
        final roomId = (m['roomId'] ?? '').toString();
        final userId = (m['userId'] ?? '').toString();
        if (roomId.isEmpty || userId.isEmpty) {
          _send(socket, {'type': 'error', 'error': 'join needs roomId + userId'});
          return;
        }
        final name = (m['name'] ?? 'INTERACT').toString();
        final room = _rooms.putIfAbsent(roomId, () => <String, _Member>{});

        // Existing members, computed BEFORE we add ourselves — the client
        // reads a non-empty list as "I joined second, so I offer".
        final peers = [
          for (final p in room.values) {'userId': p.userId, 'name': p.name},
        ];

        final me = _Member(userId, name, socket);
        room[userId] = me;
        _bySocket[socket] = me;
        _roomOf[socket] = roomId;

        _send(socket, {'type': 'joined', 'peers': peers});
        for (final p in room.values) {
          if (p.userId == userId) continue;
          _send(p.socket, {
            'type': 'peer-joined',
            'peer': {'userId': userId, 'name': name},
          });
        }
        _peerCountCtrl.add(_bySocket.length);
        debugPrint('[lan-walkie] $userId joined $roomId (${room.length} in room)');
        return;

      case 'offer':
      case 'answer':
      case 'ice-candidate':
        final me = _bySocket[socket];
        final roomId = _roomOf[socket];
        if (me == null || roomId == null) {
          _send(socket, {'type': 'error', 'error': 'join first'});
          return;
        }
        final target = m['target']?.toString();
        final room = _rooms[roomId];
        final dest = (target == null || room == null) ? null : room[target];
        if (dest == null) {
          // The cloud relay silently drops undeliverable frames; matching
          // that keeps client behaviour identical (it buffers and retries).
          debugPrint('[lan-walkie] drop $type → unknown target $target');
          return;
        }
        _send(dest.socket, {...m, 'from': me.userId});
        return;

      default:
        // Byte-for-byte the deployed relay's reply, because the client
        // logs it and the roadmap's gotcha #61 documents that exact string.
        _send(socket, {'type': 'error', 'error': 'Unknown message type: $type'});
    }
  }

  void _onGone(WebSocket socket) {
    final me = _bySocket.remove(socket);
    final roomId = _roomOf.remove(socket);
    if (me == null || roomId == null) return;
    final room = _rooms[roomId];
    if (room == null) return;
    room.remove(me.userId);
    for (final p in room.values) {
      _send(p.socket, {'type': 'peer-left', 'userId': me.userId});
    }
    if (room.isEmpty) _rooms.remove(roomId);
    _peerCountCtrl.add(_bySocket.length);
    debugPrint('[lan-walkie] ${me.userId} left $roomId');
  }

  Future<void> closeAll() async {
    for (final s in _bySocket.keys.toList()) {
      try {
        await s.close();
      } catch (_) {/* already gone */}
    }
    _bySocket.clear();
    _roomOf.clear();
    _rooms.clear();
    if (!_peerCountCtrl.isClosed) _peerCountCtrl.add(0);
  }
}
