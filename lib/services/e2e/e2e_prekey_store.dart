// SPDX-License-Identifier: AGPL-3.0
//
// Persist libsignal pre-keys in secure storage (Phase 1.5).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

/// Serialized PreKeyRecord + SignedPreKeyRecord for local SessionBuilder.
class E2ePreKeyStore {
  E2ePreKeyStore._();
  static final E2ePreKeyStore instance = E2ePreKeyStore._();

  static const _preKeysKey = 'talk.e2e.prekeys.v1';
  static const _signedKey = 'talk.e2e.signed_prekey.v1';

  final _storage = const FlutterSecureStorage();

  Future<void> save({
    required List<PreKeyRecord> preKeys,
    required SignedPreKeyRecord signedPreKey,
  }) async {
    final encoded = preKeys.map((p) => base64Encode(p.serialize())).toList();
    await _storage.write(key: _preKeysKey, value: jsonEncode(encoded));
    await _storage.write(
      key: _signedKey,
      value: base64Encode(signedPreKey.serialize()),
    );
  }

  Future<List<PreKeyRecord>> loadPreKeys() async {
    final raw = await _storage.read(key: _preKeysKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<String>()
          .map((b64) => PreKeyRecord.fromBuffer(Uint8List.fromList(base64Decode(b64))))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<SignedPreKeyRecord?> loadSignedPreKey() async {
    final raw = await _storage.read(key: _signedKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return SignedPreKeyRecord.fromSerialized(Uint8List.fromList(base64Decode(raw)));
    } catch (_) {
      return null;
    }
  }

  Future<bool> get hasStoredPreKeys async =>
      (await loadPreKeys()).isNotEmpty && (await loadSignedPreKey()) != null;
}
