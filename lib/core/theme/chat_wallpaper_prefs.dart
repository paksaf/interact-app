// SPDX-License-Identifier: AGPL-3.0
//
// Chat wallpaper — global default + optional per-thread override.
// Local-first (SharedPreferences); mirrored to Talk profile/wallpaper API.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/locale_prefs.dart';
import '../../services/talk_wallpaper_sync_service.dart';

/// Bundled wallpaper presets (same assets as camera virtual backgrounds).
const kChatWallpaperPresetAssets = <({String id, String asset})>[
  (id: 'office', asset: 'assets/backgrounds/bg_office.png'),
  (id: 'brand', asset: 'assets/backgrounds/bg_brand.png'),
  (id: 'warm', asset: 'assets/backgrounds/bg_warm.png'),
  (id: 'signal', asset: 'assets/backgrounds/app_bg.png'),
];

enum ChatWallpaperKind { none, asset, image, video }

enum ChatWallpaperScrim { none, light, dark }

class ChatWallpaperConfig {
  const ChatWallpaperConfig({
    this.kind = ChatWallpaperKind.none,
    this.asset,
    this.localPath,
    this.remoteMediaUrl,
    this.dim = 0.35,
    this.blur = 0,
    this.scrim = ChatWallpaperScrim.dark,
  });

  final ChatWallpaperKind kind;
  final String? asset;
  final String? localPath;

  /// First-party `/uploads/…` path after media/upload (cross-device sync).
  final String? remoteMediaUrl;
  final double dim;
  final double blur;
  final ChatWallpaperScrim scrim;

  bool get isActive => kind != ChatWallpaperKind.none;

  ChatWallpaperConfig copyWith({
    ChatWallpaperKind? kind,
    String? asset,
    String? localPath,
    String? remoteMediaUrl,
    bool clearAsset = false,
    bool clearLocalPath = false,
    bool clearRemoteMediaUrl = false,
    double? dim,
    double? blur,
    ChatWallpaperScrim? scrim,
  }) {
    return ChatWallpaperConfig(
      kind: kind ?? this.kind,
      asset: clearAsset ? null : (asset ?? this.asset),
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      remoteMediaUrl:
          clearRemoteMediaUrl ? null : (remoteMediaUrl ?? this.remoteMediaUrl),
      dim: dim ?? this.dim,
      blur: blur ?? this.blur,
      scrim: scrim ?? this.scrim,
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        if (asset != null) 'asset': asset,
        if (localPath != null) 'localPath': localPath,
        if (remoteMediaUrl != null) 'remoteMediaUrl': remoteMediaUrl,
        'dim': dim,
        'blur': blur,
        'scrim': scrim.name,
      };

  factory ChatWallpaperConfig.fromJson(Map<String, dynamic> json) {
    final kindRaw = json['kind'] as String? ?? 'none';
    final kind = ChatWallpaperKind.values.firstWhere(
      (k) => k.name == kindRaw,
      orElse: () => ChatWallpaperKind.none,
    );
    final scrimRaw = json['scrim'] as String? ?? 'dark';
    final scrim = ChatWallpaperScrim.values.firstWhere(
      (s) => s.name == scrimRaw,
      orElse: () => ChatWallpaperScrim.dark,
    );
    return ChatWallpaperConfig(
      kind: kind,
      asset: json['asset'] as String?,
      localPath: json['localPath'] as String?,
      remoteMediaUrl: json['remoteMediaUrl'] as String?,
      dim: (json['dim'] as num?)?.toDouble() ?? 0.35,
      blur: (json['blur'] as num?)?.toDouble() ?? 0,
      scrim: scrim,
    );
  }
}

class ChatWallpaperPrefs {
  ChatWallpaperPrefs(this._prefs);

  static const globalKey = 'chat.wallpaper.global';
  static const threadMapKey = 'chat.wallpaper.threads';
  static const syncPendingKey = 'chat.wallpaper.syncPending';

