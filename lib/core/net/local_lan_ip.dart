// SPDX-License-Identifier: AGPL-3.0
//
// Best-effort LAN IPv4 for offline RF screens. Used when mDNS discovery fails
// (common on iOS until Local Network permission is granted) — host shows IP,
// joiner can connect by address.
//
// Prefer Wi‑Fi (wlan0 / en0) over USB tether (rndis) so "Copy IP:port" matches
// the same subnet Bonsoir discovers on.

import 'dart:io';

/// Returns this device's primary Wi‑Fi/LAN IPv4, or null if unavailable.
Future<String?> primaryLanIPv4() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    String? best;
    var bestScore = -1;
    String? fallback;
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (_skipInterface(name)) continue;
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.isLoopback || ip.startsWith('169.254.')) continue;
        if (!_isUsableLanIp(ip)) {
          fallback ??= ip;
          continue;
        }
        final score = _interfaceScore(name, ip);
        if (score > bestScore) {
          bestScore = score;
          best = ip;
        }
      }
    }
    return best ?? fallback;
  } catch (_) {
    return null;
  }
}

bool _skipInterface(String name) {
  if (name == 'lo0' || name == 'lo') return true;
  if (name.startsWith('utun')) return true;
  if (name.startsWith('bridge')) return true;
  if (name.contains('awdl')) return true;
  if (name.contains('llw')) return true;
  return false;
}

bool _isUsableLanIp(String ip) =>
    ip.startsWith('192.168.') ||
    ip.startsWith('10.') ||
    _isPrivate172(ip);

/// Higher = prefer for display / join-by-IP hints.
int _interfaceScore(String name, String ip) {
  var score = 0;
  // Wi‑Fi first — matches Bonsoir same-subnet discovery.
  if (name == 'wlan0' ||
      name == 'en0' ||
      name.startsWith('wlan') ||
      name.contains('wifi')) {
    score += 100;
  }
  // Ethernet is fine on desktops.
  if (name.startsWith('eth') || name.startsWith('en') && name != 'en0') {
    score += 80;
  }
  // USB tether / rndis / mobile hotspot relay — deprioritize when Wi‑Fi exists.
  if (name.contains('rndis') ||
      name.contains('usb') ||
      name.contains('rmnet') ||
      name.contains('pdp_ip') ||
      name.contains('ccmni')) {
    score -= 50;
  }
  // Typical home LAN subnets beat carrier NAT ranges.
  if (ip.startsWith('192.168.')) score += 20;
  if (ip.startsWith('10.249.') || ip.startsWith('10.0.')) score -= 10;
  return score;
}

bool _isPrivate172(String ip) {
  if (!ip.startsWith('172.')) return false;
  final parts = ip.split('.');
  if (parts.length < 2) return false;
  final second = int.tryParse(parts[1]);
  return second != null && second >= 16 && second <= 31;
}
