// SPDX-License-Identifier: AGPL-3.0
//
// LiveRoomScreen — the TV-first conference / townhall surface.
//
// Lean-back design: a multi-participant video grid fills the screen, the
// active speaker is highlighted, and a focusable control bar is driven by
// the TV remote's D-pad (every control is a Focus node with a visible ring).
// Joins voice-first by default (mic on, camera off — enable cam in-call);
// hosts and moderators get a roster with raise-hand queue, mute-all and
// end-for-all.
//
// Self-contained: it mints the LiveKit token (LiveApi) and connects
// (LiveRoomController) itself, so routing only needs the room code + role.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../l10n/app_localizations.dart';
import '../../models/guest_join.dart';
import '../../services/camera_effects.dart';
import '../../services/live_api.dart';
import '../../services/live_room_presence_service.dart';
import '../../services/livekit_service.dart';
import '../../services/talk_api.dart';
import '../../widgets/in_call_busy_banner.dart';
import '../../widgets/meeting/guest_join_host_sheet.dart';
import '../../widgets/meeting/guest_waiting_room_panel.dart';

class LiveRoomScreen extends ConsumerStatefulWidget {
  const LiveRoomScreen({
    super.key,
    required this.code,
    this.asHost = false,
    this.role = LiveRole.speaker,
    this.mode = 'meeting',
  });

  final String code;
  final bool asHost;
  final LiveRole role;

  /// `meeting` or `ptt` (walkie hold-to-speak).
  final String mode;

  @override
  ConsumerState<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends ConsumerState<LiveRoomScreen>
    with WidgetsBindingObserver {
  final LiveRoomController _ctrl = LiveRoomController();
  bool _starting = true;
  String? _startError;
  bool _showRoster = false;
  String? _pinnedIdentity; // user-pinned participant (screen-share wins over this)
  /// When true and nothing is manually pinned, stage follows the loudest speaker.
  bool _followActiveSpeaker = false;
  bool _pttHolding = false;
  int _reconnectAttempts = 0;
  bool _reconnectScheduled = false;
  static const int _maxReconnects = 3;
  late final TalkApi _talkApi;
  String? _callLogId;
  DateTime? _callStartedAt;
  LiveRoomPresenceService? _presence;
  LiveRoomAnalytics _analytics = LiveRoomAnalytics.empty;
  StreamSubscription<LiveRoomAnalytics>? _analyticsSub;
  GuestPolicyState _guestPolicy = GuestPolicyState.off;
  List<GuestJoinRequest> _guestWaiting = const [];
  Timer? _guestPollTimer;
  bool _guestDeciding = false;

  bool get _isPtt => widget.mode == 'ptt';

  bool get _canManageGuests =>
      _ctrl.isHost || _ctrl.role == 'moderator' || _ctrl.role == 'host';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _talkApi = ref.read(talkApiProvider);
    WakelockPlus.enable();
    _ctrl.addListener(_onCtrlChanged);
    _start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    _presence?.updateFocus(state);
    unawaited(_ctrl.publishAppFocus(foreground));
  }

  /// Auto-reconnect (re-mints a fresh token via _start) with linear backoff
  /// on an unexpected drop, up to [_maxReconnects] before falling back to a
  /// manual button.
  void _onCtrlChanged() {
    if (_ctrl.dropped &&
        !_starting &&
        !_reconnectScheduled &&
        _reconnectAttempts < _maxReconnects) {
      _reconnectScheduled = true;
      final delay = Duration(seconds: 2 * (_reconnectAttempts + 1));
      Future.delayed(delay, () async {
        if (!mounted) return;
        _reconnectScheduled = false;
        _reconnectAttempts++;
        await _start();
      });
    }
  }

