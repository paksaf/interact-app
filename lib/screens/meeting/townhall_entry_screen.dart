// SPDX-License-Identifier: AGPL-3.0
//
// TownhallEntryScreen — start or join a multi-party conference / townhall.
//
// TV-first: the code field autofocuses, role options are large focusable
// cards (D-pad friendly), and "Start / Join" pushes into the LiveKit room.
// Host creates (or revives) the room; Speaker joins two-way; Listener joins
// receive-only (good for large townhalls — they can still raise a hand).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/live_api.dart';

class TownhallEntryScreen extends ConsumerStatefulWidget {
  const TownhallEntryScreen({super.key});

  @override
  ConsumerState<TownhallEntryScreen> createState() =>
      _TownhallEntryScreenState();
}

class _TownhallEntryScreenState extends ConsumerState<TownhallEntryScreen> {
  final _codeCtrl = TextEditingController();
  bool _asHost = false;
  LiveRole _role = LiveRole.speaker;

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
    context.push(
      '/live?code=$code&host=$_asHost&role=${_role.wire}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Conference / Townhall')),
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
                  Icon(Icons.groups_2, size: 56, color: cs.primary),
                  const SizedBox(height: 12),
                  Text(
                    'Join a live room',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Enter the room code shared by the host. The same code '
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
                        fontSize: 26, fontWeight: FontWeight.bold, letterSpacing: 6),
                    inputFormatters: [
                      UpperCaseFormatter(),
                      FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9-]')),
                      LengthLimitingTextInputFormatter(32),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Room code',
                      hintText: 'TOWN42',
                      border: OutlineInputBorder(),
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
                        onTap: () => setState(() {
                          _asHost = true;
                          _role = LiveRole.moderator;
                        }),
                      ),
                      _RoleCard(
                        icon: Icons.videocam,
                        title: 'Speaker',
                        subtitle: 'Camera + mic',
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
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            decoration: BoxDecoration(
              color: selected ? cs.primaryContainer : cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? cs.primary : cs.outlineVariant,
                width: selected ? 2 : 0.5,
              ),
            ),
            child: Column(
              children: [
                Icon(icon,
                    color: selected ? cs.primary : cs.onSurfaceVariant, size: 28),
                const SizedBox(height: 8),
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: selected ? cs.onPrimaryContainer : null)),
                const SizedBox(height: 2),
                Text(subtitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: cs.outline)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
