// SPDX-License-Identifier: AGPL-3.0
//
// Offline Comms Hub — one screen that gathers every way this phone can reach
// another device with no internet, oldest signalling principle to newest.
//
// Design + full rationale: docs/COMMS_BEARERS_SCAN_2026-09-01.md and
// docs/OFFLINE_BEARERS_AUDIT_2026-09-01.md.
//
// This screen is the "router made visible": today the working bearers each
// live in their own screen and a user must know which to open. The hub lists
// them together with a live/planned status and a plain-English "what it is",
// so the whole menu is discoverable in one place. Live bearers deep-link to
// their existing screens; planned ones open an info sheet — never a dead tap.
//
// ZERO new dependencies (pure Flutter + go_router) — safe under the pinned
// toolchain. New antenna/sensor bearers (SMS, NFC, Wi-Fi Aware, acoustic,
// torch/QR light) appear here as honest "Planned" tiles until built.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/branded_app_bar.dart';

/// How far a bearer reaches — drives the little reach chip on each tile.
enum _Reach { touch, room, site, area, national }

extension on _Reach {
  String get label => switch (this) {
        _Reach.touch => 'Touch',
        _Reach.room => 'Same room',
        _Reach.site => 'Same site',
        _Reach.area => 'Local area',
        _Reach.national => 'Anywhere with signal',
      };
}

/// A bearer's build state. `live` tiles navigate; the rest explain themselves.
enum _Status { live, planned, hardware, unavailable }

extension on _Status {
  String? get badge => switch (this) {
        _Status.live => null,
        _Status.planned => 'Planned',
        _Status.hardware => 'Needs device',
        _Status.unavailable => 'OS-locked',
      };
}

/// One row in the hub. `route` is non-null only for live bearers.
class _Bearer {
  const _Bearer({
    required this.icon,
    required this.name,
    required this.reach,
    required this.status,
    required this.blurb,
    this.route,
    this.detail,
  });

  final IconData icon;
  final String name;
  final _Reach reach;
  final _Status status;
  final String blurb;
  final String? route;
  final String? detail;
}

class OfflineHubScreen extends StatelessWidget {
  const OfflineHubScreen({super.key});

