// SPDX-License-Identifier: AGPL-3.0
//
// Calls — the DEFAULT landing tab for INTERACT. Voice/video first.
// Top of screen: two big primary buttons (New meeting / Join with code).
// Below: recent call history from /api/v1/meetings/log (already live).
//
// Polish pass (2026-05-22):
// - withOpacity → withValues(alpha:) (Flutter 3.27+ deprecation)
// - Direction badge per row (incoming / outgoing / missed)
// - Time-since-call timestamp (Today 14:32, Yesterday, weekday, date)
// - Empty state hints at "Join with code" too
// - "All" button is now a future-stub but no longer dead-clickable
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/call_signaling.dart';
import '../../services/device_contacts_index.dart';
import '../../services/location_service.dart';
import '../../services/talk_api.dart';
import '../../services/talk_flags.dart';
import '../../services/voice/voice_commands.dart';
import '../../utils/chat_formatters.dart';
import '../../utils/display_name.dart';
import '../../widgets/branded_app_bar.dart';

class CallsTab extends ConsumerStatefulWidget {
  const CallsTab({super.key});
  @override
  ConsumerState<CallsTab> createState() => _CallsTabState();
}

class _CallsTabState extends ConsumerState<CallsTab> {
  late Future<List<Map<String, dynamic>>> _history;

  // Personalised header subtitle — starts generic, upgrades to
  // "Good evening · Multan" once location resolves (silently stays generic if
  // permission is denied). See services/location_service.dart.
  String _subtitle = 'Voice & video first';

  @override
  void initState() {
    super.initState();
    _history = ref.read(talkApiProvider).callHistory();
    _resolvePlace();
    // Warm the read-only device-contact index so recent-call rows can show a
    // real name instead of a generic "Talk 1469" label. Best-effort; a single
    // rebuild once it's ready. Never prompts, never throws.
    ref.read(deviceContactsIndexProvider).ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _resolvePlace() async {
    final loc = ref.read(locationServiceProvider);
    final info = loc.cached ?? await loc.resolve();
    if (!mounted || info == null) return;
    setState(() => _subtitle = info.label);
  }

  Future<void> _newMeeting({String mode = 'video'}) async {
    try {
      // host=true makes MeetingRoomScreen mint a fresh room via
      // createRoom() — we don't need the code from talk_api here, the
      // route handles it. Pass mode for voice-only meetings.
      if (!mounted) return;
      context.push('/room?host=true&mode=$mode');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start meeting: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Voice assistant lives in the app bar (not a FAB). A bottom-right FAB
      // sat on top of Recent calls and "bumped" the Calls dashboard on Samsung.
      appBar: BrandedAppBar(
        title: 'INTERACT',
        subtitle: _subtitle,
        showBrandGlyph: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.mic_none),
            tooltip: 'Voice command',
            onPressed: () =>
                VoiceCommands.instance.listenAndDispatch(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'Camera background effects',
            onPressed: () => context.push('/camera-effects'),
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Scan invite QR',
            onPressed: () => context.push('/invite'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          // Block-body setState (arrow form returns the Future → Flutter throws).
          final f = ref.read(talkApiProvider).callHistory();
          setState(() {
            _history = f;
          });
          await f;
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Primary action row — two large tiles, calls-first
            Row(
              children: [
                Expanded(
                  child: _PrimaryAction(
                    icon: Icons.video_call,
                    color: cs.primary,
                    label: 'New meeting',
                    subtitle: 'Start now, share code',
                    onTap: () => _newMeeting(mode: 'video'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _PrimaryAction(
                    icon: Icons.dialpad,
                    color: cs.secondary,
                    label: 'Join with code',
                    subtitle: 'Enter or scan',
                    onTap: () => context.push('/invite'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Dial a number / email → resolve peer → ring → 1:1 call.
            _SecondaryAction(
              icon: Icons.dialpad_outlined,
              label: 'Dial a number',
              subtitle: 'Call by phone number or email',
              onTap: () => context.push('/dialpad'),
            ),
            const SizedBox(height: 10),
            // Secondary "Voice only" tile — picked up by users on patchy
            // connections, no auto-ring yet but mode=voice gets reflected
            // in createRoom + leathx-signaling auth.
            _SecondaryAction(
              icon: Icons.phone_in_talk_outlined,
              label: 'Voice-only meeting',
              subtitle: 'Lower bandwidth — useful on slow networks',
              onTap: () => _newMeeting(mode: 'voice'),
            ),
            const SizedBox(height: 10),
            // Group voice surfaces moved here from the removed Menu tab
            // (Phase-1 redesign). Reuse the existing TownhallEntryScreen.
            _SecondaryAction(
              icon: Icons.groups_2_outlined,
              label: 'Townhall',
              subtitle: 'Multi-party conference — host or join with a code',
              onTap: () => context.push('/townhall'),
            ),
            const SizedBox(height: 10),
            _SecondaryAction(
              icon: Icons.podcasts_outlined,
              label: 'Walkie',
              subtitle: 'Hold-to-speak push-to-talk channel',
              onTap: () => context.push('/walkie'),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  'Recent calls',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('All'),
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Full history screen — Phase 1.5',
                        ),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: _history,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Column(
                      children: [
                        Icon(Icons.wifi_off, size: 36, color: cs.outline),
                        const SizedBox(height: 10),
                        Text(
                          'Couldn’t load recent calls',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${snap.error}'.replaceFirst('Exception: ', ''),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: cs.outline),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: () {
                            setState(() {
                              _history =
                                  ref.read(talkApiProvider).callHistory();
                            });
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return _EmptyCallState(
                    onNew: () => _newMeeting(),
                    onJoin: () => context.push('/invite'),
                  );
                }
                return Column(
                  children: rows.map((r) => _CallRow(row: r)).toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(height: 14),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: cs.primary, size: 24),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallRow extends ConsumerWidget {
  const _CallRow({required this.row});
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final mode = row['mode'] as String? ?? 'video';
    final phone = _peerPhone();
    // Prefer a device-book name over the backend's generic "Talk 1469" label.
    final peer = resolveDisplayName(
      deviceName: ref.read(deviceContactsIndexProvider).nameFor(phone),
      backendName: row['peerName'] as String?,
      phone: phone,
    );
    final dur = row['durationSec'] as int? ?? 0;
    final dir = _direction();
    final startedAtStr = row['startedAt'] as String?;
    final startedAt = startedAtStr != null
        ? DateTime.tryParse(startedAtStr)
        : null;

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
                fontWeight: dir == 'missed' ? FontWeight.w700 : FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (startedAt != null)
            Text(
              relTime(startedAt),
              style: TextStyle(
                fontSize: 11,
                color: cs.outline,
              ),
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
            final inviteId = await ref
                .read(callSignalingProvider)
                .ring(threadId, mode);
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

class _EmptyCallState extends StatelessWidget {
  const _EmptyCallState({required this.onNew, required this.onJoin});
  final VoidCallback onNew;
  final VoidCallback onJoin;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(Icons.history_toggle_off, size: 40, color: cs.outline),
          const SizedBox(height: 8),
          Text(
            'No calls yet',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Start one now, or join with a code someone shared.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.outline, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onNew,
                icon: const Icon(Icons.video_call, size: 18),
                label: const Text('New meeting'),
              ),
              OutlinedButton.icon(
                onPressed: onJoin,
                icon: const Icon(Icons.dialpad, size: 18),
                label: const Text('Join'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
