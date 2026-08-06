// SPDX-License-Identifier: AGPL-3.0
//
// Offline LAN — two modes for phone RF without internet:
//   1) Same Wi‑Fi: Bonsoir mDNS + TCP ([LanService])
//   2) Direct (no router): Android Wi‑Fi Direct / iOS MPC ([P2pService])
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/auth_service.dart';
import '../../services/lan_service.dart';
import '../../services/p2p_service.dart';
import '../../widgets/branded_app_bar.dart';

enum _LanMode { sameWifi, direct }

class OfflineLanScreen extends ConsumerStatefulWidget {
  const OfflineLanScreen({super.key});
  @override
  ConsumerState<OfflineLanScreen> createState() => _OfflineLanScreenState();
}

class _OfflineLanScreenState extends ConsumerState<OfflineLanScreen> {
  final _textCtrl = TextEditingController();
  final List<({String? fromName, String body, bool isMine})> _log = [];
  _LanMode _mode = _LanMode.sameWifi;
  P2pDarwinRole _darwinRole = P2pDarwinRole.browser;

  List<LanPeer> _lanPeers = const [];
  List<P2pPeer> _p2pPeers = const [];
  LanPeer? _selectedLan;
  P2pPeer? _selectedP2p;
  bool _p2pConnected = false;

  StreamSubscription? _peerSub;
  StreamSubscription? _msgSub;
  bool _starting = true;
  String? _error;
  String _peerId = '';
  String _displayName = '';

  @override
  void initState() {
    super.initState();
    _bootLan();
  }

  Future<void> _bootLan() async {
    await WakelockPlus.enable();
    final auth = ref.read(authServiceProvider);
    _peerId = await auth.localUserId() ??
        await auth.phone() ??
        'anon-${DateTime.now().millisecondsSinceEpoch}';
    _displayName = await auth.displayName() ?? 'INTERACT peer';
    await _startMode(_LanMode.sameWifi);
  }

