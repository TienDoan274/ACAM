/// PipelineScreen — Multi-stage microplate analysis workflow
///
/// Architecture:
/// - Left sidebar: Navigate between stages (Original, Stage 1, Stage 2, Stage 3)
/// - Right content: Current stage view with Run/Reset buttons
/// - Each stage output persists, can review previous stages
library pipeline_screen;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;

import '../models/inference_service.dart';
import '../models/database_helper.dart';
import '../utils/constants.dart';
import '../utils/image_utils.dart';
import 'results_screen.dart';

class PipelineScreen extends StatefulWidget {
  const PipelineScreen({super.key});

  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

enum PipelineStage {
  selectFile('Select Image', Icons.folder_open),
  stage1('Stage 1: Warp', Icons.crop_rotate),
  stage2('Stage 2: Detect', Icons.grid_on),
  stage3('Stage 3: Classify', Icons.science);

  final String label;
  final IconData icon;
  const PipelineStage(this.label, this.icon);
}

class _PipelineScreenState extends State<PipelineScreen>
    with AutomaticKeepAliveClientMixin {
  PipelineStage _currentStage = PipelineStage.selectFile;

  // Batch processing state
  List<File> _inputImages = [];
  int _currentImageIndex = 0;
  List<PipelineResult> _batchResults = [];
  Map<int, String> _imageStatus = {}; // image_index -> status message

  // Pipeline state (persists across stages) - for current image
  File? get _inputImage => _currentImageIndex < _inputImages.length
      ? _inputImages[_currentImageIndex]
      : null;
  List<Map<String, double>>? _corners;
  File? _originalWithCorners; // Stage 1: original with detected corners drawn
  File? _warpedImage;
  WarpedDetection? _warpedDetection; // Stage 2 result (warped coords)
  File? _stage2Visualization;
  List<int>? _classes;
  Map<String, int>? _counts;
  File? _finalVisualization;

  // Processing state
  bool _isProcessing = false;
  String _statusMessage = '';

  // Full pipeline option
  bool _autoRunAllStages = false;

  final InferenceService _inferenceService = InferenceService();
  final DatabaseHelper _db = DatabaseHelper();

  // Determine which stages are complete
  bool get _hasStage1 => _corners != null && _warpedImage != null;
  bool get _hasStage2 => _warpedDetection != null;
  bool get _hasStage3 => _classes != null && _counts != null;

  // Responsive sizing helper
  double _getResponsiveIconSize(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    if (screenWidth < 600) return 48.0; // Mobile
    if (screenWidth < 900) return 64.0; // Tablet
    return 80.0; // Desktop
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required for AutomaticKeepAliveClientMixin
    // Mobile-first: always use drawer navigation for better UX
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: Text(
          _currentStage.label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Theme.of(context).colorScheme.inverseSurface,
        foregroundColor: Colors.white,
        toolbarHeight: 40,
        actions: _buildAppBarActions(),
      ),
      drawer: _buildMobileDrawer(),
      body: _buildCurrentStage(),
      floatingActionButton: _inputImage != null
          ? FloatingActionButton.extended(
              onPressed: _isProcessing ? null : _runFullPipelineSequential,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Run Full Pipeline'),
            )
          : null,
    );
  }

  /// Run / Reset action icons in AppBar (compact, no in-body button row)
  List<Widget> _buildAppBarActions() {
    final run = (VoidCallback fn) => IconButton(
          icon: const Icon(Icons.play_arrow),
          tooltip: 'Run',
          iconSize: 22,
          onPressed: _isProcessing ? null : fn,
        );
    final reset = (VoidCallback fn) => IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Reset',
          iconSize: 22,
          onPressed: fn,
        );

