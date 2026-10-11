/// Hình học tứ giác 4 góc plate + kiểm tra chất lượng — port của `acam/quality.py` (repo cha).
///
/// Dùng chung cho InferenceService (sắp góc trước khi warp, cảnh báo sau Stage 1/2) và màn hình
/// chỉnh góc tay (vẽ đa giác theo đúng thứ tự warp sẽ dùng, chặn tứ giác không hợp lệ).
/// Ngưỡng đọc từ PipelineConfig (mục "quality" của pipeline_config.json).
library plate_geometry;

import 'dart:math' as math;

import 'pipeline_config.dart';

typedef Corner = Map<String, double>; // {'x': .., 'y': ..}

/// Sắp 4 góc TL, TR, BR, BL: theo y (2 trên / 2 dưới) rồi theo x — như `acam.geometry.order_corners`.
List<Corner> orderCorners(List<Corner> corners) {
  final byY = List<Corner>.from(corners)..sort((a, b) => a['y']!.compareTo(b['y']!));
  final top = byY.sublist(0, 2)..sort((a, b) => a['x']!.compareTo(b['x']!));
  final bottom = byY.sublist(2)..sort((a, b) => a['x']!.compareTo(b['x']!));
  return [top[0], top[1], bottom[1], bottom[0]];
}

class QuadMetrics {
  final double aspect; // cạnh dài / cạnh ngắn (trung bình 2 cạnh đối)
  final double areaFrac; // diện tích / diện tích ảnh
  final double minAngle, maxAngle; // góc trong (độ)
  final bool convex;
  const QuadMetrics(this.aspect, this.areaFrac, this.minAngle, this.maxAngle, this.convex);

  Map<String, dynamic> toJson() => {
        'aspect': double.parse(aspect.toStringAsFixed(4)),
        'area_frac': double.parse(areaFrac.toStringAsFixed(4)),
        'min_angle': double.parse(minAngle.toStringAsFixed(2)),
        'max_angle': double.parse(maxAngle.toStringAsFixed(2)),
        'convex': convex,
      };
}

double _d(Corner a, Corner b) => math.sqrt(math.pow(a['x']! - b['x']!, 2) + math.pow(a['y']! - b['y']!, 2));

/// Như `acam.quality.quad_metrics`.
QuadMetrics quadMetrics(List<Corner> corners, double imgW, double imgH) {
  final q = orderCorners(corners);
  final cross = <double>[];
  final ang = <double>[];
  for (var i = 0; i < 4; i++) {
    final p = q[i], n = q[(i + 1) % 4], nn = q[(i + 2) % 4], prev = q[(i + 3) % 4];
    final e1x = n['x']! - p['x']!, e1y = n['y']! - p['y']!;
    final e2x = nn['x']! - n['x']!, e2y = nn['y']! - n['y']!;
    cross.add(e1x * e2y - e1y * e2x);
    final ax = prev['x']! - p['x']!, ay = prev['y']! - p['y']!;
    final bx = n['x']! - p['x']!, by = n['y']! - p['y']!;
    final den = math.max(math.sqrt(ax * ax + ay * ay) * math.sqrt(bx * bx + by * by), 1e-12);
    final c = ((ax * bx + ay * by) / den).clamp(-1.0, 1.0);
    ang.add(math.acos(c) * 180 / math.pi);
  }
  final convex = cross.every((c) => c > 0) || cross.every((c) => c < 0);
  var s = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4];
    s += a['x']! * b['y']! - a['y']! * b['x']!;
  }
  final w = (_d(q[0], q[1]) + _d(q[3], q[2])) / 2;
  final h = (_d(q[0], q[3]) + _d(q[1], q[2])) / 2;
  return QuadMetrics(math.max(w, h) / math.max(math.min(w, h), 1e-12), (s.abs() / 2) / (imgW * imgH),
      ang.reduce(math.min), ang.reduce(math.max), convex);
}

/// Mã cảnh báo Stage 1 — như `acam.quality.stage1_warnings`.
List<String> stage1Warnings(QuadMetrics m, PipelineConfig c) => [
      if (!m.convex) 'not_convex',
      if (m.minAngle < c.qcS1AngleMin || m.maxAngle > c.qcS1AngleMax) 'angle',
      if (m.areaFrac < c.qcS1MinAreaFrac) 'small_area',
      if (m.aspect < c.qcS1AspectMin || m.aspect > c.qcS1AspectMax) 'aspect',
    ];

/// Mã cảnh báo Stage 2 — như `acam.quality.stage2_warnings`. [pitch]: bước lưới (px ảnh warp).
/// Lưới thuần hình học (chế độ tay, không YOLO): truyền nInterpolated = nSnapped = 0 -> chỉ kiểm độ phân giải.
List<String> stage2Warnings(int nWells, int nInterpolated, int nSnapped, double pitch, PipelineConfig c) => [
      if (nInterpolated / nWells > c.qcS2MaxInterpFrac) 'many_interpolated',
      if (nSnapped / nWells > c.qcS2MaxSnapFrac) 'many_snapped',
      if (pitch < c.qcS2MinPitchPx) 'low_resolution',
    ];

/// Mô tả ngắn cho chip cảnh báo trên stage card.
String warningText(String code) => switch (code) {
      'not_convex' => 'corners cross each other',
      'angle' => 'corner angles look skewed',
      'small_area' => 'plate looks very small',
      'aspect' => 'unusual plate shape',
      'many_interpolated' => 'many wells not seen by the detector',
      'many_snapped' => 'many detections off the grid',
      'grid_shifted' => 'grid moved 1 well from your boxes',
      'low_resolution' => 'wells are only a few pixels wide, so classification may be less accurate '
          '(use a sharper photo or move closer to the plate)',
      _ => code,
    };
