/// GridAdjustScreen — Unified touch-gesture grid adjustment screen.
///
/// - Landscape orientation
/// - Default centered 16x24 grid on image load
/// - Touch gestures: drag (translate), pinch (scale), two-finger rotate
/// - Buttons: Reset, AutoDetect (Stage 1), YOLO (Stage 2), Classify (Stage 3)
/// - CustomPaint overlay at 60fps (no JPG encoding)
library grid_adjust_screen;

import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../models/inference_service.dart';
import '../utils/constants.dart';
import '../utils/image_utils.dart';
import '../painters/grid_overlay_painter.dart';
import 'results_screen.dart';

class GridAdjustScreen extends StatefulWidget {
  final String imagePath;

  const GridAdjustScreen({super.key, required this.imagePath});

  @override
  State<GridAdjustScreen> createState() => _GridAdjustScreenState();
}

class _GridAdjustScreenState extends State<GridAdjustScreen> {
  // Image
  img.Image? _image;
  bool _imageLoaded = false;

  // Base grid (default centered, or ML-detected)
  List<Map<String, double>> _basePositions = [];
  List<Map<String, double>> _baseCorners = [];
  double _baseDiameter = 20.0;

  // Stage 1 & 2 state (for pipeline flow)
  img.Image? _warpedImage; // warped plate from Stage 1
  List<Map<String, dynamic>> _yoloBoxes = []; // YOLO boxes from Stage 2
  bool _stage1Done = false;
  bool _stage2Done = false;

  // Gesture state
  Offset _translate = Offset.zero;
  double _scale = 1.0;
  double _rotation = 0.0; // radians
  // True until Stage 1 auto-detect or manual gesture sets real corners.
  // While true, YOLO must run Stage 1 first (default centered corners don't
  // match the actual plate position → bad warp → poor detection).
  bool _isDefaultGrid = true;

  // UI state
  bool _busy = false;
  String _statusText = '';

  // BoxFit.contain transform (for gesture coordinate mapping)
  Size _screenSize = Size.zero;
  double _imgScale = 1.0;
  Offset _imgOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Failed to decode image');
      _image = decoded;

      // Default centered grid
      _setDefaultGrid(decoded.width.toDouble(), decoded.height.toDouble());

