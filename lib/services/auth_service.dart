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
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../utils/phone_normalize.dart';
import 'api_base.dart';

const _kBase = 'https://www.interactpak.com'; // apex redirects to www

/// Talk backend that mints + verifies the offline-durable session (refresh
/// token + short access token). Same host the chat/talk APIs hit; the
/// interactpak-minted JWT verifies here via shared INTERACT_AUTH_SECRET.
String get _kSahulatBase => ApiBase.current;

/// Network timeout for auth calls. Without this the Send-code / Verify
/// buttons spin forever when the device can't reach the server — the exact
/// "stuck after entering number" symptom seen on Android TV (flaky DNS).
/// 25s is generous: the send route does a DB lookup + SMS dispatch.
const _kAuthTimeout = Duration(seconds: 25);

/// POST helper that always terminates: applies [_kAuthTimeout] and maps
/// connection failures to a clear, TV-friendly message instead of a hang.
Future<http.Response> _postJson(String url, Map<String, dynamic> body) async {
  // The auth host (www.interactpak.com) has NO multi-host failover like the
  // chat path, and this environment's resolver (HS8145C5 / ISP) flaps with
  // errno 7/8 "no address" that usually clears within a second or two. A
  // single-shot request turned that flap into a hard block where BOTH SMS and
  // WhatsApp login failed at once — and a DNS failure surfaces as a
  // ClientException ("ClientException with SocketException: Failed host
  // lookup"), which the old code threw IMMEDIATELY with no retry. Retry
  // transient network failures a few times before surfacing the error so a
  // flap self-heals. (A code that never arrives after a 200 is server-side
  // delivery — capcom6 SMS gateway / Baileys WhatsApp — not fixable here.)
  const maxAttempts = 3;
  const backoff = Duration(milliseconds: 1200);
  Object? lastErr;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await http
          .post(
            Uri.parse(url),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(_kAuthTimeout);
    } on HandshakeException catch (e) {
      // TLS / device-clock issues are not transient — fail fast with guidance.
      throw Exception(
          'Secure connection to INTERACT failed (${e.message}). '
          'Check the date/time on this device, then try again.');
    } catch (e) {
      final transient = e is TimeoutException || ApiBase.isDnsOrOffline(e);
      if (!transient) {
        if (e is http.ClientException) {
          throw Exception(
              'Network error: ${e.message}. Check this device’s connection.');
        }
        rethrow;
      }
      lastErr = e;
      // Nudge the chat-host failover probe too (helps the session calls that
      // DO use ApiBase; harmless for the auth host). Then wait out the flap.
      if (e is! TimeoutException) unawaited(ApiBase.checkAndMaybeSwitch());
      if (attempt < maxAttempts) {
        await Future<void>.delayed(backoff);
        continue;
      }
    }
  }
  // Retries exhausted — map to a clear, channel-aware message.
  if (lastErr is TimeoutException) {
    throw Exception(
        'Couldn’t reach INTERACT (timed out) after several tries. Check Wi‑Fi '
        'or Cellular, then try again. Email login also works if SMS/WhatsApp '
        'is slow.');
  }
  final detail = lastErr is SocketException
      ? (lastErr.osError?.message ?? lastErr.message).trim()
      : (lastErr?.toString() ?? '');
  throw Exception(
      'No connection to INTERACT'
      '${detail.isNotEmpty ? ' ($detail)' : ''}.\n\n'
      '• Turn on Wi‑Fi or Cellular Data for Talk\n'
      '• If Wi‑Fi has no internet, switch to mobile data\n'
      '• Then try WhatsApp again, or use Email');
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

/// Long-lived, revocable refresh credential (offline-durable auth). Stored in
/// Keystore-backed secure storage, NEVER in plain prefs. Redeemed at
/// /api/v1/talk/auth/refresh for a fresh short access token.
const _kRefreshKey = 'interact.auth.refreshToken';
/// ISO8601 of the refresh token's server-side expiry (informational only —
/// the server is the source of truth; we never self-expire a refresh token).
const _kRefreshExpKey = 'interact.auth.refreshExp';
/// Stable per-install device id so the server keeps ONE refresh credential per
/// device (re-login rotates in place) and can revoke this device individually.
const _kDeviceIdKey = 'interact.auth.deviceId';

/// Outcome of an attempt to resume a session on cold-start / after an access
/// token is no longer valid. Drives the [_Gate] routing decision.
enum RefreshOutcome {
  /// A valid access token is available (either it was still valid, or a
  /// refresh succeeded). Continue into the app.
  refreshed,

  /// The device could not reach the server (offline / timeout / 5xx). The
  /// user WAS logged in and has a refresh token — keep them signed in, show
  /// cached data, and retry on reconnect. NEVER log out here.
  offlineKeep,

