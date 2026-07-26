// SPDX-License-Identifier: AGPL-3.0
//
// Offline store-and-forward outbox — ported from Interact Maps OutboxService
// (2026-07-16 donor). JSON POSTs only; Talk uses this for chat text sends when
// the device is offline so messages deliver once connectivity returns.
//
// Queue key is Talk-specific so Maps and Talk never share a backlog.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  static const _key = 'talk_outbox_queue_v1';
  static const _maxItems = 200;
  static const _maxAgeMs = 48 * 60 * 60 * 1000; // 48 h
  static const _flushEvery = Duration(seconds: 60);
  static const _postTimeout = Duration(seconds: 8);

  Timer? _timer;
  bool _flushing = false;
  final _changed = StreamController<int>.broadcast();

  /// Fires with pending count after enqueue/flush.
  Stream<int> get changes => _changed.stream;

  void startAutoFlush() {
    _timer ??= Timer.periodic(_flushEvery, (_) => flush());
  }

  void stopAutoFlush() {
    _timer?.cancel();
    _timer = null;
  }

  Future<bool> postOrQueue({
    required String url,
    required Map<String, dynamic> body,
    Map<String, String>? headers,
    String kind = 'generic',
  }) async {
    final ok = await _post(url, body, headers);
    if (ok) {
      unawaited(flush());
      return true;
    }
    await enqueue(url: url, body: body, headers: headers, kind: kind);
    return false;
  }

  Future<void> enqueue({
    required String url,
    required Map<String, dynamic> body,
    Map<String, String>? headers,
    String kind = 'generic',
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _read(prefs);
      list.add({
        'id': DateTime.now().microsecondsSinceEpoch.toString(),
        'url': url,
        'body': body,
        if (headers != null && headers.isNotEmpty) 'headers': headers,
        'kind': kind,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
      });
      await prefs.setString(_key, jsonEncode(_prune(list)));
      _changed.add(list.length);
    } catch (e) {
      if (kDebugMode) debugPrint('Talk outbox enqueue failed: $e');
    }
  }

  Future<int> flush() async {
    if (_flushing) return 0;
    _flushing = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = _read(prefs);
      if (list.isEmpty) return 0;
      final kept = <Map<String, dynamic>>[];
      var sent = 0;
      for (final item in list) {
        final url = item['url'] as String?;
        final body = (item['body'] as Map?)?.cast<String, dynamic>();
        if (url == null || body == null) continue;
        final headers = (item['headers'] as Map?)?.cast<String, String>();
        final ok = await _post(url, body, headers);
        if (ok) {
          sent++;
        } else {
          item['attempts'] = ((item['attempts'] as num?)?.toInt() ?? 0) + 1;
          kept.add(item);
        }
      }
      await prefs.setString(_key, jsonEncode(_prune(kept)));
      _changed.add(kept.length);
      return sent;
    } catch (e) {
      if (kDebugMode) debugPrint('Talk outbox flush failed: $e');
      return 0;
    } finally {
      _flushing = false;
    }
  }

  Future<int> pendingCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _read(prefs).length;
    } catch (_) {
      return 0;
    }
  }

  List<Map<String, dynamic>> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      }
    } catch (_) {}
    return [];
  }

  List<Map<String, dynamic>> _prune(List<Map<String, dynamic>> list) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _maxAgeMs;
    var out = list
        .where((e) => ((e['ts'] as num?)?.toInt() ?? 0) >= cutoff)
        .toList();
    if (out.length > _maxItems) {
      out = out.sublist(out.length - _maxItems);
    }
    return out;
  }

  Future<bool> _post(
    String url,
    Map<String, dynamic> body,
    Map<String, String>? headers,
  ) async {
    try {
      final resp = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json', ...?headers},
            body: jsonEncode(body),
          )
          .timeout(_postTimeout);
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
