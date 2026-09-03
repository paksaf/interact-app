// SPDX-License-Identifier: AGPL-3.0
//
// Reel engagement API — like / view / comment / share on SocialReel rows.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../services/api_base.dart';
import '../services/auth_service.dart';

String get _base => ApiBase.current;

Map<String, dynamic> _extractObject(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is Map<String, dynamic>) return data;
  return <String, dynamic>{};
}

class ReelComment {
  const ReelComment({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.authorName,
    this.authorAvatarUrl,
  });

  final String id;
  final String body;
  final DateTime createdAt;
  final String authorName;
  final String? authorAvatarUrl;

  factory ReelComment.fromJson(Map<String, dynamic> j) => ReelComment(
        id: j['id'] as String? ?? '',
        body: j['body'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
        authorName: (j['author'] as Map?)?['name'] as String? ?? 'User',
        authorAvatarUrl: (j['author'] as Map?)?['avatarUrl'] as String?,
      );
}

class ReelEngagementService {
  ReelEngagementService._();
  static final ReelEngagementService instance = ReelEngagementService._();

  Future<Map<String, String>> _headers({bool auth = false}) async {
    final h = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    };
    if (auth) {
      final token = await AuthService.instance.token();
      if (token != null && token.isNotEmpty) {
        h['Authorization'] = 'Bearer $token';
      }
    }
    return h;
  }

  Uri _uri(String path) => Uri.parse('$_base$path');

  Future<({bool liked, int likeCount})?> toggleLike(String reelId) async {
    try {
      final res = await http
          .post(
            _uri('/api/v1/me/reels/$reelId/like'),
            headers: await _headers(auth: true),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      return (
        liked: data['liked'] == true,
        likeCount: (data['likeCount'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[ReelEngagement] toggleLike: $e');
      return null;
    }
  }

  Future<int?> recordView(String reelId) async {
    try {
      final authed = await AuthService.instance.hasValidToken();
      final res = await http
          .post(
            _uri('/api/v1/me/reels/$reelId/view'),
            headers: await _headers(auth: authed),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      return (data['viewCount'] as num?)?.toInt();
    } catch (e) {
      if (kDebugMode) debugPrint('[ReelEngagement] recordView: $e');
      return null;
    }
  }

  Future<int?> recordShare(String reelId) async {
    try {
      final res = await http
          .post(
            _uri('/api/v1/me/reels/$reelId/share'),
            headers: await _headers(auth: true),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      return (data['shareCount'] as num?)?.toInt();
    } catch (e) {
      if (kDebugMode) debugPrint('[ReelEngagement] recordShare: $e');
      return null;
    }
  }

  Future<List<ReelComment>> listComments(String reelId, {String? cursor}) async {
    try {
      final q = cursor != null ? '?cursor=$cursor' : '';
      final res = await http
          .get(
            _uri('/api/v1/me/reels/$reelId/comments$q'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      final items = data['items'];
      if (items is! List) return const [];
      return items
          .whereType<Map>()
          .map((e) => ReelComment.fromJson(e.cast<String, dynamic>()))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('[ReelEngagement] listComments: $e');
      return const [];
    }
  }

  Future<({ReelComment comment, int commentCount})?> addComment(
    String reelId,
    String body,
  ) async {
    try {
      final res = await http
          .post(
            _uri('/api/v1/me/reels/$reelId/comments'),
            headers: await _headers(auth: true),
            body: jsonEncode({'body': body.trim()}),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 && res.statusCode != 201) return null;
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      final commentJson = data['comment'];
      if (commentJson is! Map<String, dynamic>) return null;
      return (
        comment: ReelComment.fromJson(commentJson),
        commentCount: (data['commentCount'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[ReelEngagement] addComment: $e');
      return null;
    }
  }
}
