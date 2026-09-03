// SPDX-License-Identifier: AGPL-3.0
//
// Storage — shows the user's backup storage plan, usage, and the available
// tiers. Upgrading is disabled until the payment gateway is live (the API
// returns purchasable=false).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/auth_service.dart';
import '../../services/storage_api.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});
  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  StorageInfo? _info;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final info = await fetchStorage(ref.read(authServiceProvider));
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn’t load storage. Check your connection.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? _errorView(cs)
                : _content(cs, _info!),
      ),
    );
  }

  Widget _errorView(ColorScheme cs) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(color: cs.error)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );

  Widget _content(ColorScheme cs, StorageInfo info) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cloud_outlined, color: cs.primary),
                    const SizedBox(width: 8),
                    Text('${info.label} plan',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: info.usedFraction,
                    minHeight: 10,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${formatBytes(info.usedBytes)} of ${formatBytes(info.quotaBytes)} used',
                  style: TextStyle(color: cs.outline),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Plans', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        if (!info.purchasable)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Upgrades open once payments are enabled.',
              style: TextStyle(color: cs.outline, fontSize: 12),
            ),
          ),
        for (final tier in info.tiers) _tierCard(cs, info, tier),
      ],
    );
  }

  Widget _tierCard(ColorScheme cs, StorageInfo info, StorageTier tier) {
    final current = tier.plan == info.plan;
    final priceLabel = tier.pricePkrMonthly == 0
        ? 'Free'
        : 'Rs ${tier.pricePkrMonthly}/mo';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: current
            ? BorderSide(color: cs.primary, width: 1.5)
            : BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(tier.label,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                      if (current) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: cs.primaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text('Current',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onPrimaryContainer)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text('${formatBytes(tier.quotaBytes)} · $priceLabel',
                      style: TextStyle(color: cs.outline)),
                ],
              ),
            ),
            if (!current)
              FilledButton.tonal(
                onPressed: info.purchasable
                    ? () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Checkout coming soon.')),
                        )
                    : null,
                child: const Text('Upgrade'),
              ),
          ],
        ),
      ),
    );
  }
}
