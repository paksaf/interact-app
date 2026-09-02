// SPDX-License-Identifier: AGPL-3.0
//
// Formal bearer adapters — audit step 2. Thin wrappers over existing transports.

import '../../models/offline_frame.dart';
import '../../models/talk_bearer.dart';

enum BearerReach {
  internet,
  site,
  broadcast,
}

class BearerSendResult {
  const BearerSendResult({
    required this.handed,
    this.messageId,
  });

  /// True when the frame left this device on the bearer (not merely queued).
  final bool handed;
  final String? messageId;
}

/// Default retry order when flushing the outbox (SMS excluded — user-confirmed).
const kDefaultBearerPreference = <TalkBearer>[
  TalkBearer.cloud,
  TalkBearer.lan,
  TalkBearer.p2p,
  TalkBearer.bleMesh,
  TalkBearer.lora,
];

abstract class TalkBearerAdapter {
  TalkBearer get bearer;
  int get maxPayloadBytes;
  BearerReach get reach;

  Future<bool> get isAvailable;

  Future<BearerSendResult> send(OfflineFrame frame);
}
