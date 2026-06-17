// SPDX-License-Identifier: AGPL-3.0
//
// LiveRoomScreen — the TV-first conference / townhall surface.
//
// Lean-back design: a multi-participant video grid fills the screen, the
// active speaker is highlighted, and a focusable control bar is driven by
// the TV remote's D-pad (every control is a Focus node with a visible ring).
// Joins as full two-way by default (publishes the TV camera + mic); hosts
// and moderators get a roster with raise-hand queue, mute-all and
// end-for-all.
//
// Self-contained: it mints the LiveKit token (LiveApi) and connects
// (LiveRoomController) itself, so routing only needs the room code + role.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../services/live_api.dart';
import '../../services/livekit_service.dart';

class LiveRoomScreen extends ConsumerStatefulWidget {
  const LiveRoomScreen({
    super.key,
    required this.code,
    this.asHost = false,
    this.role = LiveRole.speaker,
  });

  final String code;
  final bool asHost;
  final LiveRole role;

  @override
  ConsumerState<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends ConsumerState<LiveRoomScreen> {
  final LiveRoomController _ctrl = LiveRoomController();
  bool _starting = true;
  String? _startError;
  bool _showRoster = false;
  String? _pinnedIdentity; // user-pinned participant (screen-share wins over this)
  int _reconnectAttempts = 0;
  bool _reconnectScheduled = false;
  static const int _maxReconnects = 3;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _ctrl.addListener(_onCtrlChanged);
    _start();
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
      final join = await ref.read(liveApiProvider).token(
            code: widget.code,
            asHost: widget.asHost,
            role: widget.role,
          );
      await _ctrl.connect(join);
      if (!mounted) return;
      setState(() {
        _starting = false;
        if (_ctrl.error == null) _reconnectAttempts = 0; // good link → reset budget
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _startError = e is LiveApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _leave() async {
    await _ctrl.leave();
    WakelockPlus.disable();
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _ctrl.removeListener(_onCtrlChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      // onPopInvoked (not ...WithResult) for Flutter >=3.22 compatibility.
      onPopInvoked: (didPop) async {
        if (!didPop) await _leave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (context, _) {
              if (_starting) return _statusView('Connecting…', spinner: true);
              if (_startError != null) {
                return _statusView(_startError!, retry: true);
              }
              if (_ctrl.error != null) {
                return _statusView(_ctrl.error!, retry: true);
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
              // Screen-share takes the stage; otherwise a user-pinned tile.
              final stage = _ctrl.screenShareTile ?? _pinnedTile();
              return Stack(
                children: [
                  Positioned.fill(
                      child: stage != null ? _pinnedLayout(stage) : _grid()),
                  _topBar(),
                  if (_showRoster) _rosterPanel(),
                  _controlBar(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // Cap the on-screen tiles so a 50-person townhall stays legible; the
  // overflow surfaces as a "+N" cell (full list is in the roster panel).
  static const int _maxCells = 12;

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
          return _TileView(tile: shown[i]);
        },
      ),
    );
  }

  // Pinned presentation: the shared screen fills the stage; participant
  // tiles run along a filmstrip beneath it.
  Widget _pinnedLayout(LiveTile share) {
    final others = _ctrl.tiles.take(_maxCells).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 64, 16, 96),
      child: Column(
        children: [
          Expanded(flex: 4, child: _TileView(tile: share)),
          const SizedBox(height: 12),
          SizedBox(
            height: 110,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: others.length,
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (context, i) => AspectRatio(
                aspectRatio: 16 / 10,
                child: _TileView(tile: others[i]),
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
    return Positioned(
      top: 12,
      left: 16,
      right: 16,
      child: Row(
        children: [
          _chip(Icons.groups, '$count'),
          const SizedBox(width: 8),
          _chip(Icons.tv, 'Room ${_ctrl.roomCode}'),
          const Spacer(),
          if (hands > 0) _chip(Icons.front_hand, '$hands', accent: true),
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

  // ── Control bar (D-pad focusable) ──────────────────────────────────
  Widget _controlBar() {
    final canModerate = _ctrl.isHost || _ctrl.role == 'moderator';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: FocusTraversalGroup(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _TvControlButton(
              icon: _ctrl.micOn ? Icons.mic : Icons.mic_off,
              label: _ctrl.micOn ? 'Mute' : 'Unmute',
              danger: !_ctrl.micOn,
              autofocus: true,
              onPressed: _ctrl.toggleMic,
            ),
            _TvControlButton(
              icon: _ctrl.camOn ? Icons.videocam : Icons.videocam_off,
              label: _ctrl.camOn ? 'Camera off' : 'Camera on',
              danger: !_ctrl.camOn,
              onPressed: _ctrl.toggleCamera,
            ),
            _TvControlButton(
              icon: Icons.cameraswitch,
              label: 'Flip',
              onPressed: _ctrl.switchCamera,
            ),
            _TvControlButton(
              icon: _ctrl.handRaised ? Icons.back_hand : Icons.front_hand,
              label: _ctrl.handRaised ? 'Lower' : 'Raise hand',
              accent: _ctrl.handRaised,
              onPressed: () =>
                  _ctrl.handRaised ? _ctrl.lowerHand() : _ctrl.raiseHand(),
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
          ],
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
                        onPressed: () => setState(() => _pinnedIdentity =
                            _pinnedIdentity == t.identity ? null : t.identity),
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
  Widget _statusView(String message, {bool spinner = false, bool retry = false}) {
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
        ],
      ),
    );
  }
}

/// A single video cell. Shows the participant's video, or an avatar
/// placeholder, with a speaking ring + name/mute chips.
class _TileView extends StatelessWidget {
  const _TileView({required this.tile});
  final LiveTile tile;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F25),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: tile.isSpeaking ? cs.primary : Colors.transparent,
            width: 3,
          ),
        ),
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
