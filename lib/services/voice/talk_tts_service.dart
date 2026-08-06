// Talk TTS — read-aloud for chat messages (Lifestyle tts_il donor).
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/voice/voice_locale.dart';

class TalkTtsService extends ChangeNotifier {
  TalkTtsService._();
  static final TalkTtsService instance = TalkTtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _speaking = false;
  List<String> _languages = const [];

  bool get isSpeaking => _speaking;

  Future<void> initialize() async {
    if (_ready) return;
    _tts.setStartHandler(() {
      _speaking = true;
      notifyListeners();
    });
    _tts.setCompletionHandler(() {
      _speaking = false;
      notifyListeners();
    });
    _tts.setCancelHandler(() {
      _speaking = false;
      notifyListeners();
    });
    _tts.setErrorHandler((_) {
      _speaking = false;
      notifyListeners();
    });
    try {
      final raw = await _tts.getLanguages;
      if (raw is List) {
        _languages = raw.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {
      _languages = const [];
    }
    await _tts.setSpeechRate(0.5);
    // Make speak() resolve only when the utterance finishes — lets the
    // caller sequence/stop cleanly and keeps `_speaking` in step with the
    // engine on Android (where speak() is otherwise fire-and-forget).
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {/* not supported on every platform — best-effort */}
    _ready = true;
  }

  Future<void> speak(String text, {required String appLang}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await initialize();
    final resolved = resolveTtsLanguage(_languages, appLang);
    if (resolved.locale != null) {
      await _tts.setLanguage(resolved.locale!);
    }
    if (_speaking) await _tts.stop();
    await _tts.speak(trimmed);
  }

  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
    notifyListeners();
  }
}