      if (mounted) setState(() => _imageLoaded = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load image: $e')),
        );
      }
    }
  }

  void _setDefaultGrid(double imgW, double imgH) {
    final margin = GridParams.margin;
    final marginX = imgW * margin;
    final marginY = imgH * margin;

    _baseCorners = [
      {'x': marginX, 'y': marginY}, // TL
      {'x': imgW - marginX, 'y': marginY}, // TR
      {'x': imgW - marginX, 'y': imgH - marginY}, // BR
      {'x': marginX, 'y': imgH - marginY}, // BL
    ];

    _basePositions = ImageUtils.bilinearInterpolateGrid(
        _baseCorners, GridParams.rows, GridParams.cols);

    final plateW = imgW * (1 - 2 * margin);
    final plateH = imgH * (1 - 2 * margin);
    _baseDiameter =
        ImageUtils.estimateWellDiameter(plateW, plateH, GridParams.rows, GridParams.cols, margin);
  }

  // ── Transform ──────────────────────────────────────────
  List<Map<String, double>> get _currentPositions =>
      _applyTransform(_basePositions);

  List<Map<String, double>> get _currentCorners =>
      _applyTransform(_baseCorners);

  List<Map<String, double>> _applyTransform(
      List<Map<String, double>> basePoints) {
    if (basePoints.isEmpty) return [];
    // Compute centroid
    double sx = 0, sy = 0;
    for (final p in basePoints) {
      sx += p['x']!;
      sy += p['y']!;
    }
    final cx = sx / basePoints.length;
    final cy = sy / basePoints.length;

    final cosR = math.cos(_rotation);
    final sinR = math.sin(_rotation);

    return basePoints.map((p) {
      final x0 = p['x']! - cx;
      final y0 = p['y']! - cy;
      // Rotate
      final rx = x0 * cosR - y0 * sinR;
      final ry = x0 * sinR + y0 * cosR;
      // Scale + translate back + gesture offset
      return {
        'x': rx * _scale + cx + _translate.dx,
        'y': ry * _scale + cy + _translate.dy,
      };
    }).toList();
  }

  // ── BoxFit.contain transform ───────────────────────────
  void _updateContainTransform(Size screenSize) {
    if (_image == null || screenSize == _screenSize) return;
    _screenSize = screenSize;
    final sx = screenSize.width / _image!.width;
    final sy = screenSize.height / _image!.height;
    _imgScale = math.min(sx, sy);
    _imgOffset = Offset(
      (screenSize.width - _image!.width * _imgScale) / 2,
      (screenSize.height - _image!.height * _imgScale) / 2,
    );
  }

  // Convert screen delta → image delta
  Offset _screenToImageDelta(Offset screenDelta) {
    return Offset(screenDelta.dx / _imgScale, screenDelta.dy / _imgScale);
  }

  // ── Gestures ───────────────────────────────────────────
  void _onScaleStart(ScaleStartDetails details) {
    // No special init needed — cumulative state
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    setState(() {
      // Pinch scale (cumulative)
      if (details.scale != 1.0) {
        _scale = (_scale * details.scale).clamp(0.3, 3.0);
      }
      // Rotation (cumulative radians)
      _rotation += details.rotation;
      // Translation — convert screen delta to image delta
      final imgDelta = _screenToImageDelta(details.focalPointDelta);
      _translate = _translate + imgDelta;
      // User has manually adjusted → corners are no longer default placeholder
      _isDefaultGrid = false;
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // Gesture complete
  }

  // ── Actions ────────────────────────────────────────────
  void _reset() {
    setState(() {
      _translate = Offset.zero;
      _scale = 1.0;
      _rotation = 0.0;
      // Reset to default centered grid (undo any auto-detect/manual adjust)
      if (_image != null) {
        _setDefaultGrid(_image!.width.toDouble(), _image!.height.toDouble());
        _isDefaultGrid = true;
      }
    });
  }

  Future<void> _autoDetect() async {
    setState(() {
      _busy = true;
      _statusText = 'Stage 1: Detecting corners + warping...';
    });
    try {
      final svc = InferenceService();
      await svc.initialize();

      // Stage 1: Detect corners + WARP (no grid interpolation)
      final stage1Result = await svc.detectCornersAndWarp(widget.imagePath);

      if (mounted) {
        setState(() {
          _warpedImage = stage1Result.warpedImage;
          _baseCorners = stage1Result.corners;
          // Keep default positions for visualization (will be replaced by YOLO)
          _basePositions = ImageUtils.bilinearInterpolateGrid(
              stage1Result.corners, GridParams.rows, GridParams.cols);
          _baseDiameter = 20.0; // Will be updated by YOLO
          _translate = Offset.zero;
          _scale = 1.0;
          _rotation = 0.0;
          _isDefaultGrid = false;
          _stage1Done = true;
          _busy = false;
          _statusText = 'Stage 1 complete: Corners detected + warped';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusText = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 1 failed: $e')),
        );
      }
    }
  }

  Future<void> _runYolo() async {
    // Require Stage 1 to complete first
    if (!_stage1Done || _warpedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please run Stage 1 (corners + warp) first!'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _busy = true;
      _statusText = 'Stage 2: Running YOLO on warped plate...';
    });
    try {
      final svc = InferenceService();
      await svc.initialize();

      // Stage 2: Run YOLO on pre-warped image from Stage 1
      final detection = await svc.detectYoloOnWarped(
        _warpedImage!,
        _baseCorners,
      );

      if (mounted) {
        setState(() {
          _yoloBoxes = detection.warpedBoxes;
          _basePositions = detection.positions;
          _baseDiameter = detection.diameter;
          _stage2Done = true;
          _busy = false;
          _statusText = 'Stage 2 complete: ${detection.positions.length} wells detected';
        });
        _showYoloStatsDialog(detection.positions.length, detection.diameter);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusText = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 2 failed: $e')),
        );
      }
    }
  }

  void _showYoloStatsDialog(int wellCount, double wellDiameter) {
    if (_image == null) return;
    final origW = _image!.width;
    final origH = _image!.height;
    final wellArea = math.pi * math.pow(wellDiameter / 2, 2);
    final plateArea = origW * origH;
    final coverage = (wellArea * wellCount / plateArea * 100);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('YOLO Detection Results'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• Wells detected: $wellCount / 384',
                style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 8),
            Text('• Input image: ${origW}x${origH} px',
                style: const TextStyle(fontSize: 14)),
            Text('• Well diameter: ${wellDiameter.toStringAsFixed(1)} px',
                style: const TextStyle(fontSize: 14)),
            Text('• Well coverage: ${coverage.toStringAsFixed(1)}%',
                style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            const Text('Grid ready to classify.',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _classify() async {
    // Require Stage 2 to complete first
    if (!_stage2Done || _yoloBoxes.isEmpty || _warpedImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please run Stage 2 (YOLO detection) first!'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() {
      _busy = true;
      _statusText = 'Stage 3: Classifying wells...';
    });
    try {
      final svc = InferenceService();
      await svc.initialize();

      // Build WarpedDetection from Stage 2 results
      final warpedDetection = WarpedDetection(
        warpedImagePath: '', // Not needed for classification
        warpedImage: _warpedImage!,
        warpedBoxes: _yoloBoxes,
        positions: _basePositions,
        diameter: _baseDiameter,
        corners: _baseCorners,
      );

      // Stage 3: Classify warped wells
      final result = await svc.classifyWarpedWells(warpedDetection);

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => ResultsScreen(result: result)),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 3 failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _statusText = '';
        });
      }
    }
  }

  // ── Build ──────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Adjust Grid', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            tooltip: 'Auto Detect Corners',
            onPressed: _busy ? null : _autoDetect,
            icon: const Icon(Icons.auto_awesome),
          ),
          IconButton(
            tooltip: 'Reset Grid',
            onPressed: _busy ? null : _reset,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _imageLoaded && _image != null ? _buildBody() : _buildLoading(),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Loading image...'),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        // Image + Grid Overlay (gesture-enabled)
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _updateContainTransform(constraints.biggest);
              return GestureDetector(
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                behavior: HitTestBehavior.translucent,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Base image
                    Image.file(
                      File(widget.imagePath),
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                    // Grid overlay (CustomPaint)
                    CustomPaint(
                      size: constraints.biggest,
                      painter: GridOverlayPainter(
                        positions: _currentPositions,
                        corners: _currentCorners,
                        diameter: _baseDiameter * _scale,
                        imageWidth: _image!.width.toDouble(),
                        imageHeight: _image!.height.toDouble(),
                      ),
                    ),
                    // Loading overlay
                    if (_busy)
                      Container(
                        color: Colors.black.withOpacity(0.5),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(color: Colors.white),
                              const SizedBox(height: 12),
                              Text(
                                _statusText,
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),

        // Bottom action bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              // Reset
              OutlinedButton.icon(
                onPressed: _busy ? null : _reset,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Reset'),
              ),
              const SizedBox(width: 8),
              // YOLO
              OutlinedButton.icon(
                onPressed: _busy ? null : _runYolo,
                icon: const Icon(Icons.sensors, size: 18),
                label: const Text('YOLO'),
              ),
              const SizedBox(width: 16),
              // Classify (primary)
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _classify,
                  icon: const Icon(Icons.check_circle, size: 20),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('Classify 384 Wells',
                        style: TextStyle(fontSize: 16)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
