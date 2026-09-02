// SPDX-License-Identifier: AGPL-3.0
//
// PushService — FCM registration + background/killed-app call ring.
//
// The Talk backend (qurbanisahulat /api/v1/talk/calls/ring) sends an FCM data
// message {type:"call_ring", callId|threadId, callerName, mode} to the callee's
// registered token; this service turns that into a full-screen ringing
// notification even when the app is killed. Foreground/recent-background ring
// already works via call_signaling.dart's poll — this closes the killed-app gap.
//
// Reuses the fleet's interact-lifestyle Firebase project. Requires
// android/app/google-services.json to build (see docs/BACKGROUND_RING_AND_CAPTIONS).
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'callkit_service.dart';
import 'notification_service.dart';
import 'api_base.dart';

String get _kBase => ApiBase.current;
const _kAppId = 'com.interactpak.interact_talk';

/// True when this FCM data message is an incoming-call ring.
/// Accepts legacy `talk_call` for older servers still mid-deploy.
bool _isCallRing(Map<String, dynamic> data) {
  final t = data['type']?.toString();
  return t == 'call_ring' || t == 'talk_call';
}

/// True when the caller cancelled the ring before the callee answered — sent
/// by /talk/calls/respond (action=cancel) as a data-only, high-priority push.
/// The in-app IncomingCallScreen already self-dismisses via its 3s isRinging
/// poll, but the NATIVE CallKit ring (raised from the background isolate for a
/// locked/backgrounded phone) never polls — without this push it rang the full
/// 45s TTL after the caller hung up (observed on device 2026-08-06).
bool _isCallCancel(Map<String, dynamic> data) =>
    data['type']?.toString() == 'call_cancel';

/// Stop every ring surface for a cancelled invite: native CallKit, the
/// fallback full-screen local notification, and (via return value) the caller
/// can also clear the in-app signaling notifier. Safe to call repeatedly.
Future<void> _dismissRingSurfaces(String callId) async {
  await CallKitService.endCall(callId);
  // Defensive: a stale entry under a different id (e.g. inviteId vs threadId
  // drift between server versions) would otherwise keep ringing forever.
  await CallKitService.endAllCalls();
  await NotificationService.instance.cancelIncomingCall(callId);
}

/// Cross-app login OTP delivered into Talk (Menu → Login codes).
bool _isAuthCode(Map<String, dynamic> data) {
  final t = data['type']?.toString();
  return t == 'talk_auth_code' || t == 'auth_code' || t == 'login_otp';
}

String _callIdOf(Map<String, dynamic> data) =>
    (data['callId'] ?? data['threadId'] ?? '').toString();

