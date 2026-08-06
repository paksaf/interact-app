// SPDX-License-Identifier: AGPL-3.0
//
// Generate a random login code + QR that OTHER apps can poll for approval.
// Useful when building/testing cross-app login, or when an app embeds Talk
// as a WhatsApp-style auth channel.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/talk_auth_api.dart';
import '../../widgets/branded_app_bar.dart';

class GenerateLoginQrScreen extends ConsumerStatefulWidget {
  const GenerateLoginQrScreen({super.key});

  @override
  ConsumerState<GenerateLoginQrScreen> createState() =>
      _GenerateLoginQrScreenState();
}

class _GenerateLoginQrScreenState extends ConsumerState<GenerateLoginQrScreen> {
  bool _busy = false;
  String? _code;
  String? _qr;
  String? _challengeId;
  String? _expiresAt;

  Future<void> _generate() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(talkAuthApiProvider).startChallenge(
            appId: 'com.interactpak.interact_talk',
            appName: 'INTERACT Talk',
            deviceLabel: 'Talk QR login',
          );
      if (!mounted) return;
      setState(() {
        _code = r.displayCode;
        _qr = r.qrPayload;
        _challengeId = r.challengeId;
        _expiresAt = r.expiresAt;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Login QR',
        subtitle: 'For other INTERACT apps',
        showBrandGlyph: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Generate a one-time code + QR. Another device or app can show '
            'this QR; you approve in Talk — same pattern as WhatsApp Web / '
            'TV pairing, and a channel for login OTPs.',
            style: TextStyle(color: cs.outline, height: 1.35),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: const Icon(Icons.refresh),
            label: Text(_code == null ? 'Generate code' : 'Generate new code'),
          ),
          if (_code != null) ...[
            const SizedBox(height: 28),
            Center(
              child: Text(
                _code!,
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 8,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_expiresAt != null)
              Center(
                child: Text(
                  'Expires $_expiresAt',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                ),
              ),
            const SizedBox(height: 20),
            if (_qr != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: QrImageView(
                    data: _qr!,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _code!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Code copied')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy code'),
            ),
            if (_challengeId != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  'challengeId: $_challengeId',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
