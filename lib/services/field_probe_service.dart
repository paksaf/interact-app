// SPDX-License-Identifier: AGPL-3.0
//
// Field-test probe log — Wave 1–3 latency + PASS evidence (P3).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Synthetic thread ids used on standalone RF screens (matches router envelope).
const kFieldBleMeshThreadId = 'field-ble-mesh';
const kFieldLanProbeThreadId = 'field-lan-probe';

class FieldProbeEvent {
  const FieldProbeEvent({
    required this.id,
    required this.bearer,
    required this.direction,
    required this.at,
    this.caseId,
    this.latencyMs,
    this.detail = '',
  });

  final String id;
  final String? caseId;
  final String bearer;
  final String direction; // tx | rx
  final DateTime at;
  final int? latencyMs;
  final String detail;

  Map<String, dynamic> toJson() => {
        'id': id,
        if (caseId != null) 'caseId': caseId,
        'bearer': bearer,
        'direction': direction,
        'at': at.toIso8601String(),
        if (latencyMs != null) 'latencyMs': latencyMs,
        'detail': detail,
      };

  factory FieldProbeEvent.fromJson(Map<String, dynamic> j) => FieldProbeEvent(
        id: (j['id'] as String?) ?? '',
        caseId: j['caseId'] as String?,
        bearer: (j['bearer'] as String?) ?? '',
        direction: (j['direction'] as String?) ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
        latencyMs: (j['latencyMs'] as num?)?.toInt(),
        detail: (j['detail'] as String?) ?? '',
      );
}

class FieldProbeService {
  FieldProbeService._();
  static final FieldProbeService instance = FieldProbeService._();

  static const _key = 'talk.field.probe_log_v1';
  static const _maxEvents = 120;

  DateTime? _lastTxAt;
  String? _lastTxBearer;

  Future<void> recordTx({
    required String bearer,
    String? caseId,
    String detail = '',
  }) async {
    _lastTxAt = DateTime.now();
    _lastTxBearer = bearer;
    await _append(FieldProbeEvent(
      id: 'tx-${DateTime.now().microsecondsSinceEpoch}',
      caseId: caseId,
      bearer: bearer,
      direction: 'tx',
      at: _lastTxAt!,
      detail: detail,
    ));
  }

  Future<int?> recordRx({
    required String bearer,
    String? caseId,
    String detail = '',
  }) async {
    int? latency;
    if (_lastTxAt != null && _lastTxBearer == bearer) {
      latency = DateTime.now().difference(_lastTxAt!).inMilliseconds;
    }
    await _append(FieldProbeEvent(
      id: 'rx-${DateTime.now().microsecondsSinceEpoch}',
      caseId: caseId,
      bearer: bearer,
      direction: 'rx',
      at: DateTime.now(),
      latencyMs: latency,
      detail: detail,
    ));
    return latency;
  }

  Future<List<FieldProbeEvent>> recent({int limit = 30}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      // Stored newest-first; return the same order for UI + tests.
      return list
          .whereType<Map>()
          .map((e) => FieldProbeEvent.fromJson(e.cast<String, dynamic>()))
          .take(limit)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> clear() async {
    _lastTxAt = null;
    _lastTxBearer = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  Future<void> _append(FieldProbeEvent event) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = await recent(limit: _maxEvents);
    final encoded = [
      event.toJson(),
      ...existing.map((e) => e.toJson()),
    ];
    final trimmed = encoded.length > _maxEvents
        ? encoded.sublist(0, _maxEvents)
        : encoded;
    await prefs.setString(_key, jsonEncode(trimmed));
  }
}

/// Wave groupings for Me → Field validation (P3).
class FieldTestWave {
  const FieldTestWave({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.caseIds,
  });

  final String id;
  final String title;
  final String subtitle;
  final List<String> caseIds;
}

const kFieldTestWaves = <FieldTestWave>[
  FieldTestWave(
    id: 'wave1',
    title: 'Wave 1 — Phone RF',
    subtitle: 'BLE gossip + same Wi‑Fi LAN (ADR gate for LoRa)',
    caseIds: [
      'RF-BLE-1',
      'RF-BLE-2',
      'RF-BLE-3',
      'RF-LAN-1',
      'RF-LAN-2',
      'RF-P2P-1',
      'RF-OFFLINE-1',
    ],
  ),
  FieldTestWave(
    id: 'wave2',
    title: 'Wave 2 — Chats router',
    subtitle: 'OfflineRouter + identity + outbox via Chats tab',
    caseIds: [
      'RF-UNIFIED-1',
      'RF-BLE-CHAT-1',
      'RF-LAN-CHAT-1',
      'RF-THREAD-PEER-1',
      'RF-OUTBOX-ROUTER-1',
      'RF-SMS-FALLBACK-1',
      'RF-MESH-BIND-1',
    ],
  ),
  FieldTestWave(
    id: 'wave3',
    title: 'Wave 3 — IoT & long-range',
    subtitle: 'Gateway ACK, IoT→Chats, LoRa / Meshtastic E2E',
    caseIds: [
      'IoT-ACK-1',
      'RF-IOT-CHAT-1',
      'RF-IOT-1',
      'LoRa-1',
      'RF-LORA-E2E-1',
      'RF-MESHTASTIC-TX-1',
    ],
  ),
  FieldTestWave(
    id: 'voice',
    title: 'Voice & push',
    subtitle: 'Walkie, BLE PTT, FCM kill-app ring',
    caseIds: [
      'RF-WALKIE-1',
      'RF-WALKIE-2',
      'RF-BLE-VOICE-1',
      'FCM-1',
    ],
  ),
  FieldTestWave(
    id: 'product',
    title: 'Product polish',
    subtitle: 'Maps pin, townhall, AI',
    caseIds: [
      'RF-LOC-BUBBLE-1',
      'RF-LOC-TRACE-1',
      'RF-TOWNHALL-AUDIT-1',
      'RF-AI-1',
    ],
  ),
];
