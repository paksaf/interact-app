// SPDX-License-Identifier: AGPL-3.0
//
// Friends map — live positions of you, your chat peers (friends), and IoT GPS
// trackers on ONE real map. Positions come from LocationTraceService, which is
// fed over OfflineRouter (cloud OR LAN/BLE mesh), so friends stay trackable
// with NO signal. The basemap is cached by OfflineMapsService (FMTC); a
// pre-downloaded region renders offline too. Map stack (flutter_map + FMTC) is
// ported from interact-maps-flutter. Added 2026-09-02.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../../models/location_fix.dart';
import '../../services/auth_service.dart';
import '../../services/location_share_service.dart';
import '../../services/location_trace_service.dart';
import '../../services/offline_maps_service.dart';
import '../../utils/shared_location_launcher.dart';
import '../../utils/shared_location_pin.dart';
import '../../widgets/branded_app_bar.dart';

class FriendsMapScreen extends ConsumerStatefulWidget {
  const FriendsMapScreen({super.key});

  @override
  ConsumerState<FriendsMapScreen> createState() => _FriendsMapScreenState();
}

class _FriendsMapScreenState extends ConsumerState<FriendsMapScreen> {
  final MapController _map = MapController();
  List<LocationFix> _fixes = const [];
  LocationShareSession? _liveSession;
  StreamSubscription<List<LocationFix>>? _fixSub;
  StreamSubscription<LocationShareSession?>? _sessionSub;
  StreamSubscription<Position>? _posSub;
  String? _myId;
  LatLng? _myPos;
  bool _fittedOnce = false;

