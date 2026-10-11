/// Màu + độ dày nét box ở ảnh Stage 2 (tô theo nguồn từng box). User chỉnh trong màn hình xem Stage 2
/// (Stage2ViewerScreen), lưu ở SharedPreferences; dùng cho cả overlay vector khi phóng to lẫn ảnh preview
/// PNG trong card (ImageUtils.drawWellBoxes qua [vizPalette] / [pngLineWidth]).
library stage2_style;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'image_utils.dart';

class Stage2Style {
  static const _prefsKey = 'stage2_style';

  /// Nguồn box: YOLO khớp lưới / nội suy từ lưới / YOLO lệch nên dùng vị trí lưới / sinh từ 3 box tay.
  static const kinds = ['detected', 'filled', 'moved', 'manual'];
  static const labels = {
    'detected': 'Detected by model',
    'filled': 'Filled from grid',
    'moved': 'Moved onto grid',
    'manual': 'From your 3 wells',
  };
  static const defaults = {
    'detected': 0xFF00B400,
    'filled': 0xFFFF8C00,
    'moved': 0xFFFFD700,
    'manual': 0xFF00BEFF,
  };

  /// Bảng màu chọn nhanh: tương phản cao trên nền agar xanh / vàng nhạt.
  static const palette = [
    0xFF00E676, 0xFF00B400, 0xFFC6FF00, 0xFFFFEA00, 0xFFFF8C00, //
    0xFFFF1744, 0xFFF500FF, 0xFF00E5FF, 0xFF2979FF, 0xFFFFFFFF, 0xFF000000,
  ];

  /// Độ dày nét (px màn hình ở overlay vector); ảnh PNG dùng [pngLineWidth].
  static const widths = {'Thin': 1.0, 'Medium': 2.0, 'Thick': 3.5};

  final Map<String, int> colors; // ARGB
  final double lineWidth;
  const Stage2Style(this.colors, this.lineWidth);

  static const standard = Stage2Style(defaults, 2.0);

  int color(String kind) => colors[kind] ?? defaults[kind]!;

  Stage2Style withColor(String kind, int argb) => Stage2Style({...colors, kind: argb}, lineWidth);
  Stage2Style withLineWidth(double w) => Stage2Style(colors, w);

  /// Nguồn của 1 box (map từ InferenceService / Stage2Meta.readBoxes).
  static String kindOf(Map<String, dynamic> box, {bool manualGeom = false}) => manualGeom
      ? 'manual'
      : (box['snapped'] == true ? 'moved' : (box['interpolated'] == true ? 'filled' : 'detected'));

  /// Mã màu Stage 2 (ImageUtils.stage2VizCodes) -> [r, g, b] cho drawWellBoxes (gửi được qua isolate).
  Map<int, List<int>> vizPalette() {
    List<int> rgb(String k) {
      final c = color(k);
      return [(c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF];
    }

    return {
      0: rgb('detected'),
      ImageUtils.stage2Interpolated: rgb('filled'),
      ImageUtils.stage2Snapped: rgb('moved'),
      ImageUtils.stage2Manual: rgb('manual'),
    };
  }

  /// Nét trên ảnh PNG ≤2048 px: 1 / 2 / 3 px.
  int get pngLineWidth => lineWidth <= 1.0 ? 1 : (lineWidth <= 2.0 ? 2 : 3);

  String get key => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {'colors': colors, 'line_width': lineWidth};

  static Future<Stage2Style> load() async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(_prefsKey);
      if (s == null) return standard;
      final j = jsonDecode(s) as Map<String, dynamic>;
      return Stage2Style(
        {...defaults, for (final e in (j['colors'] as Map).entries) e.key as String: (e.value as num).toInt()},
        (j['line_width'] as num?)?.toDouble() ?? standard.lineWidth,
      );
    } catch (_) {
      return standard;
    }
  }

  Future<void> save() async => (await SharedPreferences.getInstance()).setString(_prefsKey, key);
}