  void _retry() {
    _reconnectAttempts = 0; // manual retry → fresh auto-reconnect budget
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final join = (await ref.read(liveApiProvider).token(
            code: widget.code,
            asHost: widget.asHost,
            role: widget.role,
            mode: widget.mode,
          ))
          .copyWith(holdToSpeak: _isPtt, voiceFirst: !_isPtt);
      _callLogId = join.callLogId;
      _callStartedAt = DateTime.now();
      // Seed virtual BG before connect so camera publish picks it up.
      final effect = ref.read(cameraEffectProvider);
      await _ctrl.applyCameraEffect(effect);
      await _ctrl.connect(join);
      if (!mounted) return;
      final canPoll = join.isHost || join.role == 'moderator';
      _presence = ref.read(liveRoomPresenceServiceProvider);
      await _presence!.start(
        roomCode: join.roomCode,
        role: join.role,
        pollAnalytics: canPoll,
      );
      await _analyticsSub?.cancel();
      _analyticsSub = _presence!.analyticsStream?.listen((a) {
        if (mounted) setState(() => _analytics = a);
      });
      // Re-bind after track exists (connect also re-applies if non-none).
      if (effect != CameraEffect.none) {
        await _ctrl.applyCameraEffect(effect);
      }
      setState(() {
        _starting = false;
        if (_ctrl.error == null) _reconnectAttempts = 0; // good link → reset budget
      });
      if (canPoll) {
        unawaited(_loadGuestPolicy());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = e is LiveApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _leave() async {
    _guestPollTimer?.cancel();
    _guestPollTimer = null;
    await _analyticsSub?.cancel();
    _analyticsSub = null;
    await _presence?.stop();
    _presence = null;
    final logId = _callLogId;
    _callLogId = null;
    if (logId != null && logId.isNotEmpty) {
      final started = _callStartedAt;
      final secs = started == null
          ? null
          : DateTime.now().difference(started).inSeconds.clamp(0, 86400).toInt();
      unawaited(
        _talkApi
            .closeCallLog(logId, reason: 'ended', durationSecs: secs)
            .catchError((_) {}),
      );
    }
    await _ctrl.leave();
    WakelockPlus.disable();
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _guestPollTimer?.cancel();
    unawaited(_analyticsSub?.cancel());
    unawaited(_presence?.stop());
    WakelockPlus.disable();
    _ctrl.removeListener(_onCtrlChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) await _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            children: [
              AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              if (_starting) return _statusView('Connecting…', spinner: true);
              if (_startError != null) {
                return _statusView(_startError!,
                    retry: true, showLanWalkie: _isPtt);
              }
              if (_ctrl.error != null) {
                return _statusView(_ctrl.error!,
                    retry: true, showLanWalkie: _isPtt);
              }
              if (_ctrl.dropped) {
                final auto = _reconnectAttempts < _maxReconnects;
                return _statusView(
                  auto
                      ? 'Connection lost — reconnecting…'
                      : 'Disconnected from the room.',
                  spinner: auto,
                  retry: !auto,
                );
              }
              // Screen-share > manual pin > active-speaker follow (Wave 2).
              final stage = _ctrl.screenShareTile ??
                  (_pinnedIdentity != null
                      ? _pinnedTile()
                      : (_followActiveSpeaker ? _activeSpeakerTile() : null));
              return Stack(
                children: [
                  Positioned.fill(
                      child: stage != null ? _speakerLayout(stage) : _grid()),
                  _topBar(),
                  if (_showRoster) _rosterPanel(),
                  if (_ctrl.captionText.isNotEmpty) _captionOverlay(),
                  if (_ctrl.flashEmoji != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Center(
                          child: Text(
                            _ctrl.flashEmoji!,
                            style: const TextStyle(fontSize: 110),
                          ),
                        ),
                      ),
                    ),
                  if (_isPtt) _pttHoldPad(),
                  if (_canManageGuests &&
                      _guestPolicy.policy == GuestAdmissionPolicy.admit)
                    GuestWaitingRoomPanel(
                      waiting: _guestWaiting,
                      busy: _guestDeciding,
                      onAdmit: (r) => _decideGuest(r, 'admit'),
                      onDeny: (r) => _decideGuest(r, 'deny'),
                    ),
                  _controlBar(),
                ],
              );
            },
          ),
              const InCallBusyBanner(),
            ],
          ),
        ),
      ),
    );
  }

  // Cap the on-screen tiles so a 50-person townhall stays legible; the
  // overflow surfaces as a "+N" cell (full list is in the roster panel).
  static const int _maxCells = 12;

  // ── Live captions overlay (fed by the caption-agent) ───────────────
  Widget _captionOverlay() {
    final speaker = _ctrl.captionSpeaker;
    final text = _ctrl.captionText;
    final isFinal = _ctrl.captionIsFinal;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 104,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: isFinal ? 0.75 : 0.55),
              borderRadius: BorderRadius.circular(12),
              border: isFinal
                  ? null
                  : Border.all(color: Colors.white24, width: 1),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (speaker.isNotEmpty)
                  Text(
                    speaker,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: isFinal ? 1 : 0.85),
                    fontSize: 16,
                    height: 1.3,
                    fontStyle: isFinal ? FontStyle.normal : FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _captionLanguage = 'multi';

  static const _captionLangChoices = <(String code, String label)>[
    ('multi', 'Auto (multilingual)'),
    ('en', 'English'),
    ('ar', 'العربية Arabic'),
    ('ur', 'اردو Urdu'),
    ('tr', 'Türkçe Turkish'),
    ('ru', 'Русский Russian'),
    ('es', 'Español Spanish'),
  ];

  /// Toggle captions: flip local state + tell the backend to start/stop the agent.
  Future<void> _toggleCaptions() async {
    final turnOn = !_ctrl.captionsOn;
    if (turnOn) {
      final health = await ref.read(liveApiProvider).captionsHealth();
      if (!mounted) return;
      // Older QS deploys 404 the health probe — skip hard-block and let POST
      // decide (admin role / agent). Only hard-block on an explicit unhealthy
      // agent response.
      if (!health.unknown && (!health.agentOk || !health.configured)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Captions unavailable — caption-agent / Deepgram keys required.',
            ),
          ),
        );
        return;
      }
      final lang = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: Text(
                  'Caption language',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Speak in that language for best accuracy. Auto uses Deepgram multilingual.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
              for (final (code, label) in _captionLangChoices)
                ListTile(
                  title: Text(label),
                  trailing: code == _captionLanguage
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(ctx, code),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (!mounted || lang == null) return;
      _captionLanguage = lang;
    }
    _ctrl.setCaptionsOn(turnOn);
    try {
      final okDone = await ref.read(liveApiProvider).toggleCaptions(
            _ctrl.roomName,
            turnOn,
            language: _captionLanguage,
          );
      if (!okDone && mounted) {
        _ctrl.setCaptionsOn(false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context).captionsUnavailable)),
        );
      } else if (turnOn && mounted) {
        final label = _captionLangChoices
            .firstWhere((e) => e.$1 == _captionLanguage,
                orElse: () => (_captionLanguage, _captionLanguage))
            .$2;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Captions on · $label')),
        );
      }
    } on LiveApiException catch (e) {
      if (!mounted) return;
      _ctrl.setCaptionsOn(false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (_) {
      if (!mounted) return;
      _ctrl.setCaptionsOn(false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(AppLocalizations.of(context).captionsUnavailable)),
      );
    }
  }

  // ── Video grid ─────────────────────────────────────────────────────
  Widget _grid() {
    final tiles = _ctrl.tiles;
    if (tiles.isEmpty) {
      return _statusView('Waiting for participants…');
    }
    final overflow = tiles.length - _maxCells;
    final shown = overflow > 0 ? tiles.sublist(0, _maxCells - 1) : tiles;
    final cellCount = shown.length + (overflow > 0 ? 1 : 0);
    final cols = _columnsFor(cellCount);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 64, 16, 96),
      child: GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: 16 / 10,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: cellCount,
        itemBuilder: (context, i) {
          if (overflow > 0 && i == cellCount - 1) {
            return _overflowCell(overflow + 1);
          }
          return _TileView(
            tile: shown[i],
            onPin: () => _pinIdentity(shown[i].identity),
          );
        },
      ),
    );
  }

  // Speaker / presentation: stage fills ~70%; others in a filmstrip
  // (RoomShell-style). Filmstrip omits the staged camera; screen-share
  // keeps every camera tile.
  Widget _speakerLayout(LiveTile stage) {
    final screen = _ctrl.screenShareTile;
    final stagingScreen = screen != null &&
        identical(stage.videoTrack, screen.videoTrack);
    final others = _ctrl.tiles
        .where((t) => stagingScreen || t.identity != stage.identity)
        .take(_maxCells)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 64, 16, 96),
      child: Column(
        children: [
          Expanded(
            flex: 4,
            child: _TileView(
              tile: stage,
              onPin: stagingScreen
                  ? null
                  : () => _pinIdentity(stage.identity),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: others.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) => AspectRatio(
                aspectRatio: 16 / 10,
                child: _TileView(
                  tile: others[i],
                  onPin: () => _pinIdentity(others[i].identity),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overflowCell(int n) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F25),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(
        child: Text('+$n more',
            style: const TextStyle(color: Colors.white70, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
    );
  }

  int _columnsFor(int n) {
    if (n <= 1) return 1;
    if (n <= 4) return 2;
    if (n <= 9) return 3;
    return 4;
  }

  /// The user-pinned tile, or null (also null if that participant has left).
  LiveTile? _pinnedTile() {
    final id = _pinnedIdentity;
    if (id == null) return null;
    for (final t in _ctrl.tiles) {
      if (t.identity == id) return t;
    }
    return null;
  }

  /// Loudest remote speaker, else first remote, else local — for speaker view.
  LiveTile? _activeSpeakerTile() {
    LiveTile? speaking;
    LiveTile? firstRemote;
    LiveTile? local;
    for (final t in _ctrl.tiles) {
      if (t.isLocal) {
        local ??= t;
        continue;
      }
      firstRemote ??= t;
      if (t.isSpeaking) speaking ??= t;
    }
    return speaking ?? firstRemote ?? local;
  }

  void _pinIdentity(String identity) {
    setState(() {
      if (_pinnedIdentity == identity) {
        _pinnedIdentity = null;
        _followActiveSpeaker = false;
      } else {
        _pinnedIdentity = identity;
        _followActiveSpeaker = false;
      }
    });
  }

  /// Gallery ↔ speaker (RoomShell switchLayout). Speaker mode follows the
  /// active speaker until the user pins someone or returns to gallery.
  void _toggleSpeakerLayout() {
    setState(() {
      if (_pinnedIdentity != null || _followActiveSpeaker) {
        _pinnedIdentity = null;
        _followActiveSpeaker = false;
        return;
      }
      _followActiveSpeaker = true;
      _pinnedIdentity = null;
    });
  }

  bool get _inSpeakerLayout =>
      _ctrl.screenShareTile != null ||
      _pinnedIdentity != null ||
      _followActiveSpeaker;

  void _showReactionPicker() {
    const emojis = ['👍', '❤️', '😂', '🎉', '👏', '🔥', '😮', '🙏'];
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              for (final e in emojis)
                InkWell(
                  onTap: () {
                    _ctrl.sendReaction(e);
                    Navigator.pop(ctx);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(e, style: const TextStyle(fontSize: 32)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Guest join (host) ──────────────────────────────────────────────
  Future<void> _loadGuestPolicy() async {
    if (!_canManageGuests || !_ctrl.connected) return;
    final code = _ctrl.roomCode;
    if (code.isEmpty) return;
    final policy = await ref.read(liveApiProvider).getGuestPolicy(code);
    if (!mounted || policy == null) return;
    setState(() => _guestPolicy = policy);
    _syncGuestPolling();
  }

  void _syncGuestPolling() {
    _guestPollTimer?.cancel();
    if (!_canManageGuests ||
        !_ctrl.connected ||
        _guestPolicy.policy != GuestAdmissionPolicy.admit) {
      if (mounted && _guestWaiting.isNotEmpty) {
        setState(() => _guestWaiting = const []);
      }
      return;
    }
    unawaited(_pollGuestWaiting());
    _guestPollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_pollGuestWaiting()),
    );
  }

  Future<void> _pollGuestWaiting() async {
    if (!_canManageGuests ||
        _guestPolicy.policy != GuestAdmissionPolicy.admit) {
      return;
    }
    final code = _ctrl.roomCode;
    if (code.isEmpty) return;
    final list = await ref.read(liveApiProvider).getGuestRequests(code);
    if (!mounted) return;
    setState(() => _guestWaiting = list);
  }

  void _onGuestPolicyUpdated(GuestPolicyState updated) {
    setState(() => _guestPolicy = updated);
    _syncGuestPolling();
  }

  Future<void> _openGuestJoinSheet() async {
    await showGuestJoinHostSheet(
      context,
      roomCode: _ctrl.roomCode,
      initial: _guestPolicy,
      onUpdated: _onGuestPolicyUpdated,
    );
  }

  Future<void> _decideGuest(GuestJoinRequest request, String decision) async {
    if (_guestDeciding) return;
    setState(() => _guestDeciding = true);
    final ok = await ref.read(liveApiProvider).decideGuestRequest(
          requestId: request.id,
          decision: decision,
        );
    if (!mounted) return;
    setState(() => _guestDeciding = false);
    if (ok) {
      unawaited(_pollGuestWaiting());
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update guest — try again')),
      );
    }
  }

  // ── Moderation (host/moderator) ────────────────────────────────────
  Future<void> _moderate(String identity, String action) async {
    if (action == 'remove') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Remove participant?'),
          content: const Text('They will be disconnected from the room.'),
          actions: [
            TextButton(onPressed: () => ctx.pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: () => ctx.pop(true), child: const Text('Remove')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await ref.read(liveApiProvider).moderate(
            code: _ctrl.roomCode,
            targetIdentity: identity,
            action: action,
          );
      // For promote/demote the SFU grant is now changed; tell the target to
      // start/stop publishing.
      if (action == 'promote' || action == 'demote') {
        await _ctrl.broadcastRole(identity, action == 'promote');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(switch (action) {
          'remove' => 'Removed',
          'promote' => 'Promoted to speaker',
          'demote' => 'Moved to listener',
          _ => 'Muted',
        })),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is LiveApiException ? e.message : '$e')),
      );
    }
  }

  // ── Top bar ────────────────────────────────────────────────────────
  Widget _topBar() {
    final count = _ctrl.tiles.length;
    final hands = _ctrl.raisedHandCount;
    final canSeeAnalytics = _ctrl.isHost || _ctrl.role == 'moderator';
    final sfuBackground = _ctrl.tiles
        .where((t) => t.focus == 'background' && !t.isLocal)
        .length;
    return Positioned(
      top: 12,
      left: 16,
      right: 16,
      child: Row(
        children: [
          _chip(Icons.groups, count == 1 ? 'Just you' : '$count in call'),
          if (canSeeAnalytics && _analytics.concurrentNow > 0) ...[
            const SizedBox(width: 8),
            _chip(
              Icons.visibility,
              '${_analytics.concurrentNow} watching',
              accent: true,
            ),
          ],
          if (canSeeAnalytics &&
              (_analytics.foregroundCount > 0 ||
                  _analytics.backgroundCount > 0)) ...[
            const SizedBox(width: 8),
            _chip(
              Icons.center_focus_strong,
              '${_analytics.foregroundCount} focused',
            ),
            const SizedBox(width: 8),
            _chip(
              Icons.visibility_off,
              '${_analytics.backgroundCount} unfocused',
            ),
          ] else if (sfuBackground > 0) ...[
            const SizedBox(width: 8),
            _chip(Icons.visibility_off, '$sfuBackground bg (SFU)'),
          ],
          const SizedBox(width: 8),
          _chip(Icons.tv, 'Room ${_ctrl.roomCode}'),
          if (_inSpeakerLayout && _ctrl.screenShareTile == null) ...[
            const SizedBox(width: 8),
            _chip(
              Icons.present_to_all,
              _pinnedIdentity != null ? 'Pinned' : 'Speaker',
              accent: true,
            ),
          ],
          const Spacer(),
          if (_canManageGuests && _guestWaiting.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(
                Icons.meeting_room,
                '${_guestWaiting.length} waiting',
                accent: true,
              ),
            ),
          if (_canManageGuests && _guestPolicy.guestsEnabled)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(
                Icons.person_add_alt_1,
                switch (_guestPolicy.policy) {
                  GuestAdmissionPolicy.passcode => 'Guests · passcode',
                  GuestAdmissionPolicy.admit => 'Guests · waiting room',
                  GuestAdmissionPolicy.off => 'Guests',
                },
                accent: true,
              ),
            ),
          if (hands > 0)
            _chip(Icons.front_hand, '$hands raised', accent: true),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, {bool accent = false}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: accent ? cs.tertiary : Colors.black54,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  /// Walkie hold-to-speak pad (PTT mode). Mic stays off until pressed.
  Widget _pttHoldPad() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: Center(
        child: Listener(
          onPointerDown: (_) async {
            setState(() => _pttHolding = true);
            await _ctrl.setMicEnabled(true);
          },
          onPointerUp: (_) async {
            setState(() => _pttHolding = false);
            await _ctrl.setMicEnabled(false);
          },
          onPointerCancel: (_) async {
            setState(() => _pttHolding = false);
            await _ctrl.setMicEnabled(false);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _pttHolding
                  ? Colors.green.shade600
                  : Colors.white.withValues(alpha: 0.18),
              border: Border.all(
                color: _pttHolding ? Colors.greenAccent : Colors.white54,
                width: 3,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _pttHolding ? Icons.mic : Icons.mic_none,
                  color: Colors.white,
                  size: 40,
                ),
                const SizedBox(height: 4),
                Text(
                  _pttHolding ? 'Speaking' : 'Hold to talk',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Control bar (D-pad focusable; horizontally scrollable on phones) ─
  Widget _controlBar() {
    final canModerate = _ctrl.isHost || _ctrl.role == 'moderator';
    final buttons = <Widget>[
      if (!_isPtt)
        _TvControlButton(
          icon: _ctrl.micOn ? Icons.mic : Icons.mic_off,
          label: _ctrl.micOn ? 'Mute' : 'Unmute',
          danger: !_ctrl.micOn,
          autofocus: true,
          onPressed: _ctrl.toggleMic,
        ),
      // Captions early in the row so SM-A235F / narrow phones can reach it
      // without scrolling past share/people (admin start gate on QS).
      if (!_isPtt)
        _TvControlButton(
          icon: _ctrl.captionsOn
              ? Icons.closed_caption
              : Icons.closed_caption_off,
          label: 'Captions',
          accent: _ctrl.captionsOn,
          onPressed: _toggleCaptions,
        ),
      if (!_isPtt)
        _TvControlButton(
          icon: _ctrl.camOn ? Icons.videocam : Icons.videocam_off,
          label: _ctrl.camOn ? 'Camera off' : 'Camera on',
          danger: !_ctrl.camOn,
          onPressed: _ctrl.toggleCamera,
        ),
      if (!_isPtt) ...[
        _TvControlButton(
          icon: Icons.cameraswitch,
          label: 'Flip',
          onPressed: _ctrl.switchCamera,
        ),
        _TvControlButton(
          icon: _inSpeakerLayout ? Icons.grid_view : Icons.present_to_all,
          label: _inSpeakerLayout ? 'Exit speaker' : 'Speaker view',
          accent: _inSpeakerLayout && _ctrl.screenShareTile == null,
          onPressed: _toggleSpeakerLayout,
        ),
        _TvControlButton(
          icon: Icons.blur_on,
          label: 'BG',
          accent: ref.watch(cameraEffectProvider) != CameraEffect.none,
          onPressed: () async {
            await context.push('/camera-effects');
            if (!mounted) return;
            final effect = ref.read(cameraEffectProvider);
            if (effect != CameraEffect.none && !_ctrl.camOn) {
              await _ctrl.toggleCamera();
            }
            await _ctrl.applyCameraEffect(effect);
            setState(() {});
          },
        ),
        _TvControlButton(
          icon: _ctrl.screenSharing
              ? Icons.stop_screen_share
              : Icons.screen_share,
          label: _ctrl.screenSharing ? 'Stop share' : 'Share',
          accent: _ctrl.screenSharing,
          onPressed: _ctrl.toggleScreenShare,
        ),
        _TvControlButton(
          icon: _ctrl.handRaised ? Icons.back_hand : Icons.front_hand,
          label: _ctrl.handRaised ? 'Lower' : 'Raise hand',
          accent: _ctrl.handRaised,
          onPressed: () =>
              _ctrl.handRaised ? _ctrl.lowerHand() : _ctrl.raiseHand(),
        ),
        _TvControlButton(
          icon: Icons.emoji_emotions_outlined,
          label: 'React',
          onPressed: _showReactionPicker,
        ),
      ],
      if (canModerate)
        _TvControlButton(
          icon: Icons.person_add_alt_1,
          label: _guestWaiting.isNotEmpty
              ? 'Guests (${_guestWaiting.length})'
              : 'Guests',
          accent: _guestPolicy.guestsEnabled,
          onPressed: _openGuestJoinSheet,
        ),
      // Audio-route picker — deliberately OUTSIDE the !_isPtt guard so the
      // WALKIE screen has it too (operator report 2026-08-27: walkie had no
      // way to route to a Bluetooth speaker/headset).
      _TvControlButton(
        icon: Icons.volume_up,
        label: 'Audio',
        onPressed: _showAudioRouteSheet,
      ),
      _TvControlButton(
        icon: Icons.people,
        label: 'People',
        onPressed: () => setState(() => _showRoster = !_showRoster),
      ),
      if (canModerate)
        _TvControlButton(
          icon: Icons.mic_off,
          label: 'Mute all',
          onPressed: _ctrl.muteAll,
        ),
      _TvControlButton(
        icon: Icons.call_end,
        label: canModerate ? 'End' : 'Leave',
        danger: true,
        onPressed: canModerate ? _endOrLeave : _leave,
      ),
    ];
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: FocusTraversalGroup(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: buttons,
          ),
        ),
      ),
    );
  }

  /// Audio output routing (speaker / earpiece / Bluetooth / AirPlay) —
  /// same picker as the 1:1 meeting screen, and deliberately the same
  /// mechanism: flutter_webrtc's Helper. (LiveKit's own
  /// Hardware.selectAudioOutput is DESKTOP-ONLY — on phones it logs a
  /// warning and does nothing; verified in v2.8.1 hardware.dart. Only the
  /// speakerphone toggle goes through Hardware, which handles the iOS
  /// audio-session config correctly for LiveKit-managed tracks.)
  Future<void> _showAudioRouteSheet() async {
    List<rtc.MediaDeviceInfo> outputs = const [];
    try {
      outputs = await rtc.Helper.audiooutputs;
    } catch (e) {
      debugPrint('[live] enumerate audio outputs failed: $e');
    }
    if (!mounted) return;
    bool speaker = Hardware.instance.speakerOn ?? true;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF14343F),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('Audio output',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
              ),
              SwitchListTile(
                value: speaker,
                onChanged: (v) async {
                  setSheet(() => speaker = v);
                  try {
                    await Hardware.instance.setSpeakerphoneOn(v);
                  } catch (e) {
                    debugPrint('[live] speakerphone toggle failed: $e');
                  }
                },
                title: const Text('Loudspeaker',
                    style: TextStyle(color: Colors.white)),
                secondary:
                    const Icon(Icons.speaker_phone, color: Colors.white70),
              ),
              for (final d in outputs)
                ListTile(
                  leading: Icon(
                    d.label.toLowerCase().contains('bluetooth') ||
                            d.label.toLowerCase().contains('airpods')
                        ? Icons.bluetooth_audio
                        : d.label.toLowerCase().contains('speaker')
                            ? Icons.speaker
                            : Icons.headset,
                    color: Colors.white70,
                  ),
                  title: Text(d.label.isEmpty ? d.deviceId : d.label,
                      style: const TextStyle(color: Colors.white)),
                  onTap: () async {
                    try {
                      await rtc.Helper.selectAudioOutput(d.deviceId);
                    } catch (e) {
                      debugPrint('[live] selectAudioOutput failed: $e');
                    }
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _endOrLeave() async {
    final end = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End session?'),
        content: const Text('End for everyone, or just leave yourself?'),
        actions: [
          TextButton(onPressed: () => ctx.pop(false), child: const Text('Just leave')),
          FilledButton(onPressed: () => ctx.pop(true), child: const Text('End for all')),
        ],
      ),
    );
    if (end == true) {
      await _ctrl.endForAll();
      WakelockPlus.disable();
      if (mounted) context.pop();
    } else {
      await _leave();
    }
  }

  // ── Roster panel ───────────────────────────────────────────────────
  Widget _rosterPanel() {
    final tiles = _ctrl.tiles;
    final canModerate = _ctrl.isHost || _ctrl.role == 'moderator';
    final canSeeAnalytics = canModerate;
    return Positioned(
      top: 56,
      right: 16,
      bottom: 96,
      width: 320,
      child: Material(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canSeeAnalytics) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Audience',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Watching: ${_analytics.concurrentNow} · Peak: ${_analytics.peakConcurrent}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      'Focused: ${_analytics.foregroundCount} · Unfocused: ${_analytics.backgroundCount}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Divider(height: 16, color: Colors.white24),
            ],
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Participants',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: ListView.builder(
                itemCount: tiles.length,
                itemBuilder: (context, i) {
                  final t = tiles[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      backgroundColor: t.isSpeaking ? Colors.green : Colors.white24,
                      child: Text(
                        t.label.isNotEmpty ? t.label[0].toUpperCase() : '?',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    title: Text(t.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white)),
                    // Who-joined info (host request 2026-08-27): role +
                    // device-reported coarse area ("Pakistan · PKT (UTC+5)").
                    // Peers on older builds show role only.
                    subtitle: (t.role != null || t.area != null || t.focus != null)
                        ? Text(
                            [
                              if (t.role != null && t.role!.isNotEmpty) t.role!,
                              if (t.area != null && t.area!.isNotEmpty) t.area!,
                              if (t.focus == 'background') 'unfocused',
                              if (t.focus == 'foreground') 'focused',
                            ].join(' — '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                          )
                        : null,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        tooltip: _pinnedIdentity == t.identity ? 'Unpin' : 'Pin',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _pinnedIdentity == t.identity
                              ? Icons.push_pin
                              : Icons.push_pin_outlined,
                          color: _pinnedIdentity == t.identity
                              ? Theme.of(context).colorScheme.primary
                              : Colors.white54,
                          size: 18,
                        ),
                        onPressed: () => _pinIdentity(t.identity),
                      ),
                      if (t.handRaised)
                        const Icon(Icons.front_hand, color: Colors.amber, size: 18),
                      const SizedBox(width: 8),
                      Icon(t.audioMuted ? Icons.mic_off : Icons.mic,
                          color: t.audioMuted ? Colors.red : Colors.white70, size: 18),
                      if (canModerate && !t.isLocal) ...[
                        if (t.handRaised)
                          IconButton(
                            tooltip: 'Promote to speaker',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.record_voice_over,
                                color: Colors.greenAccent, size: 18),
                            onPressed: () => _moderate(t.identity, 'promote'),
                          ),
                        IconButton(
                          tooltip: 'Mute',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.volume_off, color: Colors.white70, size: 18),
                          onPressed: () => _moderate(t.identity, 'mute'),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.person_remove, color: Colors.redAccent, size: 18),
                          onPressed: () => _moderate(t.identity, 'remove'),
                        ),
                      ],
                    ]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Status (connecting / error / empty) ────────────────────────────
  Widget _statusView(String message,
      {bool spinner = false, bool retry = false, bool showLanWalkie = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (spinner) ...[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 16)),
          ),
          if (retry) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              autofocus: true,
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _leave, child: const Text('Leave')),
          ],
          // §22 — the online (LiveKit) walkie needs the cloud to mint a token,
          // so with no internet it dies here. Offer the offline LAN walkie
          // (docs/…§18) as a one-tap escape rather than making a field user
          // back out and hunt for the other entry.
          if (showLanWalkie) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => context.push(
                  '/lan-walkie?code=${Uri.encodeComponent(widget.code)}'),
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('No internet? Use nearby Wi‑Fi'),
            ),
          ],
        ],
      ),
    );
  }
}

