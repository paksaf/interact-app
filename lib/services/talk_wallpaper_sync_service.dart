// SPDX-License-Identifier: AGPL-3.0
//
// Best-effort mirror of global chat wallpaper → Talk backend User.uiPrefs.
// Local ChatWallpaperPrefs stay authoritative; sync never blocks UI.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/theme/chat_wallpaper_prefs.dart';
import 'api_base.dart';
import 'auth_service.dart';
import 'chat_wallpaper_storage.dart';

class RemoteWallpaperDto {
  const RemoteWallpaperDto({
    required this.type,
    this.mediaUrl,
    this.presetId,
    this.dim = 35,
    this.blur = 0,
    this.scrim = 'auto',
  });

  final String type;
  final String? mediaUrl;
  final String? presetId;
  final int dim;
  final int blur;
  final String scrim;
}

class TalkWallpaperSyncResult {
  const TalkWallpaperSyncResult.ok({this.httpStatus = 200}) : pending = false;

  const TalkWallpaperSyncResult.pending({this.httpStatus}) : pending = true;

  final bool pending;
  final int? httpStatus;
}

class TalkWallpaperSyncService {
  TalkWallpaperSyncService._();
  static final TalkWallpaperSyncService instance = TalkWallpaperSyncService._();

  static const _timeout = Duration(seconds: 12);

  Uri get _wallpaperUri =>
      Uri.parse('${ApiBase.current}/api/v1/talk/profile/wallpaper');

  /// GET server wallpaper. Returns null when absent or unreachable.
  Future<RemoteWallpaperDto?> fetchWallpaper() async {
    final token = await AuthService.instance.token();
    if (token == null || token.isEmpty) return null;

    try {
      final res = await http
          .get(
            _wallpaperUri,
            headers: {
              'Authorization': 'Bearer $token',
              'Accept': 'application/json',
            },
          )
          .timeout(_timeout);

      if (res.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('[TalkWallpaperSync] GET ${res.statusCode}');
        }
        return null;
      }

      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final wallpaper = j['wallpaper'];
      if (wallpaper == null) return null;
      if (wallpaper is! Map) return null;

      final type = wallpaper['type'] as String? ?? 'none';
      if (type == 'none') {
        return const RemoteWallpaperDto(type: 'none');
      }

      return RemoteWallpaperDto(
        type: type,
        mediaUrl: wallpaper['mediaUrl'] as String?,
        presetId: wallpaper['presetId'] as String?,
        dim: (wallpaper['dim'] as num?)?.toInt() ?? 35,
        blur: (wallpaper['blur'] as num?)?.toInt() ?? 0,
        scrim: wallpaper['scrim'] as String? ?? 'auto',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[TalkWallpaperSync] GET: $e');
      return null;
    }
  }

  /// PUT wallpaper fields. [mediaUrl] must be a first-party `/uploads/…` path.
  Future<TalkWallpaperSyncResult> pushWallpaper({
    required String type,
    String? mediaUrl,
    String? presetId,
    int? dim,
    int? blur,
    String? scrim,
  }) async {
    final token = await AuthService.instance.token();
    if (token == null || token.isEmpty) {
      return const TalkWallpaperSyncResult.pending(httpStatus: 401);
    }

    final body = <String, dynamic>{'type': type};
    if (type == 'none') {
      body['mediaUrl'] = null;
    } else {
      if (mediaUrl != null) body['mediaUrl'] = mediaUrl;
      if (presetId != null) body['presetId'] = presetId;
      if (dim != null) body['dim'] = dim.clamp(0, 80);
      if (blur != null) body['blur'] = blur.clamp(0, 30);
      if (scrim != null) body['scrim'] = scrim;
    }

    try {
      final res = await http
          .put(
            _wallpaperUri,
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);

      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (kDebugMode) debugPrint('[TalkWallpaperSync] PUT ${res.statusCode}');
        return TalkWallpaperSyncResult.ok(httpStatus: res.statusCode);
      }

      if (kDebugMode) {
        debugPrint(
          '[TalkWallpaperSync] PUT ${res.statusCode}: '
          '${res.body.length > 120 ? '${res.body.substring(0, 120)}…' : res.body}',
        );
      }
      return TalkWallpaperSyncResult.pending(httpStatus: res.statusCode);
    } catch (e) {
      if (kDebugMode) debugPrint('[TalkWallpaperSync] PUT: $e');
      return const TalkWallpaperSyncResult.pending();
    }
  }

  /// Upload local media when needed, then push the full snapshot.
  Future<TalkWallpaperSyncResult> pushFull(ChatWallpaperConfig config) async {
    final payload = await buildPushPayload(config);
    if (payload == null) {
      return const TalkWallpaperSyncResult.pending();
    }
    return pushWallpaper(
      type: payload.type,
      mediaUrl: payload.mediaUrl,
      presetId: payload.presetId,
      dim: payload.dim,
      blur: payload.blur,
      scrim: payload.scrim,
    );
  }
}

class WallpaperPushPayload {
  const WallpaperPushPayload({
    required this.type,
    this.mediaUrl,
    this.presetId,
    required this.dim,
    required this.blur,
    required this.scrim,
  });

  final String type;
  final String? mediaUrl;
  final String? presetId;
  final int dim;
  final int blur;
  final String scrim;
}

