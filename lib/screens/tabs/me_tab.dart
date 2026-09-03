// SPDX-License-Identifier: AGPL-3.0
//
// Me — account + settings + open-source link. The "About INTERACT"
// surface where we proudly point at the Forgejo repo + AGPLv3 license.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/l10n/locale_prefs.dart';
import '../../l10n/app_localizations.dart';
import '../../services/ai_router_service.dart';
import '../../services/ai_service.dart';
import '../../services/auth_service.dart';
import '../../services/chat_api.dart';
import '../../services/update_service.dart';
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
  String? _email;
  String? _avatarUrl;
  String? _appVersionLabel;
  bool _uploadingAvatar = false;
  bool _checkingUpdate = false;
  bool _privateAi = false;
  bool _autoDownload = true;
  UpdateInfo? _pendingUpdate;
  OnDeviceCapability? _cap;

  @override
  void initState() {
    super.initState();
    _hydrate();
    UpdateService.instance.addListener(_onUpdateChanged);
    _syncUpdateState();
  }

  @override
  void dispose() {
    UpdateService.instance.removeListener(_onUpdateChanged);
    super.dispose();
  }

  void _onUpdateChanged() => _syncUpdateState();

  void _syncUpdateState() {
    if (!mounted) return;
    setState(() {
      _autoDownload = UpdateService.instance.autoDownloadEnabled;
      _pendingUpdate = UpdateService.instance.available;
    });
  }

  Future<void> _hydrate() async {
    final auth = ref.read(authServiceProvider);
    final router = ref.read(aiRouterProvider);
    // Server is source of truth — clears stale phone left from another login.
    await auth.refreshCredentialsFromServer();
    final n = await auth.displayName();
    final p = await auth.phone();
    final e = await auth.email();
    final priv = await router.isPrivateAiEnabled();
    final cap = await router.onDeviceCapability();
    final avatar = await ref.read(chatApiProvider).getAvatar();
    final pkg = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _name = n;
      _phone = p;
      _email = e;
      _avatarUrl = avatar;
      _privateAi = priv;
      _cap = cap;
      _appVersionLabel = 'v${pkg.version} (${pkg.buildNumber})';
    });
  }

  Future<void> _checkForUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final svc = UpdateService.instance;
      final info = await svc.checkOnBoot(force: true);
      if (!mounted) return;
      _syncUpdateState();
      if (info == null) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${l10n.upToDate}'
              '${_appVersionLabel != null ? ' — $_appVersionLabel' : ''}.',
            ),
          ),
        );
        return;
      }
      final ready = svc.downloadState == UpdateDownloadState.downloaded;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('NEW ${info.versionMark}'),
          content: Text(
            info.changelog.isNotEmpty
                ? info.changelog
                : 'A newer INTERACT Talk build is ready to install in-app.',
          ),
          actions: [
            if (!info.forceUpdate)
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Later'),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ready ? 'Install now' : 'Update now'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await svc.installOrDownload(info: info);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ready
                  ? 'Opening installer… confirm when prompted.'
                  : 'Downloading in-app… tap Install when the banner says ready.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  /// Edit the display name — updates the Talk backend + local cache so the Me
  /// tab, chat bubbles, and the peer's roster all reflect the new name.
  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _name ?? '');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit your name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'Your name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v == null || v.length < 2 || !mounted) return;
    try {
      final saved = await ref.read(chatApiProvider).setDisplayName(v);
      await ref.read(authServiceProvider).setLocalName(saved);
      if (!mounted) return;
      setState(() => _name = saved);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name updated')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not update name: $e')));
      }
    }
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

  /// Fail-soft feedback for tiles whose backing feature isn't built yet — a
  /// dismissible snackbar instead of a silent dead `onTap: () {}`.
  void _comingSoon(String feature) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$feature — coming soon')),
    );
  }

  /// "About INTERACT" — a real About dialog with app name + version
  /// (package_info_plus) + a short blurb. Fail-soft: shows without the version
  /// string if PackageInfo can't be read.
  Future<void> _showAbout() async {
    var version = _appVersionLabel;
    if (version == null) {
      try {
        final pkg = await PackageInfo.fromPlatform();
        version = 'v${pkg.version} (${pkg.buildNumber})';
      } catch (_) {/* fail-soft — show the dialog without a version line */}
    }
    if (!mounted) return;
    showAboutDialog(
      context: context,
      applicationName: 'INTERACT Talk',
      applicationVersion: version ?? '',
      applicationLegalese: '© INTERACT · AGPLv3 — free & open-source forever',
      children: [
        const SizedBox(height: 8),
        const Text(
          'Voice/video-first, offline-capable, AI-assisted communication for '
          'Pakistan and beyond. Works over the internet, local Wi‑Fi/LAN, '
          'nearby BLE mesh, and LoRa — so you can stay connected even when the '
          'network can’t.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => _open('https://www.gnu.org/licenses/agpl-3.0.html'),
              child: const Text('License (AGPLv3)'),
            ),
            TextButton(
              onPressed: () => _open('https://hub.interactpak.com/interact/interact-app'),
              child: const Text('Source code'),
            ),
          ],
        ),
      ],
    );
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

  /// Set the public @username so peers can find you without your number.
  /// Fail-soft: taken handle → snackbar; network error → snackbar. Guarded
  /// with `context.mounted` across each async gap.
  Future<void> _setUsername() async {
    final ctrl = TextEditingController();
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set @username'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration:
              const InputDecoration(prefixText: '@', hintText: 'yourname'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, ctrl.text.trim().toLowerCase()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    // Sanitize to the server's rule ([a-z0-9_]{3,32}) instead of bouncing a
    // 400 back at the user: spaces → underscores, strip everything else.
    // "Muzafar Ahmed" becomes muzafar_ahmed rather than an error.
    final handle = v
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (handle.length < 3 || handle.length > 32) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Handle must be 3–32 characters: letters, numbers, underscore')));
      return;
    }
    final v2 = handle;
    try {
      final okUp = await ref.read(chatApiProvider).setUsername(v2);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(okUp ? 'Handle set: @$v2' : 'That handle is already taken'),
        ),
      );
    } catch (e) {
      if (mounted) {
        // 404 = the deployed server build predates the handles route
        // (Sahulat deploy freeze, 2026-08-22). Say so plainly instead of
        // surfacing a raw status code.
        final msg = '$e'.contains('404')
            ? 'Handles need the next server update — coming soon.'
            : 'Could not set handle: ${'$e'.replaceFirst('Exception: ', '')}';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    }
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
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _name ?? '—',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: _editName,
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(Icons.edit,
                                  size: 16, color: cs.onPrimaryContainer),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      if ((_phone ?? '').isNotEmpty)
                        Text(_phone!,
                            style: TextStyle(color: cs.onPrimaryContainer)),
                      if ((_email ?? '').isNotEmpty)
                        Text(_email!,
                            style: TextStyle(
                                color: cs.onPrimaryContainer, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Collapsible sections (Phase-1 redesign). Every tile that used to
          // live in flat sections — plus the three login items redistributed
          // from the removed Menu tab — is preserved here, grouped by intent.

          // PROFILE — identity handle (avatar/phone live in the card above).
          _Group(
            icon: Icons.person_outline,
            title: 'Profile',
            subtitle: 'Your handle & how people find you',
            initiallyExpanded: true,
            children: [
              _Tile(
                icon: Icons.alternate_email,
                label: 'Set your @username',
                subtitle: 'Let people find you without your number',
                onTap: _setUsername,
              ),
            ],
          ),

          // FRIENDS & FAMILY — social panel, find friends, location trace.
          _Group(
            icon: Icons.favorite_outline,
            title: 'Friends & Family',
            subtitle: 'Updates, discovery & location',
            initiallyExpanded: true,
            children: [
              _Tile(
                icon: Icons.dynamic_feed_outlined,
                label: 'Family & Friends panel',
                subtitle: 'Share updates, circles, announcements',
                onTap: () => context.push('/social-panel'),
              ),
              _Tile(
                icon: Icons.person_search_outlined,
                label: 'Find friends',
                subtitle: '@username, phone, contacts, invite',
                onTap: () => context.push('/find-friends'),
              ),
              _Tile(
                icon: Icons.map_rounded,
                label: 'Friends map',
                subtitle: 'Live pins · works offline (no API key)',
                onTap: () => context.push('/friends-map'),
              ),
              _Tile(
                icon: Icons.my_location,
                label: 'Location trace',
                subtitle: 'See live pins from chat & IoT',
                onTap: () => context.push('/location-trace'),
              ),
            ],
          ),

          // SECURITY & PRIVACY — encryption, backup, call privacy, and the
          // cross-device login tools moved from the Menu tab.
          _Group(
            icon: Icons.shield_outlined,
            title: 'Security & Privacy',
            subtitle: 'Encryption, backup & login devices',
            initiallyExpanded: true,
            children: [
              _Tile(
                icon: Icons.lock_outline,
                label: 'End-to-end encryption',
                subtitle: 'Phase 1.5 — prekey upload scaffold (libsignal next)',
                badge: 'Beta',
                onTap: () {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('End-to-end encryption'),
                      content: const Text(
                        'Phase 1.5 is in progress: device prekeys can sync to the '
                        'server, but message encryption is not enabled for all chats yet.\n\n'
                        'Your cloud chats are TLS-protected in transit. Full Signal-style '
                        'E2E for 1:1 threads lands in the next libsignal rollout.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                },
              ),
              _Tile(
                icon: Icons.cloud_sync_outlined,
                label: l10n.backupRestore,
                subtitle: l10n.backupSubtitle,
                onTap: () => context.push('/backup'),
              ),
              _Tile(
                icon: Icons.history,
                label: 'Call history',
                subtitle: 'All calls with missed/video/voice filters',
                onTap: () => context.push('/call-history'),
              ),
              _Tile(
                icon: Icons.block,
                label: 'Blocked contacts',
                subtitle: 'Blocked people can’t call or ring you',
                onTap: () => context.push('/blocked-contacts'),
              ),
              _Tile(
                icon: Icons.qr_code_2,
                label: 'Login QR',
                subtitle: 'Show a QR to sign in on another device',
                onTap: () => context.push('/login-qr'),
              ),
              _Tile(
                icon: Icons.pin_outlined,
                label: 'Login codes',
                subtitle: 'Pending sign-in codes for your account',
                onTap: () => context.push('/login-codes'),
              ),
              _Tile(
                icon: Icons.lock_open_outlined,
                label: 'Approve login',
                subtitle: 'Approve a sign-in request by code',
                onTap: () => context.push('/approve-login'),
              ),
            ],
          ),

          // AI & VOICE — private AI, on-device capability, transcription.
          _Group(
            icon: Icons.auto_awesome_outlined,
            title: 'AI & Voice',
            subtitle: 'On-device AI, transcription & audit',
            children: [
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
                subtitle: _cap == null ? 'Checking…' : _capSummary(_cap!),
                onTap: () => _comingSoon(l10n.onDeviceCapability),
              ),
              _Tile(
                icon: Icons.fact_check_outlined,
                label: 'AI audit log',
                subtitle: 'Export proof of which calls left the device',
                badge: 'Soon',
                onTap: () => _comingSoon('AI audit log'),
              ),
              _Tile(
                icon: Icons.mic,
                label: l10n.voiceNoteTranscription,
                subtitle: l10n.voiceNoteTranscriptionSubtitle,
                badge: 'Soon',
                onTap: () => _comingSoon(l10n.voiceNoteTranscription),
              ),
            ],
          ),

          // OFFLINE CONNECTIVITY — LAN / mesh / BLE / LoRa. Collapsed by
          // default: advanced field surfaces most users never open.
          _Group(
            icon: Icons.wifi_tethering,
            title: 'Offline Connectivity',
            subtitle: 'Stay connected with no internet',
            children: [
              _Tile(
                icon: Icons.travel_explore,
                label: 'Offline comms hub',
                subtitle: 'Every no‑internet channel in one place',
                onTap: () => context.push('/offline-hub'),
              ),
              _Tile(
                icon: Icons.wifi_off,
                label: 'Offline LAN mode',
                subtitle: 'Chat & call over the same Wi‑Fi (or Wi‑Fi Direct)',
                onTap: () => context.push('/offline-lan'),
              ),
              _Tile(
                icon: Icons.bluetooth_searching,
                label: 'Nearby mesh (BLE)',
                subtitle: 'Relay short texts phone-to-phone, no internet',
                onTap: () => context.push('/nearby-mesh'),
              ),
              _Tile(
                icon: Icons.sensors,
                label: 'Nearby devices',
                subtitle: 'BLE scan — name, signal, last seen (status only)',
                onTap: () => context.push('/nearby-devices'),
              ),
              _Tile(
                icon: Icons.cell_tower,
                label: 'LoRa bridge',
                subtitle: 'Long-range radio via an InteractLoRaBridge',
                onTap: () => context.push('/lora-bridge'),
              ),
              _Tile(
                icon: Icons.checklist_rtl,
                label: 'Field validation',
                subtitle: 'BLE / LAN / FCM / LoRa checklist + FCM token',
                onTap: () => context.push('/field-validation'),
              ),
            ],
          ),

          // APP SETTINGS — language, updates, communities, and about/license.
          _Group(
            icon: Icons.settings_outlined,
            title: 'App Settings',
            subtitle: 'Language, updates & about',
            children: [
              _Tile(
                icon: Icons.translate,
                label: l10n.languages,
                subtitle: l10n.languagesSubtitle,
                onTap: () => _pickLanguage(context, l10n),
              ),
              _Tile(
                icon: Icons.palette_outlined,
                label: l10n.themeSettings,
                subtitle: l10n.themeSettingsSubtitle,
                onTap: () => context.push('/settings/theme'),
              ),
              _Tile(
                icon: Icons.groups_2_outlined,
                label: l10n.communities,
                subtitle: l10n.communitiesSubtitle,
                onTap: () => context.push('/communities'),
              ),
              _Tile(
                icon: Icons.system_update,
                label: _checkingUpdate
                    ? '${l10n.checkForUpdates}…'
                    : _pendingUpdate != null
                        ? 'NEW ${_pendingUpdate!.versionMark}'
                        : l10n.checkForUpdates,
                subtitle: _pendingUpdate != null
                    ? (UpdateService.instance.downloadState ==
                            UpdateDownloadState.downloaded
                        ? 'Ready to install — tap'
                        : UpdateService.instance.downloadState ==
                                UpdateDownloadState.downloading
                            ? 'Downloading… ${(UpdateService.instance.downloadProgress * 100).round()}%'
                            : l10n.updateAvailable)
                    : (_appVersionLabel ?? l10n.upToDate),
                onTap: _checkingUpdate ? () {} : _checkForUpdate,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.download_for_offline_outlined),
                title: Text(l10n.autoUpdate),
                subtitle: Text(l10n.autoUpdateSubtitle),
                value: _autoDownload,
                onChanged: (v) async {
                  await UpdateService.instance.setAutoDownloadEnabled(v);
                  if (mounted) setState(() => _autoDownload = v);
                },
              ),
              _Tile(
                icon: Icons.info_outline,
                label: 'About INTERACT',
                subtitle: 'Voice/video-first, offline-capable, AI-assisted',
                onTap: _showAbout,
              ),
            ],
          ),

          // SIGN OUT — destructive, standalone (kept out of any group so it's
          // always one tap away).
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: _Tile(
              icon: Icons.logout,
              label: 'Sign out',
              destructive: true,
              onTap: () async {
                await ref.read(authServiceProvider).signOut();
                if (!context.mounted) return;
                context.go('/sign-in');
              },
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

/// Collapsible settings group (Phase-1 redesign). A themed ExpansionTile with
/// a leading icon + gray descriptor; children are the existing _Tiles.
class _Group extends StatelessWidget {
  const _Group({
    required this.icon,
    required this.title,
    this.subtitle,
    this.initiallyExpanded = false,
    required this.children,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool initiallyExpanded;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      elevation: 0,
      color: cs.surface.withValues(alpha: 0.55),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Remove the default ExpansionTile divider lines for a cleaner card.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          leading: Icon(icon, color: cs.primary),
          title: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!,
                  style: TextStyle(fontSize: 12, color: cs.outline)),
          childrenPadding: const EdgeInsets.only(bottom: 6),
          children: children,
        ),
      ),
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
    this.badge,
  });
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;
  final bool destructive;

  /// Small status pill for placeholder features (e.g. "Soon"). Shown before
  /// the chevron so users know the tile is a preview, not a dead tap.
  final String? badge;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = destructive ? cs.error : null;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(label, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badge != null)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                badge!,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: cs.onSecondaryContainer,
                ),
              ),
            ),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
      onTap: onTap,
    );
  }
}
