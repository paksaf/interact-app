// SPDX-License-Identifier: AGPL-3.0
//
// Message search (P3). Queries the server index (/api/v1/talk/search) scoped to
// the caller's threads; optional [threadId] narrows to one conversation. Tapping
// a hit resolves the ChatThread and opens it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/chat_api.dart';

class MessageSearchScreen extends ConsumerStatefulWidget {
  const MessageSearchScreen({super.key, this.threadId, this.initialQuery});
  final String? threadId;
  /// Optional pre-filled query — set by the voice assistant ("search <q>") so
  /// the screen opens with the query typed and the search already running.
  final String? initialQuery;

  @override
  ConsumerState<MessageSearchScreen> createState() => _MessageSearchScreenState();
}

class _MessageSearchScreenState extends ConsumerState<MessageSearchScreen> {
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _hits = const [];
  bool _busy = false;
  bool _ran = false;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _ctrl.text = q;
      // Run once the first frame is up so ScaffoldMessenger exists for errors.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run();
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final q = _ctrl.text.trim();
    if (q.length < 2) return;
    setState(() { _busy = true; _ran = true; });
    try {
      final hits = await ref.read(chatApiProvider).searchMessages(q, threadId: widget.threadId);
      if (mounted) setState(() => _hits = hits);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Search failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String threadId) async {
    try {
      final view = await ref.read(chatApiProvider).loadThreadAndMessages(threadId);
      if (!mounted) return;
      context.push('/chat/${view.thread.id}', extra: view.thread);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open chat: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _run(),
          decoration: InputDecoration(
            hintText: widget.threadId == null ? 'Search all messages' : 'Search this chat',
            border: InputBorder.none,
          ),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.search), onPressed: _busy ? null : _run),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : (!_ran
              ? Center(child: Text('Type at least 2 characters', style: TextStyle(color: cs.outline)))
              : (_hits.isEmpty
                  ? Center(child: Text('No matches', style: TextStyle(color: cs.outline)))
                  : ListView.separated(
                      itemCount: _hits.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final h = _hits[i];
                        final body = (h['body'] as String?) ?? '';
                        final ts = DateTime.tryParse((h['createdAt'] as String?) ?? '');
                        return ListTile(
                          leading: const Icon(Icons.chat_bubble_outline),
                          title: Text(body, maxLines: 2, overflow: TextOverflow.ellipsis),
                          subtitle: ts != null
                              ? Text('${ts.toLocal()}'.split('.').first)
                              : null,
                          onTap: () => _open((h['threadId'] as String?) ?? ''),
                        );
                      },
                    ))),
    );
  }
}
