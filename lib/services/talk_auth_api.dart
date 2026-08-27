// SPDX-License-Identifier: AGPL-3.0
//
// Cross-app login via Talk — QR / code approve + OTP inbox.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'api_base.dart';

String get _kBase => ApiBase.current;

final talkAuthApiProvider =
    Provider<TalkAuthApi>((ref) => TalkAuthApi(ref.read(authServiceProvider)));

class TalkAuthApi {
  TalkAuthApi(this._auth);
  final AuthService _auth;

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  /// Other apps: mint a challenge (no auth required).
  Future<({String challengeId, String displayCode, String qrPayload, String expiresAt})>
      startChallenge({
    required String appId,
    String? appName,
    String? deviceLabel,
  }) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/auth/device/start'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'appId': appId,
        if (appName != null) 'appName': appName,
        if (deviceLabel != null) 'deviceLabel': deviceLabel,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('start challenge failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] ?? body) as Map<String, dynamic>;
    return (
      challengeId: data['challengeId'] as String,
      displayCode: data['displayCode'] as String,
      qrPayload: data['qrPayload'] as String,
      expiresAt: data['expiresAt'] as String,
    );
  }

  Future<void> approve({
    required String displayCode,
    String? challengeId,
  }) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/auth/device/approve'),
      headers: await _headers(),
      body: jsonEncode({
        'displayCode': displayCode,
        if (challengeId != null) 'challengeId': challengeId,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('Approve failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<List<Map<String, dynamic>>> inbox() async {
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/auth/inbox'),
      headers: await _headers(),
    );
    if (res.statusCode >= 400) return const [];
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] ?? body) as Map<String, dynamic>;
    final items = data['items'];
    if (items is! List) return const [];
    return items.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}
