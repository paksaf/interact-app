// SPDX-License-Identifier: AGPL-3.0
//
// Cold + warm deep links for Talk (reels, join codes, approve-login).

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import 'talk_deep_link_router.dart';

class TalkDeepLinkService {
  TalkDeepLinkService._();
  static final TalkDeepLinkService instance = TalkDeepLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  void Function(String location)? _onRoute;
  bool _started = false;
  String? _pendingLocation;

  String? peekPendingLocation() => _pendingLocation;

  String? takePendingLocation() {
    final loc = _pendingLocation;
    _pendingLocation = null;
    return loc;
  }

  Future<void> init(void Function(String location) onRoute) async {
    _onRoute = onRoute;
    if (_started) return;
    _started = true;

    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _store(initial);
    } catch (e) {
      debugPrint('[TalkDeepLink] initial failed: $e');
    }

    try {
      _sub = _appLinks.uriLinkStream.listen(
        _storeAndNavigate,
        onError: (Object e) => debugPrint('[TalkDeepLink] stream error: $e'),
      );
    } catch (e) {
      debugPrint('[TalkDeepLink] stream failed: $e');
    }
  }

  void _store(Uri uri) {
    final loc = TalkDeepLinkRouter.routeFor(uri);
    if (loc != null) _pendingLocation = loc;
  }

  void _storeAndNavigate(Uri uri) {
    final loc = TalkDeepLinkRouter.routeFor(uri);
    if (loc == null) return;
    _pendingLocation = loc;
    _onRoute?.call(loc);
  }
}
