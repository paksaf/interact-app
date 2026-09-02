// SPDX-License-Identifier: AGPL-3.0
//
// Feed card — media-forward layout with reels-style preview.

import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/social_post.dart';
import '../../utils/chat_formatters.dart';
import '../user_avatar.dart';
import 'social_reels_viewer.dart';

class SocialFeedCard extends StatelessWidget {
  const SocialFeedCard({
    super.key,
    required this.post,
    required this.allMediaPosts,
  });

  final SocialPost post;
  final List<SocialPost> allMediaPosts;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kindLabel = switch (post.kind) {
      SocialPostKind.announcement => 'Announcement',
      SocialPostKind.photo => 'Photo',
      SocialPostKind.video => 'Video',
      SocialPostKind.location => 'Location',
      SocialPostKind.status => 'Update',
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            leading: UserAvatar(
              url: post.authorAvatarUrl,
              name: post.authorName,
              radius: 20,
            ),
            title: Text(
              post.authorName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '$kindLabel · ${post.audience.label} · ${relTime(post.createdAt)}',
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          ),
          if (post.hasLocalMedia) _MediaPreview(post: post, allMediaPosts: allMediaPosts),
          if (post.body.isNotEmpty && !post.hasLocalMedia)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
              child: Text(post.body),
            ),
          if (post.body.isNotEmpty && post.hasLocalMedia)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Text(
                post.body,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
          if (post.sourceThreadId != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () =>
                    Navigator.of(context).pushNamed('/chat/${post.sourceThreadId}'),
                child: Text('Open ${post.sourceThreadTitle ?? 'channel'}'),
              ),
            ),
        ],
      ),
    );
  }
}

class _MediaPreview extends StatelessWidget {
  const _MediaPreview({required this.post, required this.allMediaPosts});

  final SocialPost post;
  final List<SocialPost> allMediaPosts;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final idx = allMediaPosts.indexWhere((p) => p.id == post.id);
        SocialReelsViewer.open(
          context,
          posts: allMediaPosts,
          initialIndex: idx >= 0 ? idx : 0,
        );
      },
      child: AspectRatio(
        aspectRatio: post.isVideo ? 9 / 16 : 4 / 5,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (post.isPhoto)
              Image.file(
                File(post.mediaPath!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black12),
              )
            else
              _VideoThumb(path: post.mediaPath!),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
            if (post.isVideo)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white70),
                  ),
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 36),
                ),
              ),
            Positioned(
              right: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      post.isVideo ? Icons.movie_outlined : Icons.photo_outlined,
                      color: Colors.white,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'View',
                      style: TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF312E81), Color(0xFF1E1B4B)],
        ),
      ),
      child: const Center(
        child: Icon(Icons.videocam_outlined, color: Colors.white38, size: 48),
      ),
    );
  }
}
