// SPDX-License-Identifier: AGPL-3.0
//
// Local welcome memory — visit streak, quick notes/reminders (device-only).
// Gives the AI welcome layer continuity without a new server schema.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class WelcomeReminder {
  const WelcomeReminder({
    required this.id,
    required this.body,
    required this.dueAt,
  });

  final String id;
  final String body;
  final DateTime dueAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'body': body,
        'dueAt': dueAt.toIso8601String(),
      };

  factory WelcomeReminder.fromJson(Map<String, dynamic> j) => WelcomeReminder(
        id: j['id'] as String? ?? '',
        body: j['body'] as String? ?? '',
        dueAt: DateTime.tryParse(j['dueAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class WelcomeNote {
  const WelcomeNote({
    required this.id,
    required this.body,
    required this.updatedAt,
  });

  final String id;
  final String body;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'body': body,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory WelcomeNote.fromJson(Map<String, dynamic> j) => WelcomeNote(
        id: j['id'] as String? ?? '',
        body: j['body'] as String? ?? '',
        updatedAt:
            DateTime.tryParse(j['updatedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

class WelcomeMemory {
  const WelcomeMemory({
    required this.dayStreak,
    required this.totalOpens,
    required this.lastOpenDay,
    this.pinnedNote,
    this.reminders = const [],
  });

  final int dayStreak;
  final int totalOpens;
  final String? lastOpenDay;
  final WelcomeNote? pinnedNote;
  final List<WelcomeReminder> reminders;

  List<WelcomeReminder> get dueSoon {
    final now = DateTime.now();
    final horizon = now.add(const Duration(hours: 48));
    return reminders
        .where((r) => !r.dueAt.isBefore(now) && r.dueAt.isBefore(horizon))
        .toList()
      ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  }
}

class WelcomeMemoryStore {
  WelcomeMemoryStore._();
  static final WelcomeMemoryStore instance = WelcomeMemoryStore._();

  static const _kStreak = 'welcome.dayStreak';
  static const _kOpens = 'welcome.totalOpens';
  static const _kLastDay = 'welcome.lastOpenDay';
  static const _kNote = 'welcome.pinnedNote';
  static const _kReminders = 'welcome.reminders';

  Future<WelcomeMemory> recordAppOpen() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _dayKey(DateTime.now());
    final last = prefs.getString(_kLastDay);
    var streak = prefs.getInt(_kStreak) ?? 0;
    if (last == today) {
      // same calendar day
    } else if (last != null && _isYesterday(last, today)) {
      streak += 1;
    } else {
      streak = 1;
    }
    final opens = (prefs.getInt(_kOpens) ?? 0) + 1;
    await prefs.setInt(_kStreak, streak);
    await prefs.setInt(_kOpens, opens);
    await prefs.setString(_kLastDay, today);
    return _read(prefs, streak: streak, opens: opens, lastDay: today);
  }

  Future<WelcomeMemory> load() async {
    final prefs = await SharedPreferences.getInstance();
    return _read(prefs);
  }

  Future<void> saveNote(String body) async {
    final prefs = await SharedPreferences.getInstance();
    final note = WelcomeNote(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      body: body.trim(),
      updatedAt: DateTime.now(),
    );
    await prefs.setString(_kNote, jsonEncode(note.toJson()));
  }

  Future<void> addReminder({required String body, required DateTime dueAt}) async {
    final prefs = await SharedPreferences.getInstance();
    final mem = await load();
    final next = [
      ...mem.reminders,
      WelcomeReminder(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        body: body.trim(),
        dueAt: dueAt,
      ),
    ];
    await prefs.setString(
      _kReminders,
      jsonEncode(next.map((r) => r.toJson()).toList()),
    );
  }

  Future<WelcomeMemory> _read(
    SharedPreferences prefs, {
    int? streak,
    int? opens,
    String? lastDay,
  }) async {
    WelcomeNote? note;
    final rawNote = prefs.getString(_kNote);
    if (rawNote != null) {
      try {
        note = WelcomeNote.fromJson(
          jsonDecode(rawNote) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    var reminders = <WelcomeReminder>[];
    final rawRem = prefs.getString(_kReminders);
    if (rawRem != null) {
      try {
        final list = jsonDecode(rawRem) as List;
        reminders = list
            .whereType<Map>()
            .map((e) => WelcomeReminder.fromJson(e.cast<String, dynamic>()))
            .toList();
      } catch (_) {}
    }
    return WelcomeMemory(
      dayStreak: streak ?? prefs.getInt(_kStreak) ?? 0,
      totalOpens: opens ?? prefs.getInt(_kOpens) ?? 0,
      lastOpenDay: lastDay ?? prefs.getString(_kLastDay),
      pinnedNote: note,
      reminders: reminders,
    );
  }

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static bool _isYesterday(String last, String today) {
    try {
      final parts = last.split('-').map(int.parse).toList();
      final lastDate = DateTime(parts[0], parts[1], parts[2]);
      final todayParts = today.split('-').map(int.parse).toList();
      final todayDate = DateTime(todayParts[0], todayParts[1], todayParts[2]);
      return todayDate.difference(lastDate).inDays == 1;
    } catch (_) {
      return false;
    }
  }
}
