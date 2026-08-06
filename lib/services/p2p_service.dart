// SPDX-License-Identifier: AGPL-3.0
//
// P2P service — no-router phone↔phone RF for INTERACT Talk v1.
//   • Android: Wi‑Fi Direct via `nearby_service`
//   • iOS/macOS: Multipeer Connectivity (MPC) via `nearby_service`
// Same-Wi‑Fi Bonsoir+TCP remains in [LanService]. Cross-OS P2P
// (Android↔iOS) is not supported by the plugin — use same-Wi‑Fi LAN.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nearby_service/nearby_service.dart';

final p2pServiceProvider = Provider<P2pService>((ref) => P2pService());

enum P2pDarwinRole { browser, advertiser }

class P2pPeer {
  P2pPeer({required this.device});
  final NearbyDevice device;
  String get id => device.info.id;
  String get displayName => device.info.displayName;
  bool get isConnected => device.status.isConnected;
}

class P2pTextMessage {
  P2pTextMessage({
    required this.fromName,
    required this.body,
    required this.at,
    this.isMine = false,
  });
  final String fromName;
  final String body;
  final DateTime at;
  final bool isMine;
}

class P2pService {
  NearbyService? _nearby;
  StreamSubscription? _peersSub;
  StreamSubscription? _connectedSub;
  NearbyDevice? _connected;
  String _displayName = 'INTERACT';
  bool _running = false;

  final _peersController = StreamController<List<P2pPeer>>.broadcast();
  final _messagesController = StreamController<P2pTextMessage>.broadcast();
  final Map<String, NearbyDevice> _peers = {};

  Stream<List<P2pPeer>> get peersStream => _peersController.stream;
  Stream<P2pTextMessage> get messages => _messagesController.stream;
  List<P2pPeer> get peers =>
      _peers.values.map((d) => P2pPeer(device: d)).toList();
  NearbyDevice? get connectedDevice => _connected;
  bool get isRunning => _running;
  bool get supportsPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Start discovery. On Darwin, [darwinRole] selects Browser vs Advertiser
  /// (MPC requires complementary roles on the two phones).
  Future<void> start({
    required String displayName,
    P2pDarwinRole darwinRole = P2pDarwinRole.browser,
  }) async {
    if (!supportsPlatform) {
      throw UnsupportedError(
        'Wi‑Fi Direct / MPC requires Android or iOS (not web/desktop Linux).',
      );
    }
    _displayName = displayName;
    _nearby ??= NearbyService.getInstance();

    await _nearby!.initialize(
      data: NearbyInitializeData(darwinDeviceName: displayName),
    );

    if (Platform.isAndroid) {
      final granted = await _nearby!.android?.requestPermissions() ?? false;
      if (!granted) {
        throw StateError(
          'Wi‑Fi Direct needs location / nearby-devices permission.',
        );
      }
      final wifiOn = await _nearby!.android?.checkWifiService() ?? false;
      if (!wifiOn) {
        await _nearby!.openServicesSettings();
        throw StateError('Turn on Wi‑Fi, then retry Direct mode.');
      }
    } else {
      _nearby!.darwin?.setIsBrowser(
        value: darwinRole == P2pDarwinRole.browser,
      );
    }

    final ok = await _nearby!.discover();
    if (!ok) {
      throw StateError('P2P discovery failed to start.');
    }

    await _peersSub?.cancel();
    _peersSub = _nearby!.getPeersStream().listen((list) {
      _peers
        ..clear()
        ..addEntries(list.map((d) => MapEntry(d.info.id, d)));
      _peersController.add(peers);
    });

    _running = true;
  }

  Future<void> stop() async {
    await _peersSub?.cancel();
    await _connectedSub?.cancel();
    _peersSub = null;
    _connectedSub = null;
    try {
      await _nearby?.stopDiscovery();
    } catch (_) {/* ignore */}
    try {
      final id = _connected?.info.id;
      if (id != null) {
        await _nearby?.disconnectById(id);
      }
    } catch (_) {/* ignore */}
    _connected = null;
    _peers.clear();
    _peersController.add(const []);
    _running = false;
  }

  Future<void> connect(NearbyDevice device) async {
    final nearby = _nearby;
    if (nearby == null) return;

    final ok = await nearby.connectById(device.info.id);
    if (!ok) {
      throw StateError('Could not connect to ${device.info.displayName}');
    }

    await _connectedSub?.cancel();
    _connectedSub =
        nearby.getConnectedDeviceStreamById(device.info.id).listen((event) {
      _connected = event;
      if (event == null || !(event.status.isConnected)) {
        _connected = null;
      }
    });

    await nearby.startCommunicationChannel(
      NearbyCommunicationChannelData(
        device.info.id,
        messagesListener: NearbyServiceMessagesListener(
          onData: (message) {
            final content = message.content;
            if (content is! NearbyMessageTextRequest) return;
            _messagesController.add(P2pTextMessage(
              fromName: message.sender.displayName,
              body: content.value,
              at: DateTime.now(),
            ));
          },
        ),
      ),
    );
    _connected = device;
  }

  Future<void> sendText(String text) async {
    final body = text.trim();
    final device = _connected;
    final nearby = _nearby;
    if (body.isEmpty || device == null || nearby == null) {
      throw StateError('Connect to a peer before sending.');
    }
    await nearby.send(
      OutgoingNearbyMessage(
        content: NearbyMessageTextRequest.create(value: body),
        receiver: device.info,
      ),
    );
    _messagesController.add(P2pTextMessage(
      fromName: _displayName,
      body: body,
      at: DateTime.now(),
      isMine: true,
    ));
  }

  void dispose() {
    stop();
    _peersController.close();
    _messagesController.close();
  }
}
