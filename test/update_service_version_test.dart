import 'package:flutter_test/flutter_test.dart';
import 'package:interact/services/update_service.dart';

void main() {
  group('isRemoteReleaseNewer', () {
    test('same name + same build → no update', () {
      expect(
        isRemoteReleaseNewer(
          localName: '0.5.5',
          localBuild: 6043,
          remoteName: '0.5.5',
          remoteBuild: 6043,
        ),
        isFalse,
      );
    });

    test('same name + higher remote build → update', () {
      expect(
        isRemoteReleaseNewer(
          localName: '0.5.5',
          localBuild: 6043,
          remoteName: '0.5.5',
          remoteBuild: 6044,
        ),
        isTrue,
      );
    });

    test('higher remote name → update even if build looks smaller', () {
      // Guards Flutter abi*1000+N inflation (local arm64 split 8043 vs CDN 6044).
      expect(
        isRemoteReleaseNewer(
          localName: '0.5.5',
          localBuild: 8043,
          remoteName: '0.5.6',
          remoteBuild: 6044,
        ),
        isTrue,
      );
    });

    test('same name + lower remote build → no update (no downgrade nag)', () {
      expect(
        isRemoteReleaseNewer(
          localName: '0.5.5',
          localBuild: 8043,
          remoteName: '0.5.5',
          remoteBuild: 6043,
        ),
        isFalse,
      );
    });

    test('unreadable local build → no update (fail closed)', () {
      expect(
        isRemoteReleaseNewer(
          localName: '0.5.5',
          localBuild: 0,
          remoteName: '0.5.5',
          remoteBuild: 6043,
        ),
        isFalse,
      );
    });

    test('empty local name → no update (fail closed / MIUI cold frame)', () {
      expect(
        isRemoteReleaseNewer(
          localName: '',
          localBuild: 6043,
          remoteName: '0.5.5',
          remoteBuild: 6044,
        ),
        isFalse,
      );
    });
  });
}
