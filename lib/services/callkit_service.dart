// SPDX-License-Identifier: AGPL-3.0
//
// CallKitService — NATIVE system incoming-call screen (WhatsApp-style).
//
// Wraps flutter_callkit_incoming (3.1.x). On Android it shows a full-screen,
// over-the-lock-screen incoming-call UI (custom notification) even when the
// app is KILLED — this is the surface push_service.dart fires from the FCM
// background isolate on a `call_ring` data message. On iOS it uses the system
// CallKit UI (VoIP/PushKit setup required separately — Android is the shipping
// target).
//
// DESIGN SPLIT (see push_service.dart): the in-app poll ring
// (call_signaling → IncomingCallScreen) stays the FOREGROUND surface; CallKit
// is the killed / locked / background surface. push_service ONLY invokes
// CallKit from the FCM *background* handler, so there is no double-ring with
// the in-app screen while the app is open.
//
// API NOTE (3.1.3): `onEvent` emits a SEALED CallEvent hierarchy
// (CallEventActionCallAccept / …Decline / …Ended / …Timeout / …Callback) — we
// branch on those confirmed types. The call `id` (== our threadId) + `extra`
// live on the event's payload; to avoid coupling to the exact field name
// across plugin patch versions we read them defensively via `dynamic`
// (`.data` or `.body`, object OR map). `activeCalls()` returns CallKitParams.
import 'dart:async';

import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';

/// Recovered call metadata for an accepted / called-back call.
typedef _CallInfo = ({String mode, String? callerName, String? inviteId});

class CallKitService {
  CallKitService._();
  static final CallKitService instance = CallKitService._();

  StreamSubscription<CallEvent?>? _sub;

