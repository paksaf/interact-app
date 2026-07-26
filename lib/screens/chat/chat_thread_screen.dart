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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:sahulat_common/sahulat_common.dart';

import '../../models/chat.dart';
import '../../services/chat_api.dart';
import '../../services/message_watcher.dart';
import '../../services/call_signaling.dart';
import '../../services/auth_service.dart';
import '../../utils/chat_formatters.dart';
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
  DateTime? _recordStart;
  Timer? _recordTimer;
  Duration _recordElapsed = Duration.zero;
  // My local uuid — used to tell if I own a channel (read-only for others).
  String? _myId;

  /// Broadcast channel where I'm NOT the owner → composer is hidden (server
  /// also 403s a non-owner post). Only applies once _myId + participants load.
  bool get _isReadOnlyChannel {
    if (_currentThread.subjectType != 'channel' || _myId == null) return false;
    final iOwn = _currentThread.participants
        .any((p) => p.role == 'owner' && p.userId == _myId);
    return !iOwn;
  }

  @override
  void initState() {
    super.initState();
    _currentThread = widget.thread;
    // Cache my local uuid for the channel-owner check (read-only gate).
    ref.read(authServiceProvider).localUserId().then((id) {
      if (mounted && id != null) setState(() => _myId = id);
    }).catchError((_) {});
    // Suppress new-message notifications for the conversation on screen.
    ref.read(messageWatcherProvider).activeThreadId = widget.thread.id;
    _messages = ref.read(chatApiProvider).messages(widget.thread.id);
    // Seed _latestMessages on first load too — the FutureBuilder will
    // also seed it, but this covers the moment _openAiMenu fires
    // before the first build cycle resolves.
    _messages.then((m) {
      if (mounted) _latestMessages = m;
    }).catchError((_) {});
    // Wire the composer → typing heartbeat. Listener fires on every
    // keystroke; we throttle to a server POST every 3s (#146).
    _textCtrl.addListener(_onTextChanged);
    // Periodic refresh — Phase 1.5 is poll-based. We tighten to 3s so
    // the typing bubble feels live (anything slower and the dots lag
    // visibly behind the peer typing). Phase 2 swaps for WebSocket.
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (t) {
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

  Future<void> _refresh() async {
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
      _latestMessages = view.messages;
      setState(() {
        _currentThread = mergedThread;
        _messages = Future.value(view.messages);
      });
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
  void _startCall({required String mode}) {
    final peerActive = _currentThread.peerHasInteractInstalled;
    final peerName = _currentThread.title;
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
            onPressed: () => context.push('/room?host=true&mode=$mode&threadId=${widget.thread.id}'),
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ringing $peerName…'), duration: const Duration(seconds: 3)),
    );
    // Ring the peer (full-screen incoming call on their device), then open
    // the room as host. host=true → MeetingRoomScreen calls createRoom().
    ref.read(callSignalingProvider).ring(widget.thread.id, mode);
    context.push('/room?host=true&mode=$mode&threadId=${widget.thread.id}');
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
    try {
      final ok = await ref.read(chatApiProvider).addGroupMember(widget.thread.id, phone);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok ? 'Member added' : '$phone isn\'t on INTERACT yet'),
      ));
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

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final sent = await ref
          .read(chatApiProvider)
          .sendText(widget.thread.id, text, replyToId: _replyingTo?.id);
      _textCtrl.clear();
      if (mounted) setState(() => _replyingTo = null);
      if (sent.pending) {
        // Offline queue — keep bubble locally until flush succeeds.
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
        _scrollToBottom();
      } else {
        await _refresh();
        _scrollToBottom();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  static const int _maxAttachmentBytes = 50 * 1024 * 1024; // 50 MB

  /// Attach flow: pick Photo / Video / File → 50 MB guard → upload to
  /// qurbanisahulat /api/v1/media/upload → send the returned URL as the
  /// message attachment. Backend caps images at 5 MB, video/audio/file at 50 MB.
  Future<void> _pickAndSendAttachment() async {
    if (_sending) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Photo'),
              onTap: () => Navigator.pop(ctx, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Video'),
              onTap: () => Navigator.pop(ctx, 'video'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('File / audio / document'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;

    File? file;
    try {
      if (choice == 'photo' || choice == 'video') {
        final picker = ImagePicker();
        final x = choice == 'photo'
            ? await picker.pickImage(source: ImageSource.gallery, imageQuality: 85)
            : await picker.pickVideo(source: ImageSource.gallery);
        if (x != null) file = File(x.path);
      } else {
        final r = await FilePicker.platform.pickFiles(withData: false);
        final p = r?.files.single.path;
        if (p != null) file = File(p);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not pick file: $e')));
      }
      return;
    }
    if (file == null || !mounted) return;

    final size = await file.length();
    if (size > _maxAttachmentBytes) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That file is over 50 MB — pick a smaller one.')),
        );
      }
      return;
    }

    // Soft blur gate for photos (TryOn / Sahulat donor) — Retake or Use anyway.
    if (choice == 'photo') {
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
    try {
      final up = await ref.read(chatApiProvider).uploadMedia(file);
      await ref.read(chatApiProvider).sendAttachment(
            widget.thread.id,
            url: up.url,
            caption: _textCtrl.text.trim(),
          );
      _textCtrl.clear();
      await _refresh();
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Attachment failed: $e')),
      );
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
    final durSec = _recordElapsed.inSeconds.clamp(1, 600);

    setState(() => _sending = true);
    try {
      final api = ref.read(chatApiProvider);
      final up = await api.uploadMedia(File(path));
      // On-device Whisper is opt-in / model-gated — never block send on STT.
      String? transcript;
      try {
        transcript = await api.transcribeVoiceNote(File(path));
      } catch (_) {/* best-effort */}
      await api.sendVoice(
        widget.thread.id,
        mediaUrl: up.url,
        durationSec: durSec,
        transcript: transcript,
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

  /// Long-press action sheet: react / reply / pin / edit / delete (P1).
  Future<void> _showMessageActions(Message m) async {
    if (m.deleted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        const emojis = ['👍', '❤️', '😂', '🙏', '😮', '😢'];
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
              const Divider(height: 1),
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
            ],
          ),
        );
      },
    );
    if (action == null || !mounted) return;
    if (action.startsWith('react:')) {
      await _toggleReaction(m, action.substring(6));
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
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
                    if (_currentThread.peerIsTyping(null)) {
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
                      _currentThread.isGroup
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
          if (_currentThread.isGroup)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Group',
              onPressed: _groupMenu,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<Message>>(
              future: _messages,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final msgs = snap.data ?? const <Message>[];
                // Keep the cached snapshot fresh for the ✨ AI menu.
                if (msgs.isNotEmpty) _latestMessages = msgs;
                if (msgs.isEmpty) {
                  return Center(
                    child: Text('No messages yet — say hi 👋',
                        style: TextStyle(color: cs.outline)),
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
                if (_currentThread.peerIsTyping(null)) {
                  items.add(const _TypingBubble());
                }
                return ListView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.all(12),
                  children: items,
                );
              },
            ),
          ),
          if (_isReadOnlyChannel)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.campaign_outlined, size: 18, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(width: 8),
                  Text('Broadcast channel — only the owner can post',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline, fontSize: 13)),
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
                          Text(r.body.isNotEmpty ? r.body : '📎 attachment',
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
            recordElapsed: _recordElapsed,
            onSendText: _sendText,
            onStartRecord: _startRecording,
            onStopAndSend: _stopRecordingAndSend,
            onCancelRecord: _cancelRecording,
            onAttach: _pickAndSendAttachment,
            onSchedule: _scheduleSend,
          ),
          ],
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
                    ] else if (message.mediaUrl != null) ...[
                      _AttachmentView(url: message.mediaUrl!, fg: fg),
                      if (message.body.trim().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(message.body, style: TextStyle(color: fg)),
                        ),
                    ] else
                      Text(message.body, style: TextStyle(color: fg)),
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
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          Icon(
                            message.pending
                                ? Icons.schedule
                                : message.readAt != null ||
                                        message.deliveredAt != null
                                    ? Icons.done_all
                                    : Icons.done,
                            size: 12,
                            color: message.pending
                                ? fg.withValues(alpha: 0.7)
                                : message.readAt != null
                                    ? Colors.lightBlueAccent
                                    : fg.withValues(alpha: 0.7),
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
    final isVideo = {"mp4", "mov", "webm", "avi"}.contains(_ext);
    final isAudio = {"m4a", "mp3", "aac", "ogg", "opus", "wav", "amr"}.contains(_ext);
    final icon = isVideo
        ? Icons.play_circle_outline
        : isAudio
            ? Icons.audiotrack
            : Icons.insert_drive_file_outlined;
    final label = isVideo ? "Video" : isAudio ? "Audio" : "File";
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

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.recording,
    required this.recordElapsed,
    required this.onSendText,
    required this.onStartRecord,
    required this.onStopAndSend,
    required this.onCancelRecord,
    required this.onAttach,
    required this.onSchedule,
  });
  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final Duration recordElapsed;
  final VoidCallback onSendText;
  final VoidCallback onStartRecord;
  final VoidCallback onStopAndSend;
  final VoidCallback onCancelRecord;
  final VoidCallback onAttach;
  final VoidCallback onSchedule;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (recording) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        color: cs.errorContainer,
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              IconButton(
                onPressed: onCancelRecord,
                icon: Icon(Icons.delete_outline, color: cs.error),
              ),
              const SizedBox(width: 8),
              Icon(Icons.fiber_manual_record, color: cs.error, size: 14),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recording — ${recordElapsed.inSeconds}s',
                  style: TextStyle(color: cs.onErrorContainer),
                ),
              ),
              IconButton.filled(
                onPressed: onStopAndSend,
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
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attach photo, video or file',
              onPressed: sending ? null : onAttach,
            ),
            IconButton(
              icon: const Icon(Icons.schedule),
              tooltip: 'Schedule send',
              onPressed: sending ? null : onSchedule,
            ),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: 'Message',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                  ),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onChanged: (_) {},
              ),
            ),
            const SizedBox(width: 4),
            GestureDetector(
              onLongPress: onStartRecord,
              child: IconButton.filled(
                onPressed: controller.text.trim().isEmpty
                    ? onStartRecord
                    : onSendText,
                icon: Icon(controller.text.trim().isEmpty
                    ? Icons.mic
                    : Icons.send),
              ),
            ),
          ],
        ),
      ),
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
