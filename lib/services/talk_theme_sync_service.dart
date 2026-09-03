// SPDX-License-Identifier: AGPL-3.0
//
// Best-effort mirror of theme prefs → Talk backend User.uiPrefs.
// Local ThemePrefs stay authoritative; sync never blocks UI.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/theme/theme_prefs.dart';
import 'api_base.dart';
import 'auth_service.dart';

class RemoteThemeDto {
  const RemoteThemeDto({
    required this.mode,
    required this.seed,
    required this.accent,
  });

  final ThemeMode mode;
  final Color seed;
  final Color accent;
}

class TalkThemeSyncResult {
  const TalkThemeSyncResult.ok({this.httpStatus = 200}) : pending = false;

  const TalkThemeSyncResult.pending({this.httpStatus})
      : pending = true;

  final bool pending;
  final int? httpStatus;
}

class TalkThemeSyncService {
  TalkThemeSyncService._();
  static final TalkThemeSyncService instance = TalkThemeSyncService._();

  static const _timeout = Duration(seconds: 8);

  Uri get _themeUri => Uri.parse('${ApiBase.current}/api/v1/talk/profile/theme');

  /// GET server theme. Returns null when absent or unreachable.
  Future<RemoteThemeDto?> fetchTheme() async {
    final token = await AuthService.instance.token();
    if (token == null || token.isEmpty) return null;

    try {
      final res = await http
          .get(
            _themeUri,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(_timeout);

      if (res.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('[TalkThemeSync] GET ${res.statusCode}');
        }
        return null;
      }

      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final theme = j['theme'];
      if (theme == null) return null;
      if (theme is! Map) return null;

      final modeRaw = theme['mode'] as String?;
      final mode = switch (modeRaw) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

      final seedInt = theme['seed'];
      final accentInt = theme['accent'];
      if (seedInt is! int || accentInt is! int) return null;

      return RemoteThemeDto(
        mode: mode,
        seed: Color(seedInt),
        accent: Color(accentInt),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[TalkThemeSync] GET: $e');
      return null;
    }
  }

  /// PUT changed theme fields (>=1 required). Returns ok or pending for retry.
  Future<TalkThemeSyncResult> pushTheme({
    ThemeMode? mode,
    Color? seed,
    Color? accent,
  }) async {
    final token = await AuthService.instance.token();
    if (token == null || token.isEmpty) {
      return const TalkThemeSyncResult.pending(httpStatus: 401);
    }

    final body = <String, dynamic>{};
    if (mode != null) {
      body['mode'] = switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
    }
    if (seed != null) body['seed'] = seed.toARGB32();
    if (accent != null) body['accent'] = accent.toARGB32();

    if (body.isEmpty) return const TalkThemeSyncResult.ok();

    try {
      final res = await http
          .put(
            _themeUri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (kDebugMode) debugPrint('[TalkThemeSync] PUT ${res.statusCode}');
        return TalkThemeSyncResult.ok(httpStatus: res.statusCode);
      }

      if (kDebugMode) {
        debugPrint(
          '[TalkThemeSync] PUT ${res.statusCode}: '
          '${res.body.length > 120 ? '${res.body.substring(0, 120)}…' : res.body}',
        );
      }
      return TalkThemeSyncResult.pending(httpStatus: res.statusCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[TalkThemeSync] PUT: $e');
      return const TalkThemeSyncResult.pending();
    }
  }

  /// Push full local theme snapshot (used for flush/retry).
  Future<TalkThemeSyncResult> pushFull(AppThemeState state) {
    return pushTheme(mode: state.mode, seed: state.seed, accent: state.accent);
  }
}

/// True when the user has not customized theme on this device.
bool isDefaultLocalTheme(AppThemeState s) {
  return s.presetId == 'signal' &&
      s.mode == ThemeMode.system &&
      s.seed.toARGB32() == kDefaultThemeSeed.toARGB32() &&
      s.accent.toARGB32() == kDefaultThemeAccent.toARGB32();
}

String presetIdForColors(Color seed, Color accent) {
  for (final p in kThemePresets) {
    if (p.seed.toARGB32() == seed.toARGB32() &&
        p.accent.toARGB32() == accent.toARGB32()) {
      return p.id;
    }
  }
  return 'custom';
}

AppThemeState appThemeFromRemote(RemoteThemeDto remote) {
  return AppThemeState(
    mode: remote.mode,
    seed: remote.seed,
    accent: remote.accent,
    presetId: presetIdForColors(remote.seed, remote.accent),
  );
}
