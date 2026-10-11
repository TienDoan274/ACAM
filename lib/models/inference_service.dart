/// Inference service - FULL PIPELINE với ONNX Runtime, port 1-1 của `acam/inference.py` (repo cha).
/// Mọi hằng số tiền xử lý / hậu xử lý đọc từ `assets/models/pipeline_config.json` (PipelineConfig),
/// mọi phép ảnh dùng OpenCV (dartcv4) như `cv2` phía Python để kết quả khớp nhau.
/// - Stage 1: EfficientNet-B3 hồi quy 4 góc plate (gray 896x896) -> warp plate (margin 8%, RGB, viền đen)
/// - Stage 2: YOLOv8n 1 kênh trên plate đã warp (letterbox 640, pad 114) -> NMS -> WellGrid: ĐÚNG 384 well
/// - Stage 3: phân loại Growth / NoGrowth / NoAgar trên crop 64x64 (bbox nới 5%, INTER_AREA);
///            dự đoán = argmax(xác suất * class_prob_weights)
library inference_service;

import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:dartcv4/dartcv.dart' as cv;

import '../utils/constants.dart';
import '../utils/image_frame.dart';
import '../utils/image_utils.dart';
import '../utils/grid_transform.dart';
import '../utils/pipeline_config.dart';
import '../utils/plate_geometry.dart';
import '../utils/well_grid.dart';
import 'stage_meta.dart';

/// Làm tròn .5 lên — giống `round_half_up` của acam/geometry.py (kể cả số âm).
int _rhu(double x) => (x + 0.5).floor();

/// img.Image -> cv.Mat CV_8UC3 (thứ tự kênh RGB). Ảnh có alpha / palette / 16-bit được đổi về RGB uint8.
cv.Mat _toMatRgb(img.Image image) {
  final im = (image.numChannels == 3 && image.format == img.Format.uint8 && !image.hasPalette)
      ? image
      : image.convert(format: img.Format.uint8, numChannels: 3);
  return cv.Mat.fromList(im.height, im.width, cv.MatType.CV_8UC3, im.getBytes(order: img.ChannelOrder.rgb));
}

/// cv.Mat CV_8UC3 (RGB) -> img.Image 3 kênh.
img.Image _fromMatRgb(cv.Mat m) => img.Image.fromBytes(
    width: m.cols,
    height: m.rows,
    bytes: Uint8List.fromList(m.data).buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb);

/// Kết quả Stage 3: class id + xác suất từng class (null với fallback độ sáng) + gain chuẩn hoá độ sáng theo plate
/// (1 = ảnh bình thường, > 1 = ảnh tối đã được làm sáng trước khi phân loại).
class Stage3Output {
  final List<int> classes;
  final List<List<double>>? probs;
  final double gain;
  Stage3Output(this.classes, this.probs, {this.gain = 1.0});

  /// Độ tin cậy của class đã chọn (xác suất lớn nhất), 1.0 nếu không có xác suất.
  List<double> get confidences =>
      probs == null ? List.filled(classes.length, 1.0) : [for (var i = 0; i < classes.length; i++) probs![i][classes[i]]];
}

/// Isolate job: pure-Dart JPEG/PNG decode. A full-res photo takes seconds on
/// the UI isolate, which starves input handling during pipeline runs.
img.Image? _decodeImageJob(Uint8List bytes) => img.decodeImage(bytes);

/// Isolate job: PNG encode (full-plate encodes take seconds).
Uint8List _encodePngJob(img.Image image) =>
    Uint8List.fromList(img.encodePng(image));

/// Detection result (stage 1 + 2) — used by preview screen before classification.
class DetectionResult {
  final List<Map<String, double>> corners; // TL,TR,BR,BL (pixel coords)
  final List<Map<String, double>> positions; // 384 well centers
  final double diameter;
  final DetectionMode mode;
  final double detectionTimeMs;

  DetectionResult({
    required this.corners,
    required this.positions,
    required this.diameter,
    required this.mode,
    required this.detectionTimeMs,
  });
}

/// Pipeline result
class PipelineResult {
  final String imagePath;
  final String annotatedPath;
  final List<Map<String, dynamic>> boxes;
  final List<int> classes;
  final Map<String, int> counts;
  final double processingTimeMs;
  final List<Map<String, double>> corners;
  final DetectionMode mode;

  PipelineResult({
    required this.imagePath,
    required this.annotatedPath,
    required this.boxes,
    required this.classes,
    required this.counts,
    required this.processingTimeMs,
    required this.corners,
    required this.mode,
  });

  /// Số well: số box nếu có; kết quả mở lại từ History không lưu box -> tổng số đếm 3 class.
  int get totalWells => boxes.isNotEmpty
      ? boxes.length
      : (counts['growth'] ?? 0) + (counts['no_growth'] ?? 0) + (counts['no_agar'] ?? 0);

  String get countsDisplay =>
      'Total: $totalWells | Growth: ${counts['growth']} | '
      'NoGrowth: ${counts['no_growth']} | NoAgar: ${counts['no_agar']}';

  int getCount(String className) => counts[className] ?? 0;
}

/// Inference service cho microplate pipeline (singleton)
class InferenceService {
  // Stage 1 (always loaded) — grid corners
  OrtSession? _stage1Session;
  List<String>? _s1In;
  List<String>? _s1Out;

  // Stage 2 (lazy — only YOLO mode) — well detection
  OrtSession? _stage2Session;
  List<String>? _s2In;
  List<String>? _s2Out;
  bool _stage2Loaded = false;
  bool _stage2Available = true; // becomes false if asset missing

  // Stage 3 (always loaded) — RF classification
  OrtSession? _stage3Session;
  List<String>? _s3In;
  List<String>? _s3Out;
  bool _stage3Available = true;

  bool _isInitialized = false;

  late PipelineConfig _cfg;
  late WellGrid _grid;

  static final InferenceService _instance = InferenceService._internal();
  factory InferenceService() => _instance;
  InferenceService._internal();

  bool get isStage3Available => _stage3Available;
  bool get isStage2Available => _stage2Available && _stage2Loaded;
  PipelineConfig get config => _cfg;
  WellGrid get grid => _grid;

  /// Initialize Stage 1 + Stage 3 (Stage 2 lazy on YOLO mode).
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      OrtEnv.instance.init();
      _cfg = await PipelineConfig.load();
      _grid = WellGrid(GridParamsDyn(
        rows: _cfg.rows,
        cols: _cfg.cols,
        templateCornersUv: _cfg.templateCornersUv,
        margin: _cfg.plateMargin,
        gates: _cfg.gatesPitch,
        snapTol: _cfg.snapTolPitch,
        maxRefine: _cfg.maxRefine,
        minConf: _cfg.coarseAlignMinConf,
        scaleMin: _cfg.coarseScaleMin,
        scaleMax: _cfg.coarseScaleMax,
        phaseRadius: _cfg.phaseRadius,
        growRadii: _cfg.growRadii,
        growHomographyFrom: _cfg.growHomographyFrom,
      ));

      // Stage 1: 4 góc plate
      _stage1Session = await _loadSession(_cfg.modelAsset(_cfg.stage1Model));
      _s1In = _stage1Session!.inputNames;
      _s1Out = _stage1Session!.outputNames;
      print('[Inference] Stage1 inputs=$_s1In outputs=$_s1Out');

      // Stage 3: classifier (optional — fall back to brightness if missing)
      try {
        _stage3Session = await _loadSession(_cfg.modelAsset(_cfg.stage3Model));
        _s3In = _stage3Session!.inputNames;
        _s3Out = _stage3Session!.outputNames;
        print('[Inference] Stage3 (${_cfg.stage3Family}) loaded inputs=$_s3In outputs=$_s3Out');
      } catch (e) {
        print('[Inference] Stage3 RF not available ($e) — will use brightness fallback');
        _stage3Available = false;
      }

