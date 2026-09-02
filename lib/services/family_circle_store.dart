// SPDX-License-Identifier: AGPL-3.0
//
// Local family / friend circle — curated people for social panel + tracking.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/family_circle.dart';

final familyCircleStoreProvider = Provider<FamilyCircleStore>(
  (ref) => FamilyCircleStore.instance,
);

class FamilyCircleStore {
  FamilyCircleStore._();
  static final FamilyCircleStore instance = FamilyCircleStore._();

  static const _key = 'talk.family_circles_v1';

  static String memberKey({String? userId, String? phone}) {
    if (userId != null && userId.isNotEmpty) return 'u:$userId';
    if (phone != null && phone.isNotEmpty) return 'p:$phone';
    return 'anon-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<List<FamilyCircleMember>> listMembers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => FamilyCircleMember.fromJson(e.cast<String, dynamic>()))
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));
    } catch (_) {
      return const [];
    }
  }

  Future<List<FamilyCircleMember>> listByCircle(FamilyCircleKind circle) async {
    final all = await listMembers();
    return all.where((m) => m.circle == circle).toList();
  }

  Future<void> upsertMember(FamilyCircleMember member) async {
    final all = await listMembers();
    final next = [
      member,
      ...all.where((m) => m.key != member.key),
    ];
    await _save(next);
  }

  Future<void> removeMember(String key) async {
    final all = await listMembers();
    await _save(all.where((m) => m.key != key).toList());
  }

  Future<void> setCircle(String key, FamilyCircleKind circle) async {
    final all = await listMembers();
    final next = all
        .map((m) => m.key == key ? m.copyWith(circle: circle) : m)
        .toList();
    await _save(next);
  }

  Future<void> _save(List<FamilyCircleMember> members) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(members.map((m) => m.toJson()).toList()),
    );
  }
}
