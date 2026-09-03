// SPDX-License-Identifier: AGPL-3.0
//
// Best-effort mirror of welcome reminders → IL Lifestyle schedule tasks.
// Local WelcomeMemoryStore stays authoritative; sync never blocks UI.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'auth_service.dart';

/// Result of a single IL schedule POST.
class IlSchedulePushResult {
  const IlSchedulePushResult.success(this.taskId)
      : syncPending = false,
        httpStatus = 201;

  const IlSchedulePushResult.pending({this.httpStatus})
      : taskId = null,
        syncPending = true;

  final String? taskId;
  final bool syncPending;
  final int? httpStatus;
}

class IlScheduleSyncService {
  IlScheduleSyncService._();
  static final IlScheduleSyncService instance = IlScheduleSyncService._();

  static const _ilBase = String.fromEnvironment(
    'IL_API_BASE',
    defaultValue: 'https://lifestyle.interactpak.com/api',
  );

  static const _source = 'talk-welcome';
  static const _timeout = Duration(seconds: 8);

  Uri get _tasksUri => Uri.parse('$_ilBase/schedule/tasks');

  /// POST one reminder title + due time. Returns server task id on 201.
  Future<IlSchedulePushResult> pushReminder({
    required String title,
    required DateTime dueAt,
    String source = _source,
  }) async {
    final token = await AuthService.instance.token();
    if (token == null || token.isEmpty) {
      return const IlSchedulePushResult.pending(httpStatus: 401);
    }

    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > 200) {
      return const IlSchedulePushResult.pending(httpStatus: 400);
    }

    try {
      final body = <String, dynamic>{
        'title': trimmed,
        'dueAt': dueAt.toUtc().toIso8601String(),
        'source': source.length > 40 ? source.substring(0, 40) : source,
      };
      final res = await http
          .post(
            _tasksUri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (res.statusCode == 201) {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        final task = j['task'];
        if (task is Map) {
          final id = task['id'] as String?;
          if (id != null && id.isNotEmpty) {
            return IlSchedulePushResult.success(id);
          }
        }
        return const IlSchedulePushResult.pending(httpStatus: 201);
      }

      if (kDebugMode) {
        debugPrint(
          '[IlScheduleSync] POST ${res.statusCode}: ${res.body.length > 120 ? '${res.body.substring(0, 120)}…' : res.body}',
        );
      }
      return IlSchedulePushResult.pending(httpStatus: res.statusCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[IlScheduleSync] push: $e');
      return const IlSchedulePushResult.pending();
    }
  }
}
