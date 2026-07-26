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
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Talk backend base URL. Env-configurable (2026-07-02 connectivity canon)
/// so dev/staging builds don't hit production; defaults to the current
/// production host — zero behaviour change for normal builds.
/// Override: `--dart-define=INTERACT_TALK_API_BASE=https://staging.example`.
const _kBase = String.fromEnvironment(
  'INTERACT_TALK_API_BASE',
  defaultValue: 'https://qurbanisahulat.com',
);

/// Optional ephemeral-TURN mint endpoint (coturn REST-API scheme — same
/// contract as interactpak-nextjs /api/turn/credential and
/// Interact_com/interact-realtime nextjs/lib/rtc.ts). Default EMPTY =
/// feature off, so behaviour is unchanged until the operator sets
/// `--dart-define=INTERACT_TURN_CREDENTIAL_URL=https://interactpak.com/api/turn/credential`.
const kTurnCredentialUrl =
    String.fromEnvironment('INTERACT_TURN_CREDENTIAL_URL', defaultValue: '');

/// Fetch a short-lived TURN credential and return it as a flutter_webrtc
/// iceServers map entry. Returns null on ANY failure (endpoint disabled,
/// 4xx/5xx, malformed body, network error) so callers keep the server-token
/// iceServers as the fallback. Never hardcodes a secret.
Future<Map<String, dynamic>?> fetchEphemeralTurnIceServer({
  String? bearerToken,
}) async {
  if (kTurnCredentialUrl.isEmpty) return null;
  try {
    final res = await http.get(
      Uri.parse(kTurnCredentialUrl),
      headers: {
        if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
      },
    ).timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final username = j['username'];
    final credential = j['credential'];
    if (username is! String || credential is! String) return null;
    final urls = (j['urls'] is List)
        ? (j['urls'] as List).whereType<String>().toList()
        : const <String>[];
    return {
      'urls': urls.isNotEmpty ? urls : ['turn:turn.interactpak.com:3478'],
      'username': username,
      'credential': credential,
    };
  } catch (_) {
    return null;
  }
}

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
    String? roomId,
    String mode = 'video',
  }) async {
    final h = await _headers();
    // The backend requires ONE anchor of threadId/animalId/contractId/roomId/
    // eventId. An ad-hoc "New meeting" (from the Calls tab) has no thread, so
    // we generate a room code and send it as `roomId` — that satisfies the
    // validator AND doubles as the shareable join code others enter. Without
    // this the token mint 400s ("one of … required") and the room never
    // connects, leaving mic/camera/controls dead on a black screen (fixed
    // 2026-07-21).
    final anchorRoomId =
        threadId == null ? (roomId ?? generateRoomCode()) : null;
    final payload = <String, dynamic>{
      if (threadId != null) 'threadId': threadId,
      // Ad-hoc meeting → `talkRoom` (any signed-in user may host/join; the
      // code is the authorization). NOT `roomId`, which is the admin-only
      // free-form escape hatch and 403s for normal users (fixed 2026-07-21).
      if (anchorRoomId != null) 'talkRoom': anchorRoomId,
      'mode': mode,
    };
    // Preferred endpoint (after backend extension)
    var res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/rooms'),
      headers: h,
      body: jsonEncode(payload),
    );
    // Phase 1 fallback — the existing meetings/token endpoint with the same
    // anchor payload.
    if (res.statusCode == 404) {
      res = await http.post(
        Uri.parse('$_kBase/api/v1/meetings/token'),
        headers: h,
        body: jsonEncode(payload),
      );
    }
    if (res.statusCode >= 400) {
      throw Exception('createRoom failed: ${res.statusCode} ${res.body}');
    }
    return TalkRoomToken.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// 6-char human-shareable room code — uppercase A–Z + 2–9, minus visually
  /// confusable glyphs (I, L, O, 0, 1). Matches the server's own code shape so
  /// join-by-code round-trips cleanly.
  static String generateRoomCode() {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(6, (_) => chars[r.nextInt(chars.length)]).join();
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
      // Fallback — mint a token for the ad-hoc Talk room keyed by this code.
      // `talkRoom` lets any signed-in user join (the code is the auth); the
      // old `{general:true}` payload was rejected by the validator.
      res = await http.post(
        Uri.parse('$_kBase/api/v1/meetings/token'),
        headers: h,
        body: jsonEncode({'talkRoom': code}),
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

  /// Presence heartbeat — POST /api/v1/talk/presence/beat (TalkPresence).
  /// Fire-and-forget: network blips are swallowed so the UI never stalls.
  Future<void> heartbeat() async {
    try {
      final h = await _headers();
      await http
          .post(Uri.parse('$_kBase/api/v1/talk/presence/beat'), headers: h)
          .timeout(const Duration(seconds: 5));
    } catch (_) {/* presence is best-effort */}
  }

  /// Presence for peer keys (phone / uuid / externalUserId).
  /// Degrades to {} on any error — never throws.
  Future<Map<String, bool>> presence(List<String> keys) async {
    if (keys.isEmpty) return const {};
    try {
      final h = await _headers();
      final q = Uri.encodeQueryComponent(keys.join(','));
      final res = await http
          .get(Uri.parse('$_kBase/api/v1/talk/presence?keys=$q'), headers: h)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return const {};
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] ?? body;
      final out = <String, bool>{};
      if (data is Map) {
        data.forEach((k, v) {
          if (v is bool) {
            out[k.toString()] = v;
          } else if (v is Map && v['online'] is bool) {
            out[k.toString()] = v['online'] as bool;
          }
        });
      }
      return out;
    } catch (_) {
      return const {};
    }
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
