// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/offline/message_delivery_state.dart';
import 'package:interact/models/talk_bearer.dart';

void main() {
  test('queued shows schedule icon', () {
    final v = MessageDeliveryState.resolve(
      isMine: true,
      pending: true,
      bearerWire: TalkBearer.cloud.wire,
    );
    expect(v.kind, MessageDeliveryKind.queued);
    expect(v.icon, Icons.schedule);
  });

  test('cloud read uses blue double tick', () {
    final v = MessageDeliveryState.resolve(
      isMine: true,
      pending: false,
      bearerWire: TalkBearer.cloud.wire,
      readAt: DateTime.now(),
    );
    expect(v.kind, MessageDeliveryKind.cloudRead);
    expect(v.icon, Icons.done_all);
    expect(v.tint, Colors.lightBlueAccent);
  });

  test('BLE mesh handed off does not show cloud delivered ticks', () {
    final v = MessageDeliveryState.resolve(
      isMine: true,
      pending: false,
      bearerWire: TalkBearer.bleMesh.wire,
      deliveredAt: DateTime.now(),
      readAt: DateTime.now(),
    );
    expect(v.kind, MessageDeliveryKind.handedToBearer);
    expect(v.icon, Icons.sensors);
    expect(v.semanticLabel, contains('not confirmed'));
  });

  test('SMS handed off shows sms icon', () {
    final v = MessageDeliveryState.resolve(
      isMine: true,
      pending: false,
      bearerWire: TalkBearer.sms.wire,
    );
    expect(v.kind, MessageDeliveryKind.handedToBearer);
    expect(v.icon, Icons.sms);
    expect(v.semanticLabel, contains('SMS'));
  });
}
