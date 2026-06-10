// SPDX-License-Identifier: AGPL-3.0
//
// AppBackground — full-bleed branded gradient backdrop for INTERACT.
// Art ships at `assets/backgrounds/app_bg.png` (declared in pubspec); this
// paints it cover-fit behind a screen, with a [scrim] veil for legibility.
//
// INTERACT wires this at the ShellRoute level (behind all tabs), so the tab
// Scaffolds are made transparent and a HEAVY scrim (~0.70) keeps the dense
// call/chat/contact lists readable — the gradient reads as a faint tint.
import 'package:flutter/material.dart';

class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.child,
    this.scrim = 0.0,
    this.scrimColor,
    this.asset = 'assets/backgrounds/app_bg.png',
  });

  final Widget child;
  final double scrim;
  final Color? scrimColor;
  final String asset;

  @override
  Widget build(BuildContext context) {
    final veil = scrim.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        image: DecorationImage(
          image: AssetImage(asset),
          fit: BoxFit.cover,
        ),
      ),
      child: veil <= 0
          ? child
          : ColoredBox(
              color: (scrimColor ?? Theme.of(context).colorScheme.surface)
                  .withValues(alpha: veil),
              child: child,
            ),
    );
  }
}
