// SPDX-License-Identifier: AGPL-3.0
//
// SessionBuilder + SessionCipher wrapper (Phase 1.5). Establishes a 1:1 Signal
// session from a peer's fetched pre-key bundle, then encrypts/decrypts message
// bodies. The wire payload (inside the `e2e:v1:` envelope) is
// `<ciphertextType>:<base64>` so decrypt can pick PreKeySignalMessage (type 3)
// vs SignalMessage (type 2). Backed by E2ePersistentSignalStore.
import 'dart:convert';
import 'dart:typed_data';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '../auth_service.dart';
import 'e2e_prekey_api.dart';
import 'e2e_signal_store.dart';

class E2eSessionService {
  E2eSessionService._();
  static final E2eSessionService instance = E2eSessionService._();

  E2ePersistentSignalStore? _store;

  Future<E2ePersistentSignalStore?> _ensureStore() async =>
      _store ??= await E2ePersistentSignalStore.open();

  SignalProtocolAddress _addr(String peerUserId) =>
      SignalProtocolAddress(peerUserId, 1);

  E2ePreKeyApi get _api => E2ePreKeyApi(AuthService.instance);

  /// True if we already hold (or just built) a session with [peerUserId].
  /// Returns false when the peer has no pre-key bundle (not E2E-capable yet).
  Future<bool> ensureSession(String peerUserId) async {
    final store = await _ensureStore();
    if (store == null) return false;
    final addr = _addr(peerUserId);
    if (await store.containsSession(addr)) return true;
    final data = await _api.fetchPeerBundle(peerUserId);
    if (data == null) return false;
    final bundle = _bundleFromJson(data);
    if (bundle == null) return false;
    // Same object satisfies all four store roles.
    final builder = SessionBuilder(store, store, store, store, addr);
    await builder.processPreKeyBundle(bundle);
    return store.containsSession(addr);
  }

  /// Encrypt [plaintext] for [peerUserId]. Returns the typed payload
  /// (`<type>:<base64>`) to place inside the e2e envelope, or null if no
  /// session could be established (peer not E2E-capable).
  Future<String?> encrypt(String peerUserId, String plaintext) async {
    final store = await _ensureStore();
    if (store == null) return null;
    if (!await ensureSession(peerUserId)) return null;
    final addr = _addr(peerUserId);
    final cipher = SessionCipher(store, store, store, store, addr);
    final ct = await cipher.encrypt(
      Uint8List.fromList(utf8.encode(plaintext)),
    );
    return '${ct.getType()}:${base64Encode(ct.serialize())}';
  }

  /// Decrypt a typed payload (`<type>:<base64>`, envelope already stripped)
  /// from [peerUserId]. Returns plaintext, or null on failure.
  Future<String?> decrypt(String peerUserId, String typedPayload) async {
    final store = await _ensureStore();
    if (store == null) return null;
    final sep = typedPayload.indexOf(':');
    if (sep <= 0) return null;
    final type = int.tryParse(typedPayload.substring(0, sep));
    final bytes = Uint8List.fromList(
      base64Decode(typedPayload.substring(sep + 1)),
    );
    final cipher = SessionCipher(store, store, store, store, _addr(peerUserId));
    final Uint8List plain;
    if (type == CiphertextMessage.prekeyType) {
      // First inbound message — also establishes the session on our side.
      plain = await cipher.decrypt(PreKeySignalMessage(bytes));
    } else {
      plain = await cipher.decryptFromSignal(SignalMessage.fromSerialized(bytes));
    }
    return utf8.decode(plain);
  }

  PreKeyBundle? _bundleFromJson(Map<String, dynamic> d) {
    try {
      final spk = (d['signedPreKey'] as Map).cast<String, dynamic>();
      final otk = d['oneTimePreKey'] == null
          ? null
          : (d['oneTimePreKey'] as Map).cast<String, dynamic>();
      Uint8List b64(dynamic s) => Uint8List.fromList(base64Decode(s as String));
      return PreKeyBundle(
        (d['registrationId'] as num).toInt(),
        (d['deviceId'] as num?)?.toInt() ?? 1,
        otk == null ? null : (otk['keyId'] as num).toInt(),
        otk == null ? null : Curve.decodePoint(b64(otk['publicKey']), 0),
        (spk['keyId'] as num).toInt(),
        Curve.decodePoint(b64(spk['publicKey']), 0),
        b64(spk['signature']),
        IdentityKey.fromBytes(b64(d['identityPublicKey']), 0),
      );
    } catch (_) {
      return null;
    }
  }
}
