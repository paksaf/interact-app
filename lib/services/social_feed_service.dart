// SPDX-License-Identifier: AGPL-3.0
//
// Friends & Family feed — local posts + channel announcements.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
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
    SocialPostKind? kindOverride,
  }) async {
    final trimmed = body.trim();
    if (trimmed.isEmpty && (mediaPath == null || mediaPath.isEmpty)) {
      throw ArgumentError('empty post');
    }
    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    final avatar = await _chatApi.getAvatar();
    SocialPostKind kind = kindOverride ??
        (mediaPath != null
            ? SocialPostKind.photo
            : SocialPostKind.status);
    String? storedPath;
    if (mediaPath != null && mediaPath.isNotEmpty) {
      storedPath = await _persistMedia(mediaPath);
    }
    final post = SocialPost(
      id: 'post-${DateTime.now().microsecondsSinceEpoch}',
      authorId: myId,
      authorName: myName,
      authorAvatarUrl: avatar,
      audience: audience,
      kind: kind,
      body: trimmed,
      mediaPath: storedPath,
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

  Future<SocialPost> publishMedia({
    required String localPath,
    required SocialPostKind kind,
    String body = '',
    SocialAudience audience = SocialAudience.family,
  }) async {
    if (kind != SocialPostKind.photo && kind != SocialPostKind.video) {
      throw ArgumentError('kind must be photo or video');
    }
    return publishStatus(
      body: body,
      audience: audience,
      mediaPath: localPath,
      kindOverride: kind,
    );
  }

  /// Recent media posts grouped by author (status-style row).
  Future<Map<String, List<SocialPost>>> recentStoriesByAuthor() async {
    final local = await localPosts();
    final stories = local.where((p) => p.isRecentStory).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final map = <String, List<SocialPost>>{};
    for (final p in stories) {
      map.putIfAbsent(p.authorId, () => []).add(p);
    }
    return map;
  }

  Future<String> _persistMedia(String sourcePath) async {
    final src = File(sourcePath);
    if (!await src.exists()) return sourcePath;
    final dir = await getApplicationDocumentsDirectory();
    final socialDir = Directory('${dir.path}/social_media');
    if (!await socialDir.exists()) {
      await socialDir.create(recursive: true);
    }
    final dot = sourcePath.lastIndexOf('.');
    final ext = dot >= 0 ? sourcePath.substring(dot + 1) : 'bin';
    final dest =
        '${socialDir.path}/sm-${DateTime.now().microsecondsSinceEpoch}.$ext';
    await src.copy(dest);
    return dest;
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
