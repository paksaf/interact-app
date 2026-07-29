import 'package:flutter_test/flutter_test.dart';
import 'package:interact/utils/phone_normalize.dart';

void main() {
  test('normalizes Pakistan local and E.164 phones', () {
    expect(normalizeInteractPhone('03001234567'), '+923001234567');
    expect(normalizeInteractPhone('+92 300 1234567'), '+923001234567');
    expect(normalizeInteractPhone('923001234567'), '+923001234567');
    expect(normalizeInteractPhone('3001234567'), isNull);
    expect(normalizeInteractPhone('+971501234567'), '+971501234567');
  });

  test('email plausibility', () {
    expect(isPlausibleEmail('you@example.com'), isTrue);
    expect(isPlausibleEmail('bad'), isFalse);
  });
}
