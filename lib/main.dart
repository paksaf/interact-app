// SPDX-License-Identifier: AGPL-3.0
//
// INTERACT — voice/video-first, offline-capable, AI-assisted communication
// super-app. Pakistan-first. Free, open-source under AGPLv3.
//
// Default landing tab is CALLS (research-backed: voice is the primary
// modality for the target audience). Chats sit secondary. Contacts + Me
// round out the bottom nav.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/l10n/locale_prefs.dart';
import 'l10n/app_localizations.dart';
import 'models/chat.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/auth/profile_setup_screen.dart';
import 'screens/auth/approve_login_screen.dart';
import 'screens/auth/login_codes_inbox_screen.dart';
import 'screens/auth/generate_login_qr_screen.dart';
import 'screens/camera/camera_effects_screen.dart';
import 'screens/contacts/device_contacts_screen.dart';
import 'screens/me/backup_screen.dart';
import 'screens/chat/chat_thread_screen.dart';
import 'screens/chat/chat_thread_loader.dart';
import 'screens/chat/communities_screen.dart';
import 'screens/chat/new_group_screen.dart';
import 'screens/meeting/meeting_room_screen.dart';
import 'screens/meeting/pre_call_preview_screen.dart';
import 'screens/meeting/call_room_livekit_screen.dart';
import 'screens/meeting/incoming_call_screen.dart';
import 'screens/meeting/invite_screen.dart';
import 'screens/blocked_contacts_screen.dart';
import 'screens/call_history_screen.dart';
import 'screens/meeting/dial_pad_screen.dart';
import 'services/call_signaling.dart';
import 'services/talk_flags.dart';
import 'screens/meeting/townhall_entry_screen.dart';
import 'screens/meeting/live_room_screen.dart';
import 'services/live_api.dart';
import 'screens/shell/app_shell.dart';
import 'screens/tabs/calls_tab.dart';
import 'screens/tabs/chats_tab.dart';
import 'screens/tabs/contacts_tab.dart';
import 'screens/tabs/me_tab.dart';
import 'screens/iot/nearby_ble_devices_screen.dart';
import 'screens/lan/offline_lan_screen.dart';
import 'screens/lan/lan_walkie_screen.dart';
import 'screens/lora/lora_bridge_screen.dart';
import 'screens/mesh/nearby_mesh_screen.dart';
import 'screens/debug/field_validation_screen.dart';
import 'services/auth_service.dart';
import 'services/push_service.dart';
import 'services/callkit_service.dart';
import 'services/notification_service.dart';
import 'services/api_base.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // DNS-failover base resolver: restore last-known-good API host and
  // verify it in the background (see services/api_base.dart).
  await ApiBase.init();
  // FCM for background/killed call ring. Fail-soft: if google-services.json /
  // Firebase isn't configured yet, the app still runs (ring stays foreground-only).
  // Lifestyle donor: register the background handler BEFORE runApp.
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  } catch (_) {/* Firebase not configured — degrade gracefully */}
  runApp(const ProviderScope(child: InteractApp()));
}

/// Root navigator key — lets the native-call callbacks (CallKit accept /
/// missed-call "call back"), which fire OUTSIDE the widget tree, reach a
/// BuildContext for provider reads and router navigation.
final _rootNavKey = GlobalKey<NavigatorState>();

/// CallKit ACCEPT (or cold-start accept) → POST respond('accept') when we
/// know the invite id, then join the peer's room (host=false) by threadId.
Future<void> _handleNativeCallAccept(
  String threadId,
  String mode,
  String? callerName,
  String? inviteId,
) async {
  final ctx = _rootNavKey.currentContext;
  if (ctx != null) {
    try {
      final container = ProviderScope.containerOf(ctx, listen: false);
      final signaling = container.read(callSignalingProvider);
      var id = inviteId;
      // Fallback: match the live poll invite for this thread.
      if (id == null || id.isEmpty) {
        final live = signaling.incoming.value;
        if (live != null && live.threadId == threadId) id = live.id;
      }
      if (id != null && id.isNotEmpty) {
        // BEFORE responding: mark handled so the 4s poll can't resurface this
        // still-`ringing` invite as a second IncomingCallScreen on top of the
        // room we're about to open ("asked twice to receive the call").
        signaling.suppress(id);
        await signaling.respond(id, 'accept');
      }
    } catch (_) {/* best-effort — still open the room */}
  }
  final q = <String, String>{
    'mode': mode,
    'threadId': threadId,
    if (callerName != null && callerName.trim().isNotEmpty)
      'peerName': callerName.trim(),
    if (inviteId != null && inviteId.isNotEmpty) 'inviteId': inviteId,
  };
  final qs = q.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  // Flag-gated media surface: '/call-lk' (LiveKit + captions) when TALK_LK_CALLS
  // is on, else the unchanged P2P '/room'. Ring/accept semantics are identical.
  _router.push('${TalkFlags.callRoomPath()}?$qs');
}

