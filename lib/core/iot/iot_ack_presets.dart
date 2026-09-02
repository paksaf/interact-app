// SPDX-License-Identifier: AGPL-3.0
//
// One-tap ACK / command codes for universal IoT reply.

class IotAckPreset {
  const IotAckPreset({
    required this.code,
    required this.label,
    required this.icon,
    this.description,
  });

  final String code;
  final String label;
  final String icon;
  final String? description;
}

/// Standard ACK + common AutoSense / gate / relay codes.
const List<IotAckPreset> kIotAckPresets = [
  IotAckPreset(code: 'ACK', label: 'ACK', icon: '✓', description: 'Received'),
  IotAckPreset(code: 'OK', label: 'OK', icon: '👍'),
  IotAckPreset(code: 'NACK', label: 'NACK', icon: '✗', description: 'Reject'),
  IotAckPreset(code: 'OPEN', label: 'Open', icon: '🔓', description: 'Gate / door'),
  IotAckPreset(code: 'CLOSE', label: 'Close', icon: '🔒'),
  IotAckPreset(code: 'ARM', label: 'Arm', icon: '🛡', description: 'AutoSense alarm'),
  IotAckPreset(code: 'DISARM', label: 'Disarm', icon: '🔕'),
  IotAckPreset(code: 'HONK', label: 'Honk', icon: '📯', description: 'Car locate'),
  IotAckPreset(code: 'STOP', label: 'Stop', icon: '⏹', description: 'Halt / estop'),
  IotAckPreset(code: 'PING', label: 'Ping', icon: '📡', description: 'Probe link'),
];

IotAckPreset? presetByCode(String code) {
  for (final p in kIotAckPresets) {
    if (p.code == code) return p;
  }
  return null;
}
