/// 5-DOF grid transform (similarity transform around grid centroid).
///
/// Applies: translate-to-origin -> rotate(theta) -> uniform scale -> translate-back(+tx,+ty)
///          -> expand margin (delta from base GridParams.margin).
/// Does NOT support perspective / 4-corner drag (by design — grid stays rigid).
library grid_transform;

import 'dart:math';
import 'package:image/image.dart' as img;

import 'constants.dart';
import 'image_utils.dart';

/// Result of applying a GridTransform to a base grid.
class GridTransformResult {
  final List<Map<String, double>> positions; // 384 well centers
  final List<Map<String, double>> corners; // 4 grid corners (TL,TR,BR,BL)
  final double diameter; // estimated well diameter for boxes

  GridTransformResult({
    required this.positions,
    required this.corners,
    required this.diameter,
  });
}

class GridTransformUtils {
  /// Apply 5-DOF similarity transform to base grid (positions + corners).
  /// Fast — no ML inference, pure point math. Used for real-time manual preview.
  static GridTransformResult applyTransform(
    List<Map<String, double>> basePositions,
    List<Map<String, double>> baseCorners,
    GridTransform t,
  ) {
    // 1. centroid of base positions
    double sx = 0, sy = 0;
    for (final p in basePositions) {
      sx += p['x']!;
      sy += p['y']!;
    }
    final cx = sx / basePositions.length;
    final cy = sy / basePositions.length;

    final theta = t.rotation * pi / 180.0;
    final cosT = cos(theta);
    final sinT = sin(theta);
    final marginDelta = t.margin - GridParams.margin; // extra expansion
    final expand = 1.0 + 2.0 * marginDelta;

    // One transform returning both coords (avoids duplicate closure / unused vars).
    Map<String, double> tr(double x, double y) {
      final x0 = x - cx, y0 = y - cy;
      final rx = x0 * cosT - y0 * sinT;
      final ry = x0 * sinT + y0 * cosT;
      final sx = rx * t.scale, sy = ry * t.scale;
      final ox = sx + cx + t.translateX, oy = sy + cy + t.translateY;
      return {'x': (ox - cx) * expand + cx, 'y': (oy - cy) * expand + cy};
    }

    final positions = basePositions
        .map((p) => tr(p['x']!, p['y']!))
        .toList();
    final corners = baseCorners
        .map((p) => tr(p['x']!, p['y']!))
        .toList();

    // Recompute diameter from the (possibly transformed) corner box.
    final plateW = ((corners[1]['x']! - corners[0]['x']!).abs() +
            (corners[2]['x']! - corners[3]['x']!).abs()) /
        2;
    final plateH = ((corners[3]['y']! - corners[0]['y']!).abs() +
            (corners[2]['y']! - corners[1]['y']!).abs()) /
        2;
    final diameter = ImageUtils.estimateWellDiameter(
        plateW, plateH, GridParams.rows, GridParams.cols, t.margin);

    return GridTransformResult(
        positions: positions, corners: corners, diameter: diameter);
  }

  /// Draw grid overlay on a COPY of the image (boxes + corner dots).
  /// Used for preview only (results screen uses ImageUtils.drawWellBoxes with classes).
  static img.Image drawGridOverlay(
    img.Image src,
    List<Map<String, double>> positions,
    List<Map<String, double>> corners,
    double diameter, {
    bool drawBoxes = true,
    bool drawCorners = true,
  }) {
    final out = img.Image(width: src.width, height: src.height);
    // fast copy
    for (var y = 0; y < src.height; y++) {
      for (var x = 0; x < src.width; x++) {
        final p = src.getPixel(x, y);
        out.setPixelRgba(x, y, p.r, p.g, p.b, p.a);
      }
    }

    final radius = (diameter / 2).round();

    if (drawBoxes) {
      // green thin outline for each well
      for (final pos in positions) {
        final cx = pos['x']!.round();
        final cy = pos['y']!.round();
        _drawRect(out, cx - radius, cy - radius, cx + radius, cy + radius,
            r: 0, g: 220, b: 0);
      }
    }

    if (drawCorners) {
      // red filled dots for 4 grid corners
      for (final c in corners) {
        _drawFilledCircle(out, c['x']!.round(), c['y']!.round(), 8,
            r: 255, g: 40, b: 40);
      }
    }

    return out;
  }

  static void _drawRect(img.Image im, int x1, int y1, int x2, int y2,
      {required int r, required int g, required int b}) {
    x1 = x1.clamp(0, im.width - 1);
    x2 = x2.clamp(0, im.width - 1);
    y1 = y1.clamp(0, im.height - 1);
    y2 = y2.clamp(0, im.height - 1);
    for (var x = x1; x <= x2; x++) {
      im.setPixelRgba(x, y1, r, g, b, 255);
      im.setPixelRgba(x, y2, r, g, b, 255);
    }
    for (var y = y1; y <= y2; y++) {
      im.setPixelRgba(x1, y, r, g, b, 255);
      im.setPixelRgba(x2, y, r, g, b, 255);
    }
  }

  static void _drawFilledCircle(img.Image im, int cx, int cy, int radius,
      {required int r, required int g, required int b}) {
    final r2 = radius * radius;
    for (var dy = -radius; dy <= radius; dy++) {
      for (var dx = -radius; dx <= radius; dx++) {
        if (dx * dx + dy * dy <= r2) {
          final px = cx + dx;
          final py = cy + dy;
          if (px >= 0 && px < im.width && py >= 0 && py < im.height) {
            im.setPixelRgba(px, py, r, g, b, 255);
          }
        }
      }
    }
  }
}
