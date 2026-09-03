// SPDX-License-Identifier: AGPL-3.0
//
// Create or edit a personal note: text, a pen drawing or a photo (with crop),
// and an optional reminder that fires a local notification.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/note.dart';
import '../../services/notes_store.dart';
import '../../services/notification_service.dart';
import '../../widgets/chat/drawing_signature_sheet.dart';

class NoteEditorScreen extends StatefulWidget {
  const NoteEditorScreen({super.key, this.note});
  final Note? note;

  @override
  State<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends State<NoteEditorScreen> {
  late final TextEditingController _text;
  late final String _id;
  String? _imagePath;
  NoteKind _kind = NoteKind.text;
  DateTime? _reminderAt;
  final DateTime _createdAt;
  bool _saving = false;

  _NoteEditorScreenState() : _createdAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    final n = widget.note;
    _id = n?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    _text = TextEditingController(text: n?.text ?? '');
    _imagePath = n?.imagePath;
    _kind = n?.kind ?? NoteKind.text;
    _reminderAt = n?.reminderAt;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _addDrawing() async {
    final file = await DrawingSignatureSheet.show(context);
    if (file == null) return;
    final path = await NotesStore.instance.persistImage(file, _id);
    if (!mounted) return;
    setState(() {
      _imagePath = path;
      _kind = NoteKind.drawing;
    });
  }

  Future<void> _addPhoto(ImageSource source) async {
    final x = await ImagePicker().pickImage(
      source: source,
      maxWidth: 2400,
      imageQuality: 85,
    );
    if (x == null) return;
    File file = File(x.path);
    try {
      final cropped = await ImageCropper().cropImage(
        sourcePath: file.path,
        compressQuality: 85,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Edit photo',
            toolbarWidgetColor: Colors.white,
            lockAspectRatio: false,
          ),
          IOSUiSettings(title: 'Edit photo', aspectRatioLockEnabled: false),
        ],
      );
      if (cropped != null) file = File(cropped.path);
    } catch (_) {
      // Cropper unavailable/cancelled — keep the original photo.
    }
    final path = await NotesStore.instance.persistImage(file, _id);
    if (!mounted) return;
    setState(() {
      _imagePath = path;
      _kind = NoteKind.photo;
    });
  }

  void _choosePhotoSource() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _addPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _addPhoto(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeImage() {
    setState(() {
      _imagePath = null;
      _kind = NoteKind.text;
    });
  }

  Future<void> _pickReminder() async {
    final now = DateTime.now();
    final base = _reminderAt ?? now.add(const Duration(hours: 1));
    final d = await showDatePicker(
      context: context,
      initialDate: base.isBefore(now) ? now : base,
      firstDate: now,
      lastDate: now.add(const Duration(days: 730)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (t == null || !mounted) return;
    setState(() {
      _reminderAt = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final note = Note(
      id: _id,
      text: _text.text.trim(),
      kind: _kind,
      imagePath: _imagePath,
      reminderAt: _reminderAt,
      createdAt: widget.note?.createdAt ?? _createdAt,
      updatedAt: DateTime.now(),
    );
    await NotesStore.instance.upsert(note);
    // (Re)schedule or clear the reminder.
    await NotificationService.instance.cancelReminder(note.reminderNotifId);
    if (_reminderAt != null && _reminderAt!.isAfter(DateTime.now())) {
      await NotificationService.instance.scheduleReminder(
        id: note.reminderNotifId,
        title: 'Note reminder',
        body: note.preview,
        at: _reminderAt!,
      );
    }
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _delete() async {
    await NotificationService.instance
        .cancelReminder(widget.note!.reminderNotifId);
    await NotesStore.instance.delete(_id);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editing = widget.note != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit note' : 'New note'),
        actions: [
          if (editing)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete',
              onPressed: _delete,
            ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Save',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _text,
              autofocus: !editing,
              minLines: 4,
              maxLines: 12,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Write a note…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_imagePath != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(_imagePath!),
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    height: 220,
                    color: cs.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _removeImage,
                  icon: const Icon(Icons.close),
                  label: const Text('Remove'),
                ),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _addDrawing,
                  icon: const Icon(Icons.draw_outlined),
                  label: const Text('Draw / write'),
                ),
                OutlinedButton.icon(
                  onPressed: _choosePhotoSource,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('Photo'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: Icon(
                  _reminderAt != null
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_none,
                  color: _reminderAt != null ? cs.primary : null,
                ),
                title: Text(_reminderAt != null
                    ? 'Reminder set'
                    : 'Set a reminder'),
                subtitle: _reminderAt != null
                    ? Text(_fmt(_reminderAt!))
                    : const Text('Get notified at a time you choose'),
                trailing: _reminderAt != null
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _reminderAt = null),
                      )
                    : null,
                onTap: _pickReminder,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}  ${two(d.hour)}:${two(d.minute)}';
  }
}
