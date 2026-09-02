// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/services/field_probe_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('recordTx then recordRx computes latency for same bearer', () async {
    final svc = FieldProbeService.instance;
    await svc.clear();
    await svc.recordTx(bearer: 'lan', detail: 'thread-a');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final latency = await svc.recordRx(bearer: 'lan', detail: 'hello');
    expect(latency, isNotNull);
    expect(latency!, greaterThanOrEqualTo(0));

    final recent = await svc.recent(limit: 5);
    expect(recent.length, 2);
    expect(recent.first.direction, 'rx');
    expect(recent.first.latencyMs, isNotNull);
  });

  test('kFieldTestWaves cover P3 wave case ids', () {
    expect(kFieldTestWaves.length, greaterThanOrEqualTo(3));
    final wave1 = kFieldTestWaves.firstWhere((w) => w.id == 'wave1');
    expect(wave1.caseIds, contains('RF-BLE-1'));
    expect(wave1.caseIds, contains('RF-LAN-1'));

    final wave2 = kFieldTestWaves.firstWhere((w) => w.id == 'wave2');
    expect(wave2.caseIds, contains('RF-BLE-CHAT-1'));
    expect(wave2.caseIds, contains('RF-LAN-CHAT-1'));

    final wave3 = kFieldTestWaves.firstWhere((w) => w.id == 'wave3');
    expect(wave3.caseIds, contains('RF-LORA-E2E-1'));
  });

  test('FieldProbeEvent round-trips JSON', () {
    final event = FieldProbeEvent(
      id: 'tx-1',
      caseId: 'RF-LAN-1',
      bearer: 'lan',
      direction: 'tx',
      at: DateTime.utc(2026, 9, 1, 12),
      detail: 'probe',
    );
    final restored = FieldProbeEvent.fromJson(event.toJson());
    expect(restored.id, 'tx-1');
    expect(restored.caseId, 'RF-LAN-1');
    expect(restored.bearer, 'lan');
  });
}
