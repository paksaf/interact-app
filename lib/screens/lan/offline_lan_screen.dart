// SPDX-License-Identifier: AGPL-3.0
//
// Offline LAN — discover peers on the same Wi‑Fi via Bonsoir and exchange
// short text over TCP (no internet / TURN). Me → Offline LAN mode.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/lan_service.dart';
import '../../widgets/branded_app_bar.dart';

class OfflineLanScreen extends ConsumerStatefulWidget {
  const OfflineLanScreen({super.key});
  @override
  ConsumerState<OfflineLanScreen> createState() => _OfflineLanScreenState();
}

class _OfflineLanScreenState extends ConsumerState<OfflineLanScreen> {
  final _textCtrl = TextEditingController();
  final List<LanTextMessage> _log = [];
  List<LanPeer> _peers = const [];
  LanPeer? _selected;
  StreamSubscription? _peerSub;
  StreamSubscription? _msgSub;
  bool _starting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final auth = ref.read(authServiceProvider);
    final peerId = await auth.localUserId() ??
        await auth.phone() ??
        'anon-${DateTime.now().millisecondsSinceEpoch}';
    final name = await auth.displayName() ?? 'INTERACT peer';
    final lan = ref.read(lanServiceProvider);
    try {
      await lan.start(peerId: peerId, displayName: name);
      _peerSub = lan.peersStream.listen((p) {
        if (mounted) setState(() => _peers = p);
      });
      _msgSub = lan.messages.listen((m) {
        if (mounted) setState(() => _log.add(m));
      });
      setState(() {
        _peers = lan.peers;
        _starting = false;
      });
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
    super.dispose();
  }

  Future<void> _send() async {
    final peer = _selected;
    final text = _textCtrl.text.trim();
    if (peer == null || text.isEmpty) return;
    try {
      await ref.read(lanServiceProvider).sendText(peer, text);
      _textCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('LAN send failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Offline LAN'),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ))
              : Column(
                  children: [
                    Material(
                      color: cs.surfaceContainerHighest,
                      child: ListTile(
                        leading: Icon(Icons.wifi_tethering, color: cs.primary),
                        title: const Text('Same Wi‑Fi peers'),
                        subtitle: Text(
                          _peers.isEmpty
                              ? 'Broadcasting… open Offline LAN on another phone'
                              : '${_peers.length} peer(s) — tap one, then send',
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 88,
                      child: _peers.isEmpty
                          ? const Center(child: Text('No peers yet'))
                          : ListView.builder(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              itemCount: _peers.length,
                              itemBuilder: (_, i) {
                                final p = _peers[i];
                                final sel = _selected?.peerId == p.peerId;
                                return Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    selected: sel,
                                    label: Text(p.displayName),
                                    onSelected: (_) =>
                                        setState(() => _selected = p),
                                  ),
                                );
                              },
                            ),
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
                                  if (!m.isMine)
                                    Text(m.fromName,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: cs.outline,
                                        )),
                                  Text(
                                    m.body,
                                    style: TextStyle(
                                      color: m.isMine
                                          ? cs.onPrimary
                                          : cs.onSurface,
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
                                  hintText: _selected == null
                                      ? 'Select a peer first'
                                      : 'LAN message (no internet)',
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                                onSubmitted: (_) => _send(),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              onPressed: _selected == null ? null : _send,
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