      _isInitialized = true;
      return true;
    } catch (e) {
      print('[Inference] init failed: $e');
      return false;
    }
  }

  Future<OrtSession> _loadSession(String assetPath) async {
    final raw = await rootBundle.load(assetPath);
    final bytes = raw.buffer.asUint8List();
    return OrtSession.fromBuffer(bytes, OrtSessionOptions());
  }

  /// Lazy-load Stage 2 YOLO (only when user picks YOLO mode).
  Future<bool> ensureStage2Loaded() async {
    if (_stage2Loaded) return true;
    if (!_stage2Available) return false;
    try {
      _stage2Session = await _loadSession(_cfg.modelAsset(_cfg.stage2Model));
      _s2In = _stage2Session!.inputNames;
      _s2Out = _stage2Session!.outputNames;
      _stage2Loaded = true;
      print('[Inference] Stage2 (YOLO) loaded inputs=$_s2In outputs=$_s2Out');
      return true;
    } catch (e) {
      print('[Inference] Stage2 YOLO load failed: $e');
      _stage2Available = false;
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // STAGE 1: corner regression (shared by all modes)
  // ─────────────────────────────────────────────
  Future<List<Map<String, double>>> runStage1(img.Image image) async {
    final sw = Stopwatch()..start();

    final swPre = Stopwatch()..start();
    final (input, frame) = _preprocessStage1(image);
    print('[Stage1] preprocess: ${swPre.elapsedMilliseconds}ms');

    final shape = [1, 1, _cfg.stage1Size, _cfg.stage1Size];
    final inputOrt = OrtValueTensor.createTensorWithDataList(input, shape);
    final inputs = {_s1In!.first: inputOrt};
    final runOpts = OrtRunOptions();

    final swInf = Stopwatch()..start();
    final outputs = await _stage1Session!.runAsync(runOpts, inputs);
    print('[Stage1] inference: ${swInf.elapsedMilliseconds}ms');

    if (outputs == null || outputs.isEmpty || outputs[0] == null) {
      inputOrt.release();
      runOpts.release();
      throw Exception('Stage 1: no output');
    }
    final raw = outputs[0]!.value;
    // ONNX may return [[d0,d1,...,d7]] (nested) or [d0,d1,...,d7] (flat)
    final List<double> data;
    if (raw is List && raw.isNotEmpty && raw[0] is List) {
      // Nested: [[d0, d1, ..., d7]]
      data = (raw[0] as List).map((e) => (e as num).toDouble()).toList();
    } else if (raw is List) {
      data = raw.map((e) => (e as num).toDouble()).toList();
    } else {
      throw Exception('Stage 1: unexpected output type ${raw.runtimeType}');
    }

    // Output chuẩn hoá theo khung Stage 1 -> px khung -> px ảnh (bỏ xoay / nền), như acam.inference.stage1_corners
    final corners = <Map<String, double>>[];
    for (var i = 0; i < 4; i++) {
      final (x, y) = frame.toImage(data[i * 2] * frame.canvasW, data[i * 2 + 1] * frame.canvasH);
      corners.add({'x': x, 'y': y});
    }
    inputOrt.release();
    runOpts.release();
    for (final o in outputs) {
      o?.release();
    }
    sw.stop();
    print('[Stage1] TOTAL: ${sw.elapsedMilliseconds}ms (corner detection)');
    return _orderCorners(corners);
  }

  /// Stage 1: Detect corners via EfficientNet + WARP plate (no grid interpolation).
  /// Returns corners + warped image + inverse matrix for Stage 2 YOLO.
  Future<Stage1Result> detectCornersAndWarp(String imagePath) async {
    final sw = Stopwatch()..start();
    final image = await _decodePhoto(imagePath);

    // Step 1: Run Stage 1 EfficientNet corner detection
    final swPre = Stopwatch()..start();
    final corners = await runStage1(image);
    print('[Stage1] preprocess: ${swPre.elapsedMilliseconds}ms');

    // Step 2: Warp plate to canonical aligned view
    final swWarp = Stopwatch()..start();
    final warped = _warpPlate(image, corners);
    print('[Stage1] warp: ${swWarp.elapsedMilliseconds}ms');

    sw.stop();
    print('[Stage1] TOTAL: ${sw.elapsedMilliseconds}ms (corner detection + warp)');

    return Stage1Result(
      corners: corners,
      warpedImage: warped.image,
      inverseMatrix: warped.dstToSrc,
    );
  }

  /// DEPRECATED: Auto grid interpolation removed - use detectCornersAndWarp() instead.
  /// Detect grid (Mode A: auto). Returns corners + positions + diameter.
  Future<DetectionResult> detectAutoGrid(String imagePath) async {
    final sw = Stopwatch()..start();
    final image = await _decodePhoto(imagePath);
    final corners = await runStage1(image);

    final positions = ImageUtils.bilinearInterpolateGrid(
        corners, GridParams.rows, GridParams.cols);
    final plateW = ((corners[1]['x']! - corners[0]['x']!).abs() +
            (corners[2]['x']! - corners[3]['x']!).abs()) /
        2;
    final plateH = ((corners[3]['y']! - corners[0]['y']!).abs() +
            (corners[2]['y']! - corners[1]['y']!).abs()) /
        2;
    final diameter = ImageUtils.estimateWellDiameter(
        plateW, plateH, GridParams.rows, GridParams.cols, GridParams.margin);

    sw.stop();
    print('[Detect] auto grid: ${sw.elapsedMilliseconds}ms');
    return DetectionResult(
        corners: corners,
        positions: positions,
        diameter: diameter,
        mode: DetectionMode.autoGrid,
        detectionTimeMs: sw.elapsedMilliseconds.toDouble());
  }

  /// Detect wells via YOLO (Mode C). Warps image using corners first to match
  /// training data (warped plates), then maps detections back to original coords.
  Future<DetectionResult> detectYolo(
      String imagePath, List<Map<String, double>> corners) async {
    final ok = await ensureStage2Loaded();
    if (!ok) throw Exception('Stage 2 YOLO model unavailable');
    final sw = Stopwatch()..start();
    final image = await _decodePhoto(imagePath);

    // Step 1: Warp image to canonical aligned plate (matches training data)
    final warped = _warpPlate(image, corners);
    print('[YOLO] warped: ${warped.image.width}x${warped.image.height}');

    // DEBUG: lưu ảnh warped để kiểm tra bằng mắt (so với ảnh train)
    // Save to public Downloads so it can be pulled via adb (release builds
    // are not debuggable, so app_flutter dir is inaccessible).
    final debugBytes = Uint8List.fromList(img.encodePng(warped.image));
    final debugName = 'debug_warped_${DateTime.now().millisecondsSinceEpoch}.png';
    try {
      final debugFile = File('/storage/emulated/0/Download/$debugName');
      await debugFile.writeAsBytes(debugBytes);
      print('[DEBUG] warped saved to: ${debugFile.path}');
    } catch (e) {
      // Fallback to app docs dir
      final debugFile = await ImageUtils.saveImage(debugBytes, debugName);
      print('[DEBUG] warped saved to (fallback): ${debugFile.path}');
    }

    // Step 2: Run YOLO on warped image
    final warpedBoxes = await _detectWells384(warped.image);

    // Step 3: Map detections from warped coords back to original image coords
    final boxes = _unwarpBoxes(warpedBoxes, warped.dstToSrc, image.width.toDouble(), image.height.toDouble());

    // positions = box centers
    final positions = <Map<String, double>>[];
    for (final b in boxes) {
      final cx = ((b['x1']! + b['x2']!) / 2);
      final cy = ((b['y1']! + b['y2']!) / 2);
      positions.add({'x': cx, 'y': cy});
    }
    print('[YOLO] extracted ${positions.length} positions from ${boxes.length} boxes');
    // diameter: median box width
    final widths = boxes.map((b) => (b['x2']! - b['x1']!).abs()).toList()..sort();
    final diameter = widths.isEmpty
        ? 20.0
        : widths[widths.length ~/ 2].toDouble();

    sw.stop();
    print('[Detect] YOLO: ${sw.elapsedMilliseconds}ms, ${boxes.length} wells');
    return DetectionResult(
        corners: corners,
        positions: positions,
        diameter: diameter,
        mode: DetectionMode.yoloDetect,
        detectionTimeMs: sw.elapsedMilliseconds.toDouble());
  }

  /// Detect wells via YOLO and return results in WARPED coordinate space.
  ///
  /// Unlike detectYolo() which unwraps boxes back to original coords, this keeps
  /// boxes in warped-plate space — exactly matching full_pipeline.ipynb where
  /// Stage 2 + Stage 3 both operate on the warped plate image.
  Future<WarpedDetection> detectYoloWarped(
      String imagePath, List<Map<String, double>> corners) async {
    final ok = await ensureStage2Loaded();
    if (!ok) throw Exception('Stage 2 YOLO model unavailable');

    final swTotal = Stopwatch()..start();

    final image = await _decodePhoto(imagePath);

    // Step 1: Warp image to canonical aligned plate
    final warped = _warpPlate(image, corners);

    // Step 2: Run YOLO on warped image → boxes stay in WARPED coords (no unwarp)
    final swYOLO = Stopwatch()..start();
    final warpedBoxes = await _detectWells384(warped.image);
    print('[YOLO-warped] YOLO inference: ${swYOLO.elapsedMilliseconds}ms');

    // Save warped image
    final warpedBytes = await compute(_encodePngJob, warped.image);
    final warpedFileName = 'warped_plate_${DateTime.now().millisecondsSinceEpoch}.png';
    final warpedFile = await ImageUtils.saveImage(warpedBytes, warpedFileName);

    // positions = box centers (in warped coords)
    final positions = <Map<String, double>>[];
    for (final b in warpedBoxes) {
      final cx = ((b['x1']! + b['x2']!) / 2);
      final cy = ((b['y1']! + b['y2']!) / 2);
      positions.add({'x': cx, 'y': cy});
    }

    // diameter: median box width
    final widths = warpedBoxes.map((b) => (b['x2']! - b['x1']!).abs()).toList()..sort();
    final diameter = widths.isEmpty
        ? 20.0
        : widths[widths.length ~/ 2].toDouble();

    swTotal.stop();
    print('[YOLO-warped] TOTAL: ${swTotal.elapsedMilliseconds}ms (${warpedBoxes.length} wells)');

    return WarpedDetection(
      warpedImagePath: warpedFile.path,
      warpedImage: warped.image,
      warpedBoxes: warpedBoxes,
      positions: positions,
      diameter: diameter,
      corners: corners,
    );
  }

  /// Stage 2: Run YOLO detection on pre-warped plate image (from Stage 1).
  /// Returns YOLO boxes in warped coordinate space.
  Future<WarpedDetection> detectYoloOnWarped(
    img.Image warpedImage,
    List<Map<String, double>> corners,
  ) async {
    final ok = await ensureStage2Loaded();
    if (!ok) throw Exception('Stage 2 YOLO model unavailable');

    final swTotal = Stopwatch()..start();

    // Run YOLO directly on warped image
    final swYOLO = Stopwatch()..start();
    final warpedBoxes = await _detectWells384(warpedImage);
    print('[YOLO-warped] YOLO inference: ${swYOLO.elapsedMilliseconds}ms');

    // Save warped image (for debugging)
    final warpedBytes = Uint8List.fromList(img.encodePng(warpedImage));
    final warpedFileName = 'warped_plate_${DateTime.now().millisecondsSinceEpoch}.png';
    final warpedFile = await ImageUtils.saveImage(warpedBytes, warpedFileName);

    // positions = box centers (in warped coords)
    final positions = <Map<String, double>>[];
    for (final b in warpedBoxes) {
      final cx = ((b['x1']! + b['x2']!) / 2);
      final cy = ((b['y1']! + b['y2']!) / 2);
      positions.add({'x': cx, 'y': cy});
    }

    // diameter: median box width
    final widths = warpedBoxes.map((b) => (b['x2']! - b['x1']!).abs()).toList()..sort();
    final diameter = widths.isEmpty
        ? 20.0
        : widths[widths.length ~/ 2].toDouble();

    swTotal.stop();
    print('[YOLO-warped] TOTAL: ${swTotal.elapsedMilliseconds}ms (${warpedBoxes.length} wells)');

    return WarpedDetection(
      warpedImagePath: warpedFile.path,
      warpedImage: warpedImage,
      warpedBoxes: warpedBoxes,
      positions: positions,
      diameter: diameter,
      corners: corners,
    );
  }

  // ─────────────────────────────────────────────
  // STAGE 2: YOLO + NMS + hoàn thiện lưới 384
  // ─────────────────────────────────────────────
  /// YOLO trên plate đã warp -> WellGrid -> ĐÚNG 384 box (thứ tự lưới). Mỗi box có thêm
  /// 'interpolated' (không có detection, vị trí từ lưới) và 'snapped' (detection lệch, dùng vị trí lưới).
  Future<List<Map<String, dynamic>>> _detectWells384(img.Image warped) async {
    final dets = await _yoloDets(warped);
    final r = _grid.complete(dets, warped.width.toDouble(), warped.height.toDouble());
    print('[Grid] ${r.nDet} det -> 384 wells: ${r.nInterpolated} noi suy, ${r.nDropped} box thua bi loai, shift=${r.shift}');
    return _boxesFromGrid(r);
  }

  Future<List<Det>> _yoloDets(img.Image warped, {bool stretch = false}) async {
    final raw = await _runStage2YOLO(warped, stretch: stretch);
    return [for (final b in raw) Det(b['x1'] as double, b['y1'] as double, b['x2'] as double, b['y2'] as double, b['conf'] as double)];
  }

  List<Map<String, dynamic>> _boxesFromGrid(GridResult r) => [
        for (var i = 0; i < r.boxes.length; i++)
          {
            'x1': r.boxes[i][0],
            'y1': r.boxes[i][1],
            'x2': r.boxes[i][2],
            'y2': r.boxes[i][3],
            'conf': r.conf[i],
            'interpolated': !r.detected[i],
            'snapped': r.snapped[i],
          }
      ];

  // ─────────────────────────────────────────────
  // Luồng v2 (PipelineWorkspaceScreen): mỗi stage chạy 1 lần, kết quả lưu ở Stage1Meta / Stage2Meta
  // ─────────────────────────────────────────────
  /// Decode ảnh (isolate) — ảnh gốc hoặc plate đã warp đã lưu.
  Future<img.Image> loadImage(String path) => _decode(path);

  /// Chỉ chạy model Stage 1 (không warp): góc TL,TR,BR,BL + kích thước ảnh đã decode.
  /// Dùng để điền sẵn màn hình chỉnh góc khi chưa lưu góc (ảnh chạy Stage 1 trước bản v7).
  Future<(List<Map<String, double>>, int, int)> detectCorners(String imagePath) async {
    final image = await _decodePhoto(imagePath);
    return (await runStage1(image), image.width, image.height);
  }

  /// Stage 1: [corners] null -> model dự đoán; có -> góc chỉnh tay. Warp + lưu PNG + kiểm tra chất lượng.
  Future<Stage1Output> stage1Warp(String imagePath, {List<Map<String, double>>? corners}) async {
    final image = await _decodePhoto(imagePath);
    final auto = corners == null ? await runStage1(image) : null;
    final use = orderCorners(corners ?? auto!);
    final warped = _warpPlate(image, use);
    final bytes = await compute(_encodePngJob, warped.image);
    final file = await ImageUtils.saveImage(bytes, 'warped_plate_${DateTime.now().millisecondsSinceEpoch}.png');
    final qc = quadMetrics(use, image.width.toDouble(), image.height.toDouble());
    return Stage1Output(
      source: corners == null ? Stage1Meta.sourceAuto : Stage1Meta.sourceManual,
      image: image,
      corners: use,
      warped: warped.image,
      warpedPath: file.path,
      qc: qc,
      warn: corners == null ? stage1Warnings(qc, _cfg) : const [],
    );
  }

  /// Stage 2 trên plate đã warp. [manual] null -> YOLO + WellGrid (đúng 384 ô). Có -> chế độ tay:
  /// lưới 16x24 + refine + có YOLO -> lai (3 box hút về YOLO rồi complete); còn lại thuần hình học.
  Future<Stage2Output> stage2Detect(img.Image warped, {ManualWells? manual}) async {
    final w = warped.width.toDouble(), h = warped.height.toDouble();
    final GridResult r;
    final String source;
    var stretched = false;
    // Như OnnxPipeline.stage2_grid: lưới phải nội suy quá nhiều (ảnh tối / tương phản thấp) -> chạy lại YOLO trên
    // ảnh kéo giãn tương phản, giữ kết quả khớp nhiều ô hơn.
    Future<GridResult> withRetry(GridResult Function(List<Det>) fn) async {
      final g = fn(await _yoloDets(warped));
      if (g.nInterpolated <= _cfg.stage2RetryInterpFrac * g.boxes.length) return g;
      final g2 = fn(await _yoloDets(warped, stretch: true));
      final n1 = g.detected.where((d) => d).length, n2 = g2.detected.where((d) => d).length;
      print('[Stage2] ${g.nInterpolated} noi suy -> chay lai YOLO tren anh keo gian tuong phan: $n1 -> $n2 o khop');
      if (n2 <= n1) return g;
      stretched = true;
      return g2;
    }

    if (manual == null) {
      if (!await ensureStage2Loaded()) throw Exception('Stage 2 YOLO model unavailable');
      r = await withRetry((d) => _grid.complete(d, w, h));
      source = Stage2Meta.sourceAuto;
    } else if (manual.refine && _grid.isHybridCounts(manual.n12, manual.n13) && await ensureStage2Loaded()) {
      r = await withRetry((d) => _grid.fromAnchorsRefined(d, w, h, manual.anchors, manual.n12, manual.n13));
      source = Stage2Meta.sourceHybrid;
    } else {
      r = _grid.fromAnchors(manual.anchors, manual.n12, manual.n13);
      source = Stage2Meta.sourceGeom;
    }
    final warn = source == Stage2Meta.sourceGeom
        ? stage2Warnings(r.boxes.length, 0, 0, r.pitch, _cfg) // không có YOLO: chỉ kiểm độ phân giải
        : [
            ...stage2Warnings(r.boxes.length, r.nInterpolated, r.nSnapped, r.pitch, _cfg),
            if (source == Stage2Meta.sourceHybrid && (r.shift[0] != 0 || r.shift[1] != 0)) 'grid_shifted',
          ];
    print('[Stage2] $source: ${r.rows}x${r.cols}, ${r.nDet} det, ${r.nInterpolated} noi suy, '
        '${r.nSnapped} snap, shift=${r.shift}, warn=$warn');
    return Stage2Output(source: source, boxes: _boxesFromGrid(r), grid: r, warn: warn, stretched: stretched);
  }

  /// Detection YOLO thô (chưa ghép lưới) trên ảnh [imagePath], toạ độ nhân (scaleX, scaleY). Màn hình
  /// Manual wells chạy trên ảnh hiển thị ≤2048 px của plate đã warp (decode nhanh; YOLO vẫn resize về
  /// 640) rồi đổi về px ảnh warp gốc: hiện chấm "well model tìm được" + chạm hút box vào đó.
  /// [] nếu không có model YOLO.
  Future<List<Det>> detectWellBoxes(String imagePath, {double scaleX = 1, double scaleY = 1}) async {
    await initialize();
    if (!await ensureStage2Loaded()) return const [];
    final dets = await _yoloDets(await _decode(imagePath));
    return [for (final d in dets) Det(d.x1 * scaleX, d.y1 * scaleY, d.x2 * scaleX, d.y2 * scaleY, d.conf)];
  }

  Future<List<Map<String, dynamic>>> _runStage2YOLO(img.Image image, {bool stretch = false}) async {
    final lb = _preprocessYolo(image, stretch: stretch);
    final inp = lb.input;
    final shape = [1, 1, _cfg.stage2Size, _cfg.stage2Size];
    final inputOrt = OrtValueTensor.createTensorWithDataList(inp, shape);
    final inputs = {_s2In!.first: inputOrt};
    final runOpts = OrtRunOptions();
    final outputs = await _stage2Session!.runAsync(runOpts, inputs);
    inputOrt.release();
    runOpts.release();
    if (outputs == null || outputs.isEmpty || outputs[0] == null) {
      throw Exception('Stage 2 YOLO: no output');
    }

    // Output shape: [1, 5, 8400] -> [x_center, y_center, w, h, class_score]
    // (single class; no objectness in YOLOv8)
    final raw = outputs[0]!.value;
    for (final o in outputs) {
      o?.release();
    }

    // Flatten nested output: [[[[row0],[row1],...]]]] or [[row0],[row1],...]
    List<List<double>> rows;
    if (raw is List && raw.isNotEmpty && raw[0] is! double) {
      // Peel outer batch dims until we reach [5][8400]
      dynamic ptr = raw;
      while (ptr is List && ptr.isNotEmpty && ptr[0] is! List<double> && ptr[0] is List && (ptr[0] as List).isNotEmpty && (ptr[0] as List)[0] is! double) {
        ptr = ptr[0];
      }
      // ptr should now be [5][8400] or [5][<nested>]
      if (ptr is List && ptr.isNotEmpty && ptr[0] is List) {
        rows = (ptr as List).map((r) => (r as List).map((e) => (e as num).toDouble()).toList()).toList();
      } else {
        throw Exception('Stage 2 YOLO: unexpected output shape ${raw.runtimeType}');
      }
    } else {
      throw Exception('Stage 2 YOLO: unexpected output type ${raw.runtimeType}');
    }
    final n = rows[0].length; // 8400

    final detections = <Map<String, dynamic>>[];
    for (var i = 0; i < n; i++) {
      final score = rows[4][i];
      if (score < _cfg.stage2Conf) continue;
      // Bỏ letterbox: trừ pad (số nguyên, đúng như lúc dán ảnh), chia scale
      final cx = (rows[0][i] - lb.padX) / lb.scale;
      final cy = (rows[1][i] - lb.padY) / lb.scale;
      final w = rows[2][i] / lb.scale;
      final h = rows[3][i] / lb.scale;
      detections.add({
        'x1': cx - w / 2,
        'y1': cy - h / 2,
        'x2': cx + w / 2,
        'y2': cy + h / 2,
        'conf': score,
        '_i': i,
      });
    }
    print('[YOLO] raw detections (conf>${_cfg.stage2Conf}): ${detections.length}');

    final kept = _nms(detections, _cfg.stage2Iou);
    print('[YOLO] after NMS (iou=${_cfg.stage2Iou}): ${kept.length}');
    final result = kept.length > _cfg.stage2MaxDet ? kept.sublist(0, _cfg.stage2MaxDet) : kept;
    for (final b in result) {
      b.remove('_i');
    }
    return result;
  }

  /// Greedy NMS như acam/inference.py: sắp conf giảm dần (ỔN ĐỊNH — hoà thì theo thứ tự anchor),
  /// bỏ box có IoU > ngưỡng với box đã giữ.
  List<Map<String, dynamic>> _nms(List<Map<String, dynamic>> boxes, double iouThresh) {
    boxes.sort((a, b) {
      final c = (b['conf'] as double).compareTo(a['conf'] as double);
      return c != 0 ? c : (a['_i'] as int? ?? 0).compareTo(b['_i'] as int? ?? 0);
    });
    final kept = <Map<String, dynamic>>[];
    final suppressed = List<bool>.filled(boxes.length, false);
    for (var i = 0; i < boxes.length; i++) {
      if (suppressed[i]) continue;
      kept.add(boxes[i]);
      for (var j = i + 1; j < boxes.length; j++) {
        if (suppressed[j]) continue;
        if (_iou(boxes[i], boxes[j]) > iouThresh) suppressed[j] = true;
      }
    }
    return kept;
  }

  double _iou(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ax1 = (a['x1'] as num).toDouble(), ay1 = (a['y1'] as num).toDouble();
    final ax2 = (a['x2'] as num).toDouble(), ay2 = (a['y2'] as num).toDouble();
    final bx1 = (b['x1'] as num).toDouble(), by1 = (b['y1'] as num).toDouble();
    final bx2 = (b['x2'] as num).toDouble(), by2 = (b['y2'] as num).toDouble();
    final x1 = math.max(ax1, bx1);
    final y1 = math.max(ay1, by1);
    final x2 = math.min(ax2, bx2);
    final y2 = math.min(ay2, by2);
    final interW = (x2 - x1).clamp(0.0, double.infinity);
    final interH = (y2 - y1).clamp(0.0, double.infinity);
    final inter = interW * interH;
    final areaA = (ax2 - ax1) * (ay2 - ay1);
    final areaB = (bx2 - bx1) * (by2 - by1);
    final union = areaA + areaB - inter;
    return union <= 0 ? 0 : inter / union;
  }

  // ─────────────────────────────────────────────
  // STAGE 3: phân loại 384 well (ONNX CNN / cây quyết định, fallback độ sáng)
  // ─────────────────────────────────────────────
  /// Chỉ trả class id (API cũ). Dùng [classifyWellsDetailed] để lấy thêm xác suất.
  Future<List<int>> classifyWells(img.Image image, List<Map<String, dynamic>> boxes) async =>
      (await classifyWellsDetailed(image, boxes)).classes;

  Future<Stage3Output> classifyWellsDetailed(img.Image image, List<Map<String, dynamic>> boxes) async {
    if (_stage3Session == null || boxes.isEmpty) {
      return Stage3Output(_classifyWellsBrightness(image, boxes), null);
    }
    final sw = Stopwatch()..start();
    final size = _cfg.stage3CropSize;
    final n = boxes.length;
    final mat = _toMatRgb(image);
    final List<int> shape;
    final Float32List input;
    var gain = 1.0;
    if (_cfg.stage3Family == 'cnn') {
      // (N, C, 64, 64): C=3 theo thứ tự B,G,R (như crop cv2 lúc train) hoặc C=1 gray; chia 255.
      // Lần 1: crop + tổng gray từng crop -> gain chuẩn hoá độ sáng theo plate (như acam.models.stage3.plate_gain);
      // lần 2: pixel qua LUT gain rồi chia 255 (như crops_to_array(..., gain)).
      final c = _cfg.stage3InCh;
      final datas = <Uint8List>[];
      final sums = <int>[];
      for (var i = 0; i < n; i++) {
        final crop = _wellCrop64(mat, boxes[i]);
        final g = cv.cvtColor(crop, cv.COLOR_RGB2GRAY);
        final gd = g.data;
        var s = 0;
        for (final v in gd) {
          s += v;
        }
        sums.add(s);
        datas.add(Uint8List.fromList(c == 1 ? gd : crop.data)); // c=3: RGB xen kẽ
        g.dispose();
        crop.dispose();
      }
      gain = plateGain(sums, size * size, _cfg.stage3PlateRefGray, _cfg.stage3PlateGainMax);
      final lut = gainLut(gain);
      input = Float32List(n * c * size * size);
      for (var i = 0; i < n; i++) {
        final d = datas[i];
        final off = i * c * size * size;
        if (c == 1) {
          for (var k = 0; k < size * size; k++) {
            input[off + k] = lut[d[k]] / 255.0;
          }
        } else {
          for (var k = 0; k < size * size; k++) {
            input[off + k] = lut[d[k * 3 + 2]] / 255.0; // B
            input[off + size * size + k] = lut[d[k * 3 + 1]] / 255.0; // G
            input[off + 2 * size * size + k] = lut[d[k * 3]] / 255.0; // R
          }
        }
      }
      shape = [n, c, size, size];
    } else if (_cfg.stage3FeatureSet == 'gray64' || _cfg.stage3FeatureSet == 'app_v1') {
      input = Float32List(n * size * size);
      for (var i = 0; i < n; i++) {
        final crop = _wellCrop64(mat, boxes[i]);
        final g = cv.cvtColor(crop, cv.COLOR_RGB2GRAY);
        final d = g.data;
        for (var k = 0; k < size * size; k++) {
          input[i * size * size + k] = d[k] / 255.0;
        }
        g.dispose();
        crop.dispose();
      }
      shape = [n, size * size];
    } else {
      mat.dispose();
      throw UnsupportedError('Stage 3: bo dac trung "${_cfg.stage3FeatureSet}" chua duoc port sang Dart');
    }
    mat.dispose();

    final inputOrt = OrtValueTensor.createTensorWithDataList(input, shape);
    final runOpts = OrtRunOptions();
    final outputs = await _stage3Session!.runAsync(runOpts, {_s3In!.first: inputOrt});
    inputOrt.release();
    runOpts.release();
    if (outputs == null || outputs.isEmpty) throw Exception('Stage 3: no output');
    // CNN: 1 output 'probabilities'; cây (skl2onnx): 'label', 'probabilities'
    final pIdx = _s3Out!.indexOf('probabilities');
    final raw = outputs[pIdx < 0 ? outputs.length - 1 : pIdx]!.value as List;
    for (final o in outputs) {
      o?.release();
    }
    final probs = [for (final row in raw) [for (final v in row as List) (v as num).toDouble()]];
    final w = _cfg.classProbWeights;
    final classes = <int>[];
    for (final p in probs) {
      var best = 0;
      for (var k = 1; k < p.length; k++) {
        if (p[k] * w[k] > p[best] * w[best]) best = k;
      }
      classes.add(best);
    }
    print('[Stage3] ${_cfg.stage3Family}: $n wells ${sw.elapsedMilliseconds}ms, gain ${gain.toStringAsFixed(3)}');
    return Stage3Output(classes, probs, gain: gain);
  }

  /// Crop chuẩn Stage 3 (như acam.models.stage3.well_crop64): bbox nới margin mỗi phía, làm tròn .5 lên,
  /// kẹp trong ảnh -> resize size x size INTER_AREA. Trả Mat RGB (caller dispose).
  cv.Mat _wellCrop64(cv.Mat rgb, Map<String, dynamic> box) {
    final size = _cfg.stage3CropSize;
    final m = _cfg.stage3WellMargin;
    final x1 = (box['x1'] as num).toDouble(), y1 = (box['y1'] as num).toDouble();
    final x2 = (box['x2'] as num).toDouble(), y2 = (box['y2'] as num).toDouble();
    final cx = (x1 + x2) / 2, cy = (y1 + y2) / 2;
    final hw = (x2 - x1) * (1 + 2 * m) / 2, hh = (y2 - y1) * (1 + 2 * m) / 2;
    final a = math.max(0, _rhu(cx - hw)), b = math.max(0, _rhu(cy - hh));
    final c = math.min(rgb.cols, _rhu(cx + hw)), d = math.min(rgb.rows, _rhu(cy + hh));
    if (c - a < 2 || d - b < 2) {
      return cv.Mat.zeros(size, size, cv.MatType.CV_8UC3);
    }
    final roi = rgb.region(cv.Rect(a, b, c - a, d - b));
    final out = cv.resize(roi, (size, size), interpolation: cv.INTER_AREA);
    roi.dispose();
    return out;
  }

  // ─────────────────────────────────────────────
  // FULL PIPELINE
  // ─────────────────────────────────────────────
  /// Classify wells detected in WARPED space and draw color-coded result.
  ///
  /// Matches full_pipeline.ipynb: crops wells from the warped plate using the
  /// YOLO boxes (warped coords), classifies, and draws the final overlay on the
  /// warped plate — wells align perfectly because everything is in one frame.
  Future<PipelineResult> classifyWarpedWells(WarpedDetection detection) async {
    final sw = Stopwatch()..start();

    // Classify using warped image + warped boxes (both in warped coords)
    final swClass = Stopwatch()..start();
    final classes = await classifyWells(detection.warpedImage, detection.warpedBoxes);
    print('[Classify] took: ${swClass.elapsedMilliseconds}ms (${classes.length} wells)');

    // Draw color-coded overlay on the warped plate
    final swDraw = Stopwatch()..start();
    var annotated = ImageUtils.drawWellBoxes(
        detection.warpedImage, detection.warpedBoxes, classes);
    // Full-res warp can exceed 4096px — over GLES max texture size, which
    // stalls the raster thread (scroll freeze) when the image is displayed.
    const maxDim = 2048;
    if (annotated.width > maxDim || annotated.height > maxDim) {
      final scale = maxDim / math.max(annotated.width, annotated.height);
      annotated = img.copyResize(annotated,
          width: (annotated.width * scale).round(),
          height: (annotated.height * scale).round());
    }
    final annotatedBytes = Uint8List.fromList(img.encodePng(annotated));
    final annotatedFile = await ImageUtils.saveImage(
        annotatedBytes, 'annotated_warped_${DateTime.now().millisecondsSinceEpoch}.png');
    print('[Draw/Save] annotated: ${swDraw.elapsedMilliseconds}ms');

    // Count classes
    final counts = <String, int>{
      'growth': 0,
      'no_growth': 0,
      'no_agar': 0,
    };
    for (final cls in classes) {
      if (cls == 0) counts['growth'] = counts['growth']! + 1;
      if (cls == 1) counts['no_growth'] = counts['no_growth']! + 1;
      if (cls == 2) counts['no_agar'] = counts['no_agar']! + 1;
    }

    sw.stop();
    print('[Pipeline-warped] classify ${sw.elapsedMilliseconds}ms counts=$counts');

    return PipelineResult(
        imagePath: detection.warpedImagePath,
        annotatedPath: annotatedFile.path,
        boxes: detection.warpedBoxes,
        classes: classes,
        counts: counts,
        processingTimeMs: sw.elapsedMilliseconds.toDouble(),
        corners: detection.corners,
        mode: DetectionMode.yoloDetect);
  }

  /// Warp plate image and save to file (for Stage 1 visualization).
  Future<String> warpPlateAndSave(
    String imagePath,
    List<Map<String, double>> corners,
  ) async {
    final image = await _decodePhoto(imagePath);
    final warped = _warpPlate(image, corners);

    final bytes = await compute(_encodePngJob, warped.image);
    final filename = 'warped_plate_${DateTime.now().millisecondsSinceEpoch}.png';
    final file = await ImageUtils.saveImage(bytes, filename);
    return file.path;
  }

  // ─────────────────────────────────────────────
  // FULL PIPELINE (legacy — used by GridAdjustScreen)
  // ─────────────────────────────────────────────
  /// Run full pipeline from a detection result (already-detected wells).
  /// Used after the preview/adjust screen accepts the grid.
  Future<PipelineResult> runFromDetection(
    String imagePath,
    DetectionResult detection, {
    GridTransform? transform,
  }) async {
    final sw = Stopwatch()..start();
    final image = await _decodePhoto(imagePath);

    // Determine final boxes
    List<Map<String, dynamic>> boxes;
    List<Map<String, double>> cornersOut;
    if (detection.mode == DetectionMode.manualGrid && transform != null) {
      final r = GridTransformUtils.applyTransform(
          detection.positions, detection.corners, transform);
      boxes = ImageUtils.generateBoxesFromPositions(r.positions, r.diameter);
      cornersOut = r.corners;
    } else {
      boxes = ImageUtils.generateBoxesFromPositions(
          detection.positions, detection.diameter);
      cornersOut = detection.corners;
    }

    final classes = await classifyWells(image, boxes);

    final annotated = ImageUtils.drawWellBoxes(image, boxes, classes);
    final annotatedBytes = Uint8List.fromList(img.encodePng(annotated));
    final annotatedFile = await ImageUtils.saveImage(
        annotatedBytes, 'annotated_${DateTime.now().millisecondsSinceEpoch}.png');

    final counts = <String, int>{
      'growth': 0,
      'no_growth': 0,
      'no_agar': 0,
    };
    for (final cls in classes) {
      if (cls == 0) counts['growth'] = counts['growth']! + 1;
      if (cls == 1) counts['no_growth'] = counts['no_growth']! + 1;
      if (cls == 2) counts['no_agar'] = counts['no_agar']! + 1;
    }

    sw.stop();
    print('[Pipeline] total ${sw.elapsedMilliseconds}ms counts=$counts');
    return PipelineResult(
        imagePath: imagePath,
        annotatedPath: annotatedFile.path,
        boxes: boxes,
        classes: classes,
        counts: counts,
        processingTimeMs: sw.elapsedMilliseconds.toDouble(),
        corners: cornersOut,
        mode: detection.mode);
  }

  // ─────────────────────────────────────────────
  // Preprocessing helpers
  // ─────────────────────────────────────────────
  Future<img.Image> _decode(String imagePath) async {
    final sw = Stopwatch()..start();
    final bytes = await File(imagePath).readAsBytes();
    final image = await compute(_decodeImageJob, bytes);
    if (image == null) throw Exception('Failed to decode image');
    print('[Decode] image: ${sw.elapsedMilliseconds}ms (${image.width}x${image.height})');
    return image;
  }

  /// Ảnh chụp (mọi nguồn): decode + giới hạn độ phân giải — như acam.inference.limit_resolution: cạnh dài >
  /// max_image_side -> thu nhỏ INTER_AREA (OpenCV). Kết quả là "ảnh làm việc": mọi toạ độ Stage 1 theo ảnh này.
  /// (Ảnh warp / ảnh hiển thị đã lưu dùng [_decode]: toạ độ box theo đúng kích thước file.)
  Future<img.Image> _decodePhoto(String imagePath) async {
    final image = await _decode(imagePath);
    final (nw, nh) = workingSize(image.width, image.height, _cfg.maxImageSide);
    if (nw == image.width && nh == image.height) return image;
    final sw = Stopwatch()..start();
    final src = _toMatRgb(image);
    final dst = cv.resize(src, (nw, nh), interpolation: cv.INTER_AREA);
    final out = _fromMatRgb(dst);
    src.dispose();
    dst.dispose();
    print('[Decode] ${image.width}x${image.height} -> ${nw}x$nh (max ${_cfg.maxImageSide}px): ${sw.elapsedMilliseconds}ms');
    return out;
  }

  /// Stage 1 (như acam.inference.stage1_input): gray (OpenCV, uint8) -> khung Stage 1 (ảnh dọc xoay 90° cùng chiều
  /// kim đồng hồ; khung lệch 3:2 thêm nền = trung vị viền) -> resize size x size INTER_LINEAR_EXACT (không giữ tỉ lệ;
  /// INTER_LINEAR của OpenCV ARM lệch x86 ±1 mức xám ở ~15% pixel -> góc lệch 1-3 px, bản EXACT giống hệt bit)
  /// -> (x/255 - mean)/std. Trả kèm khung để đổi output về px ảnh.
  (Float32List, Stage1Frame) _preprocessStage1(img.Image image) {
    final size = _cfg.stage1Size;
    final rgb = _toMatRgb(image);
    var gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
    final frame = stage1Frame(image.width, image.height, _cfg.stage1CanvasAspect, _cfg.stage1AspectTol);
    if (frame.rotate) {
      final r = cv.rotate(gray, cv.ROTATE_90_CLOCKWISE);
      gray.dispose();
      gray = r;
    }
    if (frame.padded) {
      final v = borderMedian(gray.data, gray.cols, gray.rows, _cfg.stage1PadBorderFrac);
      final p = cv.copyMakeBorder(gray, frame.top, frame.bottom, frame.left, frame.right, cv.BORDER_CONSTANT,
          value: cv.Scalar.all(v.toDouble()));
      gray.dispose();
      gray = p;
    }
    if (frame.rotate || frame.padded) {
      print('[Stage1] frame ${image.width}x${image.height} -> ${frame.canvasW}x${frame.canvasH} '
          '(rotate=${frame.rotate}, pad t${frame.top} b${frame.bottom} l${frame.left} r${frame.right})');
    }
    final resized = cv.resize(gray, (size, size), interpolation: cv.INTER_LINEAR_EXACT);
    final d = resized.data;
    final input = Float32List(size * size);
    for (var i = 0; i < size * size; i++) {
      input[i] = (d[i] / 255.0 - _cfg.stage1Mean) / _cfg.stage1Std;
    }
    rgb.dispose();
    gray.dispose();
    resized.dispose();
    return (input, frame);
  }

  /// Letterbox cho YOLO (như acam.inference.letterbox): gray -> resize giữ tỉ lệ (INTER_LINEAR_EXACT)
  /// -> đặt vào khung size x size, phần thừa = pad (114, như Ultralytics lúc train) -> /255.
  YoloLetterbox _preprocessYolo(img.Image image, {bool stretch = false}) {
    final size = _cfg.stage2Size;
    final ow = image.width, oh = image.height;
    final scale = math.min(size / oh, size / ow);
    final newW = _rhu(ow * scale), newH = _rhu(oh * scale);
    final left = (size - newW) ~/ 2, top = (size - newH) ~/ 2;
    final rgb = _toMatRgb(image);
    var gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
    if (stretch) {
      // Lần chạy lại cho ảnh tối / tương phản thấp (như acam.inference.contrast_stretch)
      final s = contrastStretch(gray.data, _cfg.stage2RetryStretch[0], _cfg.stage2RetryStretch[1]);
      final g2 = cv.Mat.fromList(gray.rows, gray.cols, cv.MatType.CV_8UC1, s);
      gray.dispose();
      gray = g2;
    }
    final resized = cv.resize(gray, (newW, newH), interpolation: cv.INTER_LINEAR_EXACT);
    final boxed = cv.copyMakeBorder(resized, top, size - newH - top, left, size - newW - left, cv.BORDER_CONSTANT,
        value: cv.Scalar.all(_cfg.stage2Pad.toDouble()));
    final d = boxed.data;
    final input = Float32List(size * size);
    for (var i = 0; i < size * size; i++) {
      input[i] = d[i] / 255.0;
    }
    rgb.dispose();
    gray.dispose();
    resized.dispose();
    boxed.dispose();
    return YoloLetterbox(input: input, scale: scale, padX: left.toDouble(), padY: top.toDouble());
  }

  List<Map<String, double>> _orderCorners(List<Map<String, double>> corners) => orderCorners(corners); // TL,TR,BR,BL

  /// Brightness fallback (used only if RF model unavailable).
  List<int> _classifyWellsBrightness(
      img.Image plateImage, List<Map<String, dynamic>> boxes) {
    final classes = <int>[];
    for (final box in boxes) {
      final x1 = (box['x1'] as num).round();
      final y1 = (box['y1'] as num).round();
      final x2 = (box['x2'] as num).round();
      final y2 = (box['y2'] as num).round();
      var sum = 0, count = 0;
      for (var y = y1; y < y2; y++) {
        for (var x = x1; x < x2; x++) {
          if (x >= 0 && x < plateImage.width && y >= 0 && y < plateImage.height) {
            sum += plateImage.getPixel(x, y).r.toInt();
            count++;
          }
        }
      }
      final brightness = count > 0 ? sum / count : 0;
      if (brightness < 50) {
        classes.add(2);
      } else if (brightness < 120) {
        classes.add(1);
      } else {
        classes.add(0);
      }
    }
    return classes;
  }

  void dispose() {
    _stage1Session?.release();
    _stage2Session?.release();
    _stage3Session?.release();
    _isInitialized = false;
  }

  // ─────────────────────────────────────────────
  // Perspective warp (match generate_stage2_data.py canonical_align)
  // ─────────────────────────────────────────────

  /// Warp image so the 4 corners become a rectangular plate with PLATE_MARGIN.
  /// Uses OpenCV FFI for C++ performance (50-100x faster than Dart loop).
  /// Returns warped image + inverse matrix (to map detections back to original).
  WarpResult _warpPlate(img.Image image, List<Map<String, double>> corners) {
    final sw = Stopwatch()..start();

    // Order corners TL,TR,BR,BL (should already be ordered from Stage 1)
    final ordered = _orderCorners(corners);
    final tl = ordered[0], tr = ordered[1], br = ordered[2], bl = ordered[3];

    // Plate dimensions from corner distances
    final wTop = _dist(tl, tr);
    final wBot = _dist(bl, br);
    final hLeft = _dist(tl, bl);
    final hRight = _dist(tr, br);
    // Như acam.geometry.canonical_warp_params: làm tròn .5 lên
    final plateW = _rhu((wTop + wBot) / 2);
    final plateH = _rhu((hLeft + hRight) / 2);

    final margin = _cfg.plateMargin;
    final outW = _rhu(plateW * (1 + 2 * margin));
    final outH = _rhu(plateH * (1 + 2 * margin));
    final padX = _rhu(plateW * margin);
    final padY = _rhu(plateH * margin);

    print('[Warp OpenCV] plateW=$plateW plateH=$plateH outW=$outW outH=$outH');

    // Ảnh RGB 3 kênh (không alpha): vùng ngoài ảnh gốc = 0 (đen) như lúc train
    final srcMat = _toMatRgb(image);

    // Góc nguồn giữ nguyên số thực (float32) như cv2.getPerspectiveTransform bên Python
    final srcPoints = cv.VecPoint2f.fromList([
      cv.Point2f(tl['x']!, tl['y']!),
      cv.Point2f(tr['x']!, tr['y']!),
      cv.Point2f(br['x']!, br['y']!),
      cv.Point2f(bl['x']!, bl['y']!),
    ]);
    final dstPoints = cv.VecPoint2f.fromList([
      cv.Point2f(padX.toDouble(), padY.toDouble()),
      cv.Point2f((padX + plateW - 1).toDouble(), padY.toDouble()),
      cv.Point2f((padX + plateW - 1).toDouble(), (padY + plateH - 1).toDouble()),
      cv.Point2f(padX.toDouble(), (padY + plateH - 1).toDouble()),
    ]);
    final M = cv.getPerspectiveTransform2f(srcPoints, dstPoints);

    final warpedMat = cv.warpPerspective(
      srcMat,
      M,
      (outW, outH),
      flags: cv.INTER_LINEAR,
      borderMode: cv.BORDER_CONSTANT,
      borderValue: cv.Scalar.all(0),
    );

    // Extract inverse matrix from M (OpenCV stores as 3x3)
    final Minv = _invert3x3([
      M.at<double>(0, 0),
      M.at<double>(0, 1),
      M.at<double>(0, 2),
      M.at<double>(1, 0),
      M.at<double>(1, 1),
      M.at<double>(1, 2),
      M.at<double>(2, 0),
      M.at<double>(2, 1),
      M.at<double>(2, 2),
    ]);

    // mat.data là view vào bộ nhớ native -> _fromMatRgb copy trước khi dispose
    final warped = _fromMatRgb(warpedMat);

    srcMat.dispose();
    warpedMat.dispose();
    M.dispose();
    srcPoints.dispose();
    dstPoints.dispose();

    sw.stop();
    print('[Warp OpenCV] took: ${sw.elapsedMilliseconds}ms (${outW}x${outH}=${outW * outH} pixels)');

    return WarpResult(image: warped, dstToSrc: Minv);
  }

  /// Map YOLO detection boxes from warped (dst) coords back to original (src).
  List<Map<String, dynamic>> _unwarpBoxes(
      List<Map<String, dynamic>> warpedBoxes,
      List<double> dstToSrc,
      double origW,
      double origH) {
    final Minv = dstToSrc;

    var inBounds = 0;
    var outBounds = 0;
    var sampleLogged = 0;
    final result = <Map<String, dynamic>>[];
    for (final b in warpedBoxes) {
      // Map center + corners
      final cx = (b['x1']! + b['x2']!) / 2;
      final cy = (b['y1']! + b['y2']!) / 2;
      final p = _applyPerspective(Minv, cx, cy);
      final ox = p[0];
      final oy = p[1];

      // Log first few samples for debugging
      if (sampleLogged < 3) {
        print('[Unwarp] Sample ${sampleLogged+1}: warped=($cx,$cy) → original=($ox,$oy) bounds=(${origW.toInt()}x${origH.toInt()})');
        sampleLogged++;
      }

      if (ox < 0 || ox >= origW || oy < 0 || oy >= origH) {
        outBounds++;
        continue;
      }
      inBounds++;
      // Scale box size back (approximate using local scale at center)
      final halfW = (b['x2']! - b['x1']!) / 2;
      final halfH = (b['y2']! - b['y1']!) / 2;
      final pa = _applyPerspective(Minv, cx + halfW, cy);
      final scaleW = (pa[0] - ox).abs() / halfW.clamp(0.1, double.infinity);
      final newHalfW = halfW * (scaleW.isFinite ? scaleW : 1.0).clamp(0.1, 5.0);
      final pb = _applyPerspective(Minv, cx, cy + halfH);
      final scaleH = (pb[1] - oy).abs() / halfH.clamp(0.1, double.infinity);
      final newHalfH = halfH * (scaleH.isFinite ? scaleH : 1.0).clamp(0.1, 5.0);

      result.add({
        'x1': (ox - newHalfW).clamp(0.0, origW),
        'y1': (oy - newHalfH).clamp(0.0, origH),
        'x2': (ox + newHalfW).clamp(0.0, origW),
        'y2': (oy + newHalfH).clamp(0.0, origH),
        'conf': b['conf'],
      });
    }
    print('[Unwarp] inBounds=$inBounds outBounds=$outBounds result=${result.length}');
    return result;
  }

  double _dist(Map<String, double> a, Map<String, double> b) {
    final dx = a['x']! - b['x']!;
    final dy = a['y']! - b['y']!;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Solve 3x3 perspective transform matrix from 4 src→dst point pairs.
  /// Returns [a,b,c,d,e,f,g,h,1] (homogeneous, i=1).
  List<double> _getPerspectiveTransform(
      List<Map<String, double>> src, List<List<double>> dst) {
    // 8x8 linear system:
    // [xi yi 1 0 0 0 -xi'xi -xi'yi] [a]   [xi']
    // [0 0 0 xi yi 1 -yi'xi -yi'yi] [b] = [yi']
    // Solve for [a,b,c,d,e,f,g,h]
    final A = List.generate(8, (_) => List.filled(8, 0.0));
    final B = List.filled(8, 0.0);
    for (var i = 0; i < 4; i++) {
      final x = src[i]['x']!, y = src[i]['y']!;
      final xp = dst[i][0], yp = dst[i][1];
      // Row 2i
      A[2 * i][0] = x;
      A[2 * i][1] = y;
      A[2 * i][2] = 1;
      A[2 * i][6] = -xp * x;
      A[2 * i][7] = -xp * y;
      B[2 * i] = xp;
      // Row 2i+1
      A[2 * i + 1][3] = x;
      A[2 * i + 1][4] = y;
      A[2 * i + 1][5] = 1;
      A[2 * i + 1][6] = -yp * x;
      A[2 * i + 1][7] = -yp * y;
      B[2 * i + 1] = yp;
    }
    final sol = _solveLinear(A, B);
    return [sol[0], sol[1], sol[2], sol[3], sol[4], sol[5], sol[6], sol[7], 1.0];
  }

  /// Apply perspective transform: [x', y', w'] = M · [x, y, 1].
  List<double> _applyPerspective(List<double> M, double x, double y) {
    final w = M[6] * x + M[7] * y + M[8];
    final xp = (M[0] * x + M[1] * y + M[2]) / w;
    final yp = (M[3] * x + M[4] * y + M[5]) / w;
    return [xp, yp, w];
  }

  /// Invert 3x3 matrix.
  List<double> _invert3x3(List<double> m) {
    final a = m[0], b = m[1], c = m[2];
    final d = m[3], e = m[4], f = m[5];
    final g = m[6], h = m[7], i = m[8];
    final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (det.abs() < 1e-12) return List.filled(9, 0.0)..[8] = 1.0;
    final invDet = 1.0 / det;
    return [
      (e * i - f * h) * invDet,
      (c * h - b * i) * invDet,
      (b * f - c * e) * invDet,
      (f * g - d * i) * invDet,
      (a * i - c * g) * invDet,
      (c * d - a * f) * invDet,
      (d * h - e * g) * invDet,
      (b * g - a * h) * invDet,
      (a * e - b * d) * invDet,
    ];
  }

  /// Gaussian elimination for Ax=B.
  List<double> _solveLinear(List<List<double>> A, List<double> B) {
    final n = B.length;
    // Augmented matrix
    final M = List.generate(n, (i) => [...A[i], B[i]]);
    for (var col = 0; col < n; col++) {
      // Pivot
      var pivot = col;
      for (var r = col + 1; r < n; r++) {
        if (M[r][col].abs() > M[pivot][col].abs()) pivot = r;
      }
      if (pivot != col) {
        final tmp = M[pivot];
        M[pivot] = M[col];
        M[col] = tmp;
      }
      if (M[col][col].abs() < 1e-12) continue;
      // Eliminate
      for (var r = 0; r < n; r++) {
        if (r == col) continue;
        final factor = M[r][col] / M[col][col];
        for (var c = col; c <= n; c++) {
          M[r][c] -= factor * M[col][c];
        }
      }
    }
    final x = List.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      x[i] = M[i][n] / M[i][i];
    }
    return x;
  }
}

/// Stage 1 (luồng v2): ảnh gốc đã decode, góc đã sắp TL,TR,BR,BL, plate đã warp (bộ nhớ + PNG), QC.
class Stage1Output {
  final String source; // Stage1Meta.sourceAuto | sourceManual
  final img.Image image;
  final List<Map<String, double>> corners;
  final img.Image warped;
  final String warpedPath;
  final QuadMetrics qc;
  final List<String> warn;
  Stage1Output({
    required this.source,
    required this.image,
    required this.corners,
    required this.warped,
    required this.warpedPath,
    required this.qc,
    required this.warn,
  });
}

/// Stage 2 (luồng v2): box (map x1,y1,x2,y2,conf,interpolated,snapped), lưới + thống kê, cảnh báo.
class Stage2Output {
  final String source; // Stage2Meta.source*
  final List<Map<String, dynamic>> boxes;
  final GridResult grid;
  final List<String> warn;
  final bool stretched; // YOLO chạy lại trên ảnh kéo giãn tương phản (ảnh tối)
  Stage2Output(
      {required this.source, required this.boxes, required this.grid, required this.warn, this.stretched = false});

  Map<String, dynamic> get stats => {
        'n_det': grid.nDet,
        'n_interpolated': grid.nInterpolated,
        'n_snapped': grid.nSnapped,
        'n_dropped': grid.nDropped,
        'shift': grid.shift,
        'pitch': double.parse(grid.pitch.toStringAsFixed(2)),
        'stretched': stretched,
      };
}

/// Result of perspective warp: warped image + inverse matrix (dst→src).
class Stage1Result {
  final List<Map<String, double>> corners;
  final img.Image warpedImage;
  final List<double> inverseMatrix;
  Stage1Result({
    required this.corners,
    required this.warpedImage,
    required this.inverseMatrix,
  });
}

class WarpResult {
  final img.Image image;
  final List<double> dstToSrc; // inverse matrix (dst→src)
  WarpResult({required this.image, required this.dstToSrc});
}

/// YOLO detection result in WARPED coordinate space.
/// Matches full_pipeline.ipynb: Stage 2 + Stage 3 both run on the warped plate.
class WarpedDetection {
  final String warpedImagePath; // saved warped plate image file
  final img.Image warpedImage; // warped plate image (in-memory)
  final List<Map<String, dynamic>> warpedBoxes; // bboxes in warped coords
  final List<Map<String, double>> positions; // well centers in warped coords
  final double diameter; // median well diameter in warped coords
  final List<Map<String, double>> corners; // original corners (TL,TR,BR,BL)

  WarpedDetection({
    required this.warpedImagePath,
    required this.warpedImage,
    required this.warpedBoxes,
    required this.positions,
    required this.diameter,
    required this.corners,
  });
}

/// Letterbox params for YOLO preprocessing (matches Ultralytics letterbox).
/// Preserves aspect ratio: resize + pad with gray to 640x640.
class YoloLetterbox {
  final Float32List input;
  final double scale; // resize scale (orig → resized)
  final double padX; // horizontal padding (pixels, in 640 space)
  final double padY; // vertical padding (pixels, in 640 space)
  YoloLetterbox(
      {required this.input,
      required this.scale,
      required this.padX,
      required this.padY});
}
