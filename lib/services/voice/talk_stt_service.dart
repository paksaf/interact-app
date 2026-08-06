// Talk STT — dictate into chat composer (Lifestyle voice_il donor).
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../core/voice/voice_locale.dart';

/// Lightweight speech-to-text for the chat composer.
class TalkSttService extends ChangeNotifier {
  TalkSttService._();
  static final TalkSttService instance = TalkSttService._();

  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _ready = false;
  bool _listening = false;
  String _partial = '';
  String _finalText = '';
  List<String> _localeIds = const [];

  bool get isListening => _listening;
  String get partial => _partial;
  String get finalText => _finalText;

  Future<bool> ensureMic() async {
    var mic = await Permission.microphone.status;
    if (!mic.isGranted && !mic.isLimited) {
      mic = await Permission.microphone.request();
    }
    return mic.isGranted || mic.isLimited;
  }

  Future<bool> initialize() async {
    if (_ready) return true;
    _ready = await _stt.initialize(onError: (_) {}, onStatus: (_) {});
    if (_ready) {
      try {
        _localeIds =
            (await _stt.locales()).map((l) => l.localeId).toList(growable: false);
      } catch (_) {
        _localeIds = const [];
      }
    }
    return _ready;
  }

  /// Begin dictation. Returns `true` when the engine actually started
  /// listening, `false` when unavailable (mic denied / init failed) so the
  /// caller can fail soft (reset UI + show a one-line notice). Never throws
  /// for those expected cases.
  Future<bool> start({required String appLang}) async {
    if (_listening) return true;
    if (!await ensureMic()) return false;
    if (!await initialize()) return false;

    final resolved = resolveSttLocale(_localeIds, appLang);
    final localeId = resolved.locale ?? voiceLocaleFor(appLang).sttLocaleCandidates.first;

    _partial = '';
    _finalText = '';
    _listening = true;
    notifyListeners();

    await _stt.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        partialResults: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
      ),
      onResult: (SpeechRecognitionResult r) {
        if (r.finalResult) {
          _finalText = r.recognizedWords;
          _partial = '';
          _listening = false;
        } else {
          _partial = r.recognizedWords;
        }
        notifyListeners();
      },
    );
    return true;
  }

  Future<String?> stop() async {
    await _stt.stop();
    _listening = false;
    notifyListeners();
    var text = _finalText.trim();
    if (text.isEmpty) text = _partial.trim();
    for (final wait in const [
      Duration(milliseconds: 150),
      Duration(milliseconds: 200),
      Duration(milliseconds: 250),
    ]) {
      if (text.isNotEmpty) break;
      await Future<void>.delayed(wait);
      text = _finalText.trim().isNotEmpty ? _finalText.trim() : _partial.trim();
    }
    notifyListeners();
    return text.isEmpty ? null : text;
  }

  Future<void> cancel() async {
    await _stt.cancel();
    _listening = false;
    _partial = '';
    notifyListeners();
  }
}
