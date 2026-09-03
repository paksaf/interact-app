// SPDX-License-Identifier: AGPL-3.0
//
// Shared report reason sheet for messages and reels.

import 'package:flutter/material.dart';

import '../../services/analytics_service.dart';
import '../../services/report_service.dart';

typedef ReportSubmitCallback = Future<bool> Function(
  ReportReason reason,
  String? note,
);

/// Bottom sheet: pick a reason + optional note → [onSubmit].
Future<bool?> showReportReasonSheet(
  BuildContext context, {
  required String subjectLabel,
  required ReportSubmitCallback onSubmit,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ReportReasonSheet(
      subjectLabel: subjectLabel,
      onSubmit: onSubmit,
    ),
  );
}

class _ReportReasonSheet extends StatefulWidget {
  const _ReportReasonSheet({
    required this.subjectLabel,
    required this.onSubmit,
  });

  final String subjectLabel;
  final ReportSubmitCallback onSubmit;

  @override
  State<_ReportReasonSheet> createState() => _ReportReasonSheetState();
}

class _ReportReasonSheetState extends State<_ReportReasonSheet> {
  ReportReason? _reason;
  final _noteCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _submitting) return;
    setState(() => _submitting = true);
    final ok = await widget.onSubmit(reason, _noteCtrl.text);
    if (!mounted) return;
    if (ok) {
      AnalyticsService.instance.trackFeatureUse('report_submit');
    }
    Navigator.pop(context, ok);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Text(
                'Report ${widget.subjectLabel}',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Reports are reviewed by our team. Your note is optional.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            ...ReportReason.values.map(
              (r) => ListTile(
                leading: Icon(
                  _reason == r
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: _reason == r ? cs.primary : cs.outline,
                ),
                title: Text(r.label),
                dense: true,
                onTap: _submitting
                    ? null
                    : () => setState(() => _reason = r),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: TextField(
                controller: _noteCtrl,
                maxLines: 3,
                maxLength: 500,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  labelText: 'Additional details (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: FilledButton(
                onPressed: _reason == null || _submitting ? null : _submit,
                child: _submitting
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.onPrimary,
                        ),
                      )
                    : const Text('Submit report'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
