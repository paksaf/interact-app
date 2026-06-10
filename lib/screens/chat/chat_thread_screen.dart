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

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../models/chat.dart';
import '../../services/chat_api.dart';
import '../../utils/chat_formatters.dart';
import 'chat_ai_actions.dart';

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

  @override
  void initState() {
    super.initState();
    _currentThread = widget.thread;
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
    final label = mode == 'voice' ? 'Voice call' : 'Video call';
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
    // Soft pre-flight — let the user know the peer doesn't auto-ring yet.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label starting — share the room code with $peerName',
        ),
        duration: const Duration(seconds: 4),
      ),
    );
    // host=true → MeetingRoomScreen calls createRoom() (no code needed).
    context.push('/room?host=true&mode=$mode&threadId=${widget.thread.id}');
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
      await ref.read(chatApiProvider).sendText(widget.thread.id, text);
      _textCtrl.clear();
      await _refresh();
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Send failed: $e')),
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

    // Phase 1.5 — upload via Comms Hub media route (placeholder).
    // For now, we ship the file path as a local URL; the server-side
    // /api/v1/chat/messages route should accept multipart uploads in
    // Phase 1.5 backend extension. Sahulat already has the route.
    setState(() => _sending = true);
    try {
      // TODO Phase 1.5 backend: POST multipart upload, get back mediaUrl
      final mediaUrl = 'file://$path'; // local stub; server returns CDN URL
      // TODO Phase 1.5: run on-device Whisper transcription
      // final transcript = await WhisperAsr.instance.transcribe(File(path));
      await ref.read(chatApiProvider).sendVoice(
        widget.thread.id,
        mediaUrl: mediaUrl,
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

  /// Local-only reactions until the server-side reactions table lands
  /// (Phase 2). Keyed by message id; mutates in setState so the UI
  /// re-renders. NOT yet persisted across app restarts.
  final Map<String, String> _reactions = <String, String>{};

  Future<void> _showReactionsSheet(Message m) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        const emojis = ['👍', '❤️', '😂', '🙏', '😮', '😢'];
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              children: emojis
                  .map((e) => InkWell(
                        borderRadius: BorderRadius.circular(32),
                        onTap: () => Navigator.pop(ctx, e),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(e, style: const TextStyle(fontSize: 28)),
                        ),
                      ))
                  .toList(),
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    setState(() {
      if (_reactions[m.id] == picked) {
        _reactions.remove(m.id); // toggle off
      } else {
        _reactions[m.id] = picked;
      }
    });
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
            icon: const Icon(Icons.videocam_outlined),
            tooltip: 'Video call',
            onPressed: () => _startCall(mode: 'video'),
          ),
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            tooltip: 'Voice call',
            onPressed: () => _startCall(mode: 'voice'),
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
                    reaction: _reactions[m.id],
                    onLongPress: () => _showReactionsSheet(m),
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
          _Composer(
            controller: _textCtrl,
            sending: _sending,
            recording: _recording,
            recordElapsed: _recordElapsed,
            onSendText: _sendText,
            onStartRecord: _startRecording,
            onStopAndSend: _stopRecordingAndSend,
            onCancelRecord: _cancelRecording,
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
    this.reaction,
  });
  final Message message;
  final AudioPlayer player;
  final VoidCallback onLongPress;
  final String? reaction;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isMine = message.isMine;
    final bg = isMine ? cs.primary : cs.surfaceContainerHighest;
    final fg = isMine ? cs.onPrimary : cs.onSurface;
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
          margin: EdgeInsets.only(
            top: 4, bottom: reaction != null ? 14 : 4,
            left: isMine ? 64 : 0,
            right: isMine ? 0 : 64,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  crossAxisAlignment: isMine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMine)
                      Text(
                        message.senderName,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
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
                          Text(
                            '${message.mediaDurationSec ?? 0}s',
                            style: TextStyle(color: fg, fontSize: 12),
                          ),
                        ],
                      ),
                      if (message.transcript != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            message.transcript!,
                            style: TextStyle(color: fg, fontSize: 12),
                          ),
                        ),
                    ] else
                      Text(message.body, style: TextStyle(color: fg)),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          hm(message.sentAt),
                          style: TextStyle(
                            fontSize: 10,
                            color: fg.withValues(alpha: 0.7),
                          ),
                        ),
                        if (isMine) ...[
                          const SizedBox(width: 4),
                          Icon(
                            message.readAt != null
                                ? Icons.done_all
                                : (message.deliveredAt != null
                                    ? Icons.done_all
                                    : Icons.done),
                            size: 12,
                            color: message.readAt != null
                                ? Colors.lightBlueAccent
                                : fg.withValues(alpha: 0.7),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (reaction != null)
                Positioned(
                  bottom: -10,
                  right: isMine ? null : 8,
                  left: isMine ? 8 : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Text(
                      reaction!,
                      style: const TextStyle(fontSize: 14),
                    ),
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
  });
  final TextEditingController controller;
  final bool sending;
  final bool recording;
  final Duration recordElapsed;
  final VoidCallback onSendText;
  final VoidCallback onStartRecord;
  final VoidCallback onStopAndSend;
  final VoidCallback onCancelRecord;

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
              onPressed: () {}, // TODO Phase 1.5: image/file picker
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
