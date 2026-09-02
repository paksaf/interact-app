// SPDX-License-Identifier: AGPL-3.0
//
// Map-style bubble for shared GPS pins in chat threads.
// Donor patterns: sahulat-app flutter_map (static OSM tile here to avoid
// new deps), interact-app _AttachmentView launchUrl pattern.

import 'package:flutter/material.dart';

import '../../utils/shared_location_launcher.dart';
import '../../utils/shared_location_pin.dart';

class LocationPinBubble extends StatelessWidget {
  const LocationPinBubble({
    super.key,
    required this.pin,
    required this.foreground,
    required this.mutedForeground,
  });

  final SharedLocationPin pin;
  final Color foreground;
  final Color mutedForeground;

  Future<void> _open(BuildContext context) async {
    final ok = await openSharedLocationPin(pin);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open Maps for this pin.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  Image.network(
                    pin.previewTileUrl,
                    width: 220,
                    height: 120,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 220,
                      height: 120,
                      color: mutedForeground.withValues(alpha: 0.15),
                      alignment: Alignment.center,
                      child: Icon(Icons.map_outlined, color: mutedForeground),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: Icon(
                        Icons.location_on,
                        color: Colors.red.shade700,
                        size: 32,
                        shadows: const [
                          Shadow(color: Colors.white, blurRadius: 4),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (pin.live)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 8, color: Colors.red.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Live · tap to navigate',
                      style: TextStyle(
                        color: Colors.red.shade700,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.near_me_outlined, size: 16, color: foreground),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    pin.coordsLabel,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Tap to open in Maps',
              style: TextStyle(color: mutedForeground, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
