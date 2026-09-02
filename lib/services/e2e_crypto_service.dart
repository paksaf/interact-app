// SPDX-License-Identifier: AGPL-3.0
//
// Signal-protocol E2E — Phase 1.5 (libsignal_protocol_dart integrated, gated).

import 'auth_service.dart';
import 'e2e/e2e_envelope.dart';
import 'e2e/e2e_identity_manager.dart';
import 'e2e/e2e_prekey_api.dart';
import 'e2e/e2e_prekey_upload.dart';
import 'e2e/e2e_session_service.dart';

enum E2eStatus {
  /// libsignal not integrated — server sees message bodies on cloud path.
  notAvailable,

  /// Identity generated locally; pre-key upload / sessions pending.
  identityReady,

  /// 1:1 session established with peer.
  active,

  /// Peer has no pre-keys on server yet.
  pendingPeer,
}

/// Compile-time gate — off in production builds until field-proven.
const _kE2eEnabled = bool.fromEnvironment('INTERACT_E2E', defaultValue: false);

class E2eCryptoService {
  E2eCryptoService._();
  static final E2eCryptoService instance = E2eCryptoService._();

  E2eStatus _status = E2eStatus.notAvailable;
  E2eStatus get status => _status;

  String get userLabel => switch (_status) {
        E2eStatus.notAvailable => 'planned (libsignal Phase 1.5)',
        E2eStatus.identityReady => 'identity ready — sessions pending',
        E2eStatus.active => 'on',
        E2eStatus.pendingPeer => 'waiting for peer pre-keys',
      };

  /// Whether outbound text should be wrapped in Signal ciphertext.
  bool get shouldEncryptOutbound =>
      _kE2eEnabled && _status == E2eStatus.active;

  /// Whether inbound body is ciphertext needing decrypt.
  bool isCiphertext(String body) => isE2eEnvelope(body);

  /// Call once after sign-in. Safe to repeat.
  Future<void> bootstrap() async {
    if (!_kE2eEnabled) {
      _status = E2eStatus.notAvailable;
      return;
    }
    if (await E2eIdentityManager.instance.isInstalled) {
      _status = E2eStatus.identityReady;
      await _syncPreKeys();
      _status = E2eStatus.active; // E2E-capable; per-peer sessions build lazily
      return;
    }
    await E2eIdentityManager.instance.install();
    _status = E2eStatus.identityReady;
    await _syncPreKeys();
    _status = E2eStatus.active;
  }

  Future<void> _syncPreKeys() async {
    await E2ePreKeyUpload(E2ePreKeyApi(AuthService.instance)).syncIfNeeded();
  }

  Future<String> decryptInbound(String body,
      {required String peerUserId}) async {
    final payload = unwrapE2eCiphertext(body);
    if (payload == null) return body; // not an E2E envelope — plaintext
    try {
      final plain = await E2eSessionService.instance.decrypt(peerUserId, payload);
      if (plain != null) return plain;
    } catch (_) {/* fall through to placeholder */}
    // NEVER show the raw ciphertext envelope to the user.
    return '🔒 Encrypted message — could not be decrypted on this device.';
  }

  Future<String> encryptOutbound(String plaintext,
      {required String peerUserId}) async {
    if (!shouldEncryptOutbound) return plaintext;
    final payload =
        await E2eSessionService.instance.encrypt(peerUserId, plaintext);
    if (payload == null) {
      // No session could be built (peer has no pre-keys / not E2E-ready).
      // FAIL CLOSED — never send plaintext under an encrypted flag.
      throw StateError(
          'E2E is on but no session with the peer (not encrypted-ready). '
          'Refusing to send plaintext.');
    }
    return wrapE2eCiphertext(payload);
  }
}
