// SPDX-License-Identifier: AGPL-3.0
//
// Nearby BLE mesh text via sahl_mesh (donor). Short UTF-8 lines ride on
// MeshMessageKind.hello payloads prefixed with "talk:" so we don't break
// the SAHL kind enum wire layout.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sahl_mesh/sahl_mesh.dart';
import 'package:sahl_mesh/sahl_mesh_ble.dart';

import '../../widgets/branded_app_bar.dart';

class NearbyMeshScreen extends ConsumerStatefulWidget {
  const NearbyMeshScreen({super.key});
  @override
  ConsumerState<NearbyMeshScreen> createState() => _NearbyMeshScreenState();
}

class _NearbyMeshScreenState extends ConsumerState<NearbyMeshScreen> {
  final _textCtrl = TextEditingController();
  final List<String> _log = [];
  MeshNode? _node;
  StreamSubscription? _sub;
  bool _starting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final id = await MeshIdentity.generate();
      final node = MeshNode(
        transport: BleTransport(),
        identity: id,
      );
      await node.start();
      _sub = node.messages.listen((msg) {
        if (msg.kind != MeshMessageKind.hello) return;
        final raw = utf8.decode(msg.payload, allowMalformed: true);
        if (!raw.startsWith('talk:')) return;
        final body = raw.substring(5);
        if (!mounted) return;
        setState(() => _log.add('← $body'));
      });
      setState(() {
        _node = node;
        _starting = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _starting = false;
      });
    }
  }

  Future<void> _send() async {
    final node = _node;
    final text = _textCtrl.text.trim();
    if (node == null || text.isEmpty) return;
    final bytes = utf8.encode('talk:$text');
    final clipped = bytes.length > 180 ? bytes.sublist(0, 180) : bytes;
    try {
      await node.broadcast(MeshMessage(
        kind: MeshMessageKind.hello,
        from: node.identity.publicKey,
        payload: Uint8List.fromList(clipped),
      ));
      setState(() {
        _log.add('→ $text');
        _textCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Mesh send failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _node?.stop();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Nearby mesh (BLE)'),
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
                    const ListTile(
                      leading: Icon(Icons.bluetooth_searching),
                      title: Text('sahl_mesh gossip'),
                      subtitle: Text(
                        'Short texts hop phone-to-phone over BLE. '
                        'No internet. Range ~tens of metres.',
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
                                  hintText: 'Broadcast mesh text',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                  counterText: '',
                                ),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              onPressed: _send,
                              icon: const Icon(Icons.campaign_outlined),
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
