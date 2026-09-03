// SPDX-License-Identifier: AGPL-3.0
//
// Host sheet — guest admission policy, share link, passcode setup.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/guest_join.dart';
import '../../services/live_api.dart';

Future<void> showGuestJoinHostSheet(
  BuildContext context, {
  required String roomCode,
  required GuestPolicyState initial,
  required void Function(GuestPolicyState updated) onUpdated,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _GuestJoinHostSheet(
      roomCode: roomCode,
      initial: initial,
      onUpdated: onUpdated,
    ),
  );
}

class _GuestJoinHostSheet extends ConsumerStatefulWidget {
  const _GuestJoinHostSheet({
    required this.roomCode,
    required this.initial,
    required this.onUpdated,
  });

  final String roomCode;
  final GuestPolicyState initial;
  final void Function(GuestPolicyState updated) onUpdated;

  @override
  ConsumerState<_GuestJoinHostSheet> createState() =>
      _GuestJoinHostSheetState();
}

class _GuestJoinHostSheetState extends ConsumerState<_GuestJoinHostSheet> {
  late GuestAdmissionPolicy _policy;
  late GuestJoinRole _guestRole;
  late bool _hasPasscode;
  String? _guestUrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _policy = widget.initial.policy;
    _guestRole = widget.initial.guestRole;
    _hasPasscode = widget.initial.hasPasscode;
    _guestUrl = widget.initial.guestUrl;
  }

  Future<String?> _promptPasscode({required bool required}) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Guest passcode'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Passcode (4–64 characters)',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(required ? 'Cancel' : 'Skip'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String? _validatePasscode(String? value) {
    if (value == null) return null;
    final p = value.trim();
    if (p.length < 4 || p.length > 64) {
      return 'Passcode must be 4–64 characters';
    }
    return p;
  }

  Future<void> _applyPolicy(GuestAdmissionPolicy next) async {
    if (_saving) return;
    String? passcode;
    if (next == GuestAdmissionPolicy.passcode) {
      final needsNew = !_hasPasscode || _policy != GuestAdmissionPolicy.passcode;
      if (needsNew) {
        final raw = await _promptPasscode(required: true);
        if (!mounted) return;
        passcode = _validatePasscode(raw);
        if (passcode == null) {
          if (raw != null && raw.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Passcode must be 4–64 characters')),
            );
          }
          return;
        }
      }
    }

    setState(() => _saving = true);
    try {
      final updated = await ref.read(liveApiProvider).putGuestPolicy(
            code: widget.roomCode,
            policy: next,
            guestRole: _guestRole,
            passcode: passcode,
          );
      if (!mounted) return;
      setState(() {
        _policy = updated.policy;
        _guestRole = updated.guestRole;
        _hasPasscode = updated.hasPasscode;
        _guestUrl = updated.guestUrl;
        _saving = false;
      });
      widget.onUpdated(updated);
    } on LiveApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update guest policy: $e')),
      );
    }
  }

  Future<void> _changePasscode() async {
    final raw = await _promptPasscode(required: true);
    if (!mounted) return;
    final passcode = _validatePasscode(raw);
    if (passcode == null) return;
    setState(() => _saving = true);
    try {
      final updated = await ref.read(liveApiProvider).putGuestPolicy(
            code: widget.roomCode,
            policy: GuestAdmissionPolicy.passcode,
            guestRole: _guestRole,
            passcode: passcode,
          );
      if (!mounted) return;
      setState(() {
        _hasPasscode = updated.hasPasscode;
        _guestUrl = updated.guestUrl;
        _saving = false;
      });
      widget.onUpdated(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passcode updated')),
      );
    } on LiveApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _updateGuestRole(GuestJoinRole role) async {
    if (_saving || _guestRole == role) return;
    setState(() {
      _guestRole = role;
      _saving = true;
    });
    try {
      final updated = await ref.read(liveApiProvider).putGuestPolicy(
            code: widget.roomCode,
            policy: _policy,
            guestRole: role,
          );
      if (!mounted) return;
      setState(() {
        _guestRole = updated.guestRole;
        _guestUrl = updated.guestUrl;
        _saving = false;
      });
      widget.onUpdated(updated);
    } on LiveApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _copyLink() async {
    final url = _guestUrl;
    if (url == null || url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Guest link copied')),
    );
  }

  Future<void> _shareLink() async {
    final url = _guestUrl;
    if (url == null || url.isEmpty) return;
    await Share.share('Join our INTERACT meeting (no app needed):\n$url');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final url = _guestUrl;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Allow guests',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'People without the app can join from a browser using your room link.',
                style: TextStyle(fontSize: 13, color: cs.outline),
              ),
              const SizedBox(height: 16),
              SegmentedButton<GuestAdmissionPolicy>(
                segments: const [
                  ButtonSegment(
                    value: GuestAdmissionPolicy.off,
                    label: Text('Off'),
                    icon: Icon(Icons.block, size: 18),
                  ),
                  ButtonSegment(
                    value: GuestAdmissionPolicy.passcode,
                    label: Text('Passcode'),
                    icon: Icon(Icons.lock_outline, size: 18),
                  ),
                  ButtonSegment(
                    value: GuestAdmissionPolicy.admit,
                    label: Text('Waiting room'),
                    icon: Icon(Icons.meeting_room_outlined, size: 18),
                  ),
                ],
                selected: {_policy},
                onSelectionChanged: _saving
                    ? null
                    : (s) => _applyPolicy(s.first),
              ),
              if (_policy != GuestAdmissionPolicy.off) ...[
                const SizedBox(height: 16),
                Text('Guest permissions', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<GuestJoinRole>(
                  segments: const [
                    ButtonSegment(
                      value: GuestJoinRole.speaker,
                      label: Text('Can talk'),
                    ),
                    ButtonSegment(
                      value: GuestJoinRole.listener,
                      label: Text('Listen only'),
                    ),
                  ],
                  selected: {_guestRole},
                  onSelectionChanged: _saving
                      ? null
                      : (s) => _updateGuestRole(s.first),
                ),
              ],
              if (_policy == GuestAdmissionPolicy.passcode && _hasPasscode) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _changePasscode,
                    icon: const Icon(Icons.password),
                    label: const Text('Change passcode'),
                  ),
                ),
              ],
              if (_policy != GuestAdmissionPolicy.off &&
                  url != null &&
                  url.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Guest link', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(url, style: const TextStyle(fontSize: 13)),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyLink,
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _shareLink,
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Share'),
                      ),
                    ),
                  ],
                ),
              ],
              if (_saving) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
