// SPDX-License-Identifier: AGPL-3.0
//
// Bearer selection via formal adapters: Cloud → LAN → BLE → outbox queue.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/talk_bearer_adapter.dart';
import '../models/offline_frame.dart';
import '../models/talk_bearer.dart';
import 'auth_service.dart';
import 'bearer_adapters.dart';
import 'ble_mesh_transport_service.dart';
import 'chat_api.dart';
import 'lan_service.dart';
import 'lora_bridge_service.dart';
import 'outbox_service.dart';
import 'p2p_service.dart';
import 'thread_peer_registry.dart';

final offlineRouterProvider = Provider<OfflineRouter>((ref) {
  return OfflineRouter(
    ref.read(chatApiProvider),
    ref.read(authServiceProvider),
    ref.read(lanServiceProvider),
    ref.read(bleMeshTransportServiceProvider),
    ref.read(p2pServiceProvider),
    LoraBridgeService.instance,
  );
});

class RouteResult {
  RouteResult({
    required this.messageId,
    required this.bearer,
    this.pending = false,
  });

  final String messageId;
  final TalkBearer bearer;
  final bool pending;
}

class OfflineRouter {
  OfflineRouter(
    ChatApi chatApi,
    this._auth,
    this._lan,
    this._bleMesh,
    P2pService p2p,
    LoraBridgeService lora, {
    List<TalkBearerAdapter>? adapters,
  }) : _adapters = adapters ??
            [
              CloudBearerAdapter(chatApi),
              LanBearerAdapter(_lan, ThreadPeerRegistry.instance),
              P2pBearerAdapter(p2p),
              BleMeshBearerAdapter(_bleMesh),
              LoraBearerAdapter(lora),
            ];

  final AuthService _auth;
  final LanService _lan;
  final BleMeshTransportService _bleMesh;
  final List<TalkBearerAdapter> _adapters;

  Future<RouteResult> send(
    OfflineFrame frame, {
    List<TalkBearer>? bearerPreference,
  }) async {
    final order = bearerPreference ?? kDefaultBearerPreference;
    for (final pref in order) {
      TalkBearerAdapter? adapter;
      for (final a in _adapters) {
        if (a.bearer == pref) {
          adapter = a;
          break;
        }
      }
      if (adapter == null) continue;
      if (!await adapter.isAvailable) continue;
      try {
        final result = await adapter.send(frame);
        if (result.handed) {
          return RouteResult(
            messageId: result.messageId ?? frame.id,
            bearer: adapter.bearer,
          );
        }
      } catch (e) {
        debugPrint('[offline-router] ${adapter.bearer.wire} failed: $e');
      }
    }

    await _queueFrame(frame, lastBearer: TalkBearer.pending);
    return RouteResult(
      messageId: 'pending-${frame.id}',
      bearer: TalkBearer.pending,
      pending: true,
    );
  }

  /// Replay a queued outbox row through the full bearer stack.
  Future<bool> replayOutboxItem(Map<String, dynamic> item) async {
    final frame = await _frameFromOutboxItem(item);
    if (frame == null) return false;

    final pref = _preferenceFromItem(item);
    final result = await send(frame, bearerPreference: pref);
    return !result.pending;
  }

  Future<OfflineFrame?> _frameFromOutboxItem(Map<String, dynamic> item) async {
    final frameJson = item['frame'];
    if (frameJson is Map) {
      return OfflineFrame.fromJson(frameJson.cast<String, dynamic>());
    }
    final threadId = item['threadId'] as String?;
    final bodyMap = (item['body'] as Map?)?.cast<String, dynamic>();
    if (threadId == null || bodyMap == null) return null;
    final body = (bodyMap['body'] as String?)?.trim() ?? '';
    if (body.isEmpty) return null;
    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    return OfflineFrame(
      id: (item['id'] as String?) ?? OfflineFrame.newId(),
      threadId: threadId,
      body: body,
      senderId: (item['senderId'] as String?) ?? myId,
      senderName: (item['senderName'] as String?) ?? myName,
      sentAt: DateTime.now(),
      replyToId: bodyMap['replyToId'] as String?,
      targetPeerUserId: item['targetPeerUserId'] as String?,
    );
  }

  List<TalkBearer> _preferenceFromItem(Map<String, dynamic> item) {
    final raw = item['bearerPreference'];
    if (raw is List && raw.isNotEmpty) {
      return raw
          .map((e) => TalkBearer.fromWire(e?.toString()))
          .toList();
    }
    return kDefaultBearerPreference;
  }

  Future<void> _queueFrame(
    OfflineFrame frame, {
    TalkBearer? lastBearer,
  }) async {
    final myId = await _auth.localUserId() ?? 'local';
    final myName = await _auth.displayName() ?? 'Me';
    final targetPeer =
        frame.targetPeerUserId ??
            await ThreadPeerRegistry.instance.peerUserIdFor(frame.threadId);
    final enriched = OfflineFrame(
      id: frame.id,
      threadId: frame.threadId,
      body: frame.body,
      senderId: frame.senderId.isNotEmpty ? frame.senderId : myId,
      senderName: frame.senderName.isNotEmpty ? frame.senderName : myName,
      sentAt: frame.sentAt,
      bearer: frame.bearer,
      replyToId: frame.replyToId,
      targetPeerUserId: targetPeer,
      meshSenderPubKey: frame.meshSenderPubKey,
    );
    await OutboxService.instance.enqueueFrame(
      frame: enriched,
      bearerPreference: kDefaultBearerPreference,
      lastBearer: lastBearer,
      headers: {
        'Content-Type': 'application/json',
        if (await _auth.token() case final token?) 'Authorization': 'Bearer $token',
      },
    );
  }

  Future<void> ensureBleMesh() async {
    if (!_bleMesh.isRunning) {
      await _bleMesh.start();
    }
  }

  Future<void> ensureLan() async {
    if (_lan.isRunning) return;
    final peerId = await _auth.localUserId() ??
        await _auth.phone() ??
        'anon-${DateTime.now().millisecondsSinceEpoch}';
    final name = await _auth.displayName() ?? 'INTERACT peer';
    await _lan.start(peerId: peerId, displayName: name);
  }
}
