// SPDX-License-Identifier: AGPL-3.0
//
// Trim a picked video loop for chat wallpaper (≤10s, muted playback).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_trimmer/video_trimmer.dart';

import '../../services/chat_wallpaper_storage.dart';

class VideoWallpaperTrimScreen extends StatefulWidget {
  const VideoWallpaperTrimScreen({super.key, required this.source});

  final File source;

  @override
  State<VideoWallpaperTrimScreen> createState() =>
      _VideoWallpaperTrimScreenState();
}

class _VideoWallpaperTrimScreenState extends State<VideoWallpaperTrimScreen> {
  final Trimmer _trimmer = Trimmer();
  double _start = 0;
  double _end = 0;
  bool _loaded = false;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await _trimmer.loadVideo(videoFile: widget.source);
      setState(() => _loaded = true);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _trimmer.dispose();
    super.dispose();
  }

  void _export() {
    if (_exporting || !_loaded) return;
    setState(() => _exporting = true);
    _trimmer.saveTrimmedVideo(
      startValue: _start,
      endValue: _end,
      onSave: (outputPath) async {
        if (!mounted) return;
        setState(() => _exporting = false);
        if (outputPath == null) return;
        try {
          final file = File(outputPath);
          final size = await file.length();
          if (!mounted) return;
          if (size > ChatWallpaperStorage.maxVideoBytes) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Trimmed clip is too large — pick a shorter segment',
                ),
              ),
            );
            return;
          }
          final saved = await ChatWallpaperStorage.instance.persistVideo(file);
          if (mounted) Navigator.pop(context, saved);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not trim video: $e')),
            );
          }
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim video loop'),
        actions: [
          TextButton(
            onPressed: _loaded && !_exporting ? _export : null,
            child: _exporting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Use clip'),
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text(_error!))
          : !_loaded
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    Expanded(
                      child: VideoViewer(trimmer: _trimmer),
                    ),
                    TrimViewer(
                      trimmer: _trimmer,
                      viewerHeight: 48,
                      viewerWidth: width,
                      maxVideoLength: const Duration(seconds: 10),
                      onChangeStart: (v) => setState(() => _start = v),
                      onChangeEnd: (v) => setState(() => _end = v),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Loop cap: 10 seconds · muted · pauses when app is backgrounded',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

Future<File?> pickAndTrimVideoWallpaper(BuildContext context, File source) {
  return Navigator.of(context).push<File>(
    MaterialPageRoute(builder: (_) => VideoWallpaperTrimScreen(source: source)),
  );
}
