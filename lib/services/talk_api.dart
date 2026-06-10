// SPDX-License-Identifier: AGPL-3.0
//
// Talk API — thin wrapper over /api/v1/talk/* (to be added on
// qurbanisahulat backend in the next pass). Phase 1 falls back to
// /api/v1/meetings/token when the talk-specific endpoints aren't deployed
// yet, so the Flutter shell is testable today against the live #186
// Phase A backend.
//
// Host: qurbanisahulat.com (NOT interactpak.com — corp site has no
// /api/v1/* routes). JWT from interactpak.com auth verifies here via
// shared INTERACT_AUTH_SECRET. See [[sahulat_api_host]] memory.
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

const _kBase = 'https://qurbanisahulat.com';

// Server's `ok(payload)` envelope unwrapper — see chat_api.dart for the
// background. Same shape concern; same defensive pattern.
List<dynamic> _extractList(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is List) return data;
  if (data is Map) {
    for (final v in data.values) {
      if (v is List) return v;
    }
  }
  return const <dynamic>[];
}

final talkApiProvider = Provider<TalkApi>((ref) {
  return TalkApi(ref.read(authServiceProvider));
});

class TalkRoomToken {
  TalkRoomToken({
    required this.token,
    required this.wsUrl,
    required this.roomId,
    required this.iceServers,
    required this.expiresAt,
  });
  final String token;
  final String wsUrl;
  final String roomId;
  final List<Map<String, dynamic>> iceServers;
  final DateTime expiresAt;

  factory TalkRoomToken.fromJson(Map<String, dynamic> j) => TalkRoomToken(
        token: j['token'] as String,
        wsUrl: j['wsUrl'] as String,
        roomId: j['roomId'] as String,
        iceServers: ((j['iceServers'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        expiresAt: DateTime.parse(j['expiresAt'] as String),
      );
}

class TalkApi {
  TalkApi(this._auth);
  final AuthService _auth;

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  /// Create a new invite-code room. Server returns a 6-char code
  /// (uppercase A-Z + 2-9, no easily-confused chars). Host gets a token
  /// scoped to that room.
  ///
  /// `threadId` ties the call to a specific chat thread so the
  /// meetings backend can authorize via thread participation and
  /// later attach the CallLog to the right ChatThread. The server's
  /// /api/v1/meetings/token validator requires one of
  /// threadId/animalId/contractId/roomId, so when starting a call
  /// from a chat thread we MUST pass threadId (#145).
  Future<TalkRoomToken> createRoom({
    String? threadId,
    String mode = 'video',
  }) async {
    final h = await _headers();
    // Preferred endpoint (after backend extension)
    var res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/rooms'),
      headers: h,
      body: jsonEncode({
        if (threadId != null) 'threadId': threadId,
        'mode': mode,
      }),
    );
    // Phase 1 fallback — call the existing meetings/token endpoint with
    // the thread anchor. The previous `{general: true}` placeholder was
    // rejected by the server validator — fixed 2026-05-22.
    if (res.statusCode == 404) {
      res = await http.post(
        Uri.parse('$_kBase/api/v1/meetings/token'),
        headers: h,
        body: jsonEncode({
          if (threadId != null) 'threadId': threadId,
          'mode': mode,
        }),
      );
    }
    if (res.statusCode >= 400) {
      throw Exception('createRoom failed: ${res.statusCode} ${res.body}');
    }
    return TalkRoomToken.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Join an existing room by its 6-char code. Server validates the
  /// code is current + non-expired.
  Future<TalkRoomToken> joinRoom(String code) async {
    final h = await _headers();
    var res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/rooms/$code/join'),
      headers: h,
    );
    if (res.statusCode == 404) {
      // Fallback — request a token for a pseudo-anchor matching the
      // code. Works as long as both sides ask for the same anchor.
      res = await http.post(
        Uri.parse('$_kBase/api/v1/meetings/token'),
        headers: h,
        body: jsonEncode({'general': true, 'code': code}),
      );
    }
    if (res.statusCode >= 400) {
      throw Exception('joinRoom failed: ${res.statusCode} ${res.body}');
    }
    return TalkRoomToken.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// Recent contacts — server returns the last N peers the signed-in
  /// account has called or messaged across every INTERACT app.
  Future<List<Map<String, dynamic>>> recentContacts() async {
    final h = await _headers();
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/contacts?recent=20'),
      headers: h,
    );
    if (res.statusCode == 404) return []; // backend not yet extended
    if (res.statusCode >= 400) {
      throw Exception('contacts failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _extractList(body)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Call history — reuses CallLog from #186 Phase A. Already live.
  Future<List<Map<String, dynamic>>> callHistory() async {
    final h = await _headers();
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/meetings/log?limit=50'),
      headers: h,
    );
    if (res.statusCode >= 400) {
      throw Exception('history failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _extractList(body)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }
}
