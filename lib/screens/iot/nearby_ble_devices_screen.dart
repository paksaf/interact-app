// SPDX-License-Identifier: AGPL-3.0
//
// Wave 3 — light IoT: nearby BLE devices (status only).
// Shows name, RSSI bars, last seen. No cloud device lock-in.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/nearby_ble_devices_service.dart';
import '../../widgets/branded_app_bar.dart';

class NearbyBleDevicesScreen extends ConsumerStatefulWidget {
  const NearbyBleDevicesScreen({super.key});

  @override
  ConsumerState<NearbyBleDevicesScreen> createState() =>
      _NearbyBleDevicesScreenState();
}

class _NearbyBleDevicesScreenState
    extends ConsumerState<NearbyBleDevicesScreen> {
  StreamSubscription? _sub;
  List<NearbyBleDevice> _devices = const [];
  bool _starting = true;
  String? _error;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _boot();
    // Refresh “last seen Xs ago” labels while scanning.
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _devices.isNotEmpty) setState(() {});
    });
  }

  Future<void> _boot() async {
    final svc = ref.read(nearbyBleDevicesServiceProvider);
    try {
      await svc.start();
      _sub = svc.devicesStream.listen((list) {
        if (mounted) setState(() => _devices = list);
      });
      setState(() {
        _devices = svc.devices;
        _starting = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _starting = false;
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _sub?.cancel();
    ref.read(nearbyBleDevicesServiceProvider).stop();
    super.dispose();
  }

  String _lastSeenLabel(NearbyBleDevice d) {
    final s = d.secondsAgo;
    if (s < 2) return 'just now';
    if (s < 60) return '${s}s ago';
    return '${s ~/ 60}m ago';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Nearby devices'),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: () {
                            setState(() {
                              _starting = true;
                              _error = null;
                            });
                            _boot();
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: cs.surfaceContainerHighest,
                      child: ListTile(
                        leading: Icon(Icons.sensors, color: cs.primary),
                        title: const Text('BLE status scan'),
                        subtitle: Text(
                          _devices.isEmpty
                              ? 'Listening for advertisements…'
                              : '${_devices.length} device(s) — status only, no cloud pairing',
                        ),
                        trailing: const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _devices.isEmpty
                          ? const Center(
                              child: Text(
                                'No BLE devices in range yet.\n'
                                'Bring a phone, headset, or tag closer.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.separated(
                              itemCount: _devices.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final d = _devices[i];
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: cs.primaryContainer,
                                    child: Icon(
                                      d.connectable
                                          ? Icons.bluetooth_connected
                                          : Icons.bluetooth,
                                      color: cs.onPrimaryContainer,
                                    ),
                                  ),
                                  title: Text(
                                    d.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${d.id}\n${_lastSeenLabel(d)}'
                                    '${d.connectable ? ' · connectable' : ''}',
                                  ),
                                  isThreeLine: true,
                                  trailing: _RssiBars(
                                    bars: d.signalBars,
                                    rssi: d.rssi,
                                    color: cs.primary,
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }
}

class _RssiBars extends StatelessWidget {
  const _RssiBars({
    required this.bars,
    required this.rssi,
    required this.color,
  });

  final int bars;
  final int rssi;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) {
            final on = i < bars;
            final h = 6.0 + i * 4;
            return Container(
              width: 4,
              height: h,
              margin: const EdgeInsets.only(left: 2),
              decoration: BoxDecoration(
                color: on ? color : color.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(1),
              ),
            );
          }),
        ),
        const SizedBox(height: 4),
        Text(
          '$rssi dBm',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}
