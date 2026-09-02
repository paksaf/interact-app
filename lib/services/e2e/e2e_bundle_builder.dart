// SPDX-License-Identifier: AGPL-3.0
//
// Build public pre-key upload JSON for Sahulat POST /talk/e2e/prekeys.

import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'e2e_identity_manager.dart';

Map<String, dynamic> buildE2eUploadBundle({
  required E2eIdentityRecord identity,
  required List<PreKeyRecord> preKeys,
  required SignedPreKeyRecord signedPreKey,
}) {
  return {
    'registrationId': identity.registrationId,
    'deviceId': identity.deviceId,
    'identityPublicKey': identity.identityPublicKeyBase64,
    'signedPreKey': {
      'keyId': signedPreKey.id,
      'publicKey': base64Encode(
        signedPreKey.getKeyPair().publicKey.serialize(),
      ),
      'signature': base64Encode(signedPreKey.signature),
    },
    'oneTimePreKeys': preKeys
        .map(
          (p) => {
            'keyId': p.id,
            'publicKey': base64Encode(p.getKeyPair().publicKey.serialize()),
          },
        )
        .toList(),
  };
}
