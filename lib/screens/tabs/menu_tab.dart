// SPDX-License-Identifier: AGPL-3.0
//
// MenuTab — branded 6-tile home menu (icon-sheet layout, 2026-06-02).
//
// Additive: surfaced as the last bottom-nav destination. Tiles route to the
// existing shell tabs + Invite, so nothing is removed. The Scaffold is
// transparent so the shell's AppBackground shows through (matches the other
// tabs). "Groups" has no route yet — shown as coming-soon.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/branded_app_bar.dart';

class MenuTab extends StatelessWidget {
  const MenuTab({super.key});

  @override
  Widget build(BuildContext context) {
    final items = <_Item>[
      _Item(Icons.chat_bubble_rounded, 'Chats', () => context.go('/chats')),
      _Item(Icons.groups_2_rounded, 'Townhall',
          () => context.push('/townhall')),
      _Item(Icons.podcasts_rounded, 'Walkie', () => context.push('/walkie')),
      _Item(Icons.call_rounded, 'Calls', () => context.go('/calls')),
      _Item(Icons.person_add_alt_1, 'Invite', () => context.push('/invite')),
      _Item(Icons.contacts_rounded, 'Contacts',
          () => context.go('/contacts')),
      _Item(Icons.person_rounded, 'Me', () => context.go('/me')),
      _Item(Icons.blur_on_rounded, 'Camera FX',
          () => context.push('/camera-effects')),
      _Item(Icons.lock_open_rounded, 'Approve login',
          () => context.push('/approve-login')),
      _Item(Icons.pin_rounded, 'Login codes',
          () => context.push('/login-codes')),
      _Item(Icons.qr_code_2_rounded, 'Login QR',
          () => context.push('/login-qr')),
    ];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Menu',
        subtitle: 'Everything in one place',
        showBrandGlyph: true,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GridView.count(
            crossAxisCount: 2,
            childAspectRatio: 1.1,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            children: [for (final it in items) _Card(item: it)],
          ),
        ),
      ),
    );
  }
}

class _Item {
  const _Item(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _Card extends StatelessWidget {
  const _Card({required this.item});
  final _Item item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: item.onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: cs.outlineVariant, width: 0.5),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(item.icon, size: 28, color: cs.primary),
            ),
            const SizedBox(height: 12),
            Text(
              item.label,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
