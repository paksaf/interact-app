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
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'notification_service.dart';

const _kBase = 'https://qurbanisahulat.com';
const _kAppId = 'com.interactpak.interact_talk';

/// True when this FCM data message is an incoming-call ring.
/// Accepts legacy `talk_call` for older servers still mid-deploy.
bool _isCallRing(Map<String, dynamic> data) {
  final t = data['type']?.toString();
  return t == 'call_ring' || t == 'talk_call';
}

String _callIdOf(Map<String, dynamic> data) =>
    (data['callId'] ?? data['threadId'] ?? '').toString();

/// Runs in a background isolate when the app is backgrounded or killed.
/// Must be a top-level / static function annotated for AOT entry.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  if (_isCallRing(message.data)) {
    await NotificationService.instance.init();
    await NotificationService.instance.showIncomingCall(
      callId: _callIdOf(message.data),
      callerName: message.data['callerName'] ?? 'INTERACT caller',
      mode: message.data['mode'] ?? 'video',
    );
  }
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  bool _wired = false;

  /// Call once after sign-in (a valid JWT must exist to register the token).
  Future<void> init(AuthService auth) async {
    if (_wired) {
      // Token can still change; ensure the latest is registered.
      final t = await FirebaseMessaging.instance.getToken();
      if (t != null) await _register(t, auth);
      return;
    }
    _wired = true;

    await FirebaseMessaging.instance.requestPermission();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _register(token, auth);
    FirebaseMessaging.instance.onTokenRefresh
        .listen((t) => _register(t, auth));

    // Foreground delivery — ring immediately.
    FirebaseMessaging.onMessage.listen((m) {
      if (_isCallRing(m.data)) {
        NotificationService.instance.showIncomingCall(
          callId: _callIdOf(m.data),
          callerName: m.data['callerName'] ?? 'INTERACT caller',
          mode: m.data['mode'] ?? 'video',
        );
      }
    });
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
      await http.post(
        Uri.parse('$_kBase/api/v1/me/push-tokens'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwt',
        },
        body: jsonEncode({
          'platform': 'android',
          'token': token,
          'appId': _kAppId,
        }),
      );
    } catch (_) {/* retry on next refresh/boot */}
  }
}
