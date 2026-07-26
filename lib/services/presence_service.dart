// SPDX-License-Identifier: AGPL-3.0
//
// PresenceService — the "who's active" layer. While the app is foreground it
// sends a heartbeat to the hub every 45s (so peers can see US online) and
// exposes a cached online-map for rendering the green dots on Contacts/Chats.
//
// Backend: GET /api/v1/talk/presence + POST .../beat are live on
// qurbanisahulat (TalkPresence table). TalkApi still degrades to empty maps
// on network/404 so a blip never breaks the UI.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'talk_api.dart';

class PresenceService {
  PresenceService(this._api);
  final TalkApi _api;

  Timer? _beat;
  final Map<String, bool> _online = {};

  /// True if [key] (phone or user id) is currently online per the last poll.
  bool isOnline(String? key) => key != null && (_online[key] ?? false);

  /// Begin the foreground heartbeat loop (idempotent). Call from the shell.
  void start() {
    if (_beat != null) return;
    _api.heartbeat(); // immediate first beat
    _beat = Timer.periodic(const Duration(seconds: 45), (_) => _api.heartbeat());
  }

  void stop() {
    _beat?.cancel();
    _beat = null;
  }

  /// Refresh the online-map for the given peer keys. Safe to call on list
  /// loads; merges into the cache. Returns the fresh map for convenience.
  Future<Map<String, bool>> refresh(List<String> keys) async {
    final res = await _api.presence(keys);
    _online.addAll(res);
    return res;
  }
}

final presenceServiceProvider =
    Provider<PresenceService>((ref) => PresenceService(ref.read(talkApiProvider)));
