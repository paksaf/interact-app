// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/services/location_trace_service.dart';
import 'package:interact/utils/shared_location_pin.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('parseSharedLocationPin handles compact loc: wire form', () {
    const body = '📍 Live location\nloc:31.52040,74.35870';
    final pin = parseSharedLocationPin(body);
    expect(pin, isNotNull);
    expect(pin!.lat, closeTo(31.52040, 0.0001));
    expect(pin.lng, closeTo(74.35870, 0.0001));
    expect(pin.live, isTrue);
  });

  test('formatLocationPinBody round-trips through parser', () {
    final body = formatLocationPinBody(lat: 30.15, lng: 71.52, live: false);
    final pin = parseSharedLocationPin(body);
    expect(pin, isNotNull);
    expect(pin!.lat, closeTo(30.15, 0.001));
    expect(pin.lng, closeTo(71.52, 0.001));
  });

  test('parseIotGpsMeta reads lat/lng aliases', () {
    final gps = parseIotGpsMeta({
      'latitude': 31.5,
      'longitude': 74.3,
      'accuracy': 8,
      'device': 'tracker-1',
    });
    expect(gps, isNotNull);
    expect(gps!.lat, 31.5);
    expect(gps.accuracyM, 8);
  });

  test('LocationTraceService records message body fix', () async {
    final svc = LocationTraceService.instance;
    await svc.clear();
    await svc.recordFromMessageBody(
      body: formatLocationPinBody(lat: 33.68, lng: 73.04),
      senderId: 'peer-1',
      senderName: 'Ali',
      threadId: 'thread-x',
    );
    final fix = svc.latestFor('peer-1');
    expect(fix, isNotNull);
    expect(fix!.displayName, 'Ali');
    expect(fix.lat, closeTo(33.68, 0.01));
  });
}
