// SPDX-License-Identifier: AGPL-3.0
//
// Add a persisted SocialReel — paste link (YouTube/TikTok/X) or upload local media.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/social_post.dart';
import '../../services/social_reels_api.dart';

class AddReelSheet extends StatefulWidget {
  const AddReelSheet({super.key});

  static Future<SocialPost?> show(BuildContext context) {
    return showModalBottomSheet<SocialPost>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const AddReelSheet(),
    );
  }

  @override
  State<AddReelSheet> createState() => _AddReelSheetState();
}

class _AddReelSheetState extends State<AddReelSheet> {
  final _linkCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _api = SocialReelsApi.instance;
  final _picker = ImagePicker();
  bool _busy = false;
  double _progress = 0;
  String? _status;

  @override
  void dispose() {
    _linkCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<SocialPost?> Function() task) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _progress = 0;
      _status = null;
    });
    final post = await task();
    if (!mounted) return;
    if (post != null) {
      Navigator.pop(context, post);
      return;
    }
    setState(() {
      _busy = false;
      _status = 'Could not add reel — check the link or try again';
    });
  }

  Future<void> _submitLink() async {
    final url = _linkCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _status = 'Paste a YouTube, TikTok, or X link');
      return;
    }
    await _run(() => _api.createReelFromUrl(url));
  }

  Future<void> _pickAndUpload({required bool video}) async {
    final file = video
        ? await _picker.pickVideo(
            source: ImageSource.gallery,
            maxDuration: const Duration(seconds: 60),
          )
        : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;

    await _run(() async {
      setState(() {
        _progress = 0.2;
        _status = 'Uploading…';
      });
      final up = await _api.uploadMediaFile(File(file.path));
      if (up == null) return null;
      setState(() {
        _progress = 0.65;
        _status = 'Creating reel…';
      });
      var title = _titleCtrl.text.trim();
      if (title.isEmpty) {
        final suggestion = await _api.suggestCaption(title: video ? 'Video reel' : 'Photo reel');
        if (suggestion != null) {
          title = suggestion.caption;
          if (suggestion.hashtags.isNotEmpty) {
            title = '$title ${suggestion.hashtags.join(' ')}';
          }
          if (mounted) _titleCtrl.text = title;
        }
      }
      final mediaType = up.mediaType == 'photo' || up.mediaType == 'image'
          ? 'photo'
          : 'video';
      return _api.createLocalReel(
        mediaUrl: up.url,
        mediaType: mediaType,
        title: title.isNotEmpty ? title : null,
      );
    });
  }

  Future<void> _suggestCaption() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Suggesting caption…';
    });
    final s = await _api.suggestCaption(title: _titleCtrl.text.trim());
    if (!mounted) return;
    setState(() => _busy = false);
    if (s == null) {
      setState(() => _status = 'Caption assist unavailable — type your own');
      return;
    }
    final combined = s.hashtags.isEmpty
        ? s.caption
        : '${s.caption} ${s.hashtags.join(' ')}';
    _titleCtrl.text = combined.trim();
    setState(() => _status = null);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Add reel', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _linkCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Paste link',
              hintText: 'YouTube, TikTok, or X/Twitter',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _submitLink,
            icon: const Icon(Icons.link),
            label: const Text('Add from link'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _titleCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Caption (optional)',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _suggestCaption,
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Suggest caption'),
          ),
          const SizedBox(height: 12),
          Text('Upload from device', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickAndUpload(video: false),
                icon: const Icon(Icons.photo_outlined),
                label: const Text('Photo'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _pickAndUpload(video: true),
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Video'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ] else if (_status != null) ...[
            const SizedBox(height: 12),
            Text(
              _status!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}
