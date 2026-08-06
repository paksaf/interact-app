// SPDX-License-Identifier: AGPL-3.0
//
// CameraEffectsScreen — the Zoom/Meet-style background picker + live self-view.
//
// Pipeline (borrowed from interact-maps' driver_monitor camera→InputImage
// integration, READ-only donor — detector swapped for the selfie segmenter):
//   CameraController(front, low, nv21/bgra) → startImageStream(throttled)
//     → InputImage.fromBytes → SelfieSegmenter.processImage → SegmentationMask
//     → build (frameImage, maskImage) ui.Images
//     → CustomPainter composites: background (blur / brand image / dim) with
//       the person cut out via BlendMode.dstIn.
//
// Why Canvas + ImageFilter.blur (not per-pixel Dart blur): the blur + mask
// composite run on the GPU, so only the YUV→RGBA conversion is CPU-bound —
// tolerable at ResolutionPreset.low, throttled to ~12fps. This keeps a real,
// smooth self-view without a native processor. Broadcasting the composite to
// the LiveKit publish track is the next increment (see camera_effects.dart).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';

import '../../services/camera_effects.dart';
import '../../services/talk_camera_gate.dart';
import '../../widgets/branded_app_bar.dart';

class CameraEffectsScreen extends ConsumerStatefulWidget {
  const CameraEffectsScreen({super.key});
  @override
  ConsumerState<CameraEffectsScreen> createState() =>
      _CameraEffectsScreenState();
}

