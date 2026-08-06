// SPDX-License-Identifier: AGPL-3.0
//
// NewGroupScreen — create a WhatsApp-style group: a name + member phone
// numbers (registered INTERACT users). On create, opens the group thread.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/chat_api.dart';
import '../../utils/phone_normalize.dart';
import '../../widgets/branded_app_bar.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});
  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _phonesCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phonesCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final title = _nameCtrl.text.trim();
    final phones = _phonesCtrl.text
        .split(RegExp(r'[,\n]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => normalizeInteractPhone(s) ?? s)
        .toList();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Give the group a name')),
      );
      return;
    }
    if (phones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one member phone number')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final thread = await ref
          .read(chatApiProvider)
          .createGroup(title: title, memberPhones: phones);
      if (!mounted) return;
      context.pop();
      context.push('/chat/${thread.id}', extra: thread);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not create group: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'New group',
        subtitle: 'Name it, add members',
        showBrandGlyph: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _nameCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. Family, Team Alpha',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _phonesCtrl,
            keyboardType: TextInputType.phone,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Member phone numbers',
              hintText: 'One per line (or comma-separated)\n+923001234567\n+923009876543',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Only numbers already on INTERACT are added. You can add more members '
            'later from the group info screen.',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _create,
            icon: _busy
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.group_add),
            label: Text(_busy ? 'Creating…' : 'Create group'),
          ),
        ],
      ),
    );
  }
}
