// SPDX-License-Identifier: AGPL-3.0
//
// ChatAiActions — the ✨ button menu inside a chat thread. Three
// canonical actions:
//
//   1. Summarise — short paragraph of the last N messages
//   2. Suggest reply — 3 short reply options based on the last inbound message
//   3. Translate to Urdu — rewrites the composer text (or last message)
//
// All three go through `aiRouterProvider` which decides on-device vs
// cloud per the user's "Private AI" setting + per-tier policy. Result
// is shown in a bottom sheet with copy + insert-into-composer actions.
// Every call is audited (see ai_audit_log.dart) so the user can prove
// after the fact which messages left the device.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/chat.dart';
import '../../services/ai_router_service.dart';
import '../../services/ai_service.dart';

enum _AiAction { summarise, suggestReply, translateUrdu }

/// Opens the ✨ AI actions menu anchored to [context]. Provide the
/// thread + the visible messages so we can build prompts without
/// re-fetching. `onInsertToComposer` lets the chat screen jam the AI
/// response into the text field; if null, only Copy is offered.
Future<void> showChatAiActions({
  required BuildContext context,
  required WidgetRef ref,
  required ChatThread thread,
  required List<Message> messages,
  String composerText = '',
  void Function(String text)? onInsertToComposer,
}) async {
  final action = await showModalBottomSheet<_AiAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 20),
                SizedBox(width: 8),
                Text('AI assist',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.short_text),
            title: const Text('Summarise thread'),
            subtitle: const Text('Short paragraph of the last messages'),
            onTap: () => Navigator.of(ctx).pop(_AiAction.summarise),
          ),
          ListTile(
            leading: const Icon(Icons.reply),
            title: const Text('Suggest reply'),
            subtitle: const Text('3 short reply options'),
            onTap: () => Navigator.of(ctx).pop(_AiAction.suggestReply),
          ),
          ListTile(
            leading: const Icon(Icons.translate),
            title: const Text('Translate to Urdu'),
            subtitle: Text(
              composerText.trim().isEmpty
                  ? 'Translates the most recent message'
                  : 'Translates your composer draft',
            ),
            onTap: () => Navigator.of(ctx).pop(_AiAction.translateUrdu),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );

  if (action == null || !context.mounted) return;

  final req = _buildRequest(action, thread, messages, composerText);
  await _runAndShowResult(
    context: context,
    ref: ref,
    request: req,
    actionLabel: _label(action),
    onInsertToComposer: onInsertToComposer,
  );
}

AiRequest _buildRequest(
  _AiAction action,
  ChatThread thread,
  List<Message> messages,
  String composerText,
) {
  // Cap context at the last 30 messages for token budget. Voice
  // messages without a transcript become "[voice 12s]".
  final tail = messages.length > 30
      ? messages.sublist(messages.length - 30)
      : messages;
  String render(Message m) {
    final who = m.isMine ? 'me' : m.senderName;
    if (m.kind == MessageKind.voice) {
      final t = m.transcript;
      if (t != null && t.isNotEmpty) return '$who (voice): $t';
      return '$who: [voice ${m.mediaDurationSec ?? 0}s, no transcript]';
    }
    return '$who: ${m.body}';
  }

  final transcript = tail.map(render).join('\n');

  switch (action) {
    case _AiAction.summarise:
      return AiRequest(
        tier: AiTier.chat,
        systemPrompt:
            'You are a helpful assistant inside the INTERACT chat app. '
            'Summarise the conversation in 3-5 sentences. Preserve names. '
            'Keep it concise — the user is skimming.',
        prompt: 'Thread title: ${thread.title}\n\n$transcript',
        maxTokens: 220,
        temperature: 0.4,
      );
    case _AiAction.suggestReply:
      // Find the most recent non-mine message — that's what we're
      // replying to. Fall back to the last message if all are mine.
      final lastInbound = tail.reversed.firstWhere(
        (m) => !m.isMine,
        orElse: () => tail.last,
      );
      return AiRequest(
        tier: AiTier.chat,
        systemPrompt:
            'You are a helpful assistant inside the INTERACT chat app. '
            'Suggest 3 short reply options to the last inbound message. '
            'Number them 1, 2, 3 — one per line. Match the language of '
            'the inbound message (English or Urdu). Keep each under 20 words.',
        prompt:
            'Thread context:\n$transcript\n\nLast inbound:\n${render(lastInbound)}',
        maxTokens: 220,
        temperature: 0.8,
      );
    case _AiAction.translateUrdu:
      final source = composerText.trim().isNotEmpty
          ? composerText.trim()
          : (tail.isNotEmpty ? tail.last.body : '');
      return AiRequest(
        tier: AiTier.chat,
        systemPrompt:
            'Translate the user\'s text to natural conversational Urdu. '
            'Return ONLY the Urdu translation — no English, no notes.',
        prompt: source,
        maxTokens: 220,
        temperature: 0.3,
      );
  }
}

String _label(_AiAction a) {
  switch (a) {
    case _AiAction.summarise:
      return 'Summary';
    case _AiAction.suggestReply:
      return 'Suggested replies';
    case _AiAction.translateUrdu:
      return 'Urdu translation';
  }
}

Future<void> _runAndShowResult({
  required BuildContext context,
  required WidgetRef ref,
  required AiRequest request,
  required String actionLabel,
  void Function(String text)? onInsertToComposer,
}) async {
  // Loading sheet — keeps the user oriented while inference runs.
  // On-device call ~ 1-3s on a midrange phone, cloud call ~ 0.5-2s.
  showModalBottomSheet<void>(
    context: context,
    isDismissible: false,
    enableDrag: false,
    builder: (ctx) => const Padding(
      padding: EdgeInsets.all(24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 16),
          Text('Thinking…'),
        ],
      ),
    ),
  );

  AiResponse? res;
  Object? err;
  try {
    res = await ref.read(aiRouterProvider).complete(request);
  } catch (e) {
    err = e;
  }
  // Close loading sheet
  if (context.mounted) Navigator.of(context).pop();
  if (!context.mounted) return;

  if (err != null) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(children: [
              Icon(Icons.error_outline),
              SizedBox(width: 8),
              Text('AI request failed',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            Text(err.toString()),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    return;
  }

  final out = res!;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.92,
        builder: (_, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.auto_awesome, size: 18),
                  const SizedBox(width: 8),
                  Text(actionLabel,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: out.networkUsed
                          ? cs.tertiaryContainer
                          : cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          out.networkUsed ? Icons.cloud : Icons.lock_outline,
                          size: 12,
                          color: out.networkUsed
                              ? cs.onTertiaryContainer
                              : cs.onSecondaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          out.networkUsed ? 'cloud' : 'on-device',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: out.networkUsed
                                ? cs.onTertiaryContainer
                                : cs.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${out.modelUsed} · ${out.latencyMs}ms · '
                'in ${out.inputTokens} / out ${out.outputTokens}',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  controller: scroll,
                  child: SelectableText(
                    out.text,
                    style: const TextStyle(fontSize: 15, height: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: out.text));
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('Copied')),
                      );
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copy'),
                  ),
                  const SizedBox(width: 8),
                  if (onInsertToComposer != null)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () {
                          onInsertToComposer(out.text);
                          Navigator.of(ctx).pop();
                        },
                        icon: const Icon(Icons.send_outlined, size: 16),
                        label: const Text('Insert into composer'),
                      ),
                    )
                  else
                    Expanded(
                      child: FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close'),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
