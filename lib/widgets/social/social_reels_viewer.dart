// SPDX-License-Identifier: AGPL-3.0
//
// Full-screen status / reels viewer — progress bars, swipe, video playback,
// TikTok-style engagement rail (like / comment / share / view).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../../models/social_post.dart';
import '../../services/auth_service.dart';
import '../../services/report_service.dart';
import '../../services/social_engagement_service.dart';
import '../../utils/chat_formatters.dart';
import '../../utils/talk_reel_urls.dart';
import '../user_avatar.dart';
import '../report/report_reason_sheet.dart';
import 'reel_embed_webview.dart';

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
  late List<SocialPost> _posts;
  VideoPlayerController? _video;
  Timer? _photoTimer;
  double _progress = 0;
  bool _paused = false;
  final Set<String> _viewedReelIds = {};
  final _engagement = ReelEngagementService.instance;

  static const _photoDuration = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _posts = List<SocialPost>.from(widget.posts);
    _index = widget.initialIndex;
    _page = PageController(initialPage: _index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSlide();
      _recordViewForCurrent();
    });
  }

  @override
  void dispose() {
    _photoTimer?.cancel();
    _disposeVideo();
    _page.dispose();
    super.dispose();
  }

  SocialPost get _post => _posts[_index];

  void _patchPost(int i, SocialPost updated) {
    if (i < 0 || i >= _posts.length) return;
    _posts[i] = updated;
  }

  Future<void> _recordViewForCurrent() async {
    final reelId = _post.engagementReelId;
    if (reelId == null || _viewedReelIds.contains(reelId)) return;
    _viewedReelIds.add(reelId);
    final count = await _engagement.recordView(reelId);
    if (!mounted || count == null) return;
    setState(() {
      _patchPost(_index, _post.copyWithEngagement(viewCount: count));
    });
  }

  Future<void> _toggleLike() async {
    final reelId = _post.engagementReelId;
    if (reelId == null) return;
    if (!await AuthService.instance.hasValidToken()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to like reels')),
        );
      }
      return;
    }
    final before = _posts[_index];
    final optimistic = before.copyWithEngagement(
      liked: !before.liked,
      likeCount: before.liked
          ? (before.likeCount > 0 ? before.likeCount - 1 : 0)
          : before.likeCount + 1,
    );
    setState(() => _patchPost(_index, optimistic));
    final res = await _engagement.toggleLike(reelId);
    if (!mounted) return;
    if (res == null) {
      setState(() => _patchPost(_index, before));
      return;
    }
    setState(() => _patchPost(
          _index,
          before.copyWithEngagement(liked: res.liked, likeCount: res.likeCount),
        ));
  }

  Future<void> _reportReel() async {
    final reelId = _post.engagementReelId;
    if (reelId == null) return;
    if (!mounted) return;
    final ok = await showReportReasonSheet(
      context,
      subjectLabel: 'reel',
      onSubmit: (reason, note) => ReportService.instance.reportReel(
        reelId: reelId,
        reason: reason,
        note: note,
      ),
    );
    if (!mounted) return;
    if (ok == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report submitted — thank you')),
      );
    } else if (ok == false) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit report — try again later')),
      );
    }
  }

  Future<void> _openComments() async {
    final reelId = _post.engagementReelId;
    if (reelId == null) return;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      builder: (ctx) => _ReelCommentsSheet(
        reelId: reelId,
        onPosted: (count) {
          if (!mounted) return;
          setState(() => _patchPost(_index, _post.copyWithEngagement(commentCount: count)));
        },
      ),
    );
  }

  Future<void> _shareReel() async {
    final reelId = _post.engagementReelId;
    if (reelId == null) return;
    final url = _post.shareUrl?.isNotEmpty == true
        ? _post.shareUrl!
        : talkReelShareUrl(reelId);
    final result = await Share.share(
      '${_post.authorName} on INTERACT\n$url',
      subject: _post.titleOrBody,
    );
    if (result.status == ShareResultStatus.success ||
        result.status == ShareResultStatus.unavailable) {
      if (!await AuthService.instance.hasValidToken()) return;
      final count = await _engagement.recordShare(reelId);
      if (!mounted || count == null) return;
      setState(() => _patchPost(_index, _post.copyWithEngagement(shareCount: count)));
    }
  }

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

    if (post.hasLocalMedia && post.isVideo) {
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

    if (post.isServerVideo && post.serverMediaUrl != null) {
      final controller =
          VideoPlayerController.networkUrl(Uri.parse(post.serverMediaUrl!));
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

    if (!post.hasLocalMedia && !post.hasServerMedia) {
      _schedulePhotoProgress();
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
    if (_index >= _posts.length - 1) {
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
    final showRail = _post.engagementReelId != null;
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
        onLongPress: _reportReel,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PageView.builder(
              controller: _page,
              itemCount: _posts.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                _startSlide();
                _recordViewForCurrent();
              },
              itemBuilder: (_, i) => _MediaSlide(
                post: _posts[i],
                video: i == _index ? _video : null,
              ),
            ),
            SafeArea(
              child: Column(
                children: [
                  _ProgressBars(
                    count: _posts.length,
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
            if (showRail)
              Positioned(
                right: 12,
                bottom: 120,
                child: _EngagementRail(
                  post: _post,
                  onLike: _toggleLike,
                  onComment: _openComments,
                  onShare: _shareReel,
                  onReport: _reportReel,
                ),
              ),
            if (_post.body.isNotEmpty)
              Positioned(
                left: 0,
                right: showRail ? 72 : 0,
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

extension _SocialPostShare on SocialPost {
  String get titleOrBody =>
      body.isNotEmpty ? body : authorName;
}

class _EngagementRail extends StatelessWidget {
  const _EngagementRail({
    required this.post,
    required this.onLike,
    required this.onComment,
    required this.onShare,
    required this.onReport,
  });

  final SocialPost post;
  final VoidCallback onLike;
  final VoidCallback onComment;
  final VoidCallback onShare;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RailButton(
          icon: post.liked ? Icons.favorite : Icons.favorite_border,
          label: _fmt(post.likeCount),
          iconColor: post.liked ? Colors.redAccent : Colors.white,
          onTap: onLike,
        ),
        const SizedBox(height: 18),
        _RailButton(
          icon: Icons.chat_bubble_outline,
          label: _fmt(post.commentCount),
          onTap: onComment,
        ),
        const SizedBox(height: 18),
        _RailButton(
          icon: Icons.share_outlined,
          label: _fmt(post.shareCount),
          onTap: onShare,
        ),
        const SizedBox(height: 18),
        _RailButton(
          icon: Icons.visibility_outlined,
          label: _fmt(post.viewCount),
          onTap: () {},
        ),
        const SizedBox(height: 18),
        _RailButton(
          icon: Icons.flag_outlined,
          label: 'Report',
          onTap: onReport,
        ),
      ],
    );
  }

  String _fmt(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: iconColor, size: 30),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReelCommentsSheet extends StatefulWidget {
  const _ReelCommentsSheet({
    required this.reelId,
    required this.onPosted,
  });

  final String reelId;
  final ValueChanged<int> onPosted;

  @override
  State<_ReelCommentsSheet> createState() => _ReelCommentsSheetState();
}

class _ReelCommentsSheetState extends State<_ReelCommentsSheet> {
  final _ctrl = TextEditingController();
  final _engagement = ReelEngagementService.instance;
  List<ReelComment> _items = [];
  bool _loading = true;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final items = await _engagement.listComments(widget.reelId);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _submit() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _posting) return;
    if (!await AuthService.instance.hasValidToken()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to comment')),
        );
      }
      return;
    }
    setState(() => _posting = true);
    final res = await _engagement.addComment(widget.reelId, text);
    if (!mounted) return;
    setState(() => _posting = false);
    if (res == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not post comment')),
      );
      return;
    }
    _ctrl.clear();
    setState(() => _items = [res.comment, ..._items]);
    widget.onPosted(res.commentCount);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.55,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Comments',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(color: Colors.white54),
                    )
                  : _items.isEmpty
                      ? const Center(
                          child: Text(
                            'No comments yet — be the first',
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (_, i) {
                            final c = _items[i];
                            return ListTile(
                              leading: UserAvatar(
                                url: c.authorAvatarUrl,
                                name: c.authorName,
                                radius: 16,
                              ),
                              title: Text(
                                c.authorName,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              subtitle: Text(
                                c.body,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            );
                          },
                        ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Add a comment…',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                        filled: true,
                        fillColor: Colors.white12,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      maxLength: 500,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
                          null,
                    ),
                  ),
                  IconButton(
                    onPressed: _posting ? null : _submit,
                    icon: _posting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send, color: Colors.white),
                  ),
                ],
              ),
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

  Future<void> _openExternal(BuildContext context) async {
    final raw = post.shareUrl;
    if (raw == null || raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

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

    if (post.isServerVideo && video != null && video!.value.isInitialized) {
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

    final embed = post.embedHtml?.trim();
    if (embed != null && embed.isNotEmpty) {
      final base = post.reelPlatform == ReelPlatform.twitter
          ? 'https://twitter.com'
          : 'https://www.tiktok.com';
      return ReelEmbedWebView(embedHtml: embed, baseUrl: base);
    }

    if (post.isServerPhoto && post.serverMediaUrl != null) {
      return Image.network(
        post.serverMediaUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _thumbnailOrText(context, post),
      );
    }

    final thumb = post.thumbnailUrl ?? _youtubeThumbUrl(post.linkUrl ?? post.mediaUrl);
    if (thumb != null) {
      return GestureDetector(
        onTap: () => _openExternal(context),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              thumb,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _textOnly(post),
            ),
            const Center(
              child: Icon(Icons.play_circle_fill, color: Colors.white70, size: 72),
            ),
            if (post.reelPlatform == ReelPlatform.tiktok ||
                post.reelPlatform == ReelPlatform.twitter)
              Positioned(
                bottom: 48,
                left: 0,
                right: 0,
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => _openExternal(context),
                    icon: const Icon(Icons.open_in_new, color: Colors.white),
                    label: const Text('Open original', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return _textOnly(post);
  }

  Widget _thumbnailOrText(BuildContext context, SocialPost post) {
    final thumb = post.thumbnailUrl;
    if (thumb != null && thumb.isNotEmpty) {
      return Image.network(thumb, fit: BoxFit.cover);
    }
    return _textOnly(post);
  }

  static String? _youtubeThumbUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    String? id;
    if (uri.host.contains('youtu.be')) {
      id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
    } else if (uri.host.contains('youtube.com')) {
      id = uri.queryParameters['v'];
      if (id == null && uri.pathSegments.contains('shorts') && uri.pathSegments.length > 1) {
        id = uri.pathSegments[uri.pathSegments.indexOf('shorts') + 1];
      }
    }
    if (id == null || id.isEmpty) return null;
    return 'https://img.youtube.com/vi/$id/hqdefault.jpg';
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
