import 'package:flutter_test/flutter_test.dart';
import 'package:interact/utils/shared_location_pin.dart';

void main() {
  test('parseSharedLocationPin extracts coords and links', () {
    const body = '''
📍 Shared location
31.520400, 74.358700
Open in Maps: interactmaps://route?lat=31.520400&lng=74.358700&name=Shared%20pin
https://talk.interactpak.com/j/LOC?lat=31.520400&lng=74.358700
''';
    final pin = parseSharedLocationPin(body);
    expect(pin, isNotNull);
    expect(pin!.lat, closeTo(31.5204, 0.0001));
    expect(pin.lng, closeTo(74.3587, 0.0001));
    expect(pin.mapsDeepLink?.scheme, 'interactmaps');
    expect(pin.talkFallback?.path, '/j/LOC');
  });

  test('parseSharedLocationPin returns null for plain text', () {
    expect(parseSharedLocationPin('hello world'), isNull);
  });

  test('compactWireBody shortens full pin for BLE mesh', () {
    final full = formatLocationPinBody(lat: 31.52, lng: 74.35);
    expect(compactWireBody(full), 'loc:31.52000,74.35000');
  });
}
