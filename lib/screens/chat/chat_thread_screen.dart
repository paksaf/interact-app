// SPDX-License-Identifier: AGPL-3.0
//
// ChatThreadScreen — one thread, full conversation. Text composer +
// voice-message record (record package) + voice playback (audioplayers)
// + on-device Whisper transcription (sahulat_common WhisperAsr).
//
// On-device STT is OPT-IN: the transcript is generated locally before
// upload and attached to the message body. Recipients see the audio +
// text together. If the user doesn't grant mic permission or the
// Urdu model isn't downloaded, the message still ships as voice only.
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'package:sahulat_common/sahulat_common.dart';

import '../../core/chat/message_markup.dart';
import '../../core/l10n/locale_prefs.dart';
import '../../services/analytics_service.dart';
import '../../services/report_service.dart';
import '../../l10n/app_localizations.dart';
import '../../core/offline/message_delivery_state.dart';
import '../../models/chat.dart';
import '../../services/ai_contact_service.dart';
import '../../services/chat_api.dart';
import '../../services/chat_connectivity_service.dart';
import '../../services/message_repository.dart';
import '../../services/location_share_service.dart';
import '../../utils/shared_location_pin.dart';
import '../../models/talk_bearer.dart';
import '../../services/message_watcher.dart';
import '../../services/call_signaling.dart';
import '../../services/auth_service.dart';
import '../../services/talk_flags.dart';
import '../../services/iot/iot_chat_bridge.dart';
import '../../services/thread_peer_registry.dart';
import '../../services/outbox_service.dart';
import '../../services/talk_api.dart';
import '../../services/transcription_service.dart';
import '../../services/voice/talk_stt_service.dart';
import '../../services/voice/talk_tts_service.dart';
import '../../utils/chat_formatters.dart';
import '../../utils/phone_normalize.dart';
import '../../widgets/chat/offline_chat_banner.dart';
import '../../widgets/chat/location_pin_bubble.dart';
import '../../widgets/chat/offline_peer_sheet.dart';
import '../../widgets/chat/chat_wallpaper_layer.dart';
import '../../widgets/chat/composer_emoji_sheet.dart';
import '../../widgets/chat/drawing_signature_sheet.dart';
import '../../widgets/chat/rich_message_text.dart';
import '../../widgets/report/report_reason_sheet.dart';
import '../../widgets/sms_fallback_sheet.dart';
import '../settings/chat_wallpaper_settings_screen.dart';
import 'chat_ai_actions.dart';
import 'message_search_screen.dart';
import 'communities_screen.dart';

class ChatThreadScreen extends ConsumerStatefulWidget {
  const ChatThreadScreen({super.key, required this.thread});
  final ChatThread thread;
  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  late Future<List<Message>> _messages;
  // Latest snapshot — kept in-memory so the ✨ AI menu can build a
  // prompt without re-fetching. Updated every time the FutureBuilder
  // resolves.
  List<Message> _latestMessages = const <Message>[];
  // Latest thread metadata from the polling tick — carries participant
  // typingAt cursors that drive the typing dots (#146) and peer-active
  // flag that gates calls (#142). Initialised from widget.thread; the
  // poller mutates it via setState on every refresh.
  late ChatThread _currentThread;
  // Polling and typing debounce timers — both cancelled in dispose().
  Timer? _pollTimer;
  Timer? _typingDebounce;
  // Last time we fired a typing heartbeat to the server. Used to
  // throttle: we send at most once every 3 seconds even if the user
  // types continuously, since the server treats any value within the
  // last 5s as "live typing" — heartbeating faster than that is waste.
  DateTime? _lastTypingPing;
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _recording = false;
  bool _sending = false;
  bool _dictating = false;

  String get _appLang {
    final override = ref.read(localeControllerProvider.notifier).localeOverride;
    if (override != null) return override.languageCode;
    return Localizations.localeOf(context).languageCode;
  }
  // Guards _startCall so a single call action can only fire ring() once per
  // attempt (double-tap / rapid re-entry would otherwise create multiple
  // invites and ring the peer several times — #dedup).
  bool _ringing = false;
  // True once the message list has been auto-scrolled to the newest message
  // for the first time. Drives the one-shot initial jump-to-bottom in the
  // FutureBuilder; subsequent polls only auto-stick when the user is already
  // near the bottom (see _maybeStickToBottom).
  bool _initialScrollDone = false;
  // True once the first message load resolves. Gates the full-screen spinner
  // so the 3s poll (which swaps _messages for a fresh Future.value) can't drop
  // the list back to a loading spinner each tick — that was the "screen flash".
  bool _firstLoadDone = false;
  /// Set when the first load fails — FutureBuilder must not spin forever.
  String? _loadError;
  DateTime? _recordStart;
  Timer? _recordTimer;
  Duration _recordElapsed = Duration.zero;
  // My local uuid — used to tell if I own a channel (read-only for others).
  String? _myId;

  /// Broadcast channel where I'm NOT the owner → composer is hidden (server
  /// also 403s a non-owner post). Until `_myId` resolves, treat channels as
  /// read-only so the composer never flashes for non-owners.
  bool get _isReadOnlyChannel {
    if (_currentThread.subjectType != 'channel') return false;
    if (_myId == null) return true;
    final iOwn = _currentThread.participants
        .any((p) => p.role == 'owner' && p.userId == _myId);
    return !iOwn;
  }

  StreamSubscription<int>? _outboxSub;
  StreamSubscription<List<Message>>? _localMsgSub;
  int _outboxPending = 0;

  bool get _isAiThread => widget.thread.id == kAiThreadId;
  bool get _isIotThread => widget.thread.id == kIotAlertsThreadId;
  bool get _isLocalOnlyThread => _isAiThread || _isIotThread;

  Future<void> _bindThreadPeer() async {
    if (_isLocalOnlyThread) return;
    var peerUserId = _currentThread.peerUserId;
    if ((peerUserId == null || peerUserId.isEmpty) && _myId != null) {
      for (final p in _currentThread.participants) {
        if (p.userId.isNotEmpty && p.userId != _myId) {
          peerUserId = p.userId;
          break;
        }
      }
    }
    if (peerUserId == null || peerUserId.isEmpty) {
      final myId = await ref.read(authServiceProvider).localUserId();
      if (myId != null) {
        for (final p in _currentThread.participants) {
          if (p.userId.isNotEmpty && p.userId != myId) {
            peerUserId = p.userId;
            break;
          }
        }
      }
    }
    await ThreadPeerRegistry.instance.bindThreadPeer(
      _currentThread.id,
      peerUserId,
    );
  }

