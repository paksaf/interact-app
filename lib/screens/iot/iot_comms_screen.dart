// SPDX-License-Identifier: AGPL-3.0
//
// Universal IoT comms — one phone, any gateway. LoRa ESP32, 433 MHz RF→HTTP,
// Meshtastic (via LoRa screen), AutoSense edge (RF HTTP on car Pi).
//
// Payload: lib/core/iot/iot_frame.dart (single-line JSON, ≤200 B on LoRa).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/iot/iot_ack_presets.dart';
import '../../core/iot/iot_frame.dart';
import '../../services/iot/iot_comms_service.dart';
import '../../services/lora_bridge_service.dart';
import '../../widgets/branded_app_bar.dart';

class IotCommsScreen extends ConsumerStatefulWidget {
  const IotCommsScreen({super.key});

  @override
  ConsumerState<IotCommsScreen> createState() => _IotCommsScreenState();
}

class _IotCommsScreenState extends ConsumerState<IotCommsScreen> {
  final _hub = IotCommsService.instance;
  final _lora = LoraBridgeService.instance;
  final _textCtrl = TextEditingController();
  final _pollUrlCtrl = TextEditingController();
  final _ackUrlCtrl = TextEditingController();

  List<IotFrame> _frames = const [];
  IotFrame? _selected;
  List<LoraBridgeCandidate> _loraCandidates = const [];
  StreamSubscription<IotFrame>? _inboxSub;
  StreamSubscription? _loraCandSub;
  bool _scanning = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _hub.loadPrefs();
    if (_hub.rfPollUrl != null) _pollUrlCtrl.text = _hub.rfPollUrl!;
    if (_hub.rfAckUrl != null) _ackUrlCtrl.text = _hub.rfAckUrl!;
    _frames = _hub.history;
    _inboxSub = _hub.inbox.listen((f) {
      if (mounted) setState(() => _frames = _hub.history);
    });
    _loraCandSub = _lora.candidatesStream.listen((c) {
      if (mounted) setState(() => _loraCandidates = c);
    });
    await _scanLora();
  }

  Future<void> _scanLora() async {
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      await _lora.startScan();
      await Future<void>.delayed(const Duration(seconds: 4));
      if (_lora.candidates.isEmpty) await _lora.startScanByName();
      if (mounted) {
        setState(() {
          _loraCandidates = _lora.candidates;
          _scanning = false;
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

  Future<void> _connectLora(LoraBridgeCandidate c) async {
    try {
      await _hub.connectLoRa(c);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('LoRa bridge linked — ${c.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Connect failed: $e')),
      );
    }
  }

  Future<void> _connectRfHttp() async {
    final poll = _pollUrlCtrl.text.trim();
    if (poll.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter poll URL (e.g. http://192.168.1.10:8765/json)')),
      );
      return;
    }
    try {
      await _hub.connectRfHttp(
        poll,
        ackUrl: _ackUrlCtrl.text.trim().isEmpty ? null : _ackUrlCtrl.text.trim(),
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _tapAck(IotAckPreset preset) async {
    final inbound = _selected;
    if (inbound == null || inbound.isMine) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select an inbound signal first')),
      );
      return;
    }
    try {
      await _hub.sendAck(inbound: inbound, preset: preset);
      if (!mounted) return;
      setState(() => _frames = _hub.history);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sent ${preset.code} → ${inbound.id}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ACK failed: $e')),
      );
    }
  }

  Future<void> _sendCustom() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      await _hub.sendText(text);
      _textCtrl.clear();
      if (mounted) setState(() => _frames = _hub.history);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  void dispose() {
    _inboxSub?.cancel();
    _loraCandSub?.cancel();
    _textCtrl.dispose();
    _pollUrlCtrl.dispose();
    _ackUrlCtrl.dispose();
    _lora.stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final connected = _hub.isConnected;

    return Scaffold(
      appBar: BrandedAppBar(
        title: 'IoT gateway',
        subtitle: 'LoRa · 433 MHz · AutoSense edge',
        actions: [
          IconButton(
            tooltip: 'LoRa bridge (legacy UI)',
            onPressed: () => context.push('/lora-bridge'),
            icon: const Icon(Icons.cell_tower),
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: cs.surfaceContainerHighest,
            child: ListTile(
              leading: Icon(
                connected ? Icons.link : Icons.link_off,
                color: connected ? cs.primary : cs.outline,
              ),
              title: Text(_hub.status ?? 'Pick a gateway below'),
              subtitle: Text(
                connected
                    ? 'Tap inbound signal → one-tap ACK'
                    : 'Phone ↔ IoT — no cloud chat required',
              ),
            ),
          ),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  TabBar(
                    tabs: const [
                      Tab(text: 'Inbox', icon: Icon(Icons.inbox, size: 18)),
                      Tab(text: 'Connect', icon: Icon(Icons.settings_input_antenna, size: 18)),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _inboxTab(cs),
                        _connectTab(cs),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_selected != null && !_selected!.isMine) _ackBar(cs),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      enabled: connected,
                      decoration: InputDecoration(
                        hintText: connected
                            ? 'Custom command / text (JSON or plain)'
                            : 'Connect gateway first',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onSubmitted: (_) => _sendCustom(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: connected ? _sendCustom : null,
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

  Widget _inboxTab(ColorScheme cs) {
    if (_frames.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Inbound IoT signals appear here.\n'
            'Connect LoRa bridge or RF HTTP poll URL.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.outline),
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _frames.length,
      itemBuilder: (_, i) {
        final f = _frames[_frames.length - 1 - i];
        final sel = _selected?.id == f.id;
        return Card(
          color: sel ? cs.primaryContainer.withValues(alpha: 0.5) : null,
          child: ListTile(
            leading: Icon(
              f.isMine ? Icons.north_east : Icons.south_west,
              color: f.isMine ? cs.primary : cs.secondary,
            ),
            title: Text(
              '${f.kind.label} · ${f.body.length > 48 ? '${f.body.substring(0, 48)}…' : f.body}',
              maxLines: 2,
            ),
            subtitle: Text(
              '${f.bearer.label} · id ${f.id}'
              '${f.ackFor != null ? ' · ack→${f.ackFor}' : ''}',
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => setState(() => _selected = f),
          ),
        );
      },
    );
  }

  Widget _connectTab(ColorScheme cs) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('LoRa ESP32 (InteractLoRaBridge)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        if (_error != null)
          Text(_error!, style: TextStyle(color: cs.error)),
        if (_loraCandidates.isEmpty)
          Text(
            _scanning ? 'Scanning BLE…' : 'Power ESP32 with lora_ble_bridge firmware',
            style: TextStyle(color: cs.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in _loraCandidates)
                ActionChip(
                  avatar: const Icon(Icons.router, size: 18),
                  label: Text('${c.name} (${c.rssi})'),
                  onPressed: () => _connectLora(c),
                ),
            ],
          ),
        TextButton.icon(
          onPressed: _scanning ? null : _scanLora,
          icon: const Icon(Icons.refresh),
          label: const Text('Rescan LoRa bridges'),
        ),
        const Divider(height: 32),
        Text('433 / 868 MHz RF → HTTP (Pi / AutoSense edge)',
            style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _pollUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'Poll URL (GET JSON)',
            hintText: 'http://192.168.1.10:8765/json',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _ackUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'ACK URL (POST JSON, optional)',
            hintText: 'http://192.168.1.10:8765/ack',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _connectRfHttp,
          icon: const Icon(Icons.sensors),
          label: const Text('Start RF HTTP gateway'),
        ),
        const SizedBox(height: 16),
        Text(
          'Meshtastic: use LoRa bridge screen for GATT connect; '
          'UTF-8 TX lands here when protobuf send ships.',
          style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );
  }

  Widget _ackBar(ColorScheme cs) {
    return Material(
      color: cs.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reply to ${_selected!.id}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSecondaryContainer,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in kIotAckPresets)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text('${p.icon} ${p.label}'),
                        onSelected: (_) => _tapAck(p),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