class _CameraEffectsScreenState extends ConsumerState<CameraEffectsScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  CameraDescription? _frontCam;
  final _segmenter = SelfieSegmenter(
    mode: SegmenterMode.stream,
    enableRawSizeMask: true,
  );

  bool _busy = false;
  DateTime _lastProcess = DateTime.fromMillisecondsSinceEpoch(0);
  // Maps/AutoSense donor: skip-while-busy + ~10fps keeps mid-tier phones smooth.
  static const _minInterval = Duration(milliseconds: 100); // ~10fps

  ui.Image? _frameImage;
  ui.Image? _maskImage;
  ui.Image? _bgImage;
  String? _bgAssetLoaded;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _releaseForGate() async {
    final c = _controller;
    _controller = null;
    await _safeDispose(c);
    if (mounted) {
      setState(() {
        _frameImage = null;
        _maskImage = null;
      });
    }
  }

  /// Disposes a controller, swallowing Camerax teardown races (Maps donor).
  Future<void> _safeDispose(CameraController? c) async {
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) {
        await c.stopImageStream();
      }
    } catch (_) {/* ignore */}
    try {
      await c.dispose();
    } catch (_) {
      // releaseFlutterSurfaceTexture before preview init — safe to ignore.
    }
  }

  Future<void> _start() async {
    try {
      await TalkCameraGate.releaseIfHeld();
      TalkCameraGate.releaseLocalCamera = _releaseForGate;
      final cams = await availableCameras();
      CameraDescription? front;
      for (final c in cams) {
        if (c.lensDirection == CameraLensDirection.front) {
          front = c;
          break;
        }
      }
      front ??= cams.isNotEmpty ? cams.first : null;
      if (front == null) {
        setState(() => _error = 'No camera available');
        return;
      }
      _frontCam = front;
      await _openController(front);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera error: $e');
    }
  }

  Future<void> _openController(CameraDescription front) async {
    final previous = _controller;
    _controller = null;
    await _safeDispose(previous);
    final controller = CameraController(
      front,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.android
          ? ImageFormatGroup.nv21
          : ImageFormatGroup.bgra8888,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await _safeDispose(controller);
        return;
      }
      _controller = controller;
      await controller.startImageStream(_onImage);
      setState(() => _error = null);
    } catch (e) {
      await _safeDispose(controller);
      if (mounted) setState(() => _error = 'Camera error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Maps camera_screen: release on inactive so LiveKit / OS can reclaim;
    // reopen on resume when still on this screen.
    if (state == AppLifecycleState.inactive) {
      final c = _controller;
      _controller = null;
      _safeDispose(c);
    } else if (state == AppLifecycleState.resumed) {
      final cam = _frontCam;
      if (cam != null && _controller == null) {
        TalkCameraGate.releaseLocalCamera = _releaseForGate;
        _openController(cam);
      }
    }
  }

  void _onImage(CameraImage image) {
    if (_busy) return;
    final now = DateTime.now();
    if (now.difference(_lastProcess) < _minInterval) return;
    _lastProcess = now;
    _busy = true;
    _process(image).whenComplete(() => _busy = false);
  }

  Future<void> _process(CameraImage image) async {
    final effect = ref.read(cameraEffectProvider);
    // None → just show the raw preview widget; skip the heavy path entirely.
    if (effect == CameraEffect.none) {
      if (_frameImage != null && mounted) setState(() => _frameImage = null);
      return;
    }

    // 1. CameraImage → RGBA bytes → ui.Image (the live frame).
    final rgba = _toRgba(image);
    if (rgba == null) return;
    final frame = await _decode(rgba, image.width, image.height);

    // 2. Segment → mask alpha ui.Image (person = opaque, background = clear).
    final mask = await _segment(image);

    // 3. Preload the chosen background image once.
    if (effect.isImage && _bgAssetLoaded != effect.asset) {
      _bgImage = await _loadAsset(effect.asset!);
      _bgAssetLoaded = effect.asset;
    }

    if (!mounted) return;
    setState(() {
      _frameImage = frame;
      _maskImage = mask;
    });
  }

  Future<ui.Image?> _segment(CameraImage image) async {
    final input = _toInputImage(image);
    if (input == null) return null;
    try {
      final SegmentationMask? m = await _segmenter.processImage(input);
      if (m == null) return null;
      // confidences: foreground probability per pixel (row-major, m.width×m.height).
      final w = m.width, h = m.height;
      final conf = m.confidences;
      final px = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        final a = (conf[i] * 255).round().clamp(0, 255);
        final o = i * 4;
        px[o] = 255;
        px[o + 1] = 255;
        px[o + 2] = 255;
        px[o + 3] = a; // person → opaque white; background → transparent
      }
      return _decode(px, w, h);
    } catch (_) {
      return null;
    }
  }

  Future<ui.Image> _decode(Uint8List rgba, int w, int h) {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  Future<ui.Image> _loadAsset(String path) async {
    final data = await DefaultAssetBundle.of(context).load(path);
    final codec =
        await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// NV21 (Android) / BGRA8888 (iOS) → RGBA8888. Compact, allocation-light.
  Uint8List? _toRgba(CameraImage image) {
    try {
      final w = image.width, h = image.height;
      if (defaultTargetPlatform != TargetPlatform.android) {
        // bgra8888 — swap B/R into rgba.
        final src = image.planes.first.bytes;
        final out = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          final o = i * 4;
          out[o] = src[o + 2];
          out[o + 1] = src[o + 1];
          out[o + 2] = src[o];
          out[o + 3] = 255;
        }
        return out;
      }
      // NV21: Y plane then interleaved VU.
      final yPlane = image.planes[0].bytes;
      final uvPlane = image.planes[1].bytes;
      final out = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final yIndex = y * image.planes[0].bytesPerRow + x;
          final uvIndex =
              (y >> 1) * image.planes[1].bytesPerRow + (x >> 1) * 2;
          final yy = yPlane[yIndex] & 0xff;
          final vv = (uvPlane[uvIndex] & 0xff) - 128;
          final uu = (uvPlane[uvIndex + 1] & 0xff) - 128;
          var r = (yy + 1.370705 * vv).round();
          var g = (yy - 0.337633 * uu - 0.698001 * vv).round();
          var b = (yy + 1.732446 * uu).round();
          final o = (y * w + x) * 4;
          out[o] = r.clamp(0, 255);
          out[o + 1] = g.clamp(0, 255);
          out[o + 2] = b.clamp(0, 255);
          out[o + 3] = 255;
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  InputImage? _toInputImage(CameraImage image) {
    final sensorOrientation = _controller?.description.sensorOrientation ?? 0;
    final rotation =
        InputImageRotationValue.fromRawValue(sensorOrientation) ??
            InputImageRotation.rotation0deg;
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: image.planes.first.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(TalkCameraGate.releaseLocalCamera, _releaseForGate)) {
      TalkCameraGate.releaseLocalCamera = null;
    }
    final c = _controller;
    _controller = null;
    _safeDispose(c);
    _segmenter.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final effect = ref.watch(cameraEffectProvider);
    final ctrl = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: const BrandedAppBar(
        title: 'Camera effects',
        subtitle: 'Backgrounds like Zoom & Meet',
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _error != null
                  ? Text(_error!,
                      style: const TextStyle(color: Colors.white70))
                  : (ctrl == null || !ctrl.value.isInitialized)
                      ? const CircularProgressIndicator()
                      : AspectRatio(
                          aspectRatio: 3 / 4,
                          child: (effect == CameraEffect.none ||
                                  _frameImage == null ||
                                  _maskImage == null)
                              ? CameraPreview(ctrl)
                              : CustomPaint(
                                  painter: _EffectPainter(
                                    frame: _frameImage!,
                                    mask: _maskImage!,
                                    effect: effect,
                                    bg: _bgImage,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                        ),
            ),
          ),
          _EffectPicker(
            selected: effect,
            onSelect: (e) =>
                ref.read(cameraEffectProvider.notifier).select(e),
          ),
        ],
      ),
    );
  }
}

