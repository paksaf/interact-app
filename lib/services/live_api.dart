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
import 'api_base.dart';

String get _kBase => ApiBase.current;
const _kTimeout = Duration(seconds: 20);

/// Roles an attendee can request. Host is implied by [LiveApi.token]'s
/// `asHost` flag and is never passed as a role.
enum LiveRole { speaker, listener, moderator, pttTalker }

extension LiveRoleWire on LiveRole {
  String get wire => switch (this) {
        LiveRole.speaker => 'speaker',
        LiveRole.listener => 'listener',
        LiveRole.moderator => 'moderator',
        LiveRole.pttTalker => 'ptt-talker',
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
    this.voiceFirst = true,
    this.holdToSpeak = false,
    this.callLogId,
  });

  final String token;
  final String url; // wss://livekit.interactpak.com
  final String role; // host | moderator | speaker | listener | ptt-talker
  final bool isHost;
  final String roomCode;
  final String? roomId;
  final DateTime? expiresAt;

  /// When true (default), publish mic only on join — camera stays off until
  /// the user enables it. Bandwidth-friendly for Pakistan / voice townhalls.
  final bool voiceFirst;

  /// Walkie / PTT mode: start with mic off; UI hold-to-speak enables mic.
  final bool holdToSpeak;

  /// From /talk/live/token — POST /meetings/log on leave.
  final String? callLogId;

  /// Whether this participant is allowed to publish (camera/mic). Listeners
  /// are subscribe-only; the server's grant enforces it, but we also use
  /// this to skip the publish calls client-side.
  bool get canPublish => role != 'listener';

  LiveJoin copyWith({bool? voiceFirst, bool? holdToSpeak}) => LiveJoin(
        token: token,
        url: url,
        role: role,
        isHost: isHost,
        roomCode: roomCode,
        roomId: roomId,
        expiresAt: expiresAt,
        voiceFirst: voiceFirst ?? this.voiceFirst,
        holdToSpeak: holdToSpeak ?? this.holdToSpeak,
        callLogId: callLogId,
      );

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
        // Default voice-first; callers may override via copyWith.
        voiceFirst: (d['voiceFirst'] as bool?) ?? true,
        holdToSpeak: (d['holdToSpeak'] as bool?) ?? false,
        callLogId: d['callLogId'] as String?,
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

  /// Probe caption-agent via QS proxy. Returns configured=true when Deepgram +
  /// LiveKit keys are present on the agent.
  ///
  /// When the health route is missing on an older QS deploy (404), we return
  /// [unknown: true] so the UI can still attempt [toggleCaptions] — POST is
  /// the source of truth and will surface admin/agent errors.
  Future<({bool agentOk, bool configured, bool unknown})> captionsHealth()
      async {
    try {
      final res = await http
          .get(
            Uri.parse('$_kBase/api/v1/talk/live/captions/health'),
            headers: await _headers(),
          )
          .timeout(_kTimeout);
      if (res.statusCode == 404) {
        return (agentOk: false, configured: false, unknown: true);
      }
      if (res.statusCode >= 400) {
        return (agentOk: false, configured: false, unknown: false);
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] as Map<String, dynamic>?) ?? body;
      return (
        agentOk: data['agentOk'] == true,
        configured: data['configured'] == true,
        unknown: false,
      );
    } catch (_) {
      // Network blip — allow toggle attempt; POST will fail clearly.
      return (agentOk: false, configured: false, unknown: true);
    }
  }

  /// Toggle live in-call captions for [room] (LiveKit room name). The backend
  /// proxies to the caption-agent. Throws [LiveApiException] with a clear
  /// operator hint when the agent/keys are down.
  ///
  /// [language]: Deepgram code — `en` | `ar` | `ur` | `tr` | `ru` | `es` | `multi`.
  Future<bool> toggleCaptions(
    String room,
    bool on, {
    String language = 'multi',
  }) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_kBase/api/v1/talk/live/captions'),
            headers: await _headers(),
            body: jsonEncode({
              'room': room,
              'action': on ? 'start' : 'stop',
              if (on) 'language': language,
            }),
          )
          .timeout(_kTimeout);
      if (res.statusCode >= 200 && res.statusCode < 300) return true;
      final hint = switch (res.statusCode) {
        403 => 'Captions: admin only — ask an INTERACT admin to enable.',
        502 || 503 => 'Caption agent / Deepgram keys required (ops).',
        _ => 'Captions unavailable (${res.statusCode}).',
      };
      throw LiveApiException(hint);
    } on LiveApiException {
      rethrow;
    } catch (e) {
      throw LiveApiException('Captions unavailable — check caption-agent.');
    }
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
