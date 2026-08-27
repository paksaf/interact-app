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

/// Rendering states for the presence bubble (roadmap §10):
/// green = active · amber = busy (in a call) · grey/none = offline.
enum PresenceStatus { offline, active, busy }

class PresenceService {
  PresenceService(this._api);
  final TalkApi _api;

  Timer? _beat;
  final Map<String, PresenceInfo> _info = {};

  /// True if [key] (phone or user id) is currently online per the last poll.
  bool isOnline(String? key) => key != null && (_info[key]?.online ?? false);

  /// Tri-state presence for [key]. `busy` only fires once the backend sends
  /// rich presence payloads (client is forward-compatible already).
  PresenceStatus status(String? key) {
    final i = key == null ? null : _info[key];
    if (i == null || !i.online) return PresenceStatus.offline;
    return i.busy ? PresenceStatus.busy : PresenceStatus.active;
  }

  /// Last-seen timestamp for [key], when the backend provides it.
  DateTime? lastSeen(String? key) => key == null ? null : _info[key]?.lastSeen;

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

  /// Fire a single immediate heartbeat (e.g. on app resume, so peers see us
  /// online again without waiting for the next 45s tick). Best-effort.
  void beatNow() => _api.heartbeat();

  /// Refresh presence for the given peer keys. Safe to call on list loads;
  /// merges into the cache. Returns the fresh map for convenience.
  Future<Map<String, PresenceInfo>> refresh(List<String> keys) async {
    final res = await _api.presence(keys);
    _info.addAll(res);
    return res;
  }
}

final presenceServiceProvider =
    Provider<PresenceService>((ref) => PresenceService(ref.read(talkApiProvider)));
