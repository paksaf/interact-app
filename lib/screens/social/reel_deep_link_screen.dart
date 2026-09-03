// SPDX-License-Identifier: AGPL-3.0
//
// Resolves https://talk.interactpak.com/reel/{id} → full-screen viewer.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../services/social_reels_api.dart';
import '../../widgets/social/social_reels_viewer.dart';

class ReelDeepLinkScreen extends StatefulWidget {
  const ReelDeepLinkScreen({super.key, required this.reelId});

  final String reelId;

  @override
  State<ReelDeepLinkScreen> createState() => _ReelDeepLinkScreenState();
}

class _ReelDeepLinkScreenState extends State<ReelDeepLinkScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final post = await SocialReelsApi.instance.fetchReelById(widget.reelId);
    if (!mounted) return;
    if (post == null) {
      setState(() => _error = 'Reel not found or unavailable.');
      return;
    }
    await SocialReelsViewer.open(context, posts: [post]);
    if (!mounted) return;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/calls');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: const Color(0xFF0D4A5C),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D4A5C),
        foregroundColor: Colors.white,
        title: const Text('Reel'),
      ),
      body: Center(
        child: _error == null
            ? const CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFBE9A5F)),
              )
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.videocam_off_outlined,
                        size: 48, color: cs.error),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () => context.go('/social-panel'),
                      child: const Text('Open Friends & Family'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
