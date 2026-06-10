// SPDX-License-Identifier: AGPL-3.0
//
// AppShell — bottom-nav scaffold. Tabs persist across pushes because
// this is a go_router ShellRoute parent. Order matches the research-
// backed PRD: Calls (default) → Chats → Contacts → Me.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/app_background.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.child});
  final Widget child;

  static const _tabs = <_TabItem>[
    _TabItem('/calls',    Icons.videocam_outlined,    Icons.videocam,    'Calls'),
    _TabItem('/chats',    Icons.chat_bubble_outline,  Icons.chat_bubble, 'Chats'),
    _TabItem('/contacts', Icons.people_outline,       Icons.people,      'Contacts'),
    _TabItem('/me',       Icons.person_outline,       Icons.person,      'Me'),
    _TabItem('/menu',     Icons.grid_view_outlined,   Icons.grid_view,   'Menu'),
  ];

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    // Exact match or a true sub-path (trailing slash) — so '/menu' doesn't
    // get captured by the '/me' prefix.
    final currentIndex = _tabs.indexWhere(
        (t) => location == t.path || location.startsWith('${t.path}/'));
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;
    return Scaffold(
      body: AppBackground(scrim: 0.70, child: child),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: (i) => context.go(_tabs[i].path),
        destinations: _tabs
            .map((t) => NavigationDestination(
                  icon: Icon(t.icon),
                  selectedIcon: Icon(t.activeIcon),
                  label: t.label,
                ))
            .toList(),
      ),
    );
  }
}

class _TabItem {
  const _TabItem(this.path, this.icon, this.activeIcon, this.label);
  final String path;
  final IconData icon;
  final IconData activeIcon;
  final String label;
}
