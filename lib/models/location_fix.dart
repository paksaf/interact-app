// SPDX-License-Identifier: AGPL-3.0
//
// A single GPS fix from a phone, chat peer, or IoT gateway device.

enum LocationFixSource {
  phone('phone'),
  iot('iot'),
  ble('ble'),
  lan('lan');

  const LocationFixSource(this.wire);
  final String wire;

  static LocationFixSource fromWire(String? s) {
    for (final v in LocationFixSource.values) {
      if (v.wire == s) return v;
    }
    return LocationFixSource.phone;
  }

  String get label => switch (this) {
        LocationFixSource.phone => 'Phone GPS',
        LocationFixSource.iot => 'IoT device',
        LocationFixSource.ble => 'BLE mesh',
        LocationFixSource.lan => 'LAN',
      };
}

/// Latest-known position for a person or device.
class LocationFix {
  const LocationFix({
    required this.entityId,
    required this.displayName,
    required this.lat,
    required this.lng,
    required this.at,
    required this.source,
    this.accuracyM,
    this.threadId,
    this.live = false,
  });

  final String entityId;
  final String displayName;
  final double lat;
  final double lng;
  final DateTime at;
  final LocationFixSource source;
  final double? accuracyM;
  final String? threadId;
  final bool live;

  Map<String, dynamic> toJson() => {
        'entityId': entityId,
        'displayName': displayName,
        'lat': lat,
        'lng': lng,
        'at': at.toIso8601String(),
        'source': source.wire,
        if (accuracyM != null) 'accuracyM': accuracyM,
        if (threadId != null) 'threadId': threadId,
        if (live) 'live': true,
      };

  factory LocationFix.fromJson(Map<String, dynamic> j) => LocationFix(
        entityId: (j['entityId'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? 'Unknown',
        lat: (j['lat'] as num?)?.toDouble() ?? 0,
        lng: (j['lng'] as num?)?.toDouble() ?? 0,
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        source: LocationFixSource.fromWire(j['source'] as String?),
        accuracyM: (j['accuracyM'] as num?)?.toDouble(),
        threadId: j['threadId'] as String?,
        live: (j['live'] as bool?) ?? false,
      );

  LocationFix copyWith({
    String? displayName,
    double? lat,
    double? lng,
    DateTime? at,
    bool? live,
  }) =>
      LocationFix(
        entityId: entityId,
        displayName: displayName ?? this.displayName,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        at: at ?? this.at,
        source: source,
        accuracyM: accuracyM,
        threadId: threadId,
        live: live ?? this.live,
      );
}
