// SPDX-License-Identifier: AGPL-3.0
//
// AppShell — adaptive bottom-nav / side-rail scaffold. Tabs persist across
// pushes because this is a go_router ShellRoute parent. Order matches the
// backed PRD: Calls (default) → Chats → Contacts → Me.
//
// Also hosts the app-wide VPS auto-update strip: on first frame it asks
// UpdateService whether a newer APK exists on downloads.interactpak.com and,
// if so, shows an inline banner (NOT MaterialBanner — that pushed the whole
// dashboard down and thrashed on every download %). See in_app_update_banner.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/ui/responsive.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';
import '../../widgets/in_app_update_banner.dart';
import '../../widgets/sms_fallback_sheet.dart';
import '../../services/presence_service.dart';
import '../../services/device_contacts_index.dart';
import '../../services/notification_service.dart';
import '../../services/message_watcher.dart';
import '../../services/call_signaling.dart';
import '../../services/outbox_service.dart';
import '../../services/push_service.dart';
import '../../services/auth_service.dart';
import '../../services/inbound_funnel.dart';
import '../../services/iot/iot_chat_bridge.dart';
import '../../services/iot/iot_comms_service.dart';
import '../../services/location_share_service.dart';
import '../../services/location_trace_service.dart';
import '../../services/message_repository.dart';
import '../../services/offline_router.dart';
import '../../services/pending_mirror_sync.dart';
import '../../services/analytics_service.dart';
import '../../services/talk_route_observer.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell>
    with WidgetsBindingObserver {
  // Phase-1 redesign: 4 tabs (Calls, Chats, Contacts, Me). The former "Menu"
  // grid tab was removed and every item it held was redistributed — Invite →
  // Contacts FAB, Townhall/Walkie → Calls tab, Camera FX → chat attach menu,
  // Login QR/codes/approve → Me › Security & Privacy. No feature was lost.
  static const _tabPaths = <(String, IconData, IconData)>[
    ('/calls', Icons.videocam_outlined, Icons.videocam),
    ('/chats', Icons.chat_bubble_outline, Icons.chat_bubble),
    ('/contacts', Icons.people_outline, Icons.people),
    ('/me', Icons.person_outline, Icons.person),
  ];

  int _outboxPending = 0;
  StreamSubscription<int>? _outboxSub;
  String? _lastTrackedPath;
  DateTime? _pausedAt;
  GoRouter? _goRouter;
  VoidCallback? _routerListener;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(AnalyticsService.instance.trackSessionStart());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _goRouter = GoRouter.of(context);
      _routerListener = () {
        final path =
            _goRouter!.routerDelegate.currentConfiguration.uri.path;
        if (path != _lastTrackedPath) {
          _lastTrackedPath = path;
          trackShellPath(path);
        }
      };
      _goRouter!.routerDelegate.addListener(_routerListener!);
      _routerListener!();
    });
    // Defer to first frame so a ScaffoldMessenger exists; failures are silent.
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    // Presence heartbeat → QS /api/v1/talk/presence/beat (TalkPresence table).
    ref.read(presenceServiceProvider).start();
    // Warm the read-only device-contact index once (permission-gated, never
    // prompts) so Contacts/Calls can show real names over generic "Talk 1469".
    ref.read(deviceContactsIndexProvider).ensureLoaded();
    // Offline chat outbox drain (Maps donor pattern).
    OutboxService.instance.startAutoFlush();
    unawaited(OutboxService.instance.flush());
    // OfflineRouter — LAN + BLE mesh bearers for unified chat delivery.
    unawaited(ref.read(offlineRouterProvider).ensureLan());
    unawaited(ref.read(offlineRouterProvider).ensureBleMesh());
    unawaited(ref.read(inboundFunnelProvider).start());
    unawaited(ref.read(iotChatBridgeProvider).start());
    // Resume a saved RF-HTTP IoT gateway poll so trackers show on the map
    // at launch with zero taps (LoRa-BLE stays manual — may be out of range).
    unawaited(IotCommsService.instance.autoReconnectFromPrefs());
    unawaited(LocationTraceService.instance.load());
    LocationShareService.instance.bind(
      repo: ref.read(messageRepositoryProvider),
      auth: ref.read(authServiceProvider),
    );
    OutboxService.instance.routerHandler =
        ref.read(offlineRouterProvider).replayOutboxItem;
    _outboxSub = OutboxService.instance.changes.listen((n) {
      if (mounted) setState(() => _outboxPending = n);
    });
    unawaited(OutboxService.instance.pendingCount().then((n) {
      if (mounted) setState(() => _outboxPending = n);
    }));
    // FCM token register (background/killed call ring) — best-effort.
    // onCallCancel: a call_cancel push (caller hung up before answer) drops
    // the in-app ring at once instead of waiting for the next 3s poll; the
    // native/notification surfaces are already dismissed inside PushService.
    unawaited(PushService.instance.init(
      ref.read(authServiceProvider),
      onCallCancel: (callId, inviteId) {
        final calls = ref.read(callSignalingProvider);
        final inc = calls.incoming.value;
        if (inc != null && (inc.threadId == callId || inc.id == inviteId)) {
          calls.clear();
        }
      },
    ));
    // New-message notifications (banner + sound) while the app runs.
    NotificationService.instance.init();
    ref.read(messageWatcherProvider).start();
    // Incoming-call ring — poll for invites; show the full-screen ring
    // whenever one arrives.
    _calls = ref.read(callSignalingProvider);
    _calls.incoming.addListener(_onIncomingCall);
    _calls.start();
    _unread = ref.read(messageWatcherProvider).unreadTotal;
    _unread.addListener(_onUnreadChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(PendingMirrorSync.onAppOpen(ref, force: true));
    });
  }

  late final CallSignaling _calls;
  late final ValueNotifier<int> _unread;
  int _unreadChats = 0;

  void _onUnreadChanged() {
    if (mounted) setState(() => _unreadChats = _unread.value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(OutboxService.instance.flush());
      unawaited(AnalyticsService.instance.flush());
      _calls.checkNow();
      ref.read(presenceServiceProvider).beatNow();
      unawaited(PendingMirrorSync.onAppResume(ref));
      if (_pausedAt != null) {
        final away = DateTime.now().difference(_pausedAt!).inSeconds;
        if (away > 300) {
          unawaited(AnalyticsService.instance.trackSessionStart());
        }
        _pausedAt = null;
      }
    } else if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
      unawaited(AnalyticsService.instance.trackSessionEnd());
    }
  }

  /// Invite id of the IncomingCallScreen currently on the stack (or null).
  /// Ensures exactly ONE ring screen per invite — if the notifier re-emits
  /// the same invite, we don't push a duplicate. Cleared when the invite
  /// goes away (screen dismissed / cancelled) so a later real call rings.
  String? _shownIncomingId;

  void _onIncomingCall() {
    final call = _calls.incoming.value;
    if (call == null) {
      // Ring cleared (answered / declined / cancelled / expired) — release
      // the guard so the next distinct invite can show its screen.
      _shownIncomingId = null;
      return;
    }
    if (!mounted) return;
    // Already on a live call — CallSignaling auto-busy'd; don't push ring UI.
    if (_calls.inCall.value) return;
    // Same invite already showing → don't stack another screen.
    if (_shownIncomingId == call.id) return;
    _shownIncomingId = call.id;
    GoRouter.of(context).push('/incoming', extra: call);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final listener = _routerListener;
    final router = _goRouter;
    if (listener != null && router != null) {
      router.routerDelegate.removeListener(listener);
    }
    unawaited(AnalyticsService.instance.trackSessionEnd());
    AnalyticsService.instance.stop();
    _outboxSub?.cancel();
    _unread.removeListener(_onUnreadChanged);
    ref.read(presenceServiceProvider).stop();
    ref.read(messageWatcherProvider).stop();
    _calls.incoming.removeListener(_onIncomingCall);
    _calls.stop();
    super.dispose();
  }

  Future<void> _checkForUpdate() async {
    await checkAndShowInAppUpdate(context);
    // Banner UI is owned by InAppUpdateBannerHost (ListenableBuilder) —
    // do not clear/re-show MaterialBanner on every progress tick.
  }

  Future<void> _offerSmsForOutbox() async {
    final item = await OutboxService.instance.firstPendingChatText();
    if (item == null || !mounted) return;
    final bodyMap = (item['body'] as Map?)?.cast<String, dynamic>();
    final body = (bodyMap?['body'] as String?)?.trim() ?? '';
    if (body.isEmpty) return;
    await showSmsFallbackSheet(
      context: context,
      ref: ref,
      toPhone: '',
      body: body,
      threadId: item['threadId'] as String?,
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
    ];
    final location = GoRouterState.of(context).uri.path;
    // Exact match or a true sub-path (trailing slash). '/me' is last so it
    // can't shadow another tab's prefix.
    final currentIndex = _tabPaths.indexWhere(
        (t) => location == t.$1 || location.startsWith('${t.$1}/'));
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;
    return TalkAdaptiveNavScaffold(
      body: AppBackground(
        scrim: 0.70,
        child: Column(
          children: [
            const InAppUpdateBannerHost(),
            if (_outboxPending > 0)
              Material(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => OutboxService.instance.flush(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 8),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.cloud_off_outlined,
                                    size: 16,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onTertiaryContainer,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Offline queue · $_outboxPending message'
                                      '${_outboxPending == 1 ? '' : 's'} pending',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onTertiaryContainer,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    'Retry',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onTertiaryContainer,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _offerSmsForOutbox,
                          icon: const Icon(Icons.sms, size: 16),
                          label: const Text('SMS'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onTertiaryContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(child: widget.child),
          ],
        ),
      ),
      selectedIndex: safeIndex,
      onDestinationSelected: (i) => context.go(_tabPaths[i].$1),
      destinations: [
        for (var i = 0; i < _tabPaths.length; i++)
          NavigationDestination(
            icon: _navIcon(_tabPaths[i].$2, i == 1 ? _unreadChats : 0),
            selectedIcon: _navIcon(_tabPaths[i].$3, i == 1 ? _unreadChats : 0),
            label: labels[i],
          ),
      ],
    );
  }

  Widget _navIcon(IconData icon, int badge) {
    if (badge <= 0) return Icon(icon);
    return Badge(
      label: Text(badge > 99 ? '99+' : '$badge'),
      child: Icon(icon),
    );
  }
}
