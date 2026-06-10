// SPDX-License-Identifier: AGPL-3.0
//
// Me — account + settings + open-source link. The "About INTERACT"
// surface where we proudly point at the Forgejo repo + AGPLv3 license.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/ai_router_service.dart';
import '../../services/ai_service.dart';
import '../../services/auth_service.dart';

class MeTab extends ConsumerStatefulWidget {
  const MeTab({super.key});
  @override
  ConsumerState<MeTab> createState() => _MeTabState();
}

class _MeTabState extends ConsumerState<MeTab> {
  String? _name;
  String? _phone;
  bool _privateAi = false;
  OnDeviceCapability? _cap;

  @override
  void initState() {
    super.initState();
    _hydrate();
  }

  Future<void> _hydrate() async {
    final auth = ref.read(authServiceProvider);
    final router = ref.read(aiRouterProvider);
    final n = await auth.displayName();
    final p = await auth.phone();
    final priv = await router.isPrivateAiEnabled();
    final cap = await router.onDeviceCapability();
    if (!mounted) return;
    setState(() {
      _name = n;
      _phone = p;
      _privateAi = priv;
      _cap = cap;
    });
  }

  Future<void> _togglePrivateAi(bool on) async {
    final router = ref.read(aiRouterProvider);
    await router.setPrivateAiEnabled(on);
    if (!mounted) return;
    setState(() => _privateAi = on);
    // If the user opted in but no on-device model is downloaded yet,
    // warn them — every chat-tier request will now fail loudly rather
    // than silently leaking to cloud.
    if (on && _cap != null && !_cap!.canRunChat3B && !_cap!.canRunChat7B) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Private AI is on — but no on-device model is downloaded yet. '
            'AI requests will fail until you download a model.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    }
  }

  String _capSummary(OnDeviceCapability cap) {
    if (cap.deviceRamMb == 0 && cap.downloadedModels.isEmpty) {
      return 'Phase 3 pending — llama.cpp binding lands next session';
    }
    final caps = <String>[];
    if (cap.canRunVoice) caps.add('voice');
    if (cap.canRunChat7B) {
      caps.add('chat-7B');
    } else if (cap.canRunChat3B) {
      caps.add('chat-3B');
    }
    final ram = '${cap.deviceRamMb} MB RAM';
    if (caps.isEmpty) return '$ram · no on-device tier available yet';
    return '$ram · runs: ${caps.join(", ")}';
  }

  Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Me')),
      body: ListView(
        children: [
          // Profile card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: cs.primary,
                  child: Text(
                    (_name ?? '?').isEmpty ? '?' : _name![0].toUpperCase(),
                    style: TextStyle(
                        fontSize: 28,
                        color: cs.onPrimary,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_name ?? '—',
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(_phone ?? '',
                          style: TextStyle(color: cs.onPrimaryContainer)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Sections
          _Section(title: 'Calls', children: [
            _Tile(icon: Icons.history, label: 'Call history', onTap: () {}),
            _Tile(icon: Icons.block, label: 'Blocked contacts', onTap: () {}),
          ]),
          _Section(title: 'Privacy & security', children: [
            _Tile(
              icon: Icons.lock_outline,
              label: 'End-to-end encryption',
              subtitle: 'Phase 1.5 — libsignal_protocol_dart',
              onTap: () {},
            ),
            _Tile(
              icon: Icons.wifi_off,
              label: 'Offline LAN mode',
              subtitle: 'Phase 1.5 — Bonsoir mDNS + WebRTC direct',
              onTap: () {},
            ),
          ]),
          _Section(title: 'Voice & AI', children: [
            SwitchListTile(
              secondary: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Private AI'),
              subtitle: Text(
                _privateAi
                    ? 'On — chat & voice run on-device only. No cloud round-trips.'
                    : 'Off — chat tier uses cloud (DeepSeek/Zeka). Voice stays on-device.',
              ),
              value: _privateAi,
              onChanged: _togglePrivateAi,
            ),
            _Tile(
              icon: Icons.memory,
              label: 'On-device capability',
              subtitle: _cap == null
                  ? 'Checking…'
                  : _capSummary(_cap!),
              onTap: () {},
            ),
            _Tile(
              icon: Icons.fact_check_outlined,
              label: 'AI audit log',
              subtitle: 'Export proof of which calls left the device',
              onTap: () {},
            ),
            _Tile(
              icon: Icons.mic,
              label: 'Voice transcription (Urdu)',
              subtitle: 'On-device Whisper, downloads on first use',
              onTap: () {},
            ),
            _Tile(
              icon: Icons.translate,
              label: 'Languages',
              subtitle: 'EN · UR · PA · SD · PS · BAL',
              onTap: () {},
            ),
          ]),
          _Section(title: 'About', children: [
            _Tile(
              icon: Icons.code,
              label: 'Source code',
              subtitle: 'hub.interactpak.com/interact/interact-app',
              onTap: () =>
                  _open('https://hub.interactpak.com/interact/interact-app'),
            ),
            _Tile(
              icon: Icons.description_outlined,
              label: 'License',
              subtitle: 'AGPLv3 — free, open-source forever',
              onTap: () => _open('https://www.gnu.org/licenses/agpl-3.0.html'),
            ),
            _Tile(
              icon: Icons.shield_outlined,
              label: 'Dependencies',
              subtitle: 'See NOTICE.md',
              onTap: () => _open(
                  'https://hub.interactpak.com/interact/interact-app/raw/branch/main/NOTICE.md'),
            ),
            _Tile(
              icon: Icons.info_outline,
              label: 'About INTERACT',
              subtitle: 'Voice/video-first, offline-capable, AI-assisted',
              onTap: () {},
            ),
          ]),
          _Section(title: 'Account', children: [
            _Tile(
              icon: Icons.logout,
              label: 'Sign out',
              destructive: true,
              onTap: () async {
                await ref.read(authServiceProvider).signOut();
                if (!mounted) return;
                context.go('/sign-in');
              },
            ),
          ]),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: cs.outline,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.label,
    this.subtitle,
    required this.onTap,
    this.destructive = false,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = destructive ? cs.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.chevron_right, size: 20),
      onTap: onTap,
    );
  }
}
