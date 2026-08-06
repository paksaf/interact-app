// Shared in-app update banner — used on SignIn (pre-auth) and AppShell
// (post-auth). Auto-download default ON; see services/update_service.dart.
//
// IMPORTANT: do NOT use MaterialBanner here. MaterialBanner pushes the whole
// Scaffold body down, and AppShell used to clear+re-show it on every download
// progress tick — on Samsung that "bumps" the Calls/Chats dashboard repeatedly.
// This widget is an inline strip that updates in place via ListenableBuilder.
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/update_service.dart';

/// Kick OTA check. Safe from any screen. Returns available update, if any.
/// Does not mutate ScaffoldMessenger (no MaterialBanner).
Future<UpdateInfo?> checkAndShowInAppUpdate(BuildContext context) async {
  final svc = UpdateService.instance;
  final info = await svc.checkOnBoot(force: true);
  return info;
}

/// Inline update strip — drop into a [Column] above the main body.
/// Listens to [UpdateService]; returns [SizedBox.shrink] when nothing to show.
class InAppUpdateBannerHost extends StatelessWidget {
  const InAppUpdateBannerHost({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = UpdateService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final info = svc.available;
        if (info == null) return const SizedBox.shrink();
        return _UpdateStrip(info: info);
      },
    );
  }
}

class _UpdateStrip extends StatelessWidget {
  const _UpdateStrip({required this.info});
  final UpdateInfo info;

  @override
  Widget build(BuildContext context) {
    final svc = UpdateService.instance;
    final cs = Theme.of(context).colorScheme;
    final downloading = svc.downloadState == UpdateDownloadState.downloading;
    final ready = svc.downloadState == UpdateDownloadState.downloaded;
    final pct = (svc.downloadProgress * 100).clamp(0, 100).round();

    final String body;
    if (downloading) {
      body = 'Downloading ${info.versionMark}… $pct%';
    } else if (ready) {
      body = '${info.versionMark} ready — install over the top (account safe).'
          '${info.changelog.isNotEmpty ? '\n${info.changelog}' : ''}';
    } else {
      body = 'NEW ${info.versionMark}'
          '${info.changelog.isNotEmpty ? '\n${info.changelog}' : ''}';
    }

    return Material(
      color: cs.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                ready ? Icons.install_mobile : Icons.system_update,
                size: 20,
                color: cs.onSecondaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  body,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.25,
                    fontWeight: FontWeight.w600,
                    color: cs.onSecondaryContainer,
                  ),
                ),
              ),
              if (!info.forceUpdate)
                TextButton(
                  onPressed: () => unawaited(svc.dismiss()),
                  child: const Text('Later'),
                ),
              FilledButton(
                onPressed: downloading
                    ? null
                    : () {
                        unawaited(svc.installOrDownload(info: info));
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                            ready
                                ? 'Opening installer… confirm when prompted.'
                                : 'Downloading update in-app… install when ready.',
                          ),
                        ));
                      },
                child: Text(
                  downloading
                      ? '$pct%'
                      : ready
                          ? 'Install'
                          : 'Update',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// @Deprecated — kept as a no-op shim so older call sites compile.
/// Prefer [InAppUpdateBannerHost] in the widget tree.
@Deprecated('Use InAppUpdateBannerHost — MaterialBanner bumps the dashboard')
void showInAppUpdateBanner(BuildContext context, UpdateInfo info) {
  // Intentionally empty — banner is owned by InAppUpdateBannerHost.
}
