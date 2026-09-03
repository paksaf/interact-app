// SPDX-License-Identifier: AGPL-3.0
//
// User theme preferences — mode, seed, accent. Local-first; mirrored to Talk API.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/locale_prefs.dart';
import '../../services/talk_theme_sync_service.dart';

/// Default INTERACT brand — unchanged for users with no saved theme.
const kDefaultThemeSeed = Color(0xFF0D4A5C);
const kDefaultThemeAccent = Color(0xFFBE9A5F);

class AppThemeState {
  const AppThemeState({
    required this.mode,
    required this.seed,
    required this.accent,
    this.presetId = 'signal',
  });

  final ThemeMode mode;
  final Color seed;
  final Color accent;

  /// Which preset is active, or `custom` when the user picked HSL values.
  final String presetId;

  AppThemeState copyWith({
    ThemeMode? mode,
    Color? seed,
    Color? accent,
    String? presetId,
  }) {
    return AppThemeState(
      mode: mode ?? this.mode,
      seed: seed ?? this.seed,
      accent: accent ?? this.accent,
      presetId: presetId ?? this.presetId,
    );
  }
}

class ThemePreset {
  const ThemePreset({
    required this.id,
    required this.seed,
    required this.accent,
  });

  final String id;
  final Color seed;
  final Color accent;
}

const kThemePresets = <ThemePreset>[
  ThemePreset(id: 'signal', seed: kDefaultThemeSeed, accent: kDefaultThemeAccent),
  ThemePreset(id: 'saffron', seed: Color(0xFF0E7C6B), accent: Color(0xFFE8912A)),
  ThemePreset(id: 'indigo', seed: Color(0xFF3B4CCA), accent: Color(0xFFF2A63B)),
  ThemePreset(id: 'forest', seed: Color(0xFF1F6F4A), accent: Color(0xFFD9A441)),
  ThemePreset(id: 'plum', seed: Color(0xFF6D3B6E), accent: Color(0xFFE0A458)),
  ThemePreset(id: 'graphite', seed: Color(0xFF3A3F44), accent: Color(0xFF8FA39C)),
];

class ThemePrefs {
  ThemePrefs(this._prefs);

  static const modeKey = 'theme.mode';
  static const seedKey = 'theme.seed';
  static const accentKey = 'theme.accent';
  static const presetKey = 'theme.preset';
  static const syncPendingKey = 'theme.syncPending';

  final SharedPreferences _prefs;