  /// Show the native incoming-call screen. [id] MUST be the threadId (the room
  /// anchor) so accept can join `/room?threadId=<id>`. Safe to call from the
  /// FCM background isolate. Throws on plugin failure so the caller can fall
  /// back to a local-notification ring.
  static Future<void> showIncoming({
    required String id,
    required String callerName,
    String? avatar,
    required String mode,
    String? inviteId,
  }) async {
    final isVideo = mode == 'video';
    final name =
        callerName.trim().isEmpty ? 'INTERACT caller' : callerName.trim();
    final params = CallKitParams(
      id: id,
      nameCaller: name,
      appName: 'INTERACT',
      avatar:
          (avatar != null && avatar.trim().isNotEmpty) ? avatar.trim() : null,
      handle: name,
      type: isVideo ? 1 : 0,
      duration: 45000,
      missedCallNotification: const NotificationParams(
        showNotification: true,
        isShowCallback: true,
        subtitle: 'Missed call',
        callbackText: 'Call back',
      ),
      extra: <String, dynamic>{
        'threadId': id,
        'mode': mode,
        'callerName': callerName,
        if (avatar != null) 'callerAvatar': avatar,
        if (inviteId != null && inviteId.isNotEmpty) 'inviteId': inviteId,
      },
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0D2A33', // matches IncomingCallScreen bg
        actionColor: '#2E7D32',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Incoming call',
        missedCallNotificationChannelName: 'Missed call',
        isShowCallID: false,
        isShowFullLockedScreen: true,
      ),
      ios: IOSParams(
        handleType: 'generic',
        supportsVideo: isVideo,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
      ),
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  static Future<void> endCall(String id) async {
    try {
      await FlutterCallkitIncoming.endCall(id);
    } catch (_) {/* best-effort */}
  }

  static Future<void> endAllCalls() async {
    try {
      await FlutterCallkitIncoming.endAllCalls();
    } catch (_) {/* best-effort */}
  }

  /// Request the Android 13+ notification + Android 14+ full-screen-intent
  /// permissions the native call UI needs. Best-effort; safe to call
  /// repeatedly. Android-focused; iOS is a no-op on these calls.
  Future<void> requestPermissions() async {
    try {
      await FlutterCallkitIncoming.requestNotificationPermission(
        <String, dynamic>{
          'rationaleMessagePermission':
              'INTERACT needs notification permission to show incoming calls.',
          'postNotificationMessageRequired':
              'Please allow notifications so incoming calls can ring.',
        },
      );
    } catch (_) {/* best-effort */}
    try {
      final can = await FlutterCallkitIncoming.canUseFullScreenIntent();
      if (can == false) {
        await FlutterCallkitIncoming.requestFullIntentPermission();
      }
    } catch (_) {/* best-effort */}
  }

  /// Subscribe to native accept / decline / call-back events. Idempotent — a
  /// second call replaces the prior subscription.
  ///
  /// - [onAccept]  → user answered → navigate to the room (join, host=false).
  /// - [onDecline] → user declined / call ended / timed out → dismiss.
  /// - [onCallback]→ user tapped "Call back" on the native missed-call notif.
  void listenEvents({
    required void Function(
      String threadId,
      String mode,
      String? callerName,
      String? inviteId,
    ) onAccept,
    void Function(String threadId)? onDecline,
    void Function(String threadId, String mode)? onCallback,
  }) {
    _sub?.cancel();
    _sub = FlutterCallkitIncoming.onEvent.listen((event) async {
      if (event == null) return;
      final payload = _payloadOf(event); // event.data / event.body (dynamic)
      final id = _idOf(payload);
      if (id.isEmpty) return;
      final info = _infoOf(payload);
      if (event is CallEventActionCallAccept) {
        onAccept(id, info.mode, info.callerName, info.inviteId);
      } else if (event is CallEventActionCallCallback) {
        onCallback?.call(id, info.mode);
      } else if (event is CallEventActionCallDecline ||
          event is CallEventActionCallEnded ||
          event is CallEventActionCallTimeout) {
        onDecline?.call(id);
      }
    });
  }

  /// Cold-start: if the app was launched by ACCEPTING a native call while it
  /// was killed, land in the room. Read defensively (dynamic) so it works
  /// whether `activeCalls()` yields CallKitParams objects or maps. Android does
  /// not always flag acceptance, so we only navigate when the entry explicitly
  /// says it was accepted (otherwise the live event stream handles it).
  Future<void> checkColdStart({
    required void Function(
      String threadId,
      String mode,
      String? callerName,
      String? inviteId,
    ) onAccept,
  }) async {
    try {
      final dynamic calls = await FlutterCallkitIncoming.activeCalls();
      if (calls is! List) return;
      for (final dynamic raw in calls) {
        if (!_acceptedOf(raw)) continue;
        final id = _idOf(raw);
        if (id.isEmpty) continue;
        final info = _infoOf(raw);
        // Consume the native entry before navigating — otherwise every
        // subsequent cold start re-enters /room stuck on "Connecting…".
        await endCall(id);
        await endAllCalls();
        onAccept(id, info.mode, info.callerName, info.inviteId);
        return;
      }
    } catch (_) {/* best-effort */}
  }

  // ── defensive extractors (dynamic — API field names vary across versions) ──

  /// The data payload carried by an event: try `.data`, then `.body`.
  static dynamic _payloadOf(dynamic event) {
    try {
      final d = event.data;
      if (d != null) return d;
    } catch (_) {/* no .data on this event type */}
    try {
      final b = event.body;
      if (b != null) return b;
    } catch (_) {/* no .body */}
    return null;
  }

  static String _idOf(dynamic p) {
    if (p == null) return '';
    if (p is Map) return (p['id'] ?? '').toString();
    try {
      final v = p.id;
      return (v ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static bool _acceptedOf(dynamic p) {
    if (p == null) return false;
    if (p is Map) return p['isAccepted'] == true || p['accepted'] == true;
    try {
      return p.isAccepted == true;
    } catch (_) {
      return false;
    }
  }

  static _CallInfo _infoOf(dynamic p) {
    Map extra = const {};
    dynamic type;
    String? nameCaller;
    if (p is Map) {
      if (p['extra'] is Map) extra = p['extra'] as Map;
      type = p['type'];
      nameCaller = p['nameCaller'] as String?;
    } else if (p != null) {
      try {
        final e = p.extra;
        if (e is Map) extra = e;
      } catch (_) {}
      try {
        type = p.type;
      } catch (_) {}
      try {
        nameCaller = p.nameCaller as String?;
      } catch (_) {}
    }
    final mode = (extra['mode'] as String?) ??
        ((type == 1 || type == '1') ? 'video' : 'voice');
    final callerName = (extra['callerName'] as String?) ?? nameCaller;
    final inviteId = (extra['inviteId'] as String?) ??
        (extra['invite_id'] as String?);
    return (mode: mode, callerName: callerName, inviteId: inviteId);
  }
}
