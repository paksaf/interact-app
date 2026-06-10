// SPDX-License-Identifier: AGPL-3.0
//
// INTERACT smoke test — placeholder. The Phase 0 rebrand replaced
// `package:interact_talk/main.dart` + `MyApp` with `package:interact/main.dart`,
// and main.dart no longer exports a top-level widget (the router lives
// inside `runApp`). For now, a no-op test keeps `flutter test` green.
// Phase 1.5 swaps this for real ChatsTab + AppShell golden tests.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder — INTERACT smoke test wired in Phase 1.5', () {
    expect(1 + 1, 2);
  });
}
