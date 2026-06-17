// SPDX-License-Identifier: AGPL-3.0
//
// Live API — multi-party conference / townhall tokens (LiveKit SFU).
//
// This is the SCALABLE path, distinct from talk_api.dart's 1:1 mesh
// (/api/v1/meetings/token). It calls qurbanisahulat's
// /api/v1/talk/live/token, which authenticates the user's INTERACT JWT
// and then mints a LiveKit join token via the Comms Hub (interact-connect
// /api/rooms/*). The device never sees a LiveKit secret.
//
// Host: qurbanisahulat.com (same as talk_api/chat_api — corp site has no
// /api/v1/* routes; the interactpak JWT verifies here via shared
// INTERACT_AUTH_SECRET).
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

const _kBase = 'https://qurbanisahulat.com';
const _kTimeout = Duration(seconds: 20);

/// Roles an attendee can request. Host is implied by [LiveApi.token]'s
/// `asHost` flag and is never passed as a role.
enum LiveRole { speaker, listener, moderator }

extension LiveRoleWire on LiveRole {
  String get wire => switch (this) {
        LiveRole.speaker => 'speaker',
        LiveRole.listener => 'listener',
        LiveRole.moderator => 'moderator',
      };
}

/// Result of a token mint — everything the client needs to connect to the
/// LiveKit room. The LiveKit room name itself is embedded in the JWT grant,
/// so [url] + [token] are sufficient for `Room.connect`.
class LiveJoin {
  LiveJoin({
    required this.token,
    required this.url,
    required this.role,
    required this.isHost,
    required this.roomCode,
    this.roomId,
    this.expiresAt,
  });

  final String token;
  final String url; // wss://livekit.interactpak.com
  final String role; // host | moderator | speaker | listener
  final bool isHost;
  final String roomCode;
  final String? roomId;
  final DateTime? expiresAt;

  /// Whether this participant is allowed to publish (camera/mic). Listeners
  /// are subscribe-only; the server's grant enforces it, but we also use
  /// this to skip the publish calls client-side.
  bool get canPublish => role != 'listener';

  factory LiveJoin.fromData(Map<String, dynamic> d) => LiveJoin(
        token: d['token'] as String,
        url: d['url'] as String,
        role: (d['role'] as String?) ?? 'speaker',
        isHost: (d['isHost'] as bool?) ?? false,
        roomCode: (d['roomCode'] as String?) ?? '',
        roomId: d['roomId'] as String?,
        expiresAt: d['expiresAt'] != null
            ? DateTime.tryParse(d['expiresAt'] as String)
            : null,
      );
}

final liveApiProvider = Provider<LiveApi>((ref) {
  return LiveApi(ref.read(authServiceProvider));
});

class LiveApi {
  LiveApi(this._auth);
  final AuthService _auth;

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  /// Mint a LiveKit join token.
  ///
  /// [asHost] true creates (or revives) the room; the caller becomes host.
  /// Otherwise the caller joins as [role] (default speaker → full two-way).
  /// [mode] maps to the hub room mode: meeting | ptt | 1:1.
  Future<LiveJoin> token({
    required String code,
    bool asHost = false,
    LiveRole role = LiveRole.speaker,
    String mode = 'meeting',
  }) async {
    final res = await http
        .post(
          Uri.parse('$_kBase/api/v1/talk/live/token'),
          headers: await _headers(),
          body: jsonEncode({
            'code': code,
            'asHost': asHost,
            if (!asHost) 'role': role.wire,
            'mode': mode,
          }),
        )
        .timeout(_kTimeout);

    final body = _decode(res.body);
    if (res.statusCode >= 400) {
      // Surface the server's friendly message when present.
      final msg = (body?['error'] is Map)
          ? (body!['error']['message'] as String?)
          : null;
      throw LiveApiException(
        msg ?? 'Could not join the room (${res.statusCode}).',
        statusCode: res.statusCode,
      );
    }
    final data = body?['data'];
    if (data is! Map) {
      throw LiveApiException('Unexpected server response.');
    }
    return LiveJoin.fromData(Map<String, dynamic>.from(data));
  }

  /// Host/moderator action on another participant (real server-side mute /
  /// remove at the SFU). [targetIdentity] is the participant's LiveKit
  /// identity. [action] is 'mute' | 'unmute' | 'remove'.
  Future<void> moderate({
    required String code,
    required String targetIdentity,
    required String action,
    String? scope,
  }) async {
    final res = await http
        .post(
          Uri.parse('$_kBase/api/v1/talk/live/moderate'),
          headers: await _headers(),
          body: jsonEncode({
            'code': code,
            'targetIdentity': targetIdentity,
            'action': action,
            if (scope != null) 'scope': scope,
          }),
        )
        .timeout(_kTimeout);
    if (res.statusCode >= 400) {
      final body = _decode(res.body);
      final msg = (body?['error'] is Map)
          ? (body!['error']['message'] as String?)
          : null;
      throw LiveApiException(
        msg ?? 'Moderation failed (${res.statusCode}).',
        statusCode: res.statusCode,
      );
    }
  }

  Map<String, dynamic>? _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }
}

class LiveApiException implements Exception {
  LiveApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
