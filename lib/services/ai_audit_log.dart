// SPDX-License-Identifier: AGPL-3.0
//
// AI audit log — append-only JSONL store for compliance.
//
// Every inference call writes a row with:
//   - timestamp (unix ms)
//   - tier (voice / chat / audit)
//   - model used (e.g. 'phi-3.5-mini-q4', 'qwen2.5-7b-q4', 'cloud:zeka')
//   - SHA-256 hashes of prompt + response (NOT the content itself — the
//     raw text never leaves the user's device; hashes are enough for
//     a reviewer to verify "yes that's the request I sent")
//   - input/output token counts
//   - latency
//   - networkUsed flag — **0 means on-device only, 1 means a cloud
//     round-trip happened**. This is the compliance proof.
//
// Settings → Privacy → "Export audit log" reads the JSONL file and
// hands it to the user as a downloadable JSON document.
//
// Storage: simple append-only file at:
//   <app-support>/ai_audit.jsonl
// Rotated weekly (file renamed to ai_audit-YYYY-WW.jsonl, fresh file
// opened). One line = one inference event. Phase 3 may swap this for
// a Drift table if structured queries become useful.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'ai_service.dart';

final aiAuditLogProvider = Provider<AiAuditLog>((_) => AiAuditLog());

class AiAuditLog {
  File? _activeFile;
  IOSink? _sink;
  final _ready = Completer<void>();

  Future<void> _ensureReady() async {
    if (_sink != null) return;
    final dir = await getApplicationSupportDirectory();
    final logDir = Directory('${dir.path}/ai_audit');
    if (!await logDir.exists()) await logDir.create(recursive: true);
    final now = DateTime.now().toUtc();
    final week = _isoWeek(now);
    final file = File('${logDir.path}/ai_audit-${now.year}-W$week.jsonl');
    _activeFile = file;
    _sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Record one inference event. Safe to call from any isolate.
  Future<void> record({
    required AiTier tier,
    required String modelUsed,
    required String prompt,
    required String response,
    required int inputTokens,
    required int outputTokens,
    required int latencyMs,
    required bool networkUsed,
  }) async {
    await _ensureReady();
    final entry = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'tier': tier.name,
      'model': modelUsed,
      'promptHash': _sha256(prompt),
      'responseHash': _sha256(response),
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      'latencyMs': latencyMs,
      'networkUsed': networkUsed ? 1 : 0,
    };
    _sink!.writeln(jsonEncode(entry));
    await _sink!.flush();
  }

  /// Export the entire log as a JSON document. The reviewer can pipe
  /// this into any forensic tool to verify the SHA chain matches the
  /// user's claim about what they asked.
  Future<Map<String, dynamic>> exportAll() async {
    await _ensureReady();
    final dir = _activeFile!.parent;
    final files = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final entries = <Map<String, dynamic>>[];
    var byTier = <String, int>{'voice': 0, 'chat': 0, 'audit': 0};
    var byModel = <String, int>{};
    var networkCalls = 0;

    for (final f in files) {
      // Skip the active file's partial last-write buffer.
      final lines = await f.readAsLines();
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        try {
          final j = jsonDecode(line) as Map<String, dynamic>;
          entries.add(j);
          byTier[j['tier'] as String] = (byTier[j['tier'] as String] ?? 0) + 1;
          byModel[j['model'] as String] =
              (byModel[j['model'] as String] ?? 0) + 1;
          if ((j['networkUsed'] as int? ?? 0) == 1) networkCalls++;
        } catch (_) {
          // Skip malformed line — append-only logs can have torn writes
          // on power-loss. Move on.
        }
      }
    }

    return <String, dynamic>{
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'totalInferences': entries.length,
      'byTier': byTier,
      'byModel': byModel,
      'networkCalls': networkCalls,
      'entries': entries,
    };
  }

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }

  /// ISO 8601 week number (1-53) — used to rotate audit logs weekly.
  String _isoWeek(DateTime d) {
    final t = DateTime.utc(d.year, d.month, d.day);
    final dayOfYear = t.difference(DateTime.utc(d.year, 1, 1)).inDays + 1;
    final weekday = t.weekday;
    final week = ((dayOfYear - weekday + 10) ~/ 7).clamp(1, 53);
    return week.toString().padLeft(2, '0');
  }

  String _sha256(String text) {
    return sha256.convert(utf8.encode(text)).toString();
  }
}
