// SPDX-License-Identifier: AGPL-3.0
//
// Concrete TalkBearerAdapter implementations — wraps ChatApi, LanService,
// BleMeshTransportService without rewriting those services.

import 'dart:async';

import '../core/offline/talk_bearer_adapter.dart';
import '../models/offline_frame.dart';
import '../models/talk_bearer.dart';
import 'ble_mesh_transport_service.dart';
import 'chat_api.dart';
import 'field_probe_service.dart';
import 'lan_service.dart';
import 'lora_bridge_service.dart';
import 'mesh_cloud_bridge.dart';
import 'p2p_service.dart';
import 'thread_peer_registry.dart';

class CloudBearerAdapter implements TalkBearerAdapter {
  CloudBearerAdapter(this._chatApi);

  final ChatApi _chatApi;

  @override
  TalkBearer get bearer => TalkBearer.cloud;

  @override
  int get maxPayloadBytes => 8000;

  @override
  BearerReach get reach => BearerReach.internet;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<BearerSendResult> send(OfflineFrame frame) async {
    try {
      final sent = await _chatApi.sendText(
        frame.threadId,
        frame.body,
        replyToId: frame.replyToId,
        queueOnFailure: false,
      );
      if (sent.pending) {
        return const BearerSendResult(handed: false);
      }
      return BearerSendResult(handed: true, messageId: sent.id);
    } catch (_) {
      return const BearerSendResult(handed: false);
    }
  }
}

class LanBearerAdapter implements TalkBearerAdapter {
  LanBearerAdapter(this._lan, this._peers);

  final LanService _lan;
  final ThreadPeerRegistry _peers;

  @override
  TalkBearer get bearer => TalkBearer.lan;

  @override
  int get maxPayloadBytes => 4000;

  @override
  BearerReach get reach => BearerReach.site;

  @override
  Future<bool> get isAvailable async => _lan.isRunning;

  @override
  Future<BearerSendResult> send(OfflineFrame frame) async {
    if (!_lan.isRunning) return const BearerSendResult(handed: false);
    final peer = await _peers.resolveLanPeer(
      threadId: frame.threadId,
      discovered: _lan.peers,
      targetPeerUserId: frame.targetPeerUserId,
      lan: _lan,
    );
    if (peer == null) return const BearerSendResult(handed: false);
    try {
      final payload =
          MeshCloudBridge.encodeForThread(frame.threadId, frame.body);
      await _lan.sendText(peer, payload);
      unawaited(FieldProbeService.instance.recordTx(
        bearer: 'lan',
        detail: frame.threadId,
      ));
      return BearerSendResult(handed: true, messageId: frame.id);
    } catch (_) {
      return const BearerSendResult(handed: false);
    }
  }
}

class P2pBearerAdapter implements TalkBearerAdapter {
  P2pBearerAdapter(this._p2p);

  final P2pService _p2p;

  @override
  TalkBearer get bearer => TalkBearer.p2p;

  @override
  int get maxPayloadBytes => 4000;

  @override
  BearerReach get reach => BearerReach.site;

  @override
  Future<bool> get isAvailable async =>
      _p2p.isRunning && _p2p.connectedDevice != null;

  @override
  Future<BearerSendResult> send(OfflineFrame frame) async {
    if (!_p2p.isRunning || _p2p.connectedDevice == null) {
      return const BearerSendResult(handed: false);
    }
    try {
      final payload =
          MeshCloudBridge.encodeForThread(frame.threadId, frame.body);
      await _p2p.sendText(payload);
      unawaited(FieldProbeService.instance.recordTx(
        bearer: 'p2p',
        detail: frame.threadId,
      ));
      return BearerSendResult(handed: true, messageId: frame.id);
    } catch (_) {
      return const BearerSendResult(handed: false);
    }
  }
}

class BleMeshBearerAdapter implements TalkBearerAdapter {
  BleMeshBearerAdapter(this._bleMesh);

  final BleMeshTransportService _bleMesh;

  @override
  TalkBearer get bearer => TalkBearer.bleMesh;

  @override
  int get maxPayloadBytes => 180;

  @override
  BearerReach get reach => BearerReach.broadcast;

  @override
  Future<bool> get isAvailable async => _bleMesh.isRunning;

  @override
  Future<BearerSendResult> send(OfflineFrame frame) async {
    if (!_bleMesh.isRunning) return const BearerSendResult(handed: false);
    final ok = await _bleMesh.sendForThread(frame.threadId, frame.body);
    if (!ok) return const BearerSendResult(handed: false);
    return BearerSendResult(handed: true, messageId: frame.id);
  }
}

class LoraBearerAdapter implements TalkBearerAdapter {
  LoraBearerAdapter(this._lora);

  final LoraBridgeService _lora;

  @override
  TalkBearer get bearer => TalkBearer.lora;

  @override
  int get maxPayloadBytes => 200;

  @override
  BearerReach get reach => BearerReach.broadcast;

  @override
  Future<bool> get isAvailable async => _lora.isConnected;

  @override
  Future<BearerSendResult> send(OfflineFrame frame) async {
    if (!_lora.isConnected) return const BearerSendResult(handed: false);
    try {
      await _lora.sendText(frame.body);
      unawaited(FieldProbeService.instance.recordTx(
        bearer: 'lora',
        detail: frame.threadId,
      ));
      return BearerSendResult(handed: true, messageId: frame.id);
    } catch (_) {
      return const BearerSendResult(handed: false);
    }
  }
}
