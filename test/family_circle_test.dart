// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/models/family_circle.dart';
import 'package:interact/services/family_circle_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('upsert and list family circle members', () async {
    final store = FamilyCircleStore.instance;
    await store.upsertMember(
      FamilyCircleMember(
        key: FamilyCircleStore.memberKey(phone: '+923001234567'),
        phone: '+923001234567',
        displayName: 'Ali',
        circle: FamilyCircleKind.family,
        addedAt: DateTime.utc(2026, 9, 2),
      ),
    );
    final all = await store.listMembers();
    expect(all.length, 1);
    expect(all.first.displayName, 'Ali');

    await store.setCircle(all.first.key, FamilyCircleKind.closeFriend);
    final updated = await store.listByCircle(FamilyCircleKind.closeFriend);
    expect(updated.length, 1);

    await store.removeMember(all.first.key);
    expect(await store.listMembers(), isEmpty);
  });
}
