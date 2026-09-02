// SPDX-License-Identifier: AGPL-3.0
//
// BLE PTT walkie — Phase 2 fallback when LAN walkie unavailable.
// Central (flutter_reactive_ble) + peripheral (ble_peripheral) so two
// Talk phones discover each other without a LoRa bridge dongle.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/permission_flow.dart';
import 'package:record/record.dart';

class BleWalkieUuids {
  static final service = Uuid.parse('6e400010-b5a3-f393-e0a9-e50e24dcca9e');
  static final txNotify = Uuid.parse('6e400013-b5a3-f393-e0a9-e50e24dcca9e');
  static final rxWrite = Uuid.parse('6e400012-b5a3-f393-e0a9-e50e24dcca9e');
  static const serviceWire = '6e400010-b5a3-f393-e0a9-e50e24dcca9e';
  static const txWire = '6e400013-b5a3-f393-e0a9-e50e24dcca9e';
  static const rxWire = '6e400012-b5a3-f393-e0a9-e50e24dcca9e';
  static const nameHint = 'INTERACT';
}

class BleWalkiePeer {
  BleWalkiePeer({required this.id, required this.name, required this.rssi});
  final String id;
  final String name;
  final int rssi;
}

class BleWalkieService {
  BleWalkieService._();
  static final BleWalkieService instance = BleWalkieService._();

  final _ble = FlutterReactiveBle();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;

  final _peers = <String, BleWalkiePeer>{};
  final _peersCtrl = StreamController<List<BleWalkiePeer>>.broadcast();
  final _rxBuffer = <int>[];

  Characteristic? _rx;
  Characteristic? _tx;
  bool _scanning = false;
  bool _advertising = false;
  String _localName = BleWalkieUuids.nameHint;

  Stream<List<BleWalkiePeer>> get peers => _peersCtrl.stream;
  bool get isConnected => _rx != null && _tx != null;
  bool get isScanning => _scanning;
  bool get isAdvertising => _advertising;

  bool get supportsPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Scan for peers and advertise our GATT walkie service (both phones).
  Future<void> startSession({
    required String peerId,
    required String displayName,
  }) async {
    final short = displayName.trim().isNotEmpty
        ? displayName.trim().replaceAll(RegExp(r'\s+'), '-')
        : peerId;
    final tag = short.length <= 8 ? short : short.substring(0, 8);
    _localName = '${BleWalkieUuids.nameHint}-$tag';
    await startScan();
    await startAdvertising();
  }

  Future<void> stopSession() async {
    await stopScan();
    await stopAdvertising();
    await disconnect();
  }

