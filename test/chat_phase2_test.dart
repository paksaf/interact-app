// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/models/talk_bearer.dart';
import 'package:interact/services/chat_connectivity_service.dart';
import 'package:interact/services/e2e_crypto_service.dart';

void main() {
  test('ChatConnectivitySnapshot offline status line', () {
    final snap = ChatConnectivitySnapshot(
      cloudReachable: false,
      lanRunning: true,
      bleMeshRunning: false,
      p2pRunning: false,
      probedAt: DateTime.utc(2026, 9, 1),
    );
    expect(snap.hasOfflineTextPath, isTrue);
    expect(snap.availableOfflineBearers, [TalkBearer.lan]);
    expect(snap.statusLine, contains('Offline'));
  });

  test('E2E not shipped — honest stub', () {
    expect(E2eCryptoService.instance.status, E2eStatus.notAvailable);
    expect(E2eCryptoService.instance.shouldEncryptOutbound, isFalse);
  });

  test('ChatMediaPolicy message is non-empty', () {
    expect(ChatMediaPolicy.offlineMediaMessage, contains('internet'));
  });
}
