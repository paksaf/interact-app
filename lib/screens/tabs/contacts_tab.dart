// SPDX-License-Identifier: AGPL-3.0
//
// Contacts — recent + frequent peers from /api/v1/talk/contacts
// (cross-app: aggregates from CallLog + ChatThread participants). This
// is the UNIQUE moat — INTERACT shows your contacts from every other
// INTERACT app the moment you sign in, no manual sync.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/talk_api.dart';

class ContactsTab extends ConsumerStatefulWidget {
  const ContactsTab({super.key});
  @override
  ConsumerState<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends ConsumerState<ContactsTab> {
  late Future<List<Map<String, dynamic>>> _contacts;

  @override
  void initState() {
    super.initState();
    _contacts = ref.read(talkApiProvider).recentContacts();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Contacts'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            tooltip: 'Add contact',
            onPressed: () {},
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _contacts,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data ?? const [];
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline, size: 64, color: cs.outline),
                    const SizedBox(height: 16),
                    Text('No contacts yet',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Anyone you call or message across INTERACT apps will appear here automatically.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline, fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final name = r['name'] as String? ?? r['phone'] as String? ?? '';
              final phone = r['phone'] as String? ?? '';
              final src = r['source'] as String? ?? 'talk';
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: cs.primaryContainer,
                  child: Text(
                    name.isEmpty ? '?' : name[0].toUpperCase(),
                    style: TextStyle(color: cs.onPrimaryContainer),
                  ),
                ),
                title: Text(name),
                subtitle: Text([if (phone.isNotEmpty) phone, 'via $src'].join(' · ')),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.videocam_outlined),
                      tooltip: 'Video call',
                      onPressed: () => _quickCall(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.phone_outlined),
                      tooltip: 'Voice call',
                      onPressed: () => _quickCall(context),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _quickCall(BuildContext context) async {
    try {
      final tok = await ref.read(talkApiProvider).createRoom();
      final code = tok.roomId.split(':').last;
      if (!mounted) return;
      context.push('/room?code=$code&host=true');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not place call: $e')),
      );
    }
  }
}
