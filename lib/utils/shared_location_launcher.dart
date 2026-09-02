// SPDX-License-Identifier: AGPL-3.0
//
// Open a shared location pin in Interact Maps or system maps.

import 'package:url_launcher/url_launcher.dart';

import 'shared_location_pin.dart';

/// Opens navigation for [pin]. Tries interactmaps://, then Google Maps web.
Future<bool> openSharedLocationPin(SharedLocationPin pin) async {
  final candidates = <Uri>[
    if (pin.mapsDeepLink != null) pin.mapsDeepLink!,
    Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=${pin.lat},${pin.lng}',
    ),
    if (pin.talkFallback != null) pin.talkFallback!,
  ];

  for (final uri in candidates) {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      return true;
    }
  }
  return false;
}
