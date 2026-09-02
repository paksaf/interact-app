// SPDX-License-Identifier: AGPL-3.0
//
// In-app RF field-test checklist for Pakistan QA. Uses real Me entry points
// (Nearby mesh / Offline LAN) — not invented connectToNearbyDevice APIs.
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/auth_service.dart';
import '../../services/field_probe_service.dart';
import '../../services/push_service.dart';
import '../../widgets/branded_app_bar.dart';

const _kPrefPrefix = 'talk.field.';

class FieldValidationScreen extends ConsumerStatefulWidget {
  const FieldValidationScreen({super.key});

  @override
  ConsumerState<FieldValidationScreen> createState() =>
      _FieldValidationScreenState();
}

class _FieldValidationScreenState extends ConsumerState<FieldValidationScreen> {
  final _notes = <String, TextEditingController>{};
  final _results = <String, String>{}; // PASS | FAIL | SKIP | ''
  String? _fcmTokenTail;
  String? _fcmError;
  bool _loading = true;
  List<FieldProbeEvent> _probes = const [];
  bool _loadingProbes = false;

  static const _caseById = <String, _Case>{
    'RF-BLE-1': _Case('RF-BLE-1', 'BLE mesh 2 phones @1m', '/nearby-mesh'),
    'RF-BLE-2': _Case('RF-BLE-2', 'BLE mesh 2 phones @50m', '/nearby-mesh'),
    'RF-BLE-3': _Case('RF-BLE-3', 'BLE mesh 3 phones gossip', '/nearby-mesh'),
    'RF-LAN-1': _Case('RF-LAN-1', 'Same Wi‑Fi 2 phones (no internet)', '/offline-lan'),
    'RF-LAN-2': _Case('RF-LAN-2', 'Same Wi‑Fi 3 phones', '/offline-lan'),
    'RF-P2P-1': _Case('RF-P2P-1', 'Direct 2 Android (optional)', '/offline-lan'),
    'RF-OFFLINE-1': _Case(
      'RF-OFFLINE-1',
      'Airplane+Wi‑Fi only — LAN text + walkie',
      '/offline-hub',
    ),
    'RF-UNIFIED-1': _Case(
      'RF-UNIFIED-1',
      'Chat send routes via OfflineRouter bearer',
      '/chats',
    ),
    'RF-BLE-CHAT-1': _Case(
      'RF-BLE-CHAT-1',
      '1:1 chat → OfflineRouter → BLE mesh (sensors tick)',
      '/chats',
    ),
    'RF-LAN-CHAT-1': _Case(
      'RF-LAN-CHAT-1',
      '1:1 chat → OfflineRouter → LAN (sensors tick)',
      '/chats',
    ),
    'RF-THREAD-PEER-1': _Case(
      'RF-THREAD-PEER-1',
      '1:1 chat LAN targets mapped peerUserId',
      '/chats',
    ),
    'RF-OUTBOX-ROUTER-1': _Case(
      'RF-OUTBOX-ROUTER-1',
      'Outbox flush replays via OfflineRouter',
      '/chats',
    ),
    'RF-SMS-FALLBACK-1': _Case(
      'RF-SMS-FALLBACK-1',
      'User-confirmed SMS when cloud queue stuck',
      '/chats',
    ),
    'RF-MESH-BIND-1': _Case(
      'RF-MESH-BIND-1',
      'QR mesh identity ↔ Talk user binding',
      '/mesh-identity',
    ),
    'IoT-ACK-1': _Case(
      'IoT-ACK-1',
      'IoT signal → one-tap ACK (LoRa or RF HTTP)',
      '/iot-comms',
    ),
    'RF-IOT-CHAT-1': _Case(
      'RF-IOT-CHAT-1',
      'IoT alert appears in Chats → IoT alerts thread',
      '/iot-comms',
    ),
    'RF-IOT-1': _Case('RF-IOT-1', 'Nearby devices list', '/nearby-devices'),
    'LoRa-1': _Case('LoRa-1', '2× InteractLoRaBridge + 2 phones', '/lora-bridge'),
    'RF-LORA-E2E-1': _Case(
      'RF-LORA-E2E-1',
      'LoRa bridge E2E — phone A → bridge → RF → bridge → phone B',
      '/lora-bridge',
    ),
    'RF-MESHTASTIC-TX-1': _Case(
      'RF-MESHTASTIC-TX-1',
      'Meshtastic MeshPacket UTF-8 TX via BLE',
      '/lora-bridge',
    ),
    'RF-WALKIE-1': _Case(
      'RF-WALKIE-1',
      'LAN walkie Samsung host → iPhone join',
      '/lan-walkie',
    ),
    'RF-WALKIE-2': _Case(
      'RF-WALKIE-2',
      'LAN walkie iPhone host → Samsung join',
      '/lan-walkie',
    ),
    'RF-BLE-VOICE-1': _Case(
      'RF-BLE-VOICE-1',
      'BLE walkie PTT between 2 phones',
      '/ble-walkie',
    ),
    'FCM-1': _Case('FCM-1', 'Kill-app ring A→B', null),
    'RF-LOC-BUBBLE-1': _Case(
      'RF-LOC-BUBBLE-1',
      'Chat location pin → map bubble + Maps tap',
      '/chats',
    ),
    'RF-LOC-TRACE-1': _Case(
      'RF-LOC-TRACE-1',
      'Live share A→B + Location trace screen',
      '/location-trace',
    ),
    'RF-TOWNHALL-AUDIT-1': _Case(
      'RF-TOWNHALL-AUDIT-1',
      'Townhall host sees watching/focus counts',
      '/townhall',
    ),
    'RF-AI-1': _Case(
      'RF-AI-1',
      'INTERACT AI contact thread reply',
      '/chat/interact-ai-system',
    ),
  };

