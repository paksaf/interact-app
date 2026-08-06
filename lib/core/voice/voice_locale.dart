// Patterns adapted from interact-maps / interact_mobile_common `voice_locale.dart`
// (fleet voice locale kit, 2026-07-02). Dependency-free — no plugin imports.
//
// VOICE LOCALE KIT — fleet-wide local-language correctness
// for the speech stack (speech_to_text + flutter_tts), Urdu-first.
//
// Dependency-free ON PURPOSE: the resolvers take plain string lists, so
// this file has no plugin imports and can be copied verbatim into apps.
//
// Why this exists: STT engines expose locale ids like `ur_PK`
// (underscore) while TTS engines expose BCP-47 tags like `ur-PK`
// (hyphen) — and BOTH vary per device/engine (`ur-PK` vs `ur_IN` vs
// plain `ur`). Hardcoding one form silently breaks recognition/speech on
// half the fleet. Always probe the engine (SpeechToText.locales() /
// FlutterTts.getLanguages) and resolve through this kit.
//
// Usage (each app adapts with its own plugin instance):
//
//   // STT
//   final ids = (await stt.locales()).map((l) => l.localeId).toList();
//   final r = resolveSttLocale(ids, 'ur');
//   await stt.listen(localeId: r.locale, ...);
//
//   // TTS
//   final raw = await tts.getLanguages;
//   final tags = (raw as List<dynamic>).map((e) => e.toString()).toList();
//   final r = resolveTtsLanguage(tags, 'ur');
//   if (r.locale != null) await tts.setLanguage(r.locale!);
//   if (r.usedFallback) { /* show voiceUiText('ttsFallback', lang) */ }

/// Per-language voice configuration. Extend THIS table when adding a
/// language — never hardcode locale strings at call sites.
class VoiceLocale {
  const VoiceLocale({
    required this.lang,
    required this.nativeName,
    required this.englishName,
    required this.isRtl,
    required this.sttLocaleCandidates,
    required this.ttsLanguageCandidates,
    this.fallbackLang = 'en',
  });

  /// Short language code ('ur', 'en', …) — matches SpokenLanguage.code.
  final String lang;

  /// User-facing label in the language's own script.
  final String nativeName;

  /// Label for English-speaking admins / logs.
  final String englishName;

  /// Whether transcripts in this language render right-to-left.
  final bool isRtl;

  /// speech_to_text locale ids to try, best first (underscore AND hyphen
  /// variants — engines disagree).
  final List<String> sttLocaleCandidates;

  /// flutter_tts BCP-47 tags to try, best first.
  final List<String> ttsLanguageCandidates;

  /// Language to fall back to when no candidate is available on-device
  /// (regional languages fall to Urdu, Urdu/Arabic fall to English).
  final String fallbackLang;
}

