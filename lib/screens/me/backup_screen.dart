// SPDX-License-Identifier: AGPL-3.0
//
// BackupScreen — INTERACT #115. Passphrase-encrypted chat archive kept in
// the user's VPS space. Backup exports the chat bundle, encrypts it with a
// passphrase on-device (PBKDF2 + AES-GCM), and uploads only the ciphertext.
// Restore downloads + decrypts it to verify the archive on a new device.
//
// Note surfaced to the user: normal chats already follow them to a new
// device at sign-in (server-side). This is an EXTRA, user-held encrypted
// snapshot — the server can never read it, and a forgotten passphrase
// means it can't be recovered.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/backup_service.dart';
import '../../widgets/branded_app_bar.dart';

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});
  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  BackupStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await ref.read(backupServiceProvider).status();
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Passphrase prompt ─────────────────────────────────────────────
  Future<String?> _askPassphrase({
    required String title,
    required String cta,
    bool confirm = false,
  }) async {
    final ctrl = TextEditingController();
    final ctrl2 = TextEditingController();
    final formKey = GlobalKey<FormState>();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Passphrase',
                  helperText: 'At least 6 characters. Keep it safe — it can\'t be reset.',
                  helperMaxLines: 2,
                ),
                validator: (v) => (v ?? '').trim().length < 6
                    ? 'At least 6 characters'
                    : null,
              ),
              if (confirm)
                TextFormField(
                  controller: ctrl2,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Confirm passphrase'),
                  validator: (v) =>
                      v != ctrl.text ? 'Passphrases don\'t match' : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, ctrl.text);
              }
            },
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  Future<void> _backupNow() async {
    final pass = await _askPassphrase(
      title: 'Back up chats',
      cta: 'Back up',
      confirm: true,
    );
    if (pass == null) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(backupServiceProvider).backupNow(pass);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Backed up ${r.messageCount} messages across ${r.threadCount} chats · '
          '${_fmtSize(r.sizeBytes)}',
        ),
      ));
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Backup failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final pass = await _askPassphrase(title: 'Restore backup', cta: 'Restore');
    if (pass == null) return;
    setState(() => _busy = true);
    try {
      final r = await ref.read(backupServiceProvider).restore(pass);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup verified'),
          content: Text(
            'This archive decrypted successfully.\n\n'
            '• ${r.messageCount} messages\n'
            '• ${r.threadCount} chats\n'
            '• Exported ${_fmtDate(r.exportedAt)}\n\n'
            'Your current chats already sync from the server on this device, '
            'so nothing needs to be overwritten — this confirms your encrypted '
            'archive is intact and readable.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } on BackupDecryptError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete backup?'),
        content: const Text(
          'This removes the encrypted archive from the server. Your live '
          'chats are not affected. This can\'t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(backupServiceProvider).deleteBackup();
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso.isEmpty ? '—' : iso;
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = _status;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: const BrandedAppBar(
        title: 'Backup & Restore',
        subtitle: 'Encrypted chat archive',
        showBrandGlyph: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        s?.exists == true
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_off_outlined,
                        size: 36,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s?.exists == true
                                  ? 'Last backup'
                                  : 'No backup yet',
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s?.exists == true
                                  ? '${s!.updatedAt == null ? "" : _fmtDate(s.updatedAt!.toIso8601String())} · '
                                      '${s.messageCount ?? "?"} messages · ${_fmtSize(s.sizeBytes)}'
                                  : 'Encrypt and store a snapshot of your chats.',
                              style: TextStyle(color: cs.onPrimaryContainer),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: cs.error)),
                ],
                const SizedBox(height: 8),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _backupNow,
                  icon: const Icon(Icons.backup_outlined),
                  label: const Text('Back up now'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy || s?.exists != true ? null : _restore,
                  icon: const Icon(Icons.settings_backup_restore),
                  label: const Text('Restore / verify'),
                ),
                if (s?.exists == true) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    label: Text('Delete backup',
                        style: TextStyle(color: cs.error)),
                  ),
                ],
                const SizedBox(height: 20),
                Text(
                  'How it works',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: cs.outline,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your chats are encrypted on this device with your passphrase '
                  'before upload — the server only stores unreadable ciphertext. '
                  'Each account can store one encrypted archive (about '
                  '${(kBackupMaxBytes / (1024 * 1024)).round()} MB). '
                  'Google Drive / own-cloud export is planned — for now use '
                  'Back up now, or ask support to link your VPS folder.\n\n'
                  'Keep your passphrase safe: it is never sent anywhere and a lost '
                  'passphrase means the backup can\'t be recovered.',
                  style: TextStyle(color: cs.outline, fontSize: 13, height: 1.4),
                ),
              ],
            ),
    );
  }
}
