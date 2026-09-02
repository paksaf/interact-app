// SPDX-License-Identifier: AGPL-3.0
//
// LAN walkie — voice on the site Wi-Fi when the router has no uplink.
// Roadmap §14 Phase 1. Service: [LanWalkieService]. Media: the existing
// mesh client in [MeetingRoomScreen], pointed at the host phone's in-app
// relay instead of the cloud one.
//
// Two roles, one screen:
//   • HOST — runs the relay + advertises the channel over mDNS, then joins
//     its own relay over loopback like any other participant.
//   • JOIN — picks a channel it discovered and connects to that phone.
//
// Phase 1 is deliberately host-and-spoke: one phone holds the room. If the
// host walks away, the channel ends — the same social contract as the person
// holding the base station. Phase 2 (BLE mesh, no router at all) is §4.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/lan_walkie_service.dart';
import '../../widgets/branded_app_bar.dart';
import '../meeting/meeting_room_screen.dart';

class LanWalkieScreen extends ConsumerStatefulWidget {
  const LanWalkieScreen({super.key, this.initialCode});

  /// Pre-fills the code box — set when we arrive here as the offline
  /// fallback from a walkie join that could not reach LiveKit.
  final String? initialCode;

  @override
  ConsumerState<LanWalkieScreen> createState() => _LanWalkieScreenState();
}

class _LanWalkieScreenState extends ConsumerState<LanWalkieScreen> {
  final _svc = LanWalkieService.instance;
  late final TextEditingController _codeCtrl;
  late final TextEditingController _manualHostCtrl;
  late final TextEditingController _manualPortCtrl;

  List<LanWalkieChannel> _channels = const [];
  StreamSubscription<List<LanWalkieChannel>>? _sub;
  StreamSubscription<int>? _peerSub;
  int _hostPeers = 0;
  bool _busy = false;
  String? _error;
  String _displayName = 'INTERACT';

  @override
  void initState() {
    super.initState();
    _codeCtrl = TextEditingController(
      text: (widget.initialCode ?? 'WALKIE1').toUpperCase(),
    );
    _manualHostCtrl = TextEditingController();
    _manualPortCtrl = TextEditingController();
    _boot();
  }

  Future<void> _boot() async {
    try {
      _displayName =
          (await ref.read(authServiceProvider).displayName())?.trim() ?? '';
      if (_displayName.isEmpty) _displayName = 'INTERACT';
    } catch (_) {/* keep the default */}

    _sub = _svc.channels.listen((list) {
      if (mounted) setState(() => _channels = list);
    });
    _peerSub = _svc.peerCount.listen((n) {
      if (mounted) setState(() => _hostPeers = n);
    });

    try {
      await _svc.startDiscovery();
      if (mounted) setState(() => _channels = _svc.discovered);
    } catch (e) {
      // Almost always iOS's local-network permission on first run, or a
      // network with mDNS blocked. Hosting still works; say so rather than
      // leaving an empty list looking like "nobody is here".
      if (mounted) setState(() => _error = 'Could not scan the network: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _peerSub?.cancel();
    // Discovery is per-screen; hosting deliberately is NOT stopped here, so
    // the relay survives navigating into the call and back.
    unawaited(_svc.stopDiscovery());
    _codeCtrl.dispose();
    _manualHostCtrl.dispose();
    _manualPortCtrl.dispose();
    super.dispose();
  }

  String get _code => _codeCtrl.text.trim().toUpperCase();

  Future<void> _startHosting() async {
    if (_code.isEmpty) {
      setState(() => _error = 'Give the channel a code first.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await _svc.startHost(code: _code, hostName: _displayName);
      final self = _svc.selfChannel;
      if (self == null) throw StateError('relay did not start');
      if (!mounted) return;
      setState(() => _busy = false);
      _enterRoom(self, isHost: true);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = 'Could not host: $e'; });
    }
  }

  Future<void> _stopHosting() async {
    await _svc.stopHost();
    if (mounted) setState(() => _hostPeers = 0);
  }

  void _enterRoom(LanWalkieChannel c, {required bool isHost}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MeetingRoomScreen(
        roomCode: c.code,
        isHost: isHost,
        mode: 'voice',
        lanSignalUrl: c.wsUrl,
        lanRoomId: c.roomId,
      ),
    ));
  }

  void _joinManual() {
    final host = _manualHostCtrl.text.trim();
    final port = int.tryParse(_manualPortCtrl.text.trim());
    if (host.isEmpty || port == null || port <= 0) {
      setState(() => _error = 'Enter host IP and port from the hosting phone.');
      return;
    }
    try {
      final ch = _svc.channelFromManual(code: _code, host: host, port: port);
      setState(() => _error = null);
      _enterRoom(ch, isHost: false);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _copyHostJoinInfo() {
    final ip = _svc.hostLanIp;
    final port = _svc.hostedPort;
    if (ip == null || port == null) return;
    final text = '$ip:$port · code $_code';
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Host IP + port copied — share with joiner')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hosting = _svc.isHosting;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Nearby walkie',
        subtitle: 'Same Wi-Fi · no internet needed',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wifi_tethering, color: cs.primary),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Everyone must be on the same Wi-Fi. '
                          'One phone hosts the channel; the others join it.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _codeCtrl,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Channel code',
                      hintText: 'e.g. WALKIE1',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!hosting)
                    FilledButton.icon(
                      onPressed: _busy ? null : _startHosting,
                      icon: const Icon(Icons.podcasts),
                      label: Text(_busy ? 'Starting…' : 'Host this channel'),
                    )
                  else ...[
                    Text(
                      'Hosting ${_svc.hostedCode} · '
                      '$_hostPeers device${_hostPeers == 1 ? '' : 's'} connected',
                      style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
                    ),
                    if (_svc.hostLanIp != null && _svc.hostedPort != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Join manually: ${_svc.hostLanIp}:${_svc.hostedPort}',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _copyHostJoinInfo,
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copy for joiner'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            final self = _svc.selfChannel;
                            if (self != null) _enterRoom(self, isHost: true);
                          },
                          icon: const Icon(Icons.mic),
                          label: const Text('Open channel'),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: _stopHosting,
                          child: const Text('Stop hosting'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('Channels nearby',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const Spacer(),
              if (_channels.isEmpty)
                const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: cs.error)),
            ),
          if (_channels.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Nothing found yet. Someone has to press “Host this channel” '
                    'on one phone — then it shows up here on the others.\n\n'
                    'iPhone: Settings → INTERACT → Local Network ON. '
                    'If discovery stays empty, use manual join below.',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/ble-walkie'),
                    icon: const Icon(Icons.bluetooth_audio),
                    label: const Text('Try BLE Walkie (no Wi‑Fi)'),
                  ),
                ],
              ),
            )
          else
            for (final c in _channels)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: const Icon(Icons.podcasts),
                ),
                title: Text(c.code),
                subtitle: Text('${c.hostName} · ${c.host}'),
                trailing: FilledButton.tonal(
                  onPressed: () => _enterRoom(c, isHost: false),
                  child: const Text('Join'),
                ),
              ),
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Join by IP (mDNS blocked)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              'Host shares IP:port from their screen',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _manualHostCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Host IP',
                        hintText: '192.168.1.42',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _manualPortCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Port',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: _joinManual,
                  child: const Text('Join with IP'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Voice only in this first version, and it stays on this Wi-Fi — '
            'nothing is sent to the internet, and nothing is recorded.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
