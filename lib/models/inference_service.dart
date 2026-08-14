/// Inference service - FULL PIPELINE với ONNX Runtime (3-mode detection + RF classify)
/// - Stage 1: EfficientNet-B3 grid-corner regression (ONNX INT8) -> 4 corners
/// - Stage 2: 3 modes
///     A) autoGrid   : bilinear grid from corners
///     B) manualGrid : 5-DOF similarity transform applied to base grid
///     C) yoloDetect : YOLOv8n (ch=1) ONNX -> NMS -> 384 wells
/// - Stage 3: ExtraTrees/RF ONNX classification (replaces brightness threshold)
library inference_service;

import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:dartcv4/dartcv.dart' as cv;

import '../utils/constants.dart';
import '../utils/image_utils.dart';
import '../utils/grid_transform.dart';

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

  String get countsDisplay =>
      'Total: ${boxes.length} | Growth: ${counts['growth']} | '
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

  static final InferenceService _instance = InferenceService._internal();
  factory InferenceService() => _instance;
  InferenceService._internal();

  bool get isStage3Available => _stage3Available;
  bool get isStage2Available => _stage2Available && _stage2Loaded;

  /// Initialize Stage 1 + Stage 3 (Stage 2 lazy on YOLO mode).
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    try {
      OrtEnv.instance.init();

      // Stage 1: grid corners
      _stage1Session = await _loadSession('assets/models/stage1_grid_fp32.onnx');
      _s1In = _stage1Session!.inputNames;
      _s1Out = _stage1Session!.outputNames;
      print('[Inference] Stage1 inputs=$_s1In outputs=$_s1Out');

      // Stage 3: RF classifier (optional — fall back to brightness if missing)
      try {
        _stage3Session = await _loadSession('assets/models/stage3_rf_fp32.onnx');
        _s3In = _stage3Session!.inputNames;
        _s3Out = _stage3Session!.outputNames;
        print('[Inference] Stage3 (RF) loaded inputs=$_s3In outputs=$_s3Out');
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
      _stage2Session = await _loadSession('assets/models/stage2_yolo.onnx');
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
    final hOrig = image.height;
    final wOrig = image.width;

    final swPre = Stopwatch()..start();
    final input = _preprocessStage1(image);
    print('[Stage1] preprocess: ${swPre.elapsedMilliseconds}ms');

    final shape = [1, 1, Stage1Params.imgSize, Stage1Params.imgSize];
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

    final corners = <Map<String, double>>[];
    for (var i = 0; i < 4; i++) {
      corners.add({
        'x': data[i * 2] * wOrig,
        'y': data[i * 2 + 1] * hOrig,
      });
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
    final image = await _decode(imagePath);

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
    final image = await _decode(imagePath);
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
    final image = await _decode(imagePath);

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
    final warpedBoxes = await _runStage2YOLO(warped.image);

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

    final image = await _decode(imagePath);

    // Step 1: Warp image to canonical aligned plate
    final warped = _warpPlate(image, corners);

    // Step 2: Run YOLO on warped image → boxes stay in WARPED coords (no unwarp)
    final swYOLO = Stopwatch()..start();
    final warpedBoxes = await _runStage2YOLO(warped.image);
    print('[YOLO-warped] YOLO inference: ${swYOLO.elapsedMilliseconds}ms');

    // Save warped image
    final warpedBytes = Uint8List.fromList(img.encodePng(warped.image));
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
    final warpedBoxes = await _runStage2YOLO(warpedImage);
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
  // STAGE 2c: YOLO inference + NMS
  // ─────────────────────────────────────────────
  Future<List<Map<String, dynamic>>> _runStage2YOLO(img.Image image) async {
    final lb = _preprocessYolo(image);
    final inp = lb.input;
    final shape = [1, 1, 640, 640];
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
      if (score < Stage2Params.conf) continue;
      // Undo letterbox: subtract padding, divide by scale
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
      });
    }
    print('[YOLO] raw detections (conf>${Stage2Params.conf}): ${detections.length}');

    final kept = _nms(detections, Stage2Params.iou);
    print('[YOLO] after NMS (iou=${Stage2Params.iou}): ${kept.length}');
    // cap at maxDet
    final result = kept.length > Stage2Params.maxDet
        ? kept.sublist(0, Stage2Params.maxDet)
        : kept;
    return result;
  }

  List<Map<String, dynamic>> _nms(List<Map<String, dynamic>> boxes, double iouThresh) {
    boxes.sort((a, b) => (b['conf'] as double).compareTo(a['conf'] as double));
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
  // STAGE 3: classify 384 wells (RF ONNX or brightness fallback)
  // ─────────────────────────────────────────────
  Future<List<int>> classifyWells(
      img.Image image, List<Map<String, dynamic>> boxes) async {
    if (_stage3Session != null) {
      return _classifyWellsRF(image, boxes);
    }
    return _classifyWellsBrightness(image, boxes);
  }

  Future<List<int>> _classifyWellsRF(
      img.Image image, List<Map<String, dynamic>> boxes) async {
    final size = Stage3Params.cropSize; // 64
    // Build batch feature matrix: [N, 4096] /255
    final n = boxes.length;
    final features = Float32List(n * size * size);
    for (var i = 0; i < n; i++) {
      final f = _cropWellFeature(image, boxes[i], size);
      // f is Float32List(4096), values 0..1
      for (var j = 0; j < f.length; j++) {
        features[i * size * size + j] = f[j];
      }
    }

    final shape = [n, size * size];
    final inputOrt = OrtValueTensor.createTensorWithDataList(features, shape);
    final inputs = {_s3In!.first: inputOrt};
    final runOpts = OrtRunOptions();
    final outputs = await _stage3Session!.runAsync(runOpts, inputs);
    inputOrt.release();
    runOpts.release();
    if (outputs == null || outputs.isEmpty || outputs[0] == null) {
      throw Exception('Stage 3 RF: no output');
    }

    final raw = outputs[0]!.value;
    // Flatten nested: [[label0, label1, ...]] or [label0, label1, ...]
    final List<int> predList;
    if (raw is List && raw.isNotEmpty && raw[0] is List) {
      predList = (raw[0] as List).map((e) => (e as num).toInt()).toList();
    } else if (raw is List) {
      predList = raw.map((e) => (e as num).toInt()).toList();
    } else {
      throw Exception('Stage 3 RF: unexpected output type ${raw.runtimeType}');
    }
    final classes = predList;
    for (final o in outputs) {
      o?.release();
    }
    return classes;
  }

  /// Crop one well to (size x size) grayscale, flattened, normalized /255.
  Float32List _cropWellFeature(
      img.Image image, Map<String, dynamic> box, int size) {
    final x1 = box['x1']!.round().clamp(0, image.width - 1);
    final y1 = box['y1']!.round().clamp(0, image.height - 1);
    final x2 = box['x2']!.round().clamp(1, image.width);
    final y2 = box['y2']!.round().clamp(1, image.height);
    final cw = x2 - x1;
    final ch = y2 - y1;
    if (cw <= 0 || ch <= 0) {
      return Float32List(size * size); // zeros
    }
    // crop
    final cropped = img.copyCrop(image, x: x1, y: y1, width: cw, height: ch);
    // resize to size x size
    final resized = img.copyResize(cropped, width: size, height: size,
        interpolation: img.Interpolation.linear);
    // grayscale + flatten /255
    final bytes = resized.getBytes(order: img.ChannelOrder.rgba);
    final feat = Float32List(size * size);
    int idx = 0;
    for (int i = 0; i < bytes.length; i += 4) {
      final r = bytes[i];
      final g = bytes[i + 1];
      final b = bytes[i + 2];
      final gray = 0.299 * r + 0.587 * g + 0.114 * b;
      feat[idx++] = gray / 255.0;
    }
    return feat;
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
    final annotated = ImageUtils.drawWellBoxes(
        detection.warpedImage, detection.warpedBoxes, classes);
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
    final image = await _decode(imagePath);
    final warped = _warpPlate(image, corners);

    final bytes = Uint8List.fromList(img.encodePng(warped.image));
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
    final image = await _decode(imagePath);

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
    final image = img.decodeImage(bytes);
    if (image == null) throw Exception('Failed to decode image');
    print('[Decode] image: ${sw.elapsedMilliseconds}ms (${image.width}x${image.height})');
    return image;
  }

  Float32List _preprocessStage1(img.Image image) {
    final size = Stage1Params.imgSize;
    final resized = img.copyResize(image,
        width: size, height: size, interpolation: img.Interpolation.linear);
    final bytes = resized.getBytes(order: img.ChannelOrder.rgba);
    final input = Float32List(size * size);
    int idx = 0;
    for (int i = 0; i < bytes.length; i += 4) {
      final r = bytes[i];
      final g = bytes[i + 1];
      final b = bytes[i + 2];
      final gray = 0.299 * r + 0.587 * g + 0.114 * b;
      input[idx++] = (gray / 255.0 - Stage1Params.mean) / Stage1Params.std;
    }
    return input;
  }

  /// Letterbox preprocessing for YOLO (matches Ultralytics letterbox).
  /// Preserves aspect ratio: resize + pad with gray (0.5) to 640x640.
  /// Returns input tensor + letterbox params for unscaling detections.
  YoloLetterbox _preprocessYolo(img.Image image) {
    const size = 640;
    final ow = image.width.toDouble();
    final oh = image.height.toDouble();
    final scale = math.min(size / ow, size / oh);
    final newW = (ow * scale).round();
    final newH = (oh * scale).round();
    // Ultralytics centers the image; compute padding
    final padW = (size - newW) / 2;
    final padH = (size - newH) / 2;

    // Resize preserving aspect ratio
    final resized = img.copyResize(image,
        width: newW, height: newH, interpolation: img.Interpolation.linear);

    // Create 640x640 canvas filled with gray (0.5 * 255 = 127.5 → 128)
    final canvas = img.Image(width: size, height: size);
    img.fill(canvas, color: img.ColorRgba8(128, 128, 128, 255));
    // Paste resized image at pad offset
    final px = padW.round();
    final py = padH.round();
    img.compositeImage(canvas, resized, dstX: px, dstY: py);

    // Grayscale + normalize
    final bytes = canvas.getBytes(order: img.ChannelOrder.rgba);
    final input = Float32List(size * size);
    int idx = 0;
    for (int i = 0; i < bytes.length; i += 4) {
      final r = bytes[i];
      final g = bytes[i + 1];
      final b = bytes[i + 2];
      input[idx++] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0;
    }
    return YoloLetterbox(
        input: input, scale: scale, padX: padW, padY: padH);
  }

  List<Map<String, double>> _orderCorners(List<Map<String, double>> corners) {
    final sortedByY = List<Map<String, double>>.from(corners)
      ..sort((a, b) => a['y']!.compareTo(b['y']!));
    final top2 = sortedByY.sublist(0, 2);
    final bottom2 = sortedByY.sublist(2);
    top2.sort((a, b) => a['x']!.compareTo(b['x']!));
    bottom2.sort((a, b) => a['x']!.compareTo(b['x']!));
    return [top2[0], top2[1], bottom2[1], bottom2[0]]; // TL,TR,BR,BL
  }

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
    final plateW = ((wTop + wBot) / 2).round();
    final plateH = ((hLeft + hRight) / 2).round();

    final margin = GridParams.margin;
    final outW = (plateW * (1 + 2 * margin)).round();
    final outH = (plateH * (1 + 2 * margin)).round();
    final padX = (plateW * margin).round();
    final padY = (plateH * margin).round();

    print('[Warp OpenCV] plateW=$plateW plateH=$plateH outW=$outW outH=$outH');

    // Create cv.Mat DIRECTLY from raw RGBA bytes (no PNG encode/decode!).
    // Mat.fromList copies the data once — far cheaper than PNG compression.
    final rgbaBytes = image.getBytes(order: img.ChannelOrder.rgba);
    final srcMat = cv.Mat.fromList(
      image.height,
      image.width,
      cv.MatType.CV_8UC4,
      rgbaBytes,
    );

    // Source corners (VecPoint - integer points for getPerspectiveTransform)
    final srcPoints = cv.VecPoint.fromList([
      cv.Point(tl['x']!.toInt(), tl['y']!.toInt()),
      cv.Point(tr['x']!.toInt(), tr['y']!.toInt()),
      cv.Point(br['x']!.toInt(), br['y']!.toInt()),
      cv.Point(bl['x']!.toInt(), bl['y']!.toInt()),
    ]);

    // Destination corners (with margin)
    final dstPoints = cv.VecPoint.fromList([
      cv.Point(padX, padY),
      cv.Point(padX + plateW - 1, padY),
      cv.Point(padX + plateW - 1, padY + plateH - 1),
      cv.Point(padX, padY + plateH - 1),
    ]);

    // Get perspective transform matrix
    final M = cv.getPerspectiveTransform(srcPoints, dstPoints);

    // Warp perspective on the 4-channel RGBA Mat (OpenCV handles all channels).
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

    // Extract raw RGBA bytes DIRECTLY from the warped Mat (no PNG!).
    // mat.data is a zero-copy view over native memory; copy it before disposing.
    final warpedBytes = Uint8List.fromList(warpedMat.data);
    final warped = img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: warpedBytes.buffer,
      order: img.ChannelOrder.rgba,
    );

    // Cleanup OpenCV Mats
    srcMat.dispose();
    warpedMat.dispose();
    M.dispose();

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
