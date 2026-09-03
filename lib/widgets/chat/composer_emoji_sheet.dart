// SPDX-License-Identifier: AGPL-3.0
//
// Lightweight emoji picker for the chat composer — no third-party dep.

import 'package:flutter/material.dart';

/// Curated emoji sets (enough for daily chat; tap inserts at cursor).
class ComposerEmojiSheet extends StatelessWidget {
  const ComposerEmojiSheet({super.key, required this.onPick});

  final ValueChanged<String> onPick;

  static const _sections = <(String, List<String>)>[
    ('Smileys', [
      '😀', '😂', '🥹', '😍', '😘', '😎', '🤔', '😮', '😢', '😭',
      '🙏', '👍', '👎', '👏', '🙌', '💪', '✨', '🔥', '❤️', '💯',
    ]),
    ('Hands & people', [
      '👋', '🤝', '✌️', '🤞', '🫶', '👀', '🫡', '🤷', '🤦', '💁',
    ]),
    ('Objects', [
      '📎', '📷', '🎉', '🎁', '☕', '🍕', '✈️', '🏠', '📍', '⏰',
    ]),
    ('Flags & symbols', [
      '✅', '❌', '⚠️', '💡', '🔔', '📣', '🇵🇰', '🇦🇪', '🇹🇷', '🇷🇺',
    ]),
  ];

  static Future<void> show(
    BuildContext context, {
    required ValueChanged<String> onPick,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ComposerEmojiSheet(
        onPick: (e) {
          onPick(e);
          Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
        children: [
          for (final (title, emojis) in _sections) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 6),
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
            Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                for (final e in emojis)
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onPick(e),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(e, style: const TextStyle(fontSize: 26)),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Quick react row (long-press sheet) — extends the existing six with more.
const kTapbackEmojis = [
  '👍', '❤️', '😂', '🙏', '😮', '😢', '🎉', '🔥', '👏', '😍',
];
