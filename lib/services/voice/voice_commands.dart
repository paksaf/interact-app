// SPDX-License-Identifier: AGPL-3.0
//
// Voice command / assistant (Phase 2b) — built ON TOP OF the Phase 2a voice
// services (TalkSttService + TalkTtsService). No new plugins.
//
// Flow: capture one spoken command via STT → parse a simple, robust intent →
// dispatch it by REUSING the existing call-start + navigation paths → confirm
// the action with TTS + a SnackBar. Everything is fail-soft: mic denied →
// SnackBar and return; nothing recognised → "Sorry, I didn't catch that" plus
// the raw transcript; an ambiguous name → open the relevant list rather than
// ever placing a call to the wrong person.
//
// Reuse map (nothing here reinvents a flow):
//   • Call     → chatApi.createDirectThread → callSignaling.ring → push /room
//                (identical to DialPadScreen._place / ChatThreadScreen._startCall)
//   • Message  → chatApi.createDirectThread → push /chat/:id (extra: thread)
//   • Navigate → go_router context.go('/calls' | '/chats' | '/contacts' |
//                '/me') and context.push('/dialpad'). "menu/more/apps" → '/me'.
//   • Search   → MessageSearchScreen(initialQuery: …)
//   • Name→peer→ talkApi.recentContacts() first, then DeviceContactsIndex.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_prefs.dart';
import '../../screens/chat/message_search_screen.dart';
import '../../utils/display_name.dart';
import '../call_signaling.dart';
import '../chat_api.dart';
import '../device_contacts_index.dart';
import '../talk_api.dart';
import '../talk_flags.dart';
import 'talk_stt_service.dart';
import 'talk_tts_service.dart';

/// Recognised command kinds. `call` also covers "dial <number>" (a raw number
/// is detected inside the handler and used directly).
enum _Kind { call, navigate, message, search, unknown }

class _Command {
  const _Command(this.kind, {this.arg = '', this.mode = 'voice', this.route});
  final _Kind kind;
  final String arg; // name / number / query
  final String mode; // 'voice' | 'video' (call only)
  final String? route; // navigate target
}

/// Singleton assistant. Stateless apart from a re-entrancy guard.
class VoiceCommands {
  VoiceCommands._();
  static final VoiceCommands instance = VoiceCommands._();

  bool _active = false;

