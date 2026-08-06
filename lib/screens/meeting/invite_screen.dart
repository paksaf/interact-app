// SPDX-License-Identifier: AGPL-3.0
//
// Invite screen — paste a 6-char code, scan a QR, or open a deep link.
// Triggers a token mint via TalkApi and pushes into the meeting room.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/talk_api.dart';

class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key});
  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _join(String code) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // We don't need the token here — the meeting room calls TalkApi
      // again itself with the same code. We only validate the code
      // resolves to a real room before pushing.
      await ref.read(talkApiProvider).joinRoom(code);
      if (!mounted) return;
      context.go('/room?code=$code');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
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
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Z2-9]')),
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
                  child: MobileScanner(
                    onDetect: (cap) {
                      final v = cap.barcodes.firstOrNull?.rawValue;
                      if (v == null) return;
                      // Accept either bare code or a https://talk.interactpak.com/j/CODE link
                      final m = RegExp(r'([A-Z2-9]{6})').firstMatch(v);
                      if (m == null) return;
                      _codeCtrl.text = m.group(1)!;
                      _join(m.group(1)!);
                    },
                  ),
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
