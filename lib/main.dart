// SPDX-License-Identifier: AGPL-3.0
//
// INTERACT — voice/video-first, offline-capable, AI-assisted communication
// super-app. Pakistan-first. Free, open-source under AGPLv3.
//
// Default landing tab is CALLS (research-backed: voice is the primary
// modality for the target audience). Chats sit secondary. Contacts + Me
// round out the bottom nav.
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/l10n/locale_prefs.dart';
import 'l10n/app_localizations.dart';
import 'models/chat.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/auth/profile_setup_screen.dart';
import 'screens/camera/camera_effects_screen.dart';
import 'screens/contacts/device_contacts_screen.dart';
import 'screens/me/backup_screen.dart';
import 'screens/chat/chat_thread_screen.dart';
import 'screens/chat/communities_screen.dart';
import 'screens/chat/new_group_screen.dart';
import 'screens/meeting/meeting_room_screen.dart';
import 'screens/meeting/incoming_call_screen.dart';
import 'screens/meeting/invite_screen.dart';
import 'services/call_signaling.dart';
import 'screens/meeting/townhall_entry_screen.dart';
import 'screens/meeting/live_room_screen.dart';
import 'services/live_api.dart';
import 'screens/shell/app_shell.dart';
import 'screens/tabs/calls_tab.dart';
import 'screens/tabs/chats_tab.dart';
import 'screens/tabs/contacts_tab.dart';
import 'screens/tabs/me_tab.dart';
import 'screens/tabs/menu_tab.dart';
import 'screens/lan/offline_lan_screen.dart';
import 'screens/mesh/nearby_mesh_screen.dart';
import 'services/auth_service.dart';
import 'services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // FCM for background/killed call ring. Fail-soft: if google-services.json /
  // Firebase isn't configured yet, the app still runs (ring stays foreground-only).
  try {
    await Firebase.initializeApp();
  } catch (_) {/* Firebase not configured — degrade gracefully */}
  runApp(const ProviderScope(child: InteractApp()));
}

/// Routes — ShellRoute hosts the bottom-nav scaffold so the tab
/// switcher persists across pushes. Sign-in + meeting room + invite
/// paste live OUTSIDE the shell (full-screen).
final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const _Gate()),
    GoRoute(
      path: '/sign-in',
      builder: (ctx, st) => SignInScreen(
        sessionExpired: st.uri.queryParameters['expired'] == '1',
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
    GoRoute(
        path: '/offline-lan',
        builder: (_, __) => const OfflineLanScreen()),
    GoRoute(
        path: '/nearby-mesh',
        builder: (_, __) => const NearbyMeshScreen()),
    GoRoute(
        path: '/device-contacts',
        builder: (_, __) => const DeviceContactsScreen()),
    GoRoute(path: '/backup', builder: (_, __) => const BackupScreen()),
    GoRoute(path: '/new-group', builder: (_, __) => const NewGroupScreen()),
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
    // Multi-party conference / townhall (LiveKit SFU) — entry + room.
    GoRoute(
        path: '/townhall', builder: (_, __) => const TownhallEntryScreen()),
    GoRoute(
      path: '/live',
      builder: (ctx, st) {
        final code = st.uri.queryParameters['code'] ?? '';
        final asHost = st.uri.queryParameters['host'] == 'true';
        final roleWire = st.uri.queryParameters['role'] ?? 'speaker';
        final role = LiveRole.values.firstWhere(
          (r) => r.wire == roleWire,
          orElse: () => LiveRole.speaker,
        );
        return LiveRoomScreen(code: code, asHost: asHost, role: role);
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
        return MeetingRoomScreen(
            roomCode: code, isHost: host, mode: mode, threadId: threadId);
      },
    ),
    GoRoute(
      path: '/chat/:id',
      builder: (ctx, st) {
        final thread = st.extra as ChatThread?;
        if (thread == null) {
          // Defensive fallback — should never hit in practice since
          // ChatsTab always passes extra:thread when pushing.
          return const Scaffold(body: Center(child: Text('Thread not found')));
        }
        return ChatThreadScreen(thread: thread);
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
        GoRoute(path: '/menu', builder: (_, __) => const MenuTab()),
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
      final signedIn = await auth.hasValidToken();
      if (!mounted) return;
      if (signedIn) {
        // Register for FCM call-ring push (fail-soft; no-op if unconfigured).
        PushService.instance.init(auth).catchError((_) {});
        context.go('/calls');
        return;
      }
      final expired = await auth.hasExpiredToken();
      final phone = await auth.phone();
      if (!mounted) return;
      final q = <String, String>{
        if (expired) 'expired': '1',
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
