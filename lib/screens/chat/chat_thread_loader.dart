// SPDX-License-Identifier: AGPL-3.0
//
// Deep-link / notification entry for `/chat/:id` when no ChatThread was
// passed via `extra`. Loads thread metadata + messages, then shows the
// normal ChatThreadScreen (or a retryable error).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat.dart';
import '../../services/ai_contact_service.dart';
import '../../services/iot/iot_chat_bridge.dart';
import '../../services/chat_api.dart';
import 'chat_thread_screen.dart';

class ChatThreadLoader extends ConsumerStatefulWidget {
  const ChatThreadLoader({super.key, required this.threadId});
  final String threadId;

  @override
  ConsumerState<ChatThreadLoader> createState() => _ChatThreadLoaderState();
}

class _ChatThreadLoaderState extends ConsumerState<ChatThreadLoader> {
  late Future<ChatThread> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<ChatThread> _load() async {
    final id = widget.threadId.trim();
    if (id.isEmpty) throw Exception('Missing chat id');
    if (id == kAiThreadId) {
      return ref.read(aiContactServiceProvider).syntheticThread();
    }
    if (id == kIotAlertsThreadId) {
      return ref.read(iotChatBridgeProvider).syntheticThread();
    }

    // Prefer the chats list (richer title/preview) when online.
    try {
      final all = await ref.read(chatApiProvider).listAllThreads();
      for (final x in all) {
        if (x.id == id) return x;
      }
    } catch (_) {/* fall through to messages endpoint */}

    final view =
        await ref.read(chatApiProvider).loadThreadAndMessages(id, limit: 1);
    if (view.thread.id.isNotEmpty) return view.thread;

    return ChatThread(
      id: id,
      subjectType: 'general',
      subjectId: id,
      title: 'Chat',
      participants: const [],
      lastMessageAt: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<ChatThread>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError || snap.data == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Chat')),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.chat_bubble_outline, size: 48, color: cs.outline),
                    const SizedBox(height: 12),
                    Text(
                      'Couldn’t open this chat',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${snap.error ?? 'Unknown error'}'
                          .replaceFirst('Exception: ', ''),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => setState(() => _future = _load()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return ChatThreadScreen(thread: snap.data!);
      },
    );
  }
}
