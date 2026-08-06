// SPDX-License-Identifier: AGPL-3.0
//
// Approve a cross-app login — enter the 6-digit code or arrive via
// interact://auth/<code>?c=<challengeId> deep link / QR scan.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/talk_auth_api.dart';
import '../../widgets/branded_app_bar.dart';

class ApproveLoginScreen extends ConsumerStatefulWidget {
  const ApproveLoginScreen({
    super.key,
    this.initialCode,
    this.challengeId,
  });

  final String? initialCode;
  final String? challengeId;

  @override
  ConsumerState<ApproveLoginScreen> createState() => _ApproveLoginScreenState();
}

class _ApproveLoginScreenState extends ConsumerState<ApproveLoginScreen> {
  late final TextEditingController _codeCtrl;
  bool _busy = false;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _codeCtrl = TextEditingController(text: widget.initialCode ?? '');
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _approve({String? code, String? challengeId}) async {
    final c = (code ?? _codeCtrl.text).replaceAll(RegExp(r'\D'), '');
    if (c.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the 6-digit code')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(talkAuthApiProvider).approve(
            displayCode: c,
            challengeId: challengeId ?? widget.challengeId,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Signed in on the other app')),
      );
      Navigator.of(context).maybePop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onQr(BarcodeCapture capture) {
    if (capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    // Preferred: interact://talk/approve-login?code=482913&c=<uuid>
    // Legacy: interact://auth/482913?c=<uuid>
    final code = (uri.queryParameters['code'] ??
            (uri.pathSegments.isNotEmpty ? uri.pathSegments.last : uri.path))
        .replaceAll(RegExp(r'\D'), '');
    final challengeId = uri.queryParameters['c'];
    setState(() {
      _scanning = false;
      _codeCtrl.text = code;
    });
    _approve(code: code, challengeId: challengeId);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Approve sign-in',
        subtitle: 'Use INTERACT as your login channel',
        showBrandGlyph: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Another INTERACT app can send a login code here (like SMS or '
            'WhatsApp), or show a QR for you to scan.',
            style: TextStyle(color: cs.outline, height: 1.35),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(6),
            ],
            decoration: const InputDecoration(
              labelText: '6-digit code',
              hintText: '482913',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _approve(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => _approve(),
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Approve'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => setState(() => _scanning = !_scanning),
            icon: Icon(_scanning ? Icons.close : Icons.qr_code_scanner),
            label: Text(_scanning ? 'Close scanner' : 'Scan QR'),
          ),
          if (_scanning) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 280,
                child: MobileScanner(onDetect: _onQr),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
