// VPS in-app update — checks downloads.interactpak.com/interact/latest.json,
// downloads the ABI-matched APK into app storage, then opens the system
// installer (open_filex). Auto-download defaults ON (Maps donor pattern).
//
// Banner / Me tile ONLY when remote version_code is STRICTLY greater than the
// installed PackageInfo.buildNumber. Equal or older → clear all update UI.
//
// Gotcha #67: never publish an arm64-only file as apk_url.
// Gotcha #67b: split APKs must keep versionCode == pubspec +N (not abi*1000+N).

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

const _kDeviceChannel = MethodChannel('com.interactpak.interact_talk/device');

const String kUpdateManifestUrl = String.fromEnvironment(
  'INTERACT_UPDATE_MANIFEST',
  defaultValue: 'https://downloads.interactpak.com/interact/latest.json',
);

enum UpdateDownloadState { idle, downloading, downloaded, failed }

@immutable
class UpdateInfo {
  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.apkUrl,
    required this.changelog,
    required this.forceUpdate,
    this.apkUrlArmeabiV7a,
    this.apkUrlArm64,
    this.releasedAt,
  });

  final String versionName;
  final int versionCode;
  final String apkUrl;
  final String changelog;
  final bool forceUpdate;
  final String? apkUrlArmeabiV7a;
  final String? apkUrlArm64;
  final DateTime? releasedAt;

  /// Short mark for banners / Me tile — e.g. "v0.5.1 · Jul 31".
  String get versionMark {
    final date = releasedAt;
    if (date == null) return 'v$versionName';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = date.toLocal();
    return 'v$versionName · ${months[local.month - 1]} ${local.day}';
  }

  factory UpdateInfo.fromJson(Map<String, dynamic> j) {
    DateTime? released;
    final raw = j['released_at'] ?? j['releasedAt'] ?? j['published_at'];
    if (raw is String && raw.isNotEmpty) {
      released = DateTime.tryParse(raw);
    }
    return UpdateInfo(
      versionName: (j['version_name'] ?? j['version'] ?? '') as String,
      versionCode: (j['version_code'] is int)
          ? j['version_code'] as int
          : int.tryParse('${j['version_code'] ?? 0}') ?? 0,
      apkUrl: (j['apk_url'] ?? j['download_url'] ?? '') as String,
      apkUrlArmeabiV7a: (j['apk_url_armeabi_v7a'] as String?)?.trim(),
      apkUrlArm64: (j['apk_url_arm64_v8a'] as String?)?.trim(),
      changelog: (j['changelog'] ?? j['notes'] ?? '') as String,
      forceUpdate: (j['force_update'] ?? false) as bool,
      releasedAt: released,
    );
  }

  Future<String> downloadUrlForThisDevice() async {
    try {
      final abi = await _kDeviceChannel.invokeMethod<String>('primaryAbi');
      if (abi == 'armeabi-v7a' || abi == 'armeabi') {
        final u = apkUrlArmeabiV7a;
        if (u != null && u.isNotEmpty) return u;
      }
      if (abi != null && abi.startsWith('arm64')) {
        final u = apkUrlArm64;
        if (u != null && u.isNotEmpty) return u;
      }
    } catch (_) {/* fall through to fat */}
    return apkUrl;
  }
}

/// Whether [remoteBuild]/[remoteName] is a STRICTLY newer release than the
/// running build. Fail closed: equal, older, or unreadable → false — never nag
/// on the same release or on unknown data.
///
/// buildNumber (Android versionCode) is the comparator, but the version NAME
/// guards against Flutter `--split-per-abi` versionCode inflation
/// (`versionCode = abiIndex*1000 + base`, so a 0.5.1 arm64 split reports 8xxx
/// while the CDN advertises the 6xxx base). The version NAME is never inflated:
///   * different name → the semver name decides (build ignored);
///   * same name      → strict build compare `remote > local`.
/// A split install of the exact release the CDN advertises therefore compares
/// EQUAL by name, and its inflated local build (always ≥ base) can never
/// satisfy `remote > local` → no banner.
///
/// NOTE: this project's base versionCodes are 4-digit (e.g. 6038) AND the
/// build forces `versionCodeOverride = flutter.versionCode` for every ABI
/// (android/app/build.gradle.kts, gotcha #67b), so the on-device build already
/// equals the base for current builds. The generic `localBuild % 1000`
/// recovery would be WRONG here (6038 % 1000 == 38 → would nag) and is
/// deliberately NOT used; the version NAME is the reliable de-inflation signal.
bool isRemoteReleaseNewer({
  required String localName,
  required int localBuild,
  required String remoteName,
  required int remoteBuild,
}) {
  // Fail closed on unreadable data — never treat 0/negative as "ancient".
  if (localBuild <= 0 || remoteBuild <= 0) return false;
  // Fail closed when the LOCAL version name is unknown. package_info_plus can
  // return a populated buildNumber but an empty/partial version name on a cold
  // first frame (MIUI/plugin race — a warm restart then reads it correctly).
  // Without a readable local name we cannot trust the name-first comparison,
  // and falling through to a raw build-only compare risks a spurious "update
  // available" on launch (the "restart makes it disappear" symptom) — so never
  // prompt until the local name is known.
  if (localName.trim().isEmpty) return false;
  final byName = _compareSemver(remoteName, localName);
  if (byName != null && byName != 0) return byName > 0;
  // Same name (or a name that can't be parsed) → strict build comparison.
  return remoteBuild > localBuild;
}

