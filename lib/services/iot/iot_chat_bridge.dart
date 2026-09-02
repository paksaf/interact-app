// SPDX-License-Identifier: AGPL-3.0
//
// IoT gateway alerts → Chats thread (Phase 3). Inbound IotFrame alerts and
// telemetry appear in a local "IoT alerts" thread; ACK stays on /iot-comms.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/iot/iot_frame.dart';
import '../../models/chat.dart';
import '../../models/offline_frame.dart';
import '../../models/talk_bearer.dart';
import '../../utils/shared_location_pin.dart';
import 'iot_comms_service.dart';
import '../location_trace_service.dart';
import '../message_repository.dart';

/// Stable local thread — not synced to cloud.
const kIotAlertsThreadId = 'iot-alerts-system';
const kIotAlertsDisplayName = 'IoT alerts';

final iotChatBridgeProvider = Provider<IotChatBridge>((ref) {
  return IotChatBridge(ref.read(messageRepositoryProvider));
});

class IotChatBridge {
  IotChatBridge(this._repo);

  final MessageRepository _repo;
  StreamSubscription<IotFrame>? _sub;
  final _seenIds = <String>{};

  ChatThread syntheticThread({String? preview}) => ChatThread(
        id: kIotAlertsThreadId,
        subjectType: 'general',
        subjectId: kIotAlertsThreadId,
        title: kIotAlertsDisplayName,
        participants: const [],
        lastMessageAt: DateTime.now(),
        lastMessagePreview: preview ?? 'Gateway signals appear here',
        avatarUrl: null,
      );

  bool isIotThread(String threadId) => threadId == kIotAlertsThreadId;

  Future<void> start() async {
    await _sub?.cancel();
    await IotCommsService.instance.loadPrefs();
    for (final frame in IotCommsService.instance.history) {
      await _onFrame(frame);
    }
    _sub = IotCommsService.instance.inbox.listen(_onFrame);
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> _onFrame(IotFrame frame) async {
    if (frame.isMine) return;
    if (frame.kind == IotFrameKind.ack || frame.kind == IotFrameKind.ping) {
      return;
    }
    if (_seenIds.contains(frame.id)) return;
    _seenIds.add(frame.id);
    if (_seenIds.length > 500) {
      _seenIds.remove(_seenIds.first);
    }

    final device = (frame.meta['device'] as String?)?.trim();
    final senderId = device?.isNotEmpty == true ? device! : frame.bearer.wire;
    final senderName = device?.isNotEmpty == true
        ? device!
        : frame.bearer.label;
    final body = _formatBody(frame);

    unawaited(LocationTraceService.instance.recordFromIotFrame(frame));

    try {
      await _repo.upsertInbound(
        OfflineFrame(
          id: 'iot-${frame.id}',
          threadId: kIotAlertsThreadId,
          body: body,
          senderId: senderId,
          senderName: senderName,
          sentAt: frame.at ?? DateTime.now(),
          bearer: _mapBearer(frame.bearer),
        ),
      );
    } catch (e) {
      debugPrint('[iot-chat-bridge] ingest failed: $e');
    }
  }

  String _formatBody(IotFrame frame) {
    final gps = parseIotGpsMeta(frame.meta);
    if (gps != null) {
      final device = frame.meta['device'];
      final name = device != null ? '$device GPS' : 'IoT GPS';
      return formatLocationPinBody(
        lat: gps.lat,
        lng: gps.lng,
        live: frame.meta['live'] == true,
      ).replaceFirst('📍 Shared location', '📍 $name');
    }
    final kind = frame.kind.label;
    final prefix = frame.kind == IotFrameKind.alert ? '⚠️' : '📡';
    final device = frame.meta['device'];
    final deviceTag = device != null ? ' [$device]' : '';
    return '$prefix $kind$deviceTag: ${frame.body}';
  }

  TalkBearer _mapBearer(IotBearer bearer) => switch (bearer) {
        IotBearer.loraBle => TalkBearer.lora,
        IotBearer.meshtastic => TalkBearer.lora,
        IotBearer.rfHttp => TalkBearer.iot,
        IotBearer.autosense => TalkBearer.iot,
        IotBearer.bleMesh => TalkBearer.bleMesh,
        IotBearer.plain => TalkBearer.iot,
      };
}
