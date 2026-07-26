// SPDX-License-Identifier: AGPL-3.0
//
// Me — account + settings + open-source link. The "About INTERACT"
// surface where we proudly point at the Forgejo repo + AGPLv3 license.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/locale_prefs.dart';
import '../../l10n/app_localizations.dart';
import '../../services/ai_router_service.dart';
import '../../services/ai_service.dart';
import '../../services/auth_service.dart';
import '../../services/chat_api.dart';
import '../../widgets/branded_app_bar.dart';
import '../../widgets/user_avatar.dart';

class MeTab extends ConsumerStatefulWidget {
  const MeTab({super.key});
  @override
  ConsumerState<MeTab> createState() => _MeTabState();
}

class _MeTabState extends ConsumerState<MeTab> {
  String? _name;
  String? _phone;
  String? _avatarUrl;
  bool _uploadingAvatar = false;
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
    final avatar = await ref.read(chatApiProvider).getAvatar();
    if (!mounted) return;
    setState(() {
      _name = n;
      _phone = p;
      _avatarUrl = avatar;
      _privateAi = priv;
      _cap = cap;
    });
  }

  Future<void> _pickAvatar() async {
    if (_uploadingAvatar) return;
    final XFile? picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 640,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final url = await ref.read(chatApiProvider).setAvatarFromFile(File(picked.path));
      if (!mounted) return;
      setState(() => _avatarUrl = url);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo updated')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update photo: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
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

  Future<void> _pickLanguage(BuildContext context, AppLocalizations l10n) async {
    final current = ref.read(localeControllerProvider);
    final choice = await showModalBottomSheet<TalkLanguageOption>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget tile(TalkLanguageOption opt, String label) {
          final selected = current == opt;
          return ListTile(
            title: Text(label),
            trailing: selected ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, opt),
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(title: Text(l10n.chooseLanguage)),
              tile(TalkLanguageOption.system, l10n.languageSystem),
              tile(TalkLanguageOption.english, l10n.languageEnglish),
              tile(TalkLanguageOption.urdu, l10n.languageUrdu),
              tile(TalkLanguageOption.arabic, l10n.languageArabic),
              tile(TalkLanguageOption.turkish, l10n.languageTurkish),
              tile(TalkLanguageOption.russian, l10n.languageRussian),
              tile(TalkLanguageOption.punjabi, l10n.languagePunjabi),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(
                  l10n.rtlHint,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    await ref.read(localeControllerProvider.notifier).setOption(choice);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: l10n.tabMe,
        subtitle: 'Account & settings',
        showBrandGlyph: true,
      ),
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
                GestureDetector(
                  onTap: _pickAvatar,
                  child: Stack(
                    children: [
                      UserAvatar(url: _avatarUrl, name: _name ?? '', radius: 32),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: cs.secondary,
                            shape: BoxShape.circle,
                            border: Border.all(color: cs.primaryContainer, width: 2),
                          ),
                          child: _uploadingAvatar
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.camera_alt,
                                  size: 12, color: Colors.white),
                        ),
                      ),
                    ],
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
              subtitle: 'Bonsoir mDNS + TCP text on same Wi‑Fi',
              onTap: () => context.push('/offline-lan'),
            ),
            _Tile(
              icon: Icons.bluetooth_searching,
              label: 'Nearby mesh (BLE)',
              subtitle: 'sahl_mesh gossip — short texts, no internet',
              onTap: () => context.push('/nearby-mesh'),
            ),
            _Tile(
              icon: Icons.alternate_email,
              label: 'Set your @username',
              subtitle: 'Let people find you without your number',
              onTap: () async {
                final ctrl = TextEditingController();
                final v = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Set @username'),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      decoration: const InputDecoration(prefixText: '@', hintText: 'yourname'),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, ctrl.text.trim().toLowerCase()),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                if (v == null || v.isEmpty || !context.mounted) return;
                try {
                  final okUp = await ref.read(chatApiProvider).setUsername(v);
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(okUp ? 'Handle set: @$v' : 'That handle is already taken')),
                  );
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not set handle: $e')));
                  }
                }
              },
            ),
          ]),
          _Section(title: l10n.sectionChats, children: [
            _Tile(
              icon: Icons.groups_2_outlined,
              label: l10n.communities,
              subtitle: l10n.communitiesSubtitle,
              onTap: () => context.push('/communities'),
            ),
            _Tile(
              icon: Icons.cloud_sync_outlined,
              label: l10n.backupRestore,
              subtitle: l10n.backupSubtitle,
              onTap: () => context.push('/backup'),
            ),
          ]),
          _Section(title: l10n.sectionVoiceAi, children: [
            SwitchListTile(
              secondary: const Icon(Icons.privacy_tip_outlined),
              title: Text(l10n.privateAiComingSoon),
              subtitle: Text(
                _privateAi
                    ? l10n.privateAiOnSubtitle
                    : l10n.privateAiOffSubtitle,
              ),
              value: _privateAi,
              // Keep toggle for prefs, but warn loudly — model is not ready.
              onChanged: _togglePrivateAi,
            ),
            _Tile(
              icon: Icons.memory,
              label: l10n.onDeviceCapability,
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
              label: l10n.voiceNoteTranscription,
              subtitle: l10n.voiceNoteTranscriptionSubtitle,
              onTap: () {},
            ),
            _Tile(
              icon: Icons.translate,
              label: l10n.languages,
              subtitle: l10n.languagesSubtitle,
              onTap: () => _pickLanguage(context, l10n),
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
