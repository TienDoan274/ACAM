/// Kết quả từng stage lưu trong DB (cột stage1_meta / stage2_meta, JSON) — v7.
///
/// Nhờ đó Stage 2 dùng lại góc + ảnh warp của Stage 1, Stage 3 dùng lại box của Stage 2 (không chạy
/// lại model), và kết quả chỉnh tay (góc / 3 box ①②③) được giữ qua các lần chạy lại.
/// Box Stage 2 nằm ở file JSON riêng (resultPath), không nhét vào DB: _loadData đọc mọi hàng.
library stage_meta;

import 'dart:convert';
import 'dart:io';

List<List<double>> _pts(dynamic v) => [
      for (final p in v as List) [for (final x in p as List) (x as num).toDouble()]
    ];

List<String> _strs(dynamic v) => [for (final x in (v as List?) ?? const []) x as String];

class Stage1Meta {
  static const sourceAuto = 'auto', sourceManual = 'manual';

  final String source;
  final List<int> imageSize; // [W, H] ảnh gốc sau img.decodeImage (JPEG đã xoay theo EXIF), như pipeline
  final List<List<double>> corners; // TL, TR, BR, BL (px ảnh gốc)
  final List<List<double>>? autoCorners; // góc model dự đoán (để "Reset to auto" / so sánh)
  final String warpedPath; // PNG plate đã warp, full-res
  final List<int> warpedSize; // [w, h]
  final Map<String, dynamic> qc; // quadMetrics(corners)
  final List<String> warn; // mã cảnh báo (chỉ tính cho auto)

  Stage1Meta({
    required this.source,
    required this.imageSize,
    required this.corners,
    this.autoCorners,
    required this.warpedPath,
    required this.warpedSize,
    this.qc = const {},
    this.warn = const [],
  });

  bool get isManual => source == sourceManual;
  List<Map<String, double>> get cornerMaps => [for (final c in corners) {'x': c[0], 'y': c[1]}];

  Map<String, dynamic> toJson() => {
        'v': 1,
        'source': source,
        'image_size': imageSize,
        'corners': corners,
        'auto_corners': autoCorners,
        'warped_path': warpedPath,
        'warped_size': warpedSize,
        'qc': qc,
        'warn': warn,
      };

  factory Stage1Meta.fromJson(Map<String, dynamic> j) => Stage1Meta(
        source: j['source'] as String,
        imageSize: [for (final x in j['image_size'] as List) (x as num).toInt()],
        corners: _pts(j['corners']),
        autoCorners: j['auto_corners'] == null ? null : _pts(j['auto_corners']),
        warpedPath: j['warped_path'] as String,
        warpedSize: [for (final x in j['warped_size'] as List) (x as num).toInt()],
        qc: (j['qc'] as Map?)?.cast<String, dynamic>() ?? const {},
        warn: _strs(j['warn']),
      );

  /// Chỉ giải mã (không đụng file) — dùng khi build UI.
  static Stage1Meta? parse(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return Stage1Meta.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// null nếu chưa có / hỏng / ảnh warp đã bị xoá (hàng cũ trước v7 -> chạy lại Stage 1 tự động).
  static Stage1Meta? tryParse(String? s) {
    final m = parse(s);
    return m != null && File(m.warpedPath).existsSync() ? m : null;
  }
}

/// Input chế độ tay Stage 2: 3 box ① đầu-trái, ② đầu-phải cùng hàng, ③ cuối-trái cùng cột (px ảnh warp)
/// + số well ①→② (n12) và ①→③ (n13), kể cả 2 đầu. refine: tinh chỉnh bằng YOLO (chỉ lưới 16x24).
class ManualWells {
  final List<List<double>> anchors;
  final int n12, n13;
  final bool refine;
  const ManualWells(this.anchors, this.n12, this.n13, this.refine);

  Map<String, dynamic> toJson() => {'anchors': anchors, 'n12': n12, 'n13': n13, 'refine': refine};

  factory ManualWells.fromJson(Map<String, dynamic> j) =>
      ManualWells(_pts(j['anchors']), (j['n12'] as num).toInt(), (j['n13'] as num).toInt(), j['refine'] as bool? ?? true);
}

class Stage2Meta {
  static const sourceAuto = 'auto', sourceHybrid = 'manual_hybrid', sourceGeom = 'manual_geom';

  final String source;
  final String resultPath; // JSON: boxes, conf, interpolated, snapped
  final int rows, cols;
  final ManualWells? manual;
  final Map<String, dynamic> stats; // n_det, n_interpolated, n_snapped, n_dropped, shift, pitch
  final List<String> warn;

  Stage2Meta({
    required this.source,
    required this.resultPath,
    required this.rows,
    required this.cols,
    this.manual,
    this.stats = const {},
    this.warn = const [],
  });

  bool get isManual => source != sourceAuto;
  int get nWells => rows * cols;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'source': source,
        'result_path': resultPath,
        'rows': rows,
        'cols': cols,
        'n_wells': nWells,
        'manual': manual?.toJson(),
        'stats': stats,
        'warn': warn,
      };

  factory Stage2Meta.fromJson(Map<String, dynamic> j) => Stage2Meta(
        source: j['source'] as String,
        resultPath: j['result_path'] as String,
        rows: (j['rows'] as num).toInt(),
        cols: (j['cols'] as num).toInt(),
        manual: j['manual'] == null ? null : ManualWells.fromJson((j['manual'] as Map).cast<String, dynamic>()),
        stats: (j['stats'] as Map?)?.cast<String, dynamic>() ?? const {},
        warn: _strs(j['warn']),
      );

  static Stage2Meta? parse(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return Stage2Meta.fromJson(jsonDecode(s) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Stage2Meta? tryParse(String? s) {
    final m = parse(s);
    return m != null && File(m.resultPath).existsSync() ? m : null;
  }

  /// Ghi / đọc file box: danh sách map x1,y1,x2,y2,conf,interpolated,snapped (như InferenceService).
  static Future<void> writeBoxes(String path, List<Map<String, dynamic>> boxes, int rows, int cols, List<int> warpedSize) =>
      File(path).writeAsString(jsonEncode({
        'v': 1,
        'warped_size': warpedSize,
        'rows': rows,
        'cols': cols,
        'boxes': [for (final b in boxes) [b['x1'], b['y1'], b['x2'], b['y2']]],
        'conf': [for (final b in boxes) b['conf']],
        'interpolated': [for (final b in boxes) b['interpolated'] == true],
        'snapped': [for (final b in boxes) b['snapped'] == true],
      }));

  Future<List<Map<String, dynamic>>> readBoxes() async {
    final j = jsonDecode(await File(resultPath).readAsString()) as Map<String, dynamic>;
    final boxes = _pts(j['boxes']);
    final conf = j['conf'] as List;
    final interp = j['interpolated'] as List;
    final snapped = j['snapped'] as List;
    return [
      for (var i = 0; i < boxes.length; i++)
        {
          'x1': boxes[i][0],
          'y1': boxes[i][1],
          'x2': boxes[i][2],
          'y2': boxes[i][3],
          'conf': (conf[i] as num).toDouble(),
          'interpolated': interp[i] as bool,
          'snapped': snapped[i] as bool,
        }
    ];
  }
}
