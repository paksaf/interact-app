// SPDX-License-Identifier: AGPL-3.0
//
// ChatApi — thin wrapper over /api/v1/chat/threads* on
// qurbanisahulat (shipped in #171 + #173). INTERACT consumes the
// SAME polymorphic ChatThread backend the Sahulat sub-apps use,
// filtered to subjectType='general' (1:1 personal threads) and
// 'group' (multi-participant rooms).
//
// Listing is GET /api/v1/chat/threads?subjectType=general
// Messages are GET /api/v1/chat/threads/[threadId]/messages
// Sending is  POST /api/v1/chat/threads/[threadId]/messages
//
// Host: qurbanisahulat.com (NOT interactpak.com — corp site has no
// /api/v1/* routes). JWT issued by interactpak.com/api/auth/phone-login
// verifies on qurbanisahulat via shared INTERACT_AUTH_SECRET (see
// [[sahulat_api_host]] memory).

import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat.dart';
import 'auth_service.dart';

const _kBase = 'https://qurbanisahulat.com';

// ─── envelope helpers ────────────────────────────────────────────────
// qurbanisahulat wraps responses with `ok(payload)` from src/lib/api-response.ts:
//   { success: true, data: <payload>, meta: {}, error: null }
// where `payload` is route-specific. Most list routes nest the list:
//   ok({ threads: [...] })    →   data.threads
//   ok({ messages: [...] })   →   data.messages
//   ok({ thread: {...} })     →   data.thread
// Older / unwrapped routes return `data` directly as a list or object.
// These helpers handle BOTH shapes so the parser doesn't break the next
// time the server changes its envelope. Burned 2026-05-22.

List<dynamic> _extractList(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is List) return data;
  if (data is Map) {
    // First List-valued field wins. Each list route has exactly one
    // collection key (threads / messages / contacts / items / etc.).
    for (final v in data.values) {
      if (v is List) return v;
    }
  }
  return const <dynamic>[];
}

Map<String, dynamic> _extractObject(Map<String, dynamic> body) {
  final data = body['data'];
  if (data is Map<String, dynamic>) {
    // If the Map has exactly one Map-valued field, peel it (e.g.
    // {thread: {...}} → {...}). Otherwise the data itself is the object.
    final entries = data.entries.toList();
    if (entries.length == 1 && entries.first.value is Map) {
      return Map<String, dynamic>.from(entries.first.value as Map);
    }
    return data;
  }
  return <String, dynamic>{};
}

final chatApiProvider = Provider<ChatApi>((ref) {
  return ChatApi(ref.read(authServiceProvider));
});

/// Discriminated result of `createDirectThread`. The server has two
/// success modes (peer registered → thread opened; peer unregistered →
/// invite UX), and the client needs to branch on which one came back
/// before navigating or showing the invite sheet.
sealed class DirectThreadResult {
  const DirectThreadResult();
}

class DirectThreadFound extends DirectThreadResult {
  const DirectThreadFound(this.thread, {this.peerUserId, this.peerHasInteractInstalled});
  final ChatThread thread;
  /// Peer's local Sahulat uuid (from the server-side phone lookup).
  /// Null when no peer was resolved (e.g. caller-only thread).
  final String? peerUserId;
  /// Whether the peer has actually opened INTERACT. False for Sahulat-
  /// only marketplace users — drives the "Not on INTERACT yet" warning
  /// chip and the call-button precheck.
  final bool? peerHasInteractInstalled;
}

class DirectThreadUnregistered extends DirectThreadResult {
  const DirectThreadUnregistered({
    required this.rawPhone,
    required this.normalizedPhone,
  });
  final String rawPhone;          // what the user typed
  final String normalizedPhone;   // E.164 the server resolved to (or rawPhone if unparseable)
}

/// Invite quota snapshot. `total` is the lifetime cap (5 free Hub
/// invites). After that the client falls back to the OS SMS composer
/// which doesn't decrement.
class InviteQuota {
  const InviteQuota({required this.used, required this.total, required this.remaining});
  final int used;
  final int total;
  final int remaining;
  bool get isExhausted => remaining <= 0;

