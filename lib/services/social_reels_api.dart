// SPDX-License-Identifier: AGPL-3.0
//
// Server-linked YouTube reels — qurbanisahulat SocialReel rows with engagement.
// INTERACT Talk is the cross-app comms hub (buyers, sellers, maps, lifestyle,
// agri apps, etc.); reels live on the shared Talk backend.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/social_post.dart';
import 'api_base.dart';
import 'auth_service.dart';

String get _base => ApiBase.current;

final _uuidRe = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool isServerUserId(String id) => _uuidRe.hasMatch(id);

class SocialReelsApi {
  SocialReelsApi._();
  static final SocialReelsApi instance = SocialReelsApi._();

  Future<Map<String, String>> _headers({bool auth = false}) async {
    final h = <String, String>{'Accept': 'application/json'};
    if (auth) {
      final token = await AuthService.instance.token();
      if (token != null && token.isNotEmpty) {
        h['Authorization'] = 'Bearer $token';
      }
    }
    return h;
  }

  List<dynamic> _extractReelsList(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is Map && data['reels'] is List) {
      return data['reels'] as List;
    }
    return const [];
  }

  /// Fetch reels for [userId]. Uses /me/reels when [userId] is the signed-in user.
  Future<List<SocialPost>> fetchReelsAsPosts({
    required String userId,
    required String authorName,
    String? authorAvatarUrl,
    String? myUserId,
  }) async {
    if (!isServerUserId(userId)) return const [];

    final isSelf = myUserId != null && userId == myUserId;
    final path = isSelf
        ? '/api/v1/me/reels'
        : '/api/v1/users/$userId/reels';

    try {
      final res = await http
          .get(
            Uri.parse('$_base$path'),
            headers: await _headers(auth: isSelf),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return const [];
      return _extractReelsList(body)
          .whereType<Map>()
          .map((e) => _reelToPost(
                e.cast<String, dynamic>(),
                authorId: userId,
                authorName: authorName,
                authorAvatarUrl: authorAvatarUrl,
              ))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] fetch: $e');
      return const [];
    }
  }

  SocialPost _reelToPost(
    Map<String, dynamic> j, {
    required String authorId,
    required String authorName,
    String? authorAvatarUrl,
  }) {
    final reelId = j['id'] as String? ?? '';
    return SocialPost(
      id: 'reel-$reelId',
      reelId: reelId,
      authorId: authorId,
      authorName: authorName,
      authorAvatarUrl: authorAvatarUrl,
      audience: SocialAudience.friends,
      kind: SocialPostKind.video,
      body: (j['title'] as String?)?.trim() ?? 'Reel',
      mediaUrl: j['url'] as String?,
      createdAt: DateTime.now(),
      likeCount: (j['likeCount'] as num?)?.toInt() ?? 0,
      viewCount: (j['viewCount'] as num?)?.toInt() ?? 0,
      commentCount: (j['commentCount'] as num?)?.toInt() ?? 0,
      shareCount: (j['shareCount'] as num?)?.toInt() ?? 0,
      liked: j['liked'] as bool? ?? false,
    );
  }

  /// Merge server reel engagement into local story posts; append YouTube reels.
  Future<List<SocialPost>> enrichForViewer({
    required String authorId,
    required List<SocialPost> localPosts,
    String? myUserId,
  }) async {
    if (localPosts.isEmpty && !isServerUserId(authorId)) {
      return localPosts;
    }

    final name = localPosts.isNotEmpty
        ? localPosts.first.authorName
        : 'User';
    final avatar = localPosts.isNotEmpty
        ? localPosts.first.authorAvatarUrl
        : null;

    final serverReels = await fetchReelsAsPosts(
      userId: authorId,
      authorName: name,
      authorAvatarUrl: avatar,
      myUserId: myUserId,
    );
    if (serverReels.isEmpty) return localPosts;

    final byReelId = {for (final r in serverReels) r.reelId!: r};

    final mergedLocal = localPosts.map((p) {
      final rid = p.reelId;
      if (rid == null || !byReelId.containsKey(rid)) return p;
      final s = byReelId[rid]!;
      return p.copyWithEngagement(
        likeCount: s.likeCount,
        viewCount: s.viewCount,
        commentCount: s.commentCount,
        shareCount: s.shareCount,
        liked: s.liked,
      );
    }).toList();

    final localReelIds = mergedLocal
        .map((p) => p.reelId)
        .whereType<String>()
        .toSet();
    final extraReels =
        serverReels.where((r) => !localReelIds.contains(r.reelId)).toList();

    return [...mergedLocal, ...extraReels];
  }
}
