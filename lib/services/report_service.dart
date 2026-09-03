// SPDX-License-Identifier: AGPL-3.0
//
// Report intake — message and reel moderation. Fail-soft; no content in logs.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'auth_service.dart';

/// Server-side reason codes (must match Cowork deploy).
enum ReportReason {
  spam('spam', 'Spam or scam'),
  harassment('harassment', 'Harassment or bullying'),
  hate('hate', 'Hate speech'),
  violence('violence', 'Violence or threats'),
  nudity('nudity', 'Nudity or sexual content'),
  misinformation('misinformation', 'Misinformation'),
  other('other', 'Something else');

  const ReportReason(this.wire, this.label);
  final String wire;
  final String label;
}

class ReportService {
  ReportService._();
  static final ReportService instance = ReportService._();

  Future<Map<String, String>> _headers() async {
    final t = await AuthService.instance.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  /// POST /api/v1/chat/threads/{t}/messages/{m}/report
  Future<bool> reportMessage({
    required String threadId,
    required String messageId,
    required ReportReason reason,
    String? note,
  }) async {
    return _post(
      '${ApiBase.current}/api/v1/chat/threads/$threadId/messages/$messageId/report',
      reason: reason,
      note: note,
    );
  }

  /// POST /api/v1/me/reels/{id}/report
  Future<bool> reportReel({
    required String reelId,
    required ReportReason reason,
    String? note,
  }) async {
    return _post(
      '${ApiBase.current}/api/v1/me/reels/$reelId/report',
      reason: reason,
      note: note,
    );
  }

  Future<bool> _post(
    String url, {
    required ReportReason reason,
    String? note,
  }) async {
    try {
      final trimmed = note?.trim();
      final res = await http
          .post(
            Uri.parse(url),
            headers: await _headers(),
            body: jsonEncode({
              'reason': reason.wire,
              if (trimmed != null && trimmed.isNotEmpty) 'note': trimmed,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      debugPrint('[report] failed ${res.statusCode}');
      return false;
    } catch (e) {
      debugPrint('[report] error: $e');
      return false;
    }
  }
}
