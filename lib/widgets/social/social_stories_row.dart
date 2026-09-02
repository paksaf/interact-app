// SPDX-License-Identifier: AGPL-3.0
//
// WhatsApp-style status rings — recent media updates by author.

import 'package:flutter/material.dart';

import '../../models/social_post.dart';
import '../user_avatar.dart';

class SocialStoriesRow extends StatelessWidget {
  const SocialStoriesRow({
    super.key,
    required this.storiesByAuthor,
    required this.myAuthorId,
    required this.myName,
    this.myAvatarUrl,
    required this.onAddStory,
    required this.onOpenStories,
  });

  final Map<String, List<SocialPost>> storiesByAuthor;
  final String myAuthorId;
  final String myName;
  final String? myAvatarUrl;
  final VoidCallback onAddStory;
  final void Function(String authorId, List<SocialPost> posts) onOpenStories;

  static const _ringColors = [
    Color(0xFFEC4899),
    Color(0xFFF97316),
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
  ];

  @override
  Widget build(BuildContext context) {
    final others = storiesByAuthor.entries
        .where((e) => e.key != myAuthorId && e.value.isNotEmpty)
        .toList();
    final mine = storiesByAuthor[myAuthorId] ?? const <SocialPost>[];

    return SizedBox(
      height: 108,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _StoryBubble(
            label: mine.isEmpty ? 'Add status' : 'Your status',
            name: myName,
            avatarUrl: myAvatarUrl,
            hasRing: mine.isNotEmpty,
            ringIndex: 0,
            onTap: mine.isEmpty ? onAddStory : () => onOpenStories(myAuthorId, mine),
            onLongPress: onAddStory,
            isAdd: mine.isEmpty,
          ),
          ...others.asMap().entries.map((entry) {
            final authorId = entry.value.key;
            final posts = entry.value.value;
            final name = posts.first.authorName;
            final avatar = posts.first.authorAvatarUrl;
            return _StoryBubble(
              label: name.split(' ').first,
              name: name,
              avatarUrl: avatar,
              hasRing: true,
              ringIndex: (entry.key + 1) % _ringColors.length,
              onTap: () => onOpenStories(authorId, posts),
            );
          }),
        ],
      ),
    );
  }
}

class _StoryBubble extends StatelessWidget {
  const _StoryBubble({
    required this.label,
    required this.name,
    this.avatarUrl,
    required this.hasRing,
    required this.ringIndex,
    required this.onTap,
    this.onLongPress,
    this.isAdd = false,
  });

  final String label;
  final String name;
  final String? avatarUrl;
  final bool hasRing;
  final int ringIndex;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isAdd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ringColor = SocialStoriesRow._ringColors[ringIndex];

    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                if (hasRing)
                  Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: SweepGradient(
                        colors: [
                          ringColor,
                          ringColor.withValues(alpha: 0.4),
                          ringColor,
                        ],
                      ),
                    ),
                  ),
                Container(
                  width: hasRing ? 62 : 64,
                  height: hasRing ? 62 : 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: cs.surface,
                    border: hasRing
                        ? null
                        : Border.all(color: cs.outlineVariant, width: 2),
                  ),
                  child: isAdd
                      ? Icon(Icons.add, color: cs.primary, size: 28)
                      : UserAvatar(
                          url: avatarUrl,
                          name: name,
                          radius: hasRing ? 29 : 30,
                        ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: 72,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
