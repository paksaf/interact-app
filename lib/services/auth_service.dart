// SPDX-License-Identifier: AGPL-3.0
//
// Auth service — passwordless SMS-OTP via the interactpak-nextjs
// /api/auth/phone-login/* routes (shipped 2026-05-21). Two-step flow:
//
//   1. requestOtp(phone) → server lookup by phone → SMS via capcom6
//      gateway → returns otpId
//   2. verifyOtp(otpId, code) → server validates code → mints JWT signed
//      with INTERACT_AUTH_SECRET (shared across *.interactpak.com) →
//      sets session cookie. We also store the bearer locally so the
//      Flutter HTTP client can authenticate subsequent /api/v1/talk/*
//      calls.
//
// Per memory `sso_interactpak`: the JWT verifies on every INTERACT app
// (Pro, Sahulat, FleetOps, this app, etc.) without a separate sign-in.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

const _kBase = 'https://www.interactpak.com'; // apex redirects to www

/// Network timeout for auth calls. Without this the Send-code / Verify
/// buttons spin forever when the device can't reach the server — the exact
/// "stuck after entering number" symptom seen on Android TV (flaky DNS).
/// 25s is generous: the send route does a DB lookup + SMS dispatch.
const _kAuthTimeout = Duration(seconds: 25);

/// POST helper that always terminates: applies [_kAuthTimeout] and maps
/// connection failures to a clear, TV-friendly message instead of a hang.
Future<http.Response> _postJson(String url, Map<String, dynamic> body) async {
  try {
    return await http
        .post(
          Uri.parse(url),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_kAuthTimeout);
  } on TimeoutException {
    throw Exception(
        'Couldn’t reach INTERACT (timed out). Check this device’s internet '
        'and DNS, then try again.');
  } on SocketException {
    throw Exception(
        'No connection to INTERACT. Check Wi-Fi/DNS on this device '
        '(try DNS 8.8.8.8), then try again.');
  } on http.ClientException catch (e) {
    throw Exception('Network error: ${e.message}. Check this device’s connection.');
  }
}
const _kTokenKey = 'interact.auth.token';
const _kPhoneKey = 'interact.auth.phone';
const _kNameKey  = 'interact.auth.name';
const _kOtpIdKey = 'interact.auth.lastOtpId';   // transient, between request+verify
/// (#147) Caller's LOCAL Sahulat uuid — populated from the server's
/// `me: { id }` envelope on the first chat thread / messages response.
/// Used as the myId comparator for Message.isMine. Sticks across app
/// restarts so bubble alignment is correct on cold start.
const _kLocalUserIdKey = 'interact.auth.localUserId';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

class AuthService {
  // 2026-06-11 fleet fix (interact_pro TV lesson): bare FlutterSecureStorage
  // uses the legacy RSA-keystore backend which silently drops values on
  // some devices (TVs especially). Always use EncryptedSharedPreferences.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Local token helpers ──────────────────────────────────────────
  Future<bool> hasValidToken() async {
    final t = await _storage.read(key: _kTokenKey);
    return t != null && t.isNotEmpty;
  }

  Future<String?> token()       => _storage.read(key: _kTokenKey);
  Future<String?> phone()       => _storage.read(key: _kPhoneKey);
  Future<String?> displayName() => _storage.read(key: _kNameKey);
  /// (#147) Local Sahulat uuid for the signed-in user — written by
  /// chat_api after every response that carries `me: { id }`. Read at
  /// Message.fromJson time to compute isMine correctly.
  Future<String?> localUserId() => _storage.read(key: _kLocalUserIdKey);
  Future<void> setLocalUserId(String id) =>
      _storage.write(key: _kLocalUserIdKey, value: id);

  /// Step 1 — request a one-time SMS code by phone number.
  ///
  /// Returns the server-issued `otpId` (a UUID-like string) that must
  /// be passed back to [verifyOtp]. The server fans out the SMS through
  /// the Comms Hub dispatcher (capcom6 → Baileys WA → Twilio fallback);
  /// the client doesn't pick the channel.
  ///
  /// Enumeration-resistant: if `phone` isn't a registered user the
  /// server still returns a 200 with a decoy otpId. Treat the response
  /// as opaque.
  Future<String> requestOtp(String phone) async {
    final res = await _postJson(
      '$_kBase/api/auth/phone-login/send',
      {'phone': phone},
    );
    if (res.statusCode >= 400) {
      throw Exception('OTP send failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final otpId = body['otpId'] as String?;
    if (otpId == null || otpId.isEmpty) {
      throw Exception('OTP send returned no otpId');
    }
    await _storage.write(key: _kOtpIdKey, value: otpId);
    return otpId;
  }

  /// Step 2 — verify the 6-digit code that arrived via SMS and mint
  /// the session cookie + local bearer.
  ///
  /// Uses the otpId saved by [requestOtp]. After this returns
  /// successfully, [hasValidToken] is true and the user profile fields
  /// (phone, displayName) are populated.
  Future<void> verifyOtp(String code) async {
    final otpId = await _storage.read(key: _kOtpIdKey);
    if (otpId == null || otpId.isEmpty) {
      throw Exception('No OTP request in flight — call requestOtp() first');
    }
    final res = await _postJson(
      '$_kBase/api/auth/phone-login/verify',
      {'otpId': otpId, 'code': code},
    );
    if (res.statusCode >= 400) {
      throw Exception('OTP verify failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final user = body['user'] as Map<String, dynamic>?;

    // PRIMARY: body['token'] — set by the patched server (2026-05-21+)
    // FALLBACK: parse `interact-session=` from Set-Cookie header — works
    //   even on servers running the OLD code path that only sets the
    //   cookie. We can READ Set-Cookie off a single response even though
    //   Flutter's http package can't PERSIST it across requests.
    String? token = body['token'] as String?;

    if (token == null || token.isEmpty) {
      final setCookieHeader = res.headers['set-cookie'] ?? '';
      // Set-Cookie may be a single line ("interact-session=abc.def.ghi; Path=/; ...")
      // or multiple cookies joined by commas. Parse out interact-session.
      final match = RegExp(r'interact-session=([^;,\s]+)').firstMatch(setCookieHeader);
      if (match != null) {
        token = match.group(1);
      }
    }

    if (token == null || token.isEmpty) {
      // Last-resort fallback — store user.id so the UI shows signed-in
      // but warn loudly that backend calls will 401.
      final id = user?['id'] as String? ?? '';
      // ignore: avoid_print
      print('⚠️ phone-login/verify returned no token in body OR cookie — '
          'storing user.id (UI will look signed in but every backend '
          'call will 401).');
      await _storage.write(key: _kTokenKey, value: id);
    } else {
      await _storage.write(key: _kTokenKey, value: token);
    }
    final name = user?['name'] as String? ?? 'INTERACT user';
    final phone = user?['phone'] as String? ?? '';
    await _storage.write(key: _kPhoneKey, value: phone);
    await _storage.write(key: _kNameKey,  value: name);
    await _storage.delete(key: _kOtpIdKey); // consumed
  }

  Future<void> signOut() async {
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kPhoneKey);
    await _storage.delete(key: _kNameKey);
    await _storage.delete(key: _kOtpIdKey);
  }
}
