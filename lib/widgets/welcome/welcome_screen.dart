// SPDX-License-Identifier: AGPL-3.0
//
// Polished single-screen welcome hub on the Calls tab — greeting, voice-first
// AI, primary navigation, and subordinate cross-app chips.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../services/ai_contact_service.dart';
import '../../services/location_service.dart';
import '../../services/smart_welcome_service.dart';
import '../../services/voice/voice_commands.dart';
import '../../services/weather_snapshot_service.dart';
import 'welcome_action_sheets.dart';
import 'welcome_donor_links.dart';

/// One-line product strength — static so the hero never shifts while async
/// fields resolve.
const kWelcomeStrengthLine =
    'Secure calls & chat — offline-ready, AI-powered, all in one place.';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  static const _xs = 8.0;
  static const _sm = 12.0;
  static const _md = 16.0;
  static const _lg = 24.0;
  static const _radiusMd = 16.0;
  static const _navMin = 48.0;

  late Future<SmartWelcomeSnapshot> _future;
  late AnimationController _enter;
  late Animation<double> _fade;
  SmartWelcomeSnapshot? _data;

  @override
  void initState() {
    super.initState();
    _reload();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _fade = CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic);
    _future.then((d) {
      if (!mounted) return;
      setState(() => _data = d);
      _enter.forward();
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  void _reload() {
    _future = ref.read(smartWelcomeServiceProvider).load();
  }

  Future<void> _refresh() async {
    WeatherSnapshotService.instance.clearCache();
    final next = ref.read(smartWelcomeServiceProvider).load();
    setState(() => _future = next);
    final d = await next;
    if (!mounted) return;
    setState(() => _data = d);
    _enter.forward(from: 0);
  }

  Future<void> _open(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openCallsHub() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_md, 0, _md, _md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Calls hub', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: _sm),
                _HubTile(
                  icon: Icons.video_call_outlined,
                  label: 'New meeting',
                  subtitle: 'Start now, share a code',
                  onTap: () {
                    Navigator.pop(ctx);
                    ctx.push('/precall?host=true&mode=video');
                  },
                ),
                _HubTile(
                  icon: Icons.dialpad,
                  label: 'Join with code',
                  subtitle: 'Enter or scan an invite',
                  onTap: () {
                    Navigator.pop(ctx);
                    ctx.push('/invite');
                  },
                ),
                _HubTile(
                  icon: Icons.phone_in_talk_outlined,
                  label: 'Dial a number',
                  subtitle: 'Call by phone or email',
                  onTap: () {
                    Navigator.pop(ctx);
                    ctx.push('/dialpad');
                  },
                ),
                _HubTile(
                  icon: Icons.history,
                  label: 'Call history',
                  subtitle: 'Recent voice & video',
                  onTap: () {
                    Navigator.pop(ctx);
                    ctx.push('/call-history');
                  },
                ),
                const SizedBox(height: _xs),
                Text(
                  'Voice-only and townhall live under Walkie & Calls tiles.',
                  style: TextStyle(fontSize: 12, color: cs.outline),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final data = _data;
    final greeting =
        data?.greeting ?? LocationService.greetingForNow();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          SliverToBoxAdapter(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_md, _xs, _md, _lg),
                child: FadeTransition(
                  opacity: _fade,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(
                        onHome: () {
                          context.go('/calls');
                          unawaited(_refresh());
                        },
                      ),
                      const SizedBox(height: _lg),
                      _HeroSection(
                        greeting: greeting,
                        data: data,
                        onWeatherTap: data == null
                            ? null
                            : () => _open(
                                  WeatherSnapshotService.weatherAppUri(
                                    lat: data.latitude,
                                    lon: data.longitude,
                                  ),
                                ),
                      ),
                      const SizedBox(height: _lg),
                      _VoiceAiCta(
                        onVoice: () =>
                            VoiceCommands.instance.listenAndDispatch(
                          context,
                          ref,
                        ),
                        onType: () =>
                            context.push('/chat/$kAiThreadId'),
                      ),
                      const SizedBox(height: _lg),
                      _NavGrid(
                        minSize: _navMin,
                        radius: _radiusMd,
                        onCalls: _openCallsHub,
                      ),
                      if (data?.aiInsight != null &&
                          data!.aiInsight!.isNotEmpty) ...[
                        const SizedBox(height: _md),
                        _InsightLine(
                          text: data.aiInsight!,
                          onTap: () =>
                              context.push('/chat/$kAiThreadId'),
                        ),
                      ],
                      const SizedBox(height: _md),
                      _CrossAppChips(
                        dueReminderCount: data?.memory.dueSoon.length ?? 0,
                        onNote: () async {
                          await showWelcomeNoteSheet(context);
                          await _refresh();
                        },
                        onReminder: () async {
                          await showWelcomeReminderSheet(context);
                          await _refresh();
                        },
                        onOpen: _open,
                      ),
                      const SizedBox(height: _md),
                      Text(
                        'INTERACT Talk',
                        textAlign: TextAlign.center,
                        style: tt.labelSmall?.copyWith(color: cs.outline),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onHome});

  final VoidCallback onHome;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Semantics(
          button: true,
          label: 'Home',
          hint: 'Return to welcome home',
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onHome,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(Icons.home_rounded, size: 22),
              ),
            ),
          ),
        ),
        const Spacer(),
        Semantics(
          button: true,
          label: l10n.themeSettings,
          child: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.palette_outlined, size: 22),
            onPressed: () => context.push('/settings/theme'),
          ),
        ),
        Semantics(
          button: true,
          label: 'Scan invite QR',
          child: IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.qr_code_scanner_outlined, size: 22),
            onPressed: () => context.push('/invite'),
          ),
        ),
      ],
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection({
    required this.greeting,
    required this.data,
    required this.onWeatherTap,
  });

  final String greeting;
  final SmartWelcomeSnapshot? data;
  final VoidCallback? onWeatherTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final name = data?.displayName.trim() ?? '';
    final showName = name.isNotEmpty && name != 'Me';
    final headline = showName ? '$greeting, $name' : greeting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 34,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        child: Text(
                          headline,
                          key: ValueKey(headline),
                          style: tt.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 28,
                    child: _MetaRow(
                      city: data?.city,
                      weather: data?.weather,
                      onWeatherTap: onWeatherTap,
                    ),
                  ),
                ],
              ),
            ),
            if ((data?.memory.dayStreak ?? 0) > 0)
              _StreakChip(streak: data!.memory.dayStreak),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          kWelcomeStrengthLine,
          style: tt.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({
    required this.city,
    required this.weather,
    required this.onWeatherTap,
  });

  final String? city;
  final WeatherSnapshot? weather;
  final VoidCallback? onWeatherTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (city == null && weather == null) {
      return const _SkeletonBar(width: 160, height: 20);
    }

    final parts = <Widget>[];
    if (city != null) {
      parts.add(Text(
        city!,
        style: TextStyle(color: cs.outline, fontSize: 14),
      ));
    }
    if (weather != null) {
      if (parts.isNotEmpty) {
        parts.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('·', style: TextStyle(color: cs.outline)),
        ));
      }
      parts.add(
        Semantics(
          button: onWeatherTap != null,
          label: 'Weather ${weather!.chipLabel}',
          child: Material(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onWeatherTap,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.wb_sunny_outlined,
                        size: 16, color: cs.primary),
                    const SizedBox(width: 4),
                    Text(
                      weather!.chipLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(children: parts);
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.width, required this.height});

  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

class _StreakChip extends StatelessWidget {
  const _StreakChip({required this.streak});

  final int streak;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$streak-day streak',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: cs.onTertiaryContainer,
        ),
      ),
    );
  }
}

