// SPDX-License-Identifier: AGPL-3.0
//
// ChatThread + Message — shape adapted from Sahulat's polymorphic
// model (#171) with the animal/contract/vet_booking anchors dropped.
// INTERACT uses subjectType='general' for personal threads and
// 'group' for multi-participant rooms.
//
// 2026-05-22 polish pass:
//   - ChatThreadParticipant is now a structured object (was List<String>
//     in the prior version which couldn't carry per-participant state).
//     Each participant has lastReadAt + typingAt — used to compute
//     read-receipt ticks (#144) and live typing indicators (#146).
//   - ChatThread carries a peer/peerHasInteractInstalled hint set by the
//     server when peerPhone resolved to a registered user (#142). Drives
//     the call-button precheck and a "Not on INTERACT yet" warning chip.

class ChatThreadParticipant {
  const ChatThreadParticipant({
    required this.userId,
    required this.role,
    required this.muted,
    this.lastReadAt,
    this.typingAt,
  });

  final String userId;
  final String role;        // 'buyer' | 'seller' | 'user' | 'admin' | ...
  final bool muted;
  final DateTime? lastReadAt;
  /// Last time this participant signalled typing on the server (#146).
  /// We treat any value within the last 5 seconds as "live typing" and
  /// render the dot bubble accordingly.
  final DateTime? typingAt;

  bool get isTypingLive {
    if (typingAt == null) return false;
    return DateTime.now().difference(typingAt!).inSeconds < 5;
  }

  factory ChatThreadParticipant.fromJson(Map<String, dynamic> j) =>
      ChatThreadParticipant(
        userId: (j['userId'] as String?) ?? '',
        role: (j['role'] as String?) ?? 'user',
        muted: (j['muted'] as bool?) ?? false,
        lastReadAt:
            DateTime.tryParse(j['lastReadAt'] as String? ?? ''),
        typingAt: DateTime.tryParse(j['typingAt'] as String? ?? ''),
      );
}

class ChatThread {
  ChatThread({
    required this.id,
    required this.subjectType,
    required this.subjectId,
    required this.title,
    required this.participants,
    required this.lastMessageAt,
    this.lastMessagePreview,
    this.unreadCount = 0,
    this.avatarUrl,
    this.peerUserId,
    this.peerHasInteractInstalled,
  });

  final String id;
  final String subjectType;
  final String subjectId;
  final String title;
  final List<ChatThreadParticipant> participants;
  final DateTime lastMessageAt;
  final String? lastMessagePreview;
  final int unreadCount;
  final String? avatarUrl;

  /// 1:1 peer summary populated by the server when peerPhone matched a
  /// registered user. Null for group threads or threads opened without
  /// peer resolution (e.g. invitations, server-side seeds).
  final String? peerUserId;
  /// True when the peer has actually opened INTERACT (externalUserId !=
  /// null on the server). False if the peer is a Sahulat-only user
  /// who has never used INTERACT — the client surfaces a warning chip
  /// and disables the call buttons in that case (#142).
  final bool? peerHasInteractInstalled;

  bool get isGroup => subjectType == 'group';

  /// True if ANY non-self participant has a live typing cursor (#146).
  /// Returns false when `myUserId` isn't known yet.
  bool peerIsTyping(String? myUserId) {
    if (myUserId == null) return false;
    for (final p in participants) {
      if (p.userId == myUserId) continue;
      if (p.isTypingLive) return true;
    }
    return false;
  }