  static const LatLng _fallbackCenter = LatLng(30.3753, 69.3451); // Pakistan

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await LocationTraceService.instance.load();
    _myId = await ref.read(authServiceProvider).localUserId();
    _fixSub = LocationTraceService.instance.fixesStream.listen((f) {
      if (mounted) setState(() => _fixes = f);
    });
    _sessionSub = LocationShareService.instance.sessionStream.listen((s) {
      if (mounted) setState(() => _liveSession = s);
    });
    if (mounted) {
      setState(() {
        _fixes = LocationTraceService.instance.fixes;
        _liveSession = LocationShareService.instance.session;
      });
    }
    await _startMyLocation();
    _fitToEverything();
  }

  Future<void> _startMyLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition().timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('gps'),
      );
      if (mounted) setState(() => _myPos = LatLng(pos.latitude, pos.longitude));
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 15,
        ),
      ).listen((p) {
        if (mounted) setState(() => _myPos = LatLng(p.latitude, p.longitude));
      });
    } catch (_) {/* no GPS — map still shows peers */}
  }

  @override
  void dispose() {
    unawaited(_fixSub?.cancel());
    unawaited(_sessionSub?.cancel());
    unawaited(_posSub?.cancel());
    super.dispose();
  }

  List<LatLng> get _allPoints => [
        if (_myPos != null) _myPos!,
        for (final f in _fixes) LatLng(f.lat, f.lng),
      ];

  void _fitToEverything() {
    final pts = _allPoints;
    if (pts.isEmpty) return;
    // Defer to after first layout so the camera has a size.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (pts.length == 1) {
          _map.move(pts.first, 15);
        } else {
          _map.fitCamera(
            CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(pts),
              padding: const EdgeInsets.all(60),
              maxZoom: 16,
            ),
          );
        }
        _fittedOnce = true;
      } catch (_) {}
    });
  }

  String _ageLabel(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Color _sourceColor(LocationFixSource s, ColorScheme cs) => switch (s) {
        LocationFixSource.phone => cs.primary,
        LocationFixSource.iot => Colors.orange.shade700,
        LocationFixSource.ble => Colors.purple.shade600,
        LocationFixSource.lan => Colors.teal.shade600,
      };

  double? _distanceFromMe(LocationFix f) {
    if (_myPos == null) return null;
    return const Distance().as(
      LengthUnit.Meter,
      _myPos!,
      LatLng(f.lat, f.lng),
    );
  }

  String _distanceLabel(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final initial = _myPos ??
        (_fixes.isNotEmpty
            ? LatLng(_fixes.first.lat, _fixes.first.lng)
            : _fallbackCenter);

    return Scaffold(
      appBar: BrandedAppBar(
        title: 'Friends map',
        subtitle: 'Live · works offline',
        actions: [
          IconButton(
            tooltip: 'Fit everyone',
            icon: const Icon(Icons.center_focus_strong_rounded),
            onPressed: _fitToEverything,
          ),
          IconButton(
            tooltip: 'Download this area for offline',
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: _openOfflineSheet,
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: initial,
              initialZoom: _fixes.isEmpty && _myPos == null ? 4 : 14,
              minZoom: kFriendMapMinZoom,
              maxZoom: kFriendMapMaxZoom,
              onMapReady: () {
                if (!_fittedOnce) _fitToEverything();
              },
            ),
            children: [
              TileLayer(
                urlTemplate: kFriendMapTileUrl,
                subdomains: kFriendMapSubdomains,
                userAgentPackageName: 'com.interactpak.interactTalk',
                maxNativeZoom: kFriendMapMaxNativeZoom,
                retinaMode: RetinaMode.isHighDensity(context),
                tileProvider: OfflineMapsService.instance.tileProvider(),
              ),
              MarkerLayer(markers: _buildMarkers(cs)),
            ],
          ),
          // Attribution (Carto/OSM tile terms).
          Positioned(
            left: 6,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surface.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                kFriendMapAttribution,
                style: TextStyle(fontSize: 9, color: cs.outline),
              ),
            ),
          ),
          if (_liveSession != null)
            Positioned(
              top: 10,
              left: 12,
              right: 12,
              child: _liveShareBanner(cs),
            ),
        ],
      ),
      floatingActionButton: _liveSession == null
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/chats'),
              icon: const Icon(Icons.share_location_rounded),
              label: const Text('Share my location'),
            )
          : null,
    );
  }

  Widget _liveShareBanner(ColorScheme cs) => Material(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        elevation: 2,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.my_location, size: 18, color: cs.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Sharing your live location · until '
                  '${_liveSession!.until.toLocal().toString().substring(11, 16)}',
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    unawaited(LocationShareService.instance.stop()),
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
      );

  List<Marker> _buildMarkers(ColorScheme cs) {
    final markers = <Marker>[];
    for (final f in _fixes) {
      final isMe = _myId != null && f.entityId == _myId;
      final color = isMe ? cs.primary : _sourceColor(f.source, cs);
      markers.add(
        Marker(
          point: LatLng(f.lat, f.lng),
          width: 140,
          height: 64,
          alignment: Alignment.topCenter,
          child: _MarkerPin(
            label: isMe ? 'You' : f.displayName,
            color: color,
            live: f.live,
            onTap: () => _showFixSheet(f, isMe),
          ),
        ),
      );
    }
    if (_myPos != null && !_fixes.any((f) => f.entityId == _myId)) {
      markers.add(
        Marker(
          point: _myPos!,
          width: 24,
          height: 24,
          child: _MeDot(color: cs.primary),
        ),
      );
    }
    return markers;
  }

  void _showFixSheet(LocationFix f, bool isMe) {
    final cs = Theme.of(context).colorScheme;
    final dist = _distanceFromMe(f);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: _sourceColor(f.source, cs),
                    child: Icon(
                      isMe ? Icons.person : Icons.place,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isMe ? 'You' : f.displayName,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '${f.source.label} · ${_ageLabel(f.at)}',
                          style: TextStyle(color: cs.outline, fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  if (f.live)
                    Chip(
                      label: const Text('Live'),
                      backgroundColor: cs.errorContainer,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (dist != null)
                Text('${_distanceLabel(dist)} from you',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                '${f.lat.toStringAsFixed(5)}, ${f.lng.toStringAsFixed(5)}'
                '${f.accuracyM != null ? ' · ±${f.accuracyM!.round()} m' : ''}',
                style: TextStyle(color: cs.outline, fontSize: 12),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        _map.move(LatLng(f.lat, f.lng), 16);
                        Navigator.of(ctx).pop();
                      },
                      icon: const Icon(Icons.gps_fixed),
                      label: const Text('Center'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await openSharedLocationPin(SharedLocationPin(
                          lat: f.lat,
                          lng: f.lng,
                          label: f.displayName,
                          live: f.live,
                        ));
                      },
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Open in Maps'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Offline download sheet ────────────────────────────────────────────────
  void _openOfflineSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _OfflineSheet(map: _map),
    );
  }
}

class _MarkerPin extends StatelessWidget {
  const _MarkerPin({
    required this.label,
    required this.color,
    required this.live,
    required this.onTap,
  });
  final String label;
  final Color color;
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            constraints: const BoxConstraints(maxWidth: 130),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Icon(
            live ? Icons.location_on : Icons.location_on_outlined,
            color: color,
            size: 30,
          ),
        ],
      ),
    );
  }
}