  Future<void> startScan() async {
    if (!supportsPlatform) return;
    await requestSequentially([
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.microphone,
      Permission.locationWhenInUse,
    ]);

    _peers.clear();
    _peersCtrl.add(const []);
    _scanning = true;
    await _scanSub?.cancel();
    _scanSub = _ble
        .scanForDevices(
          withServices: [BleWalkieUuids.service],
          scanMode: ScanMode.lowLatency,
        )
        .listen((d) {
      final name = d.name;
      if (name.isEmpty) return;
      if (!name.toUpperCase().contains(BleWalkieUuids.nameHint)) return;
      _peers[d.id] = BleWalkiePeer(id: d.id, name: name, rssi: d.rssi);
      _peersCtrl.add(_peers.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi)));
    });
  }

  Future<void> stopScan() async {
    await _scanSub?.cancel();
    _scanSub = null;
    _scanning = false;
  }

  Future<void> startAdvertising() async {
    if (!supportsPlatform || _advertising) return;
    try {
      final supported = await BlePeripheral.isSupported();
      if (supported != true) {
        debugPrint('[ble-walkie] peripheral mode not supported');
        return;
      }
      await BlePeripheral.initialize();
      BlePeripheral.setWriteRequestCallback(_onPeripheralWrite);
      await BlePeripheral.clearServices();
      await BlePeripheral.addService(
        BleService(
          uuid: BleWalkieUuids.serviceWire,
          primary: true,
          characteristics: [
            BleCharacteristic(
              uuid: BleWalkieUuids.rxWire,
              properties: [
                CharacteristicProperties.write.index,
                CharacteristicProperties.writeWithoutResponse.index,
              ],
              permissions: [
                AttributePermissions.writeable.index,
              ],
              value: null,
            ),
            BleCharacteristic(
              uuid: BleWalkieUuids.txWire,
              properties: [
                CharacteristicProperties.notify.index,
              ],
              permissions: [
                AttributePermissions.readable.index,
              ],
              value: null,
            ),
          ],
        ),
      );
      await BlePeripheral.startAdvertising(
        services: [BleWalkieUuids.serviceWire],
        localName: _localName.length > 12 ? _localName.substring(0, 12) : _localName,
      );
      _advertising = true;
    } catch (e) {
      debugPrint('[ble-walkie] advertise failed: $e');
    }
  }

  Future<void> stopAdvertising() async {
    if (!_advertising) return;
    try {
      await BlePeripheral.stopAdvertising();
    } catch (e) {
      debugPrint('[ble-walkie] stop advertise: $e');
    }
    _advertising = false;
  }

  WriteRequestResult? _onPeripheralWrite(
    String deviceId,
    String characteristicId,
    int offset,
    Uint8List? value,
  ) {
    if (characteristicId.toLowerCase() != BleWalkieUuids.rxWire) return null;
    if (value == null || value.isEmpty) return null;
    _onAudioChunk(value);
    return null;
  }

  Future<void> connect(BleWalkiePeer peer) async {
    await disconnect();
    final completer = Completer<void>();
    await _connSub?.cancel();
    _connSub = _ble
        .connectToDevice(
          id: peer.id,
          connectionTimeout: const Duration(seconds: 15),
        )
        .listen((update) async {
      if (update.connectionState == DeviceConnectionState.connected) {
        try {
          await _ble.requestMtu(deviceId: peer.id, mtu: 512);
          await _bindGatt(peer.id);
          if (!completer.isCompleted) completer.complete();
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      }
    }, onError: completer.completeError);
    await completer.future.timeout(const Duration(seconds: 20));
  }

  Future<void> _bindGatt(String deviceId) async {
    await _ble.discoverAllServices(deviceId);
    final services = await _ble.getDiscoveredServices(deviceId);
    Characteristic? rx;
    Characteristic? tx;
    for (final s in services) {
      if (s.id != BleWalkieUuids.service) continue;
      for (final c in s.characteristics) {
        if (c.id == BleWalkieUuids.rxWrite) rx = c;
        if (c.id == BleWalkieUuids.txNotify) tx = c;
      }
    }
    if (rx == null || tx == null) {
      throw StateError('Peer missing BLE walkie GATT service.');
    }
    await _notifySub?.cancel();
    _notifySub = tx.subscribe().listen(_onAudioChunk);
    _rx = rx;
    _tx = tx;
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    _notifySub = null;
    _connSub = null;
    _rx = null;
    _tx = null;
    _rxBuffer.clear();
  }

  Future<void> startPtt() async {
    if (!await _recorder.hasPermission()) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/ble_ptt_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 8000),
      path: path,
    );
  }

  Future<void> stopPttAndSend() async {
    final path = await _recorder.stop();
    final rx = _rx;
    if (path == null || rx == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final bytes = await file.readAsBytes();
    await _sendAudioBytes(bytes, (payload) => rx.write(payload, withResponse: false));
    await file.delete().catchError((_) => file);
  }

  Future<void> _sendAudioBytes(
    List<int> bytes,
    Future<void> Function(List<int> payload) writeFn,
  ) async {
    const chunkSize = 400;
    var seq = 0;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = (i + chunkSize > bytes.length) ? bytes.length : i + chunkSize;
      final slice = bytes.sublist(i, end);
      final frame = jsonEncode({
        't': 'audio',
        'seq': seq,
        'fin': end >= bytes.length,
        'data': base64Encode(slice),
      });
      var payload = utf8.encode(frame);
      if (payload.length > 512) payload = payload.sublist(0, 512);
      await writeFn(payload);
      seq++;
    }
  }

  void _onAudioChunk(List<int> data) {
    try {
      final m = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (m['t'] != 'audio') return;
      final chunk = base64Decode(m['data'] as String? ?? '');
      _rxBuffer.addAll(chunk);
      if (m['fin'] == true) {
        unawaited(_playBuffer());
      }
    } catch (e) {
      debugPrint('[ble-walkie] chunk parse failed: $e');
    }
  }

  Future<void> _playBuffer() async {
    if (_rxBuffer.isEmpty) return;
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/ble_rx_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final file = File(path);
    await file.writeAsBytes(List<int>.from(_rxBuffer));
    _rxBuffer.clear();
    await _player.play(DeviceFileSource(path));
  }
}
