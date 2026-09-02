// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/services/e2e/e2e_bundle_builder.dart';
import 'package:interact/services/e2e/e2e_identity_manager.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

void main() {
  test('buildE2eUploadBundle exposes public keys only', () {
    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    const deviceId = 1;
    final preKeys = generatePreKeys(0, 3);
    final signedPreKey = generateSignedPreKey(identityKeyPair, 0);

    final record = E2eIdentityRecord(
      registrationId: registrationId,
      identityPublicKeyBase64: 'pub',
      deviceId: deviceId,
      installedAt: DateTime.utc(2026, 9, 2),
    );

    final bundle = buildE2eUploadBundle(
      identity: record,
      preKeys: preKeys,
      signedPreKey: signedPreKey,
    );

    expect(bundle['registrationId'], registrationId);
    expect(bundle['deviceId'], deviceId);
    expect(bundle['identityPublicKey'], 'pub');
    expect(bundle['signedPreKey'], isA<Map>());
    final otps = bundle['oneTimePreKeys'] as List;
    expect(otps.length, 3);
    for (final k in otps) {
      expect(k, isA<Map>());
      expect((k as Map)['publicKey'], isA<String>());
      expect(k.containsKey('privateKey'), isFalse);
    }
  });
}
