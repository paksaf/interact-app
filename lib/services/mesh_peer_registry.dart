// SPDX-License-Identifier: AGPL-3.0
//
// Trusted mesh pubkey ↔ Talk userId bindings — audit step 6.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/offline/mesh_identity_card.dart';

class MeshPeerBinding {
  const MeshPeerBinding({
    required this.meshPubKeyHex,
    required this.talkUserId,
    required this.displayName,
    required this.trustedAt,
    this.phone,
  });

  final String meshPubKeyHex;
  final String talkUserId;
  final String displayName;
  final DateTime trustedAt;
  final String? phone;

  Map<String, dynamic> toJson() => {
        'meshPubKeyHex': meshPubKeyHex,
        'talkUserId': talkUserId,
        'displayName': displayName,
        'trustedAt': trustedAt.toIso8601String(),
        if (phone != null) 'phone': phone,
      };

  factory MeshPeerBinding.fromJson(Map<String, dynamic> j) => MeshPeerBinding(
        meshPubKeyHex: (j['meshPubKeyHex'] as String?) ?? '',
        talkUserId: (j['talkUserId'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? 'Peer',
        trustedAt:
            DateTime.tryParse(j['trustedAt'] as String? ?? '') ?? DateTime.now(),
        phone: j['phone'] as String?,
      );
}

class MeshPeerRegistry {
  MeshPeerRegistry._();
  static final MeshPeerRegistry instance = MeshPeerRegistry._();

  static const _key = 'talk_mesh_peer_bindings_v1';

  Future<void> trustCard(MeshIdentityCard card) async {
    if (!looksLikeMeshPubKeyHex(card.meshPubKeyHex)) return;
    final binding = MeshPeerBinding(
      meshPubKeyHex: card.meshPubKeyHex.toLowerCase(),
      talkUserId: card.userId,
      displayName: card.displayName,
      trustedAt: DateTime.now(),
      phone: card.phone,
    );
    final prefs = await SharedPreferences.getInstance();
    final map = _read(prefs);
    map[binding.meshPubKeyHex] = jsonEncode(binding.toJson());
    map['uid:${binding.talkUserId}'] = binding.meshPubKeyHex;
    await prefs.setString(_key, jsonEncode(map));
  }

  Future<MeshPeerBinding?> lookupByPubKey(String meshPubKeyHex) async {
    if (!looksLikeMeshPubKeyHex(meshPubKeyHex)) return null;
    final prefs = await SharedPreferences.getInstance();
    final map = _read(prefs);
    final raw = map[meshPubKeyHex.toLowerCase()];
    if (raw == null) return null;
    try {
      return MeshPeerBinding.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<String?> meshPubKeyForUser(String talkUserId) async {
    if (talkUserId.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final map = _read(prefs);
    final pub = map['uid:$talkUserId'];
    return pub is String ? pub : null;
  }

  Future<List<MeshPeerBinding>> listBindings() async {
    final prefs = await SharedPreferences.getInstance();
    final map = _read(prefs);
    final out = <MeshPeerBinding>[];
    for (final entry in map.entries) {
      if (entry.key.startsWith('uid:')) continue;
      try {
        out.add(MeshPeerBinding.fromJson(
          jsonDecode(entry.value) as Map<String, dynamic>,
        ));
      } catch (_) {}
    }
    out.sort((a, b) => b.trustedAt.compareTo(a.trustedAt));
    return out;
  }

  Map<String, String> _read(SharedPreferences prefs) {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      }
    } catch (_) {}
    return {};
  }
}
