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

  test('video kind and recent story window', () {
    final video = SocialPost(
      id: 'v1',
      authorId: 'u1',
      authorName: 'Sara',
      audience: SocialAudience.family,
      kind: SocialPostKind.video,
      body: 'Clip',
      mediaPath: '/tmp/clip.mp4',
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
    );
    expect(video.isVideo, isTrue);
    expect(video.isRecentStory, isTrue);
    expect(SocialPostKind.fromWire('video'), SocialPostKind.video);
  });
}
