// SPDX-License-Identifier: AGPL-3.0
//
// InviteSheet — bottom-sheet shown when the user tries to start a chat
// with a phone number that isn't a registered INTERACT user (#140).
//
// Two action paths, both available if quota > 0:
//   1. "Invite via INTERACT" → POST /api/v1/chat/invites
//      Server routes through Comms Hub (WhatsApp → SMS fallback).
//      First 5 invites per user are free; after that the button is
//      hidden and only the OS SMS fallback is offered.
//   2. "Send from my phone" → url_launcher SMS intent with a prefilled
//      invite body. Free, doesn't touch our quota.
//
// Shows live quota ("3 of 5 free invites left") inline so the user
// knows where they stand before tapping. Fetches quota on open.
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/chat_api.dart';

class InviteSheet extends ConsumerStatefulWidget {
  const InviteSheet({
    super.key,
    required this.rawPhone,
    required this.normalizedPhone,
  });

  /// What the user typed (used in the OS-SMS intent as a fallback).
  final String rawPhone;

  /// E.164 the server resolved to (used for Hub invite POSTs and as the
  /// SMS recipient when launching the OS composer).
  final String normalizedPhone;

  @override
  ConsumerState<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<InviteSheet> {
  Future<InviteQuota>? _quota;
  bool _sending = false;

  /// (#148) Recipient lands on the dedicated install page with a
  /// platform-detected "Download APK" or iOS-waitlist CTA. The page is
  /// hosted on interactpak.com out of (public)/interact/page.tsx and
  /// serves the APK from /interact/InteractApp.apk via Caddy.
  static const String _installUrl = 'https://www.interactpak.com/interact';

  @override
  void initState() {
    super.initState();
    _quota = ref.read(chatApiProvider).inviteQuota();
  }

  String _smsBody() =>
      "Hi! I'm on INTERACT, Pakistan's private messaging app. "
      "Install (free) and chat with me: $_installUrl";

  Future<void> _sendViaInteract() async {
    setState(() => _sending = true);
    try {
      final result =
          await ref.read(chatApiProvider).sendInvite(widget.normalizedPhone);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Invite sent via ${result.channel == "whatsapp" ? "WhatsApp" : "SMS"}'
            ' — ${result.quota.remaining} of ${result.quota.total} free invites left.',
          ),
        ),
      );
    } on InviteQuotaExhausted {
      // Quota just hit the wall — refresh the sheet so the primary
      // button hides and only the OS-SMS option remains.
      if (!mounted) return;
      setState(() {
        _quota = Future.value(const InviteQuota(used: 5, total: 5, remaining: 0));
        _sending = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All 5 free invites used — send from your phone instead.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $e')),
      );
    }
  }

  /// "Send from my phone" → uses Android's share-sheet (ACTION_SEND) so
  /// the user picks the app each time. Bypasses the `sms:`-default-app
  /// hijack that hit us 2026-05-23: a user who had tapped "Always use
  /// WhatsApp" for `sms:` couldn't reach the SMS app anymore. The share
  /// sheet always shows a fresh chooser — no "Always" trap. (#163)
  ///
  /// Fallback: if the share sheet can't open (e.g. very old Android),
  /// fall back to the legacy `sms:` URL which at least respects the
  /// user's current default, even if it's WhatsApp.
  Future<void> _sendViaOsSms() async {
    try {
      // The recipient phone is NOT embeddable in a generic share intent
      // (most receiving apps don't know what to do with it), so we
      // include it inline in the body. The user pastes/edits in their
      // chosen app's compose screen as needed.
      final body = '${_smsBody()}\n\n(For: ${widget.normalizedPhone})';
      await Share.share(
        body,
        subject: 'Install INTERACT',
      );
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      // Fallback to the legacy sms: intent — better than nothing.
      try {
        final uri = Uri(
          scheme: 'sms',
          path: widget.normalizedPhone,
          queryParameters: {'body': _smsBody()},
        );
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open share / SMS on this device.'),
            ),
          );
          return;
        }
        if (!mounted) return;
        Navigator.pop(context);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Center(
              child: Icon(Icons.person_add_alt, size: 40, color: cs.primary),
            ),
            const SizedBox(height: 12),
            Text(
              'Not on INTERACT yet',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              widget.normalizedPhone,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.outline,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'They need to install INTERACT before you can chat. '
              'Pick how you want to invite them:',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FutureBuilder<InviteQuota>(
              future: _quota,
              builder: (ctx, snap) {
                final quota = snap.data;
                final showHubButton = quota == null || !quota.isExhausted;
                final remaining = quota?.remaining ?? 0;
                final total = quota?.total ?? 5;
                return Column(
                  children: [
                    if (showHubButton)
                      FilledButton.icon(
                        onPressed: _sending || quota == null ? null : _sendViaInteract,
                        icon: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                        label: Text(
                          quota == null
                              ? 'Invite via INTERACT'
                              : 'Invite via INTERACT  ($remaining of $total free)',
                        ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    if (showHubButton) const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _sending ? null : _sendViaOsSms,
                      icon: const Icon(Icons.sms_outlined),
                      label: const Text('Send from my phone'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (!showHubButton)
                      Text(
                        'All $total free invites used — uses your own SMS plan.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.outline, fontSize: 12),
                      )
                    else
                      Text(
                        'INTERACT invites are sent via WhatsApp or SMS through '
                        'our messaging gateway. "Send from my phone" uses your '
                        'own SMS plan.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.outline, fontSize: 11),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _sending ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

