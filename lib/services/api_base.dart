// ApiBase — permanent DNS-failover base-URL resolver (added 2026-08-26).
//
// WHY: some ISP/home-router resolvers (observed: the HS8145C5's upstream)
// intermittently fail to resolve qurbanisahulat.com while resolving
// interactpak.com fine (errno 8 host-lookup failures; the authoritative
// zone itself is healthy — verified via DoH the same day). We cannot fix
// user routers or ISPs, so the app carries an ordered list of equivalent
// hosts for the SAME backend and fails over automatically.
//
// SERVER PREREQ: talk.interactpak.com must be an alias of the Talk backend
// (Caddy: add the host to the qurbanisahulat.com site block; DNS A →
// 178.105.73.238). See docs/runbooks/TALK_DNS_FAILOVER_2026-08-26.md.
//
// USAGE: every service reads `ApiBase.current` instead of a const host.
// Call `ApiBase.init()` once in main(); call `ApiBase.checkAndMaybeSwitch()`
// fire-and-forget from any network-failure catch (throttled internally).
// Prefer `ApiBase.runWithFailover` for one-shot GETs that must succeed
// against whichever host resolves (Chats list, message poll).
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class ApiBase {
  ApiBase._();

  /// Ordered candidates — first reachable wins. The dart-define override
  /// (staging/dev) stays first so existing build flags keep working.
  static const List<String> candidates = [
    String.fromEnvironment(
      'INTERACT_TALK_API_BASE',
      defaultValue: 'https://qurbanisahulat.com',
    ),
    'https://talk.interactpak.com',
  ];

  static String _current = candidates.first;
  static String get current => _current;

  static DateTime _lastProbe = DateTime.fromMillisecondsSinceEpoch(0);
  static bool _probing = false;

  /// Restore last-known-good base, then verify it in the background.
  static Future<void> init() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final saved = sp.getString('talk_api_base');
      if (saved != null && candidates.contains(saved)) _current = saved;
    } catch (_) {}
    unawaited(checkAndMaybeSwitch());
  }

  /// Persist [base] as current (must be a known candidate).
  static Future<void> _adopt(String base) async {
    if (_current == base) return;
    if (!candidates.contains(base)) return;
    _current = base;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('talk_api_base', base);
    } catch (_) {}
  }

  /// Probe current base; if unreachable, switch to the first reachable
  /// candidate and persist. Throttled to one probe per 30 s so it is safe
  /// to call from every network-failure catch and poll tick.
  /// Pass [force]: true from an explicit Retry so we don't wait out the
  /// throttle while the user is staring at a DNS error.
  static Future<void> checkAndMaybeSwitch({bool force = false}) async {
    if (_probing) return;
    if (!force && DateTime.now().difference(_lastProbe).inSeconds < 30) {
      return;
    }
    _probing = true;
    _lastProbe = DateTime.now();
    try {
      if (await _reachable(_current)) return;
      for (final c in candidates) {
        if (c == _current) continue;
        if (await _reachable(c)) {
          await _adopt(c);
          return;
        }
      }
    } finally {
      _probing = false;
    }
  }

  /// Run [op] against [current]; on DNS/offline, force-failover then retry
  /// once. [op] must read `ApiBase.current` (or `_kBase`) at call time — not
  /// capture a stale base URL.
  static Future<T> runWithFailover<T>(Future<T> Function() op) async {
    try {
      return await op();
    } catch (e) {
      if (!isDnsOrOffline(e)) rethrow;
      await checkAndMaybeSwitch(force: true);
      // If probe kept the same dead host (both down, or race), try each
      // alternate explicitly so a flaky apex doesn't block talk.* forever.
      final tried = <String>{_current};
      for (final c in candidates) {
        if (tried.contains(c)) continue;
        await _adopt(c);
        try {
          return await op();
        } catch (e2) {
          if (!isDnsOrOffline(e2)) rethrow;
          tried.add(c);
        }
      }
      rethrow;
    }
  }

  /// True when [error] looks like DNS / offline (errno 8 host lookup, etc.).
  static bool isDnsOrOffline(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('socketexception') ||
        s.contains('failed host lookup') ||
        (s.contains('clientexception') && s.contains('host lookup')) ||
        s.contains('network is unreachable') ||
        s.contains('nodename nor servname') ||
        s.contains('errno = 8') ||
        s.contains('connection timed out') ||
        s.contains('timed out');
  }

  static Future<bool> _reachable(String base) async {
    try {
      // Prefer /api/v1/health (200). Bare /api/health is 404 on Sahulat —
      // still <500, but the v1 route is the real liveness signal.
      final r = await http
          .get(Uri.parse('$base/api/v1/health'))
          .timeout(const Duration(seconds: 5));
      return r.statusCode < 500;
    } on SocketException {
      return false; // DNS or connect failure — the case we exist for
    } on TimeoutException {
      return false;
    } catch (_) {
      // TLS/HTTP-level oddity still means DNS + TCP worked — keep base.
      return true;
    }
  }
}
