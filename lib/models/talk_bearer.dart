// SPDX-License-Identifier: AGPL-3.0
//
// Delivery bearer for Talk messages — cloud + offline radios.
// Wire codes mirror IotBearer style (lib/core/iot/iot_frame.dart).

enum TalkBearer {
  cloud('cloud'),
  lan('lan'),
  p2p('p2p'),
  bleMesh('ble'),
  lora('lora'),
  iot('iot'),
  sms('sms'),
  ai('ai'),
  pending('pending');

  const TalkBearer(this.wire);
  final String wire;

  static TalkBearer fromWire(String? s) {
    if (s == null || s.isEmpty) return TalkBearer.cloud;
    for (final b in TalkBearer.values) {
      if (b.wire == s) return b;
    }
    return TalkBearer.cloud;
  }

  String get label => switch (this) {
        TalkBearer.cloud => 'Cloud',
        TalkBearer.lan => 'LAN',
        TalkBearer.p2p => 'Direct',
        TalkBearer.bleMesh => 'BLE mesh',
        TalkBearer.lora => 'LoRa',
        TalkBearer.iot => 'IoT',
        TalkBearer.sms => 'SMS',
        TalkBearer.ai => 'AI',
        TalkBearer.pending => 'Queued',
      };
}
