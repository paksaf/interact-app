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

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../utils/phone_normalize.dart';

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
const _kEmailKey = 'interact.auth.email';
const _kNameKey  = 'interact.auth.name';
const _kOtpIdKey = 'interact.auth.lastOtpId';   // transient, between request+verify
/// Set true by requestOtp when the server just minted a brand-new account for
/// this identifier (open self-registration). verifyOtp reads it so the UI can
/// route a first-time user into profile setup, then clears it.
const _kJustCreatedKey = 'interact.auth.justCreated';
/// (#147) Caller's LOCAL Sahulat uuid — populated from the server's
/// `me: { id }` envelope on the first chat thread / messages response.
/// Used as the myId comparator for Message.isMine. Sticks across app
/// restarts so bubble alignment is correct on cold start.
const _kLocalUserIdKey = 'interact.auth.localUserId';

/// Result of [AuthService.requestOtp] — never treat a decoy as “code sent”.
class OtpSendResult {
  const OtpSendResult({
    required this.otpId,
    required this.channel,
    required this.delivered,
    this.provider,
    this.normalizedPhone,
    this.message,
    this.created = false,
  });

  final String otpId;
  final String channel;
  final bool delivered;
  final String? provider;
  final String? normalizedPhone;
  final String? message;

  /// True when this OTP just created a brand-new account (open registration).
  final bool created;

  /// Server returned an enumeration-resistant decoy (no active INTERACT user).
  bool get isDecoy => otpId.startsWith('decoy_');

  /// Safe to show the 6-digit entry UI.
  bool get canVerify => delivered && !isDecoy;
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

class AuthService {
  // 2026-06-11 fleet fix (interact_pro TV lesson): bare FlutterSecureStorage
  // uses the legacy RSA-keystore backend which silently drops values on
  // some devices (TVs especially). Always use EncryptedSharedPreferences.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── Local token helpers ──────────────────────────────────────────
  /// True only when a REAL, UN-EXPIRED JWT is stored. The old check merely
  /// tested non-empty, so two states masqueraded as "signed in" while every
  /// backend call 401'd: (a) the legacy fallback that stored a bare user.id
  /// (not a JWT), and (b) an expired token (interactpak mints 8-hour JWTs).
  /// Both surfaced as "create room failed" + "could not load chats" with no
  /// way back to sign-in. We now decode the JWT and check its `exp` claim so
  /// a stale/garbage token routes the user to re-sign-in instead.
  Future<bool> hasValidToken() async {
    final t = await _storage.read(key: _kTokenKey);
    if (t == null || t.isEmpty) return false;
    return _jwtStillValid(t);
  }

  /// True when a JWT is stored but past `exp` (or nearly). Used so the gate
  /// can prefill phone on sign-in — `adb install -r` does **not** wipe
  /// storage; the usual "login again after update" is this 8h TTL.
  Future<bool> hasExpiredToken() async {
    final t = await _storage.read(key: _kTokenKey);
    if (t == null || t.isEmpty) return false;
    return !_jwtStillValid(t) && t.split('.').length == 3;
  }

  /// Decode a JWT payload and confirm it's well-formed + not past `exp`.
  /// Returns false for non-JWT strings (e.g. the legacy user.id fallback).
  bool _jwtStillValid(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return false; // not a JWT
    try {
      final payloadJson = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is int) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
        // 30s skew so a token about to expire isn't treated as valid.
        if (DateTime.now().isAfter(expiry.subtract(const Duration(seconds: 30)))) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false; // malformed → treat as signed-out
    }
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

  /// Step 1 — request a one-time code on [channel]: sms | whatsapp | email.
  ///
  /// Always inspect [OtpSendResult.canVerify]. The server returns
  /// `delivered:false` + a `decoy_*` otpId when no active INTERACT user
  /// matches (enumeration-resistant) — that is NOT a successful send.
  Future<OtpSendResult> requestOtp(
    String identifier, {
    String channel = 'sms',
  }) async {
    final isEmail = channel == 'email';
    late final String payloadId;
    String? normalizedPhone;

    if (isEmail) {
      final email = identifier.trim().toLowerCase();
      if (!isPlausibleEmail(email)) {
        throw Exception('Enter a valid email (e.g. you@example.com).');
      }
      payloadId = email;
    } else {
      final e164 = normalizeInteractPhone(identifier);
      if (e164 == null) {
        throw Exception(
          'Enter a valid phone with country code '
          '(Pakistan: 03XXXXXXXXX or +923XXXXXXXXX).',
        );
      }
      payloadId = e164;
      normalizedPhone = e164;
    }

    final res = await _postJson(
      '$_kBase/api/auth/phone-login/send',
      {
        if (isEmail) 'email': payloadId else 'phone': payloadId,
        'channel': channel,
        // Open self-registration: any new phone / email / WhatsApp number
        // gets an account created on first OTP (no pre-existing account
        // needed). The server returns created:true for a brand-new user.
        'signup': true,
      },
    );

    Map<String, dynamic> body = {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      /* non-JSON error page */
    }

    if (res.statusCode == 429) {
      throw Exception(
        (body['message'] as String?) ??
            'Too many codes. Wait a minute, then try again.',
      );
    }
    if (res.statusCode >= 400) {
      final msg = body['message'] as String?;
      throw Exception(
        msg ?? 'OTP send failed (${res.statusCode}). Try another channel.',
      );
    }

    final otpId = body['otpId'] as String? ?? '';
    if (otpId.isEmpty) {
      throw Exception('OTP send returned no otpId — try again.');
    }

    final delivered = body['delivered'] == true;
    final isDecoy = otpId.startsWith('decoy_');
    final result = OtpSendResult(
      otpId: otpId,
      channel: (body['channel'] as String?) ?? channel,
      delivered: delivered && !isDecoy,
      provider: body['provider'] as String?,
      normalizedPhone: normalizedPhone,
      message: body['message'] as String?,
      created: body['created'] == true,
    );

    if (result.canVerify) {
      await _storage.write(key: _kOtpIdKey, value: otpId);
      if (normalizedPhone != null) {
        await _storage.write(key: _kPhoneKey, value: normalizedPhone);
      }
      if (isEmail) {
        await _storage.write(key: _kEmailKey, value: payloadId);
      }
      // Remember new-account status so verifyOtp can route to profile setup.
      await _storage.write(
        key: _kJustCreatedKey,
        value: result.created ? '1' : '0',
      );
    } else {
      // Do not keep a decoy id — verify would only produce a useless error.
      await _storage.delete(key: _kOtpIdKey);
    }
    return result;
  }