  // ── Modern antenna radios ────────────────────────────────────────────
  static const List<_Bearer> _antennas = [
    _Bearer(
      icon: Icons.wifi,
      name: 'Same Wi‑Fi (LAN)',
      reach: _Reach.site,
      status: _Status.live,
      blurb: 'Chat & voice over one Wi‑Fi — no internet needed.',
      route: '/offline-lan',
    ),
    _Bearer(
      icon: Icons.wifi_tethering,
      name: 'Nearby Wi‑Fi walkie',
      reach: _Reach.site,
      status: _Status.live,
      blurb:
          'Push‑to‑talk voice on the site Wi‑Fi when the router has no uplink.',
      route: '/lan-walkie',
    ),
    _Bearer(
      icon: Icons.hub,
      name: 'Wi‑Fi Direct',
      reach: _Reach.room,
      status: _Status.live,
      blurb: 'Phone‑to‑phone with no router at all (same‑OS devices).',
      route: '/offline-lan',
    ),
    _Bearer(
      icon: Icons.bluetooth_searching,
      name: 'Bluetooth mesh',
      reach: _Reach.room,
      status: _Status.live,
      blurb: 'Relay short texts phone‑to‑phone, hopping device to device.',
      route: '/nearby-mesh',
      detail:
          'Uses sahl_mesh gossip. Link mesh pubkey to Talk identity via '
          'QR on Nearby mesh → identity button (RF-MESH-BIND-1).',
    ),
    _Bearer(
      icon: Icons.my_location,
      name: 'Location trace',
      reach: _Reach.site,
      status: _Status.live,
      blurb:
          'Share GPS live or see IoT tracker fixes — phone, LAN, BLE, LoRa.',
      route: '/location-trace',
      detail:
          'Live share from a 1:1 chat (attach → Share live location). IoT '
          'gateways can publish lat/lng in RF HTTP poll JSON. Compact loc: '
          'pins work over BLE mesh offline.',
    ),
    _Bearer(
      icon: Icons.map_rounded,
      name: 'Friends map',
      reach: _Reach.site,
      status: _Status.live,
      blurb:
          'Friends, peers and IoT trackers on one live map — works offline.',
      route: '/friends-map',
      detail:
          'Live positions plotted on a real map. Download the current area '
          'for offline use so markers stay visible with no signal. Positions '
          'ride cloud or LAN/BLE mesh.',
    ),
    _Bearer(
      icon: Icons.sensors,
      name: 'Nearby devices',
      reach: _Reach.room,
      status: _Status.live,
      blurb: 'See who and what is around by Bluetooth — name, signal, last seen.',
      route: '/nearby-devices',
    ),
    _Bearer(
      icon: Icons.sms,
      name: 'SMS fallback',
      reach: _Reach.national,
      status: _Status.live,
      blurb: 'When there is signal but no data — send as a text message.',
      route: '/chats',
      detail:
          'User‑confirmed only — standard SMS rates apply. When cloud and '
          'offline bearers fail, open a 1:1 chat and tap SMS on the queue '
          'banner, or use Send failed → SMS. Never sends silently.',
    ),
    _Bearer(
      icon: Icons.nfc,
      name: 'NFC tap',
      reach: _Reach.touch,
      status: _Status.planned,
      blurb:
          'Tap two phones to swap identity — the safe way to add a contact offline.',
      detail:
          'A deliberate physical tap exchanges your INTERACT identity with the '
          'phone you touch. It cannot be intercepted at a distance, which makes '
          'it the trustworthy way to pair for offline messaging. Needs a new '
          'NFC plugin — added in a dedicated toolchain session, not before a '
          'test build.',
    ),
    _Bearer(
      icon: Icons.travel_explore,
      name: 'Wi‑Fi Aware',
      reach: _Reach.room,
      status: _Status.planned,
      blurb: 'Neighbour discovery with no router and no pairing (Android).',
      detail:
          'Android’s serverless neighbour‑awareness: phones find each '
          'other and open a data path with no access point and no pairing dance. '
          'The modern answer to Wi‑Fi Direct’s same‑OS limit. '
          'Plugin‑gated.',
    ),
    _Bearer(
      icon: Icons.router,
      name: 'IoT gateway',
      reach: _Reach.area,
      status: _Status.live,
      blurb:
          'LoRa ESP32, 433 MHz RF→HTTP, AutoSense edge — inbound signal + one-tap ACK.',
      route: '/iot-comms',
    ),
    _Bearer(
      icon: Icons.cell_tower,
      name: 'LoRa bridge',
      reach: _Reach.area,
      status: _Status.hardware,
      blurb: 'Kilometre‑range radio via an external InteractLoRaBridge node.',
      route: '/lora-bridge',
    ),
    _Bearer(
      icon: Icons.satellite_alt,
      name: 'Satellite SOS',
      reach: _Reach.national,
      status: _Status.unavailable,
      blurb: 'Emergency satellite messaging is locked to the phone’s OS.',
      detail:
          'Both iOS and Android keep satellite messaging inside the operating '
          'system — no app, including this one, can send over it. Listed here so '
          'it is never planned around by mistake.',
    ),
  ];