  @override
  void initState() {
    super.initState();
    _currentThread = widget.thread;
    unawaited(_bindThreadPeer());
    // Cache my local uuid for the channel-owner check (read-only gate).
    ref.read(authServiceProvider).localUserId().then((id) {
      if (mounted && id != null) setState(() => _myId = id);
    }).catchError((_) {});
    // Suppress new-message notifications for the conversation on screen.
    ref.read(messageWatcherProvider).activeThreadId = widget.thread.id;
    // Invalidate connectivity banner when opening a thread.
    ref.invalidate(chatConnectivityProvider);
    if (_isLocalOnlyThread) {
      _messages = ref.read(messageRepositoryProvider).loadLocal(widget.thread.id);
    } else {
      _messages = ref.read(chatApiProvider).messages(widget.thread.id);
    }
    _localMsgSub = ref
        .read(messageRepositoryProvider)
        .watchThread(widget.thread.id)
        .listen((local) {
      if (!mounted || local.isEmpty) return;
      setState(() {
        _latestMessages = _mergeMessages(_latestMessages, local);
        _messages = Future.value(_latestMessages);
      });
    });
    // Seed _latestMessages on first load too — the FutureBuilder will
    // also seed it, but this covers the moment _openAiMenu fires
    // before the first build cycle resolves.
    _messages.then((m) {
      if (mounted) {
        setState(() {
          _latestMessages = m;
          _firstLoadDone = true;
          _loadError = null;
        });
      }
    }).catchError((Object e) {
      if (mounted) {
        setState(() {
          _firstLoadDone = true;
          _loadError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    });
    // When the offline outbox drains, refresh so pending clocks clear.
    _outboxSub = OutboxService.instance.changes.listen((n) {
      _outboxPending = n;
      if (!mounted) return;
      if (n == 0 && _latestMessages.any((m) => m.pending)) {
        unawaited(_refresh());
      } else {
        setState(() {});
      }
    });
    unawaited(OutboxService.instance.pendingCount().then((n) {
      if (mounted) setState(() => _outboxPending = n);
    }));
    // Wire the composer → typing heartbeat. Listener fires on every
    // keystroke; we throttle to a server POST every 3s (#146).
    _textCtrl.addListener(_onTextChanged);
    // Periodic refresh — Phase 1.5 is poll-based. Tightened to 2s so new
    // incoming messages (incl. attachments/video) appear within a couple
    // seconds instead of lagging, and the typing bubble stays live.
    // Only runs while this screen is mounted (self-cancels below, and is
    // cancelled in dispose). Phase 2 swaps for WebSocket.
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      _refresh();
    });
  }

  @override
  void dispose() {
    // Clear the active-thread suppression (only if it's still us).
    final watcher = ref.read(messageWatcherProvider);
    if (watcher.activeThreadId == widget.thread.id) {
      watcher.activeThreadId = null;
    }
    TalkSttService.instance.removeListener(_onSttTick);
    unawaited(TalkSttService.instance.cancel());
    unawaited(TalkTtsService.instance.stop());
    _outboxSub?.cancel();
    _localMsgSub?.cancel();
    _textCtrl.removeListener(_onTextChanged);
    _pollTimer?.cancel();
    _typingDebounce?.cancel();
    _recorder.dispose();
    _player.dispose();
    _recordTimer?.cancel();
    super.dispose();
  }

  /// Composer keystroke listener — sends a typing heartbeat to the
  /// server at most once per 3 seconds while the user is actively
  /// editing the composer (#146). Stops firing as soon as the user
  /// clears the field or pauses for > 3s.
  void _onTextChanged() {
    if (_textCtrl.text.isEmpty) return;
    final now = DateTime.now();
    if (_lastTypingPing != null &&
        now.difference(_lastTypingPing!).inSeconds < 3) {
      return;
    }
    _lastTypingPing = now;
    ref.read(chatApiProvider).sendTyping(widget.thread.id);
  }

  List<Message> _mergeMessages(List<Message> server, List<Message> local) {
    final byId = <String, Message>{};
    for (final m in server) {
      byId[m.id] = m;
    }
    for (final m in local) {
      if (m.pending || (m.bearer != null && m.bearer != TalkBearer.cloud.wire)) {
        byId.putIfAbsent(m.id, () => m);
      }
    }
    return byId.values.toList()..sort((a, b) => a.sentAt.compareTo(b.sentAt));
  }

  Future<void> _refresh() async {
    if (_isAiThread) {
      try {
        final local = await ref.read(messageRepositoryProvider).loadLocal(widget.thread.id);
        if (!mounted) return;
        setState(() {
          _latestMessages = local;
          _messages = Future.value(local);
          _firstLoadDone = true;
        });
      } catch (_) {}
      return;
    }
    // Use the combined loader so we get the latest thread metadata
    // (participant typingAt / lastReadAt cursors) AND the messages in
    // one round-trip. Updating _currentThread is what makes the typing
    // bubble + read-receipt ticks tick live as the poller runs.
    try {
      final view = await ref
          .read(chatApiProvider)
          .loadThreadAndMessages(widget.thread.id);
      if (!mounted) return;
      // Preserve peer flags from the initial open (server only returns
      // them on the POST /threads call, not on subsequent message GETs).
      final mergedThread = view.thread.copyWith(
        peerUserId: _currentThread.peerUserId ?? view.thread.peerUserId,
        peerHasInteractInstalled:
            _currentThread.peerHasInteractInstalled ??
                view.thread.peerHasInteractInstalled,
      );
      _latestMessages = await ref
          .read(messageRepositoryProvider)
          .mergeWithServer(widget.thread.id, view.messages);
      _firstLoadDone = true;
      setState(() {
        _currentThread = mergedThread;
        _messages = Future.value(_latestMessages);
      });
      // Keep the newest message visible after a poll brings new ones — but
      // only if the user is parked at/near the bottom. Called right after
      // setState (before the next layout pass) so the near-bottom check is
      // measured against what the user was actually looking at.
      _maybeStickToBottom();
    } catch (_) {
      // Don't surface poll errors — the visible state is the FutureBuilder
      // which still has the prior frame's data.
    }
  }

  /// Start a 1-to-1 call from this thread. `mode` is 'video' or 'voice'.
  /// Pushes /room?host=true&mode=<mode> which mints a fresh invite-code
  /// room via talk_api.createRoom() and connects the local user as host.
  /// The peer joins via push notification (Phase 2) or by pasting the
  /// 6-char code into /invite for now — Phase 1.5 has no auto-ring yet.
  ///
  /// Precheck (#145): if the server flagged this thread's peer as not
  /// having INTERACT installed, surface a clear message instead of
  /// dropping the user into a call screen that the peer will never
  /// answer. They can still proceed manually if they want.
  Future<void> _startCall({required String mode}) async {
    // Idempotency guard — one call action = exactly one ring(). Without this
    // a rapid double-tap (or re-entry before navigation) creates multiple
    // invites and rings the peer several times.
    if (_ringing) return;
    _ringing = true;
    try {
      await _startCallInner(mode: mode);
    } finally {
      if (mounted) _ringing = false;
    }
  }

  Future<void> _startCallInner({required String mode}) async {
    final peerActive = _currentThread.peerHasInteractInstalled;
    final peerName = _currentThread.title;
    // Room deep-link carrying peer name/avatar (WhatsApp-style "Calling…"
    // overlay) and — once the ring is created — the inviteId so the room's
    // hang-up can remotely cancel the callee's ring.
    String roomUri({String? inviteId}) => Uri(
          // Flag-gated: '/call-lk' (LiveKit + captions) when TALK_LK_CALLS is
          // on, else the unchanged P2P '/room'. Ring flow below is unchanged.
          path: TalkFlags.callRoomPath(),
          queryParameters: {
            'host': 'true',
            'mode': mode,
            'threadId': widget.thread.id,
            if (peerName.isNotEmpty) 'peerName': peerName,
            if (_currentThread.avatarUrl != null &&
                _currentThread.avatarUrl!.isNotEmpty)
              'peerAvatar': _currentThread.avatarUrl!,
            if (inviteId != null) 'inviteId': inviteId,
          },
        ).toString();
    if (peerActive == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$peerName isn\'t on INTERACT yet — they won\'t see your call. '
            'Invite them first from the chat list.',
          ),
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: 'Call anyway',
            onPressed: () => context.push(roomUri()),
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ringing $peerName…'), duration: const Duration(seconds: 3)),
    );
    // Ring the peer first so we get the inviteId, then open the room as host
    // carrying it (host=true → MeetingRoomScreen calls createRoom()).
    final inviteId =
        await ref.read(callSignalingProvider).ring(widget.thread.id, mode);
    if (!mounted) return;
    context.push(roomUri(inviteId: inviteId));
    AnalyticsService.instance.trackFeatureUse('call_start');
  }

