// SPDX-License-Identifier: AGPL-3.0
//
// Find Friends — unified discovery hub (@username, phone, contacts, invite).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/chat_api.dart';
import '../../utils/phone_normalize.dart';
import '../../widgets/branded_app_bar.dart';
import '../chat/invite_sheet.dart';

class FindFriendsScreen extends ConsumerWidget {
  const FindFriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Find friends',
        subtitle: 'Phone, @username, or your address book',
        showBrandGlyph: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: Icon(Icons.alternate_email, color: cs.primary),
              title: const Text('Search by @username'),
              subtitle: const Text('Find someone on INTERACT without their number'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _lookup(context, ref),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.phone_outlined, color: cs.primary),
              title: const Text('Start chat by phone or email'),
              subtitle: const Text('Opens a thread or invite flow'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _lookup(context, ref, phoneMode: true),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.contacts_outlined, color: cs.primary),
              title: const Text('From your phone contacts'),
              subtitle: const Text('Pick someone and invite or message'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/device-contacts'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.person_add_alt_1, color: cs.primary),
              title: const Text('Invite via link or SMS'),
              subtitle: const Text('Share your invite code — 5 free hub sends'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/invite'),
            ),
          ),
          Card(
            child: ListTile(
              leading: Icon(Icons.groups_2_outlined, color: cs.primary),
              title: const Text('Family & Friends panel'),
              subtitle: const Text('Updates, circles, and location trace'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/social-panel'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'People you call or message across INTERACT apps appear automatically '
            'under Contacts — no manual sync.',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
        ],
      ),
    );
  }

  Future<void> _lookup(
    BuildContext context,
    WidgetRef ref, {
    bool phoneMode = false,
  }) async {
    final ctrl = TextEditingController();
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(phoneMode ? 'Phone or email' : '@username'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: phoneMode ? '+923… or name@email.com' : '@handle',
          ),
          keyboardType:
              phoneMode ? TextInputType.phone : TextInputType.text,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Search'),
          ),
        ],
      ),
    );
    if (q == null || q.isEmpty || !context.mounted) return;

    try {
      final api = ref.read(chatApiProvider);
      String? peerPhone;
      String? peerEmail;
      if (!phoneMode) {
        final peer = await api.lookupUsername(q);
        if (!context.mounted) return;
        if (peer == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No INTERACT user with handle $q')),
          );
          return;
        }
        peerPhone = peer.phone;
        peerEmail = peer.email;
      } else {
        final looksEmail = q.contains('@') && !q.startsWith('@');
        if (looksEmail) {
          peerEmail = q;
        } else {
          peerPhone = normalizeInteractPhone(q) ?? q;
        }
      }

      final result = await api.createDirectThread(
        peerPhone: peerPhone,
        peerEmail: peerEmail,
      );
      if (!context.mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          context.push('/chat/${thread.id}', extra: thread);
        case DirectThreadUnregistered(
            :final rawPhone,
            :final normalizedPhone,
            isEmail: final wasEmail,
          ):
          if (wasEmail) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '$rawPhone isn\'t on INTERACT yet. Try inviting by phone.',
                ),
              ),
            );
          } else {
            await showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              showDragHandle: false,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (_) => InviteSheet(
                rawPhone: rawPhone,
                normalizedPhone: normalizedPhone,
              ),
            );
          }
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not connect: $e')),
      );
    }
  }
}
