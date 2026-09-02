// SPDX-License-Identifier: AGPL-3.0
//
// Long-range path: phone ↔ InteractLoRaBridge (BLE) ↔ LoRa RF.
// Requires firmware/lora_ble_bridge flashed on ESP32 (+ second node for E2E).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/lora_bridge_service.dart';
import '../../services/meshtastic_bridge_service.dart';
import '../../widgets/branded_app_bar.dart';

class LoraBridgeScreen extends ConsumerStatefulWidget {
  const LoraBridgeScreen({super.key});

  @override
  ConsumerState<LoraBridgeScreen> createState() => _LoraBridgeScreenState();
}

class _LoraBridgeScreenState extends ConsumerState<LoraBridgeScreen> {
  final _textCtrl = TextEditingController();
  final _meshTextCtrl = TextEditingController();
  final _log = <LoraBridgeMessage>[];
  final _meshLog = <String>[];
  List<LoraBridgeCandidate> _candidates = const [];
  StreamSubscription? _candSub;
  StreamSubscription? _msgSub;
  StreamSubscription? _connSub;
  StreamSubscription? _meshEventsSub;
  bool _connected = false;
  bool _meshConnected = false;
  bool _scanning = false;
  String? _error;
  String? _status;
  String? _meshStatus;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final svc = ref.read(loraBridgeServiceProvider);
    _candSub = svc.candidatesStream.listen((c) {
      if (mounted) setState(() => _candidates = c);
    });
    _msgSub = svc.messages.listen((m) {
      if (mounted) setState(() => _log.add(m));
    });
    _connSub = svc.connectionStream.listen((up) {
      if (mounted) {
        setState(() {
          _connected = up;
          _status = up
              ? 'Connected to ${svc.connectedName ?? "bridge"}'
              : 'Disconnected';
        });
      }
    });
    await _scan();
    _meshEventsSub =
        ref.read(meshtasticBridgeServiceProvider).events.listen((line) {
      if (!mounted) return;
      setState(() {
        _meshLog.add(line);
        if (_meshLog.length > 80) _meshLog.removeAt(0);
      });
    });
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _error = null;
      _status = 'Scanning for InteractLoRaBridge…';
    });
    final svc = ref.read(loraBridgeServiceProvider);
    try {
      await svc.startScan();
      await Future<void>.delayed(const Duration(seconds: 4));
      if (svc.candidates.isEmpty) {
        await svc.startScanByName();
        _status = 'Scanning by name (InteractLoRaBridge)…';
      }
      if (mounted) {
        setState(() {
          _candidates = svc.candidates;
          _scanning = svc.isScanning;
          if (_candidates.isEmpty) {
            _status =
                'No bridge found — power ESP32 with lora_ble_bridge firmware';
          } else {
            _status = '${_candidates.length} bridge(s) — tap to connect';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _scanning = false;
        });
      }
    }
  }

  Future<void> _connect(LoraBridgeCandidate c) async {
    setState(() => _status = 'Connecting to ${c.name}…');
    try {
      await ref.read(loraBridgeServiceProvider).connect(c);
      setState(() {
        _connected = true;
        _scanning = false;
        _status = 'Connected — messages ride LoRa via the bridge';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Connect failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      await ref.read(loraBridgeServiceProvider).sendText(text);
      _textCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    }
  }

  Future<void> _ping() async {
    final stamp = DateTime.now().toIso8601String();
    try {
      await ref.read(loraBridgeServiceProvider).sendText('LoRa-1 ping $stamp');
      setState(() => _status = 'Ping sent — wait for peer notify (<10s @1km)');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ping failed: $e')),
      );
    }
  }

  Future<void> _sendMeshText() async {
    final text = _meshTextCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      await ref.read(meshtasticBridgeServiceProvider).sendText(text);
      _meshTextCtrl.clear();
      if (mounted) {
        setState(() => _meshStatus = 'MeshPacket sent — check peer node');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Meshtastic send failed: $e')),
      );
    }
  }

  @override
  void dispose() {
    _candSub?.cancel();
    _msgSub?.cancel();
    _connSub?.cancel();
    _meshEventsSub?.cancel();
    _textCtrl.dispose();
    _meshTextCtrl.dispose();
    final svc = ref.read(loraBridgeServiceProvider);
    svc.stopScan();
    // Keep connection if user pops? Prefer clean disconnect on leave.
    svc.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: BrandedAppBar(
        title: 'LoRa bridge',
        actions: [
          IconButton(
            tooltip: 'Rescan',
            onPressed: _connected
                ? null
                : () async {
                    await ref.read(loraBridgeServiceProvider).disconnect();
                    await _scan();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _scan, child: const Text('Retry')),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Material(
                  color: cs.surfaceContainerHighest,
                  child: ListTile(
                    leading: Icon(
                      _connected ? Icons.cell_tower : Icons.bluetooth_searching,
                      color: _connected ? cs.primary : cs.outline,
                    ),
                    title: Text(_connected ? 'Bridge linked' : 'Long-range RF'),
                    subtitle: Text(
                      _status ??
                          'Phone ↔ BLE ↔ InteractLoRaBridge ↔ LoRa (915/868 MHz)',
                    ),
                    trailing: _scanning && !_connected
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  ),
                ),
                if (!_connected)
                  SizedBox(
                    height: 96,
                    child: _candidates.isEmpty
                        ? const Center(child: Text('Waiting for bridge…'))
                        : ListView.builder(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            itemCount: _candidates.length,
                            itemBuilder: (_, i) {
                              final c = _candidates[i];
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ActionChip(
                                  avatar: const Icon(Icons.router, size: 18),
                                  label: Text('${c.name} (${c.rssi} dBm)'),
                                  onPressed: () => _connect(c),
                                ),
                              );
                            },
                          ),
                  ),
                const Divider(height: 1),
                Expanded(
                  child: _log.isEmpty
                      ? Center(
                          child: Text(
                            _connected
                                ? 'Send a short text — it goes out over LoRa.\n'
                                    'A second bridge+phone receives it.'
                                : 'Flash firmware/lora_ble_bridge on ESP32,\n'
                                    'then tap the bridge chip above.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.outline),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _log.length,
                          itemBuilder: (_, i) {
                            final m = _log[i];
                            return Align(
                              alignment: m.isMine
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: m.isMine
                                      ? cs.primary
                                      : cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  m.body,
                                  style: TextStyle(
                                    color: m.isMine
                                        ? cs.onPrimary
                                        : cs.onSurface,
                                  ),
                                ),
                              ),
                            );
                          },
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
                            enabled: _connected,
                            decoration: InputDecoration(
                              hintText: _connected
                                  ? 'LoRa message (≤200 bytes)'
                                  : 'Connect a bridge first',
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'LoRa-1 ping',
                          onPressed: _connected ? _ping : null,
                          icon: const Icon(Icons.speed),
                        ),
                        IconButton.filled(
                          onPressed: _connected ? _send : null,
                          icon: const Icon(Icons.send),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                ExpansionTile(
                  leading: const Icon(Icons.radar),
                  title: const Text('Meshtastic adapter'),
                  subtitle: Text(
                    _meshConnected
                        ? 'Connected — UTF-8 MeshPacket TX via ToRadio GATT'
                        : 'Official GATT — connect, then send UTF-8 text',
                  ),
                  children: [
                    if (_meshStatus != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          _meshStatus!,
                          style: TextStyle(fontSize: 12, color: cs.outline),
                        ),
                      ),
                    ListTile(
                      title: const Text('Scan & connect Meshtastic'),
                      trailing: const Icon(Icons.search),
                      onTap: () async {
                        final svc = ref.read(meshtasticBridgeServiceProvider);
                        await svc.startScan();
                        await Future<void>.delayed(const Duration(seconds: 6));
                        await svc.stopScan();
                        if (!context.mounted) return;
                        final list = svc.candidates;
                        await showModalBottomSheet<void>(
                          context: context,
                          builder: (ctx) => SafeArea(
                            child: list.isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.all(24),
                                    child: Text(
                                      'No Meshtastic advertising found.\n'
                                      'Use DIY InteractLoRaBridge for UTF-8 E2E today.',
                                      textAlign: TextAlign.center,
                                    ),
                                  )
                                : ListView(
                                    shrinkWrap: true,
                                    children: [
                                      for (final c in list)
                                        ListTile(
                                          leading: const Icon(Icons.cell_tower),
                                          title: Text(c.name),
                                          subtitle: Text(
                                              '${c.rssi} dBm · tap to connect'),
                                          onTap: () async {
                                            Navigator.pop(ctx);
                                            try {
                                              await svc.connect(c);
                                              if (!context.mounted) return;
                                              setState(() {
                                                _meshConnected = true;
                                                _meshStatus =
                                                    'Meshtastic linked: ${c.name}';
                                              });
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Connected ${c.name}. '
                                                    'Type below to send MeshPacket text.',
                                                  ),
                                                ),
                                              );
                                            } catch (e) {
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                SnackBar(content: Text('$e')),
                                              );
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                          ),
                        );
                      },
                    ),
                    if (_meshConnected) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _meshTextCtrl,
                                decoration: const InputDecoration(
                                  hintText: 'Meshtastic text (≤200 bytes UTF-8)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _sendMeshText(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              onPressed: _sendMeshText,
                              icon: const Icon(Icons.send),
                            ),
                          ],
                        ),
                      ),
                      if (_meshLog.isNotEmpty)
                        SizedBox(
                          height: 96,
                          child: ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: _meshLog.length,
                            itemBuilder: (_, i) => Text(
                              _meshLog[i],
                              style: TextStyle(fontSize: 11, color: cs.outline),
                            ),
                          ),
                        ),
                      ListTile(
                        title: const Text('Disconnect Meshtastic'),
                        leading: const Icon(Icons.link_off),
                        onTap: () async {
                          await ref
                              .read(meshtasticBridgeServiceProvider)
                              .disconnect();
                          if (!mounted) return;
                          setState(() {
                            _meshConnected = false;
                            _meshStatus = null;
                          });
                        },
                      ),
                    ],
                  ],
                ),
              ],
            ),
    );
  }
}