/// Missed-call "tap to call back" (local notif) AND CallKit "Call back" →
/// place an OUTGOING call: ring the peer, then open the room as host — the
/// same flow ChatThreadScreen uses. Reads the provider via the root navigator
/// context so it works from a static callback outside the widget tree.
Future<void> _handleCallBack(String threadId, String mode) async {
  String? inviteId;
  final ctx = _rootNavKey.currentContext;
  if (ctx != null) {
    try {
      final container = ProviderScope.containerOf(ctx, listen: false);
      inviteId =
          await container.read(callSignalingProvider).ring(threadId, mode);
    } catch (_) {/* best-effort — still open the room */}
  }
  final q = <String, String>{
    'host': 'true',
    'mode': mode,
    'threadId': threadId,
    if (inviteId != null) 'inviteId': inviteId,
  };
  final qs = q.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  // Same flag gate as the accept path — LiveKit call when TALK_LK_CALLS is on.
  _router.push('${TalkFlags.callRoomPath()}?$qs');
}

/// Map Android deep-link URIs → in-app paths. Returns null if [u] is already
/// a normal in-app location.
String? _normalizeTalkDeepLink(Uri u) {
  // interact://j/<CODE>
  if (u.scheme == 'interact' && u.host == 'j') {
    final code = u.pathSegments.isNotEmpty
        ? u.pathSegments.first
        : u.path.replaceAll('/', '');
    if (code.isNotEmpty) return '/j/${code.toUpperCase()}';
  }
  // interact:///j/<CODE> (empty host)
  if (u.scheme == 'interact' && u.path.startsWith('/j/')) {
    final code = u.path.substring(3).split('/').first;
    if (code.isNotEmpty) return '/j/${code.toUpperCase()}';
  }
  // https://talk.interactpak.com/j/<CODE>
  if ((u.scheme == 'https' || u.scheme == 'http') &&
      (u.host == 'talk.interactpak.com' || u.host == 'interactpak.com')) {
    if (u.path.startsWith('/j/')) {
      final code = u.path.substring(3).split('/').first;
      if (code.isNotEmpty) return '/j/${code.toUpperCase()}';
    }
    if (u.path.isEmpty || u.path == '/') return '/';
    return u.path;
  }
  return null;
}

