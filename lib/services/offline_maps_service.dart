// SPDX-License-Identifier: AGPL-3.0
//
// Offline map tiles for the friends map. Wraps flutter_map_tile_caching
// (FMTC v10 / ObjectBox): ONE store is both the browse cache AND the target
// for downloaded region packs, so an area a user pre-downloads is served from
// disk with ZERO signal — the whole point of tracking friends in no-coverage
// areas. Raster basemap + tile URLs mirror interact-maps-flutter's proven
// street-pack path (Carto Voyager). Added 2026-09-02.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:http/io_client.dart';

/// Carto Voyager raster basemap — same tiles interact-maps uses.
// Key-free OpenTopoMap raster — topographic detail (contours, trails, tracks,
// unpaved 4x4 roads) for off-roading + offline use. Carto keyless tiles are
// watermarked server-side; vector PMTiles can't be used here (pmtiles needs
// protobuf 3, livekit needs protobuf 6). OpenTopoMap is interact-maps' terrain
// layer. Higher-volume alternative if rate-limited: TomTom (keyed).
const String kFriendMapTileUrl =
    'https://tile.opentopomap.org/{z}/{x}/{y}.png';
const List<String> kFriendMapSubdomains = <String>[]; // OSM: no {s}
const int kFriendMapMaxNativeZoom = 17; // OpenTopoMap caps at 17
const double kFriendMapMaxZoom = 20.0;
const double kFriendMapMinZoom = 2.0;
const String kFriendMapAttribution =
    '© OpenTopoMap (CC-BY-SA) © OpenStreetMap contributors';

// TomTom raster FALLBACK (keyed) — only used when an OpenTopoMap tile fails to
// load (flutter_map fallbackUrl). Key comes from a build-time define, NOT source,
// so no live key lands in git: build with --dart-define=TOMTOM_MAP_KEY=<key>.
// Empty by default → no fallback (OpenTopoMap alone). Rotate + proxy via
// maps.interactpak.com when you can.
const String _kTomTomKey =
    String.fromEnvironment('TOMTOM_MAP_KEY', defaultValue: '');
String get kFriendMapFallbackTileUrl => _kTomTomKey.isEmpty
    ? ''
    : 'https://api.tomtom.com/map/1/tile/basic/main/{z}/{x}/{y}.png?key=$_kTomTomKey';

/// Must match the platform bundle / application id — tile CDNs and FMTC's HTTP
/// stack behave badly with a mismatched User-Agent.
String get kFriendMapUserAgent => Platform.isIOS
    ? 'com.interactpak.interactTalk'
    : 'com.interactpak.interact_talk';

/// FMTC store: browse cache + offline region packs share one store, so a
/// downloaded area is served from disk automatically when the network drops.
/// Bump suffix when tile URL/provider changes so stale error tiles are dropped.
const String kFriendMapFmtcStore = 'friendmap_v2';
const String _kLegacyFriendMapStore = 'friendmap';

IOClient _tileHttpClient() {
  // FMTC's default client chokes on some Android stacks (unknownFetchException);
  // a plain HTTP/1.1 IOClient is the documented workaround.
  final inner = HttpClient()
    ..userAgent = kFriendMapUserAgent
    ..connectionTimeout = const Duration(seconds: 10);
  return IOClient(inner);
}

class OfflinePackInfo {
  const OfflinePackInfo({
    required this.name,
    required this.tiles,
    required this.sizeKib,
  });
  final String name;
  final int tiles;
  final double sizeKib;

  String get sizeLabel => sizeKib >= 1024
      ? '${(sizeKib / 1024).toStringAsFixed(1)} MB'
      : '${sizeKib.round()} KB';
}

class OfflineMapsService {
  OfflineMapsService._();
  static final OfflineMapsService instance = OfflineMapsService._();

  bool _ready = false;
  bool get ready => _ready;

  /// Call once at startup — guarded so a cache failure never kills the app.
  Future<void> init() async {
    if (_ready) return;
    try {
      await FMTCObjectBoxBackend().initialise();
      // Drop pre-CARTO / bad-tile cache (e.g. "API key required" PNGs).
      try {
        await const FMTCStore(_kLegacyFriendMapStore).manage.delete();
      } catch (_) {}
      await const FMTCStore(kFriendMapFmtcStore).manage.create();
      _ready = true;
    } catch (e) {
      debugPrint('⚠️  Offline map cache init failed: $e');
    }
  }

  /// Direct Carto fetches — bypasses FMTC when the browse cache misbehaves on
  /// Android (FMTCBrowsingError / unknownFetchException). Mirrors interact-maps.
  TileProvider directNetworkTileProvider() =>
      NetworkTileProvider(httpClient: _tileHttpClient());

  /// Online-first FMTC browse cache + offline pack reads.
  TileProvider fmtcTileProvider() {
    if (!_ready) return directNetworkTileProvider();
    return FMTCTileProvider(
      stores: const {kFriendMapFmtcStore: BrowseStoreStrategy.readUpdateCreate},
      loadingStrategy: BrowseLoadingStrategy.onlineFirst,
      httpClient: _tileHttpClient(),
    );
  }

  /// Default tile provider for the friends map (FMTC when ready).
  TileProvider tileProvider() => fmtcTileProvider();

  TileLayer _downloadTileLayer(bool retina) => TileLayer(
        urlTemplate: kFriendMapTileUrl,
        subdomains: kFriendMapSubdomains,
        userAgentPackageName: kFriendMapUserAgent,
        retinaMode: retina,
      );

  /// Download every tile in [bounds] from [minZoom]..[maxZoom] into the offline
  /// store. Progress is reported via [onProgress]; [onDone]/[onError] finish.
  Future<void> downloadRegion({
    required LatLngBounds bounds,
    int minZoom = 11,
    int maxZoom = 16,
    bool retina = false,
    required void Function(int done, int total) onProgress,
    required void Function() onDone,
    required void Function(Object error) onError,
  }) async {
    if (!_ready) {
      onError(StateError('offline cache not ready'));
      return;
    }
    try {
      await const FMTCStore(kFriendMapFmtcStore).manage.create();
      final downloadable = RectangleRegion(bounds).toDownloadable(
        minZoom: minZoom,
        maxZoom: maxZoom,
        options: _downloadTileLayer(retina),
      );
      final dl = const FMTCStore(kFriendMapFmtcStore).download.startForeground(
            region: downloadable,
            parallelThreads: 3,
          );
      dl.downloadProgress.listen(
        (p) => onProgress(p.successfulTilesCount, p.maxTilesCount),
        onDone: onDone,
        onError: onError,
        cancelOnError: true,
      );
      dl.tileEvents.listen(null); // drain so it doesn't back-pressure
    } catch (e) {
      onError(e);
    }
  }

  Future<List<OfflinePackInfo>> listPacks() async {
    if (!_ready) return const [];
    final out = <OfflinePackInfo>[];
    try {
      final stores = await FMTCRoot.stats.storesAvailable;
      for (final s in stores) {
        out.add(OfflinePackInfo(
          name: s.storeName,
          tiles: await s.stats.length,
          sizeKib: await s.stats.size,
        ));
      }
    } catch (e) {
      debugPrint('listPacks: $e');
    }
    return out;
  }

  /// Wipe all downloaded/cached tiles (keeps the store) to reclaim space.
  Future<void> clearOfflineTiles() async {
    try {
      await const FMTCStore(kFriendMapFmtcStore).manage.reset();
    } catch (e) {
      debugPrint('clearOfflineTiles: $e');
    }
  }
}