  final SharedPreferences _prefs;

  ChatWallpaperConfig get global {
    final raw = _prefs.getString(globalKey);
    if (raw == null || raw.isEmpty) return const ChatWallpaperConfig();
    try {
      return ChatWallpaperConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return const ChatWallpaperConfig();
    }
  }

  Map<String, ChatWallpaperConfig> get threadOverrides {
    final raw = _prefs.getString(threadMapKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map(
        (id, value) => MapEntry(
          id,
          ChatWallpaperConfig.fromJson(value as Map<String, dynamic>),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  ChatWallpaperConfig? threadOverride(String threadId) {
    return threadOverrides[threadId];
  }

  ChatWallpaperConfig resolve(String? threadId) {
    if (threadId != null) {
      final override = threadOverride(threadId);
      if (override != null) return override;
    }
    return global;
  }

  Future<void> saveGlobal(ChatWallpaperConfig config) async {
    await _prefs.setString(globalKey, jsonEncode(config.toJson()));
  }

  Future<void> saveThread(String threadId, ChatWallpaperConfig config) async {
    final map = threadOverrides;
    map[threadId] = config;
    await _saveThreadMap(map);
  }

  Future<void> clearThread(String threadId) async {
    final map = threadOverrides;
    map.remove(threadId);
    await _saveThreadMap(map);
  }

  Future<void> _saveThreadMap(Map<String, ChatWallpaperConfig> map) async {
    final encoded = map.map((k, v) => MapEntry(k, v.toJson()));
    await _prefs.setString(threadMapKey, jsonEncode(encoded));
  }

  bool get syncPending => _prefs.getBool(syncPendingKey) ?? false;

  Future<void> setSyncPending(bool value) async {
    await _prefs.setBool(syncPendingKey, value);
  }
}

final chatWallpaperPrefsProvider = Provider<ChatWallpaperPrefs?>((ref) {
  final async = ref.watch(sharedPreferencesProvider);
  return async.maybeWhen(
    data: (p) => ChatWallpaperPrefs(p),
    orElse: () => null,
  );
});

class ChatWallpaperState {
  const ChatWallpaperState({
    required this.global,
    required this.threadOverrides,
  });

  final ChatWallpaperConfig global;
  final Map<String, ChatWallpaperConfig> threadOverrides;

  ChatWallpaperConfig resolve(String? threadId) {
    if (threadId != null) {
      final override = threadOverrides[threadId];
      if (override != null) return override;
    }
    return global;
  }

  ChatWallpaperState copyWith({
    ChatWallpaperConfig? global,
    Map<String, ChatWallpaperConfig>? threadOverrides,
  }) {
    return ChatWallpaperState(
      global: global ?? this.global,
      threadOverrides: threadOverrides ?? this.threadOverrides,
    );
  }
}

class ChatWallpaperController extends Notifier<ChatWallpaperState> {
  static bool _sessionPullDone = false;

  @override
  ChatWallpaperState build() {
    final prefs = ref.watch(chatWallpaperPrefsProvider);
    if (prefs == null) {
      return const ChatWallpaperState(
        global: ChatWallpaperConfig(),
        threadOverrides: {},
      );
    }
    return ChatWallpaperState(
      global: prefs.global,
      threadOverrides: Map<String, ChatWallpaperConfig>.from(prefs.threadOverrides),
    );
  }

  /// Once per session: pull server wallpaper if local is still default.
  /// Also retries a pending PUT from a prior offline change.
  Future<void> syncWithServerOnOpen() async {
    await _pullServerIfNeeded();
    await flushPendingPush();
  }

  Future<void> _pullServerIfNeeded() async {
    if (_sessionPullDone) return;
    _sessionPullDone = true;

    if (!isDefaultLocalWallpaper(state.global)) return;

    final remote = await TalkWallpaperSyncService.instance.fetchWallpaper();
    if (remote == null) return;

    final next = await wallpaperFromRemote(remote);
    if (next == null || isDefaultLocalWallpaper(next)) return;

    await _persistGlobal(next, pushRemote: false);
  }

  Future<void> flushPendingPush() async {
    final prefs = ref.read(chatWallpaperPrefsProvider);
    final global = prefs?.global ?? state.global;

    if (prefs != null && !prefs.syncPending) return;

    if (prefs == null) {
      final sp = await SharedPreferences.getInstance();
      if (!(sp.getBool(ChatWallpaperPrefs.syncPendingKey) ?? false)) return;
    }

    await _pushWallpaperBestEffort(global);
  }

  Future<void> setGlobal(ChatWallpaperConfig config) async {
    await _persistGlobal(config);
  }

  Future<void> setThread(String threadId, ChatWallpaperConfig config) async {
    final prefs = ref.read(chatWallpaperPrefsProvider);
    if (prefs == null) return;
    await prefs.saveThread(threadId, config);
    final next = Map<String, ChatWallpaperConfig>.from(state.threadOverrides);
    next[threadId] = config;
    state = state.copyWith(threadOverrides: next);
  }

  Future<void> clearThread(String threadId) async {
    final prefs = ref.read(chatWallpaperPrefsProvider);
    if (prefs == null) return;
    await prefs.clearThread(threadId);
    final next = Map<String, ChatWallpaperConfig>.from(state.threadOverrides);
    next.remove(threadId);
    state = state.copyWith(threadOverrides: next);
  }

  Future<void> _persistGlobal(
    ChatWallpaperConfig next, {
    bool pushRemote = true,
  }) async {
    await _saveGlobalLocal(next);
    state = state.copyWith(global: next);

    if (!pushRemote) return;

    await _setSyncPending(true);
    unawaited(_pushWallpaperBestEffort(next));
  }

  Future<void> _saveGlobalLocal(ChatWallpaperConfig next) async {
    final prefs = ref.read(chatWallpaperPrefsProvider);
    if (prefs != null) {
      await prefs.saveGlobal(next);
      return;
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      ChatWallpaperPrefs.globalKey,
      jsonEncode(next.toJson()),
    );
  }

  Future<void> _setSyncPending(bool value) async {
    final prefs = ref.read(chatWallpaperPrefsProvider);
    if (prefs != null) {
      await prefs.setSyncPending(value);
      return;
    }
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(ChatWallpaperPrefs.syncPendingKey, value);
  }

  Future<void> _pushWallpaperBestEffort(ChatWallpaperConfig next) async {
    final payload = await buildPushPayload(next);
    if (payload == null) {
      await _setSyncPending(true);
      if (kDebugMode) {
        debugPrint('[ChatWallpaperController] wallpaper payload build failed');
      }
      return;
    }

    var working = next;
    if (payload.mediaUrl != null && payload.mediaUrl != next.remoteMediaUrl) {
      working = next.copyWith(remoteMediaUrl: payload.mediaUrl);
      await _saveGlobalLocal(working);
      state = state.copyWith(global: working);
    }

    final result = await TalkWallpaperSyncService.instance.pushWallpaper(
      type: payload.type,
      mediaUrl: payload.mediaUrl,
      presetId: payload.presetId,
      dim: payload.dim,
      blur: payload.blur,
      scrim: payload.scrim,
    );

    if (!result.pending) {
      await _setSyncPending(false);
      if (kDebugMode) debugPrint('[ChatWallpaperController] wallpaper PUT ok');
    } else {
      await _setSyncPending(true);
      if (kDebugMode) {
        debugPrint(
          '[ChatWallpaperController] wallpaper PUT pending '
          '(${result.httpStatus})',
        );
      }
    }
  }
}

final chatWallpaperControllerProvider =
    NotifierProvider<ChatWallpaperController, ChatWallpaperState>(
  ChatWallpaperController.new,
);
