// SPDX-License-Identifier: AGPL-3.0
//
// Local persistence for personal notes (shared_preferences JSON). Attached
// images are copied into the app documents dir so they survive picker/cache
// cleanup. Backend sync can layer on later; this keeps notes on-device.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/note.dart';

class NotesStore {
  NotesStore._();
  static final NotesStore instance = NotesStore._();
  static const _kKey = 'talk_notes_v1';

  Future<List<Note>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      final notes = list
          .whereType<Map>()
          .map((e) => Note.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      notes.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return notes;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveAll(List<Note> notes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kKey,
      jsonEncode(notes.map((n) => n.toJson()).toList()),
    );
  }

  Future<void> upsert(Note note) async {
    final notes = await load();
    final i = notes.indexWhere((n) => n.id == note.id);
    if (i >= 0) {
      notes[i] = note;
    } else {
      notes.add(note);
    }
    await _saveAll(notes);
  }

  Future<void> delete(String id) async {
    final notes = await load();
    final gone = notes.firstWhere(
      (n) => n.id == id,
      orElse: () => Note(id: '', createdAt: DateTime.now(), updatedAt: DateTime.now()),
    );
    notes.removeWhere((n) => n.id == id);
    await _saveAll(notes);
    // Best-effort cleanup of the attached image file.
    final p = gone.imagePath;
    if (p != null && p.isNotEmpty) {
      try {
        final f = File(p);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// Copy [source] into a persistent notes dir and return the new path.
  Future<String> persistImage(File source, String noteId) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/notes');
    if (!await dir.exists()) await dir.create(recursive: true);
    final ext = source.path.contains('.')
        ? source.path.substring(source.path.lastIndexOf('.'))
        : '.png';
    final dest = File('${dir.path}/$noteId${ext.length <= 5 ? ext : '.png'}');
    await source.copy(dest.path);
    return dest.path;
  }
}
