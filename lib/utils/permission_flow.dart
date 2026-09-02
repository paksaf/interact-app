// SPDX-License-Identifier: AGPL-3.0
//
// Sequential permission requests. permission_handler's `[a, b, c].request()`
// fires the whole list at once, so on iOS especially the native dialogs stack
// on top of each other in the same instant — the user can't read or decide one
// before the next covers it. requestSequentially() asks for them ONE AT A TIME,
// awaiting each answer and leaving a short gap so the OS dismisses the previous
// sheet before the next appears. Returns the same
// Map<Permission, PermissionStatus> shape as the batched call, so it's a
// drop-in replacement. Added 2026-09-02.
import 'package:permission_handler/permission_handler.dart';

Future<Map<Permission, PermissionStatus>> requestSequentially(
  List<Permission> permissions, {
  Duration gap = const Duration(milliseconds: 350),
}) async {
  final result = <Permission, PermissionStatus>{};
  for (var i = 0; i < permissions.length; i++) {
    final p = permissions[i];
    // Already-decided permissions never show a dialog — record and skip the
    // gap so we only pace the prompts the user will actually see.
    final current = await p.status;
    if (current.isGranted || current.isPermanentlyDenied || current.isRestricted) {
      result[p] = current;
      continue;
    }
    result[p] = await p.request();
    if (i < permissions.length - 1) await Future<void>.delayed(gap);
  }
  return result;
}
