// SPDX-License-Identifier: AGPL-3.0
//
// Backup storage plan + usage (GET /api/v1/talk/storage). Purchase is gated on
// the payment gateway server-side (purchasable=false until then).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api_base.dart';
import 'auth_service.dart';

class StorageTier {
  const StorageTier({
    required this.plan,
    required this.label,
    required this.quotaBytes,
    required this.pricePkrMonthly,
    required this.pricePkrYearly,
  });

  final String plan;
  final String label;
  final int quotaBytes;
  final int pricePkrMonthly;
  final int pricePkrYearly;

  factory StorageTier.fromJson(Map<String, dynamic> j) => StorageTier(
        plan: (j['plan'] as String?) ?? 'free',
        label: (j['label'] as String?) ?? 'Free',
        quotaBytes: (j['quotaBytes'] as num?)?.toInt() ?? 0,
        pricePkrMonthly: (j['pricePkrMonthly'] as num?)?.toInt() ?? 0,
        pricePkrYearly: (j['pricePkrYearly'] as num?)?.toInt() ?? 0,
      );
}

class StorageInfo {
  const StorageInfo({
    required this.plan,
    required this.label,
    required this.quotaBytes,
    required this.usedBytes,
    required this.purchasable,
    required this.tiers,
  });

  final String plan;
  final String label;
  final int quotaBytes;
  final int usedBytes;
  final bool purchasable;
  final List<StorageTier> tiers;

  double get usedFraction =>
      quotaBytes <= 0 ? 0 : (usedBytes / quotaBytes).clamp(0, 1).toDouble();
}

Future<StorageInfo> fetchStorage(AuthService auth) async {
  final t = await auth.token();
  final res = await http.get(
    Uri.parse('${ApiBase.current}/api/v1/talk/storage'),
    headers: {if (t != null) 'Authorization': 'Bearer $t'},
  ).timeout(const Duration(seconds: 15));
  final body = jsonDecode(res.body) as Map<String, dynamic>;
  final d = (body['data'] as Map<String, dynamic>?) ?? body;
  final tiers = (d['tiers'] as List?)
          ?.whereType<Map>()
          .map((e) => StorageTier.fromJson(Map<String, dynamic>.from(e)))
          .toList() ??
      const <StorageTier>[];
  return StorageInfo(
    plan: (d['plan'] as String?) ?? 'free',
    label: (d['label'] as String?) ?? 'Free',
    quotaBytes: (d['quotaBytes'] as num?)?.toInt() ?? 0,
    usedBytes: (d['usedBytes'] as num?)?.toInt() ?? 0,
    purchasable: d['purchasable'] == true,
    tiers: tiers,
  );
}

String formatBytes(int bytes) {
  const gb = 1024 * 1024 * 1024;
  const mb = 1024 * 1024;
  const kb = 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes % gb == 0 ? 0 : 1)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(0)} KB';
  return '$bytes B';
}
