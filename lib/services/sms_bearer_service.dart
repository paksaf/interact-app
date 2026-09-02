// SPDX-License-Identifier: AGPL-3.0
//
// User-confirmed SMS fallback — audit step 7 / Phase 4 P1.
// Calls qurbanisahulat POST /api/v1/talk/sms/send (Comms Hub → capcom6).

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/talk_bearer.dart';
import '../utils/phone_normalize.dart';
import 'api_base.dart';
import 'auth_service.dart';

final smsBearerServiceProvider = Provider<SmsBearerService>((ref) {
  return SmsBearerService(ref.read(authServiceProvider));
});

class SmsSendResult {
  const SmsSendResult({
    required this.delivered,
    this.providerId,
    this.error,
  });

  final bool delivered;
  final String? providerId;
  final String? error;
}

class SmsBearerService {
  SmsBearerService(this._auth);

  final AuthService _auth;
  static const _maxSmsBody = 160;

  /// Clip message for a single SMS segment (server adds INTERACT: prefix).
  static String clipForSms(String body) {
    final t = body.trim();
    if (t.length <= _maxSmsBody) return t;
    return '${t.substring(0, _maxSmsBody - 1)}…';
  }

  Future<SmsSendResult> sendConfirmed({
    required String toPhone,
    required String body,
    String? threadId,
  }) async {
    final e164 = normalizeInteractPhone(toPhone);
    if (e164 == null) {
      return const SmsSendResult(
        delivered: false,
        error: 'Invalid phone number',
      );
    }
    final clipped = clipForSms(body);
    if (clipped.isEmpty) {
      return const SmsSendResult(delivered: false, error: 'Empty message');
    }

    final token = await _auth.token();
    if (token == null) {
      return const SmsSendResult(
        delivered: false,
        error: 'Sign in required to send SMS',
      );
    }

    final url = '${ApiBase.current}/api/v1/talk/sms/send';
    try {
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'toPhone': e164,
              'body': clipped,
              if (threadId != null) 'threadId': threadId,
            }),
          )
          .timeout(const Duration(seconds: 20));

      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final data = decoded['data'] as Map<String, dynamic>?;
        final delivered = data?['delivered'] == true;
        return SmsSendResult(
          delivered: delivered,
          providerId: data?['providerId'] as String?,
          error: delivered ? null : 'SMS not delivered',
        );
      }
      final err = decoded['error'] as Map<String, dynamic>?;
      return SmsSendResult(
        delivered: false,
        error: (err?['message'] as String?) ?? 'SMS send failed (${resp.statusCode})',
      );
    } catch (e) {
      return SmsSendResult(delivered: false, error: '$e');
    }
  }

  TalkBearer get bearer => TalkBearer.sms;
}
