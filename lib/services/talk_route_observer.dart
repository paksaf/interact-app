// SPDX-License-Identifier: AGPL-3.0
//
// GoRouter screen_view tracking — path only, no query params.

import 'package:flutter/material.dart';

import 'analytics_service.dart';

class TalkRouteObserver extends NavigatorObserver {
  TalkRouteObserver._();
  static final TalkRouteObserver instance = TalkRouteObserver._();

  void _track(Route<dynamic>? route) {
    if (route == null) return;
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) {
      AnalyticsService.instance.trackScreenView(name);
      return;
    }
    // Fallback: strip "MaterialPageRoute<…>(…)" noise if ever present.
    final s = route.settings.toString();
    if (s.contains('/')) {
      final i = s.indexOf('/');
      final path = s.substring(i).split("'").first.split(')').first;
      AnalyticsService.instance.trackScreenView(path);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _track(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _track(previousRoute);
  }
}

/// Tracks shell tab changes (GoRouter doesn't always push a new route).
void trackShellPath(String path) {
  AnalyticsService.instance.trackScreenView(path);
}