  Iterable<String> get _allCaseIds sync* {
    for (final wave in kFieldTestWaves) {
      for (final id in wave.caseIds) {
        yield id;
      }
    }
  }

  @override
  void initState() {
    super.initState();
    for (final id in _allCaseIds) {
      _notes[id] = TextEditingController();
      _results[id] = '';
    }
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final id in _allCaseIds) {
      _results[id] = prefs.getString('$_kPrefPrefix$id.result') ?? '';
      _notes[id]!.text = prefs.getString('$_kPrefPrefix$id.notes') ?? '';
    }
    try {
      final t = await FirebaseMessaging.instance.getToken();
      _fcmTokenTail = t == null
          ? null
          : '…${t.substring(t.length > 12 ? t.length - 12 : 0)}';
      await PushService.instance.init(ref.read(authServiceProvider));
    } catch (e) {
      _fcmError = '$e';
    }
    await _refreshProbes();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _refreshProbes() async {
    setState(() => _loadingProbes = true);
    final recent = await FieldProbeService.instance.recent(limit: 20);
    if (mounted) {
      setState(() {
        _probes = recent;
        _loadingProbes = false;
      });
    }
  }

  Future<void> _save(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kPrefPrefix$id.result', _results[id] ?? '');
    await prefs.setString('$_kPrefPrefix$id.notes', _notes[id]?.text ?? '');
  }

  int _wavePassCount(FieldTestWave wave) {
    var n = 0;
    for (final id in wave.caseIds) {
      if (_results[id] == 'PASS') n++;
    }
    return n;
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _buildCaseCard(_Case c, ColorScheme cs) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${c.id}: ${c.title}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (c.route != null)
                  TextButton(
                    onPressed: () {
                      FieldProbeService.instance.setActiveCaseId(c.id);
                      context.push(c.route!);
                    },
                    child: const Text('Open'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'PASS', label: Text('PASS')),
                ButtonSegment(value: 'FAIL', label: Text('FAIL')),
                ButtonSegment(value: 'SKIP', label: Text('SKIP')),
              ],
              emptySelectionAllowed: true,
              selected: {
                if ((_results[c.id] ?? '').isNotEmpty) _results[c.id]!,
              },
              onSelectionChanged: (s) async {
                setState(() => _results[c.id] = s.isEmpty ? '' : s.first);
                await _save(c.id);
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notes[c.id],
              decoration: const InputDecoration(
                labelText: 'Notes (latency, OEM, loss)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => _save(c.id),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Field validation'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Pakistan RF matrix — P3 waves. Open the transport screen, '
                  'measure wall-clock, mark PASS/FAIL. Probe log captures TX/RX '
                  'latency from live bearers. Runbook: docs/FIELD_TEST_WAVE1_WAVE2_2026-09-02.md',
                  style: TextStyle(color: cs.outline),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: Icon(
                      _fcmTokenTail != null ? Icons.check_circle : Icons.warning,
                      color: _fcmTokenTail != null ? Colors.green : cs.error,
                    ),
                    title: const Text('FCM token'),
                    subtitle: Text(
                      _fcmError ??
                          (_fcmTokenTail ??
                              'No token — check google-services.json / Firebase'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Probe log (last 20)',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            TextButton(
                              onPressed: _loadingProbes ? null : _refreshProbes,
                              child: const Text('Refresh'),
                            ),
                            TextButton(
                              onPressed: () async {
                                await FieldProbeService.instance.clear();
                                await _refreshProbes();
                              },
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                        if (_loadingProbes)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: LinearProgressIndicator(),
                          )
                        else if (_probes.isEmpty)
                          Text(
                            'No probes yet — send on Nearby mesh, Offline LAN, '
                            'or Chats while offline.',
                            style: TextStyle(color: cs.outline, fontSize: 13),
                          )
                        else
                          ..._probes.map((e) {
                            final lat = e.latencyMs;
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                e.direction == 'tx'
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward,
                                size: 18,
                                color: cs.primary,
                              ),
                              title: Text(
                                '${e.bearer} ${e.direction}'
                                '${lat != null ? ' · ${lat}ms' : ''}',
                                style: const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text(
                                e.detail.isEmpty ? e.at.toIso8601String() : e.detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: cs.outline),
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                for (final wave in kFieldTestWaves) ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          wave.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Chip(
                        label: Text(
                          '${_wavePassCount(wave)}/${wave.caseIds.length} PASS',
                        ),
                      ),
                    ],
                  ),
                  Text(wave.subtitle, style: TextStyle(color: cs.outline)),
                  const SizedBox(height: 8),
                  for (final id in wave.caseIds) ...[
                    if (_caseById.containsKey(id)) ...[
                      _buildCaseCard(_caseById[id]!, cs),
                      const SizedBox(height: 8),
                    ] else
                      Card(
                        child: ListTile(
                          title: Text('$id — missing case definition'),
                          textColor: cs.error,
                        ),
                      ),
                  ],
                  const SizedBox(height: 16),
                ],
                Text(
                  'Do not rewrite sahl_mesh/lan_service from failures — '
                  'harden only the failed row. LoRa uses InteractLoRaBridge '
                  '(not LoRa_Bridge / 12345678 UUIDs). Wave 3 LoRa E2E requires '
                  'Wave 1 BLE/LAN PASS (ADR gate).',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                ),
              ],
            ),
    );
  }
}

class _Case {
  const _Case(this.id, this.title, this.route);
  final String id;
  final String title;
  final String? route;
}