  /// Group actions (add member / leave) — group threads only.
  Future<void> _groupMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(_currentThread.title),
              subtitle: Text('${_currentThread.participants.length} members'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Group voice (LiveKit)'),
              subtitle: const Text('Multi-party audio room — no ring'),
              onTap: () {
                Navigator.pop(ctx);
                // Multi-party group audio uses LiveKit SFU (not 1:1 mesh).
                // Room code = UUID without hyphens (≤32 alphanumeric).
                final code = widget.thread.id.replaceAll('-', '');
                context.push('/live?code=$code&host=true');
              },
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('Add member'),
              onTap: () { Navigator.pop(ctx); _addMember(); },
            ),
            ListTile(
              leading: const Icon(Icons.groups_2_outlined),
              title: const Text('Add to community'),
              subtitle: const Text('Group this chat under a community you own'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CommunitiesScreen(attachThreadId: widget.thread.id),
                ));
              },
            ),
            ListTile(
              leading: Icon(Icons.exit_to_app, color: Theme.of(ctx).colorScheme.error),
              title: Text('Leave group',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () { Navigator.pop(ctx); _leaveGroup(); },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addMember() async {
    final ctrl = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add member'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Phone number', hintText: '+923001234567'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Add')),
        ],
      ),
    );
    if (phone == null || phone.isEmpty) return;
    final normalized = normalizeInteractPhone(phone) ?? phone;
    try {
      final ok = await ref
          .read(chatApiProvider)
          .addGroupMember(widget.thread.id, normalized);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          ok ? 'Member added' : '$normalized isn\'t on INTERACT yet',
        ),
      ));
      if (ok) await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Add failed: $e')));
    }
  }

  Future<void> _leaveGroup() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave group?'),
        content: Text('You will stop receiving messages from ${_currentThread.title}.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Leave')),
        ],
      ),
    );
    if (confirm != true) return;
    final myId = await ref.read(authServiceProvider).localUserId();
    if (myId == null) return;
    try {
      await ref.read(chatApiProvider).leaveGroup(widget.thread.id, myId);
      if (!mounted) return;
      context.pop(); // back to chats list
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Leave failed: $e')));
    }
  }

  /// P3: schedule the composer text to send at a chosen future time.
  Future<void> _scheduleSend() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Type a message to schedule')),
      );
      return;
    }
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (time == null || !mounted) return;
    final when = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!when.isAfter(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a future time')),
      );
      return;
    }
    try {
      await ref.read(chatApiProvider).scheduleMessage(widget.thread.id, text, when);
      if (!mounted) return;
      _textCtrl.clear();
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scheduled for ${when.toLocal()}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not schedule: $e')));
      }
    }
  }

  /// P2: AI meeting summary. Paste/dictate the meeting transcript (live
  /// captions / on-device STT / notes) → grounded summary + action items,
  /// with an option to post the result into the thread.
  Future<void> _meetingSummary() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: _MeetingSummarySheet(
          onSummarize: (t, lang) => ref
              .read(chatApiProvider)
              .summarizeMeeting(widget.thread.id, t, lang: lang),
          onPost: (text) async {
            await ref.read(chatApiProvider).sendText(widget.thread.id, text);
            if (mounted) await _refresh();
          },
        ),
      ),
    );
  }

  Future<void> _openAiMenu() async {
    // Use the cached snapshot — _latestMessages is updated on every
    // FutureBuilder resolution (including the initial load). If empty
    // (first millisecond after open), fall back to awaiting the future.
    var msgs = _latestMessages;
    if (msgs.isEmpty) {
      try {
        msgs = await _messages;
      } catch (_) {
        msgs = const <Message>[];
      }
    }
    if (!mounted) return;
    await showChatAiActions(
      context: context,
      ref: ref,
      thread: widget.thread,
      messages: msgs,
      composerText: _textCtrl.text,
      onInsertToComposer: (text) {
        // Insert at the current cursor position or append.
        final selection = _textCtrl.selection;
        final base = _textCtrl.text;
        final insert = text;
        if (selection.isValid &&
            selection.start >= 0 &&
            selection.end <= base.length) {
          final before = base.substring(0, selection.start);
          final after = base.substring(selection.end);
          _textCtrl.value = TextEditingValue(
            text: '$before$insert$after',
            selection: TextSelection.collapsed(
                offset: before.length + insert.length),
          );
        } else {
          _textCtrl.text = base.isEmpty ? insert : '$base $insert';
          _textCtrl.selection = TextSelection.collapsed(
              offset: _textCtrl.text.length);
        }
        setState(() {}); // refresh composer mic→send icon swap
      },
    );
  }

  Future<void> _setDisappearing(int seconds) async {
    try {
      final applied = await ref
          .read(chatApiProvider)
          .setDisappearing(widget.thread.id, seconds);
      if (!mounted) return;
      setState(() {
        _currentThread = _currentThread.copyWith(
          disappearingSeconds: applied,
          clearDisappearing: applied == null || applied == 0,
        );
        // Re-filter visible bubbles under the new timer.
        _messages = Future.value(
          _latestMessages
              .where((m) => _currentThread.messageStillVisible(m.sentAt))
              .toList(),
        );
      });
      final label = switch (seconds) {
        0 => 'Disappearing messages off',
        3600 => 'Messages disappear after 1 hour',
        86400 => 'Messages disappear after 24 hours',
        604800 => 'Messages disappear after 7 days',
        _ => 'Disappearing timer updated',
      };
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(label)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _offerSmsFallback(String body) async {
    if (_isLocalOnlyThread || _currentThread.isGroup) return;
    final phone = peerPhoneFromThreadHints(
      subjectId: _currentThread.subjectId,
      title: _currentThread.title,
    );
    await showSmsFallbackSheet(
      context: context,
      ref: ref,
      toPhone: phone ?? '',
      body: body,
      threadId: _currentThread.id,
    );
  }

  Future<void> _offerSmsForPendingOutbox() async {
    final item = await OutboxService.instance.firstPendingChatText(
      threadId: _currentThread.id,
    );
    if (item == null || !mounted) return;
    final bodyMap = (item['body'] as Map?)?.cast<String, dynamic>();
    final body = (bodyMap?['body'] as String?)?.trim() ?? '';
    if (body.isEmpty) return;
    await _offerSmsFallback(body);
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_isAiThread) {
        final added =
            await ref.read(aiContactServiceProvider).sendUserMessage(text);
        _textCtrl.clear();
        if (mounted) {
          setState(() {
            _latestMessages = [..._latestMessages, ...added];
            _messages = Future.value(_latestMessages);
          });
        }
        _scrollToBottom();
        return;
      }

      final sent = await ref.read(messageRepositoryProvider).sendText(
            widget.thread.id,
            text,
            replyToId: _replyingTo?.id,
            targetPeerUserId: _currentThread.peerUserId,
          );
      _textCtrl.clear();
      if (mounted) setState(() => _replyingTo = null);
      if (sent.pending) {
        setState(() {
          _latestMessages = [..._latestMessages, sent];
          _messages = Future.value(_latestMessages);
        });
        if (mounted) {
          final label = sent.bearer == TalkBearer.lan.wire
              ? 'Sent via LAN'
              : sent.bearer == TalkBearer.bleMesh.wire
                  ? 'Sent via BLE mesh'
                  : 'Queued — will send when you’re back online';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(label), duration: const Duration(seconds: 2)),
          );
        }
        _scrollToBottom();
      } else {
        await _refresh();
        _scrollToBottom();
      }
      AnalyticsService.instance.trackFeatureUse('chat_send');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Send failed: $e'),
          action: !_isLocalOnlyThread && !_currentThread.isGroup
              ? SnackBarAction(
                  label: 'SMS',
                  onPressed: () => unawaited(_offerSmsFallback(text)),
                )
              : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const int _maxAttachmentBytes = 50 * 1024 * 1024; // 50 MB

  /// Share a location pin as chat text + Interact Maps deep link so the peer
  /// can open Navigate on the same coordinates (Maps donor path).
  Future<void> _shareLocationPin({bool live = false}) async {
    if (_sending) return;
    if (live) {
      await _startLiveLocationShare();
      return;
    }
    setState(() => _sending = true);
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Location permission is needed to share a pin.')),
          );
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 12));
      final body = formatLocationPinBody(
        lat: pos.latitude,
        lng: pos.longitude,
      );
      final sent = await ref.read(messageRepositoryProvider).sendText(
            widget.thread.id,
            body,
            targetPeerUserId: _currentThread.peerUserId,
          );
      if (sent.pending) {
        setState(() {
          _latestMessages = [..._latestMessages, sent];
          _messages = Future.value(_latestMessages);
        });
      } else {
        await _refresh();
      }
      _scrollToBottom();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share location: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startLiveLocationShare() async {
    if (_currentThread.isGroup || _currentThread.isChannel || _isLocalOnlyThread) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Live share works in 1:1 chats only.'),
          ),
        );
      }
      return;
    }
    final duration = await showModalBottomSheet<Duration>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Share live · 15 minutes'),
              onTap: () => Navigator.pop(ctx, const Duration(minutes: 15)),
            ),
            ListTile(
              title: const Text('Share live · 1 hour'),
              onTap: () => Navigator.pop(ctx, const Duration(hours: 1)),
            ),
            ListTile(
              title: const Text('Share live · until I stop'),
              onTap: () => Navigator.pop(ctx, const Duration(hours: 8)),
            ),
          ],
        ),
      ),
    );
    if (duration == null || !mounted) return;
    final ok = await LocationShareService.instance.startLiveShare(
      threadId: widget.thread.id,
      duration: duration,
      targetPeerUserId: _currentThread.peerUserId,
    );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Location permission required for live share.')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Live location sharing started (${duration.inMinutes} min)'),
        action: SnackBarAction(
          label: 'Trace',
          onPressed: () => context.push('/location-trace'),
        ),
      ),
    );
  }

  /// Attach flow: pick Photo / Video / File → 50 MB guard → upload to
  /// qurbanisahulat /api/v1/media/upload → send the returned URL as the
  /// message attachment. Backend caps images at 5 MB, video/audio/file at 50 MB.
  Future<void> _pickAndSendAttachment() async {
    if (_sending) {
      debugPrint('[attach] ignored — already sending');
      return;
    }
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        // Scrollable so Share location stays reachable on short phones (e.g. Redmi).
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.draw_outlined),
              title: const Text('Draw or sign'),
              subtitle: const Text('Sketch → PNG attachment'),
              onTap: () => Navigator.pop(ctx, 'draw'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              subtitle: const Text('Capture with Talk camera'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Camera FX'),
              subtitle: const Text('Background effects & filters'),
              onTap: () => Navigator.pop(ctx, 'camera-fx'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video'),
              subtitle: const Text('Pick from gallery'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam),
              title: const Text('Record video'),
              subtitle: const Text('Capture with system camera (max 60s)'),
              onTap: () => Navigator.pop(ctx, 'record-video'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File / audio / document'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.location_on_outlined),
              title: const Text('Share location'),
              subtitle: const Text('Pin + open in Interact Maps'),
              onTap: () => Navigator.pop(ctx, 'location'),
            ),
            ListTile(
              leading: const Icon(Icons.my_location),
              title: const Text('Share live location'),
              subtitle: const Text('Updates every minute · offline-capable'),
              onTap: () => Navigator.pop(ctx, 'location-live'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    debugPrint('[attach] choice=$choice');

    // Camera FX moved into the attach menu (Phase-1 redesign). It's a
    // full-screen background-effects surface, not an inline picker — route to
    // the existing CameraEffectsScreen and stop the attachment flow here.
    if (choice == 'camera-fx') {
      context.push('/camera-effects');
      return;
    }
    if (choice == 'draw') {
      await _sendDrawingAttachment();
      return;
    }

    // Location pin → text + Maps deep link (Maps donor: interactmaps://route).
    if (choice == 'location') {
      await _shareLocationPin();
      return;
    }
    if (choice == 'location-live') {
      await _shareLocationPin(live: true);
      return;
    }

    if (choice != 'location' && choice != 'location-live') {
      final cloudOk = await ChatMediaPolicy.canUploadToCloud();
      if (!cloudOk && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(ChatMediaPolicy.offlineMediaMessage)),
        );
        return;
      }
    }

    File? file;
    try {
      if (choice == 'camera') {
        // Use the SYSTEM camera via image_picker. The in-app CameraController
        // path (ChatCameraCaptureScreen) crashes on many budget devices with
        // CameraX "No supported surface combination … too many use cases"
        // (Preview + JPEG capture + Video bound together at 720p). The system
        // camera handles all surfaces natively and never hits that limit, and
        // it can't hang the app the way the embedded controller did.
        final x = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
          requestFullMetadata: false,
        );
        if (x != null) file = File(x.path);
      } else if (choice == 'record-video') {
        // Record a SHORT clip via the SYSTEM camera (image_picker), NOT the
        // in-app CameraController (that crashes on budget devices — see the
        // 'camera' branch above). 60s cap keeps the upload under the 50 MB
        // guard. Flows through the same uploadMedia + sendAttachment path
        // as the 'video' (gallery) choice.
        final x = await ImagePicker().pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(seconds: 60),
        );
        if (x != null) file = File(x.path);
      } else if (choice == 'photo' || choice == 'video') {
        final picker = ImagePicker();
        // requestFullMetadata:false avoids a known Android 13+ photo-picker
        // hang on some OEMs (skips the EXIF/location metadata round-trip).
        final x = choice == 'photo'
            ? await picker.pickImage(
                source: ImageSource.gallery,
                imageQuality: 85,
                requestFullMetadata: false,
              )
            : await picker.pickVideo(source: ImageSource.gallery);
        if (x != null) file = File(x.path);
      } else {
        final r = await FilePicker.platform.pickFiles(withData: false);
        final p = r?.files.single.path;
        if (p != null) file = File(p);
      }
    } catch (e) {
      debugPrint('[attach] picker error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not pick file: $e')));
      }
      return;
    }
    debugPrint('[attach] picker returned file=${file != null} path=${file?.path}');
    if (file == null || !mounted) return;

    final size = await file.length();
    debugPrint('[attach] file length=$size bytes');
    if (size > _maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That file is over 50 MB — pick a smaller one.')),
        );
      }
      return;
    }

    // Soft blur gate for photos (TryOn / Sahulat donor) — Retake or Use anyway.
    if (choice == 'photo' || choice == 'camera') {
      try {
        final bytes = await file.readAsBytes();
        final gate = await BlurSoftGate.evaluate(bytes);
        if (gate.needsConfirm && mounted) {
          final useAnyway = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Photo looks blurry'),
              content: Text(gate.message),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Retake')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Use anyway')),
              ],
            ),
          );
          if (useAnyway != true) return;
        }
      } catch (_) {/* gate is soft — never block send on measure failure */}
    }

    setState(() => _sending = true);
    final caption = _textCtrl.text.trim();
    try {
      debugPrint('[attach] uploadMedia start (${file.path})');
      final up = await ref.read(chatApiProvider).uploadMedia(file);
      debugPrint('[attach] uploadMedia done url=${up.url}');
      final sent = await ref.read(chatApiProvider).sendAttachment(
            widget.thread.id,
            url: up.url,
            caption: caption,
          );
      _textCtrl.clear();
      if (sent.pending) {
        setState(() {
          _latestMessages = [..._latestMessages, sent];
          _messages = Future.value(_latestMessages);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Queued — will send when you’re back online'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } else {
        await _refresh();
      }
      _scrollToBottom();
      AnalyticsService.instance.trackFeatureUse('chat_attach');
    } catch (e) {
      debugPrint('[attach] failed: $e — queueing locally');
      if (!mounted) return;
      // Offline / upload failure: keep the file in the outbox.
      try {
        final pending = await ref.read(chatApiProvider).queueAttachment(
              widget.thread.id,
              file,
              caption: caption,
            );
        _textCtrl.clear();
        setState(() {
          _latestMessages = [..._latestMessages, pending];
          _messages = Future.value(_latestMessages);
        });
        _scrollToBottom();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved offline — will upload when online'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e2) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Attachment failed'),
            content: SingleChildScrollView(child: Text('$e\n$e2')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } finally {
      // _sending is only ever set true inside this block, so the finally
      // guarantees it can never get stuck (all earlier early-returns happen
      // before it is set).
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Drawing / signature sheet → PNG → media/upload → attachment message.
  Future<void> _sendDrawingAttachment() async {
    if (_sending) return;
    final cloudOk = await ChatMediaPolicy.canUploadToCloud();
    if (!cloudOk) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(ChatMediaPolicy.offlineMediaMessage)),
        );
      }
      return;
    }
    if (!mounted) return;
    final file = await DrawingSignatureSheet.show(context);
    if (file == null || !mounted) return;
    setState(() => _sending = true);
    final caption = _textCtrl.text.trim();
    try {
      final up = await ref.read(chatApiProvider).uploadMedia(file);
      final sent = await ref.read(chatApiProvider).sendAttachment(
            widget.thread.id,
            url: up.url,
            caption: caption,
          );
      _textCtrl.clear();
      if (sent.pending) {
        setState(() {
          _latestMessages = [..._latestMessages, sent];
          _messages = Future.value(_latestMessages);
        });
      } else {
        await _refresh();
      }
      _scrollToBottom();
      AnalyticsService.instance.trackFeatureUse('chat_attach');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Drawing send failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startRecording() async {
    if (!await _recorder.hasPermission()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mic permission denied')),
      );
      return;
    }
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
      path: path,
    );
    setState(() {
      _recording = true;
      _recordStart = DateTime.now();
      _recordElapsed = Duration.zero;
    });
    _recordTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _recordStart == null) return;
      setState(() => _recordElapsed = DateTime.now().difference(_recordStart!));
    });
  }

  Future<void> _stopRecordingAndSend() async {
    final path = await _recorder.stop();
    _recordTimer?.cancel();
    setState(() => _recording = false);
    if (path == null) return;
    if (!await ChatMediaPolicy.canUploadToCloud()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(ChatMediaPolicy.offlineMediaMessage)),
        );
      }
      return;
    }
    final durSec = _recordElapsed.inSeconds.clamp(1, 600);

    setState(() => _sending = true);
    try {
      final api = ref.read(chatApiProvider);
      final up = await api.uploadMedia(File(path));
      // Transcription is now ON-DEMAND (tap "Transcribe" on the voice bubble →
      // cloud Deepgram via /api/v1/talk/transcribe). We no longer auto-STT at
      // send time, so voice sends stay fast and don't burn Deepgram minutes.
      await api.sendVoice(
        widget.thread.id,
        mediaUrl: up.url,
        durationSec: durSec,
      );
      await _refresh();
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Voice send failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _cancelRecording() async {
    await _recorder.stop();
    _recordTimer?.cancel();
    setState(() => _recording = false);
  }

  /// Message being replied to (quote) — shown as a preview above the composer
  /// and sent as replyToId. Cleared after send/cancel. (P1 overlay)
  Message? _replyingTo;

  /// Toggle my [emoji] reaction on [m] against the server overlay, then reload.
  Future<void> _toggleReaction(Message m, String emoji) async {
    final mine = m.reactions.any((r) => r.emoji == emoji && r.mine);
    final api = ref.read(chatApiProvider);
    try {
      if (mine) {
        await api.unreact(widget.thread.id, m.id, emoji);
      } else {
        await api.react(widget.thread.id, m.id, emoji);
      }
      await _refresh();
    } catch (_) {/* best-effort — overlay is non-critical */}
  }

  Future<void> _reportMessage(Message m) async {
    final ok = await showReportReasonSheet(
      context,
      subjectLabel: 'message',
      onSubmit: (reason, note) => ReportService.instance.reportMessage(
        threadId: widget.thread.id,
        messageId: m.id,
        reason: reason,
        note: note,
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report submitted — thank you')),
      );
    } else if (ok == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit report — try again later')),
      );
    }
  }

  Future<void> _toggleDictate() async {
    final stt = TalkSttService.instance;
    if (_dictating) {
      final text = await stt.stop();
      if (!mounted) return;
      setState(() => _dictating = false);
      if (text != null && text.isNotEmpty) {
        final base = _textCtrl.text;
        _textCtrl.text = base.isEmpty ? text : '$base $text';
        _textCtrl.selection =
            TextSelection.collapsed(offset: _textCtrl.text.length);
        setState(() {});
      }
      return;
    }
    setState(() => _dictating = true);
    stt.addListener(_onSttTick);
    try {
      final started = await stt.start(appLang: _appLang);
      // Unavailable (mic denied / init failed) — reset UI + fail soft.
      if (!started && mounted) {
        stt.removeListener(_onSttTick);
        setState(() => _dictating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice input unavailable')),
        );
      }
    } catch (_) {
      if (mounted) {
        stt.removeListener(_onSttTick);
        setState(() => _dictating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Voice input unavailable')),
        );
      }
    }
  }

  void _onSttTick() {
    if (!mounted || !_dictating) return;
    final partial = TalkSttService.instance.partial;
    if (partial.isNotEmpty) {
      // Live preview in the composer while listening.
      _textCtrl.value = TextEditingValue(
        text: partial,
        selection: TextSelection.collapsed(offset: partial.length),
      );
    }
    if (!TalkSttService.instance.isListening &&
        TalkSttService.instance.finalText.isNotEmpty) {
      final text = TalkSttService.instance.finalText;
      _textCtrl.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      setState(() => _dictating = false);
      TalkSttService.instance.removeListener(_onSttTick);
    } else {
      setState(() {});
    }
  }

  Future<void> _readAloud(Message m) async {
    final body = stripMessageMarkup(m.body.trim());
    if (body.isEmpty) return;
    final tts = TalkTtsService.instance;
    if (tts.isSpeaking) {
      await tts.stop();
      return;
    }
    try {
      await tts.speak(body, appLang: _appLang);
    } catch (_) {
      // TTS engine unavailable — fail soft, never crash the chat.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Read aloud unavailable')),
        );
      }
    }
  }

  /// Long-press action sheet: react / reply / pin / edit / delete (P1).
  Future<void> _showMessageActions(Message m) async {
    if (m.deleted) return;
    final l10n = AppLocalizations.of(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        const emojis = kTapbackEmojis;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: emojis
                        .map((e) => InkWell(
                              borderRadius: BorderRadius.circular(32),
                              onTap: () => Navigator.pop(ctx, 'react:$e'),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(e, style: const TextStyle(fontSize: 26)),
                              ),
                            ))
                        .toList(),
                  ),
                ),
              ),
              const Divider(height: 1),
              if (m.kind == MessageKind.text && m.body.trim().isNotEmpty)
                ListTile(
                  leading: Icon(TalkTtsService.instance.isSpeaking
                      ? Icons.stop
                      : Icons.volume_up_outlined),
                  title: Text(TalkTtsService.instance.isSpeaking
                      ? l10n.voiceStopSpeaking
                      : l10n.voiceReadAloud),
                  onTap: () => Navigator.pop(ctx, 'read_aloud'),
                ),
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(ctx, 'reply'),
              ),
              ListTile(
                leading: Icon(m.isPinned ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(m.isPinned ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(ctx, m.isPinned ? 'unpin' : 'pin'),
              ),
              if (m.isMine && m.kind == MessageKind.text)
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Edit'),
                  onTap: () => Navigator.pop(ctx, 'edit'),
                ),
              if (m.isMine)
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete for everyone'),
                  onTap: () => Navigator.pop(ctx, 'delete'),
                ),
              if (!m.isMine)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Report'),
                  onTap: () => Navigator.pop(ctx, 'report'),
                ),
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    if (action == 'report') {
      await _reportMessage(m);
      return;
    }
    if (action.startsWith('react:')) {
      await _toggleReaction(m, action.substring(6));
      return;
    }
    if (action == 'read_aloud') {
      await _readAloud(m);
      return;
    }
    final api = ref.read(chatApiProvider);
    try {
      switch (action) {
        case 'reply':
          setState(() => _replyingTo = m);
          return;
        case 'pin':
          await api.pinMessage(widget.thread.id, m.id, pinned: true);
          break;
        case 'unpin':
          await api.pinMessage(widget.thread.id, m.id, pinned: false);
          break;
        case 'edit':
          await _promptEdit(m);
          return;
        case 'delete':
          await api.deleteMessage(widget.thread.id, m.id);
          break;
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action failed: $e')));
      }
    }
  }

  Future<void> _promptEdit(Message m) async {
    final ctrl = TextEditingController(text: m.body);
    final newText = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: ctrl, autofocus: true, maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || !mounted) return;
    try {
      await ref.read(chatApiProvider).editMessage(widget.thread.id, m.id, newText);
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Edit failed: $e')));
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// After the message list updates (poll/refresh), keep the newest message
  /// in view ONLY when the user is already at/near the bottom (within ~150px
  /// of the end). If they've scrolled up to read history, leave their
  /// position untouched. Must be called synchronously right after the
  /// list's setState — at that instant the controller still reports the
  /// PRE-update extent, so "near bottom" reflects what the user was looking
  /// at; _scrollToBottom then animates to the freshly-grown extent on the
  /// next frame.
  void _maybeStickToBottom() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent - pos.pixels <= 150) {
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: cs.primaryContainer,
              backgroundImage: widget.thread.avatarUrl != null
                  ? NetworkImage(widget.thread.avatarUrl!)
                  : null,
              child: widget.thread.avatarUrl == null
                  ? Text(
                      widget.thread.title.isEmpty
                          ? '?'
                          : widget.thread.title[0].toUpperCase(),
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.thread.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Builder(builder: (_) {
                    // Subtitle gets contextual based on peer state (#142/#146):
                    //   - peer is typing now → "typing..."
                    //   - peer doesn't have INTERACT installed → warning
                    //   - group thread → member count
                    //   - default → "tap for info"
                    if (_currentThread.peerIsTyping(_myId)) {
                      return Text(
                        'typing…',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                          fontStyle: FontStyle.italic,
                        ),
                      );
                    }
                    if (_currentThread.peerHasInteractInstalled == false) {
                      return Text(
                        'Not on INTERACT yet — invite to chat',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.error,
                          fontWeight: FontWeight.w500,
                        ),
                      );
                    }
                    return Text(
                      _currentThread.isChannel
                          ? (_isReadOnlyChannel
                              ? 'Broadcast channel'
                              : 'Channel · you can post')
                          : _currentThread.isGroup
                              ? '${_currentThread.participants.length} members'
                              : 'tap for info',
                      style: TextStyle(fontSize: 11, color: cs.outline),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome),
            tooltip: 'AI assist',
            onPressed: _openAiMenu,
          ),
          IconButton(
            icon: const Icon(Icons.summarize_outlined),
            tooltip: 'Meeting summary',
            onPressed: _meetingSummary,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search messages',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MessageSearchScreen(threadId: widget.thread.id),
              ),
            ),
          ),
          if (!_currentThread.isGroup &&
              !_currentThread.isChannel &&
              !_isLocalOnlyThread)
            IconButton(
              icon: const Icon(Icons.lan_outlined),
              tooltip: 'Offline LAN peer',
              onPressed: () async {
                var peerUserId = _currentThread.peerUserId;
                if ((peerUserId == null || peerUserId.isEmpty) &&
                    _myId != null) {
                  for (final p in _currentThread.participants) {
                    if (p.userId.isNotEmpty && p.userId != _myId) {
                      peerUserId = p.userId;
                      break;
                    }
                  }
                }
                await showOfflinePeerSheet(
                  context: context,
                  threadId: _currentThread.id,
                  peerUserId: peerUserId,
                  peerDisplayName: _currentThread.title,
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Video call',
            onPressed: () => _startCall(mode: 'video'),
          ),
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            tooltip: 'Voice call',
            onPressed: () => _startCall(mode: 'voice'),
          ),
          IconButton(
            icon: const Icon(Icons.wallpaper_outlined),
            tooltip: 'Chat wallpaper',
            onPressed: () => showChatWallpaperEditor(
              context,
              ref,
              scope: ChatWallpaperEditorScope.thread,
              threadId: widget.thread.id,
            ),
          ),
          PopupMenuButton<int>(
            tooltip: 'Disappearing messages',
            icon: Icon(
              Icons.timer_outlined,
              color: (_currentThread.disappearingSeconds ?? 0) > 0
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onSelected: _setDisappearing,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('Off')),
              PopupMenuItem(value: 3600, child: Text('1 hour')),
              PopupMenuItem(value: 86400, child: Text('24 hours')),
              PopupMenuItem(value: 604800, child: Text('7 days')),
            ],
          ),
          if (_currentThread.isGroup || _currentThread.isChannel)
            IconButton(
              icon: Icon(_currentThread.isChannel
                  ? Icons.campaign_outlined
                  : Icons.group_outlined),
              tooltip: _currentThread.isChannel ? 'Channel' : 'Group',
              onPressed: _groupMenu,
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          ChatWallpaperLayer(threadId: widget.thread.id),
          Column(
        children: [
          if (!_isLocalOnlyThread)
            OfflineChatBanner(
              threadId: _currentThread.id,
              outboxPending: _outboxPending,
              peerUserId: _currentThread.peerUserId,
              peerDisplayName: _currentThread.title,
              isLocalOnlyThread: _isLocalOnlyThread,
              isGroup: _currentThread.isGroup || _currentThread.isChannel,
            ),
          if ((_currentThread.disappearingSeconds ?? 0) > 0)
            Material(
              color: cs.primaryContainer.withValues(alpha: 0.55),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.timer_outlined, color: cs.primary, size: 20),
                title: Text(
                  switch (_currentThread.disappearingSeconds) {
                    3600 => 'Disappearing messages · 1 hour',
                    86400 => 'Disappearing messages · 24 hours',
                    604800 => 'Disappearing messages · 7 days',
                    _ => 'Disappearing messages on',
                  },
                  style: TextStyle(fontSize: 13, color: cs.onPrimaryContainer),
                ),
              ),
            ),
          Expanded(
            child: FutureBuilder<List<Message>>(
              future: _messages,
              // Carry the cached list across each poll's future swap so the
              // builder keeps rendering messages instead of flashing a spinner.
              initialData: _latestMessages,
              builder: (ctx, snap) {
                if (snap.hasError && !_firstLoadDone) {
                  _firstLoadDone = true;
                  _loadError ??=
                      snap.error.toString().replaceFirst('Exception: ', '');
                }
                final raw = snap.data ?? const <Message>[];
                // Spinner only during the very first load (no cached messages
                // yet). Afterwards initialData (= _latestMessages) keeps the
                // prior frame's list visible, so 3s polls never flash a spinner.
                if (!_firstLoadDone && raw.isEmpty && _loadError == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (_loadError != null && raw.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Couldn’t load messages',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _loadError!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.outline, fontSize: 13),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () {
                              setState(() {
                                _loadError = null;
                                _firstLoadDone = false;
                                _messages = ref
                                    .read(chatApiProvider)
                                    .messages(widget.thread.id);
                                _messages.then((m) {
                                  if (mounted) {
                                    setState(() {
                                      _latestMessages = m;
                                      _firstLoadDone = true;
                                    });
                                  }
                                }).catchError((Object e) {
                                  if (mounted) {
                                    setState(() {
                                      _firstLoadDone = true;
                                      _loadError = e
                                          .toString()
                                          .replaceFirst('Exception: ', '');
                                    });
                                  }
                                });
                              });
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final msgs = raw
                    .where((m) => _currentThread.messageStillVisible(m.sentAt))
                    .toList();
                // Keep the cached snapshot fresh for the ✨ AI menu.
                // Prefer unfiltered cache so disappearing filter doesn't
                // permanently drop still-valid rows from memory.
                if (raw.isNotEmpty) _latestMessages = raw;
                if (msgs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.chat_bubble_outline,
                              size: 48, color: cs.outline),
                          const SizedBox(height: 12),
                          Text(
                            _isReadOnlyChannel
                                ? 'No posts in this channel yet'
                                : 'No messages yet',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _isReadOnlyChannel
                                ? 'Only the owner can post here.'
                                : 'Say hi — or tap the paperclip to share a photo.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: cs.outline, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                // Interleave messages with day-separator chips when the
                // calendar day flips between consecutive messages.
                final items = <Widget>[];
                DateTime? lastDay;
                for (var i = 0; i < msgs.length; i++) {
                  final m = msgs[i];
                  final thatDay = DateTime(
                    m.sentAt.year,
                    m.sentAt.month,
                    m.sentAt.day,
                  );
                  if (lastDay == null || thatDay != lastDay) {
                    items.add(_DaySeparator(when: m.sentAt));
                    lastDay = thatDay;
                  }
                  items.add(_MessageBubble(
                    message: m,
                    player: _player,
                    repliedTo: m.replyToId == null
                        ? null
                        : msgs
                            .cast<Message?>()
                            .firstWhere((x) => x?.id == m.replyToId, orElse: () => null),
                    onLongPress: () => _showMessageActions(m),
                    onReactTap: (emoji) => _toggleReaction(m, emoji),
                  ));
                }
                // Live typing indicator — render after the last bubble
                // so it sits where the peer's next message would land.
                // Shows only when `_currentThread.peerIsTyping` is true
                // (any non-self participant has typingAt within last 5s).
                if (_currentThread.peerIsTyping(_myId)) {
                  items.add(const _TypingBubble());
                }
                // First render with messages: land at the newest message so
                // the thread opens at the bottom (WhatsApp behaviour) instead
                // of the oldest message at the top. One-shot — subsequent
                // updates are handled by _maybeStickToBottom in _refresh. The
                // post-frame callback runs after this build's layout, so the
                // controller has clients and the final maxScrollExtent.
                if (!_initialScrollDone) {
                  _initialScrollDone = true;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (_scrollCtrl.hasClients) {
                      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                    }
                  });
                }
                return ListView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  children: items,
                );
              },
            ),
          ),
          if (_outboxPending > 0)
            Material(
              color: Theme.of(context).colorScheme.tertiaryContainer,
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
                              Icon(Icons.cloud_upload_outlined,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onTertiaryContainer),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '$_outboxPending waiting to send — tap to retry',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onTertiaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!_isLocalOnlyThread && !_currentThread.isGroup)
                      TextButton.icon(
                        onPressed: _offerSmsForPendingOutbox,
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
          if (_isReadOnlyChannel || _isIotThread)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isIotThread ? Icons.sensors : Icons.campaign_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _isIotThread
                          ? 'Read-only alert log — tap ACK on IoT gateway'
                          : 'Broadcast channel — only the owner can post',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.outline,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  if (_isIotThread) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => context.push('/iot-comms'),
                      child: const Text('Open gateway'),
                    ),
                  ],
                ],
              ),
            )
          else ...[
          if (_replyingTo != null)
            Builder(builder: (context) {
              final cs = Theme.of(context).colorScheme;
              final r = _replyingTo!;
              return Container(
                color: cs.surfaceContainerHighest,
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                child: Row(
                  children: [
                    Container(width: 3, height: 32, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Replying to ${r.senderName}',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cs.primary)),
                          Text(r.body.isNotEmpty ? messagePlainPreview(r.body) : '📎 attachment',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _replyingTo = null),
                    ),
                  ],
                ),
              );
            }),
          _Composer(
            controller: _textCtrl,
            sending: _sending,
            recording: _recording,
            dictating: _dictating,
            recordElapsed: _recordElapsed,
            onSendText: _sendText,
            onStartRecord: _startRecording,
            onStopAndSend: _stopRecordingAndSend,
            onCancelRecord: _cancelRecording,
            onAttach: _pickAndSendAttachment,
            onSchedule: _scheduleSend,
            onDictate: _toggleDictate,
            onDraw: _sendDrawingAttachment,
          ),
          ],
        ],
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.player,
    required this.onLongPress,
    required this.onReactTap,
    this.repliedTo,
  });
  final Message message;
  final AudioPlayer player;
  final VoidCallback onLongPress;
  final void Function(String emoji) onReactTap;
  final Message? repliedTo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMine = message.isMine;
    final bg = isMine ? cs.primary : cs.surfaceContainerHighest;
    final fg = isMine ? cs.onPrimary : cs.onSurface;

    // Deleted-for-everyone: a muted, italic tombstone. No content/reactions.
    if (message.deleted) {
      return Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(top: 4, bottom: 4, left: isMine ? 64 : 0, right: isMine ? 0 : 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.block, size: 14, color: cs.outline),
            const SizedBox(width: 6),
            Text('This message was deleted',
                style: TextStyle(fontStyle: FontStyle.italic, color: cs.outline, fontSize: 13)),
          ]),
        ),
      );
    }

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: EdgeInsets.only(top: 4, bottom: 4, left: isMine ? 64 : 0, right: isMine ? 0 : 64),
          child: Column(
            crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(isMine ? 18 : 4),
                    bottomRight: Radius.circular(isMine ? 4 : 18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment:
                      isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (!isMine)
                      Text(
                        message.senderName,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary),
                      ),
                    // Quoted reply preview (P1).
                    if (repliedTo != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: fg.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                          border: Border(left: BorderSide(color: fg.withValues(alpha: 0.5), width: 3)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(repliedTo!.senderName,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg.withValues(alpha: 0.9))),
                            Text(
                              repliedTo!.deleted
                                  ? 'deleted message'
                                  : (repliedTo!.body.isNotEmpty ? repliedTo!.body : '📎 attachment'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.8)),
                            ),
                          ],
                        ),
                      ),
                    if (message.kind == MessageKind.voice) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.play_arrow, color: fg),
                            onPressed: () {
                              if (message.mediaUrl != null) {
                                player.play(UrlSource(message.mediaUrl!));
                              }
                            },
                          ),
                          Text('${message.mediaDurationSec ?? 0}s',
                              style: TextStyle(color: fg, fontSize: 12)),
                        ],
                      ),
                      if (message.transcript != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(message.transcript!, style: TextStyle(color: fg, fontSize: 12)),
                        ),
                      // On-demand transcription (cloud Deepgram) — shown when
                      // the note has no transcript yet.
                      if (message.mediaUrl != null && message.transcript == null)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: fg,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.subtitles_outlined, size: 16),
                          label: const Text('Transcribe', style: TextStyle(fontSize: 12)),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => _TranscribeDialog(
                              audioUrl: message.mediaUrl!,
                              itemId: message.id,
                            ),
                          ),
                        ),
                    ] else if (message.mediaUrl != null) ...[
                      _AttachmentView(url: message.mediaUrl!, fg: fg),
                      if (message.body.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: RichMessageText(
                            text: message.body,
                            style: TextStyle(color: fg),
                          ),
                        ),
                    ] else ...[
                      Builder(
                        builder: (context) {
                          final pin = parseSharedLocationPin(message.body);
                          if (pin != null) {
                            return LocationPinBubble(
                              pin: pin,
                              foreground: fg,
                              mutedForeground: fg.withValues(alpha: 0.75),
                            );
                          }
                          return RichMessageText(
                            text: message.body,
                            style: TextStyle(color: fg),
                          );
                        },
                      ),
                    ],
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.isPinned) ...[
                          Icon(Icons.push_pin, size: 11, color: fg.withValues(alpha: 0.7)),
                          const SizedBox(width: 3),
                        ],
                        Text(hm(message.sentAt),
                            style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7))),
                        if (message.edited)
                          Text(' · edited',
                              style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7))),
                        if (message.bearer != null &&
                            message.bearer != TalkBearer.cloud.wire)
                          Text(
                            ' · ${TalkBearer.fromWire(message.bearer).label}',
                            style: TextStyle(fontSize: 10, color: fg.withValues(alpha: 0.7)),
                          ),
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          Builder(
                            builder: (context) {
                              final delivery = MessageDeliveryState.resolve(
                                isMine: isMine,
                                pending: message.pending,
                                bearerWire: message.bearer,
                                deliveredAt: message.deliveredAt,
                                readAt: message.readAt,
                                foreground: fg,
                              );
                              if (delivery.semanticLabel.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Semantics(
                                label: delivery.semanticLabel,
                                child: Icon(
                                  delivery.icon,
                                  size: 12,
                                  color: delivery.tint,
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              // Reaction chips (tap to toggle mine).
              if (message.reactions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    spacing: 4,
                    children: message.reactions
                        .map((r) => GestureDetector(
                              onTap: () => onReactTap(r.emoji),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: r.mine ? cs.primaryContainer : cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: r.mine ? cs.primary : cs.outlineVariant,
                                    width: r.mine ? 1.2 : 1,
                                  ),
                                ),
                                child: Text('${r.emoji} ${r.count}', style: const TextStyle(fontSize: 12)),
                              ),
                            ))
                        .toList(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On-demand voice-note transcription dialog. Runs the hybrid
/// [TranscriptionService] (cloud Deepgram today; on-device whisper.cpp later),
/// shows the transcript + language + confidence, and captures 👍/👎 feedback +
/// Copy. Fail-soft: any error becomes a friendly message with a Retry.
class _TranscribeDialog extends ConsumerStatefulWidget {
  const _TranscribeDialog({required this.audioUrl, required this.itemId});
  final String audioUrl;
  final String itemId;
  @override
  ConsumerState<_TranscribeDialog> createState() => _TranscribeDialogState();
}

class _TranscribeDialogState extends ConsumerState<_TranscribeDialog> {
  bool _loading = true;
  TranscriptionResult? _result;
  String? _error;
  String? _rating; // "up" | "down" once submitted

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ref.read(transcriptionServiceProvider).transcribe(widget.audioUrl);
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } on TranscriptionException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendly(e);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Transcription unavailable';
        _loading = false;
      });
    }
  }

  String _friendly(TranscriptionException e) {
    switch (e.code) {
      case 'NOT_CONFIGURED':
        return 'Transcription is not available right now.';
      case 'RATE_LIMITED':
        return 'Too many transcriptions — try again in a minute.';
      case 'NETWORK':
        return 'No connection — transcription unavailable.';
      default:
        return 'Transcription unavailable';
    }
  }

  Future<void> _feedback(String rating) async {
    setState(() => _rating = rating);
    final ok = await ref.read(talkApiProvider).submitFeedback(
          feature: 'transcription',
          itemId: widget.itemId,
          rating: rating,
          language: _result?.language,
        );
    if (!mounted) return;
    if (!ok) setState(() => _rating = null); // allow a retry
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Thanks for the feedback' : "Couldn't send feedback")),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    final confPct = r?.confidence == null ? null : (r!.confidence! * 100).round();
    return AlertDialog(
      title: const Text('Transcription'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
                ? Text(_error!)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(r?.text ?? '', style: const TextStyle(fontSize: 15)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (r?.language != null && r!.language!.isNotEmpty)
                            Chip(
                              label: Text(r.language!.toUpperCase()),
                              visualDensity: VisualDensity.compact,
                            ),
                          if (confPct != null)
                            Chip(
                              label: Text('$confPct% confidence'),
                              visualDensity: VisualDensity.compact,
                            ),
                          Text(
                            r?.source == 'on-device' ? 'on-device' : 'cloud',
                            style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor),
                          ),
                        ],
                      ),
                      if (confPct != null && confPct < 70)
                        const Padding(
                          padding: EdgeInsets.only(top: 6),
                          child: Text('This may be inaccurate.',
                              style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                        ),
                    ],
                  ),
      ),
      actions: [
        if (!_loading && _error != null)
          TextButton(onPressed: _run, child: const Text('Retry')),
        if (!_loading && _error == null && r != null) ...[
          IconButton(
            tooltip: 'Good',
            icon: Icon(Icons.thumb_up,
                color: _rating == 'up' ? Theme.of(context).colorScheme.primary : null),
            onPressed: _rating == null ? () => _feedback('up') : null,
          ),
          IconButton(
            tooltip: 'Bad',
            icon: Icon(Icons.thumb_down,
                color: _rating == 'down' ? Theme.of(context).colorScheme.error : null),
            onPressed: _rating == null ? () => _feedback('down') : null,
          ),
          TextButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: r.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied')),
              );
            },
          ),
        ],
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

