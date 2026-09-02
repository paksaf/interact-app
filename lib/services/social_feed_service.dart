// SPDX-License-Identifier: AGPL-3.0
//
// Friends & Family feed — local posts + channel announcements.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat.dart';
import '../models/social_post.dart';
import 'auth_service.dart';
import 'chat_api.dart';

final socialFeedServiceProvider = Provider<SocialFeedService>((ref) {
  return SocialFeedService(
    ref.read(authServiceProvider),
    ref.read(chatApiProvider),
  );
});

class SocialFeedService {
  SocialFeedService(this._auth, this._chatApi);

  final AuthService _auth;
  final ChatApi _chatApi;

  static const _key = 'talk.social_posts_v1';
  static const _maxPosts = 200;

  Future<List<SocialPost>> localPosts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => SocialPost.fromJson(e.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return const [];
    }
  }

  Future<SocialPost> publishStatus({
    required String body,
    SocialAudience audience = SocialAudience.family,
    String? mediaPath,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty && (mediaPath == null || mediaPath.isEmpty)) {
      throw ArgumentError('empty post');
    }
    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    final avatar = await _chatApi.getAvatar();
    final post = SocialPost(
      id: 'post-${DateTime.now().microsecondsSinceEpoch}',
      authorId: myId,
      authorName: myName,
      authorAvatarUrl: avatar,
      audience: audience,
      kind: mediaPath != null ? SocialPostKind.photo : SocialPostKind.status,
      body: trimmed,
      mediaPath: mediaPath,
      createdAt: DateTime.now(),
      pendingSync: true,
    );
    final existing = await localPosts();
    final encoded = [
      post.toJson(),
      ...existing.map((p) => p.toJson()),
    ];
    final trimmedList = encoded.length > _maxPosts
        ? encoded.sublist(0, _maxPosts)
        : encoded;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(trimmedList));
    return post;
  }

  Future<List<SocialPost>> buildFeed({SocialAudience? filter}) async {
    final local = await localPosts();
    final announcements = await _channelAnnouncements();
    final merged = [...local, ...announcements]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (filter == null) return merged;
    return merged
        .where((p) =>
            p.audience == filter ||
            p.kind == SocialPostKind.announcement ||
            p.audience == SocialAudience.everyone)
        .toList();
  }

  Future<List<SocialPost>> _channelAnnouncements() async {
    try {
      final threads = await _chatApi.listAllThreads();
      final channels = threads.where((t) => t.isChannel).toList();
      return channels
          .where((t) =>
              (t.lastMessagePreview ?? '').trim().isNotEmpty &&
              t.lastMessageAt.isAfter(
                DateTime.now().subtract(const Duration(days: 14)),
              ))
          .map(_postFromChannel)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  SocialPost _postFromChannel(ChatThread t) => SocialPost(
        id: 'ch-${t.id}-${t.lastMessageAt.millisecondsSinceEpoch}',
        authorId: 'channel',
        authorName: t.title,
        audience: SocialAudience.everyone,
        kind: SocialPostKind.announcement,
        body: t.lastMessagePreview ?? '',
        createdAt: t.lastMessageAt,
        sourceThreadId: t.id,
        sourceThreadTitle: t.title,
      );
}
