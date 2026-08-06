// SPDX-License-Identifier: AGPL-3.0
//
// Talk ↔ InteractLoRaBridge — BLE GATT via flutter_reactive_ble (BSD-3).
// Firmware: firmware/lora_ble_bridge/ (Nordic UART UUIDs + name).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

final loraBridgeServiceProvider =
    Provider<LoraBridgeService>((ref) => LoraBridgeService());

/// Must match firmware/lora_ble_bridge/lora_ble_bridge.ino
class LoraBridgeUuids {
  static final service = Uuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
  static final txNotify = Uuid.parse('6e400003-b5a3-f393-e0a9-e50e24dcca9e');
  static final rxWrite = Uuid.parse('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static const advertisedName = 'InteractLoRaBridge';
}

class LoraBridgeCandidate {
  LoraBridgeCandidate({
    required this.id,
    required this.name,
    required this.rssi,
  });
  final String id;
  final String name;
  final int rssi;
}

class LoraBridgeMessage {
  LoraBridgeMessage({
    required this.body,
    required this.at,
    required this.isMine,
  });
  final String body;
  final DateTime at;
  final bool isMine;
}

class LoraBridgeService {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  String? _deviceName;
  Characteristic? _rx;
  Characteristic? _tx;
  bool _scanning = false;
  bool _connected = false;

  final _candidates = <String, LoraBridgeCandidate>{};
  final _candidatesController =
      StreamController<List<LoraBridgeCandidate>>.broadcast();
  final _messagesController =
      StreamController<LoraBridgeMessage>.broadcast();
  final _connectionController = StreamController<bool>.broadcast();

  Stream<List<LoraBridgeCandidate>> get candidatesStream =>
      _candidatesController.stream;
  Stream<LoraBridgeMessage> get messages => _messagesController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;

  List<LoraBridgeCandidate> get candidates =>
      _candidates.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  bool get isConnected => _connected && _rx != null && _tx != null;
  bool get isScanning => _scanning;
  String? get connectedName => _deviceName;

  bool get supportsPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> startScan() async {
    if (!supportsPlatform) {
      throw UnsupportedError('LoRa bridge BLE requires Android or iOS.');
    }
    await _ensurePermissions();
    await _requireBleOn();

    _candidates.clear();
    _candidatesController.add(const []);
    _scanning = true;

    await _scanSub?.cancel();
    _scanSub = _ble
        .scanForDevices(
          withServices: [LoraBridgeUuids.service],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen(_onScanHit, onError: (_) {});
  }

  Future<void> startScanByName() async {
    await stopScan();
    await _ensurePermissions();
    await _requireBleOn();
    _scanning = true;
    await _scanSub?.cancel();
    _scanSub = _ble
        .scanForDevices(
          withServices: const [],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen(_onScanHit, onError: (_) {});
  }

  void _onScanHit(DiscoveredDevice d) {
    final name = d.name.trim();
    final hasService = d.serviceUuids.contains(LoraBridgeUuids.service);
    if (!hasService && !_isBridgeName(name)) return;
    if (name.isNotEmpty && !hasService && !_isBridgeName(name)) return;
    final label = name.isEmpty ? LoraBridgeUuids.advertisedName : name;
    if (!_isBridgeName(label) && !hasService) return;
    _candidates[d.id] = LoraBridgeCandidate(
      id: d.id,
      name: label,
      rssi: d.rssi,
    );
    _candidatesController.add(candidates);
  }

  bool _isBridgeName(String name) {
    final n = name.toLowerCase();
    return n.contains('interactlorabridge') ||
        n.contains('interact_lora') ||
        n == LoraBridgeUuids.advertisedName.toLowerCase();
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
  }

  Future<void> connect(LoraBridgeCandidate candidate) async {
    await stopScan();
    await disconnect();

    final completer = Completer<void>();
    await _connSub?.cancel();
    _connSub = _ble
        .connectToDevice(
          id: candidate.id,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        try {
          await _ble.requestMtu(deviceId: candidate.id, mtu: 185);
        } catch (_) {}
        try {
          await _bindGatt(candidate);
          if (!completer.isCompleted) completer.complete();
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      } else if (update.connectionState == DeviceConnectionState.disconnected) {
        _connected = false;
        _rx = null;
        _tx = null;
        _connectionController.add(false);
      }
    }, onError: (Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    });

    await completer.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _bindGatt(LoraBridgeCandidate candidate) async {
    await _ble.discoverAllServices(candidate.id);
    final services = await _ble.getDiscoveredServices(candidate.id);
    Characteristic? rx;
    Characteristic? tx;
    for (final s in services) {
      if (s.id != LoraBridgeUuids.service) continue;
      for (final c in s.characteristics) {
        if (c.id == LoraBridgeUuids.rxWrite) rx = c;
        if (c.id == LoraBridgeUuids.txNotify) tx = c;
      }
    }
    if (rx == null || tx == null) {
      await disconnect();
      throw StateError(
        'Bridge GATT incomplete — flash firmware/lora_ble_bridge.',
      );
    }

    await _notifySub?.cancel();
    _notifySub = tx.subscribe().listen((bytes) {
      if (bytes.isEmpty) return;
      final body = utf8.decode(bytes, allowMalformed: true).trim();
      if (body.isEmpty) return;
      _messagesController.add(LoraBridgeMessage(
        body: body,
        at: DateTime.now(),
        isMine: false,
      ));
    });

    _deviceName = candidate.name;
    _rx = rx;
    _tx = tx;
    _connected = true;
    _connectionController.add(true);
  }

  Future<void> sendText(String text) async {
    final body = text.trim();
    final rx = _rx;
    if (body.isEmpty || rx == null || !_connected) {
      throw StateError('Connect to InteractLoRaBridge first.');
    }
    var bytes = utf8.encode(body);
    if (bytes.length > 200) bytes = bytes.sublist(0, 200);
    await rx.write(bytes, withResponse: false);
    _messagesController.add(LoraBridgeMessage(
      body: body,
      at: DateTime.now(),
      isMine: true,
    ));
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;
    await _connSub?.cancel();
    _connSub = null;
    _deviceName = null;
    _rx = null;
    _tx = null;
    _connected = false;
    _connectionController.add(false);
  }

  Future<void> _requireBleOn() async {
    final status = await _ble.statusStream.first
        .timeout(const Duration(seconds: 5), onTimeout: () => BleStatus.unknown);
    if (status == BleStatus.poweredOff) {
      throw StateError('Turn on Bluetooth, then retry.');
    }
    if (status == BleStatus.unsupported) {
      throw StateError('Bluetooth LE not supported on this device.');
    }
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) return;
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    if (!scanOk && !connOk) {
      throw StateError('Bluetooth permission required for LoRa bridge.');
    }
  }

  Future<void> dispose() async {
    await stopScan();
    await disconnect();
    await _candidatesController.close();
    await _messagesController.close();
    await _connectionController.close();
  }
}