/// Runs in a background isolate when the app is backgrounded or killed.
/// Must be a top-level / static function annotated for AOT entry.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (_isAuthCode(message.data)) {
    final code = message.data['code']?.toString() ?? '';
    final app = message.data['appName'] ?? message.data['appId'] ?? 'App';
    if (code.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: code));
    }
    await NotificationService.instance.init();
    await NotificationService.instance.showMessage(
      title: '$app login code',
      body: code.isEmpty
          ? 'Open Talk → Menu → Login codes'
          : 'Your code is $code — also copied. Paste in the other app.',
      threadId: 'auth:${message.data['challengeId'] ?? ''}',
    );
    return;
  }
  if (_isCallCancel(message.data)) {
    await _dismissRingSurfaces(_callIdOf(message.data));
    return;
  }
  if (_isCallRing(message.data)) {
    final callId = _callIdOf(message.data);
    final name = message.data['callerName'] ?? 'INTERACT caller';
    final mode = message.data['mode'] ?? 'video';
    final avatar = message.data['callerAvatar']?.toString();
    // PRIMARY: native, over-lock-screen incoming call (works from this bg
    // isolate — flutter_callkit_incoming supports FCM bg handlers). FALLBACK:
    // the original full-screen-intent local notification if CallKit throws
    // (e.g. plugin/init failure), so the ring is never silently lost.
    try {
      await CallKitService.showIncoming(
        id: callId,
        callerName: name,
        avatar: avatar,
        mode: mode,
        inviteId: message.data['inviteId']?.toString() ??
            message.data['invite_id']?.toString(),
      );
    } catch (_) {
      await NotificationService.instance.init();
      await NotificationService.instance.showIncomingCall(
        callId: callId,
        callerName: name,
        mode: mode,
      );
    }
  }
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _wired = false;

  /// Invoked when the user TAPS a call-ring push (warm background or cold
  /// start). Wired from the app layer to force an immediate incoming-call
  /// poll so the IncomingCallScreen appears at once. Fail-soft if unset.
  void Function()? _onCallTap;

  /// Foreground-only liveness check: "is this call still ringing server-side?"
  /// Wired to call_signaling.isRinging so a push that arrives AFTER the caller
  /// hung up / the invite expired becomes a "missed — tap to call back" instead
  /// of a phantom ring. Fail-soft (treat null as still-ringing).
  Future<bool> Function(String callId)? _isCallRinging;

  /// Foreground cancel hook — lets the app layer clear call_signaling's
  /// `incoming` notifier (dropping IncomingCallScreen at once) when a
  /// call_cancel push arrives, instead of waiting for the next 3s poll.
  /// Fail-soft: the poll still catches it if unset.
  void Function(String callId, String? inviteId)? _onCallCancel;

  /// Call once after sign-in (a valid JWT must exist to register the token).
  /// [onCallTap] routes a tapped call-ring push straight to the ring screen.
  /// [isRinging] enables the foreground missed-call downgrade.
  Future<void> init(
    AuthService auth, {
    void Function()? onCallTap,
    Future<bool> Function(String callId)? isRinging,
    void Function(String callId, String? inviteId)? onCallCancel,
  }) async {
    if (onCallTap != null) _onCallTap = onCallTap;
    if (isRinging != null) _isCallRinging = isRinging;
    if (onCallCancel != null) _onCallCancel = onCallCancel;
    if (_wired) {
      // Token can still change; ensure the latest is registered.
      final t = await FirebaseMessaging.instance.getToken();
      if (t != null) await _register(t, auth);
      return;
    }
    _wired = true;

    try {
      await FirebaseMessaging.instance.requestPermission();
      // Background handler is registered in main() before runApp (FCM requirement).

      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _register(token, auth);
      FirebaseMessaging.instance.onTokenRefresh
          .listen((t) => _register(t, auth));

      // Foreground delivery. While the app is OPEN/resumed, the in-app poll
    // (call_signaling → IncomingCallScreen) is the live-ring surface — do NOT
    // raise CallKit OR a max-importance / fullScreenIntent local notification.
    // On Samsung those heads-ups push/steal focus from the Calls dashboard
    // ("notification bumping main dashboard"). Only fire system UI when the
    // app is backgrounded/paused, or for quiet login-code toasts.
    FirebaseMessaging.onMessage.listen((m) async {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      final foreground = lifecycle == null ||
          lifecycle == AppLifecycleState.resumed ||
          lifecycle == AppLifecycleState.inactive;

      if (_isAuthCode(m.data)) {
        final app = m.data['appName'] ?? m.data['appId'] ?? 'App';
        final code = m.data['code'] ?? '';
        // Same-phone UX: copy so Aura/Maps can Paste without app-switching gymnastics.
        if (code.isNotEmpty) {
          await Clipboard.setData(ClipboardData(text: code));
        }
        // Quiet tray item (no heads-up) so the dashboard doesn't jump.
        NotificationService.instance.showMessage(
          title: '$app login code',
          body: code.isEmpty
              ? 'Open Talk → Me → Login codes'
              : 'Your code is $code — also copied. Paste in the other app.',
          threadId: 'auth:${m.data['challengeId'] ?? ''}',
          quiet: true,
        );
        return;
      }
      if (_isCallCancel(m.data)) {
        final callId = _callIdOf(m.data);
        await _dismissRingSurfaces(callId);
        _onCallCancel?.call(callId, m.data['inviteId']?.toString());
        return;
      }
      if (!_isCallRing(m.data)) return;
      final callId = _callIdOf(m.data);
      final name = m.data['callerName'] ?? 'INTERACT caller';
      final mode = m.data['mode'] ?? 'video';
      final ringing =
          _isCallRinging == null ? true : await _isCallRinging!(callId);
      if (!ringing) {
        NotificationService.instance
            .showMissedCall(callId: callId, callerName: name, mode: mode);
        return;
      }
      if (foreground) {
        // In-app IncomingCallScreen owns the ring while Talk is visible.
        return;
      }
      NotificationService.instance
          .showIncomingCall(callId: callId, callerName: name, mode: mode);
    });

    // Warm tap — app was backgrounded and the user tapped the ring push.
    FirebaseMessaging.onMessageOpenedApp.listen((m) {
      if (_isCallRing(m.data)) _onCallTap?.call();
    });

    // Cold tap — app was killed and launched by tapping the ring push.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null && _isCallRing(initial.data)) _onCallTap?.call();
    } catch (e) {
      // iOS ships without GoogleService-Info.plist until Firebase is provisioned;
      // degrade to poll-only ring — must not break AppShell startup.
      debugPrint('PushService init skipped (Firebase not configured?): $e');
    }
  }

  /// Remove this device's token on logout so the user stops getting rings.
  Future<void> unregister(AuthService auth) async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      final jwt = await auth.token();
      if (token == null || jwt == null) return;
      await http.delete(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwt',
        },
        body: jsonEncode({'token': token}),
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> _register(String token, AuthService auth) async {
    final jwt = await auth.token();
    if (jwt == null) return; // not signed in yet
    try {
      final res = await http.post(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwt',
        },
        body: jsonEncode({
          'platform': Platform.isIOS ? 'ios' : 'android',
          'token': token,
          'appId': _kAppId,
        }),
      );
      debugPrint('FCM token register → ${res.statusCode} '
          '(…${token.length > 8 ? token.substring(token.length - 8) : token})');
    } catch (e) {
      debugPrint('FCM token register failed: $e');
    }
  }
}
