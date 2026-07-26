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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/chat.dart';
import 'auth_service.dart';
import 'outbox_service.dart';

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
    this.isEmail = false,
  });
  final String rawPhone;          // what the user typed (phone OR email)
  final String normalizedPhone;   // E.164 the server resolved to (or rawPhone if unparseable / email)
  /// True when the lookup was by email — the caller can't SMS-invite an
  /// email, so the UI shows a note instead of the phone InviteSheet.
  final bool isEmail;
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

  /// Register this device's FCM push token so the shared Talk backend can wake
  /// the app for a background/killed-state incoming-call ring (#FCM). Idempotent
  /// (upsert by token) — safe to call on every boot. Best-effort: returns false
  /// on any failure so a push hiccup never blocks login/startup.
  Future<bool> registerPushToken(String token, {String platform = 'android', String? appId}) async {
    try {
      final res = await http.post(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: await _headers(),
        body: jsonEncode({
          'platform': platform,
          'token': token,
          if (appId != null) 'appId': appId,
        }),
      );
      return res.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  /// Remove this device's push token (logout / notifications off). Best-effort.
  Future<void> unregisterPushToken(String token) async {
    try {
      await http.delete(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: await _headers(),
        body: jsonEncode({'token': token}),
      );
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
  /// Pass EITHER [peerPhone] or [peerEmail] (email takes precedence when
  /// both are non-empty). The server resolves a registered INTERACT user by
  /// number or email symmetrically (#128).
  Future<DirectThreadResult> createDirectThread({
    String? peerPhone,
    String? peerEmail,
  }) async {
    final email = peerEmail?.trim() ?? '';
    final phone = peerPhone?.trim() ?? '';
    final isEmail = email.isNotEmpty;
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/chat/threads'),
      headers: await _headers(),
      body: jsonEncode({
        'subjectType': 'general',
        if (isEmail) 'peerEmail': email else 'peerPhone': phone,
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
        final raw = isEmail ? email : phone;
        return DirectThreadUnregistered(
          rawPhone: raw,
          normalizedPhone: (data['normalized'] as String?) ?? raw,
          isEmail: isEmail,
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
      throw const InviteQuotaExhausted();
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

  /// Send a text message. Pass [replyToId] (a hub message id) to quote/reply.
  /// On network failure the payload is queued in [OutboxService] and a local
  /// pending [Message] is returned so the bubble can show a clock icon.
  Future<Message> sendText(String threadId, String text, {String? replyToId}) async {
    return _send(threadId, body: {
      'kind': 'text',
      'body': text,
      if (replyToId != null) 'replyToId': replyToId,
    });
  }

  /// Send a voice message. [mediaUrl] is the absolute URL from [uploadMedia];
  /// [durationSec] feeds the waveform UI. Optional [transcript] is attached
  /// for accessibility + search (on-device Whisper or server STT).
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
      if (transcript != null && transcript.trim().isNotEmpty)
        'transcript': transcript.trim(),
    });
  }

  /// Best-effort voice transcription. Posts the audio to Talk's STT route;
  /// returns null when the server has no STT configured (creds-gated).
  Future<String?> transcribeVoiceNote(File file) async {
    try {
      final t = await _auth.token();
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_kBase/api/v1/talk/transcribe'),
      );
      if (t != null) req.headers['Authorization'] = 'Bearer $t';
      req.files.add(await http.MultipartFile.fromPath('file', file.path));
      final res = await http.Response.fromStream(await req.send());
      if (res.statusCode >= 400) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      final text = (data['text'] as String?)?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } catch (_) {
      return null;
    }
  }

  /// Upload a file (image/video/audio/document) to the media endpoint and
  /// return its ABSOLUTE url + resolved mediaType. The backend caps images at
  /// 5 MB and video/audio/file at 50 MB and blocks executables; callers should
  /// also guard 50 MB client-side for a friendly message before uploading.
  Future<({String url, String mediaType})> uploadMedia(File file) async {
    final t = await _auth.token();
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_kBase/api/v1/media/upload'),
    );
    if (t != null) req.headers['Authorization'] = 'Bearer $t';
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode >= 400) {
      throw Exception('upload failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] ?? body) as Map<String, dynamic>;
    final rel = (data['url'] as String?) ?? '';
    if (rel.isEmpty) throw Exception('upload returned no url');
    // media/upload returns a RELATIVE path (/uploads/...); make it absolute so
    // Image.network / launchUrl work from the app.
    final abs = rel.startsWith('http') ? rel : '$_kBase$rel';
    return (url: abs, mediaType: (data['mediaType'] as String?) ?? 'file');
  }

  /// Send a message with an attachment URL (from [uploadMedia]) + optional
  /// caption. `attachment` is the field the messages route maps to mediaUrl.
  Future<Message> sendAttachment(
    String threadId, {
    required String url,
    String caption = '',
  }) async {
    return _send(threadId, body: {'body': caption, 'attachment': url});
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
    final url = '$_kBase/api/v1/chat/threads/$threadId/messages';
    final headers = await _headers();
    final myUserId = await _auth.localUserId() ?? await _auth.phone() ?? '';
    try {
      final res = await http
          .post(
            Uri.parse(url),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode >= 400) {
        // Queue recoverable failures (offline / 5xx). Client 4xx stays loud.
        if (res.statusCode >= 500 || res.statusCode == 408 || res.statusCode == 429) {
          await OutboxService.instance.enqueue(
            url: url,
            body: body,
            headers: headers,
            kind: 'chat_text',
          );
          return _pendingLocal(threadId, body, myUserId);
        }
        throw Exception('send failed: ${res.statusCode}');
      }
      final resp = jsonDecode(res.body) as Map<String, dynamic>;
      return Message.fromJson(_extractObject(resp), myId: myUserId);
    } on SocketException {
      await OutboxService.instance.enqueue(
        url: url,
        body: body,
        headers: headers,
        kind: 'chat_text',
      );
      return _pendingLocal(threadId, body, myUserId);
    } on http.ClientException {
      await OutboxService.instance.enqueue(
        url: url,
        body: body,
        headers: headers,
        kind: 'chat_text',
      );
      return _pendingLocal(threadId, body, myUserId);
    } on TimeoutException {
      await OutboxService.instance.enqueue(
        url: url,
        body: body,
        headers: headers,
        kind: 'chat_text',
      );
      return _pendingLocal(threadId, body, myUserId);
    }
  }

  Message _pendingLocal(
    String threadId,
    Map<String, dynamic> body,
    String myUserId,
  ) {
    return Message(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      threadId: threadId,
      senderId: myUserId,
      senderName: 'You',
      kind: MessageKind.text,
      body: (body['body'] as String?) ?? '',
      sentAt: DateTime.now(),
      isMine: true,
      pending: true,
      replyToId: body['replyToId'] as String?,
    );
  }

  // ─── Message actions: reactions / edit / delete / pin (P1 overlay) ────
  /// Add my [emoji] reaction to a message. Returns the updated reaction list.
  Future<List<MessageReaction>> react(String threadId, String messageId, String emoji) =>
      _reactionCall('POST', threadId, messageId, emoji);

  /// Remove my [emoji] reaction. Returns the updated reaction list.
  Future<List<MessageReaction>> unreact(String threadId, String messageId, String emoji) =>
      _reactionCall('DELETE', threadId, messageId, emoji);

  Future<List<MessageReaction>> _reactionCall(
    String method,
    String threadId,
    String messageId,
    String emoji,
  ) async {
    final uri = Uri.parse('$_kBase/api/v1/chat/threads/$threadId/messages/$messageId/reactions');
    final headers = await _headers();
    final payload = jsonEncode({'emoji': emoji});
    final res = method == 'POST'
        ? await http.post(uri, headers: headers, body: payload)
        : await http.delete(uri, headers: headers, body: payload);
    if (res.statusCode >= 400) throw Exception('reaction failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    return ((data['reactions'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MessageReaction.fromJson)
        .toList();
  }

  /// Edit my message (author-gated server-side). Best-effort; throws on 4xx.
  Future<void> editMessage(String threadId, String messageId, String body) =>
      _patchMessage(threadId, messageId, {'action': 'edit', 'body': body});

  /// Delete-for-everyone (author-gated server-side).
  Future<void> deleteMessage(String threadId, String messageId) =>
      _patchMessage(threadId, messageId, {'action': 'delete'});

  /// Pin / unpin a message (any participant).
  Future<void> pinMessage(String threadId, String messageId, {required bool pinned}) =>
      _patchMessage(threadId, messageId, {'action': pinned ? 'pin' : 'unpin'});

  Future<void> _patchMessage(String threadId, String messageId, Map<String, dynamic> body) async {
    final res = await http.patch(
      Uri.parse('$_kBase/api/v1/chat/threads/$threadId/messages/$messageId'),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    if (res.statusCode >= 400) throw Exception('message action failed: ${res.statusCode}');
  }

  // ─── AI meeting summary (P2) ─────────────────────────────────────────
  /// Summarize a meeting transcript → grounded summary + action items.
  /// [lang] (en/ur/ar/tr/ru) yields the summary in that language.
  Future<({String summary, List<String> actionItems})> summarizeMeeting(
    String threadId,
    String transcript, {
    String? lang,
  }) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/meetings/summary'),
      headers: await _headers(),
      body: jsonEncode({
        'threadId': threadId,
        'transcript': transcript,
        if (lang != null) 'lang': lang,
      }),
    );
    if (res.statusCode >= 400) throw Exception('meeting summary failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    final items = ((data['actionItems'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    return (summary: (data['summary'] as String?) ?? '', actionItems: items);
  }

  // ─── Profile picture (#131) ──────────────────────────────────────────
  /// Upload an image via media/upload then set it as the caller's avatar.
  /// Returns the stored URL.
  Future<String> setAvatarFromFile(File image) async {
    final up = await uploadMedia(image);
    await http.post(
      Uri.parse('$_kBase/api/v1/talk/profile/avatar'),
      headers: await _headers(),
      body: jsonEncode({'url': up.url}),
    );
    return up.url;
  }

  // ─── Groups (#132) ───────────────────────────────────────────────────
  /// Create a named group with the given member phone numbers. Returns the
  /// new group ChatThread.
  Future<ChatThread> createGroup({
    required String title,
    required List<String> memberPhones,
  }) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/groups'),
      headers: await _headers(),
      body: jsonEncode({'title': title, 'memberPhones': memberPhones}),
    );
    if (res.statusCode >= 400) {
      throw Exception('createGroup failed: ${res.statusCode}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    await _captureMeFromBody(body);
    final data = (body['data'] ?? body) as Map<String, dynamic>;
    final th = (data['thread'] is Map<String, dynamic>)
        ? data['thread'] as Map<String, dynamic>
        : data;
    return ChatThread.fromJson(th);
  }

  /// Add a member to a group by phone. Returns false if the number isn't a
  /// registered INTERACT user.
  Future<bool> addGroupMember(String threadId, String phone) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/groups/$threadId/members'),
      headers: await _headers(),
      body: jsonEncode({'phone': phone}),
    );
    if (res.statusCode >= 400) throw Exception('addMember failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    return data['found'] != false; // {found:false} when unregistered
  }

  /// Leave a group (remove self).
  Future<void> leaveGroup(String threadId, String myUserId) async {
    await http.delete(
      Uri.parse('$_kBase/api/v1/talk/groups/$threadId/members'),
      headers: await _headers(),
      body: jsonEncode({'userId': myUserId}),
    );
  }

  /// The caller's current avatar URL (or null).
  // ─── Scheduled send + search (P3) ────────────────────────────────────
  /// Queue a message to send later. [sendAt] is a future time.
  Future<void> scheduleMessage(String threadId, String body, DateTime sendAt) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/scheduled'),
      headers: await _headers(),
      body: jsonEncode({
        'threadId': threadId,
        'body': body,
        'sendAt': sendAt.toUtc().toIso8601String(),
      }),
    );
    if (res.statusCode >= 400) throw Exception('schedule failed: ${res.statusCode}');
  }

  /// Full-text search my messages (optionally within one thread).
  Future<List<Map<String, dynamic>>> searchMessages(String q, {String? threadId}) async {
    final uri = Uri.parse('$_kBase/api/v1/talk/search').replace(
      queryParameters: {'q': q, if (threadId != null) 'threadId': threadId},
    );
    final res = await http.get(uri, headers: await _headers());
    if (res.statusCode >= 400) throw Exception('search failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    return ((data['hits'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  // ─── Channels / Communities / Username (P2/P3) ───────────────────────
  /// Create a broadcast channel (owner-only posting). Returns the thread.
  Future<ChatThread> createChannel(String title) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/channels'),
      headers: await _headers(),
      body: jsonEncode({'title': title}),
    );
    if (res.statusCode >= 400) throw Exception('createChannel failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    return ChatThread.fromJson(data['thread'] as Map<String, dynamic>);
  }

  /// Create a community (group-of-groups). Returns its id.
  Future<String> createCommunity(String title) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/communities'),
      headers: await _headers(),
      body: jsonEncode({'title': title}),
    );
    if (res.statusCode >= 400) throw Exception('createCommunity failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    final c = data['community'];
    return (c is Map<String, dynamic> ? c['id'] as String? : null) ?? '';
  }

  /// Communities the caller owns or belongs to (+ threadCount). Each entry:
  /// { id, title, ownerId, createdAt, threadCount }.
  Future<List<Map<String, dynamic>>> listCommunities() async {
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/communities'),
      headers: await _headers(),
    );
    if (res.statusCode >= 400) throw Exception('listCommunities failed: ${res.statusCode}');
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    return ((data['communities'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Attach a (group) thread to a community I own. 403 if I'm not the owner or
  /// not a participant of the thread.
  Future<void> attachThreadToCommunity(String communityId, String threadId) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/communities/$communityId/threads'),
      headers: await _headers(),
      body: jsonEncode({'threadId': threadId}),
    );
    if (res.statusCode >= 400) throw Exception('attachThread failed: ${res.statusCode}');
  }

  /// Claim/set my @handle. Returns false if the handle is already taken (409).
  Future<bool> setUsername(String username) async {
    final res = await http.post(
      Uri.parse('$_kBase/api/v1/talk/profile/username'),
      headers: await _headers(),
      body: jsonEncode({'username': username}),
    );
    if (res.statusCode == 409) return false;
    if (res.statusCode >= 400) throw Exception('setUsername failed: ${res.statusCode}');
    return true;
  }

  /// Look up a registered peer by @handle. Returns null when not found.
  Future<({String? phone, String? email, String? fullName})?> lookupUsername(
    String handle,
  ) async {
    var u = handle.trim().toLowerCase();
    if (u.startsWith('@')) u = u.substring(1);
    if (u.isEmpty) return null;
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/profile/username?u=${Uri.encodeQueryComponent(u)}'),
      headers: await _headers(),
    );
    if (res.statusCode >= 400) return null;
    final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
    if (data['found'] != true) return null;
    return (
      phone: data['phone'] as String?,
      email: data['email'] as String?,
      fullName: data['fullName'] as String?,
    );
  }

  Future<String?> getAvatar() async {
    try {
      final res = await http.get(
        Uri.parse('$_kBase/api/v1/talk/profile/avatar'),
        headers: await _headers(),
      );
      if (res.statusCode != 200) return null;
      final data = _extractObject(jsonDecode(res.body) as Map<String, dynamic>);
      return data['avatarUrl'] as String?;
    } catch (_) {
      return null;
    }
  }
}
