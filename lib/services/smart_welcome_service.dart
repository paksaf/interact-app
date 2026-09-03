// SPDX-License-Identifier: AGPL-3.0
//
// Composes the Calls-tab welcome snapshot — weather, memory, AI insight.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_router_service.dart';
import 'ai_service.dart';
import 'auth_service.dart';
import 'location_service.dart';
import 'weather_snapshot_service.dart';
import 'welcome_memory_store.dart';

class SmartWelcomeSnapshot {
  const SmartWelcomeSnapshot({
    required this.greeting,
    required this.displayName,
    this.city,
    this.weather,
    this.aiInsight,
    required this.memory,
    this.latitude,
    this.longitude,
  });

  final String greeting;
  final String displayName;
  final String? city;
  final WeatherSnapshot? weather;
  final String? aiInsight;
  final WelcomeMemory memory;
  final double? latitude;
  final double? longitude;

  String get headline {
    final name = displayName.trim();
    if (name.isNotEmpty && name != 'Me') {
      return '$greeting, $name';
    }
    return greeting;
  }
}

final smartWelcomeServiceProvider = Provider<SmartWelcomeService>((ref) {
  return SmartWelcomeService(
    ref.read(locationServiceProvider),
    ref.read(authServiceProvider),
    ref.read(aiRouterProvider),
  );
});

class SmartWelcomeService {
  SmartWelcomeService(this._location, this._auth, this._ai);

  final LocationService _location;
  final AuthService _auth;
  final AiRouterService _ai;

  String? _cachedInsight;
  DateTime? _insightAt;

  Future<SmartWelcomeSnapshot> load() async {
    final memory = await WelcomeMemoryStore.instance.recordAppOpen();
    final place = _location.cached ?? await _location.resolve();
    final greeting = place?.greeting ?? LocationService.greetingForNow();
    final city = place?.city;
    final lat = place?.latitude;
    final lon = place?.longitude;

    WeatherSnapshot? weather;
    if (lat != null && lon != null) {
      weather = await WeatherSnapshotService.instance.fetchFor(
        lat: lat,
        lon: lon,
      );
    }

    final name = (await _auth.displayName())?.trim() ?? '';

    final insight = await _insightFor(
      greeting: greeting,
      name: name,
      city: city,
      weather: weather,
      memory: memory,
    );

    return SmartWelcomeSnapshot(
      greeting: greeting,
      displayName: name,
      city: city,
      weather: weather,
      aiInsight: insight,
      memory: memory,
      latitude: lat,
      longitude: lon,
    );
  }

  Future<String?> _insightFor({
    required String greeting,
    required String name,
    required String? city,
    required WeatherSnapshot? weather,
    required WelcomeMemory memory,
  }) async {
    final now = DateTime.now();
    if (_cachedInsight != null &&
        _insightAt != null &&
        now.difference(_insightAt!) < const Duration(hours: 4)) {
      return _cachedInsight;
    }

    final due = memory.dueSoon;
    if (due.isNotEmpty) {
      final r = due.first;
      final h = r.dueAt.difference(now).inHours;
      final when = h <= 1 ? 'soon' : 'in $h hours';
      _cache('Reminder $when: ${r.body}');
      return _cachedInsight;
    }

    if (memory.pinnedNote != null && memory.pinnedNote!.body.isNotEmpty) {
      final snippet = memory.pinnedNote!.body.length > 60
          ? '${memory.pinnedNote!.body.substring(0, 57)}…'
          : memory.pinnedNote!.body;
      _cache('Your note: $snippet');
      return _cachedInsight;
    }

    if (memory.dayStreak >= 3) {
      _cache(
        '${memory.dayStreak}-day streak — I\'m learning your rhythm. '
        'Tap Goals to set what matters this week.',
      );
      return _cachedInsight;
    }

    try {
      final private = await _ai.isPrivateAiEnabled();
      if (private) {
        _cache(_offlineInsight(greeting, city, weather));
        return _cachedInsight;
      }

      final prompt = StringBuffer()
        ..writeln('Write ONE short proactive sentence (max 18 words) for a '
            'communication app home screen.')
        ..writeln('Tone: warm, capable, remembers the user. No emojis.')
        ..writeln('Context: $greeting${name.isNotEmpty ? ', user $name' : ''}'
            '${city != null ? ', near $city' : ''}'
            '${weather != null ? ', ${weather.chipLabel}' : ''}.');
      final res = await _ai
          .complete(AiRequest(
            tier: AiTier.chat,
            prompt: prompt.toString(),
            maxTokens: 48,
            temperature: 0.6,
            systemPrompt:
                'You are INTERACT AI — cross-app assistant for Pakistan-first users. '
                'Be concise. Never mention WhatsApp or competitors.',
          ))
          .timeout(const Duration(seconds: 5));
      final text = res.text.trim();
      if (text.isNotEmpty) {
        _cache(text.split('\n').first);
        return _cachedInsight;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[SmartWelcome] AI insight: $e');
    }

    _cache(_offlineInsight(greeting, city, weather));
    return _cachedInsight;
  }

  String _offlineInsight(
    String greeting,
    String? city,
    WeatherSnapshot? weather,
  ) {
    if (weather?.conditionLabel == 'Rain' ||
        weather?.conditionLabel == 'Showers') {
      return 'Rain nearby — voice calls beat typing when you\'re on the move.';
    }
    if (city != null) {
      return '$greeting from $city — I\'m here when you need calls, notes, or plans.';
    }
    return 'I remember your streak and notes on this device — ask me anything.';
  }

  void _cache(String s) {
    _cachedInsight = s;
    _insightAt = DateTime.now();
  }
}
