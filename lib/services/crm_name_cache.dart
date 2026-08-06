// SPDX-License-Identifier: AGPL-3.0
//
// CrmNameCache — opportunistic, TTL-cached `phone → CRM name` layer for INTERACT
// Talk (Phase 3). It sits BETWEEN the device address book and the backend's
// generic label in the display-name priority order:
//
//   device contact → CRM resolve (this) → backend name → phone → generic → Unknown
//
// Design:
//   - Sync `nameFor(phone)` returns a cached name (or null) so it can be called
//     at render time without ever blocking the UI.
//   - Async `ensureResolved(phones)` batches the not-yet-known numbers, calls
//     TalkApi.resolveCrmNames() (hash-only, JWT'd, rate-limited server side),
//     and fills the cache with a TTL. Negative results are cached too (short
//     TTL) so we don't hammer the endpoint for numbers with no CRM match.
//   - Fail-soft everywhere: any error leaves the cache unchanged and callers
//     keep whatever name they already had. Feature is a no-op until the pepper
//     is provisioned (TalkApi.resolveCrmNames returns {} then).
//
// v2 hardening (2026-07-31): TTLs (12h positive / 30m negative) already satisfy
// the review's freshness ask — left as-is. Cache SIGNING/encryption at rest is
// DEFERRED (this cache is in-memory only and holds just names, no numbers).
// resolveCrmNames now hashes with HMAC (v2) but its signature is unchanged, so
// nothing here needed to change beyond this note.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'talk_api.dart';

class _Entry {
  _Entry(this.name, this.at);
  final String? name; // null = resolved-but-no-match (negative cache)
  final DateTime at;
}

class CrmNameCache {
  CrmNameCache(this._api);
  final TalkApi _api;

  // Positive matches live longer than negatives (a name rarely changes; a
  // missing number might get added to the CRM soon).
  static const _positiveTtl = Duration(hours: 12);
  static const _negativeTtl = Duration(minutes: 30);

  final Map<String, _Entry> _byE164 = {};
  final Set<String> _inflight = {}; // e164s currently being resolved

  // "Suggest to CRM" — locally queued unmatched numbers the user labelled.
  // Intentionally a local stub: we NEVER auto-write the CRM. A future admin
  // review flow can drain this. Kept minimal to avoid scope creep.
  final List<({String phone, String name})> _suggestions = [];

  bool _fresh(_Entry e) {
    final ttl = e.name != null ? _positiveTtl : _negativeTtl;
    return DateTime.now().difference(e.at) < ttl;
  }

  /// Cached CRM name for [phone], or null when unknown / expired / no match.
  /// Synchronous — safe at render time. Does NOT trigger a network call.
  String? nameFor(String? phone) {
    if (phone == null || phone.isEmpty) return null;
    final e164 = normalizePkPhoneClient(phone);
    if (e164 == null) return null;
    final e = _byE164[e164];
    if (e == null || !_fresh(e)) return null;
    return e.name;
  }

  /// Resolve any of [phones] we don't already have fresh, caching the results.
  /// Best-effort + fail-soft; returns the count of NEW positive matches so a
  /// caller can `setState` only when something actually changed.
  Future<int> ensureResolved(Iterable<String> phones) async {
    final need = <String>[];
    for (final p in phones) {
      final e164 = normalizePkPhoneClient(p);
      if (e164 == null) continue;
      final e = _byE164[e164];
      if (e != null && _fresh(e)) continue; // already known
      if (_inflight.contains(e164)) continue; // being fetched
      need.add(e164);
    }
    if (need.isEmpty) return 0;
    _inflight.addAll(need);
    var added = 0;
    try {
      final resolved = await _api.resolveCrmNames(need);
      final now = DateTime.now();
      for (final e164 in need) {
        final name = resolved[e164];
        if (name != null && name.isNotEmpty) {
          _byE164[e164] = _Entry(name, now);
          added++;
        } else {
          _byE164[e164] = _Entry(null, now); // negative cache
        }
      }
    } catch (_) {
      // Fail-soft — leave the cache as-is; a later call can retry.
    } finally {
      _inflight.removeAll(need);
    }
    return added;
  }

  /// Suggest a name for an unmatched number to the ADMIN-REVIEWED CRM flow, and
  /// seed the local cache so the label shows immediately. This does NOT write
  /// the CRM directly (CRM is read-only) — it POSTs a `TalkCrmSuggestion` for
  /// an admin to approve/reject. Fail-soft: returns false on any submit error
  /// (the local label is still seeded so the UI feels responsive).
  ///
  /// [org]/[note]/[callId]/[summaryId] are optional context passed straight to
  /// the endpoint. [summaryText] defaults to a short synthesized line when the
  /// suggestion is just "this number is <name>" (a contact, not a call summary).
  Future<bool> suggestToCrm(
    String phone,
    String name, {
    String? org,
    String? note,
    String? summaryText,
    String? callId,
    String? summaryId,
  }) async {
    final e164 = normalizePkPhoneClient(phone);
    if (e164 == null || name.trim().isEmpty) return false;
    // Seed the local cache + queue optimistically so the label appears now.
    _suggestions.add((phone: e164, name: name.trim()));
    _byE164[e164] = _Entry(name.trim(), DateTime.now());
    return _api.suggestToCrm(
      contactName: name.trim(),
      summaryText: (summaryText != null && summaryText.trim().isNotEmpty)
          ? summaryText.trim()
          : 'Contact suggestion: $e164 is "${name.trim()}".',
      contactOrg: org,
      note: note,
      callId: callId,
      summaryId: summaryId,
    );
  }

  /// Pending local "suggest to CRM" entries (read-only snapshot).
  List<({String phone, String name})> get pendingSuggestions =>
      List.unmodifiable(_suggestions);
}

final crmNameCacheProvider =
    Provider<CrmNameCache>((ref) => CrmNameCache(ref.read(talkApiProvider)));