class _MeDot extends StatelessWidget {
  const _MeDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.5),
              blurRadius: 8,
              spreadRadius: 2,
            ),
          ],
        ),
      );
}

class _OfflineSheet extends StatefulWidget {
  const _OfflineSheet({required this.map});
  final MapController map;
  @override
  State<_OfflineSheet> createState() => _OfflineSheetState();
}

class _OfflineSheetState extends State<_OfflineSheet> {
  double _minZoom = 11;
  double _maxZoom = 16;
  bool _downloading = false;
  int _done = 0;
  int _total = 0;
  String? _error;
  List<OfflinePackInfo> _packs = const [];

  @override
  void initState() {
    super.initState();
    _refreshPacks();
  }

  Future<void> _refreshPacks() async {
    final p = await OfflineMapsService.instance.listPacks();
    if (mounted) setState(() => _packs = p);
  }

  Future<void> _download() async {
    final bounds = widget.map.camera.visibleBounds;
    setState(() {
      _downloading = true;
      _done = 0;
      _total = 0;
      _error = null;
    });
    await OfflineMapsService.instance.downloadRegion(
      bounds: bounds,
      minZoom: _minZoom.round(),
      maxZoom: _maxZoom.round(),
      retina: false,
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _done = done;
            _total = total;
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _downloading = false);
        _refreshPacks();
      },
      onError: (e) {
        if (mounted) {
          setState(() {
            _downloading = false;
            _error = e.toString();
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cached = _packs.fold<double>(0, (a, p) => a + p.sizeKib);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Download this area',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Saves the current map view so friends stay visible on the map '
              'with no signal. Zoom to the area first, then download.',
              style: TextStyle(color: cs.outline, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            Text('Detail level (zoom $_minZoom–$_maxZoom)',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            RangeSlider(
              min: 8,
              max: 18,
              divisions: 10,
              labels: RangeLabels('$_minZoom', '$_maxZoom'),
              values: RangeValues(_minZoom, _maxZoom),
              onChanged: _downloading
                  ? null
                  : (v) => setState(() {
                        _minZoom = v.start.roundToDouble();
                        _maxZoom = v.end.roundToDouble();
                      }),
            ),
            if (_downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _total > 0 ? _done / _total : null,
              ),
              const SizedBox(height: 6),
              Text('$_done / $_total tiles',
                  style: TextStyle(color: cs.outline, fontSize: 12)),
            ] else
              FilledButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Download current view'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: cs.error, fontSize: 12)),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Offline cache: ${cached >= 1024 ? '${(cached / 1024).toStringAsFixed(1)} MB' : '${cached.round()} KB'}',
                    style: TextStyle(color: cs.outline, fontSize: 12.5),
                  ),
                ),
                TextButton(
                  onPressed: _downloading
                      ? null
                      : () async {
                          await OfflineMapsService.instance
                              .clearOfflineTiles();
                          await _refreshPacks();
                        },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
