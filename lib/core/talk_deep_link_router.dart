// SPDX-License-Identifier: AGPL-3.0
//
// Map external Talk URIs → in-app GoRouter locations. Pure + static for tests.

class TalkDeepLinkRouter {
  TalkDeepLinkRouter._();

  static final _uuidRe = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  /// Returns an in-app path (e.g. `/reel/uuid`) or null when not handled.
  static String? routeFor(Uri u) {
    final reel = _reelPath(u);
    if (reel != null) return reel;

    final approve = _approveLoginPath(u);
    if (approve != null) return approve;

    // interact://j/<CODE>
    if (u.scheme == 'interact' && u.host == 'j') {
      final code = u.pathSegments.isNotEmpty
          ? u.pathSegments.first
          : u.path.replaceAll('/', '');
      if (code.isNotEmpty) return '/j/${code.toUpperCase()}';
    }
    // interact:///j/<CODE> (empty host)
    if (u.scheme == 'interact' && u.path.startsWith('/j/')) {
      final code = u.path.substring(3).split('/').first;
      if (code.isNotEmpty) return '/j/${code.toUpperCase()}';
    }
    // https://talk.interactpak.com/j/<CODE>
    if ((u.scheme == 'https' || u.scheme == 'http') &&
        (u.host == 'talk.interactpak.com' || u.host == 'interactpak.com')) {
      if (u.path.startsWith('/j/')) {
        final code = u.path.substring(3).split('/').first;
        if (code.isNotEmpty) {
          if (code.toUpperCase() == 'LOC' &&
              u.queryParameters['lat'] != null &&
              u.queryParameters['lng'] != null) {
            return '/j/LOC?lat=${u.queryParameters['lat']}&lng=${u.queryParameters['lng']}';
          }
          return '/j/${code.toUpperCase()}';
        }
      }
      if (u.path.isEmpty || u.path == '/') return '/';
      return u.path;
    }
    return null;
  }

  static String? _reelPath(Uri u) {
    String? id;
    if (u.scheme == 'interact' && u.host == 'talk') {
      final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2 && segs.first == 'reel') {
        id = segs[1];
      }
    }
    if ((u.scheme == 'https' || u.scheme == 'http') &&
        u.host == 'talk.interactpak.com' &&
        u.pathSegments.length >= 2 &&
        u.pathSegments.first == 'reel') {
      id = u.pathSegments[1];
    }
    if (id != null && _uuidRe.hasMatch(id)) return '/reel/$id';
    return null;
  }

  static String? _approveLoginPath(Uri u) {
    if (u.scheme != 'interact' || u.host != 'talk') return null;
    final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
    final isApprove =
        u.path == '/approve-login' ||
        (segs.isNotEmpty && segs.first == 'approve-login');
    if (!isApprove) return null;
    final q = u.query;
    return q.isEmpty ? '/approve-login' : '/approve-login?$q';
  }
}
