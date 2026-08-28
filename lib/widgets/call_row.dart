// SPDX-License-Identifier: AGPL-3.0
//
// CallRow — one recent-call entry. Extracted from calls_tab.dart 2026-08-27
// so the full Call-history screen (Me → Security & Privacy) can reuse it.
//
// Naming gap fixed on extraction: server call-log rows minted via
// /talk/live/token carry NO peer fields (createCallLogBestEffort logs the
// initiator only — enriching it is a Sahulat change, frozen). Those rows
// used to render as "Unknown"; now ad-hoc `talk:CODE` rows label themselves
// "Video meeting · CODE" / "Walkie · CODE" instead.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../services/call_signaling.dart';
import '../services/device_contacts_index.dart';
import '../services/talk_flags.dart';
import '../utils/chat_formatters.dart';
import '../utils/display_name.dart';

class CallRow extends ConsumerWidget {
  const CallRow({super.key, required this.row});
  final Map<String, dynamic> row;

  /// Best-effort peer phone from the call-log row — the shape varies, so try
  /// the common keys. Null when the log carries no number.
  String? _peerPhone() {
    final pp = row['peerPhone'];
    if (pp is String && pp.isNotEmpty) return pp;
    final p = row['phone'];
    if (p is String && p.isNotEmpty) return p;
    final peer = row['peer'];
    if (peer is Map && peer['phone'] is String) return peer['phone'] as String;
    return null;
  }

  /// Direction is one of 'incoming' / 'outgoing' / 'missed' — server
  /// supplies it directly when known; otherwise we infer from
  /// (durationSec == 0 ? missed : incoming). Outgoing requires the
  /// log row to flag `direction:'outgoing'` explicitly.
  String _direction() {
    final d = row['direction'] as String?;
    if (d != null && d.isNotEmpty) return d;
    final dur = row['durationSec'] as int? ?? 0;
    return dur == 0 ? 'missed' : 'incoming';
  }

  /// When name resolution bottoms out at "Unknown", describe the ROOM
  /// instead — an ad-hoc `talk:CODE` row is a meeting, not a person.
  String _roomFallback(String resolved, String mode) {
    if (resolved != 'Unknown') return resolved;
    final subjectId = row['subjectId']?.toString() ?? '';
    final code = subjectId.startsWith('talk:')
        ? subjectId.substring(5).toUpperCase()
        : '';
    final kind = switch (mode) {
      'ptt' => 'Walkie',
      'voice' => 'Voice call',
      _ => 'Video meeting',
    };
    return code.isEmpty ? kind : '$kind · $code';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final mode = row['mode'] as String? ?? 'video';
    final phone = _peerPhone();
    // Prefer a device-book name over the backend's generic "Talk 1469" label.
    final peer = _roomFallback(
      resolveDisplayName(
        deviceName: ref.read(deviceContactsIndexProvider).nameFor(phone),
        backendName: row['peerName'] as String?,
        phone: phone,
      ),
      mode,
    );
    final dur = row['durationSec'] as int? ?? 0;
    final dir = _direction();
    final startedAtStr = row['startedAt'] as String?;
    final startedAt =
        startedAtStr != null ? DateTime.tryParse(startedAtStr) : null;

    final dirIcon = switch (dir) {
      'outgoing' => Icons.call_made,
      'missed' => Icons.call_missed,
      _ => Icons.call_received,
    };
    final dirColor = switch (dir) {
      'outgoing' => cs.primary,
      'missed' => cs.error,
      _ => cs.tertiary,
    };

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: CircleAvatar(
        backgroundColor: cs.primaryContainer,
        child: Icon(
          mode == 'voice' ? Icons.phone : Icons.videocam,
          color: cs.onPrimaryContainer,
          size: 20,
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              peer,
              style: TextStyle(
                color: dir == 'missed' ? cs.error : null,
                fontWeight:
                    dir == 'missed' ? FontWeight.w700 : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (startedAt != null)
            Text(
              relTime(startedAt),
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
        ],
      ),
      subtitle: Row(
        children: [
          Icon(dirIcon, size: 13, color: dirColor),
          const SizedBox(width: 4),
          Text(
            dir == 'missed' ? 'Missed' : callDuration(dur),
            style: TextStyle(
              fontSize: 12,
              color: dir == 'missed' ? cs.error : cs.outline,
            ),
          ),
        ],
      ),
      trailing: IconButton(
        icon: Icon(mode == 'voice' ? Icons.phone : Icons.videocam),
        tooltip: 'Call back',
        onPressed: () async {
          final threadId = row['threadId']?.toString() ??
              (row['subjectType']?.toString() == 'thread'
                  ? row['subjectId']?.toString()
                  : null);
          if (threadId != null && threadId.isNotEmpty) {
            final inviteId =
                await ref.read(callSignalingProvider).ring(threadId, mode);
            if (!context.mounted) return;
            GoRouter.of(context).push(
              TalkFlags.outgoingCallLocation(
                threadId: threadId,
                mode: mode,
                inviteId: inviteId,
                peerName: row['peerName'] as String?,
              ),
            );
            return;
          }
          // Ad-hoc talk:CODE rows have no peer thread. Rejoining the old
          // code as a guest (host=false) is a dead room. Host a new call.
          if (!context.mounted) return;
          GoRouter.of(context).push(
            Uri(
              path: TalkFlags.callRoomPath(),
              queryParameters: {'host': 'true', 'mode': mode},
            ).toString(),
          );
        },
      ),
    );
  }
}
