// SPDX-License-Identifier: AGPL-3.0
//
// Signal-protocol E2E — Phase 1.5 (libsignal_protocol_dart integrated, gated).

import 'auth_service.dart';
import 'e2e/e2e_envelope.dart';
import 'e2e/e2e_identity_manager.dart';
import 'e2e/e2e_prekey_api.dart';
import 'e2e/e2e_prekey_upload.dart';

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
      return;
    }
    await E2eIdentityManager.instance.install();
    _status = E2eStatus.identityReady;
    await _syncPreKeys();
  }

  Future<void> _syncPreKeys() async {
    await E2ePreKeyUpload(E2ePreKeyApi(AuthService.instance)).syncIfNeeded();
  }

  Future<String> decryptInbound(String body) async {
    if (!isE2eEnvelope(body)) return body;
    // Session decrypt is not implemented yet (Phase 1.5). NEVER show the raw
    // ciphertext envelope to the user — surface a placeholder until the
    // Signal cipher lands.
    return '🔒 Encrypted message — update the app to read it.';
  }

  Future<String> encryptOutbound(String plaintext,
      {required String peerUserId}) async {
    if (!shouldEncryptOutbound) return plaintext;
    // FAIL CLOSED. shouldEncryptOutbound is true but the Signal cipher is not
    // implemented yet (Phase 1.5). Returning plaintext here would silently
    // send an "encrypted" message in the clear — the classic downgrade
    // breach. Refuse to send rather than lie about encryption. (Unreachable
    // today: the compile gate + status==active guard keep this false; this
    // guards whoever wires session-active before the cipher exists.)
    throw StateError(
        'E2E is enabled but the Signal cipher is not implemented (Phase 1.5). '
        'Refusing to send plaintext under an encrypted flag.');
  }
}
