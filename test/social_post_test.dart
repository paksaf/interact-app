// SPDX-License-Identifier: AGPL-3.0

import 'package:flutter_test/flutter_test.dart';
import 'package:interact/models/social_post.dart';

void main() {
  test('SocialPost round-trips JSON', () {
    final post = SocialPost(
      id: 'p1',
      authorId: 'u1',
      authorName: 'Sara',
      audience: SocialAudience.family,
      kind: SocialPostKind.status,
      body: 'Eid Mubarak!',
      createdAt: DateTime.utc(2026, 9, 2, 12),
    );
    final restored = SocialPost.fromJson(post.toJson());
    expect(restored.id, 'p1');
    expect(restored.audience, SocialAudience.family);
    expect(restored.body, 'Eid Mubarak!');
  });
}
