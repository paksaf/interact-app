import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:interact/services/lan_service.dart';
import 'package:interact/services/thread_peer_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  test('resolveLanPeer matches mDNS peerId to thread peerUserId', () async {
    final registry = ThreadPeerRegistry.instance;
    const threadId = 'thread-abc';
    const peerUserId = 'user-42';
    await registry.bindThreadPeer(threadId, peerUserId);

    final lan = LanService();
    final discovered = [
      LanPeer(
        peerId: 'user-other',
        displayName: 'Other',
        host: '192.168.1.2',
        port: 5000,
      ),
      LanPeer(
        peerId: peerUserId,
        displayName: 'Peer',
        host: '192.168.1.3',
        port: 5001,
      ),
    ];

    final match = await registry.resolveLanPeer(
      threadId: threadId,
      discovered: discovered,
      lan: lan,
    );
    expect(match?.peerId, peerUserId);
    expect(match?.host, '192.168.1.3');
  });

  test('resolveLanPeer uses manual endpoint when mDNS peer missing', () async {
    final registry = ThreadPeerRegistry.instance;
    const threadId = 'thread-manual';
    final lan = LanService();
    await registry.bindManualLanEndpoint(
      threadId,
      host: '192.168.100.84',
      port: 50759,
      peerUserId: 'user-manual',
      displayName: 'Samsung',
    );

    final match = await registry.resolveLanPeer(
      threadId: threadId,
      discovered: const [],
      lan: lan,
    );
    expect(match?.host, '192.168.100.84');
    expect(match?.port, 50759);
  });
}