  Future<void> _startMode(_LanMode mode) async {
    setState(() {
      _starting = true;
      _error = null;
      _log.clear();
      _selectedLan = null;
      _selectedP2p = null;
      _p2pConnected = false;
      _mode = mode;
    });
    await _peerSub?.cancel();
    await _msgSub?.cancel();
    await ref.read(lanServiceProvider).stop();
    await ref.read(p2pServiceProvider).stop();

    try {
      if (mode == _LanMode.sameWifi) {
        final lan = ref.read(lanServiceProvider);
        await lan.start(peerId: _peerId, displayName: _displayName);
        _peerSub = lan.peersStream.listen((p) {
          if (mounted) setState(() => _lanPeers = p);
        });
        _msgSub = lan.messages.listen((m) {
          if (mounted) {
            setState(() => _log.add((
                  fromName: m.isMine ? null : m.fromName,
                  body: m.body,
                  isMine: m.isMine,
                )));
          }
        });
        setState(() {
          _lanPeers = lan.peers;
          _starting = false;
        });
      } else {
        final p2p = ref.read(p2pServiceProvider);
        await p2p.start(
          displayName: _displayName,
          darwinRole: _darwinRole,
        );
        _peerSub = p2p.peersStream.listen((p) {
          if (mounted) setState(() => _p2pPeers = p);
        });
        _msgSub = p2p.messages.listen((m) {
          if (mounted) {
            setState(() => _log.add((
                  fromName: m.isMine ? null : m.fromName,
                  body: m.body,
                  isMine: m.isMine,
                )));
          }
        });
        setState(() {
          _p2pPeers = p2p.peers;
          _starting = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _starting = false;
      });
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _msgSub?.cancel();
    _textCtrl.dispose();
    ref.read(lanServiceProvider).stop();
    ref.read(p2pServiceProvider).stop();
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  Future<void> _connectP2p(P2pPeer peer) async {
    try {
      await ref.read(p2pServiceProvider).connect(peer.device);
      setState(() {
        _selectedP2p = peer;
        _p2pConnected = true;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Direct connect failed: $e')),
      );
    }
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    try {
      if (_mode == _LanMode.sameWifi) {
        final peer = _selectedLan;
        if (peer == null) return;
        await ref.read(lanServiceProvider).sendText(peer, text);
      } else {
        await ref.read(p2pServiceProvider).sendText(text);
      }
      _textCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    }
  }

  bool get _canSend {
    if (_mode == _LanMode.sameWifi) return _selectedLan != null;
    return _p2pConnected;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDarwin = !kIsWeb && (Platform.isIOS || Platform.isMacOS);

    return Scaffold(
      appBar: const BrandedAppBar(title: 'Offline LAN'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SegmentedButton<_LanMode>(
              segments: const [
                ButtonSegment(
                  value: _LanMode.sameWifi,
                  label: Text('Same Wi‑Fi'),
                  icon: Icon(Icons.wifi, size: 18),
                ),
                ButtonSegment(
                  value: _LanMode.direct,
                  label: Text('Direct'),
                  icon: Icon(Icons.wifi_tethering, size: 18),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                final next = s.first;
                if (next != _mode) _startMode(next);
              },
            ),
          ),
          if (_mode == _LanMode.direct && isDarwin)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SegmentedButton<P2pDarwinRole>(
                segments: const [
                  ButtonSegment(
                    value: P2pDarwinRole.browser,
                    label: Text('Browse'),
                  ),
                  ButtonSegment(
                    value: P2pDarwinRole.advertiser,
                    label: Text('Advertise'),
                  ),
                ],
                selected: {_darwinRole},
                onSelectionChanged: (s) {
                  setState(() => _darwinRole = s.first);
                  _startMode(_LanMode.direct);
                },
              ),
            ),
          if (_starting)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () => _startMode(_mode),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            Material(
              color: cs.surfaceContainerHighest,
              child: ListTile(
                leading: Icon(
                  _mode == _LanMode.sameWifi
                      ? Icons.wifi
                      : Icons.wifi_tethering,
                  color: cs.primary,
                ),
                title: Text(
                  _mode == _LanMode.sameWifi
                      ? 'Same Wi‑Fi peers (Bonsoir + TCP)'
                      : 'Direct peers (Wi‑Fi Direct / MPC)',
                ),
                subtitle: Text(
                  _mode == _LanMode.sameWifi
                      ? (_lanPeers.isEmpty
                          ? 'Broadcasting… open Offline LAN on another phone'
                          : '${_lanPeers.length} peer(s) — tap one, then send')
                      : (_p2pConnected
                          ? 'Connected to ${_selectedP2p?.displayName ?? "peer"}'
                          : (_p2pPeers.isEmpty
                              ? 'Searching… same OS only (Android↔Android or iOS↔iOS)'
                              : 'Tap a peer to connect, then send')),
                ),
              ),
            ),
            SizedBox(
              height: 88,
              child: _mode == _LanMode.sameWifi
                  ? _lanPeerChips()
                  : _p2pPeerChips(),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
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
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!m.isMine && m.fromName != null)
                            Text(m.fromName!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.outline,
                                )),
                          Text(
                            m.body,
                            style: TextStyle(
                              color:
                                  m.isMine ? cs.onPrimary : cs.onSurface,
                            ),
                          ),
                        ],
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
                        decoration: InputDecoration(
                          hintText: !_canSend
                              ? (_mode == _LanMode.direct
                                  ? 'Connect to a peer first'
                                  : 'Select a peer first')
                              : 'Offline message (no internet)',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: _canSend ? _send : null,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _lanPeerChips() {
    if (_lanPeers.isEmpty) {
      return const Center(child: Text('No peers yet'));
    }
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _lanPeers.length,
      itemBuilder: (_, i) {
        final p = _lanPeers[i];
        final sel = _selectedLan?.peerId == p.peerId;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            selected: sel,
            label: Text(p.displayName),
            onSelected: (_) => setState(() => _selectedLan = p),
          ),
        );
      },
    );
  }

  Widget _p2pPeerChips() {
    if (_p2pPeers.isEmpty) {
      return const Center(child: Text('No Direct peers yet'));
    }
    return ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _p2pPeers.length,
      itemBuilder: (_, i) {
        final p = _p2pPeers[i];
        final sel = _selectedP2p?.id == p.id && _p2pConnected;
        return Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ChoiceChip(
            selected: sel,
            label: Text(
              p.isConnected || sel ? '${p.displayName} ✓' : p.displayName,
            ),
            onSelected: (_) => _connectP2p(p),
          ),
        );
      },
    );
  }
}
