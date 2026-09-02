// SPDX-License-Identifier: AGPL-3.0
//
// Parse location pins sent by chat / live share / IoT GPS ingest.
// Format is stable text + optional interactmaps:// and talk /j/LOC links.
// Compact offline form: loc:31.52040,74.35870 (BLE mesh ≤180 B).

import 'dart:math' as math;

/// A shared GPS pin extracted from a chat message body.
class SharedLocationPin {
  const SharedLocationPin({
    required this.lat,
    required this.lng,
    this.label,
    this.mapsDeepLink,
    this.talkFallback,
    this.live = false,
  });

  final double lat;
  final double lng;
  final String? label;
  final Uri? mapsDeepLink;
  final Uri? talkFallback;
  final bool live;

  /// OpenStreetMap raster tile for a static map preview (no extra deps).
  String get previewTileUrl {
    const z = 15;
    final n = math.pow(2, z).toDouble();
    final x = ((lng + 180) / 360 * n).floor();
    final latRad = lat * math.pi / 180;
    final y = ((1 -
                math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
            2 *
        n)
        .floor()
        .clamp(0, n.toInt() - 1);
    return 'https://tile.openstreetmap.org/$z/$x/$y.png';
  }

  String get coordsLabel =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}

/// Build a full chat pin (cloud + human-readable).
String formatLocationPinBody({
  required double lat,
  required double lng,
  bool live = false,
}) {
  final latS = lat.toStringAsFixed(6);
  final lngS = lng.toStringAsFixed(6);
  final title = live ? '📍 Live location' : '📍 Shared location';
  final mapsLink = 'https://talk.interactpak.com/j/LOC?lat=$latS&lng=$lngS';
  final deep = 'interactmaps://route?lat=$latS&lng=$lngS&name=Shared%20pin';
  return '$title\n$latS, $lngS\n${formatCompactLocationBody(lat, lng)}\n'
      'Open in Maps: $deep\n$mapsLink';
}

/// Compact wire form for BLE mesh (fits in 180 B with talk: envelope).
String formatCompactLocationBody(double lat, double lng) =>
    'loc:${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

/// If [fullBody] is a location pin, return compact inner text for mesh.
String? compactWireBody(String fullBody) {
  final pin = parseSharedLocationPin(fullBody);
  if (pin == null) return null;
  return formatCompactLocationBody(pin.lat, pin.lng);
}

bool isLiveLocationPin(String body) {
  final t = body.trim();
  return t.contains('📍 Live') ||
      t.toLowerCase().contains('live location');
}

/// Returns null when [body] is not a location pin message.
SharedLocationPin? parseSharedLocationPin(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;

  final live = isLiveLocationPin(trimmed);

  // Compact: loc:31.52040,74.35870
  final compact = RegExp(r'loc:(-?\d+\.?\d*),(-?\d+\.?\d*)').firstMatch(trimmed);
  if (compact != null) {
    final lat = double.tryParse(compact.group(1)!);
    final lng = double.tryParse(compact.group(2)!);
    if (lat != null && lng != null && lat.abs() <= 90 && lng.abs() <= 180) {
      return SharedLocationPin(
        lat: lat,
        lng: lng,
        label: live ? 'Live location' : 'Shared location',
        live: live,
      );
    }
  }

  if (!trimmed.contains('📍') &&
      !trimmed.toLowerCase().contains('shared location') &&
      !live) {
    return null;
  }

  final coord = RegExp(r'(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)').firstMatch(trimmed);
  if (coord == null) return null;

  final lat = double.tryParse(coord.group(1)!);
  final lng = double.tryParse(coord.group(2)!);
  if (lat == null || lng == null) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;

  final deep =
      RegExp(r'(interactmaps://[^\s\n]+)').firstMatch(trimmed)?.group(1);
  final https = RegExp(r'(https://talk\.interactpak\.com/j/LOC[^\s\n]*)')
      .firstMatch(trimmed)
      ?.group(1);

  return SharedLocationPin(
    lat: lat,
    lng: lng,
    label: live ? 'Live location' : 'Shared location',
    mapsDeepLink: deep != null ? Uri.tryParse(deep) : null,
    talkFallback: https != null ? Uri.tryParse(https) : null,
    live: live,
  );
}

/// Parse lat/lng from IoT frame meta (device GPS trackers).
({double lat, double lng, double? accuracyM})? parseIotGpsMeta(
  Map<String, dynamic> meta,
) {
  final lat = _num(meta['lat'] ?? meta['latitude']);
  final lng = _num(meta['lng'] ?? meta['lon'] ?? meta['longitude']);
  if (lat == null || lng == null) return null;
  if (lat.abs() > 90 || lng.abs() > 180) return null;
  final acc = _num(meta['acc'] ?? meta['accuracy'] ?? meta['accuracyM']);
  return (lat: lat, lng: lng, accuracyM: acc);
}

double? _num(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
