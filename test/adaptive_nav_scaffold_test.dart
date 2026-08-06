// SPDX-License-Identifier: AGPL-3.0
//
// Adaptive nav scaffold — phone bottom bar vs tablet rail.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interact/core/ui/responsive.dart';

void main() {
  const destinations = <NavigationDestination>[
    NavigationDestination(
      icon: Icon(Icons.videocam_outlined),
      selectedIcon: Icon(Icons.videocam),
      label: 'Calls',
    ),
    NavigationDestination(
      icon: Icon(Icons.chat_bubble_outline),
      selectedIcon: Icon(Icons.chat_bubble),
      label: 'Chats',
    ),
  ];

  Widget buildScaffold() {
    return MaterialApp(
      home: TalkAdaptiveNavScaffold(
        body: const Center(child: Text('body')),
        destinations: destinations,
        selectedIndex: 0,
        onDestinationSelected: (_) {},
      ),
    );
  }

  testWidgets('shows bottom NavigationBar below tablet breakpoint',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildScaffold());
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('shows NavigationRail at tablet width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(720, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildScaffold());
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('extends NavigationRail at large tablet width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(buildScaffold());
    final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
    expect(rail.extended, isTrue);
  });
}
