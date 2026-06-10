// SPDX-License-Identifier: AGPL-3.0
//
// LAN service — Bonsoir mDNS discovery + broadcast for INTERACT's
// offline mode. Phase 1.5 (this file) ships the service-discovery
// layer. Phase 1.5 round 2 (next session) wires WebRTC direct
// peer-to-peer on top so calls/messages work with NO internet.
//
// Why this matters: no major competitor (WhatsApp / Zoom / Signal /
// Viber) does this. Briar and Jami do but lack Urdu STT and modern
// mobile UX. This is INTERACT's #1 differentiator per the
// research-backed PRD.
//
// Service type: `_interact-lan._tcp` (matches the PRD)
// TXT attributes: peerId + displayName so discovery surfaces enough
// info to render a contact tile before any TCP handshake happens.

import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const _kServiceType = '_interact-lan._tcp';
const _kPortPlaceholder = 0; // Bonsoir picks a free port at advertise time

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

class LanService {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  final _peersController = StreamController<List<LanPeer>>.broadcast();
  final Map<String, LanPeer> _peers = {};

  Stream<List<LanPeer>> get peersStream => _peersController.stream;
  List<LanPeer> get peers => _peers.values.toList();

  bool get isBroadcasting => _broadcast?.isReady ?? false;
  bool get isDiscovering => _discovery?.isReady ?? false;

  /// Start broadcasting our presence AND discovering peers.
  /// Idempotent — safe to call repeatedly.
  Future<void> start({
    required String peerId,
    required String displayName,
  }) async {
    if (_broadcast == null) {
      final service = BonsoirService(
        name: 'INTERACT-${peerId.substring(0, peerId.length.clamp(0, 8))}',
        type: _kServiceType,
        port: _kPortPlaceholder,
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
    _broadcast = null;
    _discovery = null;
    _peers.clear();
    _peersController.add(const []);
  }

  void _onDiscoveryEvent(BonsoirDiscoveryEvent event) {
    final s = event.service;
    if (s == null) return;
    if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      // Need attributes — fire resolution
      s.resolve(_discovery!.serviceResolver);
    } else if (event.type ==
        BonsoirDiscoveryEventType.discoveryServiceResolved) {
      final attrs = s.attributes;
      final peerId = attrs['peerId'];
      if (peerId == null || peerId.isEmpty) return;
      final host = (s as ResolvedBonsoirService).host ?? '';
      final port = s.port;
      _peers[peerId] = LanPeer(
        peerId: peerId,
        displayName: attrs['displayName'] ?? peerId,
        host: host,
        port: port,
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
    _broadcast?.stop();
    _discovery?.stop();
    _peersController.close();
  }
}
