// SPDX-License-Identifier: AGPL-3.0
//
// Opens SocialReelsViewer with server reel engagement wired in.

import 'package:flutter/material.dart';

import '../models/social_post.dart';
import '../widgets/social/social_reels_viewer.dart';
import 'auth_service.dart';
import 'social_reels_api.dart';

class SocialReelsViewerLauncher {
  SocialReelsViewerLauncher._();
  static final SocialReelsViewerLauncher instance = SocialReelsViewerLauncher._();

  final _api = SocialReelsApi.instance;

  Future<void> open(
    BuildContext context, {
    required String authorId,
    required List<SocialPost> posts,
    int initialIndex = 0,
  }) async {
    if (posts.isEmpty) return;
    final myId = await AuthService.instance.localUserId();
    final enriched = await _api.enrichForViewer(
      authorId: authorId,
      localPosts: posts,
      myUserId: myId,
    );
    if (!context.mounted) return;
    await SocialReelsViewer.open(
      context,
      posts: enriched,
      initialIndex: initialIndex.clamp(0, enriched.length - 1),
    );
  }
}