/// A single video cell. Speaking participants get a pulsed ring (RoomShell
/// active-speaker cue). Optional [onPin] toggles speaker-stage pin on tap.
class _TileView extends StatefulWidget {
  const _TileView({required this.tile, this.onPin});
  final LiveTile tile;
  final VoidCallback? onPin;

  @override
  State<_TileView> createState() => _TileViewState();
}

class _TileViewState extends State<_TileView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncPulse(widget.tile.isSpeaking);
  }

  @override
  void didUpdateWidget(covariant _TileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tile.isSpeaking != widget.tile.isSpeaking) {
      _syncPulse(widget.tile.isSpeaking);
    }
  }

  void _syncPulse(bool speaking) {
    if (speaking) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tile = widget.tile;
    return GestureDetector(
      onTap: widget.onPin,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          final glow = tile.isSpeaking ? 0.35 + 0.65 * _pulse.value : 0.0;
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1A1F25),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: tile.isSpeaking
                      ? cs.primary.withValues(alpha: 0.55 + 0.45 * glow)
                      : Colors.transparent,
                  width: tile.isSpeaking ? 3 + glow : 3,
                ),
                boxShadow: tile.isSpeaking
                    ? [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: 0.35 * glow),
                          blurRadius: 12 * glow,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: child,
            ),
          );
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (tile.hasVideo)
              VideoTrackRenderer(tile.videoTrack!)
            else
              Center(
                child: CircleAvatar(
                  radius: 36,
                  backgroundColor: Colors.white12,
                  child: Text(
                    tile.label.isNotEmpty ? tile.label[0].toUpperCase() : '?',
                    style: const TextStyle(color: Colors.white, fontSize: 28),
                  ),
                ),
              ),
            if (tile.handRaised)
              const Positioned(
                top: 8,
                left: 8,
                child: Icon(Icons.front_hand, color: Colors.amber, size: 22),
              ),
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Row(
                children: [
                  Icon(tile.audioMuted ? Icons.mic_off : Icons.mic,
                      size: 16,
                      color: tile.audioMuted ? Colors.red : Colors.white),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tile.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        shadows: [Shadow(blurRadius: 4, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Large, focus-highlighted control for D-pad navigation. The focused
/// button grows + shows a bright ring so it's obvious on a TV from across
/// the room.
class _TvControlButton extends StatefulWidget {
  const _TvControlButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
    this.accent = false,
    this.autofocus = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool danger;
  final bool accent;
  final bool autofocus;

  @override
  State<_TvControlButton> createState() => _TvControlButtonState();
}

class _TvControlButtonState extends State<_TvControlButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final base = widget.danger
        ? Colors.red
        : widget.accent
            ? cs.tertiary
            : Colors.black54;
    // FocusableActionDetector wires the D-pad SELECT / Enter / Space keys to
    // ActivateIntent (WidgetsApp's default activation shortcuts include
    // LogicalKeyboardKey.select + gameButtonA), so the TV remote can trigger
    // the control — a plain GestureDetector would only respond to taps.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FocusableActionDetector(
            autofocus: widget.autofocus,
            onShowFocusHighlight: (f) => setState(() => _focused = f),
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onPressed();
                  return null;
                },
              ),
            },
            child: GestureDetector(
              onTap: widget.onPressed,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: _focused ? 72 : 60,
                height: _focused ? 72 : 60,
                decoration: BoxDecoration(
                  color: base,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _focused ? cs.primary : Colors.transparent,
                    width: 4,
                  ),
                ),
                child: Icon(widget.icon,
                    color: Colors.white, size: _focused ? 32 : 26),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(widget.label,
              style: TextStyle(
                color: _focused ? Colors.white : Colors.white60,
                fontSize: 12,
              )),
        ],
      ),
    );
  }
}
