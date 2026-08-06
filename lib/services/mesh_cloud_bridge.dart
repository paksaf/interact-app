// SPDX-License-Identifier: AGPL-3.0
//
// Mesh / LAN → cloud bridge. When uplink exists, inbound offline frames are
// forwarded into Talk chat via ChatApi / OutboxService (never a second backend).
//
// Payload formats:
//   talk:0|<peerPhone>|<body>   — open/create DM by phone
//   talk:1|<threadId>|<body>    — post into an existing thread
//   talk:<free text>            — parked until user picks a target (no auto)

import 'package:flutter/foundation.dart';

import 'chat_api.dart';

class MeshCloudBridge {
  MeshCloudBridge._();
  static final MeshCloudBridge instance = MeshCloudBridge._();

  ChatApi? _api;

  void bind(ChatApi api) => _api = api;

  /// Parse a `talk:` mesh frame and try to forward to cloud.
  Future<bool> ingestTalkFrame(String raw) async {
    final api = _api;
    if (api == null) return false;
    final body = raw.startsWith('talk:') ? raw.substring(5) : raw;
    if (body.isEmpty) return false;

    try {
      if (body.startsWith('1|')) {
        final rest = body.substring(2);
        final sep = rest.indexOf('|');
        if (sep <= 0) return false;
        final threadId = rest.substring(0, sep);
        final text = rest.substring(sep + 1).trim();
        if (threadId.isEmpty || text.isEmpty) return false;
        await api.sendText(threadId, text);
        return true;
      }
      if (body.startsWith('0|')) {
        final rest = body.substring(2);
        final sep = rest.indexOf('|');
        if (sep <= 0) return false;
        final phone = rest.substring(0, sep).trim();
        final text = rest.substring(sep + 1).trim();
        if (phone.isEmpty || text.isEmpty) return false;
        final result = await api.createDirectThread(peerPhone: phone);
        switch (result) {
          case DirectThreadFound(:final thread):
            await api.sendText(thread.id, text);
            return true;
          case DirectThreadUnregistered():
            return false;
        }
      }
      // Free text — no auto-forward without an address.
      if (kDebugMode) {
        debugPrint('[mesh-bridge] free-text parked (no target): $body');
      }
      return false;
    } catch (e) {
      if (kDebugMode) debugPrint('[mesh-bridge] forward failed: $e');
      return false;
    }
  }

  /// Best-effort: treat LAN chat body as a talk frame when prefixed.
  Future<bool> ingestLanBody(String body) async {
    final t = body.trim();
    if (t.startsWith('talk:')) return ingestTalkFrame(t);
    return false;
  }

  /// Encode an outbound mesh frame for a known thread.
  static String encodeForThread(String threadId, String text) =>
      'talk:1|$threadId|${text.trim()}';

  /// Encode an outbound mesh frame addressed by phone.
  static String encodeForPhone(String phone, String text) =>
      'talk:0|$phone|${text.trim()}';
}
