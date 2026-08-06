// SPDX-License-Identifier: AGPL-3.0
//
// Fleet UI languages for INTERACT Talk: EN · UR · AR · TR · RU · PA.
// Persisted override + RTL for ur/ar. Distinct from sahulat_common's
// regional voice-language enum (ur/pa/sd/ps/bal).
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum TalkLanguageOption {
  system,
  english,
  urdu,
  arabic,
  turkish,
  russian,
  punjabi,
}

const List<Locale> kTalkSupportedLocales = <Locale>[
  Locale('en'),
  Locale('ur'),
  Locale('ar'),
  Locale('tr'),
  Locale('ru'),
  Locale('pa'),
];

class LocalePrefs {
  LocalePrefs(this._prefs);

  static const String preferenceKey = 'talk_language_option';

  final SharedPreferences _prefs;

  TalkLanguageOption get option => _decode(_prefs.getString(preferenceKey));

  Future<void> setOption(TalkLanguageOption value) async {
    await _prefs.setString(preferenceKey, _encode(value));
  }

  /// Explicit locale for MaterialApp, or null to follow the device.
  Locale? get localeOverride {
    switch (option) {
      case TalkLanguageOption.english:
        return const Locale('en');
      case TalkLanguageOption.urdu:
        return const Locale('ur');
      case TalkLanguageOption.arabic:
        return const Locale('ar');
      case TalkLanguageOption.turkish:
        return const Locale('tr');
      case TalkLanguageOption.russian:
        return const Locale('ru');
      case TalkLanguageOption.punjabi:
        return const Locale('pa');
      case TalkLanguageOption.system:
        return null;
    }
  }

  static bool isRtlLanguageCode(String code) => code == 'ar' || code == 'ur';

  static TalkLanguageOption _decode(String? raw) {
    switch (raw) {
      case 'en':
        return TalkLanguageOption.english;
      case 'ur':
        return TalkLanguageOption.urdu;
      case 'ar':
        return TalkLanguageOption.arabic;
      case 'tr':
        return TalkLanguageOption.turkish;
      case 'ru':
        return TalkLanguageOption.russian;
      case 'pa':
        return TalkLanguageOption.punjabi;
      case 'system':
      default:
        return TalkLanguageOption.system;
    }
  }

  static String _encode(TalkLanguageOption value) {
    switch (value) {
      case TalkLanguageOption.english:
        return 'en';
      case TalkLanguageOption.urdu:
        return 'ur';
      case TalkLanguageOption.arabic:
        return 'ar';
      case TalkLanguageOption.turkish:
        return 'tr';
      case TalkLanguageOption.russian:
        return 'ru';
      case TalkLanguageOption.punjabi:
        return 'pa';
      case TalkLanguageOption.system:
        return 'system';
    }
  }
}

final sharedPreferencesProvider = FutureProvider<SharedPreferences>((ref) {
  return SharedPreferences.getInstance();
});

final localePrefsProvider = Provider<LocalePrefs?>((ref) {
  final async = ref.watch(sharedPreferencesProvider);
  return async.maybeWhen(
    data: (p) => LocalePrefs(p),
    orElse: () => null,
  );
});

/// Notifies MaterialApp when the user changes language.
class LocaleController extends Notifier<TalkLanguageOption> {
  @override
  TalkLanguageOption build() {
    final prefs = ref.watch(localePrefsProvider);
    return prefs?.option ?? TalkLanguageOption.system;
  }

  Future<void> setOption(TalkLanguageOption value) async {
    final prefs = ref.read(localePrefsProvider);
    if (prefs != null) await prefs.setOption(value);
    state = value;
  }

  Locale? get localeOverride {
    switch (state) {
      case TalkLanguageOption.english:
        return const Locale('en');
      case TalkLanguageOption.urdu:
        return const Locale('ur');
      case TalkLanguageOption.arabic:
        return const Locale('ar');
      case TalkLanguageOption.turkish:
        return const Locale('tr');
      case TalkLanguageOption.russian:
        return const Locale('ru');
      case TalkLanguageOption.punjabi:
        return const Locale('pa');
      case TalkLanguageOption.system:
        return null;
    }
  }
}

final localeControllerProvider =
    NotifierProvider<LocaleController, TalkLanguageOption>(LocaleController.new);