/// Compares two dotted numeric versions ("0.5.1"). Positive if [a] > [b], 0 if
/// equal, negative if [a] < [b], or null if either can't be parsed as dotted
/// integers.
int? _compareSemver(String a, String b) {
  final pa = _semverParts(a);
  final pb = _semverParts(b);
  if (pa == null || pb == null) return null;
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

List<int>? _semverParts(String v) {
  // Drop any build/prerelease suffix: "0.5.1+6039" / "0.5.1-rc1" → "0.5.1".
  final core = v.trim().split('+').first.split('-').first;
  if (core.isEmpty) return null;
  final out = <int>[];
  for (final p in core.split('.')) {
    final n = int.tryParse(p.trim());
    if (n == null) return null;
    out.add(n);
  }
  return out.isEmpty ? null : out;
}

/// In-app OTA: check → optional silent download → one-tap install.
class UpdateService extends ChangeNotifier {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const _autoDownloadKey = 'update_auto_download';
  static const _dismissedCodeKey = 'update_dismissed_code';
  static const _autoFiredKey = 'update_autofired_version_code';

  UpdateInfo? _available;
  /// Non-null only when remote build is strictly newer than installed.
  UpdateInfo? get available => _available;

  bool _autoDownloadEnabled = true;
  bool get autoDownloadEnabled => _autoDownloadEnabled;

  UpdateDownloadState _downloadState = UpdateDownloadState.idle;
  UpdateDownloadState get downloadState => _downloadState;
  double _downloadProgress = 0;
  double get downloadProgress => _downloadProgress;
  String? _downloadedApkPath;
  String? get downloadedApkPath => _downloadedApkPath;

  int _dismissedCode = 0;
  int _installedCode = 0;
  String _installedName = '';
  /// Last known installed build (for Me tab "You're on vX").
  int get installedVersionCode => _installedCode;
  bool _bootChecked = false;

  Future<int> readInstalledVersionCode() async {
    final pkg = await PackageInfo.fromPlatform();
    final code = int.tryParse(pkg.buildNumber) ?? 0;
    _installedCode = code;
    // Version NAME (e.g. "0.5.1") is captured alongside the build so the
    // update comparison can guard against Flutter --split-per-abi versionCode
    // inflation — see isRemoteReleaseNewer().
    _installedName = pkg.version;
    return code;
  }

  Future<void> _clearOffer({bool resetDownload = true}) async {
    _available = null;
    if (resetDownload) {
      _downloadState = UpdateDownloadState.idle;
      _downloadProgress = 0;
      _downloadedApkPath = null;
    }
    notifyListeners();
  }

  /// Boot / resume: check CDN, show banner via listeners, auto-download if ON.
  Future<UpdateInfo?> checkOnBoot({bool force = false}) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      _autoDownloadEnabled = prefs.getBool(_autoDownloadKey) ?? true;
      _dismissedCode = prefs.getInt(_dismissedCodeKey) ?? 0;
    } catch (_) {/* defaults */}

    final installed = await readInstalledVersionCode();
    // Fail closed: never offer an update if we can't read the installed code
    // (would otherwise treat currentCode=0 as "ancient" and always nag).
    if (installed <= 0) {
      debugPrint('UpdateService: installed versionCode unreadable — no offer');
      await _clearOffer();
      return null;
    }

    // Stale in-memory offer from a prior probe / session — drop if no longer newer.
    if (_available != null &&
        !isRemoteReleaseNewer(
          localName: _installedName,
          localBuild: installed,
          remoteName: _available!.versionName,
          remoteBuild: _available!.versionCode,
        )) {
      await _clearOffer();
    }

    if (_bootChecked && !force && _available != null) {
      if (isRemoteReleaseNewer(
        localName: _installedName,
        localBuild: installed,
        remoteName: _available!.versionName,
        remoteBuild: _available!.versionCode,
      )) {
        return _available;
      }
      await _clearOffer();
    }
    _bootChecked = true;

    final info = await checkOnce();
    if (info == null) {
      await _clearOffer();
      return null;
    }
    if (!isRemoteReleaseNewer(
      localName: _installedName,
      localBuild: installed,
      remoteName: info.versionName,
      remoteBuild: info.versionCode,
    )) {
      await _clearOffer();
      return null;
    }
    if (info.versionCode == _dismissedCode && !info.forceUpdate) {
      await _clearOffer(resetDownload: false);
      return null;
    }

    _available = info;
    notifyListeners();

    if (_autoDownloadEnabled) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final fired = prefs.getInt(_autoFiredKey) ?? 0;
        if (fired != info.versionCode) {
          await prefs.setInt(_autoFiredKey, info.versionCode);
          unawaited(downloadInBackground());
        }
      } catch (_) {
        unawaited(downloadInBackground());
      }
    }
    return info;
  }

  /// Return an UpdateInfo IFF a strictly newer build exists.
  Future<UpdateInfo?> checkOnce() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final resp = await http
          .get(Uri.parse(kUpdateManifestUrl),
              headers: {
                'Accept': 'application/json',
                // Bust CDN/browser caches that can stick a probe version_code.
                'Cache-Control': 'no-cache',
                'Pragma': 'no-cache',
              })
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final info =
          UpdateInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
      if (info.apkUrl.isEmpty || info.versionCode <= 0) return null;

      final currentCode = await readInstalledVersionCode();
      final currentName = _installedName;
      debugPrint(
        'UpdateService.checkOnce: installed=$currentName ($currentCode) '
        'remote=${info.versionName} (${info.versionCode})',
      );
      if (currentCode <= 0) return null;
      if (!isRemoteReleaseNewer(
        localName: currentName,
        localBuild: currentCode,
        remoteName: info.versionName,
        remoteBuild: info.versionCode,
      )) {
        return null;
      }
      return info;
    } catch (e, st) {
      debugPrint('UpdateService.checkOnce failed: $e\n$st');
      return null;
    }
  }

  Future<void> setAutoDownloadEnabled(bool enabled) async {
    _autoDownloadEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoDownloadKey, enabled);
    } catch (_) {}
  }

  Future<void> dismiss() async {
    final info = _available;
    if (info == null) return;
    _dismissedCode = info.versionCode;
    await _clearOffer();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_dismissedCodeKey, info.versionCode);
    } catch (_) {}
  }

  Future<void> downloadInBackground({UpdateInfo? info}) async {
    final target = info ?? _available;
    if (target == null) return;

    // Refuse to download an APK that isn't actually newer.
    final installed = await readInstalledVersionCode();
    if (!isRemoteReleaseNewer(
      localName: _installedName,
      localBuild: installed,
      remoteName: target.versionName,
      remoteBuild: target.versionCode,
    )) {
      await _clearOffer();
      return;
    }

    if (_downloadState == UpdateDownloadState.downloading) return;
    if (_downloadState == UpdateDownloadState.downloaded &&
        _downloadedApkPath != null) {
      return;
    }

    _downloadState = UpdateDownloadState.downloading;
    _downloadProgress = 0;
    notifyListeners();

    try {
      final url = await target.downloadUrlForThisDevice();
      final dir = await getApplicationSupportDirectory();
      final path = '${dir.path}/interact-talk-${target.versionCode}.apk';
      await Dio().download(
        url,
        path,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            _downloadProgress = received / total;
            notifyListeners();
          }
        },
      );
      // Re-check after download — user may have installed meanwhile.
      final now = await readInstalledVersionCode();
      if (!isRemoteReleaseNewer(
        localName: _installedName,
        localBuild: now,
        remoteName: target.versionName,
        remoteBuild: target.versionCode,
      )) {
        await _clearOffer();
        return;
      }
      _downloadedApkPath = path;
      _downloadState = UpdateDownloadState.downloaded;
      _downloadProgress = 1;
      notifyListeners();
    } catch (e, st) {
      debugPrint('UpdateService.download failed: $e\n$st');
      _downloadState = UpdateDownloadState.failed;
      notifyListeners();
    }
  }

  Future<void> installOrDownload({UpdateInfo? info}) async {
    final target = info ?? _available;
    if (target == null) return;

    final installed = await readInstalledVersionCode();
    if (!isRemoteReleaseNewer(
      localName: _installedName,
      localBuild: installed,
      remoteName: target.versionName,
      remoteBuild: target.versionCode,
    )) {
      await _clearOffer();
      return;
    }

    if (_downloadState == UpdateDownloadState.downloaded &&
        _downloadedApkPath != null) {
      try {
        final res = await OpenFilex.open(_downloadedApkPath!);
        if (res.type == ResultType.done) return;
      } catch (e) {
        debugPrint('UpdateService.install failed: $e');
      }
    }

    if (_downloadState != UpdateDownloadState.downloading) {
      await downloadInBackground(info: target);
      if (_downloadState == UpdateDownloadState.downloaded &&
          _downloadedApkPath != null) {
        try {
          await OpenFilex.open(_downloadedApkPath!);
          return;
        } catch (_) {/* browser fallback */}
      }
    }

    await openDownload(target);
  }

  Future<void> openDownload(UpdateInfo info) async {
    try {
      final url = await info.downloadUrlForThisDevice();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e, st) {
      debugPrint('UpdateService.openDownload failed: $e\n$st');
    }
  }
}
