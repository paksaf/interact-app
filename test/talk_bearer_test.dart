import 'package:flutter_test/flutter_test.dart';
import 'package:interact/models/talk_bearer.dart';

void main() {
  test('TalkBearer wire roundtrip', () {
    expect(TalkBearer.fromWire('lan'), TalkBearer.lan);
    expect(TalkBearer.bleMesh.label, 'BLE mesh');
  });
}
