// SPDX-License-Identifier: AGPL-3.0
//
// INTERACT AI — dedicated local contact thread (Prompt C).
// Routes to AiRouterService; history stored in MessageRepository.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import '../models/talk_bearer.dart';
import 'ai_router_service.dart';
import 'ai_service.dart';
import 'auth_service.dart';
import 'message_repository.dart';

/// Stable local thread id — not synced to cloud or BLE discovery.
const kAiThreadId = 'interact-ai-system';
const kAiDisplayName = 'INTERACT AI';

final aiContactServiceProvider = Provider<AiContactService>((ref) {
  return AiContactService(
    ref.read(aiRouterProvider),
    ref.read(messageRepositoryProvider),
    ref.read(authServiceProvider),
  );
});

class AiContactService {
  AiContactService(this._router, this._repo, this._auth);

  final AiRouterService _router;
  final MessageRepository _repo;
  final AuthService _auth;

  ChatThread syntheticThread() => ChatThread(
        id: kAiThreadId,
        subjectType: 'general',
        subjectId: kAiThreadId,
        title: kAiDisplayName,
        participants: const [],
        lastMessageAt: DateTime.now(),
        lastMessagePreview: 'Ask me anything',
        avatarUrl: null,
      );

  bool isAiThread(String threadId) => threadId == kAiThreadId;

  /// User message + AI reply in one call.
  Future<List<Message>> sendUserMessage(String text) async {
    final body = text.trim();
    if (body.isEmpty) return const [];

    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    final now = DateTime.now();

    final userMsg = Message(
      id: 'ai-u-${now.microsecondsSinceEpoch}',
      threadId: kAiThreadId,
      senderId: myId,
      senderName: myName,
      kind: MessageKind.text,
      body: body,
      sentAt: now,
      isMine: true,
      bearer: TalkBearer.ai.wire,
    );

    final history = await _repo.loadLocal(kAiThreadId);
    final prompt = _buildPrompt(history, body);

    final response = await _router.complete(AiRequest(
      tier: AiTier.chat,
      systemPrompt:
          'You are INTERACT AI, a helpful assistant inside the INTERACT Talk app. '
          'Be concise and practical. User locale is Pakistan-first.',
      prompt: prompt,
      maxTokens: 512,
    ));

    final aiMsg = Message(
      id: 'ai-r-${DateTime.now().microsecondsSinceEpoch}',
      threadId: kAiThreadId,
      senderId: 'interact-ai',
      senderName: kAiDisplayName,
      kind: MessageKind.text,
      body: response.text.trim(),
      sentAt: DateTime.now(),
      isMine: false,
      bearer: TalkBearer.ai.wire,
    );

    final updated = [...history, userMsg, aiMsg];
    await _repo.saveLocalThread(kAiThreadId, updated);
    return [userMsg, aiMsg];
  }

  String _buildPrompt(List<Message> history, String latest) {
    final buf = StringBuffer();
    final recent = history.length > 10 ? history.sublist(history.length - 10) : history;
    for (final m in recent) {
      final who = m.isMine ? 'User' : kAiDisplayName;
      buf.writeln('$who: ${m.body}');
    }
    buf.writeln('User: $latest');
    buf.write('$kAiDisplayName:');
    return buf.toString();
  }
}
