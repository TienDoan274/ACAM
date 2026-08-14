/// Image processing utilities cho microplate analysis
library image_utils;

import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

/// Image preprocessing utilities
class ImageUtils {
  /// Bilinear interpolation cho grid well positions
  static List<Map<String, double>> bilinearInterpolateGrid(
    List<Map<String, double>> corners,
    int rows,
    int cols,
  ) {
    // corners: [TL, TR, BR, BL]
    final xTL = corners[0]['x']!;
    final yTL = corners[0]['y']!;
    final xTR = corners[1]['x']!;
    final yTR = corners[1]['y']!;
    final xBR = corners[2]['x']!;
    final yBR = corners[2]['y']!;
    final xBL = corners[3]['x']!;
    final yBL = corners[3]['y']!;

    final positions = <Map<String, double>>[];

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final u = c / (cols - 1); // 0..1 horizontal
        final v = r / (rows - 1); // 0..1 vertical

        // Bilinear interpolation
        final x = (1 - u) * (1 - v) * xTL +
            u * (1 - v) * xTR +
            (1 - u) * v * xBL +
            u * v * xBR;

        final y = (1 - u) * (1 - v) * yTL +
            u * (1 - v) * yTR +
            (1 - u) * v * yBL +
            u * v * yBR;

        positions.add({'x': x, 'y': y});
      }
    }

    return positions;
  }

  /// Estimate well diameter từ plate size
  static double estimateWellDiameter(double plateW, double plateH, int rows, int cols, double margin) {
    final spacingX = plateW * (1 - 2 * margin) / (cols - 1);
    final spacingY = plateH * (1 - 2 * margin) / (rows - 1);
    final avgSpacing = (spacingX + spacingY) / 2;

    // Wells occupy ~85% of spacing
    return avgSpacing * 0.85;
  }

  /// Generate bounding boxes từ positions
  static List<Map<String, dynamic>> generateBoxesFromPositions(
    List<Map<String, double>> positions,
    double diameter,
  ) {
    final boxes = <Map<String, dynamic>>[];
    final radius = diameter / 2;

    for (final pos in positions) {
      final cx = pos['x']!;
      final cy = pos['y']!;

      boxes.add({
        'x1': cx - radius,
        'y1': cy - radius,
        'x2': cx + radius,
        'y2': cy + radius,
        'conf': 1.0, // Deterministic
      });
    }

    return boxes;
  }

  /// Draw well boxes on image with color coding
  static img.Image drawWellBoxes(
    img.Image image,
    List<Map<String, dynamic>> boxes,
    List<int> classes, // [0, 1, 2] for Growth, NoGrowth, NoAgar
  ) {
    final annotated = img.Image(
      width: image.width,
      height: image.height,
    );

    // Copy original image
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        annotated.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, pixel.a);
      }
    }

    // Draw boxes with class colors
    for (var i = 0; i < boxes.length && i < classes.length; i++) {
      final box = boxes[i];
      final cls = classes[i];

      // Color based on class
      final color = _getClassColor(cls);

      // Draw rectangle
      final x1 = box['x1']!.round().clamp(0, image.width - 1);
      final y1 = box['y1']!.round().clamp(0, image.height - 1);
      final x2 = box['x2']!.round().clamp(0, image.width - 1);
      final y2 = box['y2']!.round().clamp(0, image.height - 1);

      // Draw rectangle outline
      for (var x = x1; x <= x2; x++) {
        annotated.setPixelRgba(x, y1, color['r']!, color['g']!, color['b']!, 255);
        annotated.setPixelRgba(x, y2, color['r']!, color['g']!, color['b']!, 255);
      }
      for (var y = y1; y <= y2; y++) {
        annotated.setPixelRgba(x1, y, color['r']!, color['g']!, color['b']!, 255);
        annotated.setPixelRgba(x2, y, color['r']!, color['g']!, color['b']!, 255);
      }

      // Draw center dot
      final cx = ((x1 + x2) / 2).round();
      final cy = ((y1 + y2) / 2).round();
      if (cx >= 0 && cx < image.width && cy >= 0 && cy < image.height) {
        final dotSize = 2;
        for (var dy = -dotSize; dy <= dotSize; dy++) {
          for (var dx = -dotSize; dx <= dotSize; dx++) {
            final px = cx + dx;
            final py = cy + dy;
            if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
              annotated.setPixelRgba(px, py, color['r']!, color['g']!, color['b']!, 255);
            }
          }
        }
      }
    }

    return annotated;
  }

  /// Helper: get color components from class (returns map with 'r','g','b')
  static Map<String, int> _getClassColor(int cls) {
    switch (cls) {
      case 0: // Growth
        return {'r': 0, 'g': 180, 'b': 0};  // Green
      case 1: // NoGrowth
        return {'r': 0, 'g': 0, 'b': 220};  // Red
      case 2: // NoAgar
        return {'r': 200, 'g': 0, 'b': 200}; // Purple
      default:
        return {'r': 128, 'g': 128, 'b': 128}; // Gray
    }
  }

  /// Draw the 4 detected plate corners + outline on an image (Stage 1 visualization)
  static img.Image drawCorners(
    img.Image image,
    List<Map<String, double>> corners, {
    int r = 255,
    int g = 215,
    int b = 0, // gold
  }) {
    final annotated = img.Image(width: image.width, height: image.height);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final p = image.getPixel(x, y);
        annotated.setPixelRgba(x, y, p.r, p.g, p.b, p.a);
      }
    }

    // Draw polygon outline connecting corners (TL -> TR -> BR -> BL -> TL)
    if (corners.length >= 4) {
      for (var i = 0; i < 4; i++) {
        final a = corners[i];
        final b2 = corners[(i + 1) % 4];
        _drawLine(annotated, a['x']!, a['y']!, b2['x']!, b2['y']!, r, g, b);
      }
    }

    // Draw filled circles at each corner
    const radius = 14;
    for (final c in corners) {
      final cx = c['x']!.round();
      final cy = c['y']!.round();
      for (var dy = -radius; dy <= radius; dy++) {
        for (var dx = -radius; dx <= radius; dx++) {
          if (dx * dx + dy * dy <= radius * radius) {
            final px = cx + dx;
            final py = cy + dy;
            if (px >= 0 && px < image.width && py >= 0 && py < image.height) {
              annotated.setPixelRgba(px, py, r, g, b, 255);
            }
          }
        }
      }
    }

    return annotated;
  }

  /// Bresenham line draw helper
  static void _drawLine(
    img.Image image,
    double x1d,
    double y1d,
    double x2d,
    double y2d,
    int r,
    int g,
    int b,
  ) {
    int x1 = x1d.round();
    int y1 = y1d.round();
    final x2 = x2d.round();
    final y2 = y2d.round();
    final dx = (x2 - x1).abs();
    final dy = (y2 - y1).abs();
    final sx = x1 < x2 ? 1 : -1;
    final sy = y1 < y2 ? 1 : -1;
    var err = dx - dy;
    while (true) {
      if (x1 >= 0 && x1 < image.width && y1 >= 0 && y1 < image.height) {
        image.setPixelRgba(x1, y1, r, g, b, 255);
      }
      if (x1 == x2 && y1 == y2) break;
      final e2 = 2 * err;
      if (e2 > -dy) {
        err -= dy;
        x1 += sx;
      }
      if (e2 < dx) {
        err += dx;
        y1 += sy;
      }
    }
  }

  /// Save image to app documents directory
  static Future<File> saveImage(Uint8List bytes, String filename) async {
    final directory = await getApplicationDocumentsDirectory();
    final filePath = path.join(directory.path, filename);
    final file = File(filePath);
    await file.writeAsBytes(bytes);
    return file;
  }

  /// Get temporary file path
  static Future<String> getTempFilePath(String filename) async {
    final tempDir = await getTemporaryDirectory();
    return path.join(tempDir.path, filename);
  }
}
