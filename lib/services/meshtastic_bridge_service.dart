// SPDX-License-Identifier: AGPL-3.0
//
// Meshtastic BLE adapter — official GATT via flutter_reactive_ble (BSD-3).
// Connect + want_config + FromRadio drain + MeshPacket UTF-8 TX (Phase 4 P1).
import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/meshtastic/meshtastic_packet_codec.dart';

final meshtasticBridgeServiceProvider =
    Provider<MeshtasticBridgeService>((ref) => MeshtasticBridgeService());

class MeshtasticUuids {
  static final service = Uuid.parse('6ba1b218-15a8-461f-9fa8-5dcae273eafd');
  static final toRadio = Uuid.parse('f75c76d2-129e-4dad-a1dd-7866124401e7');
  static final fromRadio = Uuid.parse('2c55e69e-4993-11ed-b878-0242ac120002');
  static final fromNum = Uuid.parse('ed9da18c-a800-4f66-a670-aa7547e34453');
}

class MeshtasticCandidate {
  MeshtasticCandidate({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;
}

class MeshtasticBridgeService {
  final _ble = FlutterReactiveBle();
  final _candidates = <String, MeshtasticCandidate>{};
  final _controller =
      StreamController<List<MeshtasticCandidate>>.broadcast();
  final _events = StreamController<String>.broadcast();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _fromNumSub;
  String? _deviceId;
  Characteristic? _toRadio;
  Characteristic? _fromRadio;
  bool _connected = false;

  Stream<List<MeshtasticCandidate>> get candidatesStream => _controller.stream;
  Stream<String> get events => _events.stream;
  List<MeshtasticCandidate> get candidates =>
      _candidates.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  bool get isConnected => _connected;
  String? get connectedName => _deviceId;

  static bool looksLikeMeshtastic(String name) {
    final n = name.toLowerCase();
    return n.contains('meshtastic') ||
        n.contains('t-beam') ||
        n.contains('t-echo') ||
        n.contains('rak4631');
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 8)}) async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    _candidates.clear();
    _controller.add(const []);
    await _scanSub?.cancel();
    _scanSub = _ble
        .scanForDevices(
          withServices: [MeshtasticUuids.service],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen((d) {
      final name = d.name.trim().isEmpty ? 'Meshtastic' : d.name.trim();
      if (!looksLikeMeshtastic(name) &&
          !d.serviceUuids.contains(MeshtasticUuids.service)) {
        return;
      }
      _candidates[d.id] = MeshtasticCandidate(
        id: d.id,
        name: name,
        rssi: d.rssi,
      );
      _controller.add(candidates);
    });
    await Future<void>.delayed(timeout);
    await stopScan();
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
  }

  Future<void> connect(MeshtasticCandidate c) async {
    await stopScan();
    await disconnect();
    final done = Completer<void>();
    _connSub = _ble
        .connectToDevice(
          id: c.id,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        try {
          await _ble.requestMtu(deviceId: c.id, mtu: 512);
        } catch (_) {}
        try {
          await _bind(c);
          if (!done.isCompleted) done.complete();
        } catch (e) {
          if (!done.isCompleted) done.completeError(e);
        }
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        _connected = false;
      }
    }, onError: (Object e) {
      if (!done.isCompleted) done.completeError(e);
    });
    await done.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _bind(MeshtasticCandidate c) async {
    await _ble.discoverAllServices(c.id);
    final services = await _ble.getDiscoveredServices(c.id);
    Characteristic? toRadio;
    Characteristic? fromRadio;
    Characteristic? fromNum;
    for (final s in services) {
      if (s.id != MeshtasticUuids.service) continue;
      for (final ch in s.characteristics) {
        if (ch.id == MeshtasticUuids.toRadio) toRadio = ch;
        if (ch.id == MeshtasticUuids.fromRadio) fromRadio = ch;
        if (ch.id == MeshtasticUuids.fromNum) fromNum = ch;
      }
    }
    if (toRadio == null || fromRadio == null || fromNum == null) {
      await disconnect();
      throw Exception('Meshtastic GATT incomplete (ToRadio/FromRadio/FromNum)');
    }

    await _fromNumSub?.cancel();
    _fromNumSub = fromNum.subscribe().listen((_) {
      unawaited(_drainFromRadio());
    });

    // ToRadio.want_config_id = 1 (protobuf field 3 varint).
    await toRadio.write(const [0x18, 0x01], withResponse: true);
    _toRadio = toRadio;
    _fromRadio = fromRadio;
    _deviceId = c.id;
    _connected = true;
    _events.add('Connected to ${c.name} — config handshake sent');
    await _drainFromRadio();
  }

  Future<void> _drainFromRadio() async {
    final fr = _fromRadio;
    if (fr == null) return;
    for (var i = 0; i < 32; i++) {
      final bytes = await fr.read();
      if (bytes.isEmpty) break;
      _events.add('← FromRadio ${bytes.length}B (protobuf)');
    }
  }

  Future<void> sendText(String text) async {
    final tx = _toRadio;
    if (!_connected || tx == null) {
      throw StateError('Not connected to Meshtastic');
    }
    final bytes = MeshtasticPacketCodec.encodeTextToRadio(text.trim());
    await tx.write(bytes, withResponse: true);
    _events.add(
      '→ Text TX ${text.length} chars (${bytes.length}B MeshPacket)',
    );
  }

  /// @deprecated use [sendText]
  Future<void> sendTextHint(String text) => sendText(text);

  Future<void> disconnect() async {
    await _fromNumSub?.cancel();
    _fromNumSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _deviceId = null;
    _toRadio = null;
    _fromRadio = null;
    _connected = false;
  }

  void dispose() {
    unawaited(stopScan());
    unawaited(disconnect());
    unawaited(_controller.close());
    unawaited(_events.close());
  }
}
