// SPDX-License-Identifier: AGPL-3.0
//
// Anonymous product analytics — batched, offline-queued, fail-soft.
// NEVER attach userId, city, or message/reel content.
//
// Wire contract (POST /api/v1/analytics/events):
//   { anonId: "<uuid>", events: [ { name, props?, ts } ] }

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api_base.dart';

class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  static const _anonKey = 'talk_analytics_anon_id_v1';
  static const _queueKey = 'talk_analytics_queue_v1';
  static const _maxQueue = 500;
  static const _maxBatch = 50;
  static const _maxAgeMs = 7 * 24 * 60 * 60 * 1000;
  static const _flushEvery = Duration(seconds: 30);

  Timer? _timer;
  bool _flushing = false;
  String? _anonId;
  DateTime? _sessionStartedAt;

  Future<void> ensureStarted() async {
    await _ensureAnonId();
    _timer ??= Timer.periodic(_flushEvery, (_) => unawaited(flush()));
    unawaited(flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> trackScreenView(String screen) async {
    await _enqueue('screen_view', {'screen': _sanitizeScreen(screen)});
  }

  Future<void> trackFeatureUse(String feature) async {
    await _enqueue('feature_use', {'feature': feature});
  }

  Future<void> trackSessionStart() async {
    _sessionStartedAt = DateTime.now().toUtc();
    await _enqueue('session_start', const {});
  }

  Future<void> trackSessionEnd({int? durationSec}) async {
    final started = _sessionStartedAt;
    final dur = durationSec ??
        (started == null
            ? null
            : DateTime.now().toUtc().difference(started).inSeconds);
    _sessionStartedAt = null;
    final props = <String, dynamic>{};
    if (dur != null) props['durationSec'] = dur.clamp(0, 86400);
    await _enqueue('session_end', props);
    unawaited(flush());
  }

  /// Translate one queued row → backend event shape. Handles legacy rows that
  /// used `type` + flat keys before the wire-contract fix.
  static Map<String, dynamic> wireEventFromQueued(Map<String, dynamic> raw) {
    final name = (raw['name'] as String?) ?? (raw['type'] as String?);
    if (name == null || name.isEmpty) {
      throw ArgumentError('analytics event missing name/type');
    }
    final props = raw['props'] is Map
        ? Map<String, dynamic>.from(raw['props'] as Map)
        : <String, dynamic>{};
    for (final key in ['screen', 'feature', 'durationSec']) {
      if (raw.containsKey(key) && raw[key] != null) {
        props.putIfAbsent(key, () => raw[key]);
      }
    }
    return {
      'name': name,
      'props': props,
      'ts': raw['ts'],
    };
  }

  /// Build the POST body the backend expects (top-level anonId + wire events).
  static Map<String, dynamic> buildPostBody({
    required String anonId,
    required List<Map<String, dynamic>> queued,
  }) {
    return {
      'anonId': anonId,
      'events': queued.map(wireEventFromQueued).toList(),
    };
  }

  /// Visible for tests — trim stale rows from [raw] queue JSON.
  static List<Map<String, dynamic>> trimQueueForTest(
    List<Map<String, dynamic>> raw, {
    required int nowMs,
    int maxItems = _maxQueue,
    int maxAgeMs = _maxAgeMs,
  }) {
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      final ts = DateTime.tryParse(item['ts'] as String? ?? '');
      if (ts == null) continue;
      if (nowMs - ts.millisecondsSinceEpoch > maxAgeMs) continue;
      out.add(item);
    }
    if (out.length > maxItems) {
      return out.sublist(out.length - maxItems);
    }
    return out;
  }

  Future<void> _ensureAnonId() async {
    if (_anonId != null) return;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_anonKey);
    if (id == null || id.isEmpty) {
      id = _randomUuid();
      await prefs.setString(_anonKey, id);
    }
    _anonId = id;
  }

  Future<void> _enqueue(String name, Map<String, dynamic> props) async {
    try {
      await _ensureAnonId();
      final prefs = await SharedPreferences.getInstance();
      final raw = _readQueue(prefs);
      raw.add({
        'name': name,
        'props': props,
        'ts': DateTime.now().toUtc().toIso8601String(),
      });
      final trimmed = trimQueueForTest(
        raw,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setString(_queueKey, jsonEncode(trimmed));
    } catch (e) {
      debugPrint('[analytics] enqueue failed: $e');
    }
  }

  List<Map<String, dynamic>> _readQueue(SharedPreferences prefs) {
    final s = prefs.getString(_queueKey);
    if (s == null || s.isEmpty) return [];
    try {
      final decoded = jsonDecode(s);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _ensureAnonId();
      final prefs = await SharedPreferences.getInstance();
      var queue = _readQueue(prefs);
      if (queue.isEmpty) return;
      queue = trimQueueForTest(
        queue,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      );
      while (queue.isNotEmpty) {
        final batch = queue.take(_maxBatch).toList();
        final ok = await _postBatch(batch);
        if (!ok) break;
        queue = queue.skip(batch.length).toList();
        await prefs.setString(_queueKey, jsonEncode(queue));
      }
    } catch (e) {
      debugPrint('[analytics] flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<bool> _postBatch(List<Map<String, dynamic>> batch) async {
    try {
      final anonId = _anonId;
      if (anonId == null || anonId.isEmpty) return false;
      final body = buildPostBody(anonId: anonId, queued: batch);
      final res = await http
          .post(
            Uri.parse('${ApiBase.current}/api/v1/analytics/events'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (e) {
      debugPrint('[analytics] post failed: $e');
      return false;
    }
  }

  String _sanitizeScreen(String screen) {
    var s = screen.trim();
    if (s.isEmpty) return '/';
    if (!s.startsWith('/')) s = '/$s';
    // Drop query strings — path only, no PII in params.
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  String _randomUuid() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int b) => b.toRadixString(16).padLeft(2, '0');
    final h = bytes.map(hex).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }
}
