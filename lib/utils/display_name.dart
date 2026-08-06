// SPDX-License-Identifier: AGPL-3.0
//
// display_name — client-side name resolution. The shared Talk backend labels
// a peer generically ("Talk 1469") when their account has no display name set.
// These helpers pick the best human name we can show WITHOUT any new network
// call: a device-book name for the peer's phone first, then a real name from
// the backend payload, then the phone, and only as a last resort the generic
// "Talk <n>" placeholder. Display-only + defensive — never throws.

/// A backend placeholder rather than a real name: empty, "Untitled",
/// "Talk 1469" / "Talk #1469", or just the peer's phone number.
final RegExp _kGenericTalk =
    RegExp(r'^\s*talk\s*#?\s*\d+\s*$', caseSensitive: false);

bool isGenericPeerName(String? name, {String? phone}) {
  final n = (name ?? '').trim();
  if (n.isEmpty) return true;
  if (n.toLowerCase() == 'untitled') return true;
  if (_kGenericTalk.hasMatch(n)) return true;
  if (phone != null && phone.trim().isNotEmpty && n == phone.trim()) return true;
  return false;
}

/// Best display name in priority order:
///  1. [deviceName] — the phone address-book name for this peer (when present)
///  2. [crmName]    — a name matched from the INTERACT CRM (Phase 3, cached +
///                    async-resolved; null when unknown/unmatched/feature-off)
///  3. [backendName] — when it's a real name (not a "Talk <n>" placeholder)
///  4. [phone] — the number itself (more useful than "Talk 1469")
///  5. [backendName] — generic placeholder, last resort
///  6. `'Unknown'`
///
/// [crmName] is optional and defaults to null, so existing callers that don't
/// pass it are unaffected.
String resolveDisplayName({
  String? deviceName,
  String? crmName,
  String? backendName,
  String? phone,
}) {
  final dn = deviceName?.trim();
  if (dn != null && dn.isNotEmpty) return dn;
  final cn = crmName?.trim();
  if (cn != null && cn.isNotEmpty && !isGenericPeerName(cn, phone: phone)) {
    return cn;
  }
  final bn = backendName?.trim();
  if (bn != null && bn.isNotEmpty && !isGenericPeerName(bn, phone: phone)) {
    return bn;
  }
  final p = phone?.trim();
  if (p != null && p.isNotEmpty) return p;
  if (bn != null && bn.isNotEmpty) return bn; // generic placeholder
  return 'Unknown';
}
