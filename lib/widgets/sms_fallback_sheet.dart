// SPDX-License-Identifier: AGPL-3.0
//
// User-confirmed SMS fallback sheet — never sends without explicit tap.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/phone_normalize.dart';
import '../services/sms_bearer_service.dart';

/// Resolve a 1:1 thread's peer phone from subjectId or title when present.
String? peerPhoneFromThreadHints({
  required String subjectId,
  required String title,
}) {
  return normalizeInteractPhone(subjectId) ?? normalizeInteractPhone(title);
}

/// Returns true when SMS was accepted by the gateway.
Future<bool> showSmsFallbackSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String toPhone,
  required String body,
  String? threadId,
}) async {
  var phone = normalizeInteractPhone(toPhone) ?? toPhone.trim();
  if (normalizeInteractPhone(phone) == null) {
    final entered = await _promptPeerPhone(context);
    if (entered == null || !context.mounted) return false;
    phone = entered;
  }

  final clipped = SmsBearerService.clipForSms(body);
  final confirmed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Send as SMS?',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'Data is unavailable but cellular may still work. '
                'Standard SMS rates apply — this is not free.',
                style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.phone),
                title: Text(phone),
                subtitle: const Text('Recipient'),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'INTERACT: $clipped',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.sms),
                label: const Text('Send SMS now'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (confirmed != true || !context.mounted) return false;

  final result = await ref.read(smsBearerServiceProvider).sendConfirmed(
        toPhone: phone,
        body: body,
        threadId: threadId,
      );
  if (!context.mounted) return result.delivered;

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result.delivered
            ? 'SMS queued via carrier'
            : (result.error ?? 'SMS failed'),
      ),
    ),
  );
  return result.delivered;
}

Future<String?> _promptPeerPhone(BuildContext context) async {
  final ctrl = TextEditingController();
  final entered = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Recipient phone'),
      content: TextField(
        controller: ctrl,
        keyboardType: TextInputType.phone,
        decoration: const InputDecoration(
          hintText: '03XX XXXXXXX or +923…',
          border: OutlineInputBorder(),
        ),
        autofocus: true,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (entered == null || entered.isEmpty) return null;
  return normalizeInteractPhone(entered) ?? entered;
}
