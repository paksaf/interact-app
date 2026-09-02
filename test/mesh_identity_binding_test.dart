// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/offline/mesh_identity_card.dart';
import 'package:interact/services/mesh_peer_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sahl_mesh/sahl_mesh.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('MeshIdentityCard round-trip parse', () {
    final pubHex = 'a' * 64;
    final sigHex = 'ab' * 32;
    final card = MeshIdentityCard(
      userId: 'user-1',
      displayName: 'Ahmed',
      meshPubKeyHex: pubHex,
      phone: '+923001234567',
      signatureHex: sigHex,
    );
    final parsed = MeshIdentityCard.parse(card.toQrPayload());
    expect(parsed?.userId, 'user-1');
    expect(parsed?.displayName, 'Ahmed');
    expect(parsed?.meshPubKeyHex, pubHex);
  });

  test('signed card verifies', () async {
    final id = await MeshIdentity.generate();
    final card = await MeshIdentityCard.signed(
      identity: id,
      userId: 'user-99',
      displayName: 'Test peer',
    );
    expect(await MeshIdentityCard.verifySignature(card), isTrue);
  });

  test('MeshPeerRegistry stores pubkey to user lookup', () async {
    final pub = 'b' * 64;
    await MeshPeerRegistry.instance.trustCard(
      MeshIdentityCard(
        userId: 'peer-7',
        displayName: 'Peer Seven',
        meshPubKeyHex: pub,
      ),
    );
    final binding = await MeshPeerRegistry.instance.lookupByPubKey(pub);
    expect(binding?.talkUserId, 'peer-7');
    expect(await MeshPeerRegistry.instance.meshPubKeyForUser('peer-7'), pub);
  });

  test('looksLikeMeshPubKeyHex', () {
    expect(looksLikeMeshPubKeyHex('a' * 64), isTrue);
    expect(looksLikeMeshPubKeyHex('user-uuid'), isFalse);
  });
}
