// SPDX-License-Identifier: AGPL-3.0
//
// Coordinates fail-soft IL reminder + Talk theme/wallpaper mirrors on open/resume.
// Waits for SharedPreferences + a valid bearer before flushing.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/locale_prefs.dart';
import '../core/theme/theme_prefs.dart';
import '../core/theme/chat_wallpaper_prefs.dart';
import 'auth_service.dart';
import 'welcome_memory_store.dart';

/// Minimum gap between resume-triggered flushes (cold start always forces).
const kMirrorSyncMinInterval = Duration(seconds: 15);

/// Pure helper — testable throttle for resume flushes.
bool shouldFlushMirrorSync(
  DateTime lastFlushAt,
  DateTime now, {
  bool force = false,
  Duration minInterval = kMirrorSyncMinInterval,
}) {
  if (force) return true;
  return now.difference(lastFlushAt) >= minInterval;
}

class PendingMirrorSync {
  PendingMirrorSync._();

  static DateTime _lastFlushAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _coldStartDone = false;

  /// Call after first frame when the signed-in shell is visible.
  static Future<void> onAppOpen(WidgetRef ref, {bool force = false}) async {
    final now = DateTime.now();
    final cold = !_coldStartDone;
    if (cold) _coldStartDone = true;

    if (!shouldFlushMirrorSync(
      _lastFlushAt,
      now,
      force: force || cold,
    )) {
      return;
    }

    final ok = await _ensureReady(ref);
    if (!ok) {
      if (kDebugMode) {
        debugPrint('[PendingMirrorSync] skipped — prefs or auth not ready');
      }
      return;
    }

    _lastFlushAt = now;

    if (kDebugMode) debugPrint('[PendingMirrorSync] flush start');

    await WelcomeMemoryStore.instance.flushPendingIlSync();

    final theme = ref.read(themeControllerProvider.notifier);
    if (cold) {
      await theme.syncWithServerOnOpen();
    } else {
      await theme.flushPendingPush();
    }

    final wallpaper = ref.read(chatWallpaperControllerProvider.notifier);
    if (cold) {
      await wallpaper.syncWithServerOnOpen();
    } else {
      await wallpaper.flushPendingPush();
    }

    if (kDebugMode) debugPrint('[PendingMirrorSync] flush done');
  }

  /// Resume from background — retry pending PUTs only (no theme GET).
  static Future<void> onAppResume(WidgetRef ref) async {
    await onAppOpen(ref, force: false);
  }

  /// Wait for SharedPreferences + JWT. One short retry for auth refresh race.
  static Future<bool> _ensureReady(WidgetRef ref) async {
    try {
      await ref.read(sharedPreferencesProvider.future);
    } catch (_) {
      return false;
    }

    if (await AuthService.instance.hasValidToken()) return true;

    await Future<void>.delayed(const Duration(seconds: 2));
    return AuthService.instance.hasValidToken();
  }

  /// Test hook — reset session throttle state.
  @visibleForTesting
  static void resetForTest() {
    _lastFlushAt = DateTime.fromMillisecondsSinceEpoch(0);
    _coldStartDone = false;
  }
}
