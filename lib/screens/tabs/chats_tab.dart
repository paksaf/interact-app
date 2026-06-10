// SPDX-License-Identifier: AGPL-3.0
//
// Chats — backed by /api/v1/chat/threads?subjectType=general (Sahulat
// polymorphic ChatThread, #171). Pull-to-refresh, tap to open a
// thread, FAB to start a new chat by phone.
//
// Polish pass (2026-05-22):
// - Functional client-side search (filters by title + preview)
// - Swipe-to-archive (Dismissible) — archive is local-only until
//   server-side archived flag lands in Phase 2
// - Better relative-time formatting (Yesterday, weekday, date)
// - Voice/image preview placeholders instead of "—"
// - Unread row gets a subtle tinted background so it jumps out
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/chat.dart';
import '../../services/chat_api.dart';
import '../../utils/chat_formatters.dart';
import '../chat/invite_sheet.dart';

class ChatsTab extends ConsumerStatefulWidget {
  const ChatsTab({super.key});
  @override
  ConsumerState<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends ConsumerState<ChatsTab> {
  late Future<List<ChatThread>> _threads;
  bool _searching = false;
  String _query = '';
  final _searchCtrl = TextEditingController();

  // Local archive — Phase 1 stub. When server-side archived flag is
  // added, this becomes an optimistic toggle that calls the API.
  final Set<String> _archivedIds = <String>{};

  @override
  void initState() {
    super.initState();
    _threads = ref.read(chatApiProvider).listThreads();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _threads = ref.read(chatApiProvider).listThreads());
    await _threads;
  }

  Future<void> _newChat() async {
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewChatDialog(),
    );
    if (phone == null || phone.trim().isEmpty) return;
    try {
      final result = await ref
          .read(chatApiProvider)
          .createDirectThread(peerPhone: phone.trim());
      if (!mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          // Registered peer → open the thread immediately.
          context.push('/chat/${thread.id}', extra: thread);
          await _refresh();
        case DirectThreadUnregistered(:final rawPhone, :final normalizedPhone):
          // Not on INTERACT — surface the invite sheet so the user can
          // pick between Comms Hub invite (5 free) or OS SMS composer.
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start chat: $e')),
      );
    }
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = '';
        _searchCtrl.clear();
      }
    });
  }

  bool _matches(ChatThread t) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    if (t.title.toLowerCase().contains(q)) return true;
    final preview = t.lastMessagePreview ?? '';
    if (preview.toLowerCase().contains(q)) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _searching ? _searchAppBar(context) : _normalAppBar(context),
      floatingActionButton: FloatingActionButton(
        onPressed: _newChat,
        tooltip: 'New chat',
        child: const Icon(Icons.edit),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<ChatThread>>(
          future: _threads,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return _ErrorState(
                message: '${snap.error}',
                onRetry: _refresh,
              );
            }
            final all = snap.data ?? const <ChatThread>[];
            final visible = all
                .where((t) => !_archivedIds.contains(t.id))
                .where(_matches)
                .toList();
            if (all.isEmpty) return const _EmptyState();
            if (visible.isEmpty) return _NoMatchesState(query: _query);
            return ListView.separated(
              itemCount: visible.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final t = visible[i];
                return Dismissible(
                  key: ValueKey('thread-${t.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.archive_outlined,
                            color:
                                Theme.of(context).colorScheme.onSecondaryContainer),
                        const SizedBox(width: 8),
                        Text('Archive',
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSecondaryContainer)),
                      ],
                    ),
                  ),
                  onDismissed: (_) {
                    setState(() => _archivedIds.add(t.id));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Archived ${t.title}'),
                        action: SnackBarAction(
                          label: 'Undo',
                          onPressed: () =>
                              setState(() => _archivedIds.remove(t.id)),
                        ),
                      ),
                    );
                  },
                  child: _ThreadTile(
                    thread: t,
                    onTap: () =>
                        context.push('/chat/${t.id}', extra: t),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  AppBar _normalAppBar(BuildContext context) {
    return AppBar(
      title: const Text('Chats'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search chats',
          onPressed: _toggleSearch,
        ),
      ],
    );
  }

  AppBar _searchAppBar(BuildContext context) {
    return AppBar(
      title: TextField(
        controller: _searchCtrl,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search chats',
          border: InputBorder.none,
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _toggleSearch,
      ),
      actions: [
        if (_query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.clear),
            onPressed: () {
              _searchCtrl.clear();
              setState(() => _query = '');
            },
          ),
      ],
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({required this.thread, required this.onTap});
  final ChatThread thread;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unread = thread.unreadCount > 0;
    return Material(
      color: unread ? cs.primary.withValues(alpha: 0.04) : Colors.transparent,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: cs.primaryContainer,
          backgroundImage: thread.avatarUrl != null
              ? NetworkImage(thread.avatarUrl!)
              : null,
          child: thread.avatarUrl == null
              ? Text(
                  thread.title.isEmpty ? '?' : thread.title[0].toUpperCase(),
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : null,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                thread.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                ),
              ),
            ),
            if (thread.isGroup)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.group, size: 14, color: cs.outline),
              ),
          ],
        ),
        subtitle: Text(
          messagePreview(preview: thread.lastMessagePreview),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: unread ? cs.onSurface : cs.outline,
            fontWeight: unread ? FontWeight.w500 : FontWeight.normal,
          ),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              relTime(thread.lastMessageAt),
              style: TextStyle(
                fontSize: 11,
                color: unread ? cs.primary : cs.outline,
                fontWeight: unread ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            const SizedBox(height: 4),
            if (unread)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${thread.unreadCount}',
                  style: TextStyle(
                    color: cs.onPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      children: [
        Icon(Icons.chat_bubble_outline, size: 64, color: cs.primary),
        const SizedBox(height: 16),
        Text(
          'No chats yet',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Tap the pencil to start a chat with anyone in your contacts — '
          'or paste their phone number to invite them to INTERACT.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline),
        ),
      ],
    );
  }
}

class _NoMatchesState extends StatelessWidget {
  const _NoMatchesState({required this.query});
  final String query;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 80),
      children: [
        Icon(Icons.search_off, size: 56, color: cs.outline),
        const SizedBox(height: 12),
        Text(
          query.isEmpty
              ? 'No chats here'
              : 'No matches for "$query"',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Try a different name or phone number.',
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.error_outline, size: 48, color: cs.error),
        const SizedBox(height: 12),
        Text(
          'Could not load chats',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Center(
          child:
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}

class _NewChatDialog extends StatefulWidget {
  const _NewChatDialog();
  @override
  State<_NewChatDialog> createState() => _NewChatDialogState();
}

class _NewChatDialogState extends State<_NewChatDialog> {
  final _ctrl = TextEditingController();
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Start a new chat'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.phone,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '03XX XXXXXXX',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'If this number is registered on INTERACT, you\'ll start a '
            'direct chat. Otherwise, an invite is sent via SMS through '
            'the Comms Hub.',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Start chat'),
        ),
      ],
    );
  }
}
