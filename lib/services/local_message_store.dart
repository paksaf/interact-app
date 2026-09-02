// SPDX-License-Identifier: AGPL-3.0
//
// Hive-backed per-thread message cache. Migrates legacy SharedPreferences
// rows on first read (talk_local_msgs_v1_* → talk_msgs_hive_v1 box).

import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalMessageStore {
  LocalMessageStore._();
  static final LocalMessageStore instance = LocalMessageStore._();

  static const _boxName = 'talk_msgs_hive_v1';
  static const _legacyPrefix = 'talk_local_msgs_v1_';
  static const _migratedFlag = 'talk_msgs_hive_migrated_v1';

  Box<String>? _box;

  Future<void> ensureInitialized() async {
    if (_box != null && _box!.isOpen) return;
    _box = await Hive.openBox<String>(_boxName);
    await _migrateLegacyOnce();
  }

  Future<List<Map<String, dynamic>>> loadThread(String threadId) async {
    await ensureInitialized();
    final raw = _box!.get(threadId);
    if (raw == null || raw.isEmpty) {
      return await _pullLegacyThread(threadId);
    }
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveThread(
    String threadId,
    List<Map<String, dynamic>> rows,
  ) async {
    await ensureInitialized();
    await _box!.put(threadId, jsonEncode(rows));
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_legacyPrefix$threadId');
  }

  Future<void> _migrateLegacyOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_migratedFlag) == true) return;
    final keys = prefs.getKeys().where((k) => k.startsWith(_legacyPrefix));
    for (final key in keys) {
      final threadId = key.substring(_legacyPrefix.length);
      if (threadId.isEmpty) continue;
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) continue;
      await _box!.put(threadId, raw);
      await prefs.remove(key);
    }
    await prefs.setBool(_migratedFlag, true);
  }

  Future<List<Map<String, dynamic>>> _pullLegacyThread(String threadId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_legacyPrefix$threadId');
    if (raw == null || raw.isEmpty) return const [];
    await _box!.put(threadId, raw);
    await prefs.remove('$_legacyPrefix$threadId');
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
