// SPDX-License-Identifier: AGPL-3.0
//
// DeviceContactsIndex — a read-only, permission-gated map of the phone's
// address book (phone → display name) used ONLY to give a real name to peers
// the shared Talk backend labelled generically ("Talk 1469").
//
// Privacy + safety (Phase 1, no new native plugins / no new prompts):
//   - NEVER prompts. We check `Permission.contacts.status` (which does NOT
//     show a dialog); if contacts access isn't ALREADY granted we stay empty.
//     The address-book permission dialog only ever appears on the
//     user-initiated DeviceContactsScreen ("Invite from contacts").
//   - Read-only — nothing is written back or uploaded.
//   - Fails soft: any error (permission, plugin, parse) leaves the index empty
//     and callers simply keep the backend name. Never throws into the UI.
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

class DeviceContactsIndex {
  final Map<String, String> _byPhone = {};
  // Name → ORIGINAL phone number entries, for the reverse lookup used by the
  // voice assistant ("call Ahmed"). We keep the original number string (not
  // the last-10 match key) so it round-trips through the server's E.164
  // normalization correctly.
  final List<({String name, String phone})> _entries = [];
  bool _loaded = false;
  Future<void>? _loading;

  /// Match key = last 10 digits, so `03XX-XXXXXXX`, `+923XXXXXXXXX`, and
  /// `00923XXXXXXXXX` all collapse onto the same entry regardless of how the
  /// address book or the backend formatted the number.
  static String? _key(String? phone) {
    if (phone == null) return null;
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return null;
    return digits.length <= 10
        ? digits
        : digits.substring(digits.length - 10);
  }

  /// Populate the index once, ONLY if contacts permission is already granted.
  /// Idempotent + concurrency-safe. If permission isn't granted we leave the
  /// index unloaded so a later call (e.g. after the user grants access on the
  /// invite screen) can retry — the status check is cheap and prompt-free.
  Future<void> ensureLoaded() {
    if (_loaded) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final status = await Permission.contacts.status;
      if (!status.isGranted) return; // stay unloaded — retry allowed, no prompt
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withPhoto: false,
      );
      for (final c in contacts) {
        final name = c.displayName.trim();
        if (name.isEmpty) continue;
        for (final p in c.phones) {
          final k = _key(p.number);
          if (k != null) _byPhone.putIfAbsent(k, () => name);
          final raw = p.number.trim();
          if (raw.isNotEmpty) _entries.add((name: name, phone: raw));
        }
      }
      _loaded = true;
    } catch (_) {
      // Fail soft — index stays empty, UI keeps the backend name.
    } finally {
      _loading = null;
    }
  }

  /// Device-book display name for [phone], or null when unknown / no
  /// permission. Synchronous so it can be called at render time.
  String? nameFor(String? phone) {
    final k = _key(phone);
    if (k == null) return null;
    return _byPhone[k];
  }

  /// Reverse lookup — the original phone number for a name [query], or null
  /// when unknown / no permission. Best match order: exact name → any
  /// whitespace token equal to the query → name starts-with → name contains.
  /// Read-only + synchronous; never prompts, never throws. Used by the voice
  /// assistant to resolve "call <name>" when the query isn't already a recent
  /// Talk contact.
  String? phoneForName(String? query) {
    final q = query?.trim().toLowerCase();
    if (q == null || q.length < 2) return null;
    ({String name, String phone})? tokenHit, startsHit, containsHit;
    for (final e in _entries) {
      final n = e.name.toLowerCase();
      if (n == q) return e.phone; // exact — best possible
      final tokens = n.split(RegExp(r'\s+'));
      if (tokenHit == null && tokens.contains(q)) tokenHit = e;
      if (startsHit == null && n.startsWith(q)) startsHit = e;
      if (containsHit == null && n.contains(q)) containsHit = e;
    }
    return (tokenHit ?? startsHit ?? containsHit)?.phone;
  }
}

final deviceContactsIndexProvider =
    Provider<DeviceContactsIndex>((ref) => DeviceContactsIndex());
