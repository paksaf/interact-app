// SPDX-License-Identifier: AGPL-3.0
//
// App-wide BLE mesh node for OfflineRouter text transport.
// Lifted from NearbyMeshScreen — screen becomes a thin UI over this.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/permission_flow.dart';
import 'package:sahl_mesh/sahl_mesh.dart';
import 'package:sahl_mesh/sahl_mesh_ble.dart';

import 'mesh_cloud_bridge.dart';
import 'mesh_foreground_service.dart';
import 'mesh_identity_store.dart';
import 'field_probe_service.dart';
import '../utils/shared_location_pin.dart';

final bleMeshTransportServiceProvider =
    Provider<BleMeshTransportService>((ref) => BleMeshTransportService.instance);

class BleMeshTransportService {
  BleMeshTransportService._();
  static final BleMeshTransportService instance = BleMeshTransportService._();

  MeshNode? _node;
  StreamSubscription? _sub;
  bool _running = false;

  final _inboundController = StreamController<({String raw, String from})>.broadcast();

  Stream<({String raw, String from})> get inbound => _inboundController.stream;
  bool get isRunning => _running && _node != null;

  Future<String> localMeshPubKeyHex() => MeshIdentityStore.instance.publicKeyHex();

  Future<void> start() async {
    if (_running) return;
    await requestSequentially([
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ]);
    await MeshForegroundService.instance.start();

    final id = await MeshIdentityStore.instance.loadOrCreate();
    final node = MeshNode(
      transport: BleTransport(
        config: const BleTransportConfig(throwOnPermissionDenied: true),
      ),
      identity: id,
    );
    await node.start();
    _sub = node.messages.listen((msg) {
      if (msg.kind != MeshMessageKind.hello) return;
      final raw = utf8.decode(msg.payload, allowMalformed: true);
      if (!raw.startsWith('talk:')) return;
      if (!_inboundController.isClosed) {
        final fromHex = msg.from
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        _inboundController.add((raw: raw, from: fromHex));
        unawaited(FieldProbeService.instance.recordRx(
          bearer: 'ble',
          detail: MeshCloudBridge.plainBody(raw) ?? raw,
        ));
      }
    });
    _node = node;
    _running = true;
    debugPrint('[ble-mesh-transport] started');
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _node?.stop();
    _node = null;
    _running = false;
  }

  /// Broadcast thread-scoped talk frame (≤180 B payload).
  Future<bool> sendForThread(String threadId, String text) async {
    final node = _node;
    if (node == null) return false;
    final inner = compactWireBody(text) ?? text;
    final payload = MeshCloudBridge.encodeForThread(threadId, inner);
    final bytes = utf8.encode(payload);
    final clipped = bytes.length > 180 ? bytes.sublist(0, 180) : bytes;
    try {
      await node.broadcast(MeshMessage(
        kind: MeshMessageKind.hello,
        from: node.identity.publicKey,
        payload: Uint8List.fromList(clipped),
      ));
      unawaited(FieldProbeService.instance.recordTx(
        bearer: 'ble',
        detail: threadId,
      ));
      return true;
    } catch (e) {
      debugPrint('[ble-mesh-transport] send failed: $e');
      return false;
    }
  }
}