  /// Listen for one command and act on it. Safe to call from a button's
  /// onPressed — never throws into the UI.
  Future<void> listenAndDispatch(BuildContext context, WidgetRef ref) async {
    if (_active) return;
    _active = true;
    final lang = _appLang(context, ref);
    // Capture the messenger BEFORE the first await — a captured
    // ScaffoldMessengerState stays usable after the widget unmounts, so
    // snackbars never touch `context` post-await.
    final messenger = ScaffoldMessenger.of(context);
    final stt = TalkSttService.instance;
    try {
      final started = await stt.start(appLang: lang);
      if (!started) {
        _snack(messenger, 'Microphone permission is needed for voice commands.');
        return;
      }
      if (!context.mounted) {
        await stt.cancel();
        return;
      }
      // Modal sheet mirrors the STT engine's partial transcript and pops with
      // the final text (or '' when nothing was heard / null when dismissed).
      final transcript = await showModalBottomSheet<String>(
        context: context,
        builder: (_) => const _ListeningSheet(),
      );
      if (!context.mounted) return;
      if (transcript == null) return; // user dismissed — silent
      final t = transcript.trim();
      if (t.isEmpty) {
        _say(messenger, lang, "Sorry, I didn't catch that.");
        return;
      }
      await _dispatch(context, ref, messenger, t, lang);
    } catch (_) {
      // Fail soft — an assistant hiccup must never crash the app.
    } finally {
      if (TalkSttService.instance.isListening) {
        unawaited(TalkSttService.instance.cancel());
      }
      _active = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Dispatch
  // ---------------------------------------------------------------------------

  Future<void> _dispatch(
    BuildContext context,
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    String raw,
    String lang,
  ) async {
    final cmd = _parse(raw);
    switch (cmd.kind) {
      case _Kind.call:
        await _handleCall(context, ref, messenger, cmd.arg, cmd.mode, lang);
      case _Kind.navigate:
        final route = cmd.route!;
        _say(messenger, lang, 'Opening ${_navLabel(route)}');
        if (!context.mounted) return;
        if (route == '/dialpad') {
          context.push(route);
        } else {
          context.go(route);
        }
      case _Kind.message:
        await _handleMessage(context, ref, messenger, cmd.arg, lang);
      case _Kind.search:
        _handleSearch(context, messenger, lang, cmd.arg);
      case _Kind.unknown:
        _say(messenger, lang, "Sorry, I didn't catch that.");
        _snack(messenger, 'Heard: "$raw"');
    }
  }

  Future<void> _handleCall(
    BuildContext context,
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    String arg,
    String mode,
    String lang,
  ) async {
    final token = arg.trim();
    if (token.isEmpty) {
      _say(messenger, lang, 'Who should I call?');
      if (context.mounted) context.push('/dialpad');
      return;
    }
    // Raw number → dial directly, no resolution guessing.
    if (_looksLikeNumber(token)) {
      final phone = token.replaceAll(RegExp(r'[^0-9+]'), '');
      _say(messenger, lang, 'Calling $phone');
      await _placeCall(context, ref, messenger,
          peerPhone: phone, displayName: phone, mode: mode, lang: lang);
      return;
    }
    final peer = await _resolvePeer(ref, token);
    if (peer == null) {
      // Never guess a call — open contacts so the user can pick.
      _say(messenger, lang, "I couldn't find $token.");
      if (context.mounted) context.go('/contacts');
      return;
    }
    final shown = peer.name.isEmpty ? token : peer.name;
    _say(messenger, lang, 'Calling $shown');
    if (!context.mounted) return;
    await _placeCall(context, ref, messenger,
        peerPhone: peer.phone, displayName: shown, mode: mode, lang: lang);
  }

  /// Identical to DialPadScreen._place: resolve peer + thread, ring, push
  /// /room as host. `mode` is 'voice' | 'video'.
  Future<void> _placeCall(
    BuildContext context,
    WidgetRef ref,
    ScaffoldMessengerState messenger, {
    required String peerPhone,
    required String displayName,
    required String mode,
    required String lang,
  }) async {
    try {
      final result =
          await ref.read(chatApiProvider).createDirectThread(peerPhone: peerPhone);
      if (!context.mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          final resolved = resolveDisplayName(
            deviceName: ref.read(deviceContactsIndexProvider).nameFor(peerPhone),
            backendName: thread.title,
            phone: peerPhone,
          );
          final peerName = resolved.isEmpty ? displayName : resolved;
          final inviteId =
              await ref.read(callSignalingProvider).ring(thread.id, mode);
          if (!context.mounted) return;
          final uri = Uri(
            // Flag-gated 1:1 media surface ('/call-lk' when TALK_LK_CALLS on,
            // else P2P '/room'); the ring above is unchanged either way.
            path: TalkFlags.callRoomPath(),
            queryParameters: {
              'host': 'true',
              'mode': mode,
              'threadId': thread.id,
              if (peerName.isNotEmpty) 'peerName': peerName,
              if (thread.avatarUrl != null && thread.avatarUrl!.isNotEmpty)
                'peerAvatar': thread.avatarUrl!,
              if (inviteId != null) 'inviteId': inviteId,
            },
          ).toString();
          context.push(uri);
        case DirectThreadUnregistered():
          _say(messenger, lang, "$displayName isn't on INTERACT yet.");
      }
    } catch (e) {
      _snack(messenger, 'Could not place call: $e');
    }
  }

  Future<void> _handleMessage(
    BuildContext context,
    WidgetRef ref,
    ScaffoldMessengerState messenger,
    String arg,
    String lang,
  ) async {
    final token = arg.trim();
    if (token.isEmpty) {
      _say(messenger, lang, 'Who do you want to message?');
      if (context.mounted) context.go('/chats');
      return;
    }
    String phone;
    String name = token;
    if (_looksLikeNumber(token)) {
      phone = token.replaceAll(RegExp(r'[^0-9+]'), '');
      name = phone;
    } else {
      final peer = await _resolvePeer(ref, token);
      if (peer == null) {
        _say(messenger, lang, "I couldn't find $token.");
        if (context.mounted) context.go('/chats');
        return;
      }
      phone = peer.phone;
      name = peer.name.isEmpty ? token : peer.name;
    }
    try {
      final result =
          await ref.read(chatApiProvider).createDirectThread(peerPhone: phone);
      if (!context.mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          _say(messenger, lang, 'Opening chat with $name');
          if (!context.mounted) return;
          // Do NOT auto-send text — just open the conversation.
          context.push('/chat/${thread.id}', extra: thread);
        case DirectThreadUnregistered():
          _say(messenger, lang, "$name isn't on INTERACT yet.");
      }
    } catch (e) {
      _snack(messenger, 'Could not open chat: $e');
    }
  }

  void _handleSearch(
    BuildContext context,
    ScaffoldMessengerState messenger,
    String lang,
    String arg,
  ) {
    final q = arg.trim();
    if (q.isEmpty) {
      // No query → the safest fallback is the chats list.
      context.go('/chats');
      return;
    }
    _say(messenger, lang, 'Searching for $q');
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MessageSearchScreen(initialQuery: q),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Name → peer resolution
  // ---------------------------------------------------------------------------

  /// Best peer for a spoken name. Recent Talk contacts first (they carry a
  /// server phone number), then the read-only device address book. Returns
  /// null when nothing is a confident match — callers must NOT guess a call.
  Future<({String phone, String name})?> _resolvePeer(
    WidgetRef ref,
    String query,
  ) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return null;

    List<Map<String, dynamic>> recents = const [];
    try {
      recents = await ref.read(talkApiProvider).recentContacts();
    } catch (_) {/* offline / not deployed — fall through to device book */}

    ({String phone, String name})? best;
    var bestScore = 0;
    for (final r in recents) {
      final phone = (r['phone'] as String?)?.trim() ?? '';
      if (phone.isEmpty) continue;
      final name = (r['name'] as String?)?.trim() ?? '';
      final score = _matchScore(name.toLowerCase(), q);
      if (score > bestScore) {
        bestScore = score;
        best = (phone: phone, name: name);
      }
    }
    if (best != null && bestScore > 0) return best;

    // Device address book fallback (prompt-free; empty if no permission).
    await ref.read(deviceContactsIndexProvider).ensureLoaded();
    final devPhone = ref.read(deviceContactsIndexProvider).phoneForName(query);
    if (devPhone != null && devPhone.isNotEmpty) {
      return (phone: devPhone, name: query);
    }
    return null;
  }

  /// 0 = no match. Higher = more confident. Whole name > exact token >
  /// name/token starts-with > substring.
  int _matchScore(String name, String q) {
    if (name.isEmpty) return 0;
    if (name == q) return 100;
    final tokens = name.split(RegExp(r'\s+'));
    if (tokens.contains(q)) return 80;
    if (name.startsWith(q)) return 60;
    if (tokens.any((t) => t.startsWith(q))) return 40;
    if (name.contains(q)) return 20;
    return 0;
  }

  bool _looksLikeNumber(String s) {
    final digits = RegExp(r'[0-9]').allMatches(s).length;
    final letters = RegExp(r'[A-Za-z؀-ۿ]').allMatches(s).length;
    return digits >= 7 && letters == 0;
  }

  // ---------------------------------------------------------------------------
  // Intent parser — simple, ordered keyword/regex matcher. English is the
  // primary set; a few ur/tr synonyms are folded in where cheap.
  // ---------------------------------------------------------------------------

  _Command _parse(String raw) {
    var t = raw.trim().toLowerCase();
    t = t
        .replaceAll(RegExp(r'[.?!،۔,]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // Common Urdu object marker "<name> ko" / "کو" → drop trailing.
    if (t.isEmpty) return const _Command(_Kind.unknown);

    RegExpMatch? m;

    // 1. Video call — must beat plain "call".
    m = RegExp(r'^(?:video call|videocall|video|ویڈیو کال|görüntülü ara)\s+(.+)$')
        .firstMatch(t);
    if (m != null) {
      return _Command(_Kind.call, arg: _stripObjectMarker(m.group(1)!), mode: 'video');
    }

    // 2. Explicit voice/audio call.
    m = RegExp(r'^(?:voice call|audio call|voice|sesli ara)\s+(.+)$').firstMatch(t);
    if (m != null) {
      return _Command(_Kind.call, arg: _stripObjectMarker(m.group(1)!), mode: 'voice');
    }

    // 3. Message / open chat with.
    m = RegExp(
            r'^(?:message|msg|text|write to|send (?:a )?message to|mesaj|پیغام|میسج)\s+(.+)$')
        .firstMatch(t);
    m ??= RegExp(r'^(?:open |start )?chat (?:with|to)\s+(.+)$').firstMatch(t);
    if (m != null) {
      return _Command(_Kind.message, arg: _stripObjectMarker(m.group(1)!));
    }

    // 4. Search.
    m = RegExp(r'^(?:search(?: for)?|find|look for|تلاش)\s+(.+)$').firstMatch(t);
    if (m != null) {
      return _Command(_Kind.search, arg: m.group(1)!.trim());
    }

    // 5. Navigate — "open/go to/show <target>" or a bare target word. Runs
    //    BEFORE the generic call verb so "dial pad" isn't read as "dial pad".
    m = RegExp(
            r'^(?:open|go to|goto|go|show|switch to|take me to|open up|aç|git|کھولو|دکھاؤ)\s+(.+)$')
        .firstMatch(t);
    final navArg = m != null ? m.group(1)!.trim() : t;
    final route = _routeForTarget(navArg);
    if (route != null) return _Command(_Kind.navigate, route: route);

    // 6. Generic call verb — "call/dial/phone/ring <name-or-number>".
    m = RegExp(r'^(?:call|dial|phone|ring|ara|کال)\s+(.+)$').firstMatch(t);
    if (m != null) {
      // Plain "call" is treated as a voice call (phone-style); "video call"
      // is caught earlier for video.
      return _Command(_Kind.call, arg: _stripObjectMarker(m.group(1)!), mode: 'voice');
    }

    return const _Command(_Kind.unknown);
  }

  /// Strip a trailing Urdu object marker ("<name> ko" / "کو") the STT may
  /// append, so "ahmed ko" resolves as "ahmed".
  String _stripObjectMarker(String s) {
    return s
        .replaceAll(RegExp(r'\s+(?:ko|کو)\s*$'), '')
        .trim();
  }

  String? _routeForTarget(String s) {
    final t = s.trim();
    if (RegExp(r'^(?:chats?|messages|inbox|conversations|mesajlar)$').hasMatch(t)) {
      return '/chats';
    }
    if (RegExp(r'^(?:calls?|call log|recents?|aramalar)$').hasMatch(t)) {
      return '/calls';
    }
    if (RegExp(r'^(?:contacts?|people|kişiler)$').hasMatch(t)) {
      return '/contacts';
    }
    // Phase-1 redesign removed the standalone Menu tab; "menu/more/apps" now
    // resolves to the Me tab, which holds settings + the redistributed items.
    if (RegExp(r'^(?:menu|more|apps)$').hasMatch(t)) return '/me';
    if (RegExp(r'^(?:me|profile|my profile|account|settings|profil)$')
        .hasMatch(t)) {
      return '/me';
    }
    if (RegExp(r'^(?:dial ?pad|dialer|keypad|numpad)$').hasMatch(t)) {
      return '/dialpad';
    }
    return null;
  }

  String _navLabel(String route) {
    switch (route) {
      case '/chats':
        return 'chats';
      case '/calls':
        return 'calls';
      case '/contacts':
        return 'contacts';
      case '/me':
        return 'your profile';
      case '/dialpad':
        return 'the dial pad';
      default:
        return route;
    }
  }

  // ---------------------------------------------------------------------------
  // Feedback helpers
  // ---------------------------------------------------------------------------

  String _appLang(BuildContext context, WidgetRef ref) {
    final override = ref.read(localeControllerProvider.notifier).localeOverride;
    if (override != null) return override.languageCode;
    return Localizations.localeOf(context).languageCode;
  }

  /// Confirm an action: SnackBar (always visible) + TTS (best-effort, NOT
  /// awaited so navigation isn't blocked on speech completing). Uses a
  /// ScaffoldMessengerState captured before any await, so it's safe post-unmount.
  void _say(ScaffoldMessengerState messenger, String lang, String msg) {
    _snack(messenger, msg);
    unawaited(
      TalkTtsService.instance.speak(msg, appLang: lang).catchError((_) {}),
    );
  }

  void _snack(ScaffoldMessengerState messenger, String msg) {
    messenger.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

/// The "Listening…" affordance. Mirrors STT partial transcript and pops with
/// the final text (or '') when the engine stops, or when the user taps Stop.
class _ListeningSheet extends StatefulWidget {
  const _ListeningSheet();
  @override
  State<_ListeningSheet> createState() => _ListeningSheetState();
}

class _ListeningSheetState extends State<_ListeningSheet> {
  final _stt = TalkSttService.instance;
  bool _popped = false;

  @override
  void initState() {
    super.initState();
    _stt.addListener(_onTick);
  }

  void _onTick() {
    if (!mounted || _popped) return;
    if (!_stt.isListening) {
      // Final result arrived (or engine stopped) — grab it and close.
      unawaited(_finish());
    } else {
      setState(() {}); // refresh the live partial transcript
    }
  }

  Future<void> _finish() async {
    if (_popped) return;
    _popped = true;
    final text = await _stt.stop();
    if (mounted) Navigator.of(context).pop(text ?? '');
  }

  @override
  void dispose() {
    _stt.removeListener(_onTick);
    // Safety net — if the sheet is dismissed while still listening, stop the
    // engine so the mic is released.
    if (_stt.isListening) unawaited(_stt.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final partial = _stt.partial;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: cs.primaryContainer,
              child: Icon(Icons.mic, size: 32, color: cs.onPrimaryContainer),
            ),
            const SizedBox(height: 16),
            Text(
              'Listening…',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            Text(
              partial.isEmpty
                  ? 'Try: "call Ahmed", "open chats", "message Sara", "search invoice"'
                  : partial,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: partial.isEmpty ? cs.outline : cs.onSurface,
                fontWeight: partial.isEmpty ? FontWeight.w400 : FontWeight.w600,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _popped ? null : () => unawaited(_finish()),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }
}
