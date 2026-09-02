// SPDX-License-Identifier: AGPL-3.0
//
// Curated family / friend circles for the social panel.

enum FamilyCircleKind {
  family('family'),
  closeFriend('close_friend'),
  friend('friend');

  const FamilyCircleKind(this.wire);
  final String wire;

  String get label => switch (this) {
        FamilyCircleKind.family => 'Family',
        FamilyCircleKind.closeFriend => 'Close friends',
        FamilyCircleKind.friend => 'Friends',
      };

  static FamilyCircleKind fromWire(String? raw) {
    switch (raw) {
      case 'close_friend':
        return FamilyCircleKind.closeFriend;
      case 'friend':
        return FamilyCircleKind.friend;
      case 'family':
      default:
        return FamilyCircleKind.family;
    }
  }
}

class FamilyCircleMember {
  const FamilyCircleMember({
    required this.key,
    required this.displayName,
    required this.circle,
    required this.addedAt,
    this.phone,
    this.userId,
    this.avatarUrl,
  });

  final String key;
  final String? phone;
  final String? userId;
  final String displayName;
  final String? avatarUrl;
  final FamilyCircleKind circle;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'key': key,
        if (phone != null) 'phone': phone,
        if (userId != null) 'userId': userId,
        'displayName': displayName,
        if (avatarUrl != null) 'avatarUrl': avatarUrl,
        'circle': circle.wire,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FamilyCircleMember.fromJson(Map<String, dynamic> j) =>
      FamilyCircleMember(
        key: (j['key'] as String?) ?? '',
        phone: j['phone'] as String?,
        userId: j['userId'] as String?,
        displayName: (j['displayName'] as String?) ?? '',
        avatarUrl: j['avatarUrl'] as String?,
        circle: FamilyCircleKind.fromWire(j['circle'] as String?),
        addedAt:
            DateTime.tryParse(j['addedAt'] as String? ?? '') ?? DateTime.now(),
      );

  FamilyCircleMember copyWith({FamilyCircleKind? circle}) => FamilyCircleMember(
        key: key,
        phone: phone,
        userId: userId,
        displayName: displayName,
        avatarUrl: avatarUrl,
        circle: circle ?? this.circle,
        addedAt: addedAt,
      );
}