/// Routes — ShellRoute hosts the bottom-nav scaffold so the tab
/// switcher persists across pushes. Sign-in + meeting room + invite
/// paste live OUTSIDE the shell (full-screen).
final _router = GoRouter(
  navigatorKey: _rootNavKey,
  initialLocation: '/',
  // A server-side refresh-token REVOKE (or explicit sign-out) flips this
  // notifier; the redirect below then boots the user to sign-in from wherever
  // they are. This is the ONLY app-wide auto-logout path — a network error
  // never flips the flag (see AuthService._doRefresh).
  refreshListenable: AuthService.instance.sessionRevoked,
  redirect: (ctx, state) {
    if (AuthService.instance.sessionRevoked.value &&
        state.matchedLocation != '/sign-in') {
      return '/sign-in?revoked=1';
    }
    // Android often forwards the FULL deep-link URI as the go_router
    // location (e.g. `https://talk.interactpak.com/j/WALKIE1` or
    // `interact://j/CODE`). Rewrite to an in-app path before matching.
    final deep = _normalizeTalkDeepLink(state.uri);
    if (deep != null && deep != state.matchedLocation && deep != state.uri.path) {
      return deep;
    }
    // Also when location string itself is an absolute URL (matchedLocation
    // may still be the full string on some Flutter/Android versions).
    final loc = state.uri.toString();
    if (loc.startsWith('https://') ||
        loc.startsWith('http://') ||
        loc.startsWith('interact://')) {
      final n = _normalizeTalkDeepLink(Uri.parse(loc));
      if (n != null) return n;
    }
    return null;
  },
  routes: [
    GoRoute(path: '/', builder: (_, __) => const _Gate()),
    // Invite / walkie / townhall join codes from QR + https://talk…/j/<CODE>
    GoRoute(
      path: '/j/:code',
      builder: (ctx, st) {
        final code = (st.pathParameters['code'] ?? '').trim().toUpperCase();
        final upper = code;
        // Walkie / PTT room codes → LiveKit hold-to-speak room.
        if (upper.startsWith('WALKIE') || upper.startsWith('PTT')) {
          return LiveRoomScreen(
            code: code,
            asHost: false,
            role: LiveRole.pttTalker,
            mode: 'ptt',
          );
        }
        // Townhall-style codes → live meeting room as speaker.
        if (upper.startsWith('TOWN') || upper.startsWith('MEET')) {
          return LiveRoomScreen(
            code: code,
            asHost: false,
            role: LiveRole.speaker,
            mode: 'meeting',
          );
        }
        // Default: 1:1 / invite meeting room (mesh call).
        return MeetingRoomScreen(
          roomCode: code,
          isHost: false,
          mode: 'video',
        );
      },
    ),
    GoRoute(
      path: '/sign-in',
      builder: (ctx, st) => SignInScreen(
        sessionExpired: st.uri.queryParameters['expired'] == '1',
        sessionRevoked: st.uri.queryParameters['revoked'] == '1',
        prefillPhone: st.uri.queryParameters['phone'],
      ),
    ),
    GoRoute(
      path: '/profile-setup',
      builder: (_, __) => const ProfileSetupScreen(),
    ),
    GoRoute(
        path: '/camera-effects',
        builder: (_, __) => const CameraEffectsScreen()),
    // Pre-call self-view (2026-08-27): check appearance/background before an
    // ad-hoc video room. Forwards its whole query string to /room on Start.
    GoRoute(
      path: '/precall',
      builder: (ctx, st) =>
          PreCallPreviewScreen(roomQuery: st.uri.query),
    ),
    GoRoute(
        path: '/offline-lan',
        builder: (_, __) => const OfflineLanScreen()),
    // §14 Phase 1 — walkie over the site Wi-Fi with no uplink. ?code= is
    // pre-filled when we land here as the offline fallback from /live.
    GoRoute(
      path: '/lan-walkie',
      builder: (ctx, st) =>
          LanWalkieScreen(initialCode: st.uri.queryParameters['code']),
    ),
    GoRoute(
        path: '/nearby-mesh',
        builder: (_, __) => const NearbyMeshScreen()),
    GoRoute(
        path: '/nearby-devices',
        builder: (_, __) => const NearbyBleDevicesScreen()),
    GoRoute(
        path: '/lora-bridge',
        builder: (_, __) => const LoraBridgeScreen()),
    GoRoute(
        path: '/field-validation',
        builder: (_, __) => const FieldValidationScreen()),
    GoRoute(
        path: '/device-contacts',
        builder: (_, __) => const DeviceContactsScreen()),
    GoRoute(path: '/backup', builder: (_, __) => const BackupScreen()),
    GoRoute(path: '/new-group', builder: (_, __) => const NewGroupScreen()),
    GoRoute(
      path: '/approve-login',
      builder: (ctx, st) => ApproveLoginScreen(
        initialCode: st.uri.queryParameters['code'],
        challengeId: st.uri.queryParameters['c'],
      ),
    ),
    GoRoute(
      path: '/auth/:code',
      builder: (ctx, st) => ApproveLoginScreen(
        initialCode: st.pathParameters['code'],
        challengeId: st.uri.queryParameters['c'],
      ),
    ),
    GoRoute(
      path: '/login-codes',
      builder: (_, __) => const LoginCodesInboxScreen(),
    ),
    GoRoute(
      path: '/login-qr',
      builder: (_, __) => const GenerateLoginQrScreen(),
    ),
    GoRoute(
      path: '/incoming',
      builder: (ctx, st) {
        final call = st.extra as IncomingCall?;
        if (call == null) {
          return const Scaffold(body: Center(child: Text('Call ended')));
        }
        return IncomingCallScreen(call: call);
      },
    ),
    GoRoute(path: '/invite', builder: (_, __) => const InviteScreen()),
    GoRoute(path: '/dialpad', builder: (_, __) => const DialPadScreen()),
    GoRoute(
        path: '/call-history',
        builder: (_, __) => const CallHistoryScreen()),
    GoRoute(
        path: '/blocked-contacts',
        builder: (_, __) => const BlockedContactsScreen()),
    // Multi-party conference / townhall / walkie (LiveKit SFU).
    GoRoute(
      path: '/townhall',
      builder: (_, st) => TownhallEntryScreen(
        mode: st.uri.queryParameters['mode'] ?? 'meeting',
      ),
    ),
    GoRoute(
      path: '/walkie',
      builder: (_, __) => const TownhallEntryScreen(mode: 'ptt'),
    ),
    GoRoute(
      path: '/live',
      builder: (ctx, st) {
        final code = st.uri.queryParameters['code'] ?? '';
        final asHost = st.uri.queryParameters['host'] == 'true';
        final mode = st.uri.queryParameters['mode'] ?? 'meeting';
        final roleWire = st.uri.queryParameters['role'] ??
            (mode == 'ptt' ? 'ptt-talker' : 'speaker');
        final role = LiveRole.values.firstWhere(
          (r) => r.wire == roleWire,
          orElse: () =>
              mode == 'ptt' ? LiveRole.pttTalker : LiveRole.speaker,
        );
        return LiveRoomScreen(
          code: code,
          asHost: asHost,
          role: role,
          mode: mode,
        );
      },
    ),
    GoRoute(
      path: '/room',
      builder: (ctx, st) {
        final code = st.uri.queryParameters['code'] ?? '';
        final host = st.uri.queryParameters['host'] == 'true';
        // mode=voice flips video off → audio-only call (per the phone
        // icon in ChatThreadScreen). Default stays 'video' for the
        // videocam icon + /invite + /j/CODE deep link.
        final mode = st.uri.queryParameters['mode'] ?? 'video';
        // threadId — chat-thread-initiated calls pass the thread uuid
        // so the meetings backend can authorize via participation and
        // attach the resulting CallLog to the right thread (#145).
        final threadId = st.uri.queryParameters['threadId'];
        final peerName = st.uri.queryParameters['peerName'];
        final peerAvatar = st.uri.queryParameters['peerAvatar'];
        // Ring invite id — lets the room's hang-up remotely cancel the
        // callee's ring (true remote-cancel) if unanswered.
        final inviteId = st.uri.queryParameters['inviteId'];
        return MeetingRoomScreen(
          roomCode: code,
          isHost: host,
          mode: mode,
          threadId: threadId,
          peerName: peerName,
          peerAvatar: peerAvatar,
          inviteId: inviteId,
        );
      },
    ),
    // Flag-gated (TALK_LK_CALLS) 1:1-over-LiveKit call — same params as /room,
    // but a 2-person LiveKit room so live captions work. Only reached when
    // TalkFlags.callRoomPath() returns '/call-lk'; default builds never do.
    GoRoute(
      path: '/call-lk',
      builder: (ctx, st) {
        final code = st.uri.queryParameters['code'] ?? '';
        final host = st.uri.queryParameters['host'] == 'true';
        final mode = st.uri.queryParameters['mode'] ?? 'video';
        final threadId = st.uri.queryParameters['threadId'];
        final peerName = st.uri.queryParameters['peerName'];
        final peerAvatar = st.uri.queryParameters['peerAvatar'];
        final inviteId = st.uri.queryParameters['inviteId'];
        return CallRoomLiveKitScreen(
          roomCode: code,
          isHost: host,
          mode: mode,
          threadId: threadId,
          peerName: peerName,
          peerAvatar: peerAvatar,
          inviteId: inviteId,
        );
      },
    ),
    GoRoute(
      path: '/chat/:id',
      builder: (ctx, st) {
        final thread = st.extra as ChatThread?;
        if (thread != null) return ChatThreadScreen(thread: thread);
        // Notification / deep-link entry — load by id.
        return ChatThreadLoader(threadId: st.pathParameters['id'] ?? '');
      },
    ),
    GoRoute(
      path: '/communities',
      builder: (ctx, st) => const CommunitiesScreen(),
    ),
    ShellRoute(
      builder: (ctx, st, child) => AppShell(child: child),
      routes: [
        GoRoute(path: '/calls', builder: (_, __) => const CallsTab()),
        GoRoute(path: '/chats', builder: (_, __) => const ChatsTab()),
        GoRoute(path: '/contacts', builder: (_, __) => const ContactsTab()),
        GoRoute(path: '/me', builder: (_, __) => const MeTab()),
      ],
    ),
  ],
);

