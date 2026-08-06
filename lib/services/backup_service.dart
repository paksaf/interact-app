// SPDX-License-Identifier: AGPL-3.0
//
// BackupService — INTERACT #115 encrypted chat backup + cross-device restore.
//
// The server already restores chats on a new device at sign-in (threads
// + Hub messages are server-side). This feature adds a USER-CONTROLLED,
// passphrase-encrypted ARCHIVE kept in the user's own VPS space:
//
//   Backup:  GET  /api/v1/talk/backup/export   → plaintext bundle (own data)
//            → encrypt(bundle, passphrase)      → AES-GCM, PBKDF2 key
//            → PUT  /api/v1/talk/backup { blob, meta }
//
//   Restore: GET  /api/v1/talk/backup           → { blob, meta }
//            → decrypt(blob, passphrase, meta)   → bundle (threads + msgs)
//
// The passphrase never leaves the device; the server stores only the
// opaque ciphertext + the non-secret decrypt envelope (salt/iv/counts).
// Forget the passphrase → the backup is unrecoverable (by design).
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

const _kBase = 'https://qurbanisahulat.com';

// PBKDF2 work factor. 120k HMAC-SHA256 iterations is a sane 2026 mobile
// default — a few hundred ms on device, painful to brute-force. Recorded
// in `meta.iterations` so a future bump stays backward-compatible on
// restore (old backups decrypt with their own recorded count).
const _kPbkdf2Iterations = 120000;
const _kBackupFormatVersion = 1;

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.read(authServiceProvider));
});

/// Server-side status of the caller's backup (without downloading it).
class BackupStatus {
  const BackupStatus({
    required this.exists,
    this.updatedAt,
    this.sizeBytes = 0,
    this.threadCount,
    this.messageCount,
  });
  final bool exists;
  final DateTime? updatedAt;
  final int sizeBytes;
  final int? threadCount;
  final int? messageCount;
}

/// Result of a completed backup upload.
class BackupResult {
  const BackupResult({
    required this.threadCount,
    required this.messageCount,
    required this.sizeBytes,
  });
  final int threadCount;
  final int messageCount;
  final int sizeBytes;
}

/// Decrypted archive returned by [restore].
class RestoreResult {
  const RestoreResult({
    required this.exportedAt,
    required this.threadCount,
    required this.messageCount,
    required this.bundle,
  });
  final String exportedAt;
  final int threadCount;
  final int messageCount;

  /// The raw decrypted export bundle: { threads: [...], messages: {id:[...]} }.
  final Map<String, dynamic> bundle;
}

/// Thrown when the passphrase is wrong (AES-GCM MAC check fails) or the
/// stored blob is corrupt. The UI shows a friendly "wrong passphrase"
/// message rather than a raw crypto exception.
class BackupDecryptError implements Exception {
  const BackupDecryptError([this.message = 'Could not decrypt backup']);
  final String message;
  @override
  String toString() => message;
}

class BackupService {
  BackupService(this._auth);
  final AuthService _auth;