  /// Step 2 — verify the 6-digit code and mint the session cookie + bearer.
  Future<void> verifyOtp(String code) async {
    final trimmed = code.trim();
    if (!RegExp(r'^\d{4,8}$').hasMatch(trimmed)) {
      throw Exception('Enter the 6-digit code from SMS / WhatsApp / email.');
    }
    final otpId = await _storage.read(key: _kOtpIdKey);
    if (otpId == null || otpId.isEmpty) {
      throw Exception('No OTP in progress — tap Send code first.');
    }
    if (otpId.startsWith('decoy_')) {
      // With open registration this is rare (only a create race/conflict).
      throw Exception(
        "Couldn't start your registration just now — request a new code, "
        'or try another channel (SMS / WhatsApp / email).',
      );
    }
    final res = await _postJson(
      '$_kBase/api/auth/phone-login/verify',
      {'otpId': otpId, 'code': trimmed},
    );

    Map<String, dynamic> body = {};
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {/* ignore */}

    if (res.statusCode >= 400) {
      throw Exception(
        (body['message'] as String?) ??
            'Invalid or expired code. Request a new one.',
      );
    }
    final user = body['user'] as Map<String, dynamic>?;

    String? token = body['token'] as String?;

    if (token == null || token.isEmpty) {
      final setCookieHeader = res.headers['set-cookie'] ?? '';
      final match =
          RegExp(r'interact-session=([^;,\s]+)').firstMatch(setCookieHeader);
      if (match != null) {
        token = match.group(1);
      }
    }

    if (token == null || token.isEmpty) {
      final id = user?['id'] as String? ?? '';
      debugPrint('⚠️ phone-login/verify returned no token in body OR cookie — '
          'storing user.id (UI will look signed in but every backend '
          'call will 401).');
      await _storage.write(key: _kTokenKey, value: id);
    } else {
      await _storage.write(key: _kTokenKey, value: token);
    }
    final name = user?['name'] as String? ?? 'INTERACT user';
    final phone = user?['phone'] as String? ?? '';
    final email = user?['email'] as String? ?? '';
    if (phone.isNotEmpty) await _storage.write(key: _kPhoneKey, value: phone);
    await _storage.write(key: _kNameKey, value: name);
    // A phone signup gets a synthetic <digits>@talk.interactpak.com email —
    // don't surface that as the user's real address.
    if (email.isNotEmpty && !email.endsWith('@talk.interactpak.com')) {
      await _storage.write(key: _kEmailKey, value: email);
    }
    await _storage.delete(key: _kOtpIdKey);
  }

  /// The signed-in user's email, if any (never the synthetic phone placeholder).
  Future<String?> email() => _storage.read(key: _kEmailKey);

  /// Read AND clear the "this account was just created" flag set by requestOtp.
  /// The sign-in screen calls this right after verifyOtp to decide whether to
  /// send a first-time user into profile setup. Returns false once consumed.
  Future<bool> consumeJustCreated() async {
    final v = await _storage.read(key: _kJustCreatedKey);
    if (v == '1') {
      await _storage.delete(key: _kJustCreatedKey);
      return true;
    }
    return false;
  }

  /// Update the locally-cached display name after a profile edit so the Me tab
  /// and message alignment reflect the change without a re-login.
  Future<void> setLocalName(String name) =>
      _storage.write(key: _kNameKey, value: name);

  Future<void> signOut() async {
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kPhoneKey);
    await _storage.delete(key: _kEmailKey);
    await _storage.delete(key: _kNameKey);
    await _storage.delete(key: _kOtpIdKey);
    await _storage.delete(key: _kJustCreatedKey);
  }
}
