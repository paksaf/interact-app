// SPDX-License-Identifier: AGPL-3.0
//
// LocationService — a light, offline-first "where am I" helper that gives the
// app a personalised feel ("Good evening · Multan") without a network round
// trip or a maps SDK. Borrows the Geolocator permission + getCurrentPosition
// pattern from interact-maps (lib/providers/location_provider.dart, READ-only
// donor) and pairs it with a compact embedded gazetteer of Pakistani cities
// (derived from _shared/data/locations + territories) so reverse-geocoding is
// a pure haversine nearest-neighbour — no `geocoding` platform call, works on
// a plane or a dead network.
//
// Privacy: the fix never leaves the device. We only keep the resolved city
// label + a coarse lat/lng in memory for the session. No persistence, no
// upload. If permission is denied we degrade silently to a generic greeting.
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// Resolved place + a time-of-day greeting, ready to drop into a header.
class PlaceInfo {
  const PlaceInfo({
    required this.city,
    required this.greeting,
    this.latitude,
    this.longitude,
  });
  final String city;
  final String greeting;
  /// Coarse fix for weather fetch — never uploaded by Talk.
  final double? latitude;
  final double? longitude;

  /// "Good evening · Multan" — the personalised subtitle.
  String get label => '$greeting · $city';
}

class _City {
  const _City(this.name, this.lat, this.lng);
  final String name;
  final double lat;
  final double lng;
}

/// Compact gazetteer — major population + INTERACT-territory centres across
/// all four provinces + AJK/GB, so the nearest-city label is meaningful
/// wherever a Pakistani user opens the app. Lat/lng from _shared data.
const _cities = <_City>[
  _City('Karachi', 24.8607, 67.0011),
  _City('Lahore', 31.5204, 74.3587),
  _City('Islamabad', 33.6844, 73.0479),
  _City('Rawalpindi', 33.5651, 73.0169),
  _City('Faisalabad', 31.4504, 73.1350),
  _City('Multan', 30.1575, 71.5249),
  _City('Bahawalpur', 29.3956, 71.6836),
  _City('Rahim Yar Khan', 28.4202, 70.2952),
  _City('Sahiwal', 30.6682, 73.1114),
  _City('Dera Ghazi Khan', 30.0561, 70.6403),
  _City('Khanewal', 30.3017, 71.9321),
  _City('Muzaffargarh', 30.0736, 71.1805),
  _City('Vehari', 30.0331, 72.3489),
  _City('Lodhran', 29.5340, 71.6335),
  _City('Bahawalnagar', 29.9990, 73.2536),
  _City('Gujranwala', 32.1877, 74.1945),
  _City('Sialkot', 32.4927, 74.5319),
  _City('Sargodha', 32.0836, 72.6711),
  _City('Sheikhupura', 31.7131, 73.9783),
  _City('Gujrat', 32.5731, 74.0789),
  _City('Jhang', 31.2681, 72.3181),
  _City('Okara', 30.8138, 73.4534),
  _City('Kasur', 31.1187, 74.4470),
  _City('Peshawar', 34.0151, 71.5249),
  _City('Mardan', 34.1980, 72.0449),
  _City('Abbottabad', 34.1688, 73.2215),
  _City('Quetta', 30.1798, 66.9750),
  _City('Hyderabad', 25.3960, 68.3578),
  _City('Sukkur', 27.7052, 68.8574),
  _City('Larkana', 27.5590, 68.2123),
  _City('Nawabshah', 26.2442, 68.4100),
  _City('Mirpur Khas', 25.5276, 69.0111),
  _City('Sadiqabad', 28.3091, 70.1295),
  _City('Muzaffarabad', 34.3700, 73.4711),
  _City('Gilgit', 35.9208, 74.3144),
  _City('Dera Ismail Khan', 31.8313, 70.9019),
  _City('Bannu', 32.9889, 70.6056),
  _City('Kohat', 33.5869, 71.4432),
  _City('Chiniot', 31.7202, 72.9784),
  _City('Nowshera', 34.0153, 71.9747),
];

class LocationService {
  PlaceInfo? _cached;

  /// The last resolved place this session (null until [resolve] succeeds).
  PlaceInfo? get cached => _cached;

  static String greetingForNow([DateTime? now]) {
    final h = (now ?? DateTime.now()).hour;
    if (h < 5) return 'Good night';
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    if (h < 21) return 'Good evening';
    return 'Good night';
  }

  /// Ask for location (once), resolve the nearest known city, cache + return.
  /// Returns null if permission is denied or the fix times out — callers show
  /// a generic greeting in that case. Never throws.
  Future<PlaceInfo?> resolve() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
      ).timeout(const Duration(seconds: 8));

      final city = _nearestCity(pos.latitude, pos.longitude);
      final info = PlaceInfo(
        city: city,
        greeting: greetingForNow(),
        latitude: pos.latitude,
        longitude: pos.longitude,
      );
      _cached = info;
      return info;
    } catch (_) {
      return null;
    }
  }

  static String _nearestCity(double lat, double lng) {
    double best = double.infinity;
    String bestName = _cities.first.name;
    for (final c in _cities) {
      final d = _haversineKm(lat, lng, c.lat, c.lng);
      if (d < best) {
        best = d;
        bestName = c.name;
      }
    }
    return bestName;
  }

  static double _haversineKm(
      double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0; // km
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_rad(lat1)) *
            math.cos(_rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  static double _rad(double deg) => deg * math.pi / 180.0;
}

final locationServiceProvider =
    Provider<LocationService>((ref) => LocationService());