/// The fleet's supported spoken languages.
const Map<String, VoiceLocale> kVoiceLocales = {
  'en': VoiceLocale(
    lang: 'en',
    nativeName: 'English',
    englishName: 'English',
    isRtl: false,
    sttLocaleCandidates: ['en_US', 'en_GB', 'en_IN', 'en'],
    ttsLanguageCandidates: ['en-US', 'en-GB', 'en-IN', 'en'],
  ),
  'ur': VoiceLocale(
    lang: 'ur',
    nativeName: 'اردو',
    englishName: 'Urdu',
    isRtl: true,
    sttLocaleCandidates: ['ur_PK', 'ur-PK', 'ur_IN', 'ur'],
    ttsLanguageCandidates: ['ur-PK', 'ur-IN', 'ur'],
  ),
  'ar': VoiceLocale(
    lang: 'ar',
    nativeName: 'العربية',
    englishName: 'Arabic',
    isRtl: true,
    sttLocaleCandidates: ['ar_AE', 'ar_SA', 'ar_EG', 'ar'],
    ttsLanguageCandidates: ['ar-AE', 'ar-SA', 'ar-EG', 'ar'],
  ),
  'pa': VoiceLocale(
    lang: 'pa',
    nativeName: 'پنجابی',
    englishName: 'Punjabi',
    isRtl: true, // Shahmukhi (Pakistani audience)
    sttLocaleCandidates: ['pa_PK', 'pa_Arab_PK', 'pa_IN', 'pa'],
    ttsLanguageCandidates: ['pa-PK', 'pa-IN', 'pa'],
    fallbackLang: 'ur',
  ),
  'sd': VoiceLocale(
    lang: 'sd',
    nativeName: 'سنڌي',
    englishName: 'Sindhi',
    isRtl: true,
    sttLocaleCandidates: ['sd_PK', 'sd_IN', 'sd'],
    ttsLanguageCandidates: ['sd-PK', 'sd-IN', 'sd'],
    fallbackLang: 'ur',
  ),
  'ps': VoiceLocale(
    lang: 'ps',
    nativeName: 'پښتو',
    englishName: 'Pashto',
    isRtl: true,
    sttLocaleCandidates: ['ps_AF', 'ps_PK', 'ps'],
    ttsLanguageCandidates: ['ps-AF', 'ps-PK', 'ps'],
    fallbackLang: 'ur',
  ),
  'bal': VoiceLocale(
    lang: 'bal',
    nativeName: 'بلۏچی',
    englishName: 'Balochi',
    isRtl: true,
    sttLocaleCandidates: ['bal_PK', 'bal'],
    ttsLanguageCandidates: ['bal-PK', 'bal'],
    fallbackLang: 'ur',
  ),
  // IL coach locales beyond the maps core set:
  'tr': VoiceLocale(
    lang: 'tr',
    nativeName: 'Türkçe',
    englishName: 'Turkish',
    isRtl: false,
    sttLocaleCandidates: ['tr_TR', 'tr-TR', 'tr'],
    ttsLanguageCandidates: ['tr-TR', 'tr'],
  ),
  'ru': VoiceLocale(
    lang: 'ru',
    nativeName: 'Русский',
    englishName: 'Russian',
    isRtl: false,
    sttLocaleCandidates: ['ru_RU', 'ru-RU', 'ru'],
    ttsLanguageCandidates: ['ru-RU', 'ru'],
  ),
  'es': VoiceLocale(
    lang: 'es',
    nativeName: 'Español',
    englishName: 'Spanish',
    isRtl: false,
    sttLocaleCandidates: ['es_ES', 'es_MX', 'es-ES', 'es'],
    ttsLanguageCandidates: ['es-ES', 'es-MX', 'es'],
  ),
};

/// Table lookup tolerant of full locale tags ('ur_PK', 'ur-PK' → 'ur').
/// Unknown languages resolve to English.
VoiceLocale voiceLocaleFor(String? lang) {
  if (lang == null || lang.isEmpty) return kVoiceLocales['en']!;
  final key = lang.split(RegExp('[-_]')).first.toLowerCase();
  return kVoiceLocales[key] ?? kVoiceLocales['en']!;
}

/// Result of resolving a requested language against what the engine
/// actually offers.
class VoiceLocaleResolution {
  const VoiceLocaleResolution({
    this.locale,
    required this.lang,
    required this.usedFallback,
  });

  /// The engine's OWN id/tag (exact casing) to pass to the plugin, or
  /// null when nothing usable was found (let the engine default).
  final String? locale;

  /// Language the resolved locale actually speaks.
  final String lang;

  /// True when the requested language could not be honored and a
  /// fallback-chain language was used instead — surface a notice.
  final bool usedFallback;
}

String _norm(String s) => s.trim().toLowerCase().replaceAll('-', '_');

String? _pickFrom(List<String> candidates, List<String> available) {
  final normAvail = <String, String>{
    for (final a in available) _norm(a): a,
  };
  // Pass 1: exact candidate match (case/separator-insensitive), keeping
  // the engine's own casing.
  for (final c in candidates) {
    final hit = normAvail[_norm(c)];
    if (hit != null) return hit;
  }
  // Pass 2: any engine entry whose language subtag matches.
  final langs = candidates.map((c) => _norm(c).split('_').first).toSet();
  for (final a in available) {
    if (langs.contains(_norm(a).split('_').first)) return a;
  }
  return null;
}

VoiceLocaleResolution _resolve(
  List<String> available,
  String lang,
  List<String> Function(VoiceLocale) candidatesOf,
) {
  var vl = voiceLocaleFor(lang);
  final direct = _pickFrom(candidatesOf(vl), available);
  if (direct != null) {
    return VoiceLocaleResolution(
      locale: direct,
      lang: vl.lang,
      usedFallback: false,
    );
  }
  // Fallback chain: requested → its fallbackLang → … → en.
  final seen = <String>{vl.lang};
  while (!seen.contains(vl.fallbackLang)) {
    vl = voiceLocaleFor(vl.fallbackLang);
    seen.add(vl.lang);
    final hit = _pickFrom(candidatesOf(vl), available);
    if (hit != null) {
      return VoiceLocaleResolution(
        locale: hit,
        lang: vl.lang,
        usedFallback: true,
      );
    }
  }
  return VoiceLocaleResolution(locale: null, lang: vl.lang, usedFallback: true);
}