  AppThemeState get state {
    final modeRaw = _prefs.getString(modeKey);
    final mode = switch (modeRaw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final seedValue = _prefs.getInt(seedKey);
    final accentValue = _prefs.getInt(accentKey);
    return AppThemeState(
      mode: mode,
      seed: seedValue != null ? Color(seedValue) : kDefaultThemeSeed,
      accent: accentValue != null ? Color(accentValue) : kDefaultThemeAccent,
      presetId: _prefs.getString(presetKey) ?? 'signal',
    );
  }

  Future<void> save(AppThemeState value) async {
    final modeStr = switch (value.mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await _prefs.setString(modeKey, modeStr);
    await _prefs.setInt(seedKey, value.seed.toARGB32());
    await _prefs.setInt(accentKey, value.accent.toARGB32());
    await _prefs.setString(presetKey, value.presetId);
  }

  bool get syncPending => _prefs.getBool(syncPendingKey) ?? false;

  Future<void> setSyncPending(bool value) async {
    await _prefs.setBool(syncPendingKey, value);
  }
}

final themePrefsProvider = Provider<ThemePrefs?>((ref) {
  final async = ref.watch(sharedPreferencesProvider);
  return async.maybeWhen(
    data: (p) => ThemePrefs(p),
    orElse: () => null,
  );
});

class ThemeController extends Notifier<AppThemeState> {
  static bool _sessionPullDone = false;

  @override
  AppThemeState build() {
    final prefs = ref.watch(themePrefsProvider);
    return prefs?.state ?? const AppThemeState(
      mode: ThemeMode.system,
      seed: kDefaultThemeSeed,
      accent: kDefaultThemeAccent,
    );
  }

  /// Once per app session: pull server theme if local is still default.
  /// Also retries a pending PUT from a prior offline change.
  Future<void> syncWithServerOnOpen() async {
    await _pullServerIfNeeded();
    await flushPendingPush();
  }

  Future<void> _pullServerIfNeeded() async {
    if (_sessionPullDone) return;
    _sessionPullDone = true;

    if (!isDefaultLocalTheme(state)) return;

    final remote = await TalkThemeSyncService.instance.fetchTheme();
    if (remote == null) return;

    final next = appThemeFromRemote(remote);
    if (isDefaultLocalTheme(next)) return;

    await _persist(next, pushRemote: false);
  }

  Future<void> flushPendingPush() async {
    final prefs = ref.read(themePrefsProvider);
    if (prefs == null || !prefs.syncPending) return;

    final result = await TalkThemeSyncService.instance.pushFull(state);
    if (!result.pending) {
      await prefs.setSyncPending(false);
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    final next = state.copyWith(mode: mode);
    await _persist(next);
  }

  Future<void> applyPreset(ThemePreset preset) async {
    final next = AppThemeState(
      mode: state.mode,
      seed: preset.seed,
      accent: preset.accent,
      presetId: preset.id,
    );
    await _persist(next);
  }

  Future<void> applyCustom({required Color seed, Color? accent}) async {
    final safeSeed = clampSeedLightness(seed);
    final safeAccent = nudgeAccentForContrast(
      accent ?? deriveAccentFromSeed(safeSeed),
      safeSeed,
    );
    final next = AppThemeState(
      mode: state.mode,
      seed: safeSeed,
      accent: safeAccent,
      presetId: 'custom',
    );
    await _persist(next);
  }

  Future<void> resetToDefault() async {
    const next = AppThemeState(
      mode: ThemeMode.system,
      seed: kDefaultThemeSeed,
      accent: kDefaultThemeAccent,
      presetId: 'signal',
    );
    await _persist(next);
  }

  Future<void> _persist(AppThemeState next, {bool pushRemote = true}) async {
    final prefs = ref.read(themePrefsProvider);
    if (prefs != null) await prefs.save(next);
    state = next;

    if (!pushRemote) return;

    unawaited(_pushThemeBestEffort(next));
  }

  Future<void> _pushThemeBestEffort(AppThemeState next) async {
    final prefs = ref.read(themePrefsProvider);
    final result = await TalkThemeSyncService.instance.pushFull(next);
    if (prefs == null) return;
    if (result.pending) {
      await prefs.setSyncPending(true);
    } else {
      await prefs.setSyncPending(false);
    }
  }
}

final themeControllerProvider =
    NotifierProvider<ThemeController, AppThemeState>(ThemeController.new);

ThemeData buildTalkTheme({
  required Color seed,
  required Color accent,
  required Brightness brightness,
}) {
  return ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(secondary: accent, tertiary: accent),
    useMaterial3: true,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      foregroundColor: brightness == Brightness.light ? seed : null,
    ),
  );
}

/// Clamp custom seed lightness to 25–60% (HSL L).
Color clampSeedLightness(Color input) {
  final hsl = HSLColor.fromColor(input);
  final l = hsl.lightness.clamp(0.25, 0.60);
  return hsl.withLightness(l).toColor();
}

Color deriveAccentFromSeed(Color seed) {
  final hsl = HSLColor.fromColor(seed);
  return hsl
      .withSaturation((hsl.saturation + 0.15).clamp(0.35, 1.0))
      .withLightness((hsl.lightness + 0.22).clamp(0.35, 0.72))
      .toColor();
}

Color nudgeAccentForContrast(Color accent, Color seed) {
  final onSurface = ColorScheme.fromSeed(
    seedColor: seed,
    brightness: Brightness.light,
  ).onSurface;
  var candidate = accent;
  for (var i = 0; i < 8; i++) {
    if (_contrastRatio(candidate, onSurface) >= 3.0) return candidate;
    final hsl = HSLColor.fromColor(candidate);
    candidate = hsl.withLightness((hsl.lightness - 0.06).clamp(0.2, 0.85)).toColor();
  }
  return candidate;
}

double _contrastRatio(Color a, Color b) {
  final l1 = _relativeLuminance(a);
  final l2 = _relativeLuminance(b);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

double _relativeLuminance(Color c) {
  double channel(double v) {
    v /= 255;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}