class _VoiceAiCta extends StatelessWidget {
  const _VoiceAiCta({required this.onVoice, required this.onType});

  final VoidCallback onVoice;
  final VoidCallback onType;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Semantics(
          button: true,
          label: 'Ask INTERACT AI by voice',
          hint: 'Tap to speak your question',
          child: Material(
            elevation: 2,
            shadowColor: cs.shadow.withValues(alpha: 0.25),
            color: cs.tertiary,
            borderRadius: BorderRadius.circular(28),
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: onVoice,
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(minHeight: 72),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.mic_rounded, size: 32, color: cs.onTertiary),
                    const SizedBox(width: 14),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Ask INTERACT AI',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: cs.onTertiary,
                            ),
                          ),
                          Text(
                            'Voice · tap to speak',
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onTertiary.withValues(alpha: 0.88),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Semantics(
          button: true,
          label: 'Type to INTERACT AI instead',
          child: TextButton.icon(
            onPressed: onType,
            icon: const Icon(Icons.keyboard_outlined, size: 18),
            label: const Text('Type instead'),
          ),
        ),
      ],
    );
  }
}

class _NavGrid extends StatelessWidget {
  const _NavGrid({
    required this.minSize,
    required this.radius,
    required this.onCalls,
  });

  final double minSize;
  final double radius;
  final VoidCallback onCalls;

