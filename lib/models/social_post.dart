// SPDX-License-Identifier: AGPL-3.0
//
// Social feed items — Friends & Family panel (local-first).

enum SocialAudience {
  family('family'),
  friends('friends'),
  everyone('everyone');

  const SocialAudience(this.wire);
  final String wire;

  String get label => switch (this) {
        SocialAudience.family => 'Family',
        SocialAudience.friends => 'Friends',
        SocialAudience.everyone => 'Everyone',
      };

  static SocialAudience fromWire(String? raw) {
    switch (raw) {
      case 'friends':
        return SocialAudience.friends;
      case 'everyone':
        return SocialAudience.everyone;
      case 'family':
      default:
        return SocialAudience.family;
    }
  }
}

enum SocialPostKind {
  status('status'),
  photo('photo'),
  video('video'),
  announcement('announcement'),
  location('location');

  const SocialPostKind(this.wire);
  final String wire;

  static SocialPostKind fromWire(String? raw) {
    switch (raw) {
      case 'photo':
        return SocialPostKind.photo;
      case 'video':
        return SocialPostKind.video;
      case 'announcement':
        return SocialPostKind.announcement;
      case 'location':
        return SocialPostKind.location;
      case 'status':
      default:
        return SocialPostKind.status;
    }
  }
}

class SocialPost {
  const SocialPost({
    required this.id,
    required this.authorId,
    required this.authorName,
    required this.audience,
    required this.kind,
    required this.body,
    required this.createdAt,
    this.authorAvatarUrl,
    this.mediaPath,
    this.mediaUrl,
    this.sourceThreadId,
    this.sourceThreadTitle,
    this.pendingSync = false,
  });

  final String id;
  final String authorId;
  final String authorName;
  final String? authorAvatarUrl;
  final SocialAudience audience;
  final SocialPostKind kind;
  final String body;
  final String? mediaPath;
  final String? mediaUrl;
  final DateTime createdAt;
  final String? sourceThreadId;
  final String? sourceThreadTitle;
  final bool pendingSync;

  Map<String, dynamic> toJson() => {
        'id': id,
        'authorId': authorId,
        'authorName': authorName,
        if (authorAvatarUrl != null) 'authorAvatarUrl': authorAvatarUrl,
        'audience': audience.wire,
        'kind': kind.wire,
        'body': body,
        if (mediaPath != null) 'mediaPath': mediaPath,
        if (mediaUrl != null) 'mediaUrl': mediaUrl,
        'createdAt': createdAt.toIso8601String(),
        if (sourceThreadId != null) 'sourceThreadId': sourceThreadId,
        if (sourceThreadTitle != null) 'sourceThreadTitle': sourceThreadTitle,
        'pendingSync': pendingSync,
      };

  factory SocialPost.fromJson(Map<String, dynamic> j) => SocialPost(
        id: (j['id'] as String?) ?? '',
        authorId: (j['authorId'] as String?) ?? '',
        authorName: (j['authorName'] as String?) ?? '',
        authorAvatarUrl: j['authorAvatarUrl'] as String?,
        audience: SocialAudience.fromWire(j['audience'] as String?),
        kind: SocialPostKind.fromWire(j['kind'] as String?),
        body: (j['body'] as String?) ?? '',
        mediaPath: j['mediaPath'] as String?,
        mediaUrl: j['mediaUrl'] as String?,
        createdAt:
            DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
        sourceThreadId: j['sourceThreadId'] as String?,
        sourceThreadTitle: j['sourceThreadTitle'] as String?,
        pendingSync: j['pendingSync'] as bool? ?? false,
      );
}

extension SocialPostMedia on SocialPost {
  bool get hasLocalMedia =>
      mediaPath != null && mediaPath!.isNotEmpty && mediaPath != 'null';

  bool get isVideo => kind == SocialPostKind.video;

  bool get isPhoto => kind == SocialPostKind.photo;

  /// WhatsApp-status window — recent media updates.
  bool get isRecentStory =>
      hasLocalMedia &&
      createdAt.isAfter(DateTime.now().subtract(const Duration(hours: 24)));
}
