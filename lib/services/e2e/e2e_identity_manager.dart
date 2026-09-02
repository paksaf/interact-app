// SPDX-License-Identifier: AGPL-3.0
//
// Local Signal identity install — persisted in secure storage (Phase 1.5).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class E2eIdentityRecord {
  const E2eIdentityRecord({
    required this.registrationId,
    required this.identityPublicKeyBase64,
    required this.deviceId,
    required this.installedAt,
  });

  final int registrationId;
  final String identityPublicKeyBase64;
  final int deviceId;
  final DateTime installedAt;

  Map<String, dynamic> toJson() => {
        'registrationId': registrationId,
        'identityPublicKeyBase64': identityPublicKeyBase64,
        'deviceId': deviceId,
        'installedAt': installedAt.toIso8601String(),
      };

  factory E2eIdentityRecord.fromJson(Map<String, dynamic> j) =>
      E2eIdentityRecord(
        registrationId: (j['registrationId'] as num?)?.toInt() ?? 0,
        identityPublicKeyBase64: (j['identityPublicKeyBase64'] as String?) ?? '',
        deviceId: (j['deviceId'] as num?)?.toInt() ?? 1,
        installedAt: DateTime.tryParse(j['installedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// Generates and stores a libsignal identity on first run.
class E2eIdentityManager {
  E2eIdentityManager._();
  static final E2eIdentityManager instance = E2eIdentityManager._();

  static const _metaKey = 'talk.e2e.identity.meta.v1';
  static const _identityPairKey = 'talk.e2e.identity.pair.v1';

  final _storage = const FlutterSecureStorage();

  E2eIdentityRecord? _cached;

  Future<E2eIdentityRecord?> loadRecord() async {
    if (_cached != null) return _cached;
    final raw = await _storage.read(key: _metaKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      _cached = E2eIdentityRecord.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return _cached;
    } catch (_) {
      return null;
    }
  }

  Future<bool> get isInstalled async => (await loadRecord()) != null;

  /// Create identity + pre-keys locally. Upload via [E2ePreKeyApi] separately.
  Future<E2eIdentityRecord> install({int preKeyCount = 50}) async {
    final existing = await loadRecord();
    if (existing != null) return existing;

    final identityKeyPair = generateIdentityKeyPair();
    final registrationId = generateRegistrationId(false);
    const deviceId = 1;

    // ⚠️ SCAFFOLD GAP (Phase 1.5): these generate valid pre-keys but their
    // return values are DISCARDED — there is no PreKeyStore persistence yet.
    // Before wiring E2E on, persist these (and load them for
    // PreKeyBundle upload + inbound PreKeySignalMessage decrypt), or sessions
    // cannot be built. Left as-is deliberately for the off-by-default scaffold.
    generatePreKeys(0, preKeyCount);
    generateSignedPreKey(identityKeyPair, 0);

    await _storage.write(
      key: _identityPairKey,
      value: base64Encode(identityKeyPair.serialize()),
    );

    final record = E2eIdentityRecord(
      registrationId: registrationId,
      identityPublicKeyBase64: base64Encode(
        identityKeyPair.getPublicKey().serialize(),
      ),
      deviceId: deviceId,
      installedAt: DateTime.now(),
    );
    await _storage.write(key: _metaKey, value: jsonEncode(record.toJson()));
    _cached = record;
    return record;
  }

  Future<IdentityKeyPair?> loadIdentityKeyPair() async {
    final b64 = await _storage.read(key: _identityPairKey);
    if (b64 == null || b64.isEmpty) return null;
    try {
      return IdentityKeyPair.fromSerialized(Uint8List.fromList(base64Decode(b64)));
    } catch (_) {
      return null;
    }
  }
}
