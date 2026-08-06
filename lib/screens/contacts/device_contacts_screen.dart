// SPDX-License-Identifier: AGPL-3.0
//
// DeviceContactsScreen — pick someone from the phone's address book to start a
// chat or invite them. This is the "add contact" entry the Contacts tab was
// missing: the on-device book was never readable before.
//
// Flow (reuses the exact registered/unregistered branch from ChatsTab):
//   tap a contact → createDirectThread(phone)
//     • registered  → open the chat thread
//     • unregistered → InviteSheet (Comms-Hub WhatsApp→SMS, or the OS share
//       sheet which reaches WhatsApp / SMS / email / any app)
//
// Privacy: read-only. We fetch contacts with phones to display + let the user
// choose; nothing is written back or uploaded. The chosen number follows the
// same path as manual entry.
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/chat_api.dart';
import '../../widgets/branded_app_bar.dart';
import '../chat/invite_sheet.dart';

class DeviceContactsScreen extends ConsumerStatefulWidget {
  const DeviceContactsScreen({super.key});
  @override
  ConsumerState<DeviceContactsScreen> createState() =>
      _DeviceContactsScreenState();
}

class _DeviceContactsScreenState extends ConsumerState<DeviceContactsScreen> {
  List<Contact>? _contacts;
  String? _error;
  bool _denied = false;
  String _query = '';
  bool _starting = false;

  // Multi-select / bulk-invite. Keyed by phone number.
  bool _selecting = false;
  final Set<String> _selected = <String>{};

  void _toggleSelecting() => setState(() {
        _selecting = !_selecting;
        if (!_selecting) _selected.clear();
      });

  void _toggleOne(String phone) => setState(() {
        if (!_selected.remove(phone)) _selected.add(phone);
      });

  /// Bulk-invite the given phone numbers via the Comms Hub (WhatsApp→SMS).
  /// Best-effort + sequential; respects the 5-free quota and reports a
  /// summary. Beyond quota, remaining numbers are skipped with a note to
  /// use the OS share sheet (individual invite) instead.
  Future<void> _bulkInvite(List<String> phones) async {
    if (phones.isEmpty || _starting) return;
    setState(() => _starting = true);
    int sent = 0, quotaHit = 0, failed = 0;
    try {
      for (final phone in phones) {
        try {
          await ref.read(chatApiProvider).sendInvite(phone);
          sent++;
        } on InviteQuotaExhausted {
          quotaHit++;
        } catch (_) {
          failed++;
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _starting = false;
          _selecting = false;
          _selected.clear();
        });
        final parts = <String>[
          if (sent > 0) '$sent invited',
          if (quotaHit > 0) '$quotaHit skipped (free quota used)',
          if (failed > 0) '$failed failed',
        ];
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(parts.isEmpty ? 'Nothing to invite' : parts.join(' · ')),
        ));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final granted = await FlutterContacts.requestPermission(readonly: true);
      if (!granted) {
        if (mounted) setState(() => _denied = true);
        return;
      }
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      final withPhones =
          contacts.where((c) => c.phones.isNotEmpty).toList()
            ..sort((a, b) => a.displayName
                .toLowerCase()
                .compareTo(b.displayName.toLowerCase()));
      if (mounted) setState(() => _contacts = withPhones);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pick(Contact c) async {
    final phone = c.phones.first.number.trim();
    if (phone.isEmpty || _starting) return;
    setState(() => _starting = true);
    try {
      final result =
          await ref.read(chatApiProvider).createDirectThread(peerPhone: phone);
      if (!mounted) return;
      switch (result) {
        case DirectThreadFound(:final thread):
          context.pop(); // close the picker
          context.push('/chat/${thread.id}', extra: thread);
        case DirectThreadUnregistered(:final rawPhone, :final normalizedPhone):
          await showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => InviteSheet(
              rawPhone: rawPhone,
              normalizedPhone: normalizedPhone,
            ),
          );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not start chat: $e')),
      );
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visiblePhones = _visiblePhones();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: _selecting ? '${_selected.length} selected' : 'Invite from contacts',
        subtitle: _selecting ? 'Pick people, then Invite' : 'Start a chat or invite',
        showBrandGlyph: !_selecting,
        actions: [
          if (_selecting) ...[
            TextButton(
              onPressed: _starting
                  ? null
                  : () => setState(() => _selected
                    ..clear()
                    ..addAll(visiblePhones)),
              child: const Text('All'),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              tooltip: 'Invite selected',
              onPressed: _starting || _selected.isEmpty
                  ? null
                  : () => _bulkInvite(_selected.toList()),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel',
              onPressed: _toggleSelecting,
            ),
          ] else
            IconButton(
              icon: const Icon(Icons.checklist),
              tooltip: 'Select multiple to invite',
              onPressed: _toggleSelecting,
            ),
        ],
      ),
      body: _body(cs),
    );
  }

  List<String> _visiblePhones() {
    final all = _contacts;
    if (all == null) return const [];
    final q = _query.trim().toLowerCase();
    return all
        .where((c) => c.phones.isNotEmpty)
        .where((c) =>
            q.isEmpty ||
            c.displayName.toLowerCase().contains(q) ||
            c.phones.any((p) => p.number.contains(q)))
        .map((c) => c.phones.first.number)
        .toList();
  }

  Widget _body(ColorScheme cs) {
    if (_denied) {
      return _Message(
        icon: Icons.contacts_outlined,
        title: 'Contacts permission needed',
        body: 'Allow contacts access to invite people from your address book. '
            'Your contacts stay on your device — nothing is uploaded. If you '
            'denied it, enable Contacts for INTERACT in Settings, then retry.',
        onRetry: _load,
      );
    }
    if (_error != null) {
      return _Message(
        icon: Icons.error_outline,
        title: 'Could not load contacts',
        body: _error!,
        onRetry: _load,
      );
    }
    final all = _contacts;
    if (all == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (all.isEmpty) {
      return const _Message(
        icon: Icons.person_off_outlined,
        title: 'No contacts with numbers',
        body: 'None of your contacts have a phone number to invite.',
      );
    }
    final q = _query.trim().toLowerCase();
    final visible = q.isEmpty
        ? all
        : all
            .where((c) =>
                c.displayName.toLowerCase().contains(q) ||
                c.phones.any((p) => p.number.contains(q)))
            .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: 'Search contacts',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              filled: true,
              fillColor: cs.surface.withValues(alpha: 0.7),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_starting) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ListView.separated(
            itemCount: visible.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final c = visible[i];
              final phone = c.phones.first.number;
              final checked = _selected.contains(phone);
              return ListTile(
                selected: _selecting && checked,
                leading: _selecting
                    ? Checkbox(
                        value: checked,
                        onChanged: (_) => _toggleOne(phone),
                      )
                    : CircleAvatar(
                        backgroundColor: cs.primaryContainer,
                        child: Text(
                          c.displayName.isEmpty
                              ? '?'
                              : c.displayName[0].toUpperCase(),
                          style: TextStyle(color: cs.onPrimaryContainer),
                        ),
                      ),
                title: Text(c.displayName,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(phone,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: _selecting
                    ? null
                    : const Icon(Icons.chat_bubble_outline, size: 18),
                onTap: () => _pick(c),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    // ignore: unused_element_parameter  (kept for API symmetry; pre-existing)
    this.action,
    this.onRetry,
  });
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;
  final Future<void> Function()? onRetry;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.outline, fontSize: 13)),
            const SizedBox(height: 16),
            if (action != null) action!,
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
