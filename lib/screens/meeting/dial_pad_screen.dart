// SPDX-License-Identifier: AGPL-3.0
//
// DialPadScreen — phone-style dialer to place a NEW 1:1 call by number OR
// email. Reuses the SAME "resolve peer → ring → push /room" pattern as
// ChatThreadScreen._startCall:
//   1. createDirectThread(peerPhone/peerEmail) resolves the peer + thread.
//   2. If DirectThreadFound → callSignalingProvider.ring(threadId, mode)
//      then pushReplacement /room?host=true&mode=..&threadId=..&peerName=..
//   3. If DirectThreadUnregistered → "not on INTERACT yet" (no navigate).
//
// A numeric keypad can't type an email, so a "Type email instead" toggle
// swaps the keypad for a normal TextField in emailAddress mode.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/call_signaling.dart';
import '../../services/chat_api.dart';
import '../../services/device_contacts_index.dart';
import '../../services/talk_flags.dart';
import '../../utils/display_name.dart';

class DialPadScreen extends ConsumerStatefulWidget {
  const DialPadScreen({super.key});
  @override
  ConsumerState<DialPadScreen> createState() => _DialPadScreenState();
}

class _DialPadScreenState extends ConsumerState<DialPadScreen> {
  // The typed number (keypad mode). Email uses its own controller so the
  // soft keyboard can enter '@' and letters.
  String _number = '';
  final _emailCtrl = TextEditingController();
  bool _emailMode = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Warm the read-only device-contact index so a call placed by number can
    // ring with the caller's real name instead of a generic "Talk 1469".
    // Best-effort — never prompts, never throws.
    ref.read(deviceContactsIndexProvider).ensureLoaded();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  String get _input => _emailMode ? _emailCtrl.text.trim() : _number.trim();

  void _tap(String ch) {
    if (_busy) return;
    setState(() => _number = '$_number$ch');
  }

  void _backspace() {
    if (_busy || _number.isEmpty) return;
    setState(() => _number = _number.substring(0, _number.length - 1));
  }

  Future<void> _place({required String mode}) async {
    // Idempotency guard — one action = one ring(). The action buttons are
    // already disabled while _busy, but this closes the double-tap race so
    // we never create two invites (which would ring the peer twice).
    if (_busy) return;
    final input = _input;
    if (input.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_emailMode
              ? 'Enter an email address'
              : 'Enter a number to call'),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await ref.read(chatApiProvider).createDirectThread(
            peerEmail: _emailMode ? input : null,
            peerPhone: _emailMode ? null : input,
          );
      if (!mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          // Prefer a device-book name for the dialled number over the
          // backend's generic thread title ("Talk 1469"). For email dials we
          // can't match a number, so device lookup is skipped.
          final peerName = resolveDisplayName(
            deviceName: _emailMode
                ? null
                : ref.read(deviceContactsIndexProvider).nameFor(input),
            backendName: thread.title,
            phone: input,
          );
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Ringing ${peerName.isEmpty ? input : peerName}…'),
              duration: const Duration(seconds: 3),
            ),
          );
          // Ring first so we carry the inviteId into the room (host hang-up
          // can then remotely cancel the callee's ring). Best-effort → null.
          final inviteId = await ref
              .read(callSignalingProvider)
              .ring(thread.id, mode);
          if (!mounted) return;
          final uri = Uri(
            // Flag-gated: '/call-lk' (LiveKit + captions) when TALK_LK_CALLS is
            // on, else the unchanged P2P '/room'. The ring above is unchanged.
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
          context.pushReplacement(uri);
        case DirectThreadUnregistered():
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'That ${_emailMode ? 'email' : 'number'} isn\'t on INTERACT '
                'yet — invite them from Chats.',
              ),
              duration: const Duration(seconds: 4),
            ),
          );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not place call: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dial a number'),
        actions: [
          TextButton.icon(
            onPressed: _busy
                ? null
                : () => setState(() => _emailMode = !_emailMode),
            icon: Icon(_emailMode ? Icons.dialpad : Icons.alternate_email,
                size: 18),
            label: Text(_emailMode ? 'Use keypad' : 'Type email instead'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            // Display field — the typed number, or an email TextField.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: _emailMode
                  ? TextField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      autofocus: true,
                      enabled: !_busy,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 22),
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                        hintText: 'name@example.com',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setState(() {}),
                    )
                  : Text(
                      _number.isEmpty ? 'Enter number' : _number,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w600,
                        color: _number.isEmpty ? cs.outline : cs.onSurface,
                      ),
                    ),
            ),
            const Spacer(),
            if (!_emailMode) _Keypad(onTap: _tap, onBackspace: _backspace),
            const SizedBox(height: 12),
            // Action buttons — Voice + Video.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _busy ? null : () => _place(mode: 'voice'),
                      icon: const Icon(Icons.phone),
                      label: const Text('Voice call'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          _busy ? null : () => _place(mode: 'video'),
                      icon: const Icon(Icons.videocam),
                      label: const Text('Video call'),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.secondary,
                        foregroundColor: cs.onSecondary,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Phone-style 4×3 keypad: 1-9, +, 0, backspace.
class _Keypad extends StatelessWidget {
  const _Keypad({required this.onTap, required this.onBackspace});
  final void Function(String) onTap;
  final VoidCallback onBackspace;

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['+', '0', '⌫'],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: rows.map((r) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: r.map((ch) {
                if (ch == '⌫') {
                  return _KeyButton(
                    onTap: onBackspace,
                    child: const Icon(Icons.backspace_outlined),
                  );
                }
                return _KeyButton(
                  onTap: () => onTap(ch),
                  child: Text(
                    ch,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 72,
          height: 72,
          child: Center(child: child),
        ),
      ),
    );
  }
}
