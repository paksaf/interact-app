// SPDX-License-Identifier: AGPL-3.0
//
// Inbox of login OTPs delivered into Talk by other INTERACT apps.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/talk_auth_api.dart';
import '../../widgets/branded_app_bar.dart';
import 'approve_login_screen.dart';

class LoginCodesInboxScreen extends ConsumerStatefulWidget {
  const LoginCodesInboxScreen({super.key});

  @override
  ConsumerState<LoginCodesInboxScreen> createState() =>
      _LoginCodesInboxScreenState();
}

class _LoginCodesInboxScreenState extends ConsumerState<LoginCodesInboxScreen> {
  late Future<List<Map<String, dynamic>>> _items;

  @override
  void initState() {
    super.initState();
    _items = ref.read(talkAuthApiProvider).inbox();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: 'Login codes',
        subtitle: 'From other INTERACT apps',
        showBrandGlyph: true,
        actions: [
          IconButton(
            tooltip: 'Approve a code',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ApproveLoginScreen()),
            ),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _items,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(28),
              children: [
                Icon(Icons.pin_outlined, size: 56, color: cs.outline),
                const SizedBox(height: 12),
                const Text(
                  'No login codes yet',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
                ),
                const SizedBox(height: 8),
                Text(
                  'When another INTERACT app sends a login code to your number '
                  'via Talk, it will show up here — same idea as SMS or WhatsApp OTP.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.outline),
                ),
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ApproveLoginScreen(),
                    ),
                  ),
                  child: const Text('Approve a QR / code'),
                ),
              ],
            );
          }
          return RefreshIndicator(
            onRefresh: () async {
              setState(() => _items = ref.read(talkAuthApiProvider).inbox());
              await _items;
            },
            child: ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final r = rows[i];
                final app = (r['appName'] as String?)?.trim().isNotEmpty == true
                    ? r['appName'] as String
                    : (r['appId'] as String? ?? 'App');
                final code = r['code'] as String? ?? '';
                // WhatsApp-style: large monospace code first; QR is for TV/camera.
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: cs.primaryContainer,
                    child: Icon(Icons.lock_outline, color: cs.onPrimaryContainer),
                  ),
                  title: Text(
                    code,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                      letterSpacing: 3,
                      fontFamily: 'monospace',
                    ),
                  ),
                  subtitle: Text(
                    '$app · tap to approve · do not share',
                    style: TextStyle(color: cs.outline),
                  ),
                  trailing: IconButton(
                    tooltip: 'Copy code',
                    icon: const Icon(Icons.copy),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied')),
                      );
                    },
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ApproveLoginScreen(
                        initialCode: code,
                        challengeId: r['challengeId'] as String?,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
