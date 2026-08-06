// SPDX-License-Identifier: AGPL-3.0
//
// TranscriptionService — the HYBRID voice-note transcription router for
// INTERACT Talk. Architected hybrid-from-day-one (roadmap review #2):
//
//   preferOnDevice → whisper.cpp ON-DEVICE when available
//                  → ELSE cloud (Deepgram) via /api/v1/talk/transcribe
//
// On-device ASR is NOT implemented yet — [_onDeviceAsrAvailable] is a hard
// `false` capability gate, so every call currently takes the cloud path. When
// a whisper.cpp Flutter binding lands, flip that gate + implement
// [_transcribeOnDevice] and NO UI change is needed: callers only ever see a
// [TranscriptionResult] (with `source` telling them which engine ran) or catch
// a [TranscriptionException]. Same shape whether on-device or cloud.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'talk_api.dart';

/// Result of a transcription, regardless of which engine produced it.
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    required this.source, // "on-device" | "cloud"
    this.confidence,
    this.language,
    this.durationMs,
  });
  final String text;
  final String source;
  final double? confidence;
  final String? language;
  final int? durationMs;
}

/// Typed failure the UI catches to show a fail-soft message. [code] mirrors the
/// backend error codes (NO_AUDIO | NOT_CONFIGURED | RATE_LIMITED |
/// TRANSCRIBE_FAILED) plus a client-side `NETWORK` for connectivity failures.
class TranscriptionException implements Exception {
  const TranscriptionException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'TranscriptionException($code): $message';
}

final transcriptionServiceProvider = Provider<TranscriptionService>((ref) {
  return TranscriptionService(ref.read(talkApiProvider));
});

class TranscriptionService {
  TranscriptionService(this._talk);
  final TalkApi _talk;

  /// Whisper.cpp on-device ASR — NOT wired yet. Hard `false` today; flip when
  /// the Flutter binding exists (it can then consult device RAM / downloaded
  /// models without changing any caller).
  bool get _onDeviceAsrAvailable => false;

  /// Transcribe the voice note at [audioUrl]. Routes on-device first when
  /// [preferOnDevice] and a local model is available; otherwise cloud.
  /// Throws [TranscriptionException] on failure (fail-soft — callers catch it).
  Future<TranscriptionResult> transcribe(
    String audioUrl, {
    String? language,
    bool preferOnDevice = true,
  }) async {
    if (preferOnDevice && _onDeviceAsrAvailable) {
      // return _transcribeOnDevice(audioUrl, language); // future: whisper.cpp
    }
    return _transcribeCloud(audioUrl, language: language, preferOnDevice: preferOnDevice);
  }

  Future<TranscriptionResult> _transcribeCloud(
    String audioUrl, {
    String? language,
    required bool preferOnDevice,
  }) async {
    try {
      final r = await _talk.transcribeVoiceNote(
        audioUrl,
        language: language,
        preferOnDevice: preferOnDevice,
      );
      return TranscriptionResult(
        text: r.text,
        source: r.source,
        confidence: r.confidence,
        language: r.language,
        durationMs: r.durationMs,
      );
    } on TalkTranscribeError catch (e) {
      // Map the backend error code straight through so the UI can be precise.
      throw TranscriptionException(e.code, e.message);
    } on TimeoutException {
      throw const TranscriptionException('NETWORK', 'Transcription timed out.');
    } catch (e) {
      // Socket/DNS/other network errors — never leak the raw exception.
      throw TranscriptionException('NETWORK', e.toString());
    }
  }
}
