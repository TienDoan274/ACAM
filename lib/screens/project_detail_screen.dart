/// ProjectDetailScreen - Main workspace for a project with integrated pipeline
library project_detail_screen;

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:csv/csv.dart';

import '../models/database_helper.dart';
import '../models/inference_service.dart';
import '../utils/constants.dart';
import '../utils/image_utils.dart';
import 'results_screen.dart';

class ProjectDetailScreen extends StatefulWidget {
  final ProjectEntry project;

  const ProjectDetailScreen({super.key, required this.project});

  @override
  State<ProjectDetailScreen> createState() => _ProjectDetailScreenState();
}

enum ProjectStage {
  selectFile('Select Image', Icons.add_photo_alternate),
  stage1('Stage 1: Warp', Icons.crop_rotate),
  stage2('Stage 2: Detect', Icons.grid_on),
  stage3('Stage 3: Classify', Icons.science),
  results('Results', Icons.analytics);

  final String label;
  final IconData icon;
  const ProjectStage(this.label, this.icon);
}

class _ProjectDetailScreenState extends State<ProjectDetailScreen> {
  // Decode cap for pipeline images: full-res (~4000px) exceeds GLES max
  // texture size (4096) and stalls the raster thread — scrolling freezes.
  static const int _imageCacheWidth = 2048;

  ProjectStage _currentStage = ProjectStage.results; // Start at Results to show existing data
  final DatabaseHelper _db = DatabaseHelper();
  final InferenceService _inference = InferenceService();

  // Batch state
  List<File> _inputImages = [];
  int _currentImageIndex = 0;
  Map<int, PipelineResult> _batchResults = {};

  // Pipeline state (for current image)
  File? get _inputImage => _currentImageIndex < _inputImages.length
      ? _inputImages[_currentImageIndex]
      : null;
  List<Map<String, double>>? _corners;
  File? _originalWithCorners;
  File? _warpedImage;
  WarpedDetection? _warpedDetection;
  File? _stage2Visualization;
  List<int>? _classes;
  Map<String, int>? _counts;
  File? _finalVisualization;

  bool _isProcessing = false;
  String _statusMessage = '';

  // Results list
  List<HistoryEntry> _projectResults = [];
  bool _isLoadingResults = true;

  @override
  void initState() {
    super.initState();
    _loadProjectResults();
  }

