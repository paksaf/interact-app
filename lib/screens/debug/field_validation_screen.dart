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

  static const _cases = <_Case>[
    _Case('RF-BLE-1', 'BLE mesh 2 phones @1m', '/nearby-mesh'),
    _Case('RF-BLE-2', 'BLE mesh 2 phones @50m', '/nearby-mesh'),
    _Case('RF-BLE-3', 'BLE mesh 3 phones gossip', '/nearby-mesh'),
    _Case('RF-LAN-1', 'Same Wi‑Fi 2 phones (no internet)', '/offline-lan'),
    _Case('RF-LAN-2', 'Same Wi‑Fi 3 phones', '/offline-lan'),
    _Case('RF-P2P-1', 'Direct 2 Android (optional)', '/offline-lan'),
    _Case('RF-IOT-1', 'Nearby devices list', '/nearby-devices'),
    _Case('FCM-1', 'Kill-app ring A→B', null),
    _Case('LoRa-1', '2× InteractLoRaBridge + 2 phones', '/lora-bridge'),
  ];

  @override
  void initState() {
    super.initState();
    for (final c in _cases) {
      _notes[c.id] = TextEditingController();
      _results[c.id] = '';
    }
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    for (final c in _cases) {
      _results[c.id] = prefs.getString('$_kPrefPrefix${c.id}.result') ?? '';
      _notes[c.id]!.text = prefs.getString('$_kPrefPrefix${c.id}.notes') ?? '';
    }
    try {
      final t = await FirebaseMessaging.instance.getToken();
      _fcmTokenTail = t == null
          ? null
          : '…${t.substring(t.length > 12 ? t.length - 12 : 0)}';
      // Re-register so prove logs appear.
      await PushService.instance.init(ref.read(authServiceProvider));
    } catch (e) {
      _fcmError = '$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_kPrefPrefix$id.result', _results[id] ?? '');
    await prefs.setString('$_kPrefPrefix$id.notes', _notes[id]?.text ?? '');
  }

  @override
  void dispose() {
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
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
                  'Pakistan RF matrix — run on real devices. '
                  'Open the transport screen, measure wall-clock, mark PASS/FAIL.',
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
                const SizedBox(height: 8),
                for (final c in _cases) ...[
                  Card(
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
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (c.route != null)
                                TextButton(
                                  onPressed: () => context.push(c.route!),
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
                              if ((_results[c.id] ?? '').isNotEmpty)
                                _results[c.id]!,
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
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  'Do not rewrite sahl_mesh/lan_service from failures — '
                  'harden only the failed row. LoRa uses InteractLoRaBridge '
                  '(not LoRa_Bridge / 12345678 UUIDs).',
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