  factory InviteQuota.fromJson(Map<String, dynamic> j) => InviteQuota(
        used: (j['used'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 5,
        remaining: (j['remaining'] as num?)?.toInt() ?? 0,
      );
}

/// Result of POST /api/v1/chat/invites — actual channel used by the
/// Comms Hub fallback chain plus the refreshed quota snapshot.
class InviteSendResult {
  const InviteSendResult({required this.channel, required this.quota});
  final String channel; // 'whatsapp' | 'sms'
  final InviteQuota quota;
}

/// Thrown by `sendInvite` when the server returns 429 (lifetime quota
/// hit). UI should pivot to the OS SMS composer instead of showing the
/// error verbatim.
class InviteQuotaExhausted implements Exception {
  const InviteQuotaExhausted();
  @override
  String toString() => 'Invite quota exhausted';
}

class ChatApi {
  ChatApi(this._auth);
  final AuthService _auth;

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  /// Capture-and-stash the caller's local Sahulat uuid from any
  /// response envelope that carries `me: { id }` (#147). The threads
  /// POST and messages GET routes both include it. Idempotent — safe
  /// to call on every response without checking. Best-effort; failures
  /// are swallowed since the uuid is a nice-to-have for isMine.
  Future<void> _captureMeFromBody(Map<String, dynamic> body) async {
    try {
      final data = body['data'];
      if (data is! Map<String, dynamic>) return;
      final me = data['me'];
      if (me is! Map<String, dynamic>) return;
      final id = me['id'];
      if (id is String && id.isNotEmpty) {
        await _auth.setLocalUserId(id);
      }
    } catch (_) {}
  }

  /// List threads — INTERACT default filter is 'general' (1:1 personal).
  /// Pass `subjectType: 'group'` to fetch group rooms instead.
  Future<List<ChatThread>> listThreads({String subjectType = 'general'}) async {
    final h = await _headers();
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/chat/threads?subjectType=$subjectType'),
      headers: h,
    );
    if (res.statusCode >= 400) {
      throw Exception('listThreads failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _extractList(body)
        .whereType<Map<String, dynamic>>()
        .map(ChatThread.fromJson)
        .toList();
  }

  /// Create a new direct thread with the given peer phone (E.164 or
  /// PK-domestic 03XX form). Server resolves to user-id and dedups so
  /// repeated calls return the same thread row.
  ///
  /// Returns one of:
  ///   - [DirectThreadFound]      → registered peer; thread is open, navigate.
  ///   - [DirectThreadUnregistered] → not in our user table; show invite sheet.
  ///
  /// Throws only on transport / server errors, NOT on the unregistered
  /// case (that's a normal success path now).
  Future<DirectThreadResult> createDirectThread({required String peerPhone}) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/chat/threads'),
      headers: await _headers(),
      body: jsonEncode({
        'subjectType': 'general',
        'peerPhone': peerPhone,
      }),
    );
    if (res.statusCode >= 400) {
      throw Exception('createDirectThread failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    // Stash caller's local uuid for isMine (#147).
    await _captureMeFromBody(body);
    final data = body['data'];
    if (data is Map<String, dynamic>) {
      // Server contract (#140): `data.found` discriminates the two cases.
      // Backward-compat: when `found` is missing, treat as the legacy
      // "thread top-level" shape and assume found=true.
      final found = data['found'];
      if (found == false) {
        return DirectThreadUnregistered(
          rawPhone: peerPhone,
          normalizedPhone: (data['normalized'] as String?) ?? peerPhone,
        );
      }
      // Either {found: true, thread, peer?} or legacy {thread} — peel & build.
      final threadJson = data['thread'] is Map<String, dynamic>
          ? data['thread'] as Map<String, dynamic>
          : data;
      final peerJson = data['peer'] is Map<String, dynamic>
          ? data['peer'] as Map<String, dynamic>
          : null;
      // Stamp the peer summary onto the ChatThread so downstream UI
      // (warning chip + call precheck) doesn't need to re-query.
      final baseThread = ChatThread.fromJson(threadJson);
      final thread = baseThread.copyWith(
        peerUserId: peerJson?['id'] as String?,
        peerHasInteractInstalled:
            peerJson?['hasInteractInstalled'] as bool?,
      );
      return DirectThreadFound(
        thread,
        peerUserId: peerJson?['id'] as String?,
        peerHasInteractInstalled:
            peerJson?['hasInteractInstalled'] as bool?,
      );
    }
    throw Exception('createDirectThread: unexpected response shape');
  }

  /// Heartbeat the caller's typing cursor for the given thread (#146).
  /// Client posts this debounced (every ~3s while the composer's
  /// onChanged is firing). Server-side it's a single UPDATE on
  /// chat_thread_participants.typing_at. Best-effort — failures are
  /// swallowed so a momentary network blip doesn't surface to the UI.
  Future<void> sendTyping(String threadId) async {
    try {
      await http.post(
        Uri.parse('$_kBase/api/v1/chat/threads/$threadId/typing'),
        headers: await _headers(),
      );
    } catch (_) {
      // Silent — typing is a nice-to-have, not load-bearing.
    }
  }

  /// Fetch the caller's lifetime invite quota (5 free Hub-paid invites).
  Future<InviteQuota> inviteQuota() async {
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/chat/invites/quota'),
      headers: await _headers(),
    );
    if (res.statusCode >= 400) {
      throw Exception('inviteQuota failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return InviteQuota.fromJson(_extractObject(body));
  }

  /// Send an INTERACT install invite via Comms Hub (WhatsApp → SMS
  /// fallback). Decrements quota by 1 on successful Hub delivery.
  /// Throws if quota is exhausted (429 → client should pivot to OS SMS).
  Future<InviteSendResult> sendInvite(String peerPhone, {String? message}) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/chat/invites'),
      headers: await _headers(),
      body: jsonEncode({
        'peerPhone': peerPhone,
        if (message != null) 'message': message,
      }),
    );
    if (res.statusCode == 429) {
      // Quota exhausted — surface as a typed exception so the UI can
      // fall through to the OS SMS composer instead of treating this
      // like a transport failure.
      throw InviteQuotaExhausted();
    }
    if (res.statusCode >= 400) {
      throw Exception('sendInvite failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = _extractObject(body);
    return InviteSendResult(
      channel: (data['channel'] as String?) ?? 'sms',
      quota: InviteQuota.fromJson(
        (data['quota'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
      ),
    );
  }

  /// Message list — newest LAST (chronological). limit defaults to 50.
  Future<List<Message>> messages(String threadId, {int limit = 50}) async {
    final view = await loadThreadAndMessages(threadId, limit: limit);
    return view.messages;
  }

  /// Combined loader — returns the latest thread metadata (including
  /// participants' typing/read cursors) AND the message list in one
  /// round-trip. Polling uses this so the typing bubble + receipt ticks
  /// stay in sync with each refresh tick (#144 + #146).
  Future<({ChatThread thread, List<Message> messages})> loadThreadAndMessages(
    String threadId, {
    int limit = 50,
  }) async {
    final res = await http.get(
      Uri.parse(
        '$_kBase/api/v1/chat/threads/$threadId/messages?limit=$limit',
      ),
      headers: await _headers(),
    );
    if (res.statusCode >= 400) {
      throw Exception('messages failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    // Stash caller's local uuid for isMine (#147), then use it.
    await _captureMeFromBody(body);
    final myUserId = await _auth.localUserId() ?? await _auth.phone();
    final data = body['data'];
    final ChatThread thread;
    final List<dynamic> messagesRaw;
    if (data is Map<String, dynamic>) {
      thread = data['thread'] is Map<String, dynamic>
          ? ChatThread.fromJson(data['thread'] as Map<String, dynamic>)
          : ChatThread.fromJson(<String, dynamic>{'id': threadId});
      messagesRaw = (data['messages'] as List?) ?? const [];
    } else {
      thread = ChatThread.fromJson(<String, dynamic>{'id': threadId});
      messagesRaw = (data is List) ? data : const [];
    }
    final messages = messagesRaw
        .whereType<Map<String, dynamic>>()
        .map((j) => Message.fromJson(j, myId: myUserId))
        .toList();
    return (thread: thread, messages: messages);
  }

  /// Send a text message.
  Future<Message> sendText(String threadId, String text) async {
    return _send(threadId, body: {'kind': 'text', 'body': text});
  }

  /// Send a voice message. [mediaUrl] is the URL returned by the
  /// upload endpoint; [durationSec] feeds the waveform UI. If a
  /// [transcript] is provided (from on-device Whisper), it's attached
  /// for accessibility + search.
  Future<Message> sendVoice(
    String threadId, {
    required String mediaUrl,
    required int durationSec,
    String? transcript,
  }) async {
    return _send(threadId, body: {
      'kind': 'voice',
      'mediaUrl': mediaUrl,
      'mediaDurationSec': durationSec,
      if (transcript != null) 'transcript': transcript,
    });
  }

  /// Mark a thread read up to a given message.
  Future<void> markRead(String threadId, String upToMessageId) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/chat/threads/$threadId/read'),
      headers: await _headers(),
      body: jsonEncode({'messageId': upToMessageId}),
    );
    if (res.statusCode >= 400) {
      // non-fatal — server may not have the read-receipt endpoint
      // wired yet; we just lose the dot on the peer's side.
    }
  }

  Future<Message> _send(
    String threadId, {
    required Map<String, dynamic> body,
  }) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/chat/threads/$threadId/messages'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    if (res.statusCode >= 400) {
      throw Exception('send failed: ${res.statusCode}');
    }
    // NB: the method param is also `body`, so name the response payload
    // differently to avoid shadowing the unsent message body parameter.
    final resp = jsonDecode(res.body) as Map<String, dynamic>;
    // The POST messages route doesn't return `me` (only GET does), so
    // we rely on the stashed value. Fall back to phone if a never-
    // refreshed install hasn't seen `me` yet.
    final myUserId = await _auth.localUserId() ?? await _auth.phone();
    return Message.fromJson(_extractObject(resp), myId: myUserId);
  }
}
