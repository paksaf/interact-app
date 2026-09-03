// SPDX-License-Identifier: AGPL-3.0
//
// NotificationService — local (on-device) notifications for new chat
// messages. A high-importance Android channel shows a heads-up banner AND
// plays the system notification sound, so no bundled audio asset is needed.
//
// Scope: fires while the app is running (foreground / recently backgrounded),
// driven by message_watcher.dart's thread poll. True killed-app push is a
// later FCM addition — this covers the common case now, with zero external
// setup.
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Background (bg-isolate) tap handler. Runs in a separate isolate and CANNOT
/// navigate — cold-start / foreground tap routing is done by
/// NotificationService._onResponse + processLaunchPayloadIfAny() in the UI
/// isolate. Must be top-level + vm:entry-point for AOT.
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // Intentionally empty — see doc comment above.
}

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  /// Set by the app layer (main.dart _Gate) to route a tapped "Missed call —
  /// tap to call back" notification. Fail-soft if unset. Payload shape:
  /// `missed:<threadId>:<mode>`.
  static void Function(String threadId, String mode)? onMissedTap;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    // Timezone setup for scheduled reminders. Default to Asia/Karachi (the
    // primary market, no DST); falls back to UTC if unavailable.
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Karachi'));
    } catch (_) {}
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    // Android 13+ runtime notification permission (no-op below 13).
    await android?.requestNotificationsPermission();
    // iOS permission.
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    // Create the notification channels EXPLICITLY. Android locks a channel's
    // importance + sound at creation and ignores later changes — so if the FCM
    // system-tray path (manifest default_notification_channel_id=interact_calls)
    // created the channel first with default/quiet settings, the incoming-call
    // ring would be silent forever. Creating it here at init guarantees
    // Importance.max + ringtone audio usage from first launch. Idempotent, so
    // it's safe in both the UI isolate and the FCM background isolate.
    const callsChannel = AndroidNotificationChannel(
      'interact_calls',
      'Calls',
      description: 'Incoming voice/video calls',
      importance: Importance.max,
      playSound: true,
      // Route through the ringtone stream (louder / rings) rather than the
      // quieter default notification stream — no bundled audio asset needed.
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      enableVibration: true,
    );
    const messagesChannel = AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'New chat messages',
      importance: Importance.high,
      playSound: true,
    );
    // Quiet tray updates (login codes while Talk is open, etc.) — no heads-up
    // so Samsung doesn't push the Calls/Chats dashboard down.
    const quietChannel = AndroidNotificationChannel(
      'messages_quiet',
      'Quiet updates',
      description: 'In-app codes and non-urgent updates',
      importance: Importance.low,
      playSound: false,
    );
    // Missed / unanswered calls — DEFAULT importance (no heads-up ring; it is
    // a quiet "you missed a call, tap to call back" banner, unlike the max
    // 'interact_calls' channel above).
    const missedChannel = AndroidNotificationChannel(
      'interact_missed',
      'Missed calls',
      description: 'Missed / unanswered calls',
      importance: Importance.defaultImportance,
      playSound: true,
    );
    await android?.createNotificationChannel(callsChannel);
    await android?.createNotificationChannel(messagesChannel);
    await android?.createNotificationChannel(quietChannel);
    await android?.createNotificationChannel(missedChannel);
    const remindersChannel = AndroidNotificationChannel(
      'reminders',
      'Reminders',
      description: 'Note reminders',
      importance: Importance.high,
      playSound: true,
    );
    await android?.createNotificationChannel(remindersChannel);

    _ready = true;
  }

  /// Schedule a local reminder notification at [at]. Uses inexact scheduling so
  /// no exact-alarm permission is needed (Android 13+). Past times are ignored.
  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime at,
    String? payload,
  }) async {
    await init();
    final when = tz.TZDateTime.from(at, tz.local);
    if (!when.isAfter(tz.TZDateTime.now(tz.local))) return;
    await _plugin.zonedSchedule(
      id,
      title,
      body,
      when,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'reminders',
          'Reminders',
          channelDescription: 'Note reminders',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
      payload: payload,
    );
  }

  /// Cancel a previously scheduled reminder by its id.
  Future<void> cancelReminder(int id) async {
    await _plugin.cancel(id);
  }

  /// Route a tapped notification. Only `missed:<threadId>:<mode>` payloads are
  /// handled here (→ [onMissedTap]); message/call payloads keep their prior
  /// no-routing behaviour so nothing regresses.
  void _onResponse(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || !payload.startsWith('missed:')) return;
    // Split into at most 3 parts so a threadId containing ':' is preserved.
    final rest = payload.substring('missed:'.length);
    final sep = rest.lastIndexOf(':');
    final threadId = sep >= 0 ? rest.substring(0, sep) : rest;
    final mode = sep >= 0 ? rest.substring(sep + 1) : 'video';
    if (threadId.isNotEmpty) onMissedTap?.call(threadId, mode);
  }

  /// Cold-start: if the app was launched by tapping a notification, replay its
  /// payload through [_onResponse]. Call once after [onMissedTap] is wired.
  Future<void> processLaunchPayloadIfAny() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      final resp = details?.notificationResponse;
      if (details?.didNotificationLaunchApp == true && resp != null) {
        _onResponse(resp);
      }
    } catch (_) {/* best-effort */}
  }

  /// "Missed call — tap to call back" notification. Fired for offline /
  /// already-dead calls (see push_service foreground path). Payload
  /// `missed:<threadId>:<mode>` routes via [onMissedTap] on tap.
  Future<void> showMissedCall({
    required String callId,
    required String callerName,
    String mode = 'video',
  }) async {
    if (!_ready) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'interact_missed',
        'Missed calls',
        channelDescription: 'Missed / unanswered calls',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        playSound: true,
        ticker: 'Missed call',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await _plugin.show(
      'missed:$callId'.hashCode & 0x7fffffff,
      'Missed call from ${callerName.isEmpty ? 'INTERACT caller' : callerName}',
      'Tap to call back',
      details,
      payload: 'missed:$callId:$mode',
    );
  }

  /// Show a "new message" notification. `threadId` becomes the payload +
  /// (hashed) notification id so repeated messages in one thread replace
  /// the prior banner instead of stacking.
  ///
  /// When [quiet] is true, uses a low-importance channel (no heads-up / sound)
  /// so foreground OTP/login codes don't bump the main dashboard on Samsung.
  Future<void> showMessage({
    required String title,
    required String body,
    String? threadId,
    bool quiet = false,
  }) async {
    if (!_ready) await init();
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        quiet ? 'messages_quiet' : 'messages',
        quiet ? 'Quiet updates' : 'Messages',
        channelDescription: quiet
            ? 'In-app codes and non-urgent updates'
            : 'New chat messages',
        importance: quiet ? Importance.low : Importance.high,
        priority: quiet ? Priority.low : Priority.high,
        playSound: !quiet,
        // Re-posting the SAME notification id (same thread) UPDATES the banner
        // silently instead of re-vibrating/re-ringing on every poll tick. The
        // FIRST post still alerts (vibrate+sound); subsequent updates are quiet.
        onlyAlertOnce: true,
        ticker: quiet ? null : 'New message',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: !quiet,
        presentBadge: true,
        presentSound: !quiet,
      ),
    );
    final id = (threadId?.hashCode ?? title.hashCode) & 0x7fffffff;
    await _plugin.show(
      id,
      title.isEmpty ? 'New message' : title,
      body.isEmpty ? 'Tap to open' : body,
      details,
      payload: threadId,
    );
  }

  /// Full-screen incoming-call notification. Uses a full-screen intent + the
  /// ringtone audio usage so a killed/backgrounded app still RINGS (not just a
  /// heads-up banner). Fired by push_service.dart on a `call_ring` FCM message.
  Future<void> showIncomingCall({
    required String callId,
    required String callerName,
    required String mode,
  }) async {
    if (!_ready) await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'interact_calls',
        'Calls',
        channelDescription: 'Incoming voice/video calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        ongoing: true,
        playSound: true,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        ticker: 'Incoming call',
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
    await _plugin.show(
      callId.hashCode & 0x7fffffff,
      'Incoming ${mode == 'voice' ? 'voice' : 'video'} call',
      callerName.isEmpty ? 'INTERACT caller' : callerName,
      details,
      payload: 'call:$callId:$mode',
    );
  }

  /// Dismiss the fallback full-screen incoming-call notification for [callId]
  /// (the caller cancelled / the invite died). Must mirror the id derivation
  /// in [showIncomingCall] exactly. No-op if none is showing.
  Future<void> cancelIncomingCall(String callId) async {
    try {
      await _plugin.cancel(callId.hashCode & 0x7fffffff);
    } catch (_) {/* best-effort */}
  }
}