    switch (_currentStage) {
      case PipelineStage.stage1:
        return [
          run(_runStage1),
          if (_hasStage1) reset(_resetFromStage1),
        ];
      case PipelineStage.stage2:
        return [
          run(_runStage2),
          if (_hasStage2) reset(_resetFromStage2),
        ];
      case PipelineStage.stage3:
        return [
          run(_runStage3),
          if (_hasStage3) reset(_resetFromStage3),
        ];
      case PipelineStage.selectFile:
        return [];
    }
  }

  Widget _buildMobileDrawer() {
    return Drawer(
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
              ),
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  'Pipeline Stages',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            _buildStageItem(
              PipelineStage.selectFile,
              _inputImage != null,
              subtitle: _inputImage?.path.split('/').last ?? 'No file selected',
              onCloseDrawer: () => Navigator.pop(context),
            ),
            _buildStageItem(
              PipelineStage.stage1,
              _hasStage1,
              subtitle: _hasStage1 ? 'Warped plate ready' : 'Pending',
              onCloseDrawer: () => Navigator.pop(context),
            ),
            _buildStageItem(
              PipelineStage.stage2,
              _hasStage2,
              subtitle: _hasStage2 ? '${_warpedDetection?.warpedBoxes.length ?? 0} wells' : 'Pending',
              onCloseDrawer: () => Navigator.pop(context),
            ),
            _buildStageItem(
              PipelineStage.stage3,
              _hasStage3,
              subtitle: _hasStage3 ? 'Classification done' : 'Pending',
              onCloseDrawer: () => Navigator.pop(context),
            ),
            const Divider(),
            if (_hasStage3)
              ListTile(
                leading: const Icon(Icons.assessment),
                title: const Text('View Results'),
                onTap: () {
                  Navigator.pop(context);
                  _viewFinalResults();
                },
              ),
            // Run Full Pipeline button
            if (_inputImage != null)
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Run Full Pipeline'),
                subtitle: const Text('Run all stages automatically'),
                onTap: () {
                  Navigator.pop(context);
                  _runFullPipelineSequential();
                },
              ),
            // Batch processing button
            if (_inputImages.length > 1)
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: Text('Process All ${_inputImages.length} Images'),
                subtitle: const Text('Run batch processing'),
                onTap: () {
                  Navigator.pop(context);
                  _runBatchPipeline();
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 280,
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                'Pipeline Stages',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Divider(),
            _buildStageItem(
              PipelineStage.selectFile,
              _inputImage != null,
              subtitle: _inputImage?.path.split('/').last ?? 'No file selected',
            ),
            _buildStageItem(
              PipelineStage.stage1,
              _hasStage1,
              subtitle: _hasStage1 ? 'Warped plate ready' : 'Pending',
            ),
            _buildStageItem(
              PipelineStage.stage2,
              _hasStage2,
              subtitle: _hasStage2 ? '${_warpedDetection?.warpedBoxes.length ?? 0} wells' : 'Pending',
            ),
            _buildStageItem(
              PipelineStage.stage3,
              _hasStage3,
              subtitle: _hasStage3 ? 'Classification done' : 'Pending',
            ),
            const SizedBox(height: 8),
            if (_hasStage3)
              Padding(
                padding: const EdgeInsets.fromLTRB(16.0, 0, 16.0, 16.0),
                child: FilledButton.icon(
                  onPressed: _viewFinalResults,
                  icon: const Icon(Icons.assessment),
                  label: const Text('View Results'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageItem(
    PipelineStage stage,
    bool isComplete, {
    String? subtitle,
    VoidCallback? onCloseDrawer,
  }) {
    final isSelected = _currentStage == stage;

    return ListTile(
      leading: Icon(
        stage.icon,
        color: isSelected
            ? Theme.of(context).colorScheme.primary
            : (isComplete ? Colors.green : Colors.grey),
      ),
      title: Text(
        stage.label,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: const TextStyle(fontSize: 12),
            )
          : null,
      selected: isSelected,
      onTap: () {
        setState(() => _currentStage = stage);
        if (onCloseDrawer != null) {
          onCloseDrawer();
        }
      },
      trailing: isComplete
          ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
          : null,
    );
  }

  Widget _buildCurrentStage() {
    return Stack(
      children: [
        // Stage content fills the entire body
        Positioned.fill(child: _buildStageContent()),
        // Compact status chip overlay (top-center) while processing
        if (_statusText.isNotEmpty)
          Positioned(
            top: 6,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _statusMessage,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStageContent() {
    switch (_currentStage) {
      case PipelineStage.selectFile:
        return _buildFileSelectStage();
      case PipelineStage.stage1:
        return _buildStage1Content();
      case PipelineStage.stage2:
        return _buildStage2Content();
      case PipelineStage.stage3:
        return _buildStage3Content();
    }
  }

  Widget _buildFileSelectStage() {
    final hasImage = _inputImage != null;
    final iconSize = _getResponsiveIconSize(context);
    final fileName = hasImage ? _inputImage!.path.split('/').last : '';
    final imageCount = _inputImages.length;
    final batchInfo = imageCount > 1
        ? ' (${_currentImageIndex + 1}/$imageCount)'
        : '';

    return Stack(
      children: [
        // Image preview (or placeholder icon when no image yet)
        hasImage
            ? Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 72),
                child: Center(
                  child: InteractiveViewer(
                    child: Image.file(_inputImage!, fit: BoxFit.contain),
                  ),
                ),
              )
            : Center(
                child: Icon(
                  Icons.folder_open,
                  size: iconSize,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),

        // Filename badge (top-left)
        if (hasImage)
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$fileName$batchInfo',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

        // Action buttons (bottom-center)
        Positioned(
          bottom: 8,
          left: 0,
          right: 0,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Camera button
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickCameraImage,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
                const SizedBox(width: 12),
                // Gallery button
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickInputFile,
                  icon: Icon(hasImage ? Icons.swap_horiz : Icons.photo_library),
                  label: Text(hasImage ? 'Change' : 'Gallery'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Processing overlay
        if (_statusText.isNotEmpty)
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }

  Widget _buildStage1Content() {
    if (_inputImage == null) {
      return Center(
        child: Text(
          'Please select an image first',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    return _hasStage1
        ? _buildStage1Output()
        : Center(
            child: Text(
              'Tap ▶ in the top bar to run Stage 1',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
  }

  Widget _buildStage1Output() {
    return Row(
      children: [
        // Original image with detected corners
        Expanded(
          child: Stack(
            children: [
              _originalWithCorners != null
                  ? Center(
                      child: InteractiveViewer(
                        child: Image.file(_originalWithCorners!, fit: BoxFit.contain),
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Original + Corners',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // Warped plate
        Expanded(
          child: Stack(
            children: [
              _warpedImage != null
                  ? Center(
                      child: InteractiveViewer(
                        child: Image.file(_warpedImage!, fit: BoxFit.contain),
                      ),
                    )
                  : const Center(child: CircularProgressIndicator()),
              Positioned(
                top: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Warped Plate',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStage2Content() {
    if (!_hasStage1) {
      return Center(
        child: Text(
          'Please complete Stage 1 first',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    return _hasStage2
        ? _buildStage2Output()
        : Center(
            child: Text(
              'Tap ▶ in the top bar to run Stage 2',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
  }

  Widget _buildStage2Output() {
    final wellCount = _warpedDetection?.warpedBoxes.length ?? 0;

    return Stack(
      children: [
        // Full-screen visualization image
        _stage2Visualization != null
            ? Center(
                child: InteractiveViewer(
                  child: Image.file(
                    _stage2Visualization!,
                    fit: BoxFit.contain,
                  ),
                ),
              )
            : const Center(child: CircularProgressIndicator()),

        // Well count badge overlay (top-right)
        Positioned(
          top: 8,
          right: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '$wellCount wells',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStage3Content() {
    if (!_hasStage2) {
      return Center(
        child: Text(
          'Please complete Stage 2 first',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
      );
    }
    return _hasStage3
        ? _buildStage3Output()
        : Center(
            child: Text(
              'Tap ▶ in the top bar to run Stage 3',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          );
  }

  Widget _buildStage3Output() {
    final total = _warpedDetection?.warpedBoxes.length ?? 0;

    return Stack(
      children: [
        // Full-screen color-coded classification visualization
        _finalVisualization != null
            ? Center(
                child: InteractiveViewer(
                  child: Image.file(
                    _finalVisualization!,
                    fit: BoxFit.contain,
                  ),
                ),
              )
            : const Center(child: CircularProgressIndicator()),

        // Counts badge overlay (top-right)
        if (_counts != null)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'G:${_counts!['growth'] ?? 0}  N:${_counts!['no_growth'] ?? 0}  A:${_counts!['no_agar'] ?? 0}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

        // View Results button (bottom-center)
        Positioned(
          bottom: 8,
          left: 8,
          right: 8,
          child: Center(
            child: FilledButton.icon(
              onPressed: _viewFinalResults,
              icon: const Icon(Icons.assessment),
              label: const Text('View Detailed Results'),
            ),
          ),
        ),
      ],
    );
  }

  String get _statusText => _isProcessing ? _statusMessage : '';

  // ─────────────────────────────────────────────
  // Pipeline execution methods
  // ─────────────────────────────────────────────

  Future<void> _pickInputFile() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage();

    if (picked.isNotEmpty) {
      setState(() {
        _inputImages = picked.map((x) => File(x.path)).toList();
        _currentImageIndex = 0;
        _batchResults = [];
        _imageStatus = {};

        // Initialize status for all images
        for (int i = 0; i < _inputImages.length; i++) {
          _imageStatus[i] = 'Pending';
        }

        // Reset all downstream stages for current image
        _resetCurrentImageStages();
      });
    }
  }

  Future<void> _pickCameraImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );

    if (picked != null) {
      setState(() {
        _inputImages = [File(picked.path)];
        _currentImageIndex = 0;
        _batchResults = [];
        _imageStatus = {0: 'Pending'};
        _resetCurrentImageStages();
      });
    }
  }

  void _resetCurrentImageStages() {
    _corners = null;
    _originalWithCorners = null;
    _warpedImage = null;
    _warpedDetection = null;
    _stage2Visualization = null;
    _classes = null;
    _counts = null;
    _finalVisualization = null;
  }

  Future<void> _runBatchPipeline() async {
    for (int i = 0; i < _inputImages.length; i++) {
      setState(() {
        _currentImageIndex = i;
        _imageStatus[i] = 'Processing ${i+1}/${_inputImages.length}...';
        _statusMessage = 'Image ${i+1}/${_inputImages.length}';
      });

      // Reset stages for this image
      _resetCurrentImageStages();

      // Run full pipeline on current image
      await _runFullPipelineOnCurrent();

      _imageStatus[i] = 'Completed';
    }

    setState(() {
      _statusMessage = 'Batch completed: ${_batchResults.length} images';
    });

    _showBatchCompletionDialog();
  }

  Future<void> _runFullPipelineOnCurrent() async {
    if (_inputImage == null) return;

    try {
      // Stage 1
      await _runStage1();
      if (!mounted) return;

      // Stage 2
      await _runStage2();
      if (!mounted) return;

      // Stage 3
      await _runStage3(showDialog: false);
      if (!mounted) return;

      // Store result
      if (_classes != null && _counts != null && _finalVisualization != null) {
        final result = PipelineResult(
          imagePath: _inputImage!.path,
          annotatedPath: _finalVisualization!.path,
          boxes: _warpedDetection?.warpedBoxes.map((box) => {
            'x1': box['x1'],
            'y1': box['y1'],
            'x2': box['x2'],
            'y2': box['y2'],
          }).toList() ?? [],
          classes: _classes!,
          counts: _counts!,
          processingTimeMs: 0.0,
          corners: _corners ?? [],
          mode: DetectionMode.yoloDetect,
        );
        _batchResults.add(result);
      }
    } catch (e) {
      print('[Batch] Error processing image $_currentImageIndex: $e');
      _imageStatus[_currentImageIndex] = 'Failed: $e';
    }
  }

  void _showBatchCompletionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Batch Processing Complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total images: ${_inputImages.length}'),
            const SizedBox(height: 8),
            Text('Successfully processed: ${_batchResults.length}'),
            const SizedBox(height: 8),
            Text('Failed: ${_inputImages.length - _batchResults.length}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          if (_batchResults.isNotEmpty)
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                // TODO: Show results grid or save to project
              },
              child: const Text('View Results'),
            ),
        ],
      ),
    );
  }


  Future<void> _runStage1() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Running Stage 1: Corner detection & warp...';
    });

    try {
      await _inferenceService.initialize();
      final detection = await _inferenceService.detectAutoGrid(_inputImage!.path);

      // Warp and save warped plate image
      final warpedPath = await _inferenceService.warpPlateAndSave(
        _inputImage!.path,
        detection.corners,
      );

      // Annotate original image with detected corners (Stage 1 visualization)
      final origBytes = await _inputImage!.readAsBytes();
      final origImage = img.decodeImage(origBytes);
      File? annotatedOriginal;
      if (origImage != null) {
        final annotated = ImageUtils.drawCorners(origImage, detection.corners);
        final annBytes = Uint8List.fromList(img.encodeJpg(annotated, quality: 90));
        final annFile = await ImageUtils.saveImage(
          annBytes,
          'stage1_corners_${DateTime.now().millisecondsSinceEpoch}.jpg',
        );
        annotatedOriginal = File(annFile.path);
      }

      if (mounted) {
        setState(() {
          _corners = detection.corners;
          _originalWithCorners = annotatedOriginal;
          _warpedImage = File(warpedPath);
          _isProcessing = false;
          _statusMessage = '';
        });

        // Auto-advance to Stage 2 if enabled
        if (_autoRunAllStages) {
          await _runStage2();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 1 failed: $e')),
        );
      }
    }
  }

  Future<void> _runStage2() async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Running Stage 2: Well detection...';
    });

    try {
      await _inferenceService.initialize();

      // Detect wells in WARPED coordinate space (matches full_pipeline.ipynb)
      final detection = await _inferenceService.detectYoloWarped(
        _inputImage!.path,
        _corners!,
      );

      print('[Pipeline] Stage 2 detected ${detection.warpedBoxes.length} wells (warped space)');

      // Draw detection boxes directly on warped image — coords match perfectly
      final placeholderClasses = List<int>.filled(detection.warpedBoxes.length, 0);
      final annotated = ImageUtils.drawWellBoxes(
          detection.warpedImage, detection.warpedBoxes, placeholderClasses);
      final visBytes = Uint8List.fromList(img.encodePng(annotated));
      final visFile = await ImageUtils.saveImage(
        visBytes,
        'stage2_detection_${DateTime.now().millisecondsSinceEpoch}.png',
      );

      print('[Pipeline] Stage 2 visualization saved to: ${visFile.path}');

      if (mounted) {
        setState(() {
          _warpedDetection = detection;
          _stage2Visualization = File(visFile.path);
          _isProcessing = false;
          _statusMessage = '';
        });

        // Auto-advance to Stage 3 if enabled
        if (_autoRunAllStages) {
          await _runStage3();
        }
      }
    } catch (e, stackTrace) {
      print('[Pipeline] Stage 2 failed: $e');
      print(stackTrace);
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 2 failed: $e')),
        );
      }
    }
  }

  /// Auto-save the completed run to History (every run: single, sequential, batch)
  Future<void> _saveRunToHistory() async {
    if (_inputImage == null || _classes == null || _counts == null || _finalVisualization == null) {
      return;
    }
    try {
      final entry = HistoryEntry(
        imagePath: _inputImage!.path,
        annotatedPath: _finalVisualization!.path,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        totalWells: _warpedDetection?.warpedBoxes.length ?? 0,
        growthCount: _counts!['growth'] ?? 0,
        noGrowthCount: _counts!['no_growth'] ?? 0,
        noAgarCount: _counts!['no_agar'] ?? 0,
        processingTimeMs: null,
        projectId: null,
      );
      await _db.insertResult(entry);
    } catch (e) {
      print('[Pipeline] Auto-save to history failed: $e');
    }
  }

  Future<void> _runStage3({bool showDialog = true}) async {
    setState(() {
      _isProcessing = true;
      _statusMessage = 'Running Stage 3: Classifying wells...';
    });

    try {
      // Classify warped wells — crops from warped plate using warped boxes,
      // draws color-coded overlay on the warped plate (perfect alignment)
      final result = await _inferenceService.classifyWarpedWells(_warpedDetection!);

      if (mounted) {
        setState(() {
          _classes = result.classes;
          _counts = result.counts;
          _finalVisualization = File(result.annotatedPath);
          _isProcessing = false;
          _statusMessage = '';
        });

        // Every completed run is auto-saved to History (no option needed)
        await _saveRunToHistory();

        if (showDialog) {
          _showCompletionDialog();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 3 failed: $e')),
        );
      }
    }
  }

  void _resetFromStage1() {
    setState(() {
      _corners = null;
      _originalWithCorners = null;
      _warpedImage = null;
      _warpedDetection = null;
      _stage2Visualization = null;
      _classes = null;
      _counts = null;
      _finalVisualization = null;
    });
  }

  void _resetFromStage2() {
    setState(() {
      _warpedDetection = null;
      _stage2Visualization = null;
      _classes = null;
      _counts = null;
      _finalVisualization = null;
    });
  }

  void _resetFromStage3() {
    setState(() {
      _classes = null;
      _counts = null;
      _finalVisualization = null;
    });
  }

  void _viewFinalResults() {
    if (_hasStage3 && _finalVisualization != null) {
      final pipelineResult = PipelineResult(
        imagePath: _warpedDetection!.warpedImagePath,
        annotatedPath: _finalVisualization!.path,
        boxes: _warpedDetection!.warpedBoxes,
        classes: _classes!,
        counts: _counts!,
        processingTimeMs: 0.0,
        corners: _corners!,
        mode: DetectionMode.yoloDetect,
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => ResultsScreen(result: pipelineResult),
        ),
      );
    }
  }

  Future<void> _runFullPipelineSequential() async {
    if (_inputImage == null || _isProcessing) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = 'Running full pipeline...';
    });

    try {
      // Stage 1
      await _runStage1();
      if (!mounted) return;

      // Stage 2
      await _runStage2();
      if (!mounted) return;

      // Stage 3
      await _runStage3(showDialog: false);
      if (!mounted) return;

      setState(() {
        _statusMessage = 'Pipeline completed!';
      });

      _showCompletionDialog();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pipeline failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _statusMessage = '';
        });
      }
    }
  }

  void _showCompletionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pipeline Complete'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total wells: ${_warpedDetection?.warpedBoxes.length ?? 0}'),
            const SizedBox(height: 8),
            if (_counts != null) ...[
              Text('Growth: ${_counts!['growth']}'),
              Text('NoGrowth: ${_counts!['no_growth']}'),
              Text('NoAgar: ${_counts!['no_agar']}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Stay Here'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              _viewFinalResults();
            },
            child: const Text('View Results'),
          ),
        ],
      ),
    );
  }
}
