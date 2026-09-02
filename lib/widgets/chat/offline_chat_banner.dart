// SPDX-License-Identifier: AGPL-3.0
//
// Phase 2 chat thread banner — honest cloud/offline/outbox state.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/chat_connectivity_service.dart';
import '../../services/e2e_crypto_service.dart';
import 'offline_peer_sheet.dart';

class OfflineChatBanner extends ConsumerWidget {
  const OfflineChatBanner({
    super.key,
    required this.threadId,
    required this.outboxPending,
    this.peerUserId,
    this.peerDisplayName,
    this.isLocalOnlyThread = false,
    this.isGroup = false,
  });

  final String threadId;
  final int outboxPending;
  final String? peerUserId;
  final String? peerDisplayName;
  final bool isLocalOnlyThread;
  final bool isGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (isLocalOnlyThread) return const SizedBox.shrink();

    final conn = ref.watch(chatConnectivityProvider);
    final cs = Theme.of(context).colorScheme;
    final e2e = E2eCryptoService.instance.status;

    return conn.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (snap) {
        final showBanner = !snap.cloudReachable ||
            outboxPending > 0 ||
            snap.hasOfflineTextPath;
        if (!showBanner) return const SizedBox.shrink();

        final offlineChip = snap.availableOfflineBearers
            .map((b) => b.label)
            .join(' · ');

        return Material(
          color: snap.cloudReachable
              ? cs.secondaryContainer.withValues(alpha: 0.45)
              : cs.errorContainer.withValues(alpha: 0.35),
          child: ListTile(
            dense: true,
            leading: Icon(
              snap.cloudReachable ? Icons.swap_horiz : Icons.cloud_off,
              color: snap.cloudReachable ? cs.primary : cs.error,
              size: 22,
            ),
            title: Text(
              snap.statusLine,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (outboxPending > 0)
                  Text(
                    '$outboxPending queued — flushing via OfflineRouter',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                if (!snap.cloudReachable && snap.hasOfflineTextPath)
                  Text(
                    'Active: $offlineChip · sensors tick = handed to radio',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                if (e2e == E2eStatus.notAvailable)
                  Text(
                    'Transport encrypted (HTTPS). Message E2E: ${E2eCryptoService.instance.userLabel}',
                    style: TextStyle(fontSize: 10, color: cs.outline),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isGroup)
                  IconButton(
                    tooltip: 'Offline LAN peer',
                    icon: const Icon(Icons.lan_outlined, size: 20),
                    onPressed: () => showOfflinePeerSheet(
                      context: context,
                      threadId: threadId,
                      peerUserId: peerUserId,
                      peerDisplayName: peerDisplayName,
                    ),
                  ),
                IconButton(
                  tooltip: 'Offline hub',
                  icon: const Icon(Icons.hub_outlined, size: 20),
                  onPressed: () => context.push('/offline-hub'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
