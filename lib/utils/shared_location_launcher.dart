// SPDX-License-Identifier: AGPL-3.0
//
// Open a shared location pin — INTERACT in-app map first, then Interact Maps
// app, then platform maps (Apple Maps on iOS, geo:/Google on Android).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import 'shared_location_pin.dart';

/// Opens [pin] in the best available maps surface.
/// Returns true when something opened successfully.
Future<bool> openSharedLocationPin(SharedLocationPin pin) async {
  for (final uri in _externalCandidates(pin)) {
    if (await _tryLaunch(uri)) return true;
  }
  return false;
}

/// Bottom sheet: INTERACT friends map (in-app) first, then external apps.
Future<void> showLocationOpenSheet(
  BuildContext context,
  SharedLocationPin pin,
) async {
  final cs = Theme.of(context).colorScheme;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              pin.label ?? 'Location',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              pin.coordsLabel,
              style: TextStyle(color: cs.outline, fontSize: 12.5),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/friends-map');
              },
              icon: const Icon(Icons.map_rounded),
              label: const Text('Open in INTERACT Map'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(ctx);
                final ok = await openSharedLocationPin(pin);
                if (ctx.mounted && !ok) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(
                      content: Text('Could not open an external maps app.'),
                    ),
                  );
                }
              },
              icon: Icon(
                Platform.isIOS ? Icons.apple : Icons.navigation_outlined,
              ),
              label: Text(
                Platform.isIOS ? 'Open in Apple Maps' : 'Open in Maps app',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

List<Uri> _externalCandidates(SharedLocationPin pin) {
  final lat = pin.lat;
  final lng = pin.lng;
  final label = Uri.encodeComponent(pin.label ?? 'Shared pin');
  final out = <Uri>[];

  if (pin.mapsDeepLink != null) {
    out.add(pin.mapsDeepLink!);
  }

  if (Platform.isIOS) {
    out.add(Uri.parse('maps://?ll=$lat,$lng&q=$label'));
    out.add(Uri.parse('http://maps.apple.com/?ll=$lat,$lng&q=$label'));
  } else if (Platform.isAndroid) {
    out.add(Uri.parse('geo:$lat,$lng?q=$lat,$lng($label)'));
    out.add(Uri.parse('google.navigation:q=$lat,$lng'));
    out.add(
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
    );
  } else {
    out.add(
      Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'),
    );
  }

  if (pin.talkFallback != null) out.add(pin.talkFallback!);
  return out;
}

Future<bool> _tryLaunch(Uri uri) async {
  try {
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  } catch (_) {}
  return false;
}
