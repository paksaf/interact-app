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

import '../../services/device_contacts_index.dart';
import '../../services/location_service.dart';
import '../../services/talk_api.dart';
import '../../services/voice/voice_commands.dart';
import '../../widgets/branded_app_bar.dart';
import '../../widgets/call_row.dart';

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
      // Video rooms go via the pre-call self-view (2026-08-27);
      // voice-only has no camera to preview.
      context.push(mode == 'video'
          ? '/precall?host=true&mode=video'
          : '/room?host=true&mode=$mode');
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
                  onPressed: () => context.push('/call-history'),
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
                  children: rows.map((r) => CallRow(row: r)).toList(),
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
