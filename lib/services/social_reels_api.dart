// SPDX-License-Identifier: AGPL-3.0
//
// Server-linked SocialReel rows — all platforms + create/upload helpers.
// INTERACT Talk is the cross-app comms hub; reels live on the Talk backend.

import 'dart:convert';
import 'dart:io';

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

class ReelCaptionSuggestion {
  const ReelCaptionSuggestion({
    required this.caption,
    required this.hashtags,
  });

  final String caption;
  final List<String> hashtags;
}

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

  String? _absUrl(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '$_base$raw';
    return null;
  }

  /// Backend expects same-origin `/uploads/…` paths for local reel create.
  String? _uploadPath(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith('/uploads/')) return raw;
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.path.startsWith('/uploads/')) return uri.path;
    return null;
  }

  List<dynamic> _extractReelsList(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is Map && data['reels'] is List) {
      return data['reels'] as List;
    }
    return const [];
  }

  SocialPost? _reelJsonToPost(
    Map<String, dynamic> j, {
    required String authorId,
    required String authorName,
    String? authorAvatarUrl,
  }) {
    final reelId = j['id'] as String? ?? '';
    if (reelId.isEmpty) return null;
    final platform = ReelPlatform.fromWire(j['platform'] as String?);
    final mediaType = j['mediaType'] as String?;
    final kind = mediaType == 'photo'
        ? SocialPostKind.photo
        : SocialPostKind.video;
    final displayAuthor =
        (j['authorName'] as String?)?.trim().isNotEmpty == true
            ? (j['authorName'] as String).trim()
            : authorName;

    return SocialPost(
      id: 'reel-$reelId',
      reelId: reelId,
      reelPlatform: platform,
      authorId: authorId,
      authorName: displayAuthor,
      authorAvatarUrl: authorAvatarUrl,
      audience: SocialAudience.friends,
      kind: kind,
      body: (j['title'] as String?)?.trim() ?? 'Reel',
      linkUrl: j['url'] as String?,
      mediaUrl: j['url'] as String?,
      serverMediaUrl: _absUrl(j['mediaUrl'] as String?),
      serverMediaType: mediaType,
      thumbnailUrl: _absUrl(j['thumbnailUrl'] as String?),
      embedHtml: j['embedHtml'] as String?,
      createdAt: DateTime.now(),
      likeCount: (j['likeCount'] as num?)?.toInt() ?? 0,
      viewCount: (j['viewCount'] as num?)?.toInt() ?? 0,
      commentCount: (j['commentCount'] as num?)?.toInt() ?? 0,
      shareCount: (j['shareCount'] as num?)?.toInt() ?? 0,
      liked: j['liked'] as bool? ?? false,
    );
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
          .map((e) => _reelJsonToPost(
                e.cast<String, dynamic>(),
                authorId: userId,
                authorName: authorName,
                authorAvatarUrl: authorAvatarUrl,
              ))
          .whereType<SocialPost>()
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] fetch: $e');
      return const [];
    }
  }

  /// POST /api/v1/me/reels — YouTube, TikTok, or X/Twitter link.
  Future<SocialPost?> createReelFromUrl(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    try {
      final res = await http
          .post(
            Uri.parse('$_base/api/v1/me/reels'),
            headers: {
              ...await _headers(auth: true),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'url': trimmed}),
          )
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final reel = data['reel'];
      if (reel is! Map) return null;
      final myId = await AuthService.instance.localUserId() ?? '';
      final myName = await AuthService.instance.displayName() ?? 'Me';
      return _reelJsonToPost(
        reel.cast<String, dynamic>(),
        authorId: myId,
        authorName: myName,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] createReelFromUrl: $e');
      return null;
    }
  }

  /// POST /api/v1/me/reels/local after media upload.
  Future<SocialPost?> createLocalReel({
    required String mediaUrl,
    required String mediaType,
    String? thumbnailUrl,
    String? title,
  }) async {
    final mediaPath = _uploadPath(mediaUrl);
    if (mediaPath == null) return null;
    final thumbPath = thumbnailUrl != null ? _uploadPath(thumbnailUrl) : null;
    try {
      final res = await http
          .post(
            Uri.parse('$_base/api/v1/me/reels/local'),
            headers: {
              ...await _headers(auth: true),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'mediaUrl': mediaPath,
              'mediaType': mediaType,
              if (thumbPath != null) 'thumbnailUrl': thumbPath,
              if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
            }),
          )
          .timeout(const Duration(seconds: 20));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final reel = data['reel'];
      if (reel is! Map) return null;
      final myId = await AuthService.instance.localUserId() ?? '';
      final myName = await AuthService.instance.displayName() ?? 'Me';
      return _reelJsonToPost(
        reel.cast<String, dynamic>(),
        authorId: myId,
        authorName: myName,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] createLocalReel: $e');
      return null;
    }
  }

  /// Multipart upload → absolute URL (reuses Talk media endpoint).
  Future<({String url, String mediaType})?> uploadMediaFile(File file) async {
    try {
      final token = await AuthService.instance.token();
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/api/v1/media/upload'),
      );
      if (token != null && token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
      final res = await http.Response.fromStream(await req.send());
      if (res.statusCode >= 400) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      final rel = (data['url'] as String?) ?? '';
      if (rel.isEmpty) return null;
      final abs = rel.startsWith('http') ? rel : '$_base$rel';
      return (
        url: abs,
        mediaType: (data['mediaType'] as String?) ?? 'file',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] uploadMediaFile: $e');
      return null;
    }
  }

  /// POST /api/v1/me/reels/caption — server-side AI; no client keys.
  Future<ReelCaptionSuggestion?> suggestCaption({
    String? title,
    String? transcript,
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/api/v1/me/reels/caption'),
            headers: {
              ...await _headers(auth: true),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
              if (transcript != null && transcript.trim().isNotEmpty)
                'transcript': transcript.trim(),
            }),
          )
          .timeout(const Duration(seconds: 25));
      if (res.statusCode == 503) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final caption = (data['caption'] as String?)?.trim() ?? '';
      final tags = (data['hashtags'] as List?)
              ?.whereType<String>()
              .toList() ??
          const <String>[];
      if (caption.isEmpty && tags.isEmpty) return null;
      return ReelCaptionSuggestion(caption: caption, hashtags: tags);
    } catch (e) {
      if (kDebugMode) debugPrint('[SocialReelsApi] suggestCaption: $e');
      return null;
    }
  }

  /// Merge server reel engagement into local story posts; append server reels.
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
      if (rid != null && byReelId.containsKey(rid)) {
        return byReelId[rid]!;
      }
      return p;
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
