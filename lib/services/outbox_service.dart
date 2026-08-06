// SPDX-License-Identifier: AGPL-3.0
//
// Offline store-and-forward outbox — ported from Interact Maps OutboxService
// (2026-07-16 donor). JSON POSTs for text; attachment items use a flush
// handler that uploads local files then POSTs the message.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional handler for kinds that need more than a JSON POST (e.g. upload).
typedef OutboxItemHandler = Future<bool> Function(Map<String, dynamic> item);

class OutboxService {
  OutboxService._();
  static final OutboxService instance = OutboxService._();

  static const _key = 'talk_outbox_queue_v1';
  static const _maxItems = 200;
  static const _maxAgeMs = 48 * 60 * 60 * 1000; // 48 h
  static const _flushEvery = Duration(seconds: 15);
  static const _postTimeout = Duration(seconds: 8);

  Timer? _timer;
  bool _flushing = false;
  final _changed = StreamController<int>.broadcast();

  /// Wired from ChatApi so attachment flush can call uploadMedia + send.
  OutboxItemHandler? attachmentHandler;

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
    String? localPath,
    String? threadId,
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
        if (localPath != null) 'localPath': localPath,
        if (threadId != null) 'threadId': threadId,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
      });
      await prefs.setString(_key, jsonEncode(_prune(list)));
      _changed.add(list.length);
    } catch (e) {
      if (kDebugMode) debugPrint('Talk outbox enqueue failed: $e');
    }
  }

  /// Persist a local attachment for later upload+send when online.
  Future<void> enqueueAttachment({
    required String threadId,
    required File file,
    String caption = '',
    Map<String, String>? headers,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/talk_outbox_media');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final ext = file.path.contains('.') ? file.path.split('.').last : 'bin';
    final dest = File(
      '${outDir.path}/${DateTime.now().microsecondsSinceEpoch}.$ext',
    );
    await file.copy(dest.path);
    await enqueue(
      url: 'attachment://$threadId',
      body: {'body': caption, 'attachment': ''},
      headers: headers,
      kind: 'chat_attach_local',
      localPath: dest.path,
      threadId: threadId,
    );
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
        final kind = (item['kind'] as String?) ?? 'generic';
        var ok = false;
        if (kind == 'chat_attach_local' && attachmentHandler != null) {
          ok = await attachmentHandler!(item);
        } else {
          final url = item['url'] as String?;
          final body = (item['body'] as Map?)?.cast<String, dynamic>();
          if (url == null || body == null || url.startsWith('attachment://')) {
            kept.add(item);
            continue;
          }
          final headers = (item['headers'] as Map?)?.cast<String, String>();
          ok = await _post(url, body, headers);
        }
        if (ok) {
          sent++;
          final path = item['localPath'] as String?;
          if (path != null) {
            try {
              await File(path).delete();
            } catch (_) {}
          }
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
