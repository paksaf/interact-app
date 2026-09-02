// SPDX-License-Identifier: AGPL-3.0
//
// Registry of latest GPS fixes — phone live share, chat pins, IoT gateways.

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/iot/iot_frame.dart';
import '../models/location_fix.dart';
import '../models/talk_bearer.dart';
import '../utils/shared_location_pin.dart';

class LocationTraceService {
  LocationTraceService._();
  static final LocationTraceService instance = LocationTraceService._();

  static const _key = 'talk.location.trace_v1';
  static const _maxFixes = 80;

  final _controller = StreamController<List<LocationFix>>.broadcast();
  final _byEntity = <String, LocationFix>{};

  Stream<List<LocationFix>> get fixesStream => _controller.stream;
  List<LocationFix> get fixes => _byEntity.values.toList()
    ..sort((a, b) => b.at.compareTo(a.at));

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final item in list) {
        if (item is! Map) continue;
        final fix = LocationFix.fromJson(item.cast<String, dynamic>());
        if (fix.entityId.isNotEmpty) _byEntity[fix.entityId] = fix;
      }
      _emit();
    } catch (_) {/* corrupt store — start fresh */}
  }

  Future<void> recordFix(LocationFix fix) async {
    if (fix.entityId.isEmpty) return;
    _byEntity[fix.entityId] = fix;
    await _persist();
    _emit();
  }

  Future<void> recordFromMessageBody({
    required String body,
    required String senderId,
    required String senderName,
    String? threadId,
    TalkBearer? bearer,
  }) async {
    final pin = parseSharedLocationPin(body);
    if (pin == null) return;
    final source = switch (bearer) {
      TalkBearer.lan => LocationFixSource.lan,
      TalkBearer.bleMesh => LocationFixSource.ble,
      TalkBearer.iot => LocationFixSource.iot,
      _ => LocationFixSource.phone,
    };
    await recordFix(LocationFix(
      entityId: senderId,
      displayName: senderName,
      lat: pin.lat,
      lng: pin.lng,
      at: DateTime.now(),
      source: source,
      threadId: threadId,
      live: pin.live,
    ));
  }

  Future<void> recordFromIotFrame(IotFrame frame) async {
    final gps = parseIotGpsMeta(frame.meta);
    if (gps == null) return;
    final device = (frame.meta['device'] as String?)?.trim();
    final entityId = device?.isNotEmpty == true ? device! : 'iot-${frame.id}';
    final name = device?.isNotEmpty == true ? device! : frame.bearer.label;
    await recordFix(LocationFix(
      entityId: entityId,
      displayName: name,
      lat: gps.lat,
      lng: gps.lng,
      at: frame.at ?? DateTime.now(),
      source: LocationFixSource.iot,
      accuracyM: gps.accuracyM,
      live: frame.body.toLowerCase() == 'gps' ||
          frame.meta['live'] == true,
    ));
  }

  LocationFix? latestFor(String entityId) => _byEntity[entityId];

  Future<void> clear() async {
    _byEntity.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(fixes);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = fixes.take(_maxFixes).map((f) => f.toJson()).toList();
    await prefs.setString(_key, jsonEncode(sorted));
  }
}
