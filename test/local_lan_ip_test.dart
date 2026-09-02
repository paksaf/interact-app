// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/net/local_lan_ip.dart';

void main() {
  test('primaryLanIPv4 returns an address or null without throwing', () async {
    final ip = await primaryLanIPv4();
    if (ip != null) {
      expect(ip.contains('.'), isTrue);
      expect(ip.startsWith('127.'), isFalse);
    }
  });
}
