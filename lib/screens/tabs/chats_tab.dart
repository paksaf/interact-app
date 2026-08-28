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
import '../../services/auth_service.dart';
import '../../services/block_service.dart';
import '../../services/chat_api.dart';
import '../../utils/chat_formatters.dart';
import '../../utils/phone_normalize.dart';
import '../../widgets/branded_app_bar.dart';
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
    _threads = _loadThreads();
  }

  /// Load threads with a reactive-refresh retry: on a 401 (access token
  /// rejected), silently renew ONCE via the refresh manager and retry. A true
  /// server revoke flips [AuthService.sessionRevoked] → the router redirects to
  /// sign-in; a network failure keeps us signed in and just surfaces a retry.
  Future<List<ChatThread>> _loadThreads() async {
    final api = ref.read(chatApiProvider);
    try {
      return await api.listAllThreads();
    } catch (e) {
      if (e.toString().contains('401')) {
        final outcome =
            await ref.read(authServiceProvider).attemptSilentResume();
        if (outcome == RefreshOutcome.refreshed ||
            outcome == RefreshOutcome.offlineKeep) {
          return api.listAllThreads();
        }
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Do the work first, then setState with a BLOCK body (returns void).
    // `setState(() => x = future)` returns the Future from the arrow, which
    // Flutter rejects ("setState callback returned a Future").
    final f = _loadThreads();
    setState(() {
      _threads = f;
    });
    await f;
  }

  Future<void> _newMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('New chat'),
              subtitle: const Text('By phone, email, or @username'),
              onTap: () { Navigator.pop(ctx); _newChat(); },
            ),
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('New group'),
              subtitle: const Text('Name it, add members'),
              onTap: () { Navigator.pop(ctx); context.push('/new-group'); },
            ),
            ListTile(
              leading: const Icon(Icons.campaign_outlined),
              title: const Text('New channel'),
              subtitle: const Text('Broadcast — only you post'),
              onTap: () { Navigator.pop(ctx); _newChannel(); },
            ),
            ListTile(
              leading: const Icon(Icons.workspaces_outline),
              title: const Text('New community'),
              subtitle: const Text('Group your teams together'),
              onTap: () { Navigator.pop(ctx); _newCommunity(); },
            ),
          ],
        ),
      ),
    );
  }

  /// Prompt for a single-line title (reused by channel + community).
  Future<String?> _promptTitle(String heading, String hint) async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(heading),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Create')),
        ],
      ),
    );
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _newChannel() async {
    final title = await _promptTitle('New channel', 'e.g. Company Announcements');
    if (title == null || !mounted) return;
    try {
      final thread = await ref.read(chatApiProvider).createChannel(title);
      if (!mounted) return;
      context.push('/chat/${thread.id}', extra: thread);
      await _refresh();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create channel: $e')));
    }
  }

  Future<void> _newCommunity() async {
    final title = await _promptTitle('New community', 'e.g. Karachi Ops');
    if (title == null || !mounted) return;
    try {
      await ref.read(chatApiProvider).createCommunity(title);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Community "$title" created — add groups from the group menu.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create community: $e')));
    }
  }

  Future<void> _newChat() async {
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewChatDialog(),
    );
    final q = input?.trim() ?? '';
    if (q.isEmpty) return;
    try {
      final api = ref.read(chatApiProvider);
      // @handle → lookup → start chat by phone/email. Plain email still works
      // (contains '@' but not a leading handle). Phone otherwise.
      final looksEmail = q.contains('@') && !q.startsWith('@');
      final looksPhone = RegExp(r'^\+?\d[\d\s-]{6,}$').hasMatch(q);
      final isHandle = !looksPhone &&
          !looksEmail &&
          (q.startsWith('@') ||
              RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,31}$').hasMatch(q));
      String? peerPhone;
      String? peerEmail;
      if (isHandle) {
        final peer = await api.lookupUsername(q);
        if (!mounted) return;
        if (peer == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No INTERACT user with handle $q')),
          );
          return;
        }
        peerPhone = peer.phone;
        peerEmail = peer.email;
        if ((peerPhone == null || peerPhone.isEmpty) &&
            (peerEmail == null || peerEmail.isEmpty)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${peer.fullName ?? q} has no reachable phone/email on file',
              ),
            ),
          );
          return;
        }
      } else if (looksEmail) {
        peerEmail = q;
      } else {
        peerPhone = normalizeInteractPhone(q) ?? q;
      }
      final result = await api.createDirectThread(
            peerPhone: peerPhone,
            peerEmail: peerEmail,
          );
      if (!mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          // Registered peer → open the thread immediately.
          context.push('/chat/${thread.id}', extra: thread);
          await _refresh();
        case DirectThreadUnregistered(
            :final rawPhone,
            :final normalizedPhone,
            isEmail: final wasEmail,
          ):
          if (wasEmail) {
            // Can't SMS-invite an email — tell the user to invite by number.
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  '$rawPhone isn\'t on INTERACT yet. Invite them by phone number instead.',
                ),
              ),
            );
          } else {
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

  /// Long-press actions on a chat row. v1: Block / Unblock (local — see
  /// BlockService). Groups/channels aren't blockable — nothing rings from
  /// them — so the sheet only shows for 1:1 threads.
  Future<void> _threadActions(ChatThread t) async {
    final blocks = ref.read(blockServiceProvider);
    final isBlocked = blocks.isBlocked(t.id);
    if (t.isGroup || t.isChannel) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(isBlocked ? Icons.check_circle_outline : Icons.block,
                  color: isBlocked ? null : Theme.of(ctx).colorScheme.error),
              title: Text(isBlocked
                  ? 'Unblock ${t.title}'
                  : 'Block ${t.title}'),
              subtitle: isBlocked
                  ? null
                  : const Text('They won\'t be able to call or ring you'),
              onTap: () =>
                  Navigator.pop(ctx, isBlocked ? 'unblock' : 'block'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'block') {
      await blocks.block(t.id, t.title);
    } else {
      await blocks.unblock(t.id);
    }
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(action == 'block'
            ? '${t.title} blocked — manage in Me → Blocked contacts'
            : '${t.title} unblocked')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: _searching ? _searchAppBar(context) : _normalAppBar(context),
      floatingActionButton: FloatingActionButton(
        onPressed: _newMenu,
        tooltip: 'New chat or group',
        backgroundColor: Theme.of(context).colorScheme.secondary,
        foregroundColor: Colors.white,
        child: const Icon(Icons.edit_outlined),
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
              // 401 here means a silent refresh was already attempted and did
              // NOT yield a usable session (offline, or transient server
              // error) — we are NOT necessarily signed out. A true revoke is
              // handled by the router redirect, so keep this message soft and
              // retry-oriented rather than telling the user they're signed out.
              final unauthorized = snap.error.toString().contains('401');
              return _ErrorState(
                message: unauthorized
                    ? "Couldn't refresh your session just now. Check your "
                        "connection and tap Retry — you're still signed in."
                    : '${snap.error}',
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
                    blocked: ref.read(blockServiceProvider).isBlocked(t.id),
                    onTap: () =>
                        context.push('/chat/${t.id}', extra: t),
                    onLongPress: () => _threadActions(t),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  PreferredSizeWidget _normalAppBar(BuildContext context) {
    return BrandedAppBar(
      title: 'Chats',
      subtitle: 'Messages & invites',
      showBrandGlyph: true,
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search chats',
          onPressed: _toggleSearch,
        ),
      ],
    );
  }

  PreferredSizeWidget _searchAppBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: _toggleSearch,
      ),
      title: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: cs.surface.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(21),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: cs.outline),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                textAlignVertical: TextAlignVertical.center,
                decoration: const InputDecoration(
                  hintText: 'Search chats',
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_query.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
                child: Icon(Icons.clear, size: 18, color: cs.outline),
              ),
          ],
        ),
      ),
      titleTextStyle: TextStyle(color: cs.onSurface, fontSize: 15),
    );
  }
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile({
    required this.thread,
    required this.onTap,
    this.onLongPress,
    this.blocked = false,
  });
  final ChatThread thread;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Locally blocked peer (BlockService) — shows a "Blocked" tag.
  final bool blocked;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unread = thread.unreadCount > 0;
    return Material(
      color: unread ? cs.primary.withValues(alpha: 0.04) : Colors.transparent,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(1.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: (unread ? cs.primary : cs.outlineVariant)
                  .withValues(alpha: unread ? 0.55 : 0.4),
              width: 1.5,
            ),
          ),
          child: CircleAvatar(
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
            if (blocked)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Blocked',
                    style: TextStyle(fontSize: 10, color: cs.error)),
              ),
            if (thread.isGroup)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.group, size: 14, color: cs.outline),
              )
            else if (thread.isChannel)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.campaign, size: 14, color: cs.outline),
              ),
          ],
        ),
        subtitle: Text(
          messagePreview(
            preview: thread.lastMessagePreview,
            lastKindRaw: thread.lastMessageKind,
          ),
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
        onLongPress: onLongPress,
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
            keyboardType: TextInputType.emailAddress,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Phone, email, or @username',
              hintText: '03XX…  ·  name@…  ·  @ali',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Enter a phone number, email, or @username. Registered peers '
            'open a direct chat. An unregistered number can be invited via SMS.',
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
