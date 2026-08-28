// SPDX-License-Identifier: AGPL-3.0
//
// CallHistoryScreen — the full call log ("All" from the Calls tab and the
// Call-history tile in Me → Security & Privacy, both previously "Soon").
// Server data comes from the SAME /api/v1/meetings/log the Recent-calls
// strip already uses — this screen just shows all of it with filters.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/talk_api.dart';
import '../widgets/branded_app_bar.dart';
import '../widgets/call_row.dart';

enum _Filter { all, missed, video, voice }

class CallHistoryScreen extends ConsumerStatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  ConsumerState<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends ConsumerState<CallHistoryScreen> {
  late Future<List<Map<String, dynamic>>> _history;
  _Filter _filter = _Filter.all;

  @override
  void initState() {
    super.initState();
    _history = ref.read(talkApiProvider).callHistory();
  }

  Future<void> _refresh() async {
    final f = ref.read(talkApiProvider).callHistory();
    setState(() => _history = f);
    await f.catchError((_) => <Map<String, dynamic>>[]);
  }

  bool _matches(Map<String, dynamic> r) {
    final mode = r['mode'] as String? ?? 'video';
    final dur = r['durationSec'] as int? ?? 0;
    final dir = r['direction'] as String? ?? (dur == 0 ? 'missed' : '');
    return switch (_filter) {
      _Filter.all => true,
      _Filter.missed => dir == 'missed' || dur == 0,
      _Filter.video => mode != 'voice' && mode != 'ptt',
      _Filter.voice => mode == 'voice' || mode == 'ptt',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: const BrandedAppBar(title: 'Call history'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                for (final (f, label) in const [
                  (_Filter.all, 'All'),
                  (_Filter.missed, 'Missed'),
                  (_Filter.video, 'Video'),
                  (_Filter.voice, 'Voice'),
                ]) ...[
                  ChoiceChip(
                    label: Text(label),
                    selected: _filter == f,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _history,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_off, size: 36, color: cs.outline),
                        const SizedBox(height: 10),
                        const Text('Couldn’t load call history'),
                        const SizedBox(height: 12),
                        FilledButton.tonal(
                          onPressed: _refresh,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }
                final rows =
                    (snap.data ?? const []).where(_matches).toList();
                if (rows.isEmpty) {
                  return Center(
                    child: Text(
                      _filter == _Filter.all
                          ? 'No calls yet'
                          : 'No ${_filter.name} calls',
                      style: TextStyle(color: cs.outline),
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => CallRow(row: rows[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
