import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/iot/iot_frame.dart';

void main() {
  test('round-trip JSON envelope under 200 bytes', () {
    final f = const IotFrame(
      id: 'abcd1234',
      kind: IotFrameKind.alert,
      bearer: IotBearer.rfHttp,
      body: 'gate_open',
      meta: {'device': '433-1'},
    );
    final line = f.encodeLine();
    expect(line.length, lessThanOrEqualTo(200));
    final back = IotFrame.decode(line, defaultBearer: IotBearer.plain);
    expect(back?.id, 'abcd1234');
    expect(back?.body, 'gate_open');
    expect(back?.kind, IotFrameKind.alert);
  });

  test('legacy plain text wraps as telemetry', () {
    final f = IotFrame.decode('SENSOR:42', defaultBearer: IotBearer.loraBle);
    expect(f?.bearer, IotBearer.loraBle);
    expect(f?.body, 'SENSOR:42');
    expect(f?.kind, IotFrameKind.telemetry);
  });

  test('ack frame references inbound id', () {
    final inbound = const IotFrame(
      id: 'in111111',
      kind: IotFrameKind.alert,
      bearer: IotBearer.loraBle,
      body: 'ping',
    );
    final ack = IotFrame.ack(
      inbound: inbound,
      code: 'ACK',
      bearer: IotBearer.loraBle,
    );
    expect(ack.kind, IotFrameKind.ack);
    expect(ack.ackFor, 'in111111');
    expect(ack.body, 'ACK');
  });
}
