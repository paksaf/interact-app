// SPDX-License-Identifier: AGPL-3.0
//
// Pakistan-first phone → E.164 (mirrors interactpak-nextjs/src/lib/phone-e164.ts).
String? normalizeInteractPhone(String raw) {
  final digits = raw.replaceAll(RegExp(r'[\s\-()]'), '');
  if (digits.isEmpty) return null;

  if (digits.startsWith('+92') ||
      digits.startsWith('92') ||
      digits.startsWith('0')) {
    var rest = digits;
    if (rest.startsWith('+92')) {
      rest = rest.substring(3);
    } else if (rest.startsWith('92') && rest.length >= 12) {
      rest = rest.substring(2);
    } else if (rest.startsWith('0')) {
      rest = rest.substring(1);
    }
    if (RegExp(r'^3\d{9}$').hasMatch(rest)) return '+92$rest';
  }

  if (digits.startsWith('+') && RegExp(r'^\+\d{8,15}$').hasMatch(digits)) {
    return digits;
  }
  return null;
}

bool isPlausibleEmail(String raw) {
  final e = raw.trim().toLowerCase();
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e);
}
