// SPDX-License-Identifier: AGPL-3.0
//
// INTERACT — voice/video-first, offline-capable, AI-assisted communication
// super-app. Pakistan-first. Free, open-source under AGPLv3.
//
// Default landing tab is CALLS (research-backed: voice is the primary
// modality for the target audience). Chats sit secondary. Contacts + Me
// round out the bottom nav.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'models/chat.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/chat/chat_thread_screen.dart';
import 'screens/meeting/meeting_room_screen.dart';
import 'screens/meeting/invite_screen.dart';
import 'screens/shell/app_shell.dart';
import 'screens/tabs/calls_tab.dart';
import 'screens/tabs/chats_tab.dart';
import 'screens/tabs/contacts_tab.dart';
import 'screens/tabs/me_tab.dart';
import 'screens/tabs/menu_tab.dart';
import 'services/auth_service.dart';

void main() {
  runApp(const ProviderScope(child: InteractApp()));
}

/// Routes — ShellRoute hosts the bottom-nav scaffold so the tab
/// switcher persists across pushes. Sign-in + meeting room + invite
/// paste live OUTSIDE the shell (full-screen).
final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, __) => const _Gate()),
    GoRoute(path: '/sign-in', builder: (_, __) => const SignInScreen()),
    GoRoute(path: '/invite', builder: (_, __) => const InviteScreen()),
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

class InteractApp extends StatelessWidget {
  const InteractApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'INTERACT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF06B6D4), // INTERACT cyan
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF06B6D4),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
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
      context.go(signedIn ? '/calls' : '/sign-in');
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