  final _algorithm = AesGcm.with256bits();
  final _rand = Random.secure();

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  Uint8List _randomBytes(int n) {
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = _rand.nextInt(256);
    }
    return b;
  }

  Map<String, dynamic> _dataOf(http.Response res) {
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = body['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  // ── PBKDF2 → AES-GCM ────────────────────────────────────────────────

  Future<SecretKey> _deriveKey(
    String passphrase,
    List<int> salt, {
    int iterations = _kPbkdf2Iterations,
  }) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  // ── Status ──────────────────────────────────────────────────────────

  Future<BackupStatus> status() async {
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/backup'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Backup status failed (${res.statusCode})');
    }
    final data = _dataOf(res);
    if (data['exists'] != true) return const BackupStatus(exists: false);
    final meta = (data['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    return BackupStatus(
      exists: true,
      sizeBytes: (data['sizeBytes'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.tryParse(data['updatedAt']?.toString() ?? ''),
      threadCount: (meta['threadCount'] as num?)?.toInt(),
      messageCount: (meta['messageCount'] as num?)?.toInt(),
    );
  }

  // ── Backup ──────────────────────────────────────────────────────────

  Future<BackupResult> backupNow(String passphrase) async {
    if (passphrase.trim().length < 6) {
      throw Exception('Passphrase must be at least 6 characters');
    }

    // 1. Export plaintext bundle (own data, server-assembled).
    final exportRes = await http.get(
      Uri.parse('$_kBase/api/v1/talk/backup/export'),
      headers: await _headers(),
    );
    if (exportRes.statusCode != 200) {
      throw Exception('Export failed (${exportRes.statusCode})');
    }
    final bundle = _dataOf(exportRes);
    final threadCount = (bundle['threadCount'] as num?)?.toInt() ?? 0;
    final messageCount = (bundle['messageCount'] as num?)?.toInt() ?? 0;

    // 2. Encrypt on device.
    final plaintext = utf8.encode(jsonEncode(bundle));
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _deriveKey(passphrase, salt);
    final box = await _algorithm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );
    // blob = cipherText || mac  (mac is 16 bytes, appended so a single
    // base64 string round-trips the whole authenticated ciphertext).
    final combined = Uint8List(box.cipherText.length + box.mac.bytes.length)
      ..setAll(0, box.cipherText)
      ..setAll(box.cipherText.length, box.mac.bytes);
    final blob = base64Encode(combined);

    final meta = <String, dynamic>{
      'v': _kBackupFormatVersion,
      'alg': 'AES-GCM-256',
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _kPbkdf2Iterations,
      'salt': base64Encode(salt),
      'iv': base64Encode(nonce),
      'macLen': box.mac.bytes.length,
      'threadCount': threadCount,
      'messageCount': messageCount,
      'exportedAt': bundle['exportedAt'],
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };

    // 3. Upload opaque blob.
    final putRes = await http.put(
      Uri.parse('$_kBase/api/v1/talk/backup'),
      headers: await _headers(),
      body: jsonEncode({'blob': blob, 'meta': meta}),
    );
    if (putRes.statusCode != 200) {
      throw Exception('Upload failed (${putRes.statusCode})');
    }
    final stored = _dataOf(putRes);
    return BackupResult(
      threadCount: threadCount,
      messageCount: messageCount,
      sizeBytes: (stored['sizeBytes'] as num?)?.toInt() ?? blob.length,
    );
  }

  // ── Restore ─────────────────────────────────────────────────────────

  Future<RestoreResult> restore(String passphrase) async {
    final res = await http.get(
      Uri.parse('$_kBase/api/v1/talk/backup'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Fetch backup failed (${res.statusCode})');
    }
    final data = _dataOf(res);
    if (data['exists'] != true) {
      throw Exception('No backup found on the server');
    }
    final meta = (data['meta'] as Map).cast<String, dynamic>();
    final blob = data['blob'] as String;

    final salt = base64Decode(meta['salt'] as String);
    final nonce = base64Decode(meta['iv'] as String);
    final iterations =
        (meta['iterations'] as num?)?.toInt() ?? _kPbkdf2Iterations;
    final macLen = (meta['macLen'] as num?)?.toInt() ?? 16;

    final combined = base64Decode(blob);
    if (combined.length < macLen) throw const BackupDecryptError();
    final cipherText = combined.sublist(0, combined.length - macLen);
    final mac = Mac(combined.sublist(combined.length - macLen));

    final key = await _deriveKey(passphrase, salt, iterations: iterations);
    List<int> clear;
    try {
      clear = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: key,
      );
    } catch (_) {
      // AES-GCM MAC failure → almost always a wrong passphrase.
      throw const BackupDecryptError('Wrong passphrase, or the backup is corrupt');
    }

    final bundle = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
    return RestoreResult(
      exportedAt: bundle['exportedAt']?.toString() ?? '',
      threadCount: (bundle['threadCount'] as num?)?.toInt() ?? 0,
      messageCount: (bundle['messageCount'] as num?)?.toInt() ?? 0,
      bundle: bundle,
    );
  }

  Future<void> deleteBackup() async {
    final res = await http.delete(
      Uri.parse('$_kBase/api/v1/talk/backup'),
      headers: await _headers(),
    );
    if (res.statusCode != 200) {
      throw Exception('Delete failed (${res.statusCode})');
    }
  }
}