class _DaySeparator extends StatelessWidget {
  const _DaySeparator({required this.when});
  final DateTime when;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            daySeparator(when),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders a chat attachment: inline image thumbnail (tap → open full), or a
/// tappable chip for video/audio/other files (tap → open in the OS viewer).
class _AttachmentView extends StatelessWidget {
  const _AttachmentView({required this.url, required this.fg});
  final String url;
  final Color fg;

  static const _imageExts = {"jpg", "jpeg", "png", "webp", "gif", "avif", "heic"};

  String get _ext {
    final clean = url.split("?").first;
    final dot = clean.lastIndexOf(".");
    return dot >= 0 ? clean.substring(dot + 1).toLowerCase() : "";
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageExts.contains(_ext)) {
      return GestureDetector(
        onTap: _open,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.network(
            url,
            width: 200,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _chip(Icons.broken_image_outlined, "Image"),
            loadingBuilder: (ctx, child, progress) => progress == null
                ? child
                : const SizedBox(
                    width: 200,
                    height: 120,
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
          ),
        ),
      );
    }
    final isVideo = {"mp4", "mov", "webm", "avi", "m4v"}.contains(_ext);
    if (isVideo) {
      // Play video INLINE (in-app) — tap the thumbnail to load + play with
      // a play/pause overlay. No external browser launch (that was the old
      // "Video · tap to open" behaviour).
      return _InlineVideo(url: url, fg: fg);
    }
    final isAudio = {"m4a", "mp3", "aac", "ogg", "opus", "wav", "amr"}.contains(_ext);
    final icon = isAudio ? Icons.audiotrack : Icons.insert_drive_file_outlined;
    final label = isAudio ? "Audio" : "File";
    return GestureDetector(onTap: _open, child: _chip(icon, "$label · tap to open"));
  }

