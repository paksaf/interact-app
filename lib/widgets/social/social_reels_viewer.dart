// SPDX-License-Identifier: AGPL-3.0
//
// Full-screen status / reels viewer — progress bars, swipe, video playback.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../models/social_post.dart';
import '../../utils/chat_formatters.dart';
import '../user_avatar.dart';

class SocialReelsViewer extends StatefulWidget {
  const SocialReelsViewer({
    super.key,
    required this.posts,
    this.initialIndex = 0,
  });

  final List<SocialPost> posts;
  final int initialIndex;

  static Future<void> open(
    BuildContext context, {
    required List<SocialPost> posts,
    int initialIndex = 0,
  }) {
    if (posts.isEmpty) return Future.value();
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        pageBuilder: (_, __, ___) => SocialReelsViewer(
          posts: posts,
          initialIndex: initialIndex.clamp(0, posts.length - 1),
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<SocialReelsViewer> createState() => _SocialReelsViewerState();
}

class _SocialReelsViewerState extends State<SocialReelsViewer> {
  late PageController _page;
  late int _index;
  VideoPlayerController? _video;
  Timer? _photoTimer;
  double _progress = 0;
  bool _paused = false;

  static const _photoDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSlide());
  }

  @override
  void dispose() {
    _photoTimer?.cancel();
    _disposeVideo();
    _page.dispose();
    super.dispose();
  }

  SocialPost get _post => widget.posts[_index];

  Future<void> _disposeVideo() async {
    final v = _video;
    _video = null;
    if (v != null) {
      await v.pause();
      await v.dispose();
    }
  }

  Future<void> _startSlide() async {
    _photoTimer?.cancel();
    setState(() => _progress = 0);
    await _disposeVideo();

    final post = _post;
    if (!post.hasLocalMedia) {
      _schedulePhotoProgress();
      return;
    }

    if (post.isVideo) {
      final file = File(post.mediaPath!);
      if (!await file.exists()) {
        _schedulePhotoProgress();
        return;
      }
      final controller = VideoPlayerController.file(file);
      _video = controller;
      try {
        await controller.initialize();
        controller.setLooping(false);
        controller.addListener(_onVideoTick);
        if (!_paused) await controller.play();
        if (mounted) setState(() {});
      } catch (_) {
        await _disposeVideo();
        _schedulePhotoProgress();
      }
      return;
    }

    _schedulePhotoProgress();
  }

  void _onVideoTick() {
    final v = _video;
    if (v == null || !v.value.isInitialized || !mounted) return;
    final dur = v.value.duration.inMilliseconds;
    if (dur <= 0) return;
    setState(() {
      _progress = v.value.position.inMilliseconds / dur;
    });
    if (v.value.position >= v.value.duration) {
      _next();
    }
  }

  void _schedulePhotoProgress() {
    _photoTimer?.cancel();
    if (_paused) return;
    const tick = Duration(milliseconds: 50);
    var elapsed = Duration.zero;
    _photoTimer = Timer.periodic(tick, (t) {
      if (_paused || !mounted) return;
      elapsed += tick;
      setState(() {
        _progress = elapsed.inMilliseconds / _photoDuration.inMilliseconds;
      });
      if (elapsed >= _photoDuration) {
        t.cancel();
        _next();
      }
    });
  }

  void _next() {
    if (_index >= widget.posts.length - 1) {
      Navigator.of(context).maybePop();
      return;
    }
    _page.nextPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _prev() {
    if (_index <= 0) return;
    _page.previousPage(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    final v = _video;
    if (v != null && v.value.isInitialized) {
      _paused ? v.pause() : v.play();
    } else if (!_paused) {
      _schedulePhotoProgress();
    } else {
      _photoTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.sizeOf(context).width;
          if (d.localPosition.dx < w * 0.35) {
            _prev();
          } else if (d.localPosition.dx > w * 0.65) {
            _next();
          } else {
            _togglePause();
          }
        },
        onLongPress: _togglePause,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _page,
              itemCount: widget.posts.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _startSlide();
              },
              itemBuilder: (_, i) => _MediaSlide(post: widget.posts[i], video: i == _index ? _video : null),
            ),
            SafeArea(
              child: Column(
                children: [
                  _ProgressBars(
                    count: widget.posts.length,
                    index: _index,
                    progress: _progress,
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                    child: Row(
                      children: [
                        UserAvatar(
                          url: _post.authorAvatarUrl,
                          name: _post.authorName,
                          radius: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _post.authorName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                relTime(_post.createdAt),
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (_post.body.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.85),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
                    child: Text(
                      _post.body,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            if (_paused)
              const Center(
                child: Icon(Icons.pause_circle_outline,
                    color: Colors.white70, size: 64),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBars extends StatelessWidget {
  const _ProgressBars({
    required this.count,
    required this.index,
    required this.progress,
  });

  final int count;
  final int index;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: List.generate(count, (i) {
          final filled = (i < index ? 1.0 : (i == index ? progress.clamp(0.0, 1.0) : 0.0)).toDouble();
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i < count - 1 ? 4 : 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: filled,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  color: Colors.white,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _MediaSlide extends StatelessWidget {
  const _MediaSlide({required this.post, this.video});

  final SocialPost post;
  final VideoPlayerController? video;

  @override
  Widget build(BuildContext context) {
    if (post.hasLocalMedia && post.isVideo && video != null && video!.value.isInitialized) {
      return FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: video!.value.size.width,
          height: video!.value.size.height,
          child: VideoPlayer(video!),
        ),
      );
    }

    if (post.hasLocalMedia && post.isPhoto) {
      return Image.file(
        File(post.mediaPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _textOnly(post),
      );
    }

    return _textOnly(post);
  }

  Widget _textOnly(SocialPost post) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E3A5F), Color(0xFF0F172A)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Text(
        post.body.isNotEmpty ? post.body : post.authorName,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Colors.white, fontSize: 22),
      ),
    );
  }
}