  // ── Classic line-of-sight & sensor bearers (old ideas, modern sensors) ─
  static const List<_Bearer> _sensors = [
    _Bearer(
      icon: Icons.qr_code_2,
      name: 'Scan a code',
      reach: _Reach.touch,
      status: _Status.live,
      blurb: 'Show a QR to join a call or sign in on another device.',
      route: '/invite',
    ),
    _Bearer(
      icon: Icons.flashlight_on,
      name: 'Light signal',
      reach: _Reach.room,
      status: _Status.planned,
      blurb:
          'Blink a channel code with the torch or screen — read by eye or camera.',
      detail:
          'The heliograph, on a phone. The torch or screen flashes a short '
          'channel code in on‑off pulses; the other phone reads it with its '
          'camera, or a person reads it by eye. Works when Bluetooth is switched '
          'off or its permission is denied. No pairing, no radio.',
    ),
    _Bearer(
      icon: Icons.graphic_eq,
      name: 'Sound chirp',
      reach: _Reach.room,
      status: _Status.planned,
      blurb: 'Send a short code across a room as an audio tone.',
      detail:
          'Data over sound — the acoustic‑coupler modem idea. The speaker '
          'chirps a channel code and nearby mics decode it. Slow and noisy but '
          'it survives when every radio is off. Buildable with the audio '
          'libraries already shipped — no new dependency.',
    ),
    _Bearer(
      icon: Icons.hearing,
      name: 'Ultrasonic',
      reach: _Reach.room,
      status: _Status.planned,
      blurb: 'The same code, sent silently just above hearing.',
      detail:
          'A near‑inaudible version of the sound chirp (~19–21 kHz). '
          'Quieter and shorter‑range, limited by the phone speaker, but '
          'unobtrusive. Same DSP path as the audible chirp.',
    ),
    _Bearer(
      icon: Icons.settings_remote,
      name: 'Infrared',
      reach: _Reach.room,
      status: _Status.hardware,
      blurb: 'A private line‑of‑sight beam — only on phones with an IR blaster.',
      detail:
          'A few Android phones still ship an infrared blaster, the TV‑remote '
          'transmitter. Where present it is a genuine private, licence‑free, '
          'line‑of‑sight channel. Most phones no longer have the hardware.',
    ),
    _Bearer(
      icon: Icons.explore,
      name: 'Compass pulse',
      reach: _Reach.touch,
      status: _Status.planned,
      blurb: 'Experimental — nudge a nearby phone’s compass to pass a few bits.',
      detail:
          'The oldest telegraph principle: a modulated magnetic field twitches '
          'another phone’s compass sensor. Real but tiny bandwidth — a proof '
          'of concept, not a message channel. Kept here for completeness of the '
          'signalling menu.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Offline comms',
        subtitle: 'Every way to reach a phone with no internet',
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Card(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.travel_explore),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'This phone is many radios and sensors at once. Below is '
                      'every channel it can use with no internet — the ones that '
                      'work today, and the ones on the way.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          _sectionHeader(context, 'Radios',
              'Antenna bearers — Bluetooth, Wi‑Fi, cellular, LoRa'),
          for (final b in _antennas) _tile(context, b),
          const SizedBox(height: 24),
          _sectionHeader(context, 'Light & sound',
              'Old signalling ideas, read by the phone’s sensors'),
          for (final b in _sensors) _tile(context, b),
          const SizedBox(height: 24),
          Text(
            'Nothing here sends to the internet, and short‑range channels '
            'stay in the room. Full bearer scan: Me → Field validation.',
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title, String subtitle) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: cs.primary)),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, _Bearer b) {
    final cs = Theme.of(context).colorScheme;
    final live = b.status == _Status.live;
    final badge = b.status.badge;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(b.icon, color: live ? cs.primary : cs.onSurfaceVariant),
      title: Text(b.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(b.blurb),
          const SizedBox(height: 4),
          Row(
            children: [
              _chip(context, b.reach.label, cs.surfaceContainerHighest,
                  cs.onSurfaceVariant),
              if (badge != null) ...[
                const SizedBox(width: 6),
                _chip(context, badge, cs.secondaryContainer,
                    cs.onSecondaryContainer),
              ],
            ],
          ),
        ],
      ),
      trailing: Icon(live ? Icons.chevron_right : Icons.info_outline, size: 20),
      isThreeLine: true,
      onTap: () {
        if (live && b.route != null) {
          context.push(b.route!);
        } else {
          _showInfo(context, b);
        }
      },
    );
  }

  Widget _chip(BuildContext context, String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text,
          style:
              TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  void _showInfo(BuildContext context, _Bearer b) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(b.icon, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(b.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                    ),
                    if (b.status.badge != null)
                      _chip(ctx, b.status.badge!, cs.secondaryContainer,
                          cs.onSecondaryContainer),
                  ],
                ),
                const SizedBox(height: 12),
                Text(b.detail ?? b.blurb,
                    style: TextStyle(color: cs.onSurfaceVariant, height: 1.4)),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Got it'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