  factory ChatThread.fromJson(Map<String, dynamic> j) {
    // Participants on modern responses are objects; older responses
    // returned plain string userIds. Handle both shapes defensively.
    final partsRaw = (j['participants'] as List?) ?? const [];
    final parts = <ChatThreadParticipant>[];
    for (final p in partsRaw) {
      if (p is Map<String, dynamic>) {
        parts.add(ChatThreadParticipant.fromJson(p));
      } else if (p is String) {
        parts.add(ChatThreadParticipant(
          userId: p,
          role: 'user',
          muted: false,
        ));
      }
    }
    return ChatThread(
      id: (j['id'] as String?) ?? '',
      subjectType: (j['subjectType'] as String?) ?? 'general',
      subjectId: (j['subjectId'] as String?) ?? '',
      title: (j['title'] as String?) ?? 'Untitled',
      participants: parts,
      lastMessageAt:
          DateTime.tryParse(j['lastMessageAt'] as String? ?? '') ??
              DateTime.now(),
      lastMessagePreview: j['lastMessagePreview'] as String?,
      unreadCount: (j['unreadCount'] as num?)?.toInt() ?? 0,
      avatarUrl: j['avatarUrl'] as String?,
      peerUserId: j['peerUserId'] as String?,
      peerHasInteractInstalled: j['peerHasInteractInstalled'] as bool?,
    );
  }

  ChatThread copyWith({
    List<ChatThreadParticipant>? participants,
    String? peerUserId,
    bool? peerHasInteractInstalled,
  }) {
    return ChatThread(
      id: id,
      subjectType: subjectType,
      subjectId: subjectId,
      title: title,
      participants: participants ?? this.participants,
      lastMessageAt: lastMessageAt,
      lastMessagePreview: lastMessagePreview,
      unreadCount: unreadCount,
      avatarUrl: avatarUrl,
      peerUserId: peerUserId ?? this.peerUserId,
      peerHasInteractInstalled:
          peerHasInteractInstalled ?? this.peerHasInteractInstalled,
    );
  }
}

enum MessageKind { text, voice, image, file, system }

class Message {
  Message({
    required this.id,
    required this.threadId,
    required this.senderId,
    required this.senderName,
    required this.kind,
    required this.body,
    required this.sentAt,
    this.mediaUrl,
    this.mediaDurationSec,
    this.transcript,
    this.deliveredAt,
    this.readAt,
    this.isMine = false,
  });

  final String id;
  final String threadId;
  final String senderId;
  final String senderName;
  final MessageKind kind;
  final String body;
  final DateTime sentAt;
  final String? mediaUrl;
  final int? mediaDurationSec;
  final String? transcript;
  final DateTime? deliveredAt;
  final DateTime? readAt;
  final bool isMine;

  factory Message.fromJson(Map<String, dynamic> j, {String? myId}) {
    final senderId = (j['senderId'] as String?) ?? '';
    // `id` is normally a server-issued uuid, but a prior version of the
    // POST messages route returned a hub-result envelope with no `id`
    // field — defensive fallback so a future regression doesn't crash
    // the chat screen.
    final id = (j['id'] as String?) ??
        'local-${DateTime.now().microsecondsSinceEpoch}';
    return Message(
      id: id,
      threadId: (j['threadId'] as String?) ?? '',
      senderId: senderId,
      senderName: (j['senderName'] as String?) ?? senderId,
      kind: _kindFrom(j['kind'] as String? ?? 'text'),
      body: (j['body'] as String?) ?? '',
      sentAt:
          DateTime.tryParse(j['sentAt'] as String? ?? '') ?? DateTime.now(),
      mediaUrl: j['mediaUrl'] as String?,
      mediaDurationSec: (j['mediaDurationSec'] as num?)?.toInt(),
      transcript: j['transcript'] as String?,
      deliveredAt: DateTime.tryParse(j['deliveredAt'] as String? ?? ''),
      readAt: DateTime.tryParse(j['readAt'] as String? ?? ''),
      isMine: myId != null && senderId == myId,
    );
  }

  static MessageKind _kindFrom(String s) {
    switch (s) {
      case 'voice':
        return MessageKind.voice;
      case 'image':
        return MessageKind.image;
      case 'file':
        return MessageKind.file;
      case 'system':
        return MessageKind.system;
      default:
        return MessageKind.text;
    }
  }
}
