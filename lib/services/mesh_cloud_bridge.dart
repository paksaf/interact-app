// SPDX-License-Identifier: AGPL-3.0
//
// Offline-frame decoder for LOCAL display. INBOUND ONLY, and it never sends.
//
// ── Why this file no longer forwards to cloud (2026-09-01 security fix) ──
//
// Until now this bridge re-injected every inbound LAN/BLE frame into Talk
// chat using the LOCAL USER'S credentials (ChatApi.sendText /
// createDirectThread). Because `lan_service` fed it every unauthenticated
// inbound TCP frame and `nearby_mesh_screen` every BLE frame, ANY device on
// the same Wi-Fi or in BLE range could make the victim's phone send an
// attacker-chosen message to an attacker-chosen number, AS the victim. A
// classic confused-deputy hole: the app's authority used for the sender's
// intent. Ed25519 signing in sahl_mesh does not help — it proves frame
// integrity, not authorisation, and any node can mint an identity.
//
// The send path is now REMOVED, not merely disabled — there is no flag to
// flip it back on. Inbound frames are rendered LOCALLY, attributed to the
// mesh sender. A relay that re-posts a mesh message to cloud attributed to
// the ORIGINAL sender (not the local user) is future work: it needs paired,
// trusted mesh identities AND a backend attribution concept (Sahulat, frozen).
// See docs/OFFLINE_BEARERS_AUDIT_2026-09-01.md §3 (audit step 6). Do NOT
// reintroduce a local-user send here.

/// Static-only utility (all members static) — not instantiated.
class MeshCloudBridge {
  /// Strip the `talk:` envelope from an inbound frame for LOCAL display.
  /// Returns the human-readable text, or null if [raw] is not a talk frame
  /// (or carries no text). NEVER sends — inbound frames stay on this device.
  ///
  /// Envelopes understood (all rendered the same way — as their text):
  ///   talk:1|<threadId>|<text>
  ///   talk:0|<phone>|<text>     (recipient hint ignored on inbound by design)
  ///   talk:<free text>
  static String? plainBody(String raw) {
    if (!raw.startsWith('talk:')) return null;
    var body = raw.substring(5);
    if (body.startsWith('1|') || body.startsWith('0|')) {
      final rest = body.substring(2);
      final sep = rest.indexOf('|');
      if (sep >= 0) body = rest.substring(sep + 1);
    }
    final t = body.trim();
    return t.isEmpty ? null : t;
  }

  /// Encode an OUTBOUND mesh frame for a known thread. Outbound is
  /// user-initiated and safe; only the inbound auto-send was the hole.
  static String encodeForThread(String threadId, String text) =>
      'talk:1|$threadId|${text.trim()}';
}
