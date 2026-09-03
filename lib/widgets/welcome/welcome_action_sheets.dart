// SPDX-License-Identifier: AGPL-3.0
//
// Quick capture sheets for welcome-layer notes and reminders.

import 'package:flutter/material.dart';

import '../../services/welcome_memory_store.dart';

Future<void> showWelcomeNoteSheet(BuildContext context) async {
  final ctrl = TextEditingController();
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
      return Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Quick note',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Jot something down — synced to this device for now',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save note'),
            ),
          ],
        ),
      );
    },
  );
  if (saved == true && ctrl.text.trim().isNotEmpty) {
    await WelcomeMemoryStore.instance.saveNote(ctrl.text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note saved — I\'ll surface it here')),
      );
    }
  }
  ctrl.dispose();
}

Future<void> showWelcomeReminderSheet(BuildContext context) async {
  final ctrl = TextEditingController();
  var due = DateTime.now().add(const Duration(hours: 1));

  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
      return StatefulBuilder(
        builder: (ctx, setSt) {
          return Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Reminder',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'What should I remind you about?',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final h in [1, 3, 24])
                      ChoiceChip(
                        label: Text(h == 24 ? 'Tomorrow' : 'In $h h'),
                        selected: due.difference(DateTime.now()).inHours == h ||
                            (h == 24 &&
                                due.difference(DateTime.now()).inHours >= 20),
                        onSelected: (_) {
                          setSt(() {
                            due = DateTime.now().add(Duration(hours: h));
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Set reminder'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  if (saved == true && ctrl.text.trim().isNotEmpty) {
    await WelcomeMemoryStore.instance.addReminder(
      body: ctrl.text,
      dueAt: due,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Reminder set for ${due.hour}:${due.minute.toString().padLeft(2, '0')}',
          ),
        ),
      );
    }
  }
  ctrl.dispose();
}
