// SPDX-License-Identifier: AGPL-3.0
//
// Location weather for the Calls welcome layer — Open-Meteo (no key) with
// optional IL Lifestyle public point when WEATHER_APP_KEY is compiled in.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class WeatherSnapshot {
  const WeatherSnapshot({
    required this.temperatureLabel,
    this.conditionLabel,
    this.humidityPercent,
    this.source = 'open-meteo',
  });

  final String temperatureLabel;
  final String? conditionLabel;
  final int? humidityPercent;
  final String source;

  String get chipLabel {
    if (conditionLabel != null && conditionLabel!.isNotEmpty) {
      return '$temperatureLabel · $conditionLabel';
    }
    return temperatureLabel;
  }
}

class WeatherSnapshotService {
  WeatherSnapshotService._();
  static final WeatherSnapshotService instance = WeatherSnapshotService._();

  static const _ilBase = String.fromEnvironment(
    'IL_API_BASE',
    defaultValue: 'https://lifestyle.interactpak.com/api',
  );
  static const _weatherAppKey = String.fromEnvironment(
    'WEATHER_APP_KEY',
    defaultValue: '',
  );

  WeatherSnapshot? _cached;

  /// Full IL Weather app / Lifestyle planning surface.
  static Uri weatherAppUri({double? lat, double? lon}) {
    final q = <String, String>{};
    if (lat != null && lon != null) {
      q['lat'] = lat.toStringAsFixed(4);
      q['lon'] = lon.toStringAsFixed(4);
    }
    return Uri.parse('https://lifestyle.interactpak.com/weather').replace(
      queryParameters: q.isEmpty ? null : q,
    );
  }

  Future<WeatherSnapshot?> fetchFor({
    required double lat,
    required double lon,
  }) async {
    if (_cached != null) return _cached;

    if (_weatherAppKey.isNotEmpty) {
      final il = await _fetchIlPublic(lat: lat, lon: lon);
      if (il != null) {
        _cached = il;
        return il;
      }
    }

    final om = await _fetchOpenMeteo(lat: lat, lon: lon);
    _cached = om;
    return om;
  }

  void clearCache() => _cached = null;

  Future<WeatherSnapshot?> _fetchIlPublic({
    required double lat,
    required double lon,
  }) async {
    try {
      final uri = Uri.parse('$_ilBase/weather/public/point').replace(
        queryParameters: {
          'lat': lat.toString(),
          'lon': lon.toString(),
          'use_case': 'general',
          'locale': 'en',
        },
      );
      final res = await http
          .get(uri, headers: {
            'Accept': 'application/json',
            'X-Weather-App-Key': _weatherAppKey,
          })
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final data = j['data'] ?? j;
      if (data is! Map) return null;
      final temp = data['temperatureC'] ?? data['tempC'] ?? data['temperature'];
      if (temp == null) return null;
      final tNum = temp is num ? temp : double.tryParse('$temp');
      if (tNum == null) return null;
      return WeatherSnapshot(
        temperatureLabel: '${tNum.round()}°C',
        conditionLabel: (data['summary'] as String?)?.trim(),
        humidityPercent: (data['humidity'] as num?)?.toInt(),
        source: 'il-lifestyle',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[WeatherSnapshot] IL: $e');
      return null;
    }
  }

  Future<WeatherSnapshot?> _fetchOpenMeteo({
    required double lat,
    required double lon,
  }) async {
    try {
      final uri = Uri.parse(
        'https://api.open-meteo.com/v1/forecast'
        '?latitude=$lat&longitude=$lon'
        '&current=temperature_2m,relative_humidity_2m,weather_code',
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final cur = j['current'] as Map<String, dynamic>?;
      if (cur == null) return null;
      final t = cur['temperature_2m'];
      if (t is! num) return null;
      final code = (cur['weather_code'] as num?)?.toInt();
      return WeatherSnapshot(
        temperatureLabel: '${t.round()}°C',
        conditionLabel: _wmoLabel(code),
        humidityPercent: (cur['relative_humidity_2m'] as num?)?.toInt(),
        source: 'open-meteo',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[WeatherSnapshot] Open-Meteo: $e');
      return null;
    }
  }

  static String? _wmoLabel(int? code) {
    if (code == null) return null;
    return switch (code) {
      0 => 'Clear',
      1 || 2 || 3 => 'Partly cloudy',
      45 || 48 => 'Fog',
      51 || 53 || 55 => 'Drizzle',
      61 || 63 || 65 => 'Rain',
      71 || 73 || 75 => 'Snow',
      80 || 81 || 82 => 'Showers',
      95 || 96 || 99 => 'Storm',
      _ => 'Cloudy',
    };
  }
}
