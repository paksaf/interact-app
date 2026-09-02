// SPDX-License-Identifier: AGPL-3.0
//
// Maps 1:1 chat threads to LAN/BLE peer ids (userId from auth / mDNS peerId).

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'lan_service.dart';

class ThreadPeerRegistry {
  ThreadPeerRegistry._();
  static final ThreadPeerRegistry instance = ThreadPeerRegistry._();

  static const _threadPeerKey = 'talk_thread_peer_user_v1';
  static const _manualLanKey = 'talk_thread_lan_endpoint_v1';
  static const _peerThreadKey = 'talk_peer_thread_v1';

  Future<void> bindThreadPeer(String threadId, String? peerUserId) async {
    if (threadId.isEmpty || peerUserId == null || peerUserId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final map = _readMap(prefs, _threadPeerKey);
    map[threadId] = peerUserId;
    await prefs.setString(_threadPeerKey, jsonEncode(map));
    final reverse = _readMap(prefs, _peerThreadKey);
    reverse[peerUserId] = threadId;
    await prefs.setString(_peerThreadKey, jsonEncode(reverse));
  }

  Future<String?> peerUserIdFor(String threadId) async {
    if (threadId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final map = _readMap(prefs, _threadPeerKey);
    return map[threadId];
  }

  Future<String?> threadIdForPeerUser(String peerUserId) async {
    if (peerUserId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final map = _readMap(prefs, _peerThreadKey);
    return map[peerUserId];
  }

  /// Learn thread ↔ peer from inbound LAN/BLE when envelope carries threadId.
  Future<void> noteInboundPeer({
    required String peerUserId,
    required String threadId,
  }) async {
    await bindThreadPeer(threadId, peerUserId);
  }

  /// When mDNS is blocked, persist a manual IP:port for this thread.
  Future<void> bindManualLanEndpoint(
    String threadId, {
    required String host,
    required int port,
    String? peerUserId,
    String? displayName,
  }) async {
    if (threadId.isEmpty || host.trim().isEmpty || port <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final map = _readMap(prefs, _manualLanKey);
    map[threadId] = jsonEncode({
      'host': host.trim(),
      'port': port,
      if (peerUserId != null && peerUserId.isNotEmpty) 'peerUserId': peerUserId,
      if (displayName != null && displayName.isNotEmpty) 'displayName': displayName,
    });
    await prefs.setString(_manualLanKey, jsonEncode(map));
    if (peerUserId != null && peerUserId.isNotEmpty) {
      await bindThreadPeer(threadId, peerUserId);
    }
  }

  /// Pick the LAN peer for a 1:1 thread — match mDNS peerId to peerUserId first.
  Future<LanPeer?> resolveLanPeer({
    required String threadId,
    required List<LanPeer> discovered,
    String? targetPeerUserId,
    required LanService lan,
  }) async {
    var peerUserId = targetPeerUserId;
    peerUserId ??= await peerUserIdFor(threadId);
    if (peerUserId != null && peerUserId.isNotEmpty) {
      for (final p in discovered) {
        if (p.peerId == peerUserId) return p;
      }
    }

    final manual = await manualEndpointFor(threadId);
    if (manual != null && manual.host.isNotEmpty && manual.port > 0) {
      return lan.addManualPeer(
        host: manual.host,
        port: manual.port,
        peerId: manual.peerUserId,
        displayName: manual.displayName,
      );
    }
    return null;
  }

  Future<ManualLanEndpoint?> manualEndpointFor(String threadId) async {
    final prefs = await SharedPreferences.getInstance();
    final map = _readMap(prefs, _manualLanKey);
    final raw = map[threadId];
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ManualLanEndpoint(
        host: (j['host'] as String?) ?? '',
        port: (j['port'] as num?)?.toInt() ?? 0,
        peerUserId: j['peerUserId'] as String?,
        displayName: j['displayName'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _readMap(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return {};
  }
}

class ManualLanEndpoint {
  const ManualLanEndpoint({
    required this.host,
    required this.port,
    this.peerUserId,
    this.displayName,
  });
  final String host;
  final int port;
  final String? peerUserId;
  final String? displayName;
}
