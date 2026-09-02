// SPDX-License-Identifier: AGPL-3.0
//
// Wire format for Signal ciphertext in chat bodies (Phase 1.5).

const kE2eEnvelopePrefix = 'e2e:v1:';

bool isE2eEnvelope(String body) => body.startsWith(kE2eEnvelopePrefix);

String wrapE2eCiphertext(String base64Ciphertext) =>
    '$kE2eEnvelopePrefix$base64Ciphertext';

String? unwrapE2eCiphertext(String body) {
  if (!isE2eEnvelope(body)) return null;
  final payload = body.substring(kE2eEnvelopePrefix.length).trim();
  return payload.isEmpty ? null : payload;
}
