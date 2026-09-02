// SPDX-License-Identifier: AGPL-3.0
//
// Phase 2 chat — cloud vs offline bearer availability for composer UX.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/talk_bearer.dart';
import 'api_base.dart';
import 'ble_mesh_transport_service.dart';
import 'lan_service.dart';
import 'p2p_service.dart';

class ChatConnectivitySnapshot {
  const ChatConnectivitySnapshot({
    required this.cloudReachable,
    required this.lanRunning,
    required this.bleMeshRunning,
    required this.p2pRunning,
    required this.probedAt,
  });

  final bool cloudReachable;
  final bool lanRunning;
  final bool bleMeshRunning;
  final bool p2pRunning;
  final DateTime probedAt;

  bool get hasOfflineTextPath =>
      lanRunning || bleMeshRunning || p2pRunning;

  /// Bearers OfflineRouter can try after cloud (text only).
  List<TalkBearer> get availableOfflineBearers {
    final out = <TalkBearer>[];
    if (lanRunning) out.add(TalkBearer.lan);
    if (p2pRunning) out.add(TalkBearer.p2p);
    if (bleMeshRunning) out.add(TalkBearer.bleMesh);
    return out;
  }

  String get statusLine {
    if (cloudReachable && !hasOfflineTextPath) {
      return 'Cloud connected';
    }
    if (!cloudReachable && hasOfflineTextPath) {
      final names = availableOfflineBearers.map((b) => b.label).join(', ');
      return 'Offline · text via $names';
    }
    if (!cloudReachable) {
      return 'No cloud · start Offline LAN or BLE mesh for text';
    }
    return 'Cloud + offline text paths available';
  }
}

final chatConnectivityProvider =
    FutureProvider.autoDispose<ChatConnectivitySnapshot>((ref) async {
  final lan = ref.read(lanServiceProvider);
  final ble = ref.read(bleMeshTransportServiceProvider);
  final p2p = ref.read(p2pServiceProvider);
  final cloud = await ApiBase.isCloudReachable();
  return ChatConnectivitySnapshot(
    cloudReachable: cloud,
    lanRunning: lan.isRunning,
    bleMeshRunning: ble.isRunning,
    p2pRunning: p2p.isRunning && p2p.connectedDevice != null,
    probedAt: DateTime.now(),
  );
});

/// Media uploads require cloud — attachments cannot ride LAN/BLE (Phase 2 policy).
class ChatMediaPolicy {
  ChatMediaPolicy._();

  static const offlineMediaMessage =
      'Photos, video, voice, and files need internet. '
      'Text and location pins work offline via LAN or BLE mesh.';

  static Future<bool> canUploadToCloud() => ApiBase.isCloudReachable();

  static Future<bool> ensureCloudOrExplain() async {
    return canUploadToCloud();
  }
}
