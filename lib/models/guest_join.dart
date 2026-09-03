// SPDX-License-Identifier: AGPL-3.0
//
// Guest join — host policy + waiting-room queue (LiveKit townhall).

/// Host-selected guest admission mode for a live room code.
enum GuestAdmissionPolicy {
  off('off'),
  passcode('passcode'),
  admit('admit');

  const GuestAdmissionPolicy(this.wire);
  final String wire;

  static GuestAdmissionPolicy fromWire(String? wire) {
    return GuestAdmissionPolicy.values.firstWhere(
      (p) => p.wire == wire,
      orElse: () => GuestAdmissionPolicy.off,
    );
  }
}

/// Guest publish grant when they join from the web page.
enum GuestJoinRole {
  speaker('speaker'),
  listener('listener');

  const GuestJoinRole(this.wire);
  final String wire;

  static GuestJoinRole fromWire(String? wire) {
    return GuestJoinRole.values.firstWhere(
      (r) => r.wire == wire,
      orElse: () => GuestJoinRole.speaker,
    );
  }
}

class GuestPolicyState {
  const GuestPolicyState({
    required this.policy,
    required this.guestRole,
    required this.hasPasscode,
    this.guestUrl,
  });

  final GuestAdmissionPolicy policy;
  final GuestJoinRole guestRole;
  final bool hasPasscode;
  final String? guestUrl;

  static const off = GuestPolicyState(
    policy: GuestAdmissionPolicy.off,
    guestRole: GuestJoinRole.speaker,
    hasPasscode: false,
  );

  bool get guestsEnabled => policy != GuestAdmissionPolicy.off;

  factory GuestPolicyState.fromData(Map<String, dynamic> d) => GuestPolicyState(
        policy: GuestAdmissionPolicy.fromWire(d['policy'] as String?),
        guestRole: GuestJoinRole.fromWire(d['guestRole'] as String?),
        hasPasscode: d['hasPasscode'] == true,
        guestUrl: d['guestUrl'] as String?,
      );

  GuestPolicyState copyWith({
    GuestAdmissionPolicy? policy,
    GuestJoinRole? guestRole,
    bool? hasPasscode,
    String? guestUrl,
  }) =>
      GuestPolicyState(
        policy: policy ?? this.policy,
        guestRole: guestRole ?? this.guestRole,
        hasPasscode: hasPasscode ?? this.hasPasscode,
        guestUrl: guestUrl ?? this.guestUrl,
      );
}

class GuestJoinRequest {
  const GuestJoinRequest({
    required this.id,
    required this.displayName,
    this.createdAt,
  });

  final String id;
  final String displayName;
  final DateTime? createdAt;

  factory GuestJoinRequest.fromJson(Map<String, dynamic> j) => GuestJoinRequest(
        id: (j['id'] as String?) ?? '',
        displayName: (j['displayName'] as String?) ?? 'Guest',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? ''),
      );
}
