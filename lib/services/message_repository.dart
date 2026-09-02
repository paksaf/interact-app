// SPDX-License-Identifier: AGPL-3.0
//
// Local message cache + unified send entry for OfflineRouter.
// Hive v1 store — merges cloud poll with offline inbound frames.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/mesh_identity_card.dart';
import '../models/chat.dart';
import '../models/offline_frame.dart';
import '../models/talk_bearer.dart';
import 'auth_service.dart';
import 'local_message_store.dart';
import 'location_trace_service.dart';
import 'e2e_crypto_service.dart';
import 'offline_router.dart';
import 'thread_peer_registry.dart';

final messageRepositoryProvider = Provider<MessageRepository>((ref) {
  return MessageRepository(
    ref.read(authServiceProvider),
    ref.read(offlineRouterProvider),
  );
});

class MessageRepository {
  MessageRepository(this._auth, this._router);

  final AuthService _auth;
  final OfflineRouter _router;
  final LocalMessageStore _store = LocalMessageStore.instance;
  final ThreadPeerRegistry _peers = ThreadPeerRegistry.instance;

  final _streams = <String, StreamController<List<Message>>>{};

  Stream<List<Message>> watchThread(String threadId) {
    return _controller(threadId).stream;
  }

  StreamController<List<Message>> _controller(String threadId) {
    return _streams.putIfAbsent(
      threadId,
      () => StreamController<List<Message>>.broadcast(),
    );
  }

  Future<List<Message>> loadLocal(String threadId) async {
    final myId = await _auth.localUserId();
    final rows = await _store.loadThread(threadId);
    return rows
        .map((m) => _messageFromLocal(m, myId))
        .toList();
  }

  Future<void> _persist(String threadId, List<Message> messages) async {
    final encoded = messages.map(_messageToLocal).toList();
    await _store.saveThread(threadId, encoded);
    final ctrl = _streams[threadId];
    if (ctrl != null && !ctrl.isClosed) ctrl.add(messages);
  }

  /// Merge server messages with local-only offline rows (dedupe by id).
  Future<List<Message>> mergeWithServer(
    String threadId,
    List<Message> serverMessages,
  ) async {
    final local = await loadLocal(threadId);
    final byId = <String, Message>{};
    for (final m in serverMessages) {
      byId[m.id] = m;
    }
    for (final m in local) {
      if (m.pending || m.bearer != null && m.bearer != TalkBearer.cloud.wire) {
        byId.putIfAbsent(m.id, () => m);
      }
    }

    // Phase 2 reconcile: drop local pending rows once cloud echoed same body.
    final supersededPending = <String>{};
    for (final m in byId.values) {
      if (!m.isMine || !m.pending) continue;
      for (final s in serverMessages) {
        if (!s.isMine) continue;
        if (s.body.trim() != m.body.trim()) continue;
        if (s.sentAt.difference(m.sentAt).inSeconds.abs() > 180) continue;
        supersededPending.add(m.id);
        break;
      }
    }
    if (supersededPending.isNotEmpty) {
      byId.removeWhere((id, _) => supersededPending.contains(id));
    }

    final merged = byId.values.toList()
      ..sort((a, b) => a.sentAt.compareTo(b.sentAt));
    await _persist(threadId, merged);
    return merged;
  }

  /// Single send path for text — routes via OfflineRouter.
  Future<Message> sendText(
    String threadId,
    String text, {
    String? replyToId,
    String? targetPeerUserId,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw ArgumentError('empty message');
    }
    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    final peerUserId =
        targetPeerUserId ?? await _peers.peerUserIdFor(threadId);
    var wireBody = body;
    if (E2eCryptoService.instance.shouldEncryptOutbound &&
        peerUserId != null &&
        peerUserId.isNotEmpty) {
      wireBody = await E2eCryptoService.instance.encryptOutbound(
        body,
        peerUserId: peerUserId,
      );
    }
    final frame = OfflineFrame(
      id: OfflineFrame.newId(),
      threadId: threadId,
      body: wireBody,
      senderId: myId,
      senderName: myName,
      sentAt: DateTime.now(),
      replyToId: replyToId,
      targetPeerUserId: peerUserId,
    );

    final result = await _router.send(frame);
    final msg = Message(
      id: result.messageId,
      threadId: threadId,
      senderId: myId,
      senderName: myName,
      kind: MessageKind.text,
      body: body,
      sentAt: frame.sentAt,
      isMine: true,
      replyToId: replyToId,
      pending: result.pending,
      bearer: result.bearer.wire,
    );

    final local = await loadLocal(threadId);
    await _persist(threadId, [...local, msg]);

    unawaited(LocationTraceService.instance.recordFromMessageBody(
      body: body,
      senderId: myId,
      senderName: myName,
      threadId: threadId,
      bearer: result.bearer,
    ));
    return msg;
  }

  /// Inbound from LAN/BLE/P2P funnel.
  Future<void> upsertInbound(OfflineFrame frame) async {
    if (frame.body.trim().isEmpty) return;
    final myId = await _auth.localUserId();
    if (frame.senderId.isNotEmpty && frame.senderId == myId) return;

    final senderId = frame.senderId;
    final isUnresolvedMeshPubKey = looksLikeMeshPubKeyHex(senderId);

    if (!isUnresolvedMeshPubKey &&
        frame.threadId.isNotEmpty &&
        senderId.isNotEmpty) {
      await _peers.noteInboundPeer(
        peerUserId: senderId,
        threadId: frame.threadId,
      );
    }

    final msg = Message(
      id: frame.id,
      threadId: frame.threadId,
      senderId: frame.senderId,
      senderName: frame.senderName.isNotEmpty ? frame.senderName : 'Peer',
      kind: MessageKind.text,
      body: frame.body,
      sentAt: frame.sentAt,
      isMine: false,
      bearer: frame.bearer.wire,
    );

    final local = await loadLocal(frame.threadId);
    if (local.any((m) => m.id == msg.id)) return;
    await _persist(frame.threadId, [...local, msg]);

    unawaited(LocationTraceService.instance.recordFromMessageBody(
      body: frame.body,
      senderId: frame.senderId,
      senderName: msg.senderName,
      threadId: frame.threadId,
      bearer: frame.bearer,
    ));
  }

  Future<void> saveLocalThread(String threadId, List<Message> messages) async {
    await _persist(threadId, messages);
  }

  Map<String, dynamic> _messageToLocal(Message m) => {
        'id': m.id,
        'threadId': m.threadId,
        'senderId': m.senderId,
        'senderName': m.senderName,
        'kind': m.kind.name,
        'body': m.body,
        'sentAt': m.sentAt.toIso8601String(),
        'isMine': m.isMine,
        if (m.bearer != null) 'bearer': m.bearer,
        if (m.pending) 'pending': true,
        if (m.replyToId != null) 'replyToId': m.replyToId,
      };

  Message _messageFromLocal(Map<String, dynamic> j, String? myId) {
    final senderId = (j['senderId'] as String?) ?? '';
    return Message(
      id: (j['id'] as String?) ?? OfflineFrame.newId(),
      threadId: (j['threadId'] as String?) ?? '',
      senderId: senderId,
      senderName: (j['senderName'] as String?) ?? senderId,
      kind: MessageKind.text,
      body: (j['body'] as String?) ?? '',
      sentAt: DateTime.tryParse(j['sentAt'] as String? ?? '') ?? DateTime.now(),
      isMine: (j['isMine'] as bool?) ?? (myId != null && senderId == myId),
      bearer: j['bearer'] as String?,
      pending: (j['pending'] as bool?) ?? false,
      replyToId: j['replyToId'] as String?,
    );
  }
}
