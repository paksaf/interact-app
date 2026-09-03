// SPDX-License-Identifier: AGPL-3.0
//
// Full-bleed chat wallpaper — image, bundled asset, or muted looping video.
// Dim / blur / scrim overlays keep bubbles legible.

import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/theme/chat_wallpaper_prefs.dart';

class ChatWallpaperLayer extends ConsumerStatefulWidget {
  const ChatWallpaperLayer({
    super.key,
    this.threadId,
    this.previewConfig,
  });

  final String? threadId;

  /// When set (settings editor), overrides resolved prefs for live preview.
  final ChatWallpaperConfig? previewConfig;

  @override
  ConsumerState<ChatWallpaperLayer> createState() => _ChatWallpaperLayerState();
}

class _ChatWallpaperLayerState extends ConsumerState<ChatWallpaperLayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _video;
  String? _videoPathLoaded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeVideo();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _video;
    if (controller == null || !controller.value.isInitialized) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      controller.pause();
    } else if (state == AppLifecycleState.resumed && mounted) {
      controller.play();
    }
  }

  void _disposeVideo() {
    _video?.dispose();
    _video = null;
    _videoPathLoaded = null;
  }

  ChatWallpaperConfig _config() {
    if (widget.previewConfig != null) return widget.previewConfig!;
    final state = ref.watch(chatWallpaperControllerProvider);
    return state.resolve(widget.threadId);
  }

  Future<void> _ensureVideo(String path) async {
    if (_videoPathLoaded == path &&
        _video != null &&
        _video!.value.isInitialized) {
      return;
    }
    _disposeVideo();
    final controller = VideoPlayerController.file(File(path));
    _video = controller;
    _videoPathLoaded = path;
    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      if (!mounted) return;
      await controller.play();
      setState(() {});
    } catch (_) {
      _disposeVideo();
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _config();
    final cs = Theme.of(context).colorScheme;

    if (!config.isActive) {
      return ColoredBox(color: cs.surface);
    }

    if (config.kind == ChatWallpaperKind.video &&
        config.localPath != null &&
        config.localPath!.isNotEmpty) {
      _ensureVideo(config.localPath!);
    } else if (_video != null) {
      _disposeVideo();
    }

    Widget backdrop;
    switch (config.kind) {
      case ChatWallpaperKind.none:
        backdrop = ColoredBox(color: cs.surface);
      case ChatWallpaperKind.asset:
        backdrop = Image.asset(
          config.asset ?? kChatWallpaperPresetAssets.first.asset,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        );
      case ChatWallpaperKind.image:
        final path = config.localPath;
        if (path == null || !File(path).existsSync()) {
          backdrop = ColoredBox(color: cs.surface);
        } else {
          backdrop = Image.file(
            File(path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
          );
        }
      case ChatWallpaperKind.video:
        final controller = _video;
        if (controller != null && controller.value.isInitialized) {
          backdrop = FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: controller.value.size.width,
              height: controller.value.size.height,
              child: VideoPlayer(controller),
            ),
          );
        } else {
          backdrop = ColoredBox(color: cs.surfaceContainerHighest);
        }
    }

    final blur = config.blur.clamp(0.0, 20.0);
    if (blur > 0.5) {
      backdrop = ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: backdrop,
      );
    }

    final dim = config.dim.clamp(0.0, 0.8);
    final scrimColor = switch (config.scrim) {
      ChatWallpaperScrim.none => null,
      ChatWallpaperScrim.light => Colors.white.withValues(alpha: 0.22),
      ChatWallpaperScrim.dark => Colors.black.withValues(alpha: 0.28),
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        backdrop,
        if (dim > 0)
          ColoredBox(color: Colors.black.withValues(alpha: dim)),
        if (scrimColor != null) ColoredBox(color: scrimColor),
      ],
    );
  }
}

/// Sample bubbles for wallpaper live preview in settings.
class ChatWallpaperPreviewMessages extends StatelessWidget {
  const ChatWallpaperPreviewMessages({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: _PreviewBubble(
              color: cs.surfaceContainerHighest,
              text: 'Hey — can you see this clearly?',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: _PreviewBubble(
              color: cs.primary,
              textColor: cs.onPrimary,
              text: 'Yes, bubbles look good on the wallpaper.',
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    required this.color,
    required this.text,
    this.textColor,
  });

  final Color color;
  final Color? textColor;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        text,
        style: TextStyle(color: textColor ?? Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}
