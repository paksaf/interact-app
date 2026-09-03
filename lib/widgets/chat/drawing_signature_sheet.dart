// SPDX-License-Identifier: AGPL-3.0
//
// Drawing / signature canvas → PNG bytes for media/upload.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

class DrawingSignatureSheet extends StatefulWidget {
  const DrawingSignatureSheet({super.key});

  /// Returns a PNG [File] or null if cancelled.
  static Future<File?> show(BuildContext context) {
    return showModalBottomSheet<File?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const DrawingSignatureSheet(),
    );
  }

  @override
  State<DrawingSignatureSheet> createState() => _DrawingSignatureSheetState();
}

class _DrawingSignatureSheetState extends State<DrawingSignatureSheet> {
  final _strokes = <List<Offset>>[];
  List<Offset>? _current;
  final _repaintKey = GlobalKey();

  void _clear() {
    setState(() {
      _strokes.clear();
      _current = null;
    });
  }

  Future<File?> _export() async {
    if (_strokes.isEmpty && _current == null) return null;
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return null;
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/draw_${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await file.writeAsBytes(byteData.buffer.asUint8List());
      return file;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Draw or sign',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(onPressed: _clear, child: const Text('Clear')),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: RepaintBoundary(
              key: _repaintKey,
              child: Container(
                height: 220,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GestureDetector(
                    onPanStart: (d) {
                      setState(() {
                        _current = [d.localPosition];
                        _strokes.add(_current!);
                      });
                    },
                    onPanUpdate: (d) {
                      setState(() => _current?.add(d.localPosition));
                    },
                    onPanEnd: (_) => _current = null,
                    child: CustomPaint(
                      painter: _StrokePainter(_strokes),
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      final file = await _export();
                      if (!context.mounted) return;
                      Navigator.pop(context, file);
                    },
                    child: const Text('Send drawing'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0D4A5C)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (var i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) =>
      oldDelegate.strokes != strokes;
}
