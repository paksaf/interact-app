// SPDX-License-Identifier: AGPL-3.0
//
// Shared formatters for chat / calls surfaces. Keep this small and
// dependency-free so the rest of the app can use it without pulling
// extra packages.

import '../models/chat.dart';

/// Relative timestamp for thread tiles and call rows:
///   < 1 min  → "now"
///   < 1 h    → "12m"
///   today    → "14:32"
///   yesterday→ "Yesterday"
///   < 7 days → weekday short ("Mon", "Tue", ...)
///   older    → "yyyy-MM-dd"
String relTime(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inSeconds < 0) return _hm(t); // future timestamp, just show time
  if (diff.inMinutes < 1) return 'now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  final dayDiff = today.difference(that).inDays;
  if (dayDiff == 0) return _hm(t);
  if (dayDiff == 1) return 'Yesterday';
  if (dayDiff < 7) return _weekdayShort(t.weekday);
  return '${t.year}-${_pad2(t.month)}-${_pad2(t.day)}';
}

/// HH:mm in 24-hour format. Used in message bubble timestamps.
String hm(DateTime t) => _hm(t);

String _hm(DateTime t) => '${_pad2(t.hour)}:${_pad2(t.minute)}';

String _pad2(int n) => n.toString().padLeft(2, '0');

String _weekdayShort(int weekday) {
  // DateTime.weekday: 1=Mon ... 7=Sun
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return names[(weekday - 1).clamp(0, 6)];
}

/// Heading shown between messages on different days inside a thread.
///   today    → "Today"
///   yesterday→ "Yesterday"
///   < 7 days → weekday full ("Monday")
///   older    → "12 May 2026"
String daySeparator(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(t.year, t.month, t.day);
  final dayDiff = today.difference(that).inDays;
  if (dayDiff == 0) return 'Today';
  if (dayDiff == 1) return 'Yesterday';
  if (dayDiff < 7) {
    const full = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ];
    return full[(t.weekday - 1).clamp(0, 6)];
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${t.day} ${months[(t.month - 1).clamp(0, 11)]} ${t.year}';
}

/// Subtitle preview for a thread tile. Maps MessageKind → human text so
/// voice/image/file threads don't show an empty "—" when the server
/// didn't backfill `lastMessagePreview`.
///
/// Pass the raw `lastMessagePreview` if you have it; otherwise pass null
/// and we'll fall back to the kind-derived placeholder.
String messagePreview({
  String? preview,
  MessageKind? lastKind,
  String? lastKindRaw,
}) {
  final kind = lastKind ?? _kindFromRaw(lastKindRaw);
  final p = preview?.trim() ?? '';
  if (p.isNotEmpty) {
    final lower = p.toLowerCase();
    if (lower == 'video' || lower == 'video call') return '📹 Video call';
    if (lower == 'voice' || lower == 'voice call' || lower == 'audio') {
      return '📞 Voice call';
    }
    return p;
  }
  switch (kind) {
    case MessageKind.voice:
      return '🎤 Voice message';
    case MessageKind.image:
      return '📷 Photo';
    case MessageKind.file:
      return '📎 Attachment';
    case MessageKind.system:
      return 'System update';
    case MessageKind.text:
    case null:
      return 'Tap to open';
  }
}

MessageKind? _kindFromRaw(String? raw) {
  switch ((raw ?? '').toLowerCase()) {
    case 'voice':
      return MessageKind.voice;
    case 'image':
    case 'photo':
      return MessageKind.image;
    case 'file':
    case 'document':
      return MessageKind.file;
    case 'system':
    case 'call':
      return MessageKind.system;
    case 'text':
      return MessageKind.text;
    default:
      return null;
  }
}

/// Format a call duration like "2m 14s" / "47s" / "—".
String callDuration(int sec) {
  if (sec <= 0) return '—';
  if (sec < 60) return '${sec}s';
  final m = sec ~/ 60;
  final s = sec % 60;
  if (s == 0) return '${m}m';
  return '${m}m ${s}s';
}