  Future<void> _loadProjectResults() async {
    if (widget.project.id == null) return;

    setState(() => _isLoadingResults = true);
    try {
      final results = await _db.getResultsByProject(widget.project.id!);
      if (mounted) {
        setState(() {
          _projectResults = results;
          _isLoadingResults = false;
          // If no results yet, skip empty state → go straight to Select Image
          if (results.isEmpty && _currentStage == ProjectStage.results) {
            _currentStage = ProjectStage.selectFile;
          }
        });
      }
    } catch (e) {
      print('[ProjectDetail] Error loading results: $e');
      if (mounted) {
        setState(() => _isLoadingResults = false);
      }
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
        _batchResults = {};
        _resetCurrentImageStages();
      });
    }
  }

  Future<void> _pickGalleryImages() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage();

    if (picked.isNotEmpty) {
      setState(() {
        _inputImages = picked.map((x) => File(x.path)).toList();
        _currentImageIndex = 0;
        _batchResults = {};
        _resetCurrentImageStages();
      });
    }
  }

  Future<void> _runFullPipeline() async {
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
      await _runStage3();
      if (!mounted) return;

      // Save result to project
      await _saveCurrentResult();

      setState(() {
        _statusMessage = 'Pipeline completed!';
      });

      // Auto-switch to Results stage to see the new result
      if (mounted) {
        setState(() => _currentStage = ProjectStage.results);
      }

      // Show completion dialog
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

  Future<void> _runStage1() async {
    if (_inputImage == null) return;

    try {
      await _inference.initialize();
      final detection = await _inference.detectAutoGrid(_inputImage!.path);

      final warpedPath = await _inference.warpPlateAndSave(
        _inputImage!.path,
        detection.corners,
      );

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
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 1 failed: $e')),
        );
        rethrow;
      }
    }
  }

  Future<void> _runStage2() async {
    if (_inputImage == null || _corners == null) return;

    try {
      await _inference.initialize();

      final detection = await _inference.detectYoloWarped(
        _inputImage!.path,
        _corners!,
      );

      final placeholderClasses = List<int>.filled(detection.warpedBoxes.length, 0);
      final annotated = ImageUtils.drawWellBoxes(
          detection.warpedImage, detection.warpedBoxes, placeholderClasses);
      final visBytes = Uint8List.fromList(img.encodePng(annotated));
      final visFile = await ImageUtils.saveImage(
        visBytes,
        'stage2_detection_${DateTime.now().millisecondsSinceEpoch}.png',
      );

      if (mounted) {
        setState(() {
          _warpedDetection = detection;
          _stage2Visualization = File(visFile.path);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 2 failed: $e')),
        );
        rethrow;
      }
    }
  }

  Future<void> _runStage3() async {
    if (_warpedDetection == null) return;

    try {
      final result = await _inference.classifyWarpedWells(_warpedDetection!);

      if (mounted) {
        setState(() {
          _classes = result.classes;
          _counts = result.counts;
          _finalVisualization = File(result.annotatedPath);
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Stage 3 failed: $e')),
        );
        rethrow;
      }
    }
  }

  Future<void> _saveCurrentResult() async {
    if (_classes == null || _counts == null || _finalVisualization == null) return;

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
        projectId: widget.project.id,
      );

      await _db.insertResult(entry);
      await _loadProjectResults();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Saved to ${widget.project.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e'),
            backgroundColor: Colors.red,
          ),
        );
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
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() => _currentStage = ProjectStage.results);
            },
            child: const Text('View Results'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportProject() async {
    if (widget.project.id == null) return;

    try {
      // Export project data to JSON
      final results = await _db.getResultsByProject(widget.project.id!);

      final exportData = {
        'project': {
          'name': widget.project.name,
          'description': widget.project.description,
          'color': widget.project.color,
          'created_at': widget.project.createdAt,
          'updated_at': widget.project.updatedAt,
        },
        'results': results.map((r) => {
          'image_path': r.imagePath,
          'annotated_path': r.annotatedPath,
          'timestamp': r.timestamp,
          'total_wells': r.totalWells,
          'growth_count': r.growthCount,
          'no_growth_count': r.noGrowthCount,
          'no_agar_count': r.noAgarCount,
          'processing_time_ms': r.processingTimeMs,
        }).toList(),
      };

      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final file = File('${directory.path}/${widget.project.name}_$timestamp.json');
      await file.writeAsString(jsonEncode(exportData));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported: ${file.path}')),
        );

        // Share the file
        await Share.shareXFiles([XFile(file.path)], text: 'Project export: ${widget.project.name}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        backgroundColor: Color(widget.project.color),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
            tooltip: 'Open stages menu',
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload),
            onPressed: _exportProject,
            tooltip: 'Export Project',
          ),
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
            tooltip: 'Back to Projects',
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: _buildCurrentStage(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: (_isProcessing || _inputImage == null) ? null : _runFullPipeline,
        icon: const Icon(Icons.play_arrow),
        label: Text(
          _inputImage == null
              ? 'Select Image First'
              : (_currentStage == ProjectStage.selectFile
                  ? 'Run Full Pipeline'
                  : 'Run New Analysis'),
        ),
        backgroundColor: _inputImage == null
            ? Colors.grey
            : Color(widget.project.color),
        tooltip: _inputImage == null
            ? 'Choose an image from gallery or camera first'
            : 'Run full pipeline on selected image',
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(
                color: Color(widget.project.color),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.project.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Results: ${_projectResults.length}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildStageItem(ProjectStage.selectFile),
            _buildStageItem(ProjectStage.stage1),
            _buildStageItem(ProjectStage.stage2),
            _buildStageItem(ProjectStage.stage3),
            _buildStageItem(ProjectStage.results),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.refresh),
              title: const Text('Refresh Results'),
              onTap: () {
                Navigator.pop(context);
                _loadProjectResults();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStageItem(ProjectStage stage) {
    final bool isComplete = stage == ProjectStage.selectFile && _inputImage != null;
    final bool isSelected = _currentStage == stage;

    return ListTile(
      leading: Icon(
        stage.icon,
        color: isSelected
            ? Color(widget.project.color)
            : (isComplete ? Colors.green : Colors.grey),
      ),
      title: Text(
        stage.label,
        style: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: isSelected,
      onTap: () {
        setState(() => _currentStage = stage);
        Navigator.pop(context);
      },
      trailing: isComplete
          ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
          : null,
    );
  }

  Widget _buildCurrentStage() {
    return Stack(
      children: [
        Positioned.fill(child: _buildStageContent()),
        if (_statusMessage.isNotEmpty)
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
                    if (_isProcessing)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                    if (_isProcessing) const SizedBox(width: 8),
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
      case ProjectStage.selectFile:
        return _buildFileSelectStage();
      case ProjectStage.stage1:
        return _buildStage1Content();
      case ProjectStage.stage2:
        return _buildStage2Content();
      case ProjectStage.stage3:
        return _buildStage3Content();
      case ProjectStage.results:
        return _buildResultsListStage();
    }
  }

  Widget _buildFileSelectStage() {
    final hasImage = _inputImage != null;
    final imageCount = _inputImages.length;
    final fileName = hasImage ? _inputImage!.path.split('/').last : '';
    final batchInfo = imageCount > 1
        ? ' (${_currentImageIndex + 1}/$imageCount)'
        : '';

    return Stack(
      children: [
        // Image gallery (horizontal scroll) or placeholder
        hasImage
            ? Padding(
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 72),
                child: Column(
                  children: [
                    // Image preview with page indicator
                    Expanded(
                      child: Stack(
                        children: [
                          // Main image viewer
                          InteractiveViewer(
                            child: Image.file(_inputImage!,
                                fit: BoxFit.contain,
                                cacheWidth: _imageCacheWidth),
                          ),
                          // Left/right navigation arrows (only for multiple images)
                          if (imageCount > 1) ...[
                            Positioned(
                              left: 8,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: IconButton(
                                  iconSize: 48,
                                  icon: const Icon(Icons.chevron_left, color: Colors.white70),
                                  onPressed: _currentImageIndex > 0
                                      ? () => setState(() => _currentImageIndex--)
                                      : null,
                                ),
                              ),
                            ),
                            Positioned(
                              right: 8,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: IconButton(
                                  iconSize: 48,
                                  icon: const Icon(Icons.chevron_right, color: Colors.white70),
                                  onPressed: _currentImageIndex < imageCount - 1
                                      ? () => setState(() => _currentImageIndex++)
                                      : null,
                                ),
                              ),
                            ),
                          ],
                          // Filename badge (top-left)
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
                        ],
                      ),
                    ),
                    // Thumbnail strip (horizontal scroll, shows 3 at a time)
                    if (imageCount > 1)
                      SizedBox(
                        height: 80,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: imageCount,
                          itemBuilder: (context, index) {
                            final isSelected = index == _currentImageIndex;
                            return GestureDetector(
                              onTap: () => setState(() => _currentImageIndex = index),
                              child: Container(
                                width: 100,
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: isSelected
                                        ? Color(widget.project.color)
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.file(
                                    _inputImages[index],
                                    fit: BoxFit.cover,
                                    cacheWidth: 200,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              )
            : Center(
                child: Icon(
                  Icons.add_photo_alternate,
                  size: 64,
                  color: Color(widget.project.color),
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
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickCameraImage,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _pickGalleryImages,
                  icon: const Icon(Icons.photo_library),
                  label: Text(hasImage ? 'Change' : 'Gallery'),
                ),
              ],
            ),
          ),
        ),
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
    if (_corners == null) {
      return Center(
        child: Text(
          'Tap ▶ "Run Full Pipeline" to process',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: _originalWithCorners != null
              ? InteractiveViewer(
                  child: Image.file(_originalWithCorners!,
                      fit: BoxFit.contain, cacheWidth: _imageCacheWidth),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
        Expanded(
          child: _warpedImage != null
              ? InteractiveViewer(
                  child: Image.file(_warpedImage!,
                      fit: BoxFit.contain, cacheWidth: _imageCacheWidth),
                )
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }

  Widget _buildStage2Content() {
    if (_warpedDetection == null) {
      return const Center(child: Text('Run Stage 1 first'));
    }
    return Stack(
      children: [
        _stage2Visualization != null
            ? InteractiveViewer(
                child: Image.file(
                  _stage2Visualization!,
                  fit: BoxFit.contain,
                  cacheWidth: _imageCacheWidth,
                ),
              )
            : const Center(child: CircularProgressIndicator()),
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
              '${_warpedDetection?.warpedBoxes.length ?? 0} wells',
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
    if (_finalVisualization == null) {
      return const Center(child: Text('Run Stage 2 first'));
    }
    return Stack(
      children: [
        InteractiveViewer(
          child: Image.file(
            _finalVisualization!,
            fit: BoxFit.contain,
            cacheWidth: _imageCacheWidth,
          ),
        ),
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
      ],
    );
  }

  Widget _buildResultsListStage() {
    if (_isLoadingResults) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_projectResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.analytics_outlined,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'No results yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Run pipeline to add results to this project',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                setState(() => _currentStage = ProjectStage.selectFile);
              },
              icon: const Icon(Icons.add_photo_alternate),
              label: const Text('Select Image to Run'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _projectResults.length,
      itemBuilder: (context, index) {
        final entry = _projectResults[index];
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Color(widget.project.color),
              child: Text('${entry.totalWells}'),
            ),
            title: Text(entry.formattedDate),
            subtitle: Text(entry.countsDisplay),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility),
                  onPressed: () => _viewResult(entry),
                  tooltip: 'View',
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => _deleteResult(entry.id!),
                  tooltip: 'Delete',
                  color: Colors.red,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _viewResult(HistoryEntry entry) async {
    final result = PipelineResult(
      imagePath: entry.imagePath,
      annotatedPath: entry.annotatedPath ?? '',
      boxes: [],
      classes: [],
      counts: {
        'growth': entry.growthCount,
        'no_growth': entry.noGrowthCount,
        'no_agar': entry.noAgarCount,
      },
      processingTimeMs: entry.processingTimeMs ?? 0,
      corners: [],
      mode: DetectionMode.autoGrid,
    );

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ResultsScreen(result: result),
      ),
    );

    _loadProjectResults();
  }

  Future<void> _deleteResult(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Result'),
        content: const Text('Are you sure?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _db.deleteResult(id);
      _loadProjectResults();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Result deleted')),
        );
      }
    }
  }
}
