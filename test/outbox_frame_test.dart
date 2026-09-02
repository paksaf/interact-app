// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/offline/talk_bearer_adapter.dart';
import 'package:interact/models/offline_frame.dart';
import 'package:interact/models/talk_bearer.dart';
import 'package:interact/services/outbox_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default bearer preference is cloud then lan p2p ble lora', () {
    expect(kDefaultBearerPreference, [
      TalkBearer.cloud,
      TalkBearer.lan,
      TalkBearer.p2p,
      TalkBearer.bleMesh,
      TalkBearer.lora,
    ]);
  });

  test('enqueueFrame stores full OfflineFrame blob', () async {
    final frame = OfflineFrame(
      id: 'off-test-1',
      threadId: 'thread-x',
      body: 'hello offline',
      senderId: 'user-a',
      senderName: 'Alice',
      sentAt: DateTime.utc(2026, 9, 1, 12),
      targetPeerUserId: 'user-b',
    );
    await OutboxService.instance.enqueueFrame(
      frame: frame,
      bearerPreference: kDefaultBearerPreference,
      headers: const {'Authorization': 'Bearer test'},
    );
    final item = await OutboxService.instance.firstPendingChatText(
      threadId: 'thread-x',
    );
    expect(item, isNotNull);
    expect(item!['frame'], isA<Map>());
    final stored = OfflineFrame.fromJson(
      (item['frame'] as Map).cast<String, dynamic>(),
    );
    expect(stored.body, 'hello offline');
    expect(stored.targetPeerUserId, 'user-b');
    expect(item['bearerPreference'], ['cloud', 'lan', 'p2p', 'ble', 'lora']);
  });
}
