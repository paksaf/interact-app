// SPDX-License-Identifier: AGPL-3.0
//
// Communities browse (P2 — group-of-groups). Lists the communities I own or
// belong to (with thread counts), lets me create a new one, and — when opened
// with [attachThreadId] set — lets me attach that group thread to a community
// I own (server 403s if I'm not the owner). Backend: /api/v1/talk/communities.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/chat_api.dart';

class CommunitiesScreen extends ConsumerStatefulWidget {
  const CommunitiesScreen({super.key, this.attachThreadId});

  /// When non-null, tapping a community attaches this thread to it.
  final String? attachThreadId;

  @override
  ConsumerState<CommunitiesScreen> createState() => _CommunitiesScreenState();
}

class _CommunitiesScreenState extends ConsumerState<CommunitiesScreen> {
  List<Map<String, dynamic>> _items = const [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _busy = true; _error = null; });
    try {
      final items = await ref.read(chatApiProvider).listCommunities();
      if (mounted) setState(() { _items = items; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _busy = false; });
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New community'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: 'Community name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    try {
      await ref.read(chatApiProvider).createCommunity(title);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create: $e')));
      }
    }
  }

  Future<void> _attach(Map<String, dynamic> community) async {
    final id = (community['id'] as String?) ?? '';
    if (id.isEmpty) return;
    try {
      await ref.read(chatApiProvider).attachThreadToCommunity(id, widget.attachThreadId!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Added to ${community['title'] ?? 'community'}')),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not attach (only the owner can): $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final attaching = widget.attachThreadId != null;
    return Scaffold(
      appBar: AppBar(title: Text(attaching ? 'Add to community' : 'Communities')),
      floatingActionButton: attaching
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('New'),
            ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? Center(child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Could not load communities.\n$_error',
                      textAlign: TextAlign.center, style: TextStyle(color: cs.error)),
                ))
              : (_items.isEmpty
                  ? Center(child: Text(
                      attaching ? 'Create a community first' : 'No communities yet',
                      style: TextStyle(color: cs.outline)))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          final c = _items[i];
                          final count = (c['threadCount'] as num?)?.toInt() ?? 0;
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cs.primaryContainer,
                              child: Icon(Icons.groups_2_outlined, color: cs.onPrimaryContainer),
                            ),
                            title: Text((c['title'] as String?) ?? 'Community'),
                            subtitle: Text('$count group${count == 1 ? '' : 's'}'),
                            trailing: attaching ? const Icon(Icons.add_link) : null,
                            onTap: attaching ? () => _attach(c) : null,
                          );
                        },
                      ),
                    ))),
    );
  }
}
