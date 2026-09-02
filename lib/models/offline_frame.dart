// SPDX-License-Identifier: AGPL-3.0
//
// Unified offline message envelope for OfflineRouter + InboundFunnel.

import 'talk_bearer.dart';

class OfflineFrame {
  OfflineFrame({
    required this.id,
    required this.threadId,
    required this.body,
    required this.senderId,
    required this.senderName,
    required this.sentAt,
    this.bearer = TalkBearer.cloud,
    this.replyToId,
    this.targetPeerUserId,
    this.meshSenderPubKey,
  });

  final String id;
  final String threadId;
  final String body;
  final String senderId;
  final String senderName;
  final DateTime sentAt;
  final TalkBearer bearer;
  final String? replyToId;
  /// 1:1 thread peer userId — used to pick the correct LAN/BLE target.
  final String? targetPeerUserId;
  /// Ed25519 mesh pubkey hex when sender came over BLE gossip.
  final String? meshSenderPubKey;

  Map<String, dynamic> toJson() => {
        'id': id,
        'threadId': threadId,
        'body': body,
        'senderId': senderId,
        'senderName': senderName,
        'sentAt': sentAt.toIso8601String(),
        'bearer': bearer.wire,
        if (replyToId != null) 'replyToId': replyToId,
        if (targetPeerUserId != null) 'targetPeerUserId': targetPeerUserId,
        if (meshSenderPubKey != null) 'meshSenderPubKey': meshSenderPubKey,
      };

  factory OfflineFrame.fromJson(Map<String, dynamic> j) => OfflineFrame(
        id: (j['id'] as String?) ?? '',
        threadId: (j['threadId'] as String?) ?? '',
        body: (j['body'] as String?) ?? '',
        senderId: (j['senderId'] as String?) ?? '',
        senderName: (j['senderName'] as String?) ?? '',
        sentAt: DateTime.tryParse(j['sentAt'] as String? ?? '') ?? DateTime.now(),
        bearer: TalkBearer.fromWire(j['bearer'] as String?),
        replyToId: j['replyToId'] as String?,
        targetPeerUserId: j['targetPeerUserId'] as String?,
        meshSenderPubKey: j['meshSenderPubKey'] as String?,
      );

  static String newId() =>
      'off-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
}
