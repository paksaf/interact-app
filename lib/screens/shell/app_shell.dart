// SPDX-License-Identifier: AGPL-3.0
//
// AppShell — adaptive bottom-nav / side-rail scaffold. Tabs persist across
// pushes because this is a go_router ShellRoute parent. Order matches the
// backed PRD: Calls (default) → Chats → Contacts → Me.
//
// Also hosts the app-wide VPS auto-update banner: on first frame it asks
// UpdateService whether a newer APK exists on downloads.interactpak.com and,
// if so, surfaces a non-blocking MaterialBanner. "Update now" streams the
// APK down + fires the system installer (see services/update_service.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ui/responsive.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';
import '../../services/update_service.dart';
import '../../services/presence_service.dart';
import '../../services/notification_service.dart';
import '../../services/message_watcher.dart';
import '../../services/call_signaling.dart';
import '../../services/outbox_service.dart';
import '../../services/push_service.dart';
import '../../services/auth_service.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _tabPaths = <(String, IconData, IconData)>[
    ('/calls', Icons.videocam_outlined, Icons.videocam),
    ('/chats', Icons.chat_bubble_outline, Icons.chat_bubble),
    ('/contacts', Icons.people_outline, Icons.people),
    ('/me', Icons.person_outline, Icons.person),
    ('/menu', Icons.grid_view_outlined, Icons.grid_view),
  ];

  @override
  void initState() {
    super.initState();
    // Defer to first frame so a ScaffoldMessenger exists; failures are silent.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    // Presence heartbeat → QS /api/v1/talk/presence/beat (TalkPresence table).
    ref.read(presenceServiceProvider).start();
    // Offline chat outbox drain (Maps donor pattern).
    OutboxService.instance.startAutoFlush();
    unawaited(OutboxService.instance.flush());
    // FCM token register (background/killed call ring) — best-effort.
    unawaited(PushService.instance.init(ref.read(authServiceProvider)));
    // New-message notifications (banner + sound) while the app runs.
    NotificationService.instance.init();
    ref.read(messageWatcherProvider).start();
    // Incoming-call ring — poll for invites; show the full-screen ring
    // whenever one arrives.
    _calls = ref.read(callSignalingProvider);
    _calls.incoming.addListener(_onIncomingCall);
    _calls.start();
  }

  late final CallSignaling _calls;

  void _onIncomingCall() {
    final call = _calls.incoming.value;
    if (call == null || !mounted) return;
    GoRouter.of(context).push('/incoming', extra: call);
  }

  @override
  void dispose() {
    ref.read(presenceServiceProvider).stop();
    ref.read(messageWatcherProvider).stop();
    _calls.incoming.removeListener(_onIncomingCall);
    _calls.stop();
    super.dispose();
  }

  Future<void> _checkForUpdate() async {
    final info = await UpdateService.instance.checkOnce();
    if (info == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showMaterialBanner(
      MaterialBanner(
        leading: const Icon(Icons.system_update),
        content: Text(
          'Update available — v${info.versionName}'
          '${info.changelog.isNotEmpty ? '\n${info.changelog}' : ''}',
        ),
        actions: [
          if (!info.forceUpdate)
            TextButton(
              onPressed: messenger.hideCurrentMaterialBanner,
              child: const Text('Later'),
            ),
          FilledButton(
            onPressed: () {
              messenger.hideCurrentMaterialBanner();
              UpdateService.instance.openDownload(info);
              messenger.showSnackBar(const SnackBar(
                content: Text('Opening the update download… tap the APK when it finishes to install.'),
              ));
            },
            child: const Text('Update now'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = <String>[
      l10n.tabCalls,
      l10n.tabChats,
      l10n.tabContacts,
      l10n.tabMe,
      'Menu',
    ];
    final location = GoRouterState.of(context).uri.path;
    // Exact match or a true sub-path (trailing slash) — so '/menu' doesn't
    // get captured by the '/me' prefix.
    final currentIndex = _tabPaths.indexWhere(
        (t) => location == t.$1 || location.startsWith('${t.$1}/'));
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;
    return TalkAdaptiveNavScaffold(
      body: AppBackground(scrim: 0.70, child: widget.child),
      selectedIndex: safeIndex,
      onDestinationSelected: (i) => context.go(_tabPaths[i].$1),
      destinations: [
        for (var i = 0; i < _tabPaths.length; i++)
          NavigationDestination(
            icon: Icon(_tabPaths[i].$2),
            selectedIcon: Icon(_tabPaths[i].$3),
            label: labels[i],
          ),
      ],
    );
  }
}