  Widget _chip(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 20),
          const SizedBox(width: 8),
          Flexible(
            child: Text(text,
                style: TextStyle(color: fg, decoration: TextDecoration.underline)),
          ),
        ],
      );
}

/// Inline chat video: a tappable poster that, on first tap, initialises a
/// [VideoPlayerController] from the network URL and plays the clip IN-APP
/// (AspectRatio + VideoPlayer). Tapping the video toggles play/pause. The
/// controller is lazily created (nothing downloads until the user taps) and
/// always disposed. Replaces the old "launch URL in browser" behaviour.
class _InlineVideo extends StatefulWidget {
  const _InlineVideo({required this.url, required this.fg});
  final String url;
  final Color fg;
  @override
  State<_InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<_InlineVideo> {
  VideoPlayerController? _controller;
  bool _initializing = false;
  bool _failed = false;

  @override
  void dispose() {
    // Always release the native player + buffered data.
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_initializing || _controller != null) return;
    setState(() {
      _initializing = true;
      _failed = false;
    });
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initializing = false;
      });
      await c.play();
    } catch (_) {
      await c.dispose();
      if (mounted) {
        setState(() {
          _initializing = false;
          _failed = true;
        });
      }
    }
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    // The ValueListenableBuilder below reacts to the controller's value
    // change, so no setState is needed here.
    c.value.isPlaying ? c.pause() : c.play();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    // Not loaded yet → poster tile with a play badge (or spinner / error).
    if (c == null || !c.value.isInitialized) {
      return GestureDetector(
        onTap: _failed ? _load : (_initializing ? null : _load),
        child: Container(
          width: 220,
          height: 132,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: _initializing
                ? const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _failed
                            ? Icons.error_outline
                            : Icons.play_circle_fill,
                        color: Colors.white,
                        size: 46,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _failed ? 'Tap to retry' : 'Video',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
          ),
        ),
      );
    }
    final ar = c.value.aspectRatio == 0 ? 16 / 9 : c.value.aspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: GestureDetector(
        onTap: _togglePlay,
        child: SizedBox(
          width: 240,
          child: AspectRatio(
            aspectRatio: ar,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(c),
                // Play overlay — shown only while paused.
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (_, value, __) => value.isPlaying
                      ? const SizedBox.shrink()
                      : Container(
                          decoration: const BoxDecoration(
                            color: Colors.black45,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(6),
                          child: const Icon(Icons.play_arrow,
                              color: Colors.white, size: 40),
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

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.recording,
    required this.dictating,
    required this.recordElapsed,
    required this.onSendText,
    required this.onStartRecord,
    required this.onStopAndSend,
    required this.onCancelRecord,
    required this.onAttach,
    required this.onSchedule,
    required this.onDictate,
    required this.onDraw,
  });
  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final bool dictating;
  final Duration recordElapsed;
  final VoidCallback onSendText;
  final VoidCallback onStartRecord;
  final VoidCallback onStopAndSend;
  final VoidCallback onCancelRecord;
  final VoidCallback onAttach;
  final VoidCallback onSchedule;
  final VoidCallback onDictate;
  final VoidCallback onDraw;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  bool _showFormatBar = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    if (widget.recording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        color: cs.errorContainer,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onCancelRecord,
                icon: Icon(Icons.delete_outline, color: cs.error),
              ),
              const SizedBox(width: 8),
              Icon(Icons.fiber_manual_record, color: cs.error, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recording — ${widget.recordElapsed.inSeconds}s',
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
              IconButton.filled(
                onPressed: widget.onStopAndSend,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showFormatBar)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FmtBtn(
                      icon: Icons.format_bold,
                      tooltip: 'Bold',
                      onPressed: widget.sending
                          ? null
                          : () => wrapComposerSelection(
                                widget.controller,
                                openTag: '{b}',
                                closeTag: '{/b}',
                              ),
                    ),
                    _FmtBtn(
                      icon: Icons.format_italic,
                      tooltip: 'Italic',
                      onPressed: widget.sending
                          ? null
                          : () => wrapComposerSelection(
                                widget.controller,
                                openTag: '{i}',
                                closeTag: '{/i}',
                              ),
                    ),
                    _FmtBtn(
                      icon: Icons.format_underlined,
                      tooltip: 'Underline',
                      onPressed: widget.sending
                          ? null
                          : () => wrapComposerSelection(
                                widget.controller,
                                openTag: '{u}',
                                closeTag: '{/u}',
                              ),
                    ),
                    _FmtBtn(
                      icon: Icons.format_color_text,
                      tooltip: 'Accent color',
                      onPressed: widget.sending
                          ? null
                          : () => wrapComposerSelection(
                                widget.controller,
                                openTag: '{c:BE9A5F}',
                                closeTag: '{/c}',
                              ),
                    ),
                    _FmtBtn(
                      icon: Icons.draw_outlined,
                      tooltip: 'Draw or sign',
                      onPressed: widget.sending ? null : widget.onDraw,
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                IconButton(
                  icon: Icon(
                    _showFormatBar ? Icons.text_fields : Icons.text_format,
                    color: _showFormatBar ? cs.primary : null,
                  ),
                  tooltip: 'Text formatting',
                  onPressed: widget.sending
                      ? null
                      : () => setState(() => _showFormatBar = !_showFormatBar),
                ),
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  tooltip: 'Attach photo, video or file',
                  onPressed: widget.sending ? null : widget.onAttach,
                ),
                IconButton(
                  icon: const Icon(Icons.schedule),
                  tooltip: 'Schedule send',
                  onPressed: widget.sending ? null : widget.onSchedule,
                ),
                IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  tooltip: 'Emoji',
                  onPressed: widget.sending || widget.recording
                      ? null
                      : () => ComposerEmojiSheet.show(
                            context,
                            onPick: (e) =>
                                insertAtComposerCursor(widget.controller, e),
                          ),
                ),
                IconButton(
                  icon: Icon(
                    widget.dictating ? Icons.mic : Icons.keyboard_voice_outlined,
                    color: widget.dictating ? cs.error : null,
                  ),
                  tooltip:
                      widget.dictating ? l10n.voiceListening : l10n.voiceDictateHint,
                  onPressed: widget.sending || widget.recording
                      ? null
                      : widget.onDictate,
                ),
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    minLines: 1,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: widget.dictating
                          ? l10n.voiceListening
                          : l10n.messageHint,
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 4),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: widget.controller,
                  builder: (_, value, __) {
                    final hasText = value.text.trim().isNotEmpty;
                    return GestureDetector(
                      onLongPress: widget.onStartRecord,
                      child: IconButton.filled(
                        onPressed: hasText ? widget.onSendText : widget.onStartRecord,
                        icon: Icon(hasText ? Icons.send : Icons.mic),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FmtBtn extends StatelessWidget {
  const _FmtBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onPressed,
    );
  }
}

/// Animated three-dot bubble shown at the end of the message list when
/// a peer is actively typing (#146). Sits left-aligned like an
/// incoming message bubble — same shape + grey surface — and runs a
/// 600ms loop of three dots fading in sequence. Polling-driven: it
/// disappears the next time _currentThread.peerIsTyping returns false.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();
  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 4, bottom: 4, right: 64),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) {
            // Three dots, each phase-shifted by 1/3 of the cycle.
            // Each dot eases between alpha 0.3 and 1.0 on a sine curve
            // so the row looks like a WhatsApp "..." pulse.
            Widget dot(double phase) {
              final t = (_ctrl.value + phase) % 1.0;
              final eased = 0.5 + 0.5 * (1 - (2 * t - 1).abs());
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(
                      alpha: 0.3 + 0.7 * eased,
                    ),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [dot(0.0), dot(0.33), dot(0.66)],
            );
          },
        ),
      ),
    );
  }
}

