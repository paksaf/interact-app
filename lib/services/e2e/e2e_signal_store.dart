// SPDX-License-Identifier: AGPL-3.0
//
// Persistent libsignal store (Phase 1.5). One object implementing all four
// libsignal stores (Session / PreKey / SignedPreKey / IdentityKey), backed by
// flutter_secure_storage so double-ratchet SESSION state survives app
// restarts — otherwise a relaunch loses the ratchet and messages become
// undecryptable. Seeded from E2eIdentityManager (identity + registrationId)
// and E2ePreKeyStore (the pre-keys generated + uploaded at install()).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import 'e2e_identity_manager.dart';
import 'e2e_prekey_store.dart';

class E2ePersistentSignalStore
    implements SessionStore, PreKeyStore, SignedPreKeyStore, IdentityKeyStore {
  E2ePersistentSignalStore(this._identityKeyPair, this._registrationId);

  final IdentityKeyPair _identityKeyPair;
  final int _registrationId;
  final FlutterSecureStorage _s = const FlutterSecureStorage();

  static const _sess = 'e2e.sess.'; // + <name>.<deviceId>
  static const _tid = 'e2e.tid.'; //  + <name>.<deviceId>  (trusted identity)
  static const _pk = 'e2e.pk.'; //    + <id>
  static const _spk = 'e2e.spk.'; //  + <id>

  String _addr(String prefix, SignalProtocolAddress a) =>
      '$prefix${a.getName()}.${a.getDeviceId()}';
  Uint8List _b64d(String s) => Uint8List.fromList(base64Decode(s));

  /// Open the store for the installed identity, seeding pre-keys once.
  /// Returns null if no identity is installed yet.
  static Future<E2ePersistentSignalStore?> open() async {
    final pair = await E2eIdentityManager.instance.loadIdentityKeyPair();
    final rec = await E2eIdentityManager.instance.loadRecord();
    if (pair == null || rec == null) return null;
    final store = E2ePersistentSignalStore(pair, rec.registrationId);
    await store._seedFromInstallIfEmpty();
    return store;
  }

  Future<void> _seedFromInstallIfEmpty() async {
    final all = await _s.readAll();
    final hasPk = all.keys.any((k) => k.startsWith(_pk));
    if (!hasPk) {
      for (final pk in await E2ePreKeyStore.instance.loadPreKeys()) {
        await storePreKey(pk.id, pk);
      }
    }
    final signed = await E2ePreKeyStore.instance.loadSignedPreKey();
    if (signed != null && !await containsSignedPreKey(signed.id)) {
      await storeSignedPreKey(signed.id, signed);
    }
  }

  // ── IdentityKeyStore ──────────────────────────────────────────────────────
  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async => _identityKeyPair;

  @override
  Future<int> getLocalRegistrationId() async => _registrationId;

  @override
  Future<bool> saveIdentity(
      SignalProtocolAddress address, IdentityKey? identityKey) async {
    if (identityKey == null) return false;
    final key = _addr(_tid, address);
    final existing = await _s.read(key: key);
    final incoming = base64Encode(identityKey.serialize());
    if (existing == incoming) return false;
    await _s.write(key: key, value: incoming);
    return true; // stored a new/changed identity
  }

  @override
  Future<bool> isTrustedIdentity(SignalProtocolAddress address,
      IdentityKey? identityKey, Direction? direction) async {
    if (identityKey == null) return false;
    final existing = await _s.read(key: _addr(_tid, address));
    if (existing == null) return true; // TOFU — trust on first use
    return existing == base64Encode(identityKey.serialize());
  }

  @override
  Future<IdentityKey?> getIdentity(SignalProtocolAddress address) async {
    final b64 = await _s.read(key: _addr(_tid, address));
    if (b64 == null) return null;
    return IdentityKey.fromBytes(_b64d(b64), 0);
  }

  // ── SessionStore ──────────────────────────────────────────────────────────
  @override
  Future<SessionRecord> loadSession(SignalProtocolAddress address) async {
    final b64 = await _s.read(key: _addr(_sess, address));
    if (b64 == null) return SessionRecord();
    try {
      return SessionRecord.fromSerialized(_b64d(b64));
    } catch (_) {
      return SessionRecord();
    }
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) async {
    final all = await _s.readAll();
    final prefix = '$_sess$name.';
    final out = <int>[];
    for (final k in all.keys) {
      if (k.startsWith(prefix)) {
        final dev = int.tryParse(k.substring(prefix.length));
        if (dev != null && dev != 1) out.add(dev);
      }
    }
    return out;
  }

  @override
  Future<void> storeSession(
      SignalProtocolAddress address, SessionRecord record) async {
    await _s.write(
        key: _addr(_sess, address), value: base64Encode(record.serialize()));
  }

  @override
  Future<bool> containsSession(SignalProtocolAddress address) async =>
      (await _s.read(key: _addr(_sess, address))) != null;

  @override
  Future<void> deleteSession(SignalProtocolAddress address) async =>
      _s.delete(key: _addr(_sess, address));

  @override
  Future<void> deleteAllSessions(String name) async {
    final all = await _s.readAll();
    final prefix = '$_sess$name.';
    for (final k in all.keys) {
      if (k.startsWith(prefix)) await _s.delete(key: k);
    }
  }

  // ── PreKeyStore ───────────────────────────────────────────────────────────
  @override
  Future<PreKeyRecord> loadPreKey(int preKeyId) async {
    final b64 = await _s.read(key: '$_pk$preKeyId');
    if (b64 == null) {
      throw InvalidKeyIdException('No pre-key $preKeyId');
    }
    return PreKeyRecord.fromBuffer(_b64d(b64));
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) async =>
      _s.write(key: '$_pk$preKeyId', value: base64Encode(record.serialize()));

  @override
  Future<bool> containsPreKey(int preKeyId) async =>
      (await _s.read(key: '$_pk$preKeyId')) != null;

  @override
  Future<void> removePreKey(int preKeyId) async =>
      _s.delete(key: '$_pk$preKeyId');

  // ── SignedPreKeyStore ─────────────────────────────────────────────────────
  @override
  Future<SignedPreKeyRecord> loadSignedPreKey(int signedPreKeyId) async {
    final b64 = await _s.read(key: '$_spk$signedPreKeyId');
    if (b64 == null) {
      throw InvalidKeyIdException('No signed pre-key $signedPreKeyId');
    }
    return SignedPreKeyRecord.fromSerialized(_b64d(b64));
  }

  @override
  Future<List<SignedPreKeyRecord>> loadSignedPreKeys() async {
    final all = await _s.readAll();
    final out = <SignedPreKeyRecord>[];
    for (final e in all.entries) {
      if (e.key.startsWith(_spk)) {
        out.add(SignedPreKeyRecord.fromSerialized(_b64d(e.value)));
      }
    }
    return out;
  }

  @override
  Future<void> storeSignedPreKey(
          int signedPreKeyId, SignedPreKeyRecord record) async =>
      _s.write(
          key: '$_spk$signedPreKeyId',
          value: base64Encode(record.serialize()));

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async =>
      (await _s.read(key: '$_spk$signedPreKeyId')) != null;

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) async =>
      _s.delete(key: '$_spk$signedPreKeyId');
}
