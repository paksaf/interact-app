// SPDX-License-Identifier: AGPL-3.0
//
// Waiting-room queue — host admits or denies browser guests (policy=admit).

import 'package:flutter/material.dart';

import '../../models/guest_join.dart';

class GuestWaitingRoomPanel extends StatelessWidget {
  const GuestWaitingRoomPanel({
    super.key,
    required this.waiting,
    required this.onAdmit,
    required this.onDeny,
    this.busy = false,
  });

  final List<GuestJoinRequest> waiting;
  final void Function(GuestJoinRequest request) onAdmit;
  final void Function(GuestJoinRequest request) onDeny;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (waiting.isEmpty) return const SizedBox.shrink();
    return Positioned(
      top: 56,
      left: 16,
      width: 300,
      bottom: 112,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  const Icon(Icons.meeting_room, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Waiting room (${waiting.length})',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: waiting.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                itemBuilder: (context, i) {
                  final r = waiting[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      r.displayName,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    subtitle: r.createdAt != null
                        ? Text(
                            _relTime(r.createdAt!),
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          )
                        : null,
                    trailing: busy
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Deny',
                                icon: const Icon(Icons.close, color: Colors.redAccent),
                                onPressed: () => onDeny(r),
                              ),
                              IconButton(
                                tooltip: 'Admit',
                                icon: const Icon(Icons.check, color: Colors.greenAccent),
                                onPressed: () => onAdmit(r),
                              ),
                            ],
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relTime(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    return '${diff.inHours}h ago';
  }
}
