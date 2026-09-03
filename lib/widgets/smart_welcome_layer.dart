// SPDX-License-Identifier: AGPL-3.0
//
// AI-aware welcome card on the Calls tab — weather, memory, cross-app actions.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ai_contact_service.dart';
import '../services/smart_welcome_service.dart';
import '../services/weather_snapshot_service.dart';
import 'welcome/welcome_action_sheets.dart';

/// Donor-app surfaces — link out, never duplicate full stacks in Talk.
class WelcomeDonorLinks {
  WelcomeDonorLinks._();

  static Uri get lifestyle => Uri.parse('https://lifestyle.interactpak.com');
  static Uri get lifestyleBookings =>
      Uri.parse('https://lifestyle.interactpak.com/bookings');
  static Uri get lifestyleGoals =>
      Uri.parse('https://lifestyle.interactpak.com/goals');
  static Uri get execOs => Uri.parse('https://execute.interactpak.com');
  static Uri get interactPro => Uri.parse('interactpro://open?path=/notes');
  static Uri get zeka => Uri.parse('https://www.interactpak.com/zeka');
}

class SmartWelcomeLayer extends ConsumerStatefulWidget {
  const SmartWelcomeLayer({super.key, this.onSubtitle});

  /// Optional hook so CallsTab can mirror city in the app bar subtitle.
  final ValueChanged<String>? onSubtitle;

  @override
  ConsumerState<SmartWelcomeLayer> createState() => _SmartWelcomeLayerState();
}

class _SmartWelcomeLayerState extends ConsumerState<SmartWelcomeLayer> {
  late Future<SmartWelcomeSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _future = ref.read(smartWelcomeServiceProvider).load();
  }

  Future<void> _open(Uri uri) async {
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<SmartWelcomeSnapshot>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _shell(
            cs,
            child: const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        final data = snap.data;
        if (data == null) return const SizedBox.shrink();

        if (data.city != null) {
          widget.onSubtitle?.call('${data.greeting} · ${data.city}');
        }

        return _shell(
          cs,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          data.headline,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (data.city != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            data.city!,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.outline,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (data.memory.dayStreak > 0)
                    _StreakChip(streak: data.memory.dayStreak),
                ],
              ),
              if (data.weather != null) ...[
                const SizedBox(height: 10),
                _WeatherRow(
                  weather: data.weather!,
                  onPlan: () => _open(
                    WeatherSnapshotService.weatherAppUri(
                      lat: data.latitude,
                      lon: data.longitude,
                    ),
                  ),
                ),
              ],
              if (data.aiInsight != null && data.aiInsight!.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AiInsightRow(
                  text: data.aiInsight!,
                  onTap: () => context.push('/chat/$kAiThreadId'),
                ),
              ],
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _ActionChip(
                      icon: Icons.sticky_note_2_outlined,
                      label: 'Note',
                      onTap: () async {
                        await showWelcomeNoteSheet(context);
                        setState(_reload);
                      },
                    ),
                    _ActionChip(
                      icon: Icons.alarm_outlined,
                      label: data.memory.dueSoon.isEmpty
                          ? 'Reminder'
                          : 'Reminder (${data.memory.dueSoon.length})',
                      onTap: () async {
                        await showWelcomeReminderSheet(context);
                        setState(_reload);
                      },
                    ),
                    _ActionChip(
                      icon: Icons.event_available_outlined,
                      label: 'Booking',
                      onTap: () => _open(WelcomeDonorLinks.lifestyleBookings),
                    ),
                    _ActionChip(
                      icon: Icons.flag_outlined,
                      label: 'Goals',
                      onTap: () => _open(WelcomeDonorLinks.lifestyleGoals),
                    ),
                    _ActionChip(
                      icon: Icons.insights_outlined,
                      label: 'ExecOS',
                      onTap: () => _open(WelcomeDonorLinks.execOs),
                    ),
                    _ActionChip(
                      icon: Icons.edit_note_outlined,
                      label: 'Pro notes',
                      onTap: () => _open(WelcomeDonorLinks.interactPro),
                    ),
                    _ActionChip(
                      icon: Icons.psychology_outlined,
                      label: 'Zeka',
                      onTap: () => _open(WelcomeDonorLinks.zeka),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _shell(ColorScheme cs, {required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cs.primary.withValues(alpha: 0.14),
            cs.secondary.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: child,
    );
  }
}

class _StreakChip extends StatelessWidget {
  const _StreakChip({required this.streak});
  final int streak;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '🔥 $streak day${streak == 1 ? '' : 's'}',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _WeatherRow extends StatelessWidget {
  const _WeatherRow({required this.weather, required this.onPlan});

  final WeatherSnapshot weather;
  final VoidCallback onPlan;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPlan,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.wb_sunny_outlined, color: cs.primary, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  weather.chipLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              Text(
                'Plan →',
                style: TextStyle(
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiInsightRow extends StatelessWidget {
  const _AiInsightRow({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.primaryContainer.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.auto_awesome, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: cs.onSurface,
                  ),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: cs.outline),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
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
      child: ActionChip(
        avatar: Icon(icon, size: 18, color: cs.primary),
        label: Text(label),
        onPressed: onTap,
        backgroundColor: cs.surface.withValues(alpha: 0.72),
      ),
    );
  }
}
