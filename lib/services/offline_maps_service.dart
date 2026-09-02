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
const String kFriendMapTileUrl =
    'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png';
const List<String> kFriendMapSubdomains = ['a', 'b', 'c', 'd'];
const int kFriendMapMaxNativeZoom = 18;
const double kFriendMapMaxZoom = 20.0;
const double kFriendMapMinZoom = 2.0;
const String kFriendMapAttribution = '© CARTO © OpenStreetMap contributors';
const String _kUserAgent = 'com.interactpak.interactTalk';

/// FMTC store: browse cache + offline region packs share one store, so a
/// downloaded area is served from disk automatically when the network drops.
const String kFriendMapFmtcStore = 'friendmap';

IOClient _tileHttpClient() {
  // FMTC's default client chokes on some Android stacks (unknownFetchException);
  // a plain HTTP/1.1 IOClient is the documented workaround.
  final inner = HttpClient()
    ..userAgent = _kUserAgent
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
      await const FMTCStore(kFriendMapFmtcStore).manage.create();
      _ready = true;
    } catch (e) {
      debugPrint('⚠️  Offline map cache init failed: $e');
    }
  }

  /// Online-first tile provider that writes browsed tiles into the offline
  /// store and serves downloaded packs when the network is gone. Falls back to
  /// a plain network provider if FMTC never initialised.
  TileProvider tileProvider() {
    if (!_ready) {
      // Same HTTP client + user-agent as FMTC path — bare NetworkTileProvider
      // fails on some Android stacks and can show blank / error tiles.
      return NetworkTileProvider(httpClient: _tileHttpClient());
    }
    return FMTCTileProvider(
      stores: const {kFriendMapFmtcStore: BrowseStoreStrategy.readUpdateCreate},
      loadingStrategy: BrowseLoadingStrategy.onlineFirst,
      httpClient: _tileHttpClient(),
    );
  }

  TileLayer _downloadTileLayer(bool retina) => TileLayer(
        urlTemplate: kFriendMapTileUrl,
        subdomains: kFriendMapSubdomains,
        userAgentPackageName: _kUserAgent,
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
