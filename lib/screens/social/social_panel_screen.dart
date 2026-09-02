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
import '../../services/family_circle_store.dart';
import '../../services/location_trace_service.dart';
import '../../services/presence_service.dart';
import '../../services/social_feed_service.dart';
import '../../services/talk_api.dart';
import '../../utils/chat_formatters.dart';
import '../../widgets/branded_app_bar.dart';
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
  bool _busy = true;

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
    final feed = await ref.read(socialFeedServiceProvider).buildFeed(filter: _filter);
    final circle = await ref.read(familyCircleStoreProvider).listMembers();
    if (!mounted) return;
    setState(() {
      _feed = feed;
      _circle = circle;
      _busy = false;
    });
  }

  Future<void> _compose() async {
    final ctrl = TextEditingController();
    SocialAudience audience = SocialAudience.family;
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
            builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Share an update',
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: 'What\'s happening with family?',
                    border: OutlineInputBorder(),
                  ),
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
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Post'),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (posted != true || !mounted) return;
    final body = ctrl.text.trim();
    if (body.isEmpty) return;
    await ref.read(socialFeedServiceProvider).publishStatus(
          body: body,
          audience: audience,
        );
    await _reload();
  }

  Future<void> _composePhoto() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
    if (file == null || !mounted) return;
    final caption = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          title: const Text('Photo caption'),
          content: TextField(controller: c, autofocus: true, maxLines: 3),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('Post'),
            ),
          ],
        );
      },
    );
    await ref.read(socialFeedServiceProvider).publishStatus(
          body: caption ?? '',
          audience: SocialAudience.family,
          mediaPath: file.path,
        );
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
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'photo',
                  onPressed: _composePhoto,
                  child: const Icon(Icons.photo_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.extended(
                  heroTag: 'status',
                  onPressed: _compose,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Update'),
                ),
              ],
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
          if (_circle.isNotEmpty)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 96,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.all(12),
                  itemCount: _circle.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 12),
                  itemBuilder: (_, i) {
                    final m = _circle[i];
                    final online = m.phone != null &&
                        ref.watch(presenceServiceProvider).status(m.phone!) !=
                            PresenceStatus.offline;
                    return Column(
                      children: [
                        Stack(
                          children: [
                            UserAvatar(name: m.displayName, radius: 28),
                            if (online)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF22C55E),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: cs.surface, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          width: 64,
                          child: Text(
                            m.displayName.split(' ').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          if (_feed.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No updates yet — post something for family')),
            )
          else
            SliverList.separated(
              itemCount: _feed.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _FeedTile(post: _feed[i], cs: cs),
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
                'Add family and close friends to see them in your feed row '
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

class _FeedTile extends StatelessWidget {
  const _FeedTile({required this.post, required this.cs});
  final SocialPost post;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final kindLabel = switch (post.kind) {
      SocialPostKind.announcement => 'Announcement',
      SocialPostKind.photo => 'Photo',
      SocialPostKind.location => 'Location',
      SocialPostKind.status => 'Update',
    };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: UserAvatar(
        url: post.authorAvatarUrl,
        name: post.authorName,
        radius: 22,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              post.authorName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(relTime(post.createdAt), style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$kindLabel · ${post.audience.label}',
              style: TextStyle(fontSize: 11, color: cs.outline)),
          if (post.body.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(post.body),
          ],
          if (post.mediaPath != null && post.mediaPath!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(post.mediaPath!),
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
          if (post.sourceThreadId != null)
            TextButton(
              onPressed: () => context.push('/chat/${post.sourceThreadId}'),
              child: Text('Open ${post.sourceThreadTitle ?? 'channel'}'),
            ),
        ],
      ),
    );
  }
}
