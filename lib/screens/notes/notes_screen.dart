// SPDX-License-Identifier: AGPL-3.0
//
// Notes list — personal notes with pen drawings, photos and reminders.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/note.dart';
import '../../services/notes_store.dart';
import 'note_editor_screen.dart';

class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key});
  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Note> _notes = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final notes = await NotesStore.instance.load();
    if (!mounted) return;
    setState(() {
      _notes = notes;
      _loading = false;
    });
  }

  Future<void> _open(Note? note) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => NoteEditorScreen(note: note)),
    );
    if (changed == true) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Notes')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(null),
        icon: const Icon(Icons.add),
        label: const Text('New note'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? _empty(cs)
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _notes.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _tile(_notes[i], cs),
                ),
    );
  }

  Widget _empty(ColorScheme cs) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.sticky_note_2_outlined, size: 56, color: cs.outline),
              const SizedBox(height: 12),
              Text('No notes yet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Jot a note, sketch with the pen, snap a photo, and set a reminder.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.outline),
              ),
            ],
          ),
        ),
      );

  Widget _tile(Note n, ColorScheme cs) {
    final due = n.reminderAt != null;
    return ListTile(
      leading: n.hasImage
          ? ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(n.imagePath!),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(Icons.image_not_supported_outlined, color: cs.outline),
              ),
            )
          : CircleAvatar(
              backgroundColor: cs.primaryContainer,
              child: Icon(
                n.kind == NoteKind.drawing
                    ? Icons.draw_outlined
                    : Icons.notes_outlined,
                color: cs.onPrimaryContainer,
                size: 20,
              ),
            ),
      title: Text(n.preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: due
          ? Row(
              children: [
                Icon(Icons.notifications_active_outlined,
                    size: 14, color: cs.primary),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _NoteEditorFmt.fmt(n.reminderAt!),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.primary, fontSize: 12),
                  ),
                ),
              ],
            )
          : null,
      onTap: () => _open(n),
    );
  }
}

class _NoteEditorFmt {
  static String fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
  }
}