  static const _items = <_NavItem>[
    _NavItem(Icons.chat_bubble_outline, 'Messages', '/chats'),
    _NavItem(Icons.videocam_outlined, 'Calls', null, callsHub: true),
    _NavItem(Icons.play_circle_outline, 'Reels', '/social-panel'),
    _NavItem(Icons.map_outlined, 'Map', '/friends-map'),
    _NavItem(Icons.groups_outlined, 'Communities', '/communities'),
    _NavItem(Icons.podcasts_outlined, 'Walkie', '/walkie'),
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const cols = 3;
        const gap = 12.0;
        final tileW = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: _items.map((item) {
            return SizedBox(
              width: tileW,
              child: _NavTile(
                item: item,
                minSize: minSize,
                radius: radius,
                onCalls: onCalls,
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _NavItem {
  const _NavItem(this.icon, this.label, this.route, {this.callsHub = false});

  final IconData icon;
  final String label;
  final String? route;
  final bool callsHub;
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.minSize,
    required this.radius,
    required this.onCalls,
  });

  final _NavItem item;
  final double minSize;
  final double radius;
  final VoidCallback onCalls;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: item.label,
      child: Material(
        elevation: 1,
        shadowColor: cs.shadow.withValues(alpha: 0.12),
        color: cs.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: () {
            if (item.callsHub) {
              onCalls();
            } else if (item.route != null) {
              context.go(item.route!);
            }
          },
          child: Container(
            constraints: BoxConstraints(minHeight: minSize + 28),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: cs.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(item.icon, size: 26, color: cs.primary),
                const SizedBox(height: 8),
                Text(
                  item.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightLine extends StatelessWidget {
  const _InsightLine({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'AI insight: $text',
      child: Material(
        color: cs.primaryContainer.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.auto_awesome_outlined, size: 16, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, size: 16, color: cs.outline),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CrossAppChips extends StatelessWidget {
  const _CrossAppChips({
    required this.dueReminderCount,
    required this.onNote,
    required this.onReminder,
    required this.onOpen,
  });

  final int dueReminderCount;
  final Future<void> Function() onNote;
  final Future<void> Function() onReminder;
  final Future<void> Function(Uri uri) onOpen;

  @override
  Widget build(BuildContext context) {
    final reminderLabel = dueReminderCount == 0
        ? 'Reminder'
        : 'Reminder ($dueReminderCount)';

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _MiniChip(
            icon: Icons.sticky_note_2_outlined,
            label: 'Note',
            onTap: () => onNote(),
          ),
          _MiniChip(
            icon: Icons.alarm_outlined,
            label: reminderLabel,
            onTap: () => onReminder(),
          ),
          _MiniChip(
            icon: Icons.event_available_outlined,
            label: 'Booking',
            onTap: () => onOpen(WelcomeDonorLinks.lifestyleBookings),
          ),
          _MiniChip(
            icon: Icons.flag_outlined,
            label: 'Goals',
            onTap: () => onOpen(WelcomeDonorLinks.lifestyleGoals),
          ),
          _MiniChip(
            icon: Icons.insights_outlined,
            label: 'ExecOS',
            onTap: () => onOpen(WelcomeDonorLinks.execOs),
          ),
          _MiniChip(
            icon: Icons.edit_note_outlined,
            label: 'Notes',
            onTap: () => context.push('/notes'),
          ),
          _MiniChip(
            icon: Icons.psychology_outlined,
            label: 'Zeka',
            onTap: () => onOpen(WelcomeDonorLinks.zeka),
          ),
          _MiniChip(
            icon: Icons.help_outline,
            label: 'Help',
            onTap: () => context.push('/help'),
          ),
          _MiniChip(
            icon: Icons.cloud_outlined,
            label: 'Storage',
            onTap: () => context.push('/storage'),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Semantics(
        button: true,
        label: label,
        child: ActionChip(
          avatar: Icon(icon, size: 16, color: cs.primary),
          label: Text(label, style: const TextStyle(fontSize: 12)),
          onPressed: onTap,
          backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  const _HubTile({
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
    return ListTile(
      leading: Icon(icon, color: cs.primary),
      title: Text(label),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: cs.outline)),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}
