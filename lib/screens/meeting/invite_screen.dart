// SPDX-License-Identifier: AGPL-3.0
//
// Invite screen — paste a 6-char code, scan a QR, or open a deep link.
// Triggers a token mint via TalkApi and pushes into the meeting room.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../services/talk_api.dart';

// Room codes use the full A–Z 0–9 alphabet (server-generated). The old
// formatter dropped 0 and 1, so a code like "A1B2C3" could never reach six
// characters and Join stayed disabled.
final _codeChars = RegExp(r'[A-Z0-9]');
final _codeInLink = RegExp(r'([A-Z0-9]{6})');

class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key});
  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  // Camera permission gate — avoids MobileScanner's raw "unexpected error"
  // when permission is missing, which is the common cause on first open.
  bool _camChecked = false;
  bool _camGranted = false;

  @override
  void initState() {
    super.initState();
    _ensureCamera();
  }

  Future<void> _ensureCamera() async {
    final status = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _camGranted = status.isGranted;
      _camChecked = true;
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _join(String code) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // We only validate the code resolves to a real room before pushing;
      // the meeting room mints its own token with the same code.
      await ref.read(talkApiProvider).joinRoom(code);
      if (!mounted) return;
      context.go('/room?code=$code');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _scanner() {
    if (!_camChecked) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_camGranted) {
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            const Text(
              'Camera access is off, so QR scanning is unavailable.\nYou can still type the code above.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => openAppSettings(),
              child: const Text('Open settings'),
            ),
          ],
        ),
      );
    }
    return MobileScanner(
      onDetect: (cap) {
        final v = cap.barcodes.firstOrNull?.rawValue;
        if (v == null) return;
        // Accept either a bare code or a .../j/CODE deep link.
        final m = _codeInLink.firstMatch(v.toUpperCase());
        if (m == null || _busy) return;
        _codeCtrl.text = m.group(1)!;
        _join(m.group(1)!);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Join with code')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Paste the 6-character code',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(_codeChars),
                  LengthLimitingTextInputFormatter(6),
                ],
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) {
                  final code = v.trim().toUpperCase();
                  if (!_busy && code.length == 6) _join(code);
                },
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'A1B2C3',
                  hintStyle: TextStyle(letterSpacing: 4, fontSize: 22),
                ),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 4,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy || _codeCtrl.text.length != 6
                    ? null
                    : () => _join(_codeCtrl.text),
                icon: const Icon(Icons.login),
                label: const Text('Join'),
              ),
              const SizedBox(height: 24),
              Divider(color: cs.outlineVariant),
              const SizedBox(height: 12),
              Text(
                'Or scan the QR code',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 240,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _scanner(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
