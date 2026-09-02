// SPDX-License-Identifier: AGPL-3.0
//
// Live trace map — see yourself, chat peers, and IoT GPS devices on one screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/location_fix.dart';
import '../../services/auth_service.dart';
import '../../services/location_share_service.dart';
import '../../services/location_trace_service.dart';
import '../../utils/shared_location_launcher.dart';
import '../../utils/shared_location_pin.dart';
import '../../widgets/branded_app_bar.dart';
import '../../widgets/chat/location_pin_bubble.dart';

class LocationTraceScreen extends ConsumerStatefulWidget {
  const LocationTraceScreen({super.key});

  @override
  ConsumerState<LocationTraceScreen> createState() =>
      _LocationTraceScreenState();
}

class _LocationTraceScreenState extends ConsumerState<LocationTraceScreen> {
  List<LocationFix> _fixes = const [];
  LocationShareSession? _liveSession;
  StreamSubscription<List<LocationFix>>? _fixSub;
  StreamSubscription<LocationShareSession?>? _sessionSub;
  String? _myId;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await LocationTraceService.instance.load();
    _myId = await ref.read(authServiceProvider).localUserId();
    _fixSub = LocationTraceService.instance.fixesStream.listen((f) {
      if (mounted) setState(() => _fixes = f);
    });
    _sessionSub = LocationShareService.instance.sessionStream.listen((s) {
      if (mounted) setState(() => _liveSession = s);
    });
    if (mounted) {
      setState(() {
        _fixes = LocationTraceService.instance.fixes;
        _liveSession = LocationShareService.instance.session;
      });
    }
  }

  @override
  void dispose() {
    unawaited(_fixSub?.cancel());
    unawaited(_sessionSub?.cancel());
    super.dispose();
  }

  Future<void> _openFix(LocationFix fix) async {
    final pin = SharedLocationPin(
      lat: fix.lat,
      lng: fix.lng,
      label: fix.displayName,
      live: fix.live,
    );
    final ok = await openSharedLocationPin(pin);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open Maps for this fix.')),
    );
  }

  String _ageLabel(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Location trace'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Latest positions from phone GPS, chat pins, and IoT trackers '
            '(LoRa / RF HTTP / BLE). Tap a row to open in Maps.',
            style: TextStyle(color: cs.outline),
          ),
          if (_liveSession != null) ...[
            const SizedBox(height: 12),
            Card(
              color: cs.primaryContainer,
              child: ListTile(
                leading: Icon(Icons.my_location, color: cs.onPrimaryContainer),
                title: Text(
                  'Sharing live to chat',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                subtitle: Text(
                  'Until ${_liveSession!.until.toLocal().toString().substring(11, 16)} · '
                  'every ${_liveSession!.intervalSec}s',
                  style: TextStyle(color: cs.onPrimaryContainer.withValues(alpha: 0.85)),
                ),
                trailing: TextButton(
                  onPressed: () =>
                      unawaited(LocationShareService.instance.stop()),
                  child: const Text('Stop'),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => context.push('/chats'),
                  icon: const Icon(Icons.chat_outlined),
                  label: const Text('Share from chat'),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Clear trace log',
                onPressed: () async {
                  await LocationTraceService.instance.clear();
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Tracked (${_fixes.length})',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (_fixes.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  'No fixes yet. Share a location pin in a 1:1 chat, start live '
                  'share, or connect an IoT gateway with GPS in the poll JSON '
                  '(lat/lng fields).',
                  style: TextStyle(color: cs.outline),
                ),
              ),
            )
          else
            ..._fixes.map((fix) {
              final isMe = _myId != null && fix.entityId == _myId;
              final pin = SharedLocationPin(
                lat: fix.lat,
                lng: fix.lng,
                label: fix.displayName,
                live: fix.live,
              );
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => unawaited(_openFix(fix)),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                isMe ? 'You' : fix.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            if (fix.live)
                              Chip(
                                label: const Text('Live'),
                                visualDensity: VisualDensity.compact,
                                backgroundColor: cs.errorContainer,
                              ),
                            Chip(
                              label: Text(fix.source.label),
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                        Text(
                          '${_ageLabel(fix.at)} · ${fix.coordsLabel}',
                          style: TextStyle(color: cs.outline, fontSize: 12),
                        ),
                        if (fix.accuracyM != null)
                          Text(
                            '±${fix.accuracyM!.round()} m',
                            style: TextStyle(color: cs.outline, fontSize: 11),
                          ),
                        const SizedBox(height: 8),
                        LocationPinBubble(
                          pin: pin,
                          foreground: cs.onSurface,
                          mutedForeground: cs.outline,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 12),
          Text(
            'Sources: Phone (live share + pins) · IoT gateway JSON with lat/lng '
            '· Offline bearers (LAN/BLE) when peers share pins.',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
        ],
      ),
    );
  }
}

extension on LocationFix {
  String get coordsLabel =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}
