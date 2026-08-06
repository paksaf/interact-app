// SPDX-License-Identifier: AGPL-3.0
//
// LAN service — Bonsoir mDNS discovery + TCP text transport for INTERACT
// offline mode (Phase 1.5 → 2). Peers on the same Wi‑Fi exchange newline-
// delimited UTF-8 chat without internet. WebRTC 1:1 still uses the cloud
// signal path; LAN text is the offline differentiator that needs no TURN.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

// unawaited from dart:async

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mesh_cloud_bridge.dart';

const _kServiceType = '_interact-lan._tcp';

final lanServiceProvider = Provider<LanService>((ref) => LanService());

class LanPeer {
  LanPeer({
    required this.peerId,
    required this.displayName,
    required this.host,
    required this.port,
  });
  final String peerId;
  final String displayName;
  final String host;
  final int port;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LanPeer && other.peerId == peerId);
  @override
  int get hashCode => peerId.hashCode;
}

class LanTextMessage {
  LanTextMessage({
    required this.fromPeerId,
    required this.fromName,
    required this.body,
    required this.at,
    this.isMine = false,
  });
  final String fromPeerId;
  final String fromName;
  final String body;
  final DateTime at;
  final bool isMine;
}

class LanService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  ServerSocket? _server;
  final _peersController = StreamController<List<LanPeer>>.broadcast();
  final _messagesController = StreamController<LanTextMessage>.broadcast();
  final Map<String, LanPeer> _peers = {};
  String _peerId = '';
  String _displayName = '';

  Stream<List<LanPeer>> get peersStream => _peersController.stream;
  Stream<LanTextMessage> get messages => _messagesController.stream;
  List<LanPeer> get peers => _peers.values.toList();

  bool get isRunning => _server != null;

  /// Start TCP listener + mDNS advertise/discover. Idempotent.
  Future<void> start({
    required String peerId,
    required String displayName,
  }) async {
    _peerId = peerId;
    _displayName = displayName;

    if (_server == null) {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      _server!.listen(_onInboundSocket);
    }
    final port = _server!.port;

    if (_broadcast == null) {
      final service = BonsoirService(
        name: 'INTERACT-${peerId.substring(0, peerId.length.clamp(0, 8))}',
        type: _kServiceType,
        port: port,
        attributes: {
          'peerId': peerId,
          'displayName': displayName,
          'app': 'interact',
        },
      );
      _broadcast = BonsoirBroadcast(service: service);
      await _broadcast!.ready;
      await _broadcast!.start();
    }

    if (_discovery == null) {
      _discovery = BonsoirDiscovery(type: _kServiceType);
      await _discovery!.ready;
      _discovery!.eventStream?.listen(_onDiscoveryEvent);
      await _discovery!.start();
    }
  }

  Future<void> stop() async {
    await _broadcast?.stop();
    await _discovery?.stop();
    await _server?.close();
    _broadcast = null;
    _discovery = null;
    _server = null;
    _peers.clear();
    _peersController.add(const []);
  }

  /// Send a short UTF-8 text line to [peer] over TCP.
  Future<void> sendText(LanPeer peer, String text) async {
    final body = text.trim();
    if (body.isEmpty) return;
    final payload = jsonEncode({
      't': 'chat',
      'from': _peerId,
      'name': _displayName,
      'body': body,
      'at': DateTime.now().toIso8601String(),
    });
    Socket? sock;
    try {
      sock = await Socket.connect(peer.host, peer.port,
          timeout: const Duration(seconds: 4));
      sock.write('$payload\n');
      await sock.flush();
      _messagesController.add(LanTextMessage(
        fromPeerId: _peerId,
        fromName: _displayName,
        body: body,
        at: DateTime.now(),
        isMine: true,
      ));
    } finally {
      await sock?.close();
    }
  }

  void _onInboundSocket(Socket sock) {
    utf8.decoder.bind(sock).transform(const LineSplitter()).listen((line) {
      if (line.trim().isEmpty) return;
      try {
        final m = jsonDecode(line) as Map<String, dynamic>;
        if (m['t'] != 'chat') return;
        final from = (m['from'] as String?) ?? '';
        if (from.isEmpty || from == _peerId) return;
        final body = (m['body'] as String?) ?? '';
        _messagesController.add(LanTextMessage(
          fromPeerId: from,
          fromName: (m['name'] as String?) ?? from,
          body: body,
          at: DateTime.tryParse(m['at'] as String? ?? '') ?? DateTime.now(),
        ));
        // Bridge talk:-prefixed LAN frames into cloud when online.
        unawaited(MeshCloudBridge.instance.ingestLanBody(body));
      } catch (_) {/* ignore malformed */}
    });
  }

  void _onDiscoveryEvent(BonsoirDiscoveryEvent event) {
    final s = event.service;
    if (s == null) return;
    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      s.resolve(_discovery!.serviceResolver);
    } else if (event.type ==
        BonsoirDiscoveryEventType.discoveryServiceResolved) {
      final attrs = s.attributes;
      final peerId = attrs['peerId'];
      if (peerId == null || peerId.isEmpty || peerId == _peerId) return;
      final host = (s as ResolvedBonsoirService).host ?? '';
      if (host.isEmpty) return;
      _peers[peerId] = LanPeer(
        peerId: peerId,
        displayName: attrs['displayName'] ?? peerId,
        host: host,
        port: s.port,
      );
      _peersController.add(_peers.values.toList());
    } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      final attrs = s.attributes;
      final peerId = attrs['peerId'];
      if (peerId != null) _peers.remove(peerId);
      _peersController.add(_peers.values.toList());
    }
  }

  void dispose() {
    stop();
    _peersController.close();
    _messagesController.close();
  }
}
