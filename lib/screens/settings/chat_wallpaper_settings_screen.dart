// SPDX-License-Identifier: AGPL-3.0
//
// Chat wallpaper settings — global default with live preview, crop/trim flow.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/theme/chat_wallpaper_prefs.dart';
import '../../l10n/app_localizations.dart';
import '../../services/chat_wallpaper_storage.dart';
import '../../widgets/branded_app_bar.dart';
import '../../widgets/chat/chat_wallpaper_crop.dart';
import '../../widgets/chat/chat_wallpaper_layer.dart';
import '../settings/video_wallpaper_trim_screen.dart';

enum ChatWallpaperEditorScope { global, thread }

Future<void> showChatWallpaperEditor(
  BuildContext context,
  WidgetRef ref, {
  required ChatWallpaperEditorScope scope,
  String? threadId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.55,
      maxChildSize: 0.96,
      builder: (_, scrollCtrl) => ChatWallpaperEditorPanel(
        scope: scope,
        threadId: threadId,
        scrollController: scrollCtrl,
      ),
    ),
  );
}

class ChatWallpaperSettingsScreen extends ConsumerWidget {
  const ChatWallpaperSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: BrandedAppBar(
        title: l10n.chatWallpaperTitle,
        subtitle: l10n.chatWallpaperSubtitle,
        showBrandGlyph: true,
      ),
      body: const ChatWallpaperEditorPanel(
        scope: ChatWallpaperEditorScope.global,
      ),
    );
  }
}

class ChatWallpaperEditorPanel extends ConsumerStatefulWidget {
  const ChatWallpaperEditorPanel({
    super.key,
    required this.scope,
    this.threadId,
    this.scrollController,
  });

  final ChatWallpaperEditorScope scope;
  final String? threadId;
  final ScrollController? scrollController;

  @override
  ConsumerState<ChatWallpaperEditorPanel> createState() =>
      _ChatWallpaperEditorPanelState();
}

class _ChatWallpaperEditorPanelState
    extends ConsumerState<ChatWallpaperEditorPanel> {
  late ChatWallpaperConfig _draft;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(chatWallpaperControllerProvider);
    _draft = widget.scope == ChatWallpaperEditorScope.global
        ? state.global
        : state.resolve(widget.threadId);
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
      requestFullMetadata: false,
    );
    if (x == null || !mounted) return;
    final cropped = await cropChatWallpaperImage(context, File(x.path));
    if (cropped == null || !mounted) return;
    final saved = await ChatWallpaperStorage.instance.persistImage(cropped);
    setState(() {
      _draft = _draft.copyWith(
        kind: ChatWallpaperKind.image,
        clearAsset: true,
        clearRemoteMediaUrl: true,
        localPath: saved.path,
      );
    });
  }

  Future<void> _pickVideo() async {
    final x = await ImagePicker().pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(seconds: 30),
    );
    if (x == null || !mounted) return;
    final trimmed = await pickAndTrimVideoWallpaper(context, File(x.path));
    if (trimmed == null || !mounted) return;
    setState(() {
      _draft = _draft.copyWith(
        kind: ChatWallpaperKind.video,
        clearAsset: true,
        clearRemoteMediaUrl: true,
        localPath: trimmed.path,
      );
    });
  }

  void _selectPreset(String asset) {
    setState(() {
      _draft = _draft.copyWith(
        kind: ChatWallpaperKind.asset,
        asset: asset,
        clearLocalPath: true,
        clearRemoteMediaUrl: true,
      );
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final controller = ref.read(chatWallpaperControllerProvider.notifier);
      if (widget.scope == ChatWallpaperEditorScope.global) {
        await controller.setGlobal(_draft);
      } else if (widget.threadId != null) {
        await controller.setThread(widget.threadId!, _draft);
      }
      if (mounted) {
        if (widget.scrollController != null) {
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context).save)),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    final controller = ref.read(chatWallpaperControllerProvider.notifier);
    if (widget.scope == ChatWallpaperEditorScope.global) {
      await controller.setGlobal(const ChatWallpaperConfig());
    } else if (widget.threadId != null) {
      await controller.clearThread(widget.threadId!);
    }
    if (!mounted) return;
    setState(() => _draft = const ChatWallpaperConfig());
    if (widget.scrollController != null) {
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).chatWallpaperReset)),
      );
    }
  }

  String _presetLabel(AppLocalizations l10n, String id) {
    switch (id) {
      case 'office':
        return l10n.chatWallpaperPresetOffice;
      case 'brand':
        return l10n.chatWallpaperPresetBrand;
      case 'warm':
        return l10n.chatWallpaperPresetWarm;
      case 'signal':
        return l10n.chatWallpaperPresetSignal;
      default:
        return id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final isSheet = widget.scrollController != null;

    return ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(16, isSheet ? 0 : 8, 16, 24),
      children: [
        if (isSheet)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              widget.scope == ChatWallpaperEditorScope.global
                  ? l10n.chatWallpaperTitle
                  : l10n.chatWallpaperThreadTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: 200,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ChatWallpaperLayer(previewConfig: _draft),
                const ChatWallpaperPreviewMessages(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(l10n.chatWallpaperPresets,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in kChatWallpaperPresetAssets)
              ChoiceChip(
                label: Text(_presetLabel(l10n, preset.id)),
                selected: _draft.kind == ChatWallpaperKind.asset &&
                    _draft.asset == preset.asset,
                onSelected: (_) => _selectPreset(preset.asset),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_outlined),
                label: Text(l10n.chatWallpaperPickImage),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickVideo,
                icon: const Icon(Icons.movie_outlined),
                label: Text(l10n.chatWallpaperPickVideo),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(l10n.chatWallpaperDim,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: _draft.dim.clamp(0, 0.8),
          min: 0,
          max: 0.8,
          divisions: 16,
          label: '${(_draft.dim * 100).round()}%',
          onChanged: (v) => setState(() => _draft = _draft.copyWith(dim: v)),
        ),
        Text(l10n.chatWallpaperBlur,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        Slider(
          value: _draft.blur.clamp(0, 20),
          min: 0,
          max: 20,
          divisions: 20,
          label: _draft.blur.round().toString(),
          onChanged: (v) => setState(() => _draft = _draft.copyWith(blur: v)),
        ),
        Text(l10n.chatWallpaperScrim,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        SegmentedButton<ChatWallpaperScrim>(
          segments: [
            ButtonSegment(
              value: ChatWallpaperScrim.none,
              label: Text(l10n.chatWallpaperScrimNone),
            ),
            ButtonSegment(
              value: ChatWallpaperScrim.light,
              label: Text(l10n.chatWallpaperScrimLight),
            ),
            ButtonSegment(
              value: ChatWallpaperScrim.dark,
              label: Text(l10n.chatWallpaperScrimDark),
            ),
          ],
          selected: {_draft.scrim},
          onSelectionChanged: (s) =>
              setState(() => _draft = _draft.copyWith(scrim: s.first)),
        ),
        if (widget.scope == ChatWallpaperEditorScope.thread) ...[
          const SizedBox(height: 12),
          Text(
            l10n.chatWallpaperThreadHint,
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.save),
        ),
        TextButton(
          onPressed: _reset,
          child: Text(
            widget.scope == ChatWallpaperEditorScope.global
                ? l10n.chatWallpaperReset
                : l10n.chatWallpaperUseGlobal,
          ),
        ),
      ],
    );
  }
}
