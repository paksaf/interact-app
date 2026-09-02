// SPDX-License-Identifier: AGPL-3.0
//
// Offline mesh ↔ Talk identity binding card — audit step 6 (QR v1; NFC later).

import 'dart:convert';
import 'dart:typed_data';

import 'package:sahl_mesh/sahl_mesh.dart';

class MeshIdentityCard {
  const MeshIdentityCard({
    required this.userId,
    required this.displayName,
    required this.meshPubKeyHex,
    this.phone,
    this.signatureHex,
  });

  static const version = 1;

  final String userId;
  final String displayName;
  final String meshPubKeyHex;
  final String? phone;
  final String? signatureHex;

  /// Canonical bytes signed by the mesh private key.
  Uint8List canonicalBytes() {
    final line =
        '$version|$userId|$displayName|$meshPubKeyHex|${phone ?? ''}';
    return Uint8List.fromList(utf8.encode(line));
  }

  Map<String, dynamic> toJson() => {
        'v': version,
        'userId': userId,
        'name': displayName,
        'meshPub': meshPubKeyHex,
        if (phone != null && phone!.isNotEmpty) 'phone': phone,
        if (signatureHex != null) 'sig': signatureHex,
      };

  String toQrPayload() => jsonEncode(toJson());

  static MeshIdentityCard? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final j = jsonDecode(trimmed) as Map<String, dynamic>;
      final v = (j['v'] as num?)?.toInt() ?? 0;
      if (v != version) return null;
      final pub = (j['meshPub'] as String?)?.trim() ?? '';
      final userId = (j['userId'] as String?)?.trim() ?? '';
      final name = (j['name'] as String?)?.trim() ?? '';
      if (pub.length != 64 || userId.isEmpty) return null;
      return MeshIdentityCard(
        userId: userId,
        displayName: name.isEmpty ? 'INTERACT peer' : name,
        meshPubKeyHex: pub.toLowerCase(),
        phone: j['phone'] as String?,
        signatureHex: (j['sig'] as String?)?.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Build a signed card for this device to show as QR.
  static Future<MeshIdentityCard> signed({
    required MeshIdentity identity,
    required String userId,
    required String displayName,
    String? phone,
  }) async {
    final pubHex = identity.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final card = MeshIdentityCard(
      userId: userId,
      displayName: displayName,
      meshPubKeyHex: pubHex,
      phone: phone,
    );
    final sig = await identity.sign(card.canonicalBytes());
    return MeshIdentityCard(
      userId: userId,
      displayName: displayName,
      meshPubKeyHex: pubHex,
      phone: phone,
      signatureHex: sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    );
  }

  /// Verify [signatureHex] matches [meshPubKeyHex] over [canonicalBytes].
  static Future<bool> verifySignature(MeshIdentityCard card) async {
    final sigHex = card.signatureHex;
    if (sigHex == null || sigHex.length < 32) return false;
    final pub = _hexToBytes(card.meshPubKeyHex);
    final sig = _hexToBytes(sigHex);
    if (pub == null || sig == null) return false;
    return MeshIdentity.verify(
      preimage: card.canonicalBytes(),
      signature: sig,
      senderPubKey: pub,
    );
  }

  static Uint8List? _hexToBytes(String hex) {
    if (hex.length.isOdd) return null;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      if (byte == null) return null;
      out[i] = byte;
    }
    return out;
  }
}

bool looksLikeMeshPubKeyHex(String value) =>
    RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value.trim());
