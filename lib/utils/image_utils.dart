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

  /// Draw well boxes on image with color coding.
  ///
  /// If [confidences] is provided (index-aligned with boxes), each box gets a
  /// small "0.xx" confidence label drawn at its top-left corner.
  /// [palette]: mã -> [r, g, b] thay màu mặc định (Stage 2: màu user chọn, Stage2Style);
  /// [lineWidth]: độ dày viền (px), vẽ vào phía trong box.
  static img.Image drawWellBoxes(
    img.Image image,
    List<Map<String, dynamic>> boxes,
    List<int> classes, { // [0, 1, 2] for Growth, NoGrowth, NoAgar
    Map<int, double>? confidences,
    Map<int, List<int>>? palette,
    int lineWidth = 1,
  }) {
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
      final custom = palette?[cls];
      final color = custom != null ? {'r': custom[0], 'g': custom[1], 'b': custom[2]} : _getClassColor(cls);

      // Draw rectangle
      final x1 = box['x1']!.round().clamp(0, image.width - 1);
      final y1 = box['y1']!.round().clamp(0, image.height - 1);
      final x2 = box['x2']!.round().clamp(0, image.width - 1);
      final y2 = box['y2']!.round().clamp(0, image.height - 1);

      // Draw rectangle outline (lineWidth px, inward)
      for (var t = 0; t < lineWidth && x1 + t <= x2 - t && y1 + t <= y2 - t; t++) {
        final ax = x1 + t, ay = y1 + t, bx = x2 - t, by = y2 - t;
        for (var x = ax; x <= bx; x++) {
          annotated.setPixelRgba(x, ay, color['r']!, color['g']!, color['b']!, 255);
          annotated.setPixelRgba(x, by, color['r']!, color['g']!, color['b']!, 255);
        }
        for (var y = ay; y <= by; y++) {
          annotated.setPixelRgba(ax, y, color['r']!, color['g']!, color['b']!, 255);
          annotated.setPixelRgba(bx, y, color['r']!, color['g']!, color['b']!, 255);
        }
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

      // Confidence label (drawn last so it stays on top)
      if (confidences != null) {
        final conf = confidences[i];
        if (conf != null) {
          _drawConfLabel(
              annotated, x1, y1, conf.toStringAsFixed(2),
              cr: color['r']!, cg: color['g']!, cb: color['b']!);
        }
      }
    }

    return annotated;
  }

  /// Draw a tiny solid badge with the confidence text at the box's top-left.
  /// Pixel-drawn text keeps it readable when zoomed without a bitmap font.
  static void _drawConfLabel(
    img.Image image,
    int bx,
    int by,
    String text, {
    required int cr,
    required int cg,
    required int cb,
  }) {
    // 3x5 digit/point glyphs packed as rows of bits (MSB left).
    const glyphs = <String, List<int>>{
      '0': [7, 5, 5, 5, 7],
      '1': [2, 6, 2, 2, 7],
      '2': [7, 1, 7, 4, 7],
      '3': [7, 1, 7, 1, 7],
      '4': [5, 5, 7, 1, 1],
      '5': [7, 4, 7, 1, 7],
      '6': [7, 4, 7, 5, 7],
      '7': [7, 1, 2, 2, 2],
      '8': [7, 5, 7, 5, 7],
      '9': [7, 5, 7, 1, 7],
      '.': [0, 0, 0, 0, 2],
    };

    const glyphW = 3, glyphH = 5, spacing = 1;
    final totalW = text.length * (glyphW + spacing) - spacing;
    final h = glyphH;

    // Badge background block (black, slightly padded) so it reads on any plate
    var ox = bx.clamp(0, image.width - 1);
    var oy = (by - h - 4).clamp(0, image.height - 1);
    for (var y = oy; y < oy + h + 2; y++) {
      for (var x = ox; x < ox + totalW + 2; x++) {
        if (x >= 0 && x < image.width && y >= 0 && y < image.height) {
          image.setPixelRgba(x, y, 0, 0, 0, 255);
        }
      }
    }

    // Glyph pixels in white-ish tint of the class color
    var px = ox + 1;
    for (final ch in text.split('')) {
      final g = glyphs[ch];
      if (g == null) {
        px += glyphW + spacing;
        continue;
      }
      for (var row = 0; row < glyphH; row++) {
        final bits = g[row];
        for (var col = 0; col < glyphW; col++) {
          if ((bits >> (glyphW - 1 - col)) & 1 == 1) {
            final x = px + col;
            final y = oy + 1 + row;
            if (x >= 0 && x < image.width && y >= 0 && y < image.height) {
              // Blend toward white so any class hue stays readable
              final r = ((cr + 255) / 2).round().clamp(0, 255);
              final gg = ((cg + 255) / 2).round().clamp(0, 255);
              final b = ((cb + 255) / 2).round().clamp(0, 255);
              image.setPixelRgba(x, y, r, gg, b, 255);
            }
          }
        }
      }
      px += glyphW + spacing;
    }
  }

  /// Mã màu preview Stage 2 (truyền như class vào [drawWellBoxes]); 0 = box YOLO (xanh lá).
  static const int stage2Interpolated = 10, stage2Snapped = 11, stage2Manual = 12;

  /// Mã màu Stage 2 cho từng box theo nguồn của nó.
  static List<int> stage2VizCodes(List<Map<String, dynamic>> boxes, {bool manualGeom = false}) => [
        for (final b in boxes)
          manualGeom
              ? stage2Manual
              : (b['snapped'] == true ? stage2Snapped : (b['interpolated'] == true ? stage2Interpolated : 0))
      ];

  /// Helper: get color components from class (returns map with 'r','g','b')
  static Map<String, int> _getClassColor(int cls) {
    switch (cls) {
      case 0: // Growth
        return {'r': 0, 'g': 180, 'b': 0};  // Green
      case 1: // NoGrowth
        return {'r': 0, 'g': 0, 'b': 220};  // Red
      case 2: // NoAgar
        return {'r': 200, 'g': 0, 'b': 200}; // Purple
      // Mã chỉ dùng cho ảnh preview Stage 2 (nguồn của từng box, chưa phân loại)
      case stage2Interpolated: // không có detection YOLO, vị trí từ lưới
        return {'r': 255, 'g': 140, 'b': 0}; // Orange
      case stage2Snapped: // có detection nhưng lệch lưới -> dùng vị trí lưới
        return {'r': 255, 'g': 215, 'b': 0}; // Yellow
      case stage2Manual: // lưới sinh thuần hình học từ 3 box tay
        return {'r': 0, 'g': 190, 'b': 255}; // Sky blue
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
