// SPDX-License-Identifier: AGPL-3.0
//
// BrandedAppBar — the single header shared across every tab so the app reads
// as one surface. AppShell already paints AppBackground(scrim: .70) behind
// all tabs, so this header stays fully transparent (no fill, no elevation)
// and lets the teal-navy→gold gradient flow edge to edge behind it. An
// optional brand glyph (the icon's voice-waveform mark on a teal→gold chip)
// anchors the wordmark; a soft "large title" variant gives Calls/Chats a
// modern, breathing header instead of the flat default AppBar.
import 'package:flutter/material.dart';

class BrandedAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandedAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    this.showBrandGlyph = false,
    this.bottom,
  });

  final String title;
  final String? subtitle;
  final List<Widget>? actions;
  final bool showBrandGlyph;
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize => Size.fromHeight(
        (subtitle == null ? kToolbarHeight : kToolbarHeight + 14) +
            (bottom?.preferredSize.height ?? 0),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppBar(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: showBrandGlyph ? 16 : null,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showBrandGlyph) ...[
            _BrandGlyph(cs: cs),
            const SizedBox(width: 11),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                  height: 1.05,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: cs.outline,
                    height: 1.1,
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: actions,
      bottom: bottom,
    );
  }
}

/// The teal→gold rounded chip carrying the voice-waveform mark — a compact
/// echo of the launcher icon so the header self-identifies as INTERACT.
class _BrandGlyph extends StatelessWidget {
  const _BrandGlyph({required this.cs});
  final ColorScheme cs;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary, cs.secondary],
        ),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.28),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: const Icon(Icons.graphic_eq_rounded, size: 18, color: Colors.white),
    );
  }
}
