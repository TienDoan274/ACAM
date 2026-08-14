/// CustomPainter for 384-well grid overlay — 60fps, no JPG encoding.
///
/// Maps image-space coordinates to screen-space using the same
/// BoxFit.contain logic that Image.file uses:
///   imageScale = min(screenW / imageW, screenH / imageH)
///   offsetX   = (screenW - imageW * imageScale) / 2
///   offsetY   = (screenH - imageH * imageScale) / 2
///   screenPos  = imagePos * imageScale + offset
library grid_overlay_painter;

import 'package:flutter/material.dart';

class GridOverlayPainter extends CustomPainter {
  final List<Map<String, double>> positions; // 384 well centers (image coords)
  final List<Map<String, double>> corners; // 4 grid corners (image coords)
  final double diameter; // well diameter in image pixels
  final double imageWidth;
  final double imageHeight;

  GridOverlayPainter({
    required this.positions,
    required this.corners,
    required this.diameter,
    required this.imageWidth,
    required this.imageHeight,
  });

  /// Convert image-space (x,y) to screen-space Offset.
  Offset _toScreen(double imgX, double imgY, double scale, Offset offset) {
    return Offset(imgX * scale + offset.dx, imgY * scale + offset.dy);
  }

  /// Compute BoxFit.contain transform: scale + offset.
  (double, Offset) _containTransform(Size screenSize) {
    final sx = screenSize.width / imageWidth;
    final sy = screenSize.height / imageHeight;
    final s = sx < sy ? sx : sy; // min
    final ox = (screenSize.width - imageWidth * s) / 2;
    final oy = (screenSize.height - imageHeight * s) / 2;
    return (s, Offset(ox, oy));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (positions.isEmpty) {
      print('[Painter] positions.isEmpty, skipping paint');
      return;
    }

    final (imgScale, imgOffset) = _containTransform(size);
    print('[Painter] painting ${positions.length} positions, scale=$imgScale offset=$imgOffset size=$size');

    // --- Draw well boxes (green stroke) ---
    final boxPaint = Paint()
      ..color = const Color(0xCC00DC00) // semi-transparent green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final radiusImg = diameter / 2;
    final radiusScreen = radiusImg * imgScale;

    var drawn = 0;
    for (final pos in positions) {
      final x = pos['x']!;
      final y = pos['y']!;
      final center = _toScreen(x, y, imgScale, imgOffset);
      final rect = Rect.fromCircle(center: center, radius: radiusScreen);
      canvas.drawRect(rect, boxPaint);
      drawn++;
    }
    print('[Painter] drew $drawn boxes');

    // --- Draw corner dots (red filled) ---
    if (corners.isNotEmpty) {
      final cornerPaint = Paint()
        ..color = const Color(0xFFFF2828)
        ..style = PaintingStyle.fill;

      final cornerRadius = (imgScale * 6).clamp(4.0, 12.0);

      for (final c in corners) {
        final center = _toScreen(c['x']!, c['y']!, imgScale, imgOffset);
        canvas.drawCircle(center, cornerRadius, cornerPaint);
      }

      // --- Draw corner connecting lines (red dashed) ---
      final linePaint = Paint()
        ..color = const Color(0x88FF2828)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;

      if (corners.length == 4) {
        final tl = _toScreen(corners[0]['x']!, corners[0]['y']!, imgScale, imgOffset);
        final tr = _toScreen(corners[1]['x']!, corners[1]['y']!, imgScale, imgOffset);
        final br = _toScreen(corners[2]['x']!, corners[2]['y']!, imgScale, imgOffset);
        final bl = _toScreen(corners[3]['x']!, corners[3]['y']!, imgScale, imgOffset);
        canvas.drawLine(tl, tr, linePaint);
        canvas.drawLine(tr, br, linePaint);
        canvas.drawLine(br, bl, linePaint);
        canvas.drawLine(bl, tl, linePaint);
      }
    }
  }

  @override
  bool shouldRepaint(GridOverlayPainter oldDelegate) {
    return oldDelegate.positions != positions ||
        oldDelegate.corners != corners ||
        oldDelegate.diameter != diameter ||
        oldDelegate.imageWidth != imageWidth ||
        oldDelegate.imageHeight != imageHeight;
  }
}
