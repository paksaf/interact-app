// SPDX-License-Identifier: AGPL-3.0
//
// QR-based mesh ↔ Talk identity binding — audit step 6 v1 (NFC later).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/offline/mesh_identity_card.dart';
import '../../services/auth_service.dart';
import '../../services/mesh_identity_store.dart';
import '../../services/mesh_peer_registry.dart';
import '../../widgets/branded_app_bar.dart';

class MeshIdentityBindScreen extends ConsumerStatefulWidget {
  const MeshIdentityBindScreen({super.key});

  @override
  ConsumerState<MeshIdentityBindScreen> createState() =>
      _MeshIdentityBindScreenState();
}

class _MeshIdentityBindScreenState extends ConsumerState<MeshIdentityBindScreen> {
  MeshIdentityCard? _myCard;
  String? _error;
  bool _loading = true;
  bool _scanning = false;
  final _scannerCtrl = MobileScannerController();

  @override
  void initState() {
    super.initState();
    _loadCard();
  }

  Future<void> _loadCard() async {
    try {
      final auth = ref.read(authServiceProvider);
      final userId = await auth.localUserId();
      if (userId == null || userId.isEmpty) {
        setState(() {
          _error = 'Sign in to link your mesh identity';
          _loading = false;
        });
        return;
      }
      final identity = await MeshIdentityStore.instance.loadOrCreate();
      final card = await MeshIdentityCard.signed(
        identity: identity,
        userId: userId,
        displayName: await auth.displayName() ?? 'INTERACT user',
        phone: await auth.phone(),
      );
      if (mounted) {
        setState(() {
          _myCard = card;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _trustPayload(String raw) async {
    final card = MeshIdentityCard.parse(raw);
    if (card == null) {
      _toast('Invalid identity card');
      return;
    }
    final ok = await MeshIdentityCard.verifySignature(card);
    if (!ok) {
      _toast('Signature check failed — do not trust');
      return;
    }
    await MeshPeerRegistry.instance.trustCard(card);
    if (!mounted) return;
    _toast('Trusted ${card.displayName}');
    setState(() => _scanning = false);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _scannerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: BrandedAppBar(
        title: 'Mesh identity',
        actions: [
          IconButton(
            tooltip: _scanning ? 'Show my QR' : 'Scan peer QR',
            onPressed: () => setState(() => _scanning = !_scanning),
            icon: Icon(_scanning ? Icons.qr_code : Icons.qr_code_scanner),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!, textAlign: TextAlign.center))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      'Link a BLE mesh device to a Talk account so offline '
                      'messages show the real name — not a raw pubkey.',
                      style: TextStyle(color: cs.outline),
                    ),
                    const SizedBox(height: 16),
                    if (_scanning) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(
                          height: 260,
                          child: MobileScanner(
                            controller: _scannerCtrl,
                            onDetect: (capture) {
                              final codes = capture.barcodes;
                              if (codes.isEmpty) return;
                              final raw = codes.first.rawValue;
                              if (raw == null) return;
                              unawaited(_trustPayload(raw));
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Point at the other phone\'s QR. Signature is verified '
                        'before trust is stored on-device.',
                        style: TextStyle(fontSize: 12, color: cs.outline),
                      ),
                    ] else if (_myCard != null) ...[
                      Center(
                        child: QrImageView(
                          data: _myCard!.toQrPayload(),
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(_myCard!.displayName),
                        subtitle: Text(
                          'Mesh ${_myCard!.meshPubKeyHex.substring(0, 8)}…',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.copy),
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(text: _myCard!.toQrPayload()),
                            );
                            _toast('Card JSON copied');
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FutureBuilder(
                      future: MeshPeerRegistry.instance.listBindings(),
                      builder: (context, snap) {
                        final list = snap.data ?? const [];
                        if (list.isEmpty) {
                          return Text(
                            'No trusted mesh peers yet.',
                            style: TextStyle(color: cs.outline),
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Trusted peers (${list.length})',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            for (final b in list)
                              ListTile(
                                dense: true,
                                title: Text(b.displayName),
                                subtitle: Text(
                                  '${b.talkUserId.substring(0, 8)}… · '
                                  '${b.meshPubKeyHex.substring(0, 8)}…',
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
    );
  }
}