class InteractApp extends ConsumerWidget {
  const InteractApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(localeControllerProvider);
    final override = ref.read(localeControllerProvider.notifier).localeOverride;

    return MaterialApp.router(
      title: 'INTERACT',
      debugShowCheckedModeBanner: false,
      locale: override,
      supportedLocales: kTalkSupportedLocales,
      // Prefer an exact Talk locale (incl. Turkish `tr`) when the device
      // language is supported; otherwise fall back to English — never drop TR.
      localeResolutionCallback: (device, supported) {
        if (override != null) return override;
        if (device == null) return const Locale('en');
        for (final l in supported) {
          if (l.languageCode == device.languageCode) return l;
        }
        return const Locale('en');
      },
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D4A5C), // INTERACT teal-navy (matches app icon)
          brightness: Brightness.light,
        ).copyWith(
          secondary: const Color(0xFFBE9A5F), // gold accent
          tertiary: const Color(0xFFBE9A5F),
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D4A5C),
          brightness: Brightness.dark,
        ).copyWith(
          secondary: const Color(0xFFBE9A5F),
          tertiary: const Color(0xFFBE9A5F),
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      builder: (context, child) {
        final inner = child ?? const SizedBox.shrink();
        final code = Localizations.localeOf(context).languageCode;
        if (LocalePrefs.isRtlLanguageCode(code)) {
          return Directionality(
            textDirection: TextDirection.rtl,
            child: inner,
          );
        }
        return inner;
      },
    );
  }
}

