// SPDX-License-Identifier: AGPL-3.0
//
// Persist sahl_mesh Ed25519 identity across restarts — one pubkey per install.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sahl_mesh/sahl_mesh.dart';

class MeshIdentityStore {
  MeshIdentityStore._();
  static final MeshIdentityStore instance = MeshIdentityStore._();

  static const _seedKey = 'talk_mesh_identity_seed_v1';
  static const _storage = FlutterSecureStorage();

  MeshIdentity? _cached;

  /// Load persisted identity or generate + store a new one.
  Future<MeshIdentity> loadOrCreate() async {
    if (_cached != null) return _cached!;
    try {
      final raw = await _storage.read(key: _seedKey);
      if (raw != null && raw.isNotEmpty) {
        final seed = base64Decode(raw);
        if (seed.length == 32) {
          _cached = await MeshIdentity.fromSeed(seed);
          return _cached!;
        }
      }
    } catch (e) {
      debugPrint('[mesh-identity-store] load failed: $e');
    }
    final id = await MeshIdentity.generate();
    try {
      final seed = await id.exportSeed();
      await _storage.write(key: _seedKey, value: base64Encode(seed));
    } catch (e) {
      debugPrint('[mesh-identity-store] persist failed: $e');
    }
    _cached = id;
    return id;
  }

  Future<String> publicKeyHex() async {
    final id = await loadOrCreate();
    return id.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> clearForTests() async {
    _cached = null;
    await _storage.delete(key: _seedKey);
  }
}
