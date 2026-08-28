// SPDX-License-Identifier: AGPL-3.0
//
// BlockService — local blocked-contacts list (Me → Security & Privacy,
// previously a "Soon" placeholder). Fully client-side v1: the server has no
// block model yet (and Sahulat is deploy-frozen), so blocking works like a
// silent do-not-disturb per peer:
//   • their incoming call invites are ignored (never ring, never surface —
//     the caller just sees no-answer, same as WhatsApp's block behavior)
//   • their chat thread rows show a "Blocked" tag
// Keyed by THREAD id — that's the only stable peer identifier an incoming
// invite carries (no phone in the payload). Persisted in SharedPreferences
// as JSON [{t: threadId, n: displayName}].

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kPrefsKey = 'talk.blocked.v1';

class BlockedPeer {
  const BlockedPeer({required this.threadId, required this.name});
  final String threadId;
  final String name;
}

class BlockService extends ChangeNotifier {
  final Map<String, String> _byThread = {}; // threadId -> display name
  bool _loaded = false;

  bool get isLoaded => _loaded;
  List<BlockedPeer> get all => _byThread.entries
      .map((e) => BlockedPeer(threadId: e.key, name: e.value))
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  bool isBlocked(String? threadId) =>
      threadId != null && _byThread.containsKey(threadId);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final e in list) {
            if (e is Map && e['t'] is String) {
              _byThread[e['t'] as String] = (e['n'] as String?) ?? 'Blocked';
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[block] load failed: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> block(String threadId, String name) async {
    _byThread[threadId] = name;
    notifyListeners();
    await _persist();
  }

  Future<void> unblock(String threadId) async {
    _byThread.remove(threadId);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPrefsKey,
        jsonEncode([
          for (final e in _byThread.entries) {'t': e.key, 'n': e.value}
        ]),
      );
    } catch (e) {
      debugPrint('[block] persist failed: $e');
    }
  }
}

// Plain Provider (house style — see presenceServiceProvider). Screens that
// need reactivity wrap in ListenableBuilder(listenable: service).
final blockServiceProvider = Provider<BlockService>((ref) {
  final s = BlockService();
  s.ensureLoaded();
  return s;
});