/// Splash gate — route to Calls (default tab) if signed in, sign-in
/// otherwise. Calls is the landing surface, NOT Chats — voice/video is
/// the primary modality per the research-backed PRD.
class _Gate extends ConsumerStatefulWidget {
  const _Gate();
  @override
  ConsumerState<_Gate> createState() => _GateState();
}

class _GateState extends ConsumerState<_Gate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final auth = ref.read(authServiceProvider);
      // Offline-durable resume: valid token → in; refresh succeeds → in;
      // OFFLINE (no server) but we hold a refresh token → STAY in (cached
      // data + outbox, retry on reconnect); server REVOKE → sign-in; no
      // durable credential → sign-in. The old 8h hard-logout is gone.
      final outcome = await auth.attemptSilentResume();
      if (!mounted) return;

      if (outcome == RefreshOutcome.refreshed ||
          outcome == RefreshOutcome.offlineKeep) {
        // Navigate FIRST — never block cold-start on network / plugin init.
        // (A hung /me call or CallKit permission dialog looked like
        // splash-then-close on slower phones with a truncated APK.)
        context.go('/calls');

        // Background: establish refresh credential (backward-compat migration
        // for legacy 8h sessions), sync credentials + push/CallKit — all
        // fail-soft. Skipped implicitly when offline (calls just no-op).
        unawaited(() async {
          try {
            await auth.establishRefreshTokenIfNeeded();
          } catch (_) {/* ignore — retried next launch */}
          try {
            await auth.refreshCredentialsFromServer();
          } catch (_) {/* ignore */}
          if (!mounted) return;
          try {
            final calls = ref.read(callSignalingProvider);
            PushService.instance
                .init(auth, onCallTap: calls.checkNow, isRinging: calls.isRinging)
                .catchError((_) {});
            NotificationService.onMissedTap = _handleCallBack;
            CallKitService.instance.listenEvents(
              onAccept: _handleNativeCallAccept,
              onDecline: (id) => CallKitService.endCall(id),
              onCallback: _handleCallBack,
            );
            CallKitService.instance.requestPermissions().catchError((_) {});
            NotificationService.instance
                .init()
                .then((_) =>
                    NotificationService.instance.processLaunchPayloadIfAny())
                .catchError((_) {});
            CallKitService.instance
                .checkColdStart(onAccept: _handleNativeCallAccept)
                .catchError((_) {});
          } catch (_) {/* plugin init must never kill the session */}
        }());
        return;
      }

      // revoked / noCredential → sign-in. Prefill phone (secure storage is not
      // wiped by `adb install -r`), and mark WHY so the copy is accurate.
      final phone = await auth.phone();
      if (!mounted) return;
      final q = <String, String>{
        if (outcome == RefreshOutcome.revoked)
          'revoked': '1'
        else
          'expired': '1',
        if (phone != null && phone.isNotEmpty) 'phone': phone,
      };
      final qs = q.isEmpty
          ? ''
          : '?${q.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value)}').join('&')}';
      context.go('/sign-in$qs');
    });
  }

  @override
  Widget build(BuildContext context) {
    // Brand-colored gate (teal, matches the native splash + launcher icon) so
    // the cold-start transition native-splash → gate → /calls has NO white
    // flash/jerk. A bare white Scaffold here caused the "sudden splash" blink.
    return const Scaffold(
      backgroundColor: Color(0xFF0D4A5C),
      body: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFBE9A5F)),
        ),
      ),
    );
  }
}
