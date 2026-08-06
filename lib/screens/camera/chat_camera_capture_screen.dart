// SPDX-License-Identifier: AGPL-3.0
//
// Chat camera capture — full-screen CameraController flow borrowed from
// interact-maps camera_screen (safe dispose, lifecycle pause/resume, flip,
// jpeg high preset). Returns the captured file path via Navigator.pop.
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../services/talk_camera_gate.dart';
import '../../widgets/branded_app_bar.dart';

/// Full-screen capture for chat attachments. Pop with a [File] path string,
/// or null if cancelled.
class ChatCameraCaptureScreen extends StatefulWidget {
  const ChatCameraCaptureScreen({super.key, this.preferRear = true});

  final bool preferRear;

  @override
  State<ChatCameraCaptureScreen> createState() =>
      _ChatCameraCaptureScreenState();
}

class _ChatCameraCaptureScreenState extends State<ChatCameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _ctrl;
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  bool _loading = true;
  String? _error;
  bool _capturing = false;
  FlashMode _flash = FlashMode.off;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCameras();
  }

  Future<void> _releaseForGate() async {
    final c = _ctrl;
    _ctrl = null;
    await _safeDispose(c);
    if (mounted) setState(() => _loading = true);
  }

  Future<void> _safeDispose(CameraController? c) async {
    if (c == null) return;
    try {
      await c.dispose();
    } catch (_) {
      // Camerax: releaseFlutterSurfaceTexture before preview init — ignore.
    }
  }

  Future<void> _initCameras() async {
    try {
      // Release any other Talk camera holder (effects / prior capture), then
      // re-register ourselves as the exclusive owner.
      await TalkCameraGate.releaseIfHeld();
      TalkCameraGate.releaseLocalCamera = _releaseForGate;
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() {
          _error = 'No camera available';
          _loading = false;
        });
        return;
      }
      _cameras = cameras;
      if (widget.preferRear) {
        final rear = cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
        _cameraIndex = rear >= 0 ? rear : 0;
      } else {
        final front = cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
        );
        _cameraIndex = front >= 0 ? front : 0;
      }
      await _openCamera(_cameraIndex);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Camera init failed: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _openCamera(int index) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final previous = _ctrl;
    _ctrl = null;
    await _safeDispose(previous);
    final cam = _cameras[index];
    final ctrl = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await ctrl.initialize();
      try {
        await ctrl.setFlashMode(_flash);
      } catch (_) {/* device may not support flash */}
      if (!mounted) {
        await _safeDispose(ctrl);
        return;
      }
      setState(() {
        _ctrl = ctrl;
        _loading = false;
      });
    } catch (e) {
      await _safeDispose(ctrl);
      if (!mounted) return;
      setState(() {
        _error = 'Cannot open camera: $e';
        _loading = false;
      });
    }
  }

  Future<void> _cycleCamera() async {
    if (_cameras.length < 2 || _capturing) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _openCamera(_cameraIndex);
  }

  Future<void> _toggleFlash() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    final next = _flash == FlashMode.off ? FlashMode.auto : FlashMode.off;
    try {
      await ctrl.setFlashMode(next);
      setState(() => _flash = next);
    } catch (_) {/* ignore */}
  }

  Future<void> _takePicture() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final file = await ctrl.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(file.path);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Capture failed: $e')),
        );
        setState(() => _capturing = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      final c = _ctrl;
      _ctrl = null;
      _safeDispose(c);
    } else if (state == AppLifecycleState.resumed) {
      if (_cameras.isNotEmpty) _openCamera(_cameraIndex);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(TalkCameraGate.releaseLocalCamera, _releaseForGate)) {
      TalkCameraGate.releaseLocalCamera = null;
    }
    final c = _ctrl;
    _ctrl = null;
    c?.dispose().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: BrandedAppBar(
        title: 'Camera',
        subtitle: 'Capture for chat',
        actions: [
          if (_cameras.length > 1)
            IconButton(
              tooltip: 'Flip camera',
              onPressed: _loading ? null : _cycleCamera,
              icon: const Icon(Icons.cameraswitch),
            ),
          IconButton(
            tooltip: 'Flash',
            onPressed: _loading ? null : _toggleFlash,
            icon: Icon(
              _flash == FlashMode.off ? Icons.flash_off : Icons.flash_auto,
            ),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => _openCamera(_cameraIndex),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            )
          else if (_ctrl != null && _ctrl!.value.isInitialized)
            SizedBox.expand(child: CameraPreview(_ctrl!)),
          if (!_loading && _error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 32,
              child: Center(
                child: Semantics(
                  button: true,
                  label: 'Take photo',
                  child: Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _capturing ? null : _takePicture,
                      child: SizedBox(
                        width: 72,
                        height: 72,
                        child: _capturing
                            ? const Padding(
                                padding: EdgeInsets.all(20),
                                child: CircularProgressIndicator(strokeWidth: 3),
                              )
                            : const Icon(Icons.circle,
                                size: 64, color: Colors.black87),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
