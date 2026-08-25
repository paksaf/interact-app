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
import 'package:crypto/crypto.dart';
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

/// CRM name-resolve (Phase 3) hashing scheme versions. The server accepts BOTH
/// (dual-algo) so older build ≤6040 clients keep working; this client now sends
/// v2 (HMAC) by default. Must stay byte-identical to the server's
/// `CRM_RESOLVE_ALGO` / `CRM_RESOLVE_ALGO_V2` in qurbanisahulat
/// src/lib/crm-shared.ts.
///
///   v1 = sha256(pepper + e164)                         (legacy, still accepted)
///   v2 = HMAC-SHA256(key=pepper, msg=e164)             (preferred, default)
///
/// Both digests are lowercase hex, matching Node's `.digest("hex")`.
const kCrmResolveAlgoV1 = 'sha256-e164-pepper-v1';
const kCrmResolveAlgoV2 = 'hmac-sha256-pepper-v1';

/// Algo this client hashes + sends. Default v2 (HMAC).
const kCrmResolveAlgo = kCrmResolveAlgoV2;

/// Shared pepper for the CRM name-resolve hashing scheme. Provisioned via
/// `--dart-define=CRM_RESOLVE_PEPPER=<value>` and MUST equal the server's
/// `CRM_RESOLVE_PEPPER` env var. Default EMPTY = feature OFF (resolveCrmNames
/// short-circuits to an empty map), so behaviour is unchanged until the
/// operator provisions the pepper. It is NOT a strong secret — it only obscures
/// numbers in transit; the real protection is JWT + server rate limit +
/// names-only responses.
const _kCrmResolvePepper =
    String.fromEnvironment('CRM_RESOLVE_PEPPER', defaultValue: '');

/// Normalize a raw phone string into E.164, mirroring the server's
/// `normalizePkPhone` (qurbanisahulat src/lib/phone-normalize.ts) EXACTLY — the
/// two must agree or the sha256(pepper + e164) hashes won't line up. Returns
/// null for inputs that don't match a known pattern.
///
/// Accepted (all → +923xxxxxxxxx):
///   03001234567 · 3001234567 · 923001234567 · +923001234567 · +92-300-1234567
/// Plus generic +CCxxx… pass-through for non-PK numbers (8–15 digits).
String? normalizePkPhoneClient(String raw) {
  if (raw.isEmpty) return null;
  final trimmed = raw.trim();
  final hasPlus = trimmed.startsWith('+');
  final digits = trimmed.replaceAll(RegExp(r'[^\d]'), '');

  // Already E.164 PK: +923xxxxxxxxx
  if (hasPlus && digits.startsWith('92') && digits.length == 12) {
    return '+$digits';
  }
  // 03xxxxxxxxx (PK domestic) → +92 3xxxxxxxxx
  if (!hasPlus && digits.startsWith('03') && digits.length == 11) {
    return '+92${digits.substring(1)}';
  }
  // 923xxxxxxxxx (PK without +) → +923xxxxxxxxx
  if (!hasPlus && digits.startsWith('92') && digits.length == 12) {
    return '+$digits';
  }
  // 3xxxxxxxxx (10 digits, missing the leading 0)
  if (!hasPlus && digits.startsWith('3') && digits.length == 10) {
    return '+92$digits';
  }
  // Generic +CCxxx… pass-through for non-PK numbers (length 8-15)
  if (hasPlus && digits.length >= 8 && digits.length <= 15) {
    return '+$digits';
  }
  return null;
}

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

/// Unwrap `{ ok, data: {…} }` from Sahulat `ok()` helpers. Falls back to the
/// body itself when the payload is already flat (older clients / proxies).
Map<String, dynamic> _extractMap(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is Map) return Map<String, dynamic>.from(data);
  return body;
}

final talkApiProvider = Provider<TalkApi>((ref) {
  return TalkApi(ref.read(authServiceProvider));
});

/// Thrown by [TalkApi.transcribeVoiceNote] on a non-2xx from the backend.
/// Carries the server `error.code` (NO_AUDIO | NOT_CONFIGURED | RATE_LIMITED |
/// TRANSCRIBE_FAILED) so the caller (TranscriptionService / UI) can show a
/// precise, fail-soft message. Kept here (low-level) so talk_api.dart has no
/// upward import of transcription_service.dart.
class TalkTranscribeError implements Exception {
  TalkTranscribeError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'TalkTranscribeError($code): $message';
}

