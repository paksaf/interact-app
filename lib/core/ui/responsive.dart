import 'package:flutter/material.dart';

/// Layout helpers for phone vs tablet widths.
///
/// Ported from `interact-lifestyle/mobile/lib/core/ui/responsive.dart`
/// (`IlAdaptiveNavScaffold`). A landscape-mounted car head-unit tablet
/// (typically 8"-12", 1280x720 or larger) reports a width well past
/// [tablet] here, so it is covered by the same "tablet" bucket used for
/// iPads/Android tablets — no separate device class is needed.
class TalkBreakpoints {
  TalkBreakpoints._();

  static const double tablet = 600;
  static const double largeTablet = 900;
}

bool isTabletWidth(double maxWidth) => maxWidth >= TalkBreakpoints.tablet;

bool isLargeTabletWidth(double maxWidth) =>
    maxWidth >= TalkBreakpoints.largeTablet;

/// Adaptive primary navigation chrome: bottom [NavigationBar] on phone-width
/// screens, side [NavigationRail] on tablet-width+ screens (car tablets,
/// iPads, Android tablets, wide Android TV displays).
class TalkAdaptiveNavScaffold extends StatelessWidget {
  const TalkAdaptiveNavScaffold({
    super.key,
    this.appBar,
    required this.body,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.labelBehavior = NavigationDestinationLabelBehavior.alwaysShow,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final NavigationDestinationLabelBehavior labelBehavior;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!isTabletWidth(constraints.maxWidth)) {
          return Scaffold(
            appBar: appBar,
            body: body,
            bottomNavigationBar: NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: onDestinationSelected,
              labelBehavior: labelBehavior,
              destinations: destinations,
            ),
          );
        }

        final bool extended = isLargeTabletWidth(constraints.maxWidth);
        return Scaffold(
          appBar: appBar,
          body: Row(
            children: <Widget>[
              NavigationRail(
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                extended: extended,
                labelType: extended ? null : NavigationRailLabelType.all,
                destinations: <NavigationRailDestination>[
                  for (final NavigationDestination d in destinations)
                    NavigationRailDestination(
                      icon: d.icon,
                      selectedIcon: d.selectedIcon,
                      label: Text(d.label),
                    ),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }
}