/// Composites the person (frame masked by [mask]) over a background derived
/// from [effect]: gaussian-blurred frame, a brand image, or a dim frame.
class _EffectPainter extends CustomPainter {
  _EffectPainter({
    required this.frame,
    required this.mask,
    required this.effect,
    this.bg,
  });
  final ui.Image frame;
  final ui.Image mask;
  final CameraEffect effect;
  final ui.Image? bg;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    final srcFrame = Rect.fromLTWH(
        0, 0, frame.width.toDouble(), frame.height.toDouble());

    // ── Background layer ──
    switch (effect) {
      case CameraEffect.blur:
        final p = Paint()
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14);
        canvas.saveLayer(dst, p);
        canvas.drawImageRect(frame, srcFrame, dst, Paint());
        canvas.restore();
        break;
      case CameraEffect.officeBg:
      case CameraEffect.brandBg:
      case CameraEffect.warmBg:
        if (bg != null) {
          canvas.drawImageRect(
            bg!,
            Rect.fromLTWH(0, 0, bg!.width.toDouble(), bg!.height.toDouble()),
            dst,
            Paint(),
          );
        } else {
          canvas.drawRect(dst, Paint()..color = const Color(0xFF0D4A5C));
        }
        break;
      case CameraEffect.none:
        canvas.drawImageRect(frame, srcFrame, dst, Paint());
        return;
    }

    // ── Foreground (person) layer: frame ∧ mask (dstIn) ──
    canvas.saveLayer(dst, Paint());
    canvas.drawImageRect(frame, srcFrame, dst, Paint());
    final srcMask =
        Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble());
    canvas.drawImageRect(mask, srcMask, dst, Paint()..blendMode = BlendMode.dstIn);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EffectPainter old) =>
      old.frame != frame || old.mask != mask || old.effect != effect;
}

class _EffectPicker extends StatelessWidget {
  const _EffectPicker({required this.selected, required this.onSelect});
  final CameraEffect selected;
  final ValueChanged<CameraEffect> onSelect;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: CameraEffect.values.length,
          separatorBuilder: (_, __) => const SizedBox(width: 12),
          itemBuilder: (_, i) {
            final e = CameraEffect.values[i];
            final on = e == selected;
            return GestureDetector(
              onTap: () => onSelect(e),
              child: Column(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: on ? cs.secondary : Colors.white24,
                        width: on ? 2.5 : 1,
                      ),
                    ),
                    child: Icon(
                      switch (e) {
                        CameraEffect.none => Icons.block,
                        CameraEffect.blur => Icons.blur_on,
                        _ => Icons.image_outlined,
                      },
                      color: on ? cs.secondary : Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(e.label,
                      style: TextStyle(
                          fontSize: 11,
                          color: on ? cs.secondary : Colors.white70)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
