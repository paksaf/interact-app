// SPDX-License-Identifier: AGPL-3.0
//
// Keep the Talk process elevated while Nearby mesh (sahl_mesh) is active.
// Pattern from Interact Maps `BackgroundGpsService` (flutter_background_service),
// FG type `connectedDevice` for BLE scan/advertise. BLE I/O stays on the UI
// isolate; this FGS only prevents OEM process kills during field tests.
import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const _kChannelId = 'interact_talk_mesh';
const _kNotifId = 887;

class MeshForegroundService {
  MeshForegroundService._();
  static final instance = MeshForegroundService._();

  final _service = FlutterBackgroundService();
  bool _configured = false;

  Future<void> ensureConfigured() async {
    if (_configured) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(android: androidInit),
    );
    const channel = AndroidNotificationChannel(
      _kChannelId,
      'Nearby mesh',
      description: 'Keeps BLE mesh active for field tests',
      importance: Importance.low,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _kChannelId,
        initialNotificationTitle: 'INTERACT Nearby mesh',
        initialNotificationContent: 'BLE gossip active',
        foregroundServiceNotificationId: _kNotifId,
        foregroundServiceTypes: const [AndroidForegroundType.connectedDevice],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
    _configured = true;
  }

  Future<void> start() async {
    try {
      await ensureConfigured();
      if (await _service.isRunning()) return;
      await _service.startService();
    } catch (e) {
      debugPrint('MeshForegroundService.start failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      if (await _service.isRunning()) {
        _service.invoke('stop');
      }
    } catch (_) {}
  }
}

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
void _onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: 'INTERACT Nearby mesh',
      content: 'BLE gossip active — keep phones nearby',
    );
  }
  service.on('stop').listen((_) async {
    await service.stopSelf();
  });
  // Heartbeat so the isolate stays warm; mesh I/O is on the UI isolate.
  Timer.periodic(const Duration(seconds: 15), (_) async {
    if (service is AndroidServiceInstance) {
      if (await service.isForegroundService()) {
        service.setForegroundNotificationInfo(
          title: 'INTERACT Nearby mesh',
          content: 'BLE gossip active',
        );
      }
    }
  });
}
