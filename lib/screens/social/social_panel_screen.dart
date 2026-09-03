// SPDX-License-Identifier: AGPL-3.0
//
// Friends & Family social panel — feed, circles, tracking shortcuts.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../models/family_circle.dart';
import '../../models/social_post.dart';
import '../../services/auth_service.dart';
import '../../services/chat_api.dart';
import '../../services/family_circle_store.dart';
import '../../services/location_trace_service.dart';
import '../../services/social_feed_service.dart';
import '../../services/talk_api.dart';
import '../../widgets/branded_app_bar.dart';
import '../../widgets/social/social_feed_card.dart';
import '../../services/social_reels_viewer_launcher.dart';
import '../../widgets/social/social_stories_row.dart';
import '../../widgets/user_avatar.dart';

class SocialPanelScreen extends ConsumerStatefulWidget {
  const SocialPanelScreen({super.key});

  @override
  ConsumerState<SocialPanelScreen> createState() => _SocialPanelScreenState();
}

class _SocialPanelScreenState extends ConsumerState<SocialPanelScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  SocialAudience? _filter;
  List<SocialPost> _feed = const [];
  List<FamilyCircleMember> _circle = const [];
  Map<String, List<SocialPost>> _storiesByAuthor = const {};
  String _myAuthorId = 'local';
  String _myName = 'Me';
  String? _myAvatarUrl;
  bool _busy = true;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
    _reload();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _busy = true);
    final svc = ref.read(socialFeedServiceProvider);
    final feed = await svc.buildFeed(filter: _filter);
    final circle = await ref.read(familyCircleStoreProvider).listMembers();
    final stories = await svc.recentStoriesByAuthor();
    final myId = await ref.read(authServiceProvider).localUserId() ?? 'local';
    final myName = await ref.read(authServiceProvider).displayName() ?? 'Me';
    final myAvatar = await ref.read(chatApiProvider).getAvatar();
    if (!mounted) return;
    setState(() {
      _feed = feed;
      _circle = circle;
      _storiesByAuthor = stories;
      _myAuthorId = myId;
      _myName = myName;
      _myAvatarUrl = myAvatar;
      _busy = false;
    });
  }

  List<SocialPost> get _mediaPosts =>
      _feed.where((p) => p.hasLocalMedia).toList();

  Future<void> _openCompose({bool pickMediaFirst = false}) async {
    final caption = TextEditingController();
    SocialAudience audience = SocialAudience.family;
    XFile? picked;
    SocialPostKind? mediaKind;

    Future<void> pick({
      required ImageSource source,
      required bool video,
    }) async {
      final file = video
          ? await _picker.pickVideo(source: source, maxDuration: const Duration(seconds: 60))
          : await _picker.pickImage(source: source, imageQuality: 85);
      if (file != null) {
        picked = file;
        mediaKind = video ? SocialPostKind.video : SocialPostKind.photo;
      }
    }

    if (pickMediaFirst) {
      await pick(source: ImageSource.gallery, video: false);
      if (!mounted) return;
    }

    final posted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 8,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) {
              final canPost = caption.text.trim().isNotEmpty || picked != null;
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      picked == null ? 'Share an update' : 'Share media',
                      style: Theme.of(ctx).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    if (picked != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: mediaKind == SocialPostKind.video ? 9 / 16 : 4 / 5,
                          child: mediaKind == SocialPostKind.video
                              ? Container(
                                  color: const Color(0xFF1E1B4B),
                                  child: const Center(
                                    child: Icon(Icons.videocam, color: Colors.white54, size: 48),
                                  ),
                                )
                              : Image.file(
                                  File(picked!.path),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => ColoredBox(
                                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                                    child: const Center(child: Icon(Icons.image_outlined)),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: caption,
                      autofocus: picked == null,
                      maxLines: 4,
                      onChanged: (_) => setLocal(() {}),
                      decoration: InputDecoration(
                        hintText: picked == null
                            ? 'What\'s happening with family?'
                            : 'Add a caption (optional)',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text('Attach', style: Theme.of(ctx).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _MediaChip(
                          icon: Icons.photo_library_outlined,
                          label: 'Gallery',
                          onTap: () async {
                            await pick(source: ImageSource.gallery, video: false);
                            setLocal(() {});
                          },
                        ),
                        _MediaChip(
                          icon: Icons.video_library_outlined,
                          label: 'Video',
                          onTap: () async {
                            await pick(source: ImageSource.gallery, video: true);
                            setLocal(() {});
                          },
                        ),
                        _MediaChip(
                          icon: Icons.photo_camera_outlined,
                          label: 'Camera',
                          onTap: () async {
                            await pick(source: ImageSource.camera, video: false);
                            setLocal(() {});
                          },
                        ),
                        _MediaChip(
                          icon: Icons.videocam_outlined,
                          label: 'Record',
                          onTap: () async {
                            await pick(source: ImageSource.camera, video: true);
                            setLocal(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Who can see this', style: Theme.of(ctx).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: SocialAudience.values.map((a) {
                        return ChoiceChip(
                          label: Text(a.label),
                          selected: audience == a,
                          onSelected: (_) => setLocal(() => audience = a),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: canPost ? () => Navigator.pop(ctx, true) : null,
                      child: const Text('Post'),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );

    if (posted != true || !mounted) {
      caption.dispose();
      return;
    }

    final body = caption.text.trim();
    caption.dispose();

    if (picked != null && mediaKind != null) {
      await ref.read(socialFeedServiceProvider).publishMedia(
            localPath: picked!.path,
            kind: mediaKind!,
            body: body,
            audience: audience,
          );
    } else if (body.isNotEmpty) {
      await ref.read(socialFeedServiceProvider).publishStatus(
            body: body,
            audience: audience,
          );
    } else {
      return;
    }
    await _reload();
  }

  Future<void> _addToCircle() async {
    final contacts = await ref.read(talkApiProvider).recentContacts();
    if (!mounted) return;
    if (contacts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No contacts yet — call or chat someone first, or use Find friends.'),
        ),
      );
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView.builder(
        itemCount: contacts.length,
        itemBuilder: (_, i) {
          final r = contacts[i];
          final name = (r['name'] as String?) ?? (r['phone'] as String?) ?? '?';
          return ListTile(
            title: Text(name),
            subtitle: Text((r['phone'] as String?) ?? ''),
            onTap: () => Navigator.pop(ctx, r),
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    final phone = picked['phone'] as String?;
    final userId = picked['userId'] as String?;
    final name = (picked['name'] as String?) ?? phone ?? 'Friend';
    final circle = await showDialog<FamilyCircleKind>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Add to circle'),
        children: FamilyCircleKind.values
            .map(
              (c) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, c),
                child: Text(c.label),
              ),
            )
            .toList(),
      ),
    );
    if (circle == null) return;
    await ref.read(familyCircleStoreProvider).upsertMember(
          FamilyCircleMember(
            key: FamilyCircleStore.memberKey(userId: userId, phone: phone),
            phone: phone,
            userId: userId,
            displayName: name,
            circle: circle,
            addedAt: DateTime.now(),
          ),
        );
    await _reload();
  }

  Future<void> _openStories(String authorId, List<SocialPost> posts) async {
    await SocialReelsViewerLauncher.instance.open(
      context,
      authorId: authorId,
      posts: posts,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fixes = LocationTraceService.instance.fixes;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: 'Friends & Family',
        subtitle: 'Updates · circles · trace',
        showBrandGlyph: true,
        showHomeShortcut: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.person_search_outlined),
            tooltip: 'Find friends',
            onPressed: () => context.push('/find-friends'),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Feed'),
            Tab(text: 'Circles'),
            Tab(text: 'Track'),
          ],
        ),
      ),
      floatingActionButton: _tabs.index == 0
          ? FloatingActionButton.extended(
              heroTag: 'share',
              onPressed: () => _openCompose(),
              icon: const Icon(Icons.add),
              label: const Text('Share'),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          _feedTab(cs),
          _circlesTab(cs),
          _trackTab(cs, fixes.length),
        ],
      ),
    );
  }

  Widget _feedTab(ColorScheme cs) {
    if (_busy) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Wrap(
                spacing: 8,
                children: [
                  FilterChip(
                    label: const Text('All'),
                    selected: _filter == null,
                    onSelected: (_) {
                      setState(() => _filter = null);
                      _reload();
                    },
                  ),
                  ...SocialAudience.values.map(
                    (a) => FilterChip(
                      label: Text(a.label),
                      selected: _filter == a,
                      onSelected: (_) {
                        setState(() => _filter = a);
                        _reload();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SocialStoriesRow(
              storiesByAuthor: _storiesByAuthor,
              myAuthorId: _myAuthorId,
              myName: _myName,
              myAvatarUrl: _myAvatarUrl,
              onAddStory: () => _openCompose(pickMediaFirst: true),
              onOpenStories: _openStories,
            ),
          ),
          if (_feed.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No updates yet — tap Share to post text, photos, or video for family',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => SocialFeedCard(
                  post: _feed[i],
                  allMediaPosts: _mediaPosts,
                ),
                childCount: _feed.length,
              ),
            ),
        ],
      ),
    );
  }

  Widget _circlesTab(ColorScheme cs) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          FilledButton.icon(
            onPressed: _addToCircle,
            icon: const Icon(Icons.person_add),
            label: const Text('Add from contacts'),
          ),
          const SizedBox(height: 12),
          ...FamilyCircleKind.values.map((kind) {
            final members = _circle.where((m) => m.circle == kind).toList();
            if (members.isEmpty) return const SizedBox.shrink();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(kind.label,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                ...members.map(
                  (m) => ListTile(
                    leading: UserAvatar(name: m.displayName, radius: 20),
                    title: Text(m.displayName),
                    subtitle: Text(m.phone ?? m.userId ?? ''),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () async {
                        await ref
                            .read(familyCircleStoreProvider)
                            .removeMember(m.key);
                        await _reload();
                      },
                    ),
                  ),
                ),
              ],
            );
          }),
          if (_circle.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 32),
              child: Text(
                'Add family and close friends to see them in your status row '
                'and filter updates.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.outline),
              ),
            ),
        ],
      ),
    );
  }

  Widget _trackTab(ColorScheme cs, int fixCount) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: Icon(Icons.map_rounded, color: cs.primary),
            title: const Text('INTERACT Friends map'),
            subtitle: const Text('In-app map — live pins, offline tiles'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/friends-map'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(Icons.my_location, color: cs.primary),
            title: const Text('Location trace'),
            subtitle: Text('$fixCount recent fixes from chat & IoT'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/location-trace'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(Icons.share_location_outlined, color: cs.primary),
            title: const Text('Share live location in chat'),
            subtitle: const Text('Attach → Share live location (15m / 1h / 8h)'),
            onTap: () => context.go('/chats'),
          ),
        ),
        Card(
          child: ListTile(
            leading: Icon(Icons.campaign_outlined, color: cs.primary),
            title: const Text('Family announcements channel'),
            subtitle: const Text('Create a broadcast channel for one-way updates'),
            onTap: () => context.go('/chats'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Location pins and live share work offline over LAN/BLE when cloud '
          'is down. E2E encryption for location is Phase 1.5 (libsignal).',
          style: TextStyle(fontSize: 12, color: cs.outline),
        ),
      ],
    );
  }
}

class _MediaChip extends StatelessWidget {
  const _MediaChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
    );
  }
}
