// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/meshtastic/meshtastic_packet_codec.dart';

void main() {
  test('encodeTextToRadio returns non-empty protobuf bytes', () {
    final bytes = MeshtasticPacketCodec.encodeTextToRadio('hello mesh');
    expect(bytes, isNotEmpty);
    expect(bytes.length, greaterThan(8));
  });

  test('encodeTextToRadio rejects empty text', () {
    expect(
      () => MeshtasticPacketCodec.encodeTextToRadio(''),
      throwsArgumentError,
    );
  });

  test('encodeTextToRadio rejects oversized payload', () {
    expect(
      () => MeshtasticPacketCodec.encodeTextToRadio('x' * 201),
      throwsArgumentError,
    );
  });

  test('broadcast destination is 0xFFFFFFFF', () {
    expect(kMeshtasticBroadcast, 0xFFFFFFFF);
  });
}
