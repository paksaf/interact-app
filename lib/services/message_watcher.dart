// SPDX-License-Identifier: AGPL-3.0
//
// MessageWatcher — global poll that turns inbound chat messages into
// on-device notifications while the app runs, and exposes unread totals
// for bottom-nav badges.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat.dart';
import 'api_base.dart';
import 'chat_api.dart';
import 'notification_service.dart';

final messageWatcherProvider =
    Provider<MessageWatcher>((ref) => MessageWatcher(ref.read(chatApiProvider)));

class MessageWatcher {
  MessageWatcher(this._api);
  final ChatApi _api;

  Timer? _timer;
  final Map<String, DateTime> _lastSeen = {};
  bool _primed = false;

  /// Set by ChatThreadScreen while a conversation is open; notifications for
  /// this thread are suppressed (you're already looking at it).
  String? activeThreadId;

  /// Sum of server unreadCount across threads (for Chats tab badge).
  final ValueNotifier<int> unreadTotal = ValueNotifier<int>(0);

  void start() {
    if (_timer != null) return;
    _tick(); // prime immediately
    _timer = Timer.periodic(const Duration(seconds: 12), (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> checkNow() => _tick();

  Future<void> _tick() async {
    List<ChatThread> threads;
    try {
      threads = await _api.listAllThreads();
    } catch (_) {
      // offline / 401 / DNS failure — kick the base-URL failover probe
      // (throttled internally) so a resolver outage self-heals, then
      // try again next tick.
      unawaited(ApiBase.checkAndMaybeSwitch());
      return;
    }
    // Only raise a SYSTEM notification when the app is backgrounded/paused —
    // in-app you already see messages in the UI, so a buzz+sound each poll tick
    // (~12s) is wrong. We still advance the seen-marker below regardless, so
    // nothing double-fires later when the app is next backgrounded.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final backgrounded = lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached;
    var unread = 0;
    for (final t in threads) {
      unread += t.unreadCount;
      final prev = _lastSeen[t.id];
      _lastSeen[t.id] = t.lastMessageAt;
      if (!_primed) continue; // first pass: baseline only, no notifications
      final advanced = prev == null || t.lastMessageAt.isAfter(prev);
      if (advanced && t.id != activeThreadId && backgrounded) {
        NotificationService.instance.showMessage(
          title: t.title,
          body: t.lastMessagePreview ?? 'New message',
          threadId: t.id,
        );
      }
    }
    unreadTotal.value = unread;
    _primed = true;
  }
}