/// Build PUT body fields from local config; uploads image/video when required.
Future<WallpaperPushPayload?> buildPushPayload(
  ChatWallpaperConfig config,
) async {
  final dim = wallpaperDimToServer(config.dim);
  final blur = wallpaperBlurToServer(config.blur);
  final scrim = wallpaperScrimToServer(config.scrim);

  switch (config.kind) {
    case ChatWallpaperKind.none:
      return WallpaperPushPayload(
        type: 'none',
        dim: dim,
        blur: blur,
        scrim: scrim,
      );
    case ChatWallpaperKind.asset:
      final presetId = presetIdFromAsset(config.asset);
      if (presetId == null) return null;
      return WallpaperPushPayload(
        type: 'preset',
        presetId: presetId,
        dim: dim,
        blur: blur,
        scrim: scrim,
      );
    case ChatWallpaperKind.image:
    case ChatWallpaperKind.video:
      var uploadsPath = relativeUploadsPath(config.remoteMediaUrl);
      if (uploadsPath == null && config.localPath != null) {
        uploadsPath = await uploadLocalWallpaperMedia(
          File(config.localPath!),
          isVideo: config.kind == ChatWallpaperKind.video,
        );
      }
      if (uploadsPath == null) return null;
      return WallpaperPushPayload(
        type: config.kind == ChatWallpaperKind.video ? 'video' : 'image',
        mediaUrl: uploadsPath,
        dim: dim,
        blur: blur,
        scrim: scrim,
      );
  }
}

/// Multipart upload → `/uploads/…` relative path for wallpaper PUT.
Future<String?> uploadLocalWallpaperMedia(
  File file, {
  required bool isVideo,
}) async {
  final token = await AuthService.instance.token();
  if (token == null || token.isEmpty) return null;

  try {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('${ApiBase.current}/api/v1/media/upload'),
    );
    req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path));
    final res = await http.Response.fromStream(await req.send()).timeout(
      TalkWallpaperSyncService._timeout,
    );
    if (res.statusCode >= 400) {
      if (kDebugMode) {
        debugPrint('[TalkWallpaperSync] upload ${res.statusCode}');
      }
      return null;
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] ?? body) as Map<String, dynamic>;
    final rel = (data['url'] as String?) ?? '';
    return relativeUploadsPath(rel);
  } catch (e) {
    if (kDebugMode) debugPrint('[TalkWallpaperSync] upload: $e');
    return null;
  }
}

String? relativeUploadsPath(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('/uploads/')) return url;
  final uri = Uri.tryParse(url);
  if (uri != null && uri.path.startsWith('/uploads/')) return uri.path;
  final base = ApiBase.current;
  if (url.startsWith(base)) {
    final tail = url.substring(base.length);
    if (tail.startsWith('/uploads/')) return tail;
  }
  return null;
}

String? presetIdFromAsset(String? asset) {
  if (asset == null) return null;
  for (final p in kChatWallpaperPresetAssets) {
    if (p.asset == asset) return p.id;
  }
  return null;
}

String? assetFromPresetId(String? presetId) {
  if (presetId == null) return null;
  for (final p in kChatWallpaperPresetAssets) {
    if (p.id == presetId) return p.asset;
  }
  return null;
}

int wallpaperDimToServer(double dim) => (dim.clamp(0.0, 0.8) * 100).round();

double wallpaperDimFromServer(int dim) => (dim.clamp(0, 80) / 100.0);

int wallpaperBlurToServer(double blur) => blur.clamp(0.0, 20.0).round();

double wallpaperBlurFromServer(int blur) => blur.clamp(0, 30).toDouble();

String wallpaperScrimToServer(ChatWallpaperScrim scrim) {
  return switch (scrim) {
    ChatWallpaperScrim.none => 'auto',
    ChatWallpaperScrim.light => 'light',
    ChatWallpaperScrim.dark => 'dark',
  };
}

ChatWallpaperScrim wallpaperScrimFromServer(String? scrim) {
  return switch (scrim) {
    'light' => ChatWallpaperScrim.light,
    'dark' => ChatWallpaperScrim.dark,
    _ => ChatWallpaperScrim.none,
  };
}

bool isDefaultLocalWallpaper(ChatWallpaperConfig c) {
  return c.kind == ChatWallpaperKind.none;
}

/// Apply remote wallpaper to local config (downloads media when needed).
Future<ChatWallpaperConfig?> wallpaperFromRemote(RemoteWallpaperDto remote) async {
  if (remote.type == 'none') return const ChatWallpaperConfig();

  final dim = wallpaperDimFromServer(remote.dim);
  final blur = wallpaperBlurFromServer(remote.blur);
  final scrim = wallpaperScrimFromServer(remote.scrim);

  if (remote.type == 'preset') {
    final asset = assetFromPresetId(remote.presetId);
    if (asset == null) return null;
    return ChatWallpaperConfig(
      kind: ChatWallpaperKind.asset,
      asset: asset,
      dim: dim,
      blur: blur,
      scrim: scrim,
    );
  }

  if (remote.type == 'image' || remote.type == 'video') {
    final rel = relativeUploadsPath(remote.mediaUrl);
    if (rel == null) return null;
    final cached = await ChatWallpaperStorage.instance.cacheRemoteMedia(
      relativePath: rel,
      isVideo: remote.type == 'video',
    );
    if (cached == null) return null;
    return ChatWallpaperConfig(
      kind: remote.type == 'video'
          ? ChatWallpaperKind.video
          : ChatWallpaperKind.image,
      localPath: cached.path,
      remoteMediaUrl: rel,
      dim: dim,
      blur: blur,
      scrim: scrim,
    );
  }

  return null;
}
