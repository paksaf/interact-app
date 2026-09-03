// SPDX-License-Identifier: AGPL-3.0
//
// Persists user-picked chat wallpaper files under app support dir.

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'api_base.dart';
import 'auth_service.dart';

class ChatWallpaperStorage {
  ChatWallpaperStorage._();
  static final instance = ChatWallpaperStorage._();

  static const maxVideoBytes = 25 * 1024 * 1024;

  Future<Directory> wallpaperDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/chat_wallpapers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> persistImage(File source) async {
    final dir = await wallpaperDir();
    final name = 'img_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final dest = File('${dir.path}/$name');
    await source.copy(dest.path);
    return dest;
  }

  Future<File> persistVideo(File source) async {
    final size = await source.length();
    if (size > maxVideoBytes) {
      throw StateError('Video wallpaper must be under 25 MB');
    }
    final dir = await wallpaperDir();
    final name = 'vid_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final dest = File('${dir.path}/$name');
    await source.copy(dest.path);
    return dest;
  }

  Future<void> deleteIfOwned(String? localPath) async {
    if (localPath == null || localPath.isEmpty) return;
    try {
      final file = File(localPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {/* best-effort cleanup */}
  }

  /// Download a first-party `/uploads/…` wallpaper to local cache.
  Future<File?> cacheRemoteMedia({
    required String relativePath,
    required bool isVideo,
  }) async {
    final url = relativePath.startsWith('http')
        ? relativePath
        : '${ApiBase.current}$relativePath';
    try {
      final token = await AuthService.instance.token();
      final headers = <String, String>{};
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;

      final dir = await wallpaperDir();
      final ext = isVideo ? '.mp4' : '.jpg';
      final file = File(
        '${dir.path}/remote_${DateTime.now().millisecondsSinceEpoch}$ext',
      );
      await file.writeAsBytes(res.bodyBytes);
      return file;
    } catch (_) {
      return null;
    }
  }
}
