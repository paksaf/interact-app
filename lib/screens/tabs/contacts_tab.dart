// SPDX-License-Identifier: AGPL-3.0
//
// Contacts — recent + frequent peers from /api/v1/talk/contacts
// (cross-app: aggregates from CallLog + ChatThread participants). This
// is the UNIQUE moat — INTERACT shows your contacts from every other
// INTERACT app the moment you sign in, no manual sync.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/crm_name_cache.dart';
import '../../services/device_contacts_index.dart';
import '../../services/presence_service.dart';
import '../../services/talk_api.dart';
import '../../utils/display_name.dart';
import '../../widgets/branded_app_bar.dart';

class ContactsTab extends ConsumerStatefulWidget {
  const ContactsTab({super.key});
  @override
  ConsumerState<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends ConsumerState<ContactsTab> {
  late Future<List<Map<String, dynamic>>> _contacts;
  // Run the one-shot decoration (device-name index warm-up + presence
  // refresh) exactly once after the first load — guards against the
  // per-frame setState→rebuild→refresh loop the naive postFrame form causes.
  bool _decorated = false;

  @override
  void initState() {
    super.initState();
    _contacts = ref.read(talkApiProvider).recentContacts();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Invite moved here from the removed Menu tab (Phase-1 redesign). Reuses
      // the existing InviteScreen (/invite) — share/scan an invite code/QR.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/invite'),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Invite'),
      ),
      appBar: BrandedAppBar(
        title: 'Contacts',
        subtitle: 'Synced across every INTERACT app',
        showBrandGlyph: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_outlined),
            tooltip: 'Invite from contacts',
            onPressed: () => context.push('/device-contacts'),
          ),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _contacts,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data ?? const [];
          // One-shot decoration: warm the read-only device-contact index (for
          // real names over generic "Talk 1469") + presence refresh by phone
          // key → QS TalkPresence. Guarded so it runs once, not every frame.
          if (rows.isNotEmpty && !_decorated) {
            _decorated = true;
            final keys = rows
                .map((r) => (r['phone'] as String?) ?? '')
                .where((p) => p.isNotEmpty)
                .toList();
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              await ref.read(deviceContactsIndexProvider).ensureLoaded();
              await ref.read(presenceServiceProvider).refresh(keys);
              if (mounted) setState(() {});
              // Opportunistically resolve names from the INTERACT CRM (hash-only,
              // fail-soft, no-op until the pepper is provisioned). Rebuild again
              // only when a match actually landed, so cached names appear.
              final added =
                  await ref.read(crmNameCacheProvider).ensureResolved(keys);
              if (added > 0 && mounted) setState(() {});
            });
          }
          if (rows.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline, size: 64, color: cs.outline),
                    const SizedBox(height: 16),
                    Text('No contacts yet',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Anyone you call or message across INTERACT apps will appear here automatically.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.outline, fontSize: 12),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final r = rows[i];
              final phone = r['phone'] as String? ?? '';
              // Prefer a device-book name, then a CRM-matched name, over the
              // backend's generic label.
              final name = resolveDisplayName(
                deviceName:
                    ref.read(deviceContactsIndexProvider).nameFor(phone),
                crmName: ref.read(crmNameCacheProvider).nameFor(phone),
                backendName: r['name'] as String?,
                phone: phone,
              );
              final src = r['source'] as String? ?? 'talk';
              final online =
                  ref.read(presenceServiceProvider).isOnline(phone);
              return ListTile(
                leading: Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: online
                              ? const Color(0xFF22C55E).withValues(alpha: 0.7)
                              : cs.outlineVariant.withValues(alpha: 0.4),
                          width: 1.5,
                        ),
                      ),
                      child: CircleAvatar(
                        backgroundColor: cs.primaryContainer,
                        child: Text(
                          name.isEmpty ? '?' : name[0].toUpperCase(),
                          style: TextStyle(color: cs.onPrimaryContainer),
                        ),
                      ),
                    ),
                    if (online)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: const Color(0xFF22C55E),
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.surface, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                title: Text(name),
                subtitle: Text([if (phone.isNotEmpty) phone, 'via $src'].join(' · ')),
                // Unobtrusive: long-press to propose this contact to the CRM
                // (admin-reviewed; never writes the CRM directly).
                onLongPress: phone.isEmpty
                    ? null
                    : () => _suggestToCrm(context, name: name, phone: phone),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.videocam_outlined),
                      tooltip: 'Video call',
                      onPressed: () => _quickCall(context),
                    ),
                    IconButton(
                      icon: const Icon(Icons.phone_outlined),
                      tooltip: 'Voice call',
                      onPressed: () => _quickCall(context),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Small "Suggest to CRM" dialog — prefills the contact name from whatever is
  /// currently resolved, lets the user tweak it + add an org/note, then submits
  /// an admin-reviewed suggestion. Fail-soft: a submit error still shows a
  /// gentle SnackBar. The CRM is read-only — this never writes it directly.
  Future<void> _suggestToCrm(
    BuildContext context, {
    required String name,
    required String phone,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final nameCtl = TextEditingController(text: name);
    final orgCtl = TextEditingController();
    final noteCtl = TextEditingController();

    final submit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Suggest to CRM'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              phone,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(ctx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtl,
              decoration: const InputDecoration(labelText: 'Contact name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: orgCtl,
              decoration:
                  const InputDecoration(labelText: 'Organization (optional)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtl,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Suggest'),
          ),
        ],
      ),
    );

    if (submit != true) return;
    final suggestedName = nameCtl.text.trim();
    if (suggestedName.isEmpty) return;

    final okSent = await ref.read(crmNameCacheProvider).suggestToCrm(
          phone,
          suggestedName,
          org: orgCtl.text.trim().isEmpty ? null : orgCtl.text.trim(),
          note: noteCtl.text.trim().isEmpty ? null : noteCtl.text.trim(),
        );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          okSent
              ? 'Sent to CRM for review'
              : 'Saved locally — will submit when online',
        ),
      ),
    );
  }

  Future<void> _quickCall(BuildContext context) async {
    // Capture the messenger BEFORE the await — safe to use post-unmount, so
    // the error snackbar never touches `context` after the async gap.
    final messenger = ScaffoldMessenger.of(context);
    try {
      final tok = await ref.read(talkApiProvider).createRoom();
      final code = tok.roomId.split(':').last;
      if (!context.mounted) return;
      context.push('/room?code=$code&host=true');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not place call: $e')),
      );
    }
  }
}