  /// The server DEFINITIVELY rejected the refresh token (revoked / unknown /
  /// expired). This is the only non-user-initiated path that ends a session.
  revoked,

  /// No durable credential exists (fresh install, or a pre-migration user
  /// whose legacy token already expired offline). Fall back to sign-in.
  noCredential,
}

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

/// Shared singleton so the go_router revoke-redirect and the Riverpod-scoped
/// consumers observe the SAME [AuthService.sessionRevoked] notifier. The
/// service holds no per-scope state (just secure storage + the notifier), so a
/// singleton is safe and avoids duplicate notifiers drifting out of sync.
final authServiceProvider = Provider<AuthService>((ref) => AuthService.instance);

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  // 2026-06-11 fleet fix (interact_pro TV lesson): bare FlutterSecureStorage
  // uses the legacy RSA-keystore backend which silently drops values on
  // some devices (TVs especially). Always use EncryptedSharedPreferences.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Flips true ONLY when the server explicitly rejects the refresh token
  /// (REFRESH_REVOKED) while online, or the user signs out. The router listens
  /// and routes to /sign-in?revoked=1. Never flips on a network error.
  final ValueNotifier<bool> sessionRevoked = ValueNotifier<bool>(false);

  /// Single-flight guard so concurrent API calls that all hit a near-expiry
  /// token trigger exactly ONE refresh network round-trip.
  Future<void>? _refreshInFlight;

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

  /// THE bearer choke-point. Every API call in the app obtains its token
  /// here (`talk_api`/`chat_api`/`talk_auth_api` `_headers()`, uploads, etc.),
  /// so this is where PROACTIVE silent refresh lives: when the stored access
  /// token is within the skew window of expiry (or already expired) AND a
  /// refresh token exists, renew it silently before returning. Fail-soft — on
  /// any network failure the (possibly stale) stored token is returned
  /// unchanged so the call proceeds; a resulting 401 does NOT log the user out
  /// (the refresh manager owns session-ending, not individual call sites).
  Future<String?> token() async {
    final t = await _storage.read(key: _kTokenKey);
    if (t == null || t.isEmpty) return t;
    if (_jwtNeedsRefresh(t) && await _hasRefreshToken()) {
      await _ensureFreshAccess();
      return (await _storage.read(key: _kTokenKey)) ?? t;
    }
    return t;
  }

  /// Raw stored access token WITHOUT triggering a refresh (used internally by
  /// the refresh/establish paths to avoid recursion).
  Future<String?> _rawToken() => _storage.read(key: _kTokenKey);

  Future<String?> refreshToken() => _storage.read(key: _kRefreshKey);
  Future<bool> _hasRefreshToken() async {
    final r = await _storage.read(key: _kRefreshKey);
    return r != null && r.isNotEmpty;
  }

  /// Stable per-install device id (created once, reused forever). Lets the
  /// server keep a single refresh credential per device + revoke it remotely.
  Future<String> deviceId() async {
    var id = await _storage.read(key: _kDeviceIdKey);
    if (id == null || id.isEmpty) {
      // Random 128-bit hex — no plugin needed; secure_storage persists it.
      final r = Random.secure();
      id = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
      await _storage.write(key: _kDeviceIdKey, value: id);
    }
    return id;
  }

  /// True when [token] is not a JWT, is already expired, or is within the
  /// refresh skew window (5 min) of expiry — i.e. should be renewed now.
  bool _jwtNeedsRefresh(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return true; // legacy/non-JWT → refresh if possible
    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
      ) as Map<String, dynamic>;
      final exp = payload['exp'];
      if (exp is! int) return false; // no exp claim → treat as long-lived
      final expiry = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      return DateTime.now()
          .isAfter(expiry.subtract(const Duration(minutes: 5)));
    } catch (_) {
      return true;
    }
  }

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
    } else {
      await _storage.delete(key: _kEmailKey);
    }
    await _storage.delete(key: _kOtpIdKey);
    // Reconcile with Sahulat (phone-first admin merge) so Me shows the
    // canonical number/email for this account, not a stale mix.
    await refreshCredentialsFromServer();
    // Immediately establish the durable refresh credential so this session is
    // offline-durable from the first launch (swaps to a short Sahulat access
    // token + stores the 365-day refresh token). Best-effort — a failure here
    // just defers establishment to the next cold start.
    await establishRefreshTokenIfNeeded();
  }

  /// The signed-in user's email, if any (never the synthetic phone placeholder).
  Future<String?> email() => _storage.read(key: _kEmailKey);

  /// Pull canonical phone / email / name / local uuid from the server and
  /// overwrite local secure-storage. Prevents Me tab showing a stale phone
  /// from a previous login mixed with a different JWT identity.
  Future<bool> refreshCredentialsFromServer() async {
    final t = await token();
    if (t == null || t.isEmpty || !_jwtStillValid(t)) return false;
    try {
      // Sahulat/Talk is the source of truth for phone↔admin identity.
      final res = await http
          .get(
            Uri.parse('${ApiBase.current}/api/v1/auth/me'),
            headers: {
              'Authorization': 'Bearer $t',
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode >= 400) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      final id = data['id'] as String?;
      final name = (data['fullName'] as String?)?.trim();
      final phone = (data['phone'] as String?)?.trim();
      final email = (data['email'] as String?)?.trim();
      if (id != null && id.isNotEmpty) {
        await setLocalUserId(id);
      }
      if (name != null && name.isNotEmpty) {
        await _storage.write(key: _kNameKey, value: name);
      }
      // Always sync phone: clear local cache when server has none so we never
      // show another account's number beside this JWT.
      if (phone != null && phone.isNotEmpty) {
        await _storage.write(key: _kPhoneKey, value: phone);
      } else {
        await _storage.delete(key: _kPhoneKey);
      }
      if (email != null &&
          email.isNotEmpty &&
          !email.endsWith('@talk.interactpak.com') &&
          !email.endsWith('@sso.interactpak.local')) {
        await _storage.write(key: _kEmailKey, value: email);
      } else if (email == null || email.isEmpty) {
        await _storage.delete(key: _kEmailKey);
      }
      return true;
    } catch (e) {
      debugPrint('refreshCredentialsFromServer failed: $e');
      return false;
    }
  }

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

  // ── Offline-durable session (refresh manager) ────────────────────────
  //
  // Design invariant: the ONLY events that end a session are (a) the server
  // EXPLICITLY rejecting the refresh token while online (REFRESH_REVOKED), or
  // (b) the user tapping Sign out. A network error, a timeout, a 5xx, or an
  // expired access token while offline must KEEP the user signed in.

  /// Establish a refresh token from the CURRENT valid access token, if we
  /// don't already have one. This is the backward-compat migration: an existing
  /// user still holding a valid legacy 8h token gets a durable credential on
  /// their next online launch, so they never hit the old hard-logout again.
  /// Best-effort + idempotent — safe to call on every cold start.
  Future<bool> establishRefreshTokenIfNeeded() async {
    if (await _hasRefreshToken()) return true;
    final t = await _rawToken();
    if (t == null || t.isEmpty || !_jwtStillValid(t)) return false;
    try {
      return await ApiBase.runWithFailover(() async {
        final res = await http
            .post(
              Uri.parse('$_kSahulatBase/api/v1/talk/auth/session'),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $t',
              },
              body: jsonEncode({
                'deviceId': await deviceId(),
                'deviceLabel': Platform.isAndroid ? 'Android' : 'iOS',
                'appId': 'com.interactpak.interact_talk',
              }),
            )
            .timeout(const Duration(seconds: 12));
        if (res.statusCode >= 400) return false;
        final data = _dataOf(res.body);
        await _storeSessionFrom(data);
        return (data['refreshToken'] as String?)?.isNotEmpty ?? false;
      });
    } catch (e) {
      debugPrint('establishRefreshTokenIfNeeded failed: $e');
      return false; // fail-soft — retried on the next launch
    }
  }

  /// Cold-start / access-invalid resume. Decides whether to enter the app,
  /// stay signed-in offline, or route to sign-in. See [RefreshOutcome].
  Future<RefreshOutcome> attemptSilentResume() async {
    final t = await _rawToken();
    final tokenValid = t != null && t.isNotEmpty && _jwtStillValid(t);
    if (tokenValid) return RefreshOutcome.refreshed;
    if (!await _hasRefreshToken()) return RefreshOutcome.noCredential;
    return _doRefresh();
  }

  /// Proactive/near-expiry renewal used by [token()]. Swallows the outcome
  /// (the choke-point stays fail-soft); session-ending is signalled via
  /// [sessionRevoked]. Single-flight so concurrent calls share one round-trip.
  Future<void> _ensureFreshAccess() {
    return _refreshInFlight ??= _doRefresh().whenComplete(() {
      _refreshInFlight = null;
    });
  }

  /// The single refresh network round-trip. Redeems the refresh token for a
  /// fresh access token. Maps the three outcomes precisely:
  ///   • 200            → tokens updated → [RefreshOutcome.refreshed]
  ///   • 401 REFRESH_REVOKED → definitive → clear + notify → [revoked]
  ///   • network/timeout/5xx/other → keep session → [offlineKeep]
  Future<RefreshOutcome> _doRefresh() async {
    final r = await _storage.read(key: _kRefreshKey);
    if (r == null || r.isEmpty) return RefreshOutcome.noCredential;
    try {
      return await ApiBase.runWithFailover(() async {
        final res = await http
            .post(
              Uri.parse('$_kSahulatBase/api/v1/talk/auth/refresh'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'refreshToken': r}),
            )
            .timeout(const Duration(seconds: 12));

        if (res.statusCode == 200) {
          try {
            await _storeSessionFrom(_dataOf(res.body));
            return RefreshOutcome.refreshed;
          } catch (_) {
            return RefreshOutcome.offlineKeep;
          }
        }

        // DEFINITIVE rejection ONLY on the distinct revoke code. A 400/5xx/etc is
        // transient (or a deploy skew) — keep the session and retry later.
        if (res.statusCode == 401 &&
            _errorCodeOf(res.body) == 'REFRESH_REVOKED') {
          await _clearForRevoke();
          sessionRevoked.value = true;
          return RefreshOutcome.revoked;
        }
        return RefreshOutcome.offlineKeep;
      });
    } on TimeoutException {
      return RefreshOutcome.offlineKeep;
    } on SocketException {
      return RefreshOutcome.offlineKeep;
    } on http.ClientException {
      return RefreshOutcome.offlineKeep;
    } catch (_) {
      return RefreshOutcome.offlineKeep;
    }
  }

  /// Persist the tokens from a /session or /refresh success envelope. The
  /// access token is swapped atomically; the refresh token (when present —
  /// only /session returns it) and its expiry are stored too.
  Future<void> _storeSessionFrom(Map<String, dynamic> data) async {
    final access = data['accessToken'] as String?;
    if (access != null && access.isNotEmpty) {
      await _storage.write(key: _kTokenKey, value: access);
    }
    final refresh = data['refreshToken'] as String?;
    if (refresh != null && refresh.isNotEmpty) {
      await _storage.write(key: _kRefreshKey, value: refresh);
    }
    final refreshExp = data['refreshExpiresAt'] as String?;
    if (refreshExp != null && refreshExp.isNotEmpty) {
      await _storage.write(key: _kRefreshExpKey, value: refreshExp);
    }
    final user = data['user'];
    if (user is Map<String, dynamic>) {
      final id = user['userId'] as String?;
      if (id != null && id.isNotEmpty) await setLocalUserId(id);
    }
  }

  /// Unwrap the Sahulat `ok(payload)` envelope → payload map.
  Map<String, dynamic> _dataOf(String responseBody) {
    final body = jsonDecode(responseBody) as Map<String, dynamic>;
    final data = body['data'];
    return data is Map<String, dynamic> ? data : body;
  }

  /// Read `error.code` from an `err()` envelope, if present.
  String? _errorCodeOf(String responseBody) {
    try {
      final body = jsonDecode(responseBody) as Map<String, dynamic>;
      final e = body['error'];
      if (e is Map<String, dynamic>) return e['code'] as String?;
    } catch (_) {}
    return null;
  }

  /// Clear session on a server revoke. Keeps the phone (for sign-in prefill)
  /// and the deviceId (stable identity), drops everything auth-bearing.
  Future<void> _clearForRevoke() async {
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kRefreshKey);
    await _storage.delete(key: _kRefreshExpKey);
    await _storage.delete(key: _kLocalUserIdKey);
    await _storage.delete(key: _kOtpIdKey);
    await _storage.delete(key: _kJustCreatedKey);
  }

  Future<void> signOut() async {
    // Best-effort server revoke so a lost/stolen device is cut off remotely.
    // Never let this block or fail the local sign-out.
    try {
      final r = await _storage.read(key: _kRefreshKey);
      final dev = await _storage.read(key: _kDeviceIdKey);
      if ((r != null && r.isNotEmpty) || (dev != null && dev.isNotEmpty)) {
        await http
            .post(
              Uri.parse('$_kSahulatBase/api/v1/talk/auth/logout'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                if (r != null && r.isNotEmpty) 'refreshToken': r,
                if (dev != null && dev.isNotEmpty) 'deviceId': dev,
              }),
            )
            .timeout(const Duration(seconds: 6));
      }
    } catch (_) {/* offline sign-out still proceeds */}
    await _storage.delete(key: _kTokenKey);
    await _storage.delete(key: _kRefreshKey);
    await _storage.delete(key: _kRefreshExpKey);
    await _storage.delete(key: _kPhoneKey);
    await _storage.delete(key: _kEmailKey);
    await _storage.delete(key: _kNameKey);
    await _storage.delete(key: _kOtpIdKey);
    await _storage.delete(key: _kJustCreatedKey);
    await _storage.delete(key: _kLocalUserIdKey);
    // Keep _kDeviceIdKey — stable per-install identity for future logins.
  }
}