/// Resolve the best speech_to_text locale id for [lang] from the ids the
/// engine reported via `SpeechToText.locales()`.
VoiceLocaleResolution resolveSttLocale(
  List<String> availableLocaleIds,
  String lang,
) =>
    _resolve(availableLocaleIds, lang, (v) => v.sttLocaleCandidates);

/// Resolve the best flutter_tts language tag for [lang] from the tags
/// the engine reported via `FlutterTts.getLanguages`.
VoiceLocaleResolution resolveTtsLanguage(
  List<String> availableLanguages,
  String lang,
) =>
    _resolve(availableLanguages, lang, (v) => v.ttsLanguageCandidates);

/// Whether transcripts for [lang] should render right-to-left.
bool isRtlVoiceLang(String? lang) => voiceLocaleFor(lang).isRtl;

/// True when [text] is predominantly Arabic-script (Urdu / Arabic /
/// Sindhi / Pashto / Balochi). Use it to set textDirection on transcript
/// Text widgets — Flutter's default is the ambient (usually LTR) one.
bool looksRtlText(String text) {
  var rtl = 0;
  var ltr = 0;
  for (final c in text.codeUnits) {
    if ((c >= 0x0600 && c <= 0x06FF) || // Arabic
        (c >= 0x0750 && c <= 0x077F) || // Arabic Supplement
        (c >= 0xFB50 && c <= 0xFEFF)) { // Presentation forms
      rtl++;
    } else if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
      ltr++;
    }
  }
  return rtl > 0 && rtl >= ltr;
}

/// Bilingual strings for the common voice-surface statuses. English +
/// Urdu everywhere, Arabic for the UAE-facing apps. Regional languages
/// (pa/sd/ps/bal) read the Urdu string — their users read Urdu script.
const Map<String, Map<String, String>> kVoiceUiStrings = {
  'ready': {'en': 'Ready', 'ur': 'تیار', 'ar': 'جاهز'},
  'listening': {'en': 'Listening…', 'ur': 'سن رہا ہوں…', 'ar': 'أستمع…'},
  'tapToSpeak': {
    'en': 'Tap to speak',
    'ur': 'بولنے کے لیے دبائیں',
    'ar': 'اضغط للتحدث',
  },
  'holdToTalk': {
    'en': 'Hold to talk',
    'ur': 'بولنے کے لیے دبائے رکھیں',
    'ar': 'اضغط باستمرار للتحدث',
  },
  'releaseToAsk': {
    'en': 'Release to ask',
    'ur': 'سوال کے لیے چھوڑ دیں',
    'ar': 'اترك للسؤال',
  },
  'thinking': {'en': 'Thinking…', 'ur': 'سوچ رہا ہوں…', 'ar': 'أفكر…'},
  'speaking': {'en': 'Speaking…', 'ur': 'بول رہا ہوں…', 'ar': 'أتحدث…'},
  'didNotCatch': {
    'en': "Didn't catch that — try again.",
    'ur': 'کچھ سنائی نہیں دیا — دوبارہ کوشش کریں۔',
    'ar': 'لم أسمع شيئًا — حاول مرة أخرى.',
  },
  'setupNeeded': {
    'en': 'Voice setup needed',
    'ur': 'آواز کی ترتیب درکار ہے',
    'ar': 'يلزم إعداد الصوت',
  },
  'micPermission': {
    'en': 'Microphone permission needed.',
    'ur': 'مائیکروفون کی اجازت درکار ہے۔',
    'ar': 'إذن الميكروفون مطلوب.',
  },
  'tryAgain': {
    'en': 'Please try again.',
    'ur': 'براہ کرم دوبارہ کوشش کریں۔',
    'ar': 'يرجى المحاولة مرة أخرى.',
  },
  'typeInstead': {
    'en': 'Or type your question…',
    'ur': 'یا اپنا سوال لکھیں…',
    'ar': 'أو اكتب سؤالك…',
  },
  'ttsFallback': {
    'en': 'This language\'s voice is not installed — using another voice.',
    'ur': 'اس زبان کی آواز انسٹال نہیں ہے — دوسری آواز استعمال ہو رہی ہے۔',
    'ar': 'صوت هذه اللغة غير مثبت — يتم استخدام صوت آخر.',
  },
};

/// Localized voice-UI string for [key]. Falls back RTL-regional → Urdu,
/// anything else → English, unknown key → the key itself.
String voiceUiText(String key, String? lang) {
  final m = kVoiceUiStrings[key];
  if (m == null) return key;
  final vl = voiceLocaleFor(lang);
  return m[vl.lang] ?? (vl.isRtl ? m['ur'] : null) ?? m['en'] ?? key;
}
