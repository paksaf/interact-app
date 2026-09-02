// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/services/e2e/e2e_envelope.dart';

void main() {
  test('e2e envelope wrap and unwrap', () {
    expect(isE2eEnvelope('hello'), isFalse);
    final wrapped = wrapE2eCiphertext('abc123');
    expect(wrapped, 'e2e:v1:abc123');
    expect(isE2eEnvelope(wrapped), isTrue);
    expect(unwrapE2eCiphertext(wrapped), 'abc123');
    expect(unwrapE2eCiphertext('plain'), isNull);
  });
}
