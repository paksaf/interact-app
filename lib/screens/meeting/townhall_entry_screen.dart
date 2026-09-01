// SPDX-License-Identifier: AGPL-3.0
//
// TownhallEntryScreen — start or join a multi-party conference / townhall
// or a LiveKit PTT (walkie) channel.
//
// TV-first: the code field autofocuses, role options are large focusable
// cards (D-pad friendly), and "Start / Join" pushes into the LiveKit room.
// Host creates (or revives) the room; Speaker joins two-way; Listener joins
// receive-only (good for large townhalls — they can still raise a hand).
// Walkie mode uses hold-to-speak (mic off until PTT pressed).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/live_api.dart';

class TownhallEntryScreen extends ConsumerStatefulWidget {
  const TownhallEntryScreen({super.key, this.mode = 'meeting'});

  /// `meeting` (default townhall) or `ptt` (walkie / hold-to-speak).
  final String mode;

  @override
  ConsumerState<TownhallEntryScreen> createState() =>
      _TownhallEntryScreenState();
}

class _TownhallEntryScreenState extends ConsumerState<TownhallEntryScreen> {
  late final TextEditingController _codeCtrl;
  bool _asHost = false;
  LiveRole _role = LiveRole.speaker;

  bool get _isPtt => widget.mode == 'ptt';

  @override
  void initState() {
    super.initState();
    if (_isPtt) _role = LiveRole.pttTalker;
    // Prefill so Host → Start works without retyping. Hint-only "TOWN42"
    // looked filled on phones but `_codeCtrl` was empty (snackbar 3+ chars).
    _codeCtrl = TextEditingController(text: _isPtt ? 'WALKIE1' : 'TOWN42');
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  void _start() {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a room code (3+ characters).')),
      );
      return;
    }
    final role = _asHost
        ? (_isPtt ? LiveRole.pttTalker : LiveRole.moderator)
        : _role;
    context.push(
      '/live?code=$code&host=$_asHost&role=${role.wire}&mode=${widget.mode}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isPtt ? 'Walkie channel' : 'Conference / Townhall'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    _isPtt ? Icons.podcasts : Icons.groups_2,
                    size: 56,
                    color: cs.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isPtt ? 'Push-to-talk channel' : 'Join a live room',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isPtt
                        ? 'Hold the talk button to speak. Uses LiveKit SFU '
                            '(same stack as townhall). BLE mesh voice is a later phase.'
                        : 'Enter the room code shared by the host. The same code '
                            'works across every INTERACT app and ExecOS.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.outline),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _codeCtrl,
                    autofocus: true,
                    textCapitalization: TextCapitalization.characters,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 6),
                    inputFormatters: [
                      UpperCaseFormatter(),
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9-]')),
                      LengthLimitingTextInputFormatter(32),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Room code',
                      // Hint only when user clears the prefilled default.
                      hintText: _isPtt ? 'e.g. WALKIE1' : 'e.g. TOWN42',
                      helperText: 'Edit or keep the default code, then Start',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _start(),
                  ),
                  const SizedBox(height: 24),
                  Text('Join as', style: TextStyle(color: cs.outline)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _RoleCard(
                        icon: Icons.star,
                        title: 'Host',
                        subtitle: 'Start the room',
                        selected: _asHost,
                        onTap: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          setState(() {
                            _asHost = true;
                            _role = _isPtt
                                ? LiveRole.pttTalker
                                : LiveRole.moderator;
                          });
                        },
                      ),
                      if (_isPtt)
                        _RoleCard(
                          icon: Icons.mic,
                          title: 'Talker',
                          subtitle: 'Hold to speak',
                          selected: !_asHost && _role == LiveRole.pttTalker,
                          onTap: () {
                            FocusManager.instance.primaryFocus?.unfocus();
                            setState(() {
                              _asHost = false;
                              _role = LiveRole.pttTalker;
                            });
                          },
                        )
                      else ...[
                        _RoleCard(
                          icon: Icons.mic,
                          title: 'Speaker',
                          subtitle: 'Mic first · cam optional',
                          selected: !_asHost && _role == LiveRole.speaker,
                          onTap: () => setState(() {
                            _asHost = false;
                            _role = LiveRole.speaker;
                          }),
                        ),
                        _RoleCard(
                          icon: Icons.hearing,
                          title: 'Listener',
                          subtitle: 'Watch + raise hand',
                          selected: !_asHost && _role == LiveRole.listener,
                          onTap: () => setState(() {
                            _asHost = false;
                            _role = LiveRole.listener;
                          }),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _start,
                    icon: Icon(_asHost ? Icons.play_circle : Icons.login),
                    label: Text(_asHost ? 'Start room' : 'Join room'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  // §14 Phase 1 — the walkie that still works when the site
                  // router has no uplink. Offered up-front rather than only
                  // after a failed join: on a known-dead network the operator
                  // should not have to watch LiveKit time out first.
                  if (_isPtt) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: () => context.push(
                          '/lan-walkie?code=${Uri.encodeComponent(_codeCtrl.text.trim().toUpperCase())}'),
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('No internet? Use nearby Wi-Fi'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Forces typed text to uppercase so the displayed code matches what the
/// server normalises to.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: selected
              ? cs.primaryContainer
              : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              child: Column(
                children: [
                  Icon(icon,
                      color: selected ? cs.onPrimaryContainer : cs.onSurface),
                  const SizedBox(height: 6),
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? cs.onPrimaryContainer
                              : cs.onSurface)),
                  Text(subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11,
                          color: selected
                              ? cs.onPrimaryContainer.withValues(alpha: 0.8)
                              : cs.outline)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
