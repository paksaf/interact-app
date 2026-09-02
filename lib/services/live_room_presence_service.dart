// SPDX-License-Identifier: AGPL-3.0
//
// Room-scoped presence beats for townhall audience analytics.
// Mirrors app-wide PresenceService → POST /talk/presence/beat, but scoped
// to a live room code with focus (foreground/background) telemetry.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'live_api.dart';
import 'livekit_service.dart';

final liveRoomPresenceServiceProvider = Provider<LiveRoomPresenceService>((ref) {
  return LiveRoomPresenceService(ref.read(liveApiProvider));
});

class LiveRoomPresenceService {
  LiveRoomPresenceService(this._api);

  final LiveApi _api;
  Timer? _beat;
  String _roomCode = '';
  String _role = 'listener';
  bool _running = false;
  String _focus = 'foreground';

  Stream<LiveRoomAnalytics>? get analyticsStream => _analyticsCtrl?.stream;
  StreamController<LiveRoomAnalytics>? _analyticsCtrl;
  Timer? _poll;
  bool _pollHost = false;

  bool get isRunning => _running;

  /// Start beats when connected to a live room. Hosts also poll analytics.
  Future<void> start({
    required String roomCode,
    required String role,
    required bool pollAnalytics,
  }) async {
    await stop();
    _roomCode = roomCode;
    _role = role;
    _pollHost = pollAnalytics;
    _running = true;
    _focus = 'foreground';

    await _api.livePresenceBeat(
      roomCode: roomCode,
      role: role,
      focus: _focus,
      area: deviceAreaString(),
    );

    _beat = Timer.periodic(const Duration(seconds: 30), (_) {
      _api.livePresenceBeat(
        roomCode: _roomCode,
        role: _role,
        focus: _focus,
        area: deviceAreaString(),
      );
    });

    if (pollAnalytics) {
      _analyticsCtrl = StreamController<LiveRoomAnalytics>.broadcast();
      _poll = Timer.periodic(const Duration(seconds: 12), (_) => _fetchAnalytics());
      unawaited(_fetchAnalytics());
    }
  }

  void updateFocus(AppLifecycleState state) {
    final next = state == AppLifecycleState.resumed ? 'foreground' : 'background';
    if (next == _focus || !_running) return;
    _focus = next;
    _api.livePresenceBeat(
      roomCode: _roomCode,
      role: _role,
      focus: _focus,
      area: deviceAreaString(),
    );
  }

  Future<void> _fetchAnalytics() async {
    if (!_pollHost || _roomCode.isEmpty) return;
    final stats = await _api.liveAnalytics(_roomCode);
    if (stats != null && _analyticsCtrl != null && !_analyticsCtrl!.isClosed) {
      _analyticsCtrl!.add(stats);
    }
  }

  Future<void> stop() async {
    _beat?.cancel();
    _beat = null;
    _poll?.cancel();
    _poll = null;
    if (_running && _roomCode.isNotEmpty) {
      await _api.livePresenceLeave(_roomCode);
    }
    _running = false;
    _roomCode = '';
    await _analyticsCtrl?.close();
    _analyticsCtrl = null;
  }
}
