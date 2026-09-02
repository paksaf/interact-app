// SPDX-License-Identifier: AGPL-3.0
//
// Cross-bearer inbound dedupe → MessageRepository.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/offline/mesh_identity_card.dart';
import '../models/offline_frame.dart';
import '../models/talk_bearer.dart';
import 'ble_mesh_transport_service.dart';
import 'lan_service.dart';
import 'field_probe_service.dart';
import 'mesh_cloud_bridge.dart';
import 'mesh_peer_registry.dart';
import 'message_repository.dart';

final inboundFunnelProvider = Provider<InboundFunnel>((ref) {
  return InboundFunnel(
    ref.read(messageRepositoryProvider),
    ref.read(lanServiceProvider),
    ref.read(bleMeshTransportServiceProvider),
  );
});

class InboundFunnel {
  InboundFunnel(this._repo, this._lan, this._bleMesh);

  final MessageRepository _repo;
  final LanService _lan;
  final BleMeshTransportService _bleMesh;

  StreamSubscription? _lanSub;
  StreamSubscription? _bleSub;
  final _seenIds = <String>{};

  Future<void> start() async {
    await _lanSub?.cancel();
    await _bleSub?.cancel();

    _lanSub = _lan.messages.listen((m) async {
      if (m.isMine) return;
      final body = m.body;
      final threadId = _threadFromTalkEnvelope(body) ?? 'offline-lan';
      await ingest(OfflineFrame(
        id: 'lan-${m.fromPeerId}-${m.at.millisecondsSinceEpoch}',
        threadId: threadId,
        body: MeshCloudBridge.plainBody(body) ?? body,
        senderId: m.fromPeerId,
        senderName: m.fromName,
        sentAt: m.at,
        bearer: TalkBearer.lan,
      ));
    });

    _bleSub = _bleMesh.inbound.listen((evt) async {
      final plain = MeshCloudBridge.plainBody(evt.raw);
      if (plain == null || plain.isEmpty) return;
      final threadId = _threadFromTalkEnvelope(evt.raw) ?? 'offline-ble';
      var senderId = evt.from;
      var senderName = 'Mesh peer';
      if (looksLikeMeshPubKeyHex(senderId)) {
        final binding =
            await MeshPeerRegistry.instance.lookupByPubKey(senderId);
        if (binding != null) {
          senderId = binding.talkUserId;
          senderName = binding.displayName;
        } else {
          senderName = 'Mesh ${senderId.substring(0, 8)}…';
        }
      }
      await ingest(OfflineFrame(
        // Key by stable content, NOT arrival time: sahl_mesh rebroadcasts
        // each frame with TTL, so DateTime.now() gave every hop a new id and
        // defeated dedupe → duplicate messages in the UI. raw.hashCode is
        // stable for identical frames within the session.
        id: 'ble-${evt.from}-${evt.raw.hashCode}',
        threadId: threadId,
        body: plain,
        senderId: senderId,
        senderName: senderName,
        sentAt: DateTime.now(),
        bearer: TalkBearer.bleMesh,
        meshSenderPubKey: evt.from,
      ));
    });
  }

  Future<void> stop() async {
    await _lanSub?.cancel();
    await _bleSub?.cancel();
    _lanSub = null;
    _bleSub = null;
  }

  Future<void> ingest(OfflineFrame frame) async {
    if (_seenIds.contains(frame.id)) return;
    _seenIds.add(frame.id);
    if (_seenIds.length > 500) {
      _seenIds.remove(_seenIds.first);
    }
    if (frame.bearer == TalkBearer.lan ||
        frame.bearer == TalkBearer.bleMesh) {
      unawaited(FieldProbeService.instance.recordRx(
        bearer: frame.bearer.wire,
        detail: frame.threadId,
      ));
    }
    await _repo.upsertInbound(frame);
  }

  String? _threadFromTalkEnvelope(String raw) {
    if (!raw.startsWith('talk:1|')) return null;
    final rest = raw.substring(7);
    final sep = rest.indexOf('|');
    if (sep <= 0) return null;
    return rest.substring(0, sep);
  }
}
