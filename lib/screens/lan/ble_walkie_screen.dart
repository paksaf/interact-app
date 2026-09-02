// SPDX-License-Identifier: AGPL-3.0
//
// BLE PTT walkie — fallback when LAN walkie channels are empty.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/ai_contact_service.dart';
import '../../services/auth_service.dart';
import '../../services/ble_walkie_service.dart';
import '../../widgets/branded_app_bar.dart';

class BleWalkieScreen extends ConsumerStatefulWidget {
  const BleWalkieScreen({super.key});

  @override
  ConsumerState<BleWalkieScreen> createState() => _BleWalkieScreenState();
}

class _BleWalkieScreenState extends ConsumerState<BleWalkieScreen> {
  final _svc = BleWalkieService.instance;
  List<BleWalkiePeer> _peers = const [];
  BleWalkiePeer? _selected;
  StreamSubscription<List<BleWalkiePeer>>? _sub;
  bool _ptt = false;
  bool _starting = true;
  String? _advertiseHint;

  @override
  void initState() {
    super.initState();
    _sub = _svc.peers.listen((p) {
      if (mounted) setState(() => _peers = p);
    });
    _boot();
  }

  Future<void> _boot() async {
    setState(() => _starting = true);
    final auth = ref.read(authServiceProvider);
    final peerId = await auth.localUserId() ??
        await auth.phone() ??
        'anon-${DateTime.now().millisecondsSinceEpoch}';
    final name = await auth.displayName() ?? 'INTERACT peer';
    await _svc.startSession(peerId: peerId, displayName: name);
    if (!mounted) return;
    setState(() {
      _starting = false;
      _advertiseHint = _svc.isAdvertising
          ? 'Advertising as BLE peripheral — other phones can scan you.'
          : 'Peripheral advertise unavailable on this device — scan only.';
    });
  }

  Future<void> _rescan() async {
    setState(() => _starting = true);
    await _svc.startScan();
    if (mounted) setState(() => _starting = false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_svc.stopSession());
    super.dispose();
  }

  Future<void> _connect(BleWalkiePeer peer) async {
    setState(() => _selected = peer);
    await _svc.connect(peer);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Connected to ${peer.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'BLE Walkie'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'No Wi‑Fi walkie? Hold to speak over Bluetooth — short PTT bursts '
            '(8 kHz, chunked over BLE). Both phones open this screen; each '
            'advertises + scans.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          if (_advertiseHint != null) ...[
            const SizedBox(height: 8),
            Text(_advertiseHint!, style: TextStyle(color: cs.primary)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _starting ? null : _rescan,
                child: Text(_starting ? 'Starting…' : 'Rescan peers'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => context.push('/chat/$kAiThreadId'),
                child: const Text('Talk to AI'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_peers.isEmpty)
            Text(
              'No INTERACT BLE peers yet. Open BLE Walkie on the other phone.',
              style: TextStyle(color: cs.onSurfaceVariant),
            )
          else
            for (final p in _peers)
              ListTile(
                leading: const Icon(Icons.bluetooth_audio),
                title: Text(p.name),
                subtitle: Text('RSSI ${p.rssi}'),
                trailing: FilledButton(
                  onPressed: () => _connect(p),
                  child: const Text('Connect'),
                ),
              ),
          const SizedBox(height: 24),
          Center(
            child: Listener(
              onPointerDown: (_) async {
                setState(() => _ptt = true);
                await _svc.startPtt();
              },
              onPointerUp: (_) async {
                setState(() => _ptt = false);
                await _svc.stopPttAndSend();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _ptt ? cs.error : cs.primary,
                ),
                alignment: Alignment.center,
                child: Icon(
                  _ptt ? Icons.mic : Icons.mic_none,
                  color: cs.onPrimary,
                  size: 48,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              _selected == null
                  ? 'Connect to a peer first'
                  : (_ptt ? 'Speaking…' : 'Hold to talk'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