class TalkRoomToken {
  TalkRoomToken({
    required this.token,
    required this.wsUrl,
    required this.roomId,
    required this.iceServers,
    required this.expiresAt,
    this.callLogId,
  });
  final String token;
  final String wsUrl;
  final String roomId;
  final List<Map<String, dynamic>> iceServers;
  final DateTime expiresAt;
  /// From /meetings/token — POST /meetings/log on hangup so endedAt is written.
  final String? callLogId;

  factory TalkRoomToken.fromJson(Map<String, dynamic> j) {
    final m = _extractMap(j);
    final token = m['token'] as String?;
    final wsUrl = (m['wsUrl'] ?? m['url']) as String?;
    final roomId = m['roomId'] as String?;
    final expiresRaw = m['expiresAt'];
    if (token == null || wsUrl == null || roomId == null) {
      throw FormatException(
        'TalkRoomToken missing fields: token/wsUrl/roomId '
        '(keys=${m.keys.toList()})',
      );
    }
    return TalkRoomToken(
      token: token,
      wsUrl: wsUrl,
      roomId: roomId,
      iceServers: ((m['iceServers'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      expiresAt: expiresRaw is String
          ? DateTime.parse(expiresRaw)
          : DateTime.now().add(const Duration(hours: 1)),
      callLogId: m['callLogId'] as String?,
    );
  }
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
    return TalkRoomToken.fromJson(
      jsonDecode(res.body) as Map<String, dynamic>,
    );
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

  /// Resolve display names for [numbers] from the INTERACT CRM (Phase 3),
  /// WITHOUT the CRM ever reaching the device. We normalize each number to
  /// E.164, hash it under the v2 scheme `HMAC-SHA256(key=pepper, msg=e164)`
  /// (byte-identical to the server's `hmac-sha256-pepper-v1`), and POST only
  /// the hashes to /api/v1/talk/contacts/resolve. The server returns matched
  /// names keyed by hash; we map them back to the E.164 number.
  ///
  /// Returns an `e164 → name` map. Fail-soft: returns `{}` on any error, 404,
  /// non-200, or when the pepper isn't provisioned (feature off) — the caller
  /// simply keeps whatever name it already had (device/backend/phone).
  Future<Map<String, String>> resolveCrmNames(List<String> numbers) async {
    if (_kCrmResolvePepper.isEmpty || numbers.isEmpty) return const {};
    // HMAC key = pepper bytes; digest = lowercase hex, matching Node's
    // crypto.createHmac('sha256', pepper).update(e164).digest('hex').
    final hmac = Hmac(sha256, utf8.encode(_kCrmResolvePepper));
    // Build hash → e164 so we can map the server's hash-keyed matches back.
    final hashToE164 = <String, String>{};
    for (final n in numbers) {
      final e164 = normalizePkPhoneClient(n);
      if (e164 == null) continue;
      final hash = hmac.convert(utf8.encode(e164)).toString();
      hashToE164[hash] = e164; // lowercase hex, matches Node digest("hex")
    }
    if (hashToE164.isEmpty) return const {};

    // Server caps at 50 hashes/request — chunk to stay within it.
    const chunkSize = 50;
    final out = <String, String>{};
    final allHashes = hashToE164.keys.toList();
    try {
      final h = await _headers();
      for (var i = 0; i < allHashes.length; i += chunkSize) {
        final chunk = allHashes.sublist(i,
            i + chunkSize > allHashes.length ? allHashes.length : i + chunkSize);
        final res = await http
            .post(
              Uri.parse('$_kBase/api/v1/talk/contacts/resolve'),
              headers: h,
              body: jsonEncode({'hashes': chunk, 'algo': kCrmResolveAlgo}),
            )
            .timeout(const Duration(seconds: 8));
        if (res.statusCode != 200) continue; // 404/429/4xx → skip, fail-soft
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final data = _extractMap(body);
        final matches = data['matches'];
        if (matches is! List) continue;
        for (final m in matches) {
          if (m is! Map) continue;
          final hash = m['hash'] as String?;
          final name = m['name'] as String?;
          final e164 = hash == null ? null : hashToE164[hash];
          if (e164 != null && name != null && name.trim().isNotEmpty) {
            out[e164] = name.trim();
          }
        }
      }
    } catch (_) {
      // Fail-soft — whatever we resolved before the error is still returned.
    }
    return out;
  }

  /// Suggest linking a contact / call summary to the INTERACT CRM (admin-
  /// reviewed). Stores a `TalkCrmSuggestion` server-side and emails admins via
  /// the Comms Hub. The CRM is READ-ONLY — this never writes it; an admin later
  /// approves/rejects. Fail-soft: returns false on any error / non-2xx so the
  /// caller can show a gentle "couldn't submit" message without throwing.
  ///
  /// POST /api/v1/talk/crm/suggest
  ///   { contactName, contactOrg?, note?, summaryText, callId?, summaryId? }
  ///   → ok({ suggestionId, status:"pending" })
  Future<bool> suggestToCrm({
    required String contactName,
    required String summaryText,
    String? contactOrg,
    String? note,
    String? callId,
    String? summaryId,
  }) async {
    if (contactName.trim().isEmpty || summaryText.trim().isEmpty) return false;
    try {
      final h = await _headers();
      final res = await http
          .post(
            Uri.parse('$_kBase/api/v1/talk/crm/suggest'),
            headers: h,
            body: jsonEncode({
              'contactName': contactName.trim(),
              'summaryText': summaryText.trim(),
              if (contactOrg != null && contactOrg.trim().isNotEmpty)
                'contactOrg': contactOrg.trim(),
              if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
              if (callId != null && callId.isNotEmpty) 'callId': callId,
              if (summaryId != null && summaryId.isNotEmpty)
                'summaryId': summaryId,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false; // fail-soft — never surface a network error as a throw
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

  /// Close the CallLog row minted with the room token. Hangup must POST this
  /// or `ended_at` stays NULL (PLAN §7.8). Fail-soft — never throw.
  Future<void> closeCallLog(
    String id, {
    String reason = 'hangup',
    int? durationSecs,
  }) async {
    try {
      final h = await _headers();
      await http
          .post(
            Uri.parse('$_kBase/api/v1/meetings/log'),
            headers: h,
            body: jsonEncode({
              'id': id,
              'endedReason': reason,
              if (durationSecs != null) 'durationSecs': durationSecs,
            }),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {/* audit only */}
  }

  /// CLOUD transcription of a voice note at [audioUrl] (the absolute /uploads/…
  /// URL from ChatApi.uploadMedia). Deepgram runs server-side; this is the
  /// cloud half of the hybrid fork in [TranscriptionService] (on-device
  /// whisper.cpp is client-side, later). [language] is a BCP-47 hint (omit to
  /// auto-detect). [preferOnDevice] is forwarded for a stable contract but the
  /// server always uses cloud.
  ///
  /// POST /api/v1/talk/transcribe { audioUrl, language?, preferOnDevice? }
  ///   → ok({ text, language, confidence, source:"cloud", durationMs })
  /// Throws [TalkTranscribeError] on any non-2xx (carrying the server error
  /// code) so the caller can surface a precise fail-soft message.
  Future<({
    String text,
    String? language,
    double? confidence,
    String source,
    int? durationMs,
  })> transcribeVoiceNote(
    String audioUrl, {
    String? language,
    bool preferOnDevice = false,
  }) async {
    final h = await _headers();
    final res = await http
        .post(
          Uri.parse('$_kBase/api/v1/talk/transcribe'),
          headers: h,
          body: jsonEncode({
            'audioUrl': audioUrl,
            if (language != null && language.isNotEmpty) 'language': language,
            'preferOnDevice': preferOnDevice,
          }),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      var code = 'TRANSCRIBE_FAILED';
      var msg = 'Transcription failed (${res.statusCode})';
      try {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        final e = body['error'];
        if (e is Map) {
          if (e['code'] is String) code = e['code'] as String;
          if (e['message'] is String) msg = e['message'] as String;
        }
      } catch (_) {/* keep defaults */}
      throw TalkTranscribeError(code, msg);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = _extractMap(body);
    return (
      text: ((data['text'] as String?) ?? '').trim(),
      language: data['language'] as String?,
      confidence: (data['confidence'] as num?)?.toDouble(),
      source: (data['source'] as String?) ?? 'cloud',
      durationMs: (data['durationMs'] as num?)?.toInt(),
    );
  }

  /// Record 👍/👎 [rating] ("up"|"down") on an AI [feature]
  /// ("transcription"|"summary") for [itemId]. Fail-soft: returns true on
  /// success, false on any error — feedback must never disrupt the UI.
  ///
  /// POST /api/v1/talk/feedback { feature, itemId, rating, comment?, language? }
  Future<bool> submitFeedback({
    required String feature,
    required String itemId,
    required String rating,
    String? comment,
    String? language,
  }) async {
    try {
      final h = await _headers();
      final res = await http
          .post(
            Uri.parse('$_kBase/api/v1/talk/feedback'),
            headers: h,
            body: jsonEncode({
              'feature': feature,
              'itemId': itemId,
              'rating': rating,
              if (comment != null && comment.trim().isNotEmpty)
                'comment': comment.trim(),
              if (language != null && language.isNotEmpty) 'language': language,
            }),
          )
          .timeout(const Duration(seconds: 8));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false; // fail-soft — never surface as a throw
    }
  }
}
