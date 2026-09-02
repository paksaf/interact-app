// SPDX-License-Identifier: AGPL-3.0
//
// Nearby BLE mesh — thin UI over app-wide [BleMeshTransportService] (P3 Wave 1).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../utils/permission_flow.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/offline/mesh_identity_card.dart';
import '../../services/ble_mesh_transport_service.dart';
import '../../services/field_probe_service.dart';
import '../../services/mesh_cloud_bridge.dart';
import '../../services/mesh_foreground_service.dart';
import '../../widgets/branded_app_bar.dart';

class NearbyMeshScreen extends ConsumerStatefulWidget {
  const NearbyMeshScreen({super.key});
  @override
  ConsumerState<NearbyMeshScreen> createState() => _NearbyMeshScreenState();
}

class _NearbyMeshScreenState extends ConsumerState<NearbyMeshScreen> {
  final _textCtrl = TextEditingController();
  final _log = <String>[];
  StreamSubscription? _sub;
  bool _starting = true;
  String? _error;
  int? _lastLatencyMs;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await requestSequentially([
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.locationWhenInUse,
      ]);
      await WakelockPlus.enable();
      await MeshForegroundService.instance.start();

      final transport = ref.read(bleMeshTransportServiceProvider);
      await transport.start();
      _sub = transport.inbound.listen((evt) async {
        final plain = MeshCloudBridge.plainBody(evt.raw);
        if (plain == null || plain.isEmpty) return;
        final latency = await FieldProbeService.instance.recordRx(
          bearer: 'ble',
          detail: plain,
        );
        if (!mounted) return;
        setState(() {
          _lastLatencyMs = latency;
          final from = looksLikeMeshPubKeyHex(evt.from)
              ? evt.from.substring(0, 8)
              : evt.from;
          _log.add('← $plain (${latency ?? '?'} ms, $from…)');
        });
      });
      setState(() => _starting = false);
    } catch (e) {
      setState(() {
        _error = '$e';
        _starting = false;
      });
    }
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      final ok = await ref
          .read(bleMeshTransportServiceProvider)
          .sendForThread(kFieldBleMeshThreadId, text);
      if (!ok) throw StateError('BLE mesh send failed');
      setState(() {
        _log.add('→ $text');
        _textCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(
        title: 'Nearby mesh (BLE)',
        actions: [
          IconButton(
            tooltip: 'Link mesh identity',
            onPressed: () => context.push('/mesh-identity'),
            icon: const Icon(Icons.qr_code_2),
          ),
        ],
      ),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'BLE mesh unavailable:\n$_error\n\n'
                      'Grant nearby-devices / Bluetooth permissions and retry.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.bluetooth_searching),
                      title: const Text('sahl_mesh gossip'),
                      subtitle: Text(
                        'Same transport as Chats offline router. '
                        'Field: RF-BLE-1 @1m, RF-BLE-2 @50m, RF-BLE-3 3 phones.'
                        '${_lastLatencyMs != null ? '\nLast RX: ${_lastLatencyMs}ms' : ''}',
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _log.length,
                        itemBuilder: (_, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(_log[i]),
                        ),
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _textCtrl,
                                maxLength: 160,
                                decoration: const InputDecoration(
                                  hintText: 'Short text (talk:1|thread|… envelope)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              onPressed: _send,
                              icon: const Icon(Icons.send),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
