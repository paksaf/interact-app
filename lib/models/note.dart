// SPDX-License-Identifier: AGPL-3.0
//
// A personal note in Talk: free text plus an optional pen drawing or photo,
// and an optional reminder time. Stored locally (NotesStore).
enum NoteKind { text, drawing, photo }

class Note {
  Note({
    required this.id,
    this.text = '',
    this.kind = NoteKind.text,
    this.imagePath,
    this.reminderAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  String text;
  NoteKind kind;
  String? imagePath; // persistent local file (drawing/photo), else null
  DateTime? reminderAt;
  final DateTime createdAt;
  DateTime updatedAt;

  /// Stable, positive notification id derived from the note id.
  int get reminderNotifId => id.hashCode & 0x7fffffff;

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  String get preview {
    final t = text.trim();
    if (t.isNotEmpty) return t.split('\n').first;
    switch (kind) {
      case NoteKind.drawing:
        return 'Drawing';
      case NoteKind.photo:
        return 'Photo';
      case NoteKind.text:
        return 'Empty note';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'kind': kind.name,
        'imagePath': imagePath,
        'reminderAt': reminderAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        id: j['id'] as String,
        text: (j['text'] as String?) ?? '',
        kind: NoteKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => NoteKind.text,
        ),
        imagePath: j['imagePath'] as String?,
        reminderAt: (j['reminderAt'] as String?) != null
            ? DateTime.tryParse(j['reminderAt'] as String)
            : null,
        createdAt:
            DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        updatedAt:
            DateTime.tryParse((j['updatedAt'] as String?) ?? '') ?? DateTime.now(),
      );
}