/// P2 meeting-summary sheet: transcript in → grounded AI summary + action
/// items → optionally post to the thread. Transcript source is the user
/// (paste / dictate / live-caption text); the server stays grounded.
class _MeetingSummarySheet extends StatefulWidget {
  const _MeetingSummarySheet({required this.onSummarize, required this.onPost});
  final Future<({String summary, List<String> actionItems})> Function(
    String transcript,
    String lang,
  ) onSummarize;
  final Future<void> Function(String text) onPost;

  @override
  State<_MeetingSummarySheet> createState() => _MeetingSummarySheetState();
}

class _MeetingSummarySheetState extends State<_MeetingSummarySheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _summary;
  List<String> _actions = const [];
  String _lang = 'en';

  static const _langs = <(String, String)>[
    ('en', 'English'),
    ('ur', 'Urdu'),
    ('ar', 'Arabic'),
    ('tr', 'Turkish'),
    ('ru', 'Russian'),
    ('pa', 'Punjabi'),
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final r = await widget.onSummarize(t, _lang);
      if (!mounted) return;
      setState(() {
        _summary = r.summary;
        _actions = r.actionItems;
      });
      if (r.summary.isEmpty && r.actionItems.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No summary produced (transcript too short, or AI unavailable).')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Summary failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _asMessage() {
    final b = StringBuffer('🧠 Meeting summary\n${_summary ?? ''}');
    if (_actions.isNotEmpty) {
      b.write('\n\nAction items:');
      for (final a in _actions) {
        b.write('\n• $a');
      }
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Meeting summary', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Paste or dictate the meeting transcript / notes.',
                style: TextStyle(fontSize: 12, color: cs.outline)),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'e.g. Ali: ship the APK today. Sara: run analyze then build…',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Summary language',
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _lang,
                        items: [
                          for (final (code, label) in _langs)
                            DropdownMenuItem(value: code, child: Text(label)),
                        ],
                        onChanged: _busy
                            ? null
                            : (v) {
                                if (v != null) setState(() => _lang = v);
                              },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : _run,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: const Text('Summarize'),
                ),
              ],
            ),
            if (_summary != null && _summary!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_summary!, style: const TextStyle(fontSize: 14)),
                      if (_actions.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text('Action items', style: Theme.of(context).textTheme.labelLarge),
                        const SizedBox(height: 4),
                        ..._actions.map((a) => Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('☐ '),
                                  Expanded(child: Text(a, style: const TextStyle(fontSize: 13))),
                                ],
                              ),
                            )),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        await widget.onPost(_asMessage());
                        if (context.mounted) Navigator.pop(context);
                      },
                      child: const Text('Post to chat'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
