// SPDX-License-Identifier: AGPL-3.0
//
// Manual LAN peer bind for a 1:1 chat thread (mDNS fallback — P3 Wave 2).

import 'package:flutter/material.dart';

import '../../services/thread_peer_registry.dart';

Future<void> showOfflinePeerSheet({
  required BuildContext context,
  required String threadId,
  String? peerUserId,
  String? peerDisplayName,
}) async {
  final hostCtrl = TextEditingController();
  final portCtrl = TextEditingController(text: '5000');
  final nameCtrl = TextEditingController(text: peerDisplayName ?? '');

  final existing = await ThreadPeerRegistry.instance.manualEndpointFor(threadId);
  if (existing != null) {
    hostCtrl.text = existing.host;
    portCtrl.text = '${existing.port}';
    if (existing.displayName != null) {
      nameCtrl.text = existing.displayName!;
    }
  }

  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            24 + MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Offline LAN peer',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'When mDNS is blocked (guest Wi‑Fi, AP isolation), enter the '
                'peer\'s IP:port from Offline LAN → hint line.',
                style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: hostCtrl,
                decoration: const InputDecoration(
                  labelText: 'Host (IP)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Display name (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final host = hostCtrl.text.trim();
                  final port = int.tryParse(portCtrl.text.trim()) ?? 0;
                  if (host.isEmpty || port <= 0) return;
                  await ThreadPeerRegistry.instance.bindManualLanEndpoint(
                    threadId,
                    host: host,
                    port: port,
                    peerUserId: peerUserId,
                    displayName: nameCtrl.text.trim().isEmpty
                        ? null
                        : nameCtrl.text.trim(),
                  );
                  if (ctx.mounted) Navigator.pop(ctx);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('LAN endpoint saved — $host:$port')),
                    );
                  }
                },
                child: const Text('Save for this chat'),
              ),
            ],
          ),
        ),
      );
    },
  );

  hostCtrl.dispose();
  portCtrl.dispose();
  nameCtrl.dispose();
}
