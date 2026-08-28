// SPDX-License-Identifier: AGPL-3.0
//
// BlockedContactsScreen — manage the local block list (see BlockService for
// the v1 semantics: blocked peers can't ring you; their chats get a tag).
// Blocking happens from a chat's long-press menu; this screen unblocks.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/block_service.dart';
import '../widgets/branded_app_bar.dart';

class BlockedContactsScreen extends ConsumerWidget {
  const BlockedContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.read(blockServiceProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Blocked contacts'),
      body: ListenableBuilder(
        listenable: svc,
        builder: (context, _) {
          final rows = svc.all;
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.block, size: 40, color: cs.outline),
                    const SizedBox(height: 12),
                    const Text('No blocked contacts',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text(
                      'Long-press a chat and choose "Block" — blocked '
                      'people can\'t call or ring you on this device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: cs.outline),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final b = rows[i];
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: cs.errorContainer,
                  child: Icon(Icons.block, color: cs.error, size: 20),
                ),
                title: Text(b.name),
                trailing: TextButton(
                  onPressed: () async {
                    await svc.unblock(b.threadId);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('${b.name} unblocked')),
                      );
                    }
                  },
                  child: const Text('Unblock'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
