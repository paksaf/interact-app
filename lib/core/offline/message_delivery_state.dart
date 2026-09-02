// SPDX-License-Identifier: AGPL-3.0
//
// Honest delivery ticks — cloud confirms receipt; offline radios only confirm
// "handed to bearer" (gossip/LAN cannot prove peer delivery).

import 'package:flutter/material.dart';

import '../../models/talk_bearer.dart';

enum MessageDeliveryKind {
  /// Outbox / router queue — not handed to any bearer yet.
  queued,

  /// Cloud path: accepted by server, no delivery receipt yet.
  cloudSent,

  /// Cloud path: server or peer device got it.
  cloudDelivered,

  /// Cloud path: read receipt.
  cloudRead,

  /// LAN / BLE mesh / LoRa / IoT — handed to the radio, not confirmed delivered.
  handedToBearer,
}

class MessageDeliveryVisual {
  const MessageDeliveryVisual({
    required this.kind,
    required this.icon,
    required this.semanticLabel,
    this.tint,
  });

  final MessageDeliveryKind kind;
  final IconData icon;
  final String semanticLabel;

  /// When set, overrides the bubble foreground alpha tint.
  final Color? tint;
}

class MessageDeliveryState {
  static MessageDeliveryVisual resolve({
    required bool isMine,
    required bool pending,
    required String? bearerWire,
    DateTime? deliveredAt,
    DateTime? readAt,
    Color? foreground,
  }) {
    if (!isMine) {
      return const MessageDeliveryVisual(
        kind: MessageDeliveryKind.cloudSent,
        icon: Icons.minimize,
        semanticLabel: '',
      );
    }

    final bearer = TalkBearer.fromWire(bearerWire);
    final fg = foreground ?? Colors.white;

    if (pending || bearer == TalkBearer.pending) {
      return MessageDeliveryVisual(
        kind: MessageDeliveryKind.queued,
        icon: Icons.schedule,
        semanticLabel: 'Queued — waiting for network',
        tint: fg.withValues(alpha: 0.7),
      );
    }

    if (bearer.confirmsEndToEndDelivery) {
      if (readAt != null) {
        return MessageDeliveryVisual(
          kind: MessageDeliveryKind.cloudRead,
          icon: Icons.done_all,
          semanticLabel: 'Read',
          tint: Colors.lightBlueAccent,
        );
      }
      if (deliveredAt != null) {
        return MessageDeliveryVisual(
          kind: MessageDeliveryKind.cloudDelivered,
          icon: Icons.done_all,
          semanticLabel: 'Delivered',
          tint: fg.withValues(alpha: 0.7),
        );
      }
      return MessageDeliveryVisual(
        kind: MessageDeliveryKind.cloudSent,
        icon: Icons.done,
        semanticLabel: 'Sent',
        tint: fg.withValues(alpha: 0.7),
      );
    }

    if (bearer == TalkBearer.sms) {
      return MessageDeliveryVisual(
        kind: MessageDeliveryKind.handedToBearer,
        icon: Icons.sms,
        semanticLabel: 'Sent via SMS — standard carrier delivery applies',
        tint: fg.withValues(alpha: 0.85),
      );
    }

    return MessageDeliveryVisual(
      kind: MessageDeliveryKind.handedToBearer,
      icon: Icons.sensors,
      semanticLabel: 'Handed to ${bearer.label} — delivery not confirmed',
      tint: fg.withValues(alpha: 0.7),
    );
  }
}

extension TalkBearerDelivery on TalkBearer {
  /// Cloud + explicit SMS confirm get end-to-end style ticks; SMS shows SMS icon.
  bool get confirmsEndToEndDelivery =>
      this == TalkBearer.cloud || this == TalkBearer.ai;
}
