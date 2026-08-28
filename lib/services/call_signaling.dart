// SPDX-License-Identifier: AGPL-3.0
//
// CallSignaling — incoming-call ring (FaceTime-style), poll-based.
//
// The caller posts a ring (POST /talk/calls/ring) for the thread's other
// participant. Each running app polls GET /talk/calls/incoming every few
// seconds; when a ringing invite appears, `incoming` fires and AppShell shows
// the full-screen IncomingCallScreen — unless [inCall] is true, in which case
// we auto-respond `busy` and surface [missedWhileBusy] so the in-call UI can
// show a banner.
//
// Foreground / recently-backgrounded today; killed-app ring is a later FCM
// step (same as message notifications).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';
import 'api_base.dart';
import 'block_service.dart';

String get _kBase => ApiBase.current;

/// A ringing invite the callee should answer.
class IncomingCall {
  const IncomingCall({
    required this.id,
    required this.threadId,
    required this.mode,
    required this.callerName,
    this.callerAvatar,
  });
  final String id;
  final String threadId;
  final String mode; // 'video' | 'voice'
  final String callerName;
  final String? callerAvatar;

  factory IncomingCall.fromJson(Map<String, dynamic> j) => IncomingCall(
        id: j['id'] as String,
        threadId: (j['threadId'] as String?) ?? '',
        mode: (j['mode'] as String?) ?? 'video',
        callerName: (j['callerName'] as String?) ?? 'INTERACT caller',
        callerAvatar: j['callerAvatar'] as String?,
      );
}

final callSignalingProvider = Provider<CallSignaling>((ref) {
  final s = CallSignaling(ref.read(authServiceProvider));
  // Blocked-contacts enforcement (Me → Security & Privacy): invites from a
  // blocked thread are silently ignored — no ring, caller sees no-answer.
  s.isBlockedThread = ref.read(blockServiceProvider).isBlocked;
  return s;
});

class CallSignaling {
  CallSignaling(this._auth);
  final AuthService _auth;

  /// Injected from blockServiceProvider — returns true when the thread's
  /// peer is on the local block list. Null-safe default: nothing blocked.
  bool Function(String? threadId) isBlockedThread = (_) => false;

  Timer? _timer;

  /// Latest ringing invite (or null). AppShell listens and shows the ring.
  final ValueNotifier<IncomingCall?> incoming = ValueNotifier<IncomingCall?>(null);

  /// True while MeetingRoomScreen (or Live room) is active. Second callers get
  /// an immediate `busy` response instead of stacking a full-screen ring.
  final ValueNotifier<bool> inCall = ValueNotifier<bool>(false);

  /// Last caller who hit us while we were already on a call (for in-call banner).
  final ValueNotifier<IncomingCall?> missedWhileBusy =
      ValueNotifier<IncomingCall?>(null);

  /// Ids we've already surfaced/handled — avoids re-ringing the same invite
  /// on the next poll before its status flips server-side.
  final Set<String> _handled = <String>{};

  Future<Map<String, String>> _headers() async {
    final t = await _auth.token();
    return {
      'Content-Type': 'application/json',
      if (t != null) 'Authorization': 'Bearer $t',
    };
  }

  void setInCall(bool value) {
    inCall.value = value;
    if (!value) {
      // Leaving a call — allow a fresh banner next time.
      missedWhileBusy.value = null;
    } else {
      // Catch a ring that landed in the last poll window ASAP.
      checkNow();
    }
  }

  void clearMissedWhileBusy() => missedWhileBusy.value = null;

  void start() {
    if (_timer != null) return;
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Force an immediate incoming-call poll, bypassing the 4s cadence. Called
  /// when the user taps the FCM call-ring push so the IncomingCallScreen shows
  /// at once instead of waiting for the next periodic tick.
  void checkNow() => _poll();

  Future<void> _poll() async {
    // Don't stack a second ring while one is showing.
    if (incoming.value != null) return;
    try {
      final res = await http
          .get(Uri.parse('$_kBase/api/v1/talk/calls/incoming'), headers: await _headers())
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      final inv = data['invite'];
      if (inv is Map<String, dynamic>) {
        final call = IncomingCall.fromJson(inv);
        if (_handled.contains(call.id)) return;
        _handled.add(call.id);

        // Blocked peer → swallow the invite entirely (no ring, no banner,
        // no respond — the caller's side times out as a normal no-answer).
        if (isBlockedThread(call.threadId)) return;

        if (inCall.value) {
          // Already in a live call — tell the caller we're busy and banner locally.
          missedWhileBusy.value = call;
          unawaited(respond(call.id, 'busy'));
          return;
        }

        incoming.value = call;
      }
    } catch (_) {/* best-effort */}
  }

  /// Caller side — ring the thread's other participant(s) for an outgoing call.
  /// Returns the created invite id (1:1) so the caller can remotely CANCEL the
  /// callee's ring via [respond](id, 'cancel') if they hang up before it's
  /// answered. Null when the ring couldn't be created (best-effort).
  Future<String?> ring(String threadId, String mode) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_kBase/api/v1/talk/calls/ring'),
            headers: await _headers(),
            body: jsonEncode({'threadId': threadId, 'mode': mode}),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode >= 400) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      return data['inviteId'] as String?;
    } catch (_) {
      return null; // ring is best-effort; the call still proceeds
    }
  }

  /// Caller polls invite status while "Ringing…" so a remote `busy` ends the
  /// wait instead of sitting until TTL.
  Future<String?> inviteStatus(String id) async {
    try {
      final res = await http
          .get(
            Uri.parse('$_kBase/api/v1/talk/calls/status/$id'),
            headers: await _headers(),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      return data['status'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Callee side — is [id] still a live ringing invite? The incoming-call
  /// screen polls this so it auto-dismisses when the caller cancels/hangs up
  /// (the /incoming endpoint returns the latest ringing invite, or null once
  /// this one is cancelled/expired/answered).
  Future<bool> isRinging(String id) async {
    try {
      final res = await http
          .get(Uri.parse('$_kBase/api/v1/talk/calls/incoming'),
              headers: await _headers())
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return true; // network blip — don't dismiss
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = (body['data'] ?? body) as Map<String, dynamic>;
      final inv = data['invite'];
      return inv is Map<String, dynamic> && inv['id'] == id;
    } catch (_) {
      return true; // transient error — keep ringing rather than false-dismiss
    }
  }

  /// Callee accept/decline/busy (or caller cancel) of an invite.
  Future<void> respond(String id, String action) async {
    if (action != 'busy') {
      incoming.value = null; // dismiss the ring immediately (busy never set it)
    }
    try {
      await http
          .post(
            Uri.parse('$_kBase/api/v1/talk/calls/respond'),
            headers: await _headers(),
            body: jsonEncode({'id': id, 'action': action}),
          )
          .timeout(const Duration(seconds: 6));
    } catch (_) {/* best-effort */}
  }

  /// Clear the current ring without responding (e.g. it expired / caller hung up).
  void clear() => incoming.value = null;

  /// Mark an invite as handled OUTSIDE the poll (e.g. accepted on the native
  /// CallKit surface) so the poll never resurfaces it as a second in-app ring.
  /// Without this, a native accept raced the 4s poll: the poll's GET could
  /// return the still-`ringing` invite after the accept cleared [incoming],
  /// pushing IncomingCallScreen ON TOP of the call room — the user was
  /// "asked twice to receive the call" (observed on device 2026-08-06).
  void suppress(String id) {
    _handled.add(id);
    if (incoming.value?.id == id) incoming.value = null;
  }
}
