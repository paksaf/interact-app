import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/theme/chat_wallpaper_prefs.dart';
import 'package:interact/core/theme/theme_prefs.dart';
import 'package:interact/services/pending_mirror_sync.dart';
import 'package:interact/services/talk_theme_sync_service.dart';
import 'package:interact/services/talk_wallpaper_sync_service.dart';
import 'package:interact/services/welcome_memory_store.dart';

void main() {
  group('shouldFlushMirrorSync', () {
    final t0 = DateTime(2026, 9, 3, 12, 0);

    test('force bypasses throttle', () {
      expect(
        shouldFlushMirrorSync(t0, t0.add(const Duration(seconds: 1)), force: true),
        isTrue,
      );
    });

    test('blocks rapid resume within interval', () {
      expect(
        shouldFlushMirrorSync(t0, t0.add(const Duration(seconds: 5))),
        isFalse,
      );
    });

    test('allows flush after interval', () {
      expect(
        shouldFlushMirrorSync(t0, t0.add(const Duration(seconds: 16))),
        isTrue,
      );
    });
  });

  group('pendingIlReminders', () {
    test('selects only syncPending without ilTaskId', () {
      final due = DateTime.now().add(const Duration(hours: 2));
      final reminders = [
        WelcomeReminder(id: '1', body: 'A', dueAt: due, syncPending: true),
        WelcomeReminder(
          id: '2',
          body: 'B',
          dueAt: due,
          ilTaskId: 'il-99',
          syncPending: false,
        ),
        WelcomeReminder(id: '3', body: 'C', dueAt: due, syncPending: false),
      ];

      final pending = pendingIlReminders(reminders);
      expect(pending, hasLength(1));
      expect(pending.first.id, '1');
    });

    test('respects maxItems cap', () {
      final due = DateTime.now().add(const Duration(hours: 1));
      final reminders = List.generate(
        8,
        (i) => WelcomeReminder(
          id: '$i',
          body: 'R$i',
          dueAt: due,
          syncPending: true,
        ),
      );
      expect(pendingIlReminders(reminders, maxItems: 3), hasLength(3));
    });
  });

  group('WelcomeReminder.fromJson', () {
    test('defaults syncPending when ilTaskId missing', () {
      final r = WelcomeReminder.fromJson({
        'id': 'x',
        'body': 'test',
        'dueAt': DateTime.now().toIso8601String(),
      });
      expect(r.syncPending, isTrue);
      expect(r.ilTaskId, isNull);
    });

    test('clears syncPending when ilTaskId present', () {
      final r = WelcomeReminder.fromJson({
        'id': 'x',
        'body': 'test',
        'dueAt': DateTime.now().toIso8601String(),
        'ilTaskId': 'task-1',
        'syncPending': false,
      });
      expect(r.syncPending, isFalse);
      expect(r.ilTaskId, 'task-1');
    });
  });

  group('isDefaultLocalTheme', () {
    test('signal + system is default', () {
      expect(
        isDefaultLocalTheme(
          const AppThemeState(
            mode: ThemeMode.system,
            seed: kDefaultThemeSeed,
            accent: kDefaultThemeAccent,
            presetId: 'signal',
          ),
        ),
        isTrue,
      );
    });

    test('custom preset is not default', () {
      expect(
        isDefaultLocalTheme(
          const AppThemeState(
            mode: ThemeMode.system,
            seed: Color(0xFF0E7C6B),
            accent: Color(0xFFE8912A),
            presetId: 'saffron',
          ),
        ),
        isFalse,
      );
    });
  });

  group('presetIdForColors', () {
    test('matches saffron preset', () {
      expect(
        presetIdForColors(const Color(0xFF0E7C6B), const Color(0xFFE8912A)),
        'saffron',
      );
    });

    test('unknown pair is custom', () {
      expect(
        presetIdForColors(Colors.pink, Colors.cyan),
        'custom',
      );
    });
  });

  group('wallpaper sync helpers', () {
    test('default wallpaper is none', () {
      expect(isDefaultLocalWallpaper(const ChatWallpaperConfig()), isTrue);
      expect(
        isDefaultLocalWallpaper(
          const ChatWallpaperConfig(kind: ChatWallpaperKind.asset, asset: 'x'),
        ),
        isFalse,
      );
    });

    test('dim round-trips server ints', () {
      expect(wallpaperDimToServer(0.35), 35);
      expect(wallpaperDimFromServer(35), 0.35);
    });

    test('preset id maps to bundled asset', () {
      expect(presetIdFromAsset('assets/backgrounds/bg_warm.png'), 'warm');
      expect(assetFromPresetId('warm'), 'assets/backgrounds/bg_warm.png');
    });

    test('relativeUploadsPath accepts absolute talk URLs', () {
      expect(
        relativeUploadsPath('https://qurbanisahulat.com/uploads/wall.jpg'),
        '/uploads/wall.jpg',
      );
      expect(relativeUploadsPath('/uploads/wall.jpg'), '/uploads/wall.jpg');
    });

    test('scrim auto maps to none locally', () {
      expect(wallpaperScrimFromServer('auto'), ChatWallpaperScrim.none);
      expect(
        wallpaperScrimToServer(ChatWallpaperScrim.dark),
        'dark',
      );
    });
  });
}
