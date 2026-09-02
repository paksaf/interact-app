// SPDX-License-Identifier: AGPL-3.0
//
// Best-effort LAN IPv4 for offline RF screens. Used when mDNS discovery fails
// (common on iOS until Local Network permission is granted) — host shows IP,
// joiner can connect by address.

import 'dart:io';

/// Returns this device's primary Wi‑Fi/LAN IPv4, or null if unavailable.
Future<String?> primaryLanIPv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    String? fallback;
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (name == 'lo0' ||
          name.startsWith('utun') ||
          name.startsWith('bridge') ||
          name.contains('awdl')) {
        continue;
      }
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.isLoopback || ip.startsWith('169.254.')) continue;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            _isPrivate172(ip)) {
          return ip;
        }
        fallback ??= ip;
      }
    }
    return fallback;
  } catch (_) {
    return null;
  }
}

bool _isPrivate172(String ip) {
  if (!ip.startsWith('172.')) return false;
  final parts = ip.split('.');
  if (parts.length < 2) return false;
  final second = int.tryParse(parts[1]);
  return second != null && second >= 16 && second <= 31;
}
