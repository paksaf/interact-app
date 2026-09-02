// SPDX-License-Identifier: AGPL-3.0
//
// Live location share — periodic GPS pins to a chat thread via OfflineRouter.

import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/location_fix.dart';
import '../utils/shared_location_pin.dart';
import 'auth_service.dart';
import 'location_trace_service.dart';
import 'message_repository.dart';

class LocationShareSession {
  const LocationShareSession({
    required this.threadId,
    required this.until,
    required this.intervalSec,
  });

  final String threadId;
  final DateTime until;
  final int intervalSec;
}

class LocationShareService {
  LocationShareService._();
  static final LocationShareService instance = LocationShareService._();

  Timer? _timer;
  LocationShareSession? _session;
  MessageRepository? _repo;
  AuthService? _auth;

  final _sessionController = StreamController<LocationShareSession?>.broadcast();

  Stream<LocationShareSession?> get sessionStream => _sessionController.stream;
  LocationShareSession? get session => _session;
  bool get isSharing => _timer != null;

  void bind({
    required MessageRepository repo,
    required AuthService auth,
  }) {
    _repo = repo;
    _auth = auth;
  }

  Future<bool> startLiveShare({
    required String threadId,
    Duration duration = const Duration(minutes: 15),
    Duration interval = const Duration(seconds: 60),
    String? targetPeerUserId,
  }) async {
    await stop();
    final repo = _repo;
    if (repo == null) return false;

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      return false;
    }

    _session = LocationShareSession(
      threadId: threadId,
      until: DateTime.now().add(duration),
      intervalSec: interval.inSeconds,
    );
    _sessionController.add(_session);

    await _tick(threadId, targetPeerUserId: targetPeerUserId);
    _timer = Timer.periodic(interval, (_) async {
      if (_session == null) return;
      if (DateTime.now().isAfter(_session!.until)) {
        await stop();
        return;
      }
      await _tick(threadId, targetPeerUserId: targetPeerUserId);
    });
    return true;
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _session = null;
    _sessionController.add(null);
  }

  Future<void> _tick(
    String threadId, {
    String? targetPeerUserId,
  }) async {
    final repo = _repo;
    final auth = _auth;
    if (repo == null || auth == null) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 12));
      final body = formatLocationPinBody(
        lat: pos.latitude,
        lng: pos.longitude,
        live: true,
      );
      final myId = await auth.localUserId() ?? 'local';
      final myName = await auth.displayName() ?? 'Me';
      await repo.sendText(
        threadId,
        body,
        targetPeerUserId: targetPeerUserId,
      );
      await LocationTraceService.instance.recordFix(LocationFix(
        entityId: myId,
        displayName: myName,
        lat: pos.latitude,
        lng: pos.longitude,
        at: DateTime.now(),
        source: LocationFixSource.phone,
        accuracyM: pos.accuracy,
        threadId: threadId,
        live: true,
      ));
    } catch (_) {/* skip tick — next interval retries */}
  }

  Future<void> dispose() async {
    await stop();
    await _sessionController.close();
  }
}
