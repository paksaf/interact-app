// SPDX-License-Identifier: AGPL-3.0
//
// Nearby BLE devices — Wave 3 light IoT status dashboard.
// Status-only list (name, RSSI, last seen). Scan via flutter_reactive_ble
// (BSD-3) — no flutter_blue_plus.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

final nearbyBleDevicesServiceProvider =
    Provider<NearbyBleDevicesService>((ref) => NearbyBleDevicesService());

class NearbyBleDevice {
  NearbyBleDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.lastSeen,
    this.connectable = false,
  });

  final String id;
  final String name;
  final int rssi;
  final DateTime lastSeen;
  final bool connectable;

  int get secondsAgo =>
      DateTime.now().difference(lastSeen).inSeconds.clamp(0, 99999);

  int get signalBars {
    if (rssi >= -55) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -85) return 2;
    if (rssi >= -100) return 1;
    return 0;
  }
}

class NearbyBleDevicesService {
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;
  Timer? _pruneTimer;
  final _devices = <String, NearbyBleDevice>{};
  final _controller = StreamController<List<NearbyBleDevice>>.broadcast();
  bool _scanning = false;

  Stream<List<NearbyBleDevice>> get devicesStream => _controller.stream;
  List<NearbyBleDevice> get devices => _sorted();
  bool get isScanning => _scanning;

  bool get supportsPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  Future<void> start() async {
    if (!supportsPlatform) {
      throw UnsupportedError('BLE scan requires Android or iOS.');
    }
    if (_scanning) return;

    await _ensurePermissions();

    final status = await _ble.statusStream.first
        .timeout(const Duration(seconds: 5), onTimeout: () => BleStatus.unknown);
    if (status == BleStatus.poweredOff) {
      throw StateError('Turn on Bluetooth, then retry.');
    }
    if (status == BleStatus.unsupported) {
      throw StateError('This device does not support Bluetooth LE.');
    }

    _scanning = true;
    _scanSub = _ble
        .scanForDevices(
          withServices: const [],
          scanMode: ScanMode.lowLatency,
          requireLocationServicesEnabled: false,
        )
        .listen(_onDevice, onError: (_) {});

    _pruneTimer?.cancel();
    _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pruneStale();
    });
  }

  Future<void> stop() async {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    await _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
  }

  Future<void> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
      final locOk =
          statuses[Permission.locationWhenInUse]?.isGranted ?? false;
      if (!scanOk && !locOk) {
        throw StateError(
          'Bluetooth / location permission required to scan nearby devices.',
        );
      }
    }
  }

  void _onDevice(DiscoveredDevice d) {
    final now = DateTime.now();
    final name = d.name.trim().isNotEmpty ? d.name.trim() : 'Unknown';
    final prev = _devices[d.id];
    _devices[d.id] = NearbyBleDevice(
      id: d.id,
      name: name == 'Unknown' && prev != null ? prev.name : name,
      rssi: d.rssi,
      lastSeen: now,
      connectable: d.connectable == Connectable.available,
    );
    _emit();
  }

  void _pruneStale() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emit();
  }

  List<NearbyBleDevice> _sorted() {
    final list = _devices.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  void _emit() => _controller.add(_sorted());

  void dispose() {
    stop();
    _controller.close();
  }
}
