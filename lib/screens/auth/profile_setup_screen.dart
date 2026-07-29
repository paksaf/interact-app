// SPDX-License-Identifier: AGPL-3.0
//
// ProfileSetupScreen — first-run profile builder shown right after a brand-new
// user registers (open self-registration). Collects a display name + optional
// avatar, saves them to the Talk backend, then lands the user in the app.
// Reachable at /profile-setup; a returning user never sees this.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/auth_service.dart';
import '../../services/chat_api.dart';
import '../../widgets/user_avatar.dart';

class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});
  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _nameCtrl = TextEditingController();
  String? _avatarUrl;
  bool _uploadingAvatar = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Seed with any name the server already has (e.g. an email prefix) so the
    // field isn't blank — the user can overwrite it.
    ref.read(authServiceProvider).displayName().then((n) {
      if (mounted && n != null && n.isNotEmpty && n != 'INTERACT user') {
        _nameCtrl.text = n;
      }
    });
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    if (_uploadingAvatar) return;
    final XFile? picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 640,
      imageQuality: 85,
    );
    if (picked == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final url =
          await ref.read(chatApiProvider).setAvatarFromFile(File(picked.path));
      if (!mounted) return;
      setState(() => _avatarUrl = url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not upload photo: $e')),
      );
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Enter your name (at least 2 characters).');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await ref.read(chatApiProvider).setDisplayName(name);
      await ref.read(authServiceProvider).setLocalName(saved);
      if (!mounted) return;
      context.go('/calls');
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up your profile')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 8),
            Text(
              'Welcome! Add a name and photo so people know who they’re '
              'talking to. You can change these anytime.',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            Center(
              child: Stack(
                children: [
                  UserAvatar(
                    url: _avatarUrl,
                    name: _nameCtrl.text,
                    radius: 52,
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: cs.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _uploadingAvatar ? null : _pickAvatar,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: _uploadingAvatar
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: cs.onPrimary,
                                  ),
                                )
                              : Icon(Icons.camera_alt,
                                  size: 20, color: cs.onPrimary),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
            TextField(
              controller: _nameCtrl,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              maxLength: 60,
              onChanged: (_) => setState(() {}), // live-refresh avatar initials
              decoration: const InputDecoration(
                labelText: 'Your name',
                hintText: 'e.g. Ayesha Khan',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: cs.error)),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Continue'),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : () => context.go('/calls'),
              child: const Text('Skip for now'),
            ),
          ],
        ),
      ),
    );
  }
}
