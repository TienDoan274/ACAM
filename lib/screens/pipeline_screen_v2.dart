/// PipelineWorkspaceScreen - per-project working area
///
/// Layout (fullscreen page pushed from Projects tab):
/// - Left sidebar (~40%): toolbar (add / select-all / Run Full) + image list
///   with live thumbnails and per-image status icons
/// - Right content (~60%): large original preview + one card per stage.
///   Each completed stage renders its visualization inline (fixed height,
///   thumbnail decode) with a zoom badge opening the fullscreen viewer;
///   the Results panel adds a one-line summary and a "View Detail Result"
///   button that pushes a fullscreen page with the full statistics.
library pipeline_screen_v2;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/inference_service.dart';
import '../models/database_helper.dart';
import '../models/stage_meta.dart';
import '../utils/image_utils.dart';
import '../utils/pipeline_config.dart';
import '../utils/plate_geometry.dart' show warningText;
import '../utils/stage2_style.dart';
import '../widgets/plate_edit_canvas.dart' show EditImage, prepareEditImage;
import 'manual_corners_screen.dart';
import 'manual_wells_screen.dart';
import 'stage2_viewer_screen.dart';

// ──────────────────────────────────────────────────────────────────────────────
// Fullscreen pinch-zoom image viewer
// ──────────────────────────────────────────────────────────────────────────────

class ImageViewerScreen extends StatefulWidget {
  final String imagePath;
  final String title;

  const ImageViewerScreen({super.key, required this.imagePath, this.title = ''});

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  bool _chromeVisible = true;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Decode at roughly screen resolution x2 — sharp when zoomed without
    // decoding multi-megabyte plates in full.
    final cacheW = (mq.size.width * mq.devicePixelRatio)
        .clamp(1024.0, 2560.0)
        .round();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _chromeVisible
          ? AppBar(
              toolbarHeight: 44,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(widget.title,
                  style: const TextStyle(fontSize: 14),
                  overflow: TextOverflow.ellipsis),
            )
          : null,
      body: GestureDetector(
        // Tap gives visible feedback (chrome toggle) so a fullscreen image
        // never feels like the whole app stopped responding.
        onTap: () => setState(() => _chromeVisible = !_chromeVisible),
        child: Center(
          child: InteractiveViewer(
            panEnabled: true,
            minScale: 0.5,
            maxScale: 10,
            child: Image.file(
              File(widget.imagePath),
              fit: BoxFit.contain,
              cacheWidth: cacheW,
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  size: 48, color: Colors.white24),
            ),
          ),
        ),
      ),
    );
  }
}

void _openImageViewer(BuildContext context, String path, String title) {
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ImageViewerScreen(imagePath: path, title: title),
    ),
  );
}

/// Opens the fullscreen viewer only when the enclosing scrollable is at
/// rest. A quick touch landing on a preview while the list is flinging
/// used to open the viewer mid-scroll — which fills the screen with a
/// similar-looking image whose pan is clamped at fit scale, reading as
/// "the app stopped scrolling".
void _openViewerIfNotScrolling(BuildContext context, String path, String title) {
  if (Scrollable.recommendDeferredLoadingForContext(context)) return;
  _openImageViewer(context, path, title);
}

/// Isolate job: decode a (potentially huge) source image, downscale and save
/// as JPEG thumbnail. Runs off the UI isolate so scrolling never stalls.
Future<Map<String, String?>> createThumbJob(Map<String, dynamic> args) async {
  final src = args['src'] as String;
  final dst = args['dst'] as String;
  final width = args['width'] as int;
  try {
    final bytes = await File(src).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return {'path': null};
    final w = width < decoded.width ? width : decoded.width;
    final resized =
        w == decoded.width ? decoded : img.copyResize(decoded, width: w);
    await File(dst)
        .writeAsBytes(Uint8List.fromList(img.encodeJpg(resized, quality: 82)));
    return {'path': dst};
  } catch (_) {
    return {'path': null};
  }
}

/// Isolate job: draw the well-box overlay on a warped plate and encode PNG.
/// The per-pixel overlay copy plus the PNG encode take many seconds at full
/// warp resolution — running them on the UI isolate starved input handling
/// long enough for Android to treat the app as unresponsive (scroll appeared
/// dead right after stage-3 results were shown). Downsamples to 2048px
/// first: full-res warps exceed the GLES max texture size (4096), and
/// displaying such a texture stalls the raster thread.
Uint8List renderAnnotatedVizJob(Map<String, dynamic> args) {
  final source = args['image'] as img.Image;
  final boxes = (args['boxes'] as List).cast<Map<String, dynamic>>();
  final classes = (args['classes'] as List).cast<int>();
  final confRaw = args['confidences'] as Map<Object?, Object?>?;
  final confidences = confRaw == null
      ? null
      : confRaw.map((k, v) => MapEntry(k as int, (v as num).toDouble()));
  // Màu Stage 2 user chọn (Stage2Style.vizPalette) + độ dày nét
  final paletteRaw = args['palette'] as Map<Object?, Object?>?;
  final palette = paletteRaw?.map((k, v) => MapEntry(k as int, (v as List).cast<int>()));
  final lineWidth = (args['lineWidth'] as int?) ?? 1;

  const maxDim = 2048;
  var work = source;
  var scale = 1.0;
  if (work.width > maxDim || work.height > maxDim) {
    scale = maxDim / math.max(work.width, work.height);
    work = img.copyResize(work,
        width: (work.width * scale).round(),
        height: (work.height * scale).round());
  }

  final scaledBoxes = scale == 1.0
      ? boxes
      : [
          for (final b in boxes)
            <String, dynamic>{
              'x1': (b['x1'] as num) * scale,
              'y1': (b['y1'] as num) * scale,
              'x2': (b['x2'] as num) * scale,
              'y2': (b['y2'] as num) * scale,
              'conf': b['conf'],
            },
        ];

  final annotated = ImageUtils.drawWellBoxes(work, scaledBoxes, classes,
      confidences: confidences, palette: palette, lineWidth: lineWidth);
  return Uint8List.fromList(img.encodePng(annotated));
}

/// Isolate job: decode a full-res photo, draw the Stage 1 corner overlay and
/// encode JPEG — three multi-second steps kept off the UI isolate.
Uint8List renderCornersVizJob(Map<String, dynamic> args) {
  // 'image': ảnh đã decode sẵn (Stage 1 vừa decode) — tránh decode lại; không có thì decode 'bytes'
  final decoded = (args['image'] as img.Image?) ?? img.decodeImage(args['bytes'] as Uint8List);
  if (decoded == null) return Uint8List(0);
  final annotated = ImageUtils.drawCorners(
      decoded, (args['corners'] as List).cast<Map<String, double>>());
  return Uint8List.fromList(img.encodeJpg(annotated, quality: 90));
}

/// Kết quả Stage 1 / Stage 2 trong bộ nhớ, truyền giữa các stage của cùng một lần chạy
/// (không phải đọc lại ảnh warp / file box).
class _S1Run {
  final Stage1Meta meta;
  final img.Image warped;
  _S1Run(this.meta, this.warped);
}

class _S2Run {
  final Stage1Meta s1;
  final Stage2Meta meta;
  final img.Image warped;
  final List<Map<String, dynamic>> boxes;
  _S2Run(this.s1, this.meta, this.warped, this.boxes);
}

bool _sameCorners(List<List<double>> a, List<List<double>>? b) {
  if (b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i][0] - b[i][0]).abs() > 1e-6 || (a[i][1] - b[i][1]).abs() > 1e-6) return false;
  }
  return true;
}

// ──────────────────────────────────────────────────────────────────────────────
// Main workspace screen
// ──────────────────────────────────────────────────────────────────────────────

class PipelineWorkspaceScreen extends StatefulWidget {
  final ProjectEntry project;

  const PipelineWorkspaceScreen({super.key, required this.project});

  @override
  State<PipelineWorkspaceScreen> createState() =>
      _PipelineWorkspaceScreenState();
}

class _PipelineWorkspaceScreenState extends State<PipelineWorkspaceScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  final InferenceService _inference = InferenceService();

  List<PipelineImageEntry> _images = [];
  final Set<int> _selectedImageIds = {};
  PipelineImageEntry? _activeImage;

  bool _isLoading = true;
  bool _isProcessing = false;
  String _statusMessage = '';
  Stage2Style _s2Style = Stage2Style.standard; // màu box Stage 2 (chú thích trong card + ảnh preview)

  ProjectEntry get project => widget.project;

  @override
  void initState() {
    super.initState();
    _loadData();
    Stage2Style.load().then((s) {
      if (mounted) setState(() => _s2Style = s);
    });
  }

  Future<void> _loadData() async {
    if (project.id == null) return;
    if (mounted) setState(() => _isLoading = true);

    try {
      await _resetStaleRunningStatuses();
      final images =
          await _db.getPipelineImagesByProject(project.id!);
      developer.log(
          '[Workspace] Loaded ${images.length} images for project ${project.id}',
          name: 'pipeline');

      if (mounted) {
        setState(() {
          _images = images;
          _isLoading = false;
          _selectedImageIds.retainWhere((id) => images.any((i) => i.id == id));
          if (_activeImage != null &&
              !images.any((i) => i.id == _activeImage!.id)) {
            _activeImage = null;
          } else if (_activeImage != null) {
            _activeImage =
                images.firstWhere((i) => i.id == _activeImage!.id);
          }
        });
      }

      // Legacy entries have no thumbnails — generate them off the UI thread
      // so old results scroll as smoothly as new ones.
      unawaited(_backfillThumbs(images));
    } catch (e) {
      print('[Workspace] Error loading data: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Crash recovery: a stage left in 'running' by a sudden app exit (or the
  /// process being swiped from RAM) can never finish on its own — demote it
  /// back to 'pending' so the pipeline resumes from that stage. Completed
  /// stages keep their outputs, so work already done is never repeated.
  /// Only safe to call while nothing is processing (init/refresh).
  Future<void> _resetStaleRunningStatuses() async {
    if (_isProcessing) return;
    final images = await _db.getPipelineImagesByProject(project.id!);
    for (final image in images) {
      if (image.stage1Status == 'running') {
        await _markStage(image.id!, 'stage1', 'pending');
      }
      if (image.stage2Status == 'running') {
        await _markStage(image.id!, 'stage2', 'pending');
      }
      if (image.stage3Status == 'running') {
        await _markStage(image.id!, 'stage3', 'pending');
      }
    }
  }

  /// Ensure the ORIGINAL photo of every entry has a thumbnail file (used by
  /// the sidebar list and the big preview — the only inline images left;
  /// stage visualizations render fullscreen on demand via their buttons).
  /// Heavy decode/resize runs in background isolates; a setState at the end
  /// lets in-view tiles pick up newly created thumbs.
  Future<void> _backfillThumbs(List<PipelineImageEntry> entries) async {
    final candidates = <String>{};
    for (final e in entries) {
      final p = e.imagePath;
      if (p.isEmpty) continue;
      if (!File(_thumbPathOf(p)).existsSync()) candidates.add(p);
    }
    if (candidates.isEmpty) return;

    var created = 0;
    for (final src in candidates) {
      final dst = _thumbPathOf(src);
      try {
        final res = await compute(createThumbJob, {'src': src, 'dst': dst, 'width': 900});
        if (res['path'] != null) {
          created++;
          _thumbKnown.add(src);
        }
      } catch (_) {}
    }
    print('[Workspace] backfill thumbs created=$created/${candidates.length}');

    if (created > 0 && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(project.name,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            onPressed: _showStatusLegend,
            tooltip: 'Status icon legend',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loadData,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.4,
                  child: _buildSidebar(),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _activeImage != null
                      ? _buildMainContent()
                      : _buildEmptyState(),
                ),
              ],
            ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Sidebar: toolbar + flat image list with thumbnails
  // ──────────────────────────────────────────────────────────────────────────

  bool get _allSelected =>
      _images.isNotEmpty && _selectedImageIds.length == _images.length;

  void _toggleSelectAll() {
    setState(() {
      if (_allSelected) {
        _selectedImageIds.clear();
      } else {
        _selectedImageIds.addAll(_images.map((i) => i.id!));
      }
    });
  }

  Widget _buildSidebar() {
    return Column(
      children: [
        // Toolbar: [add][select-all] ......... [Run Full Pipeline (n)]
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: _pickImages,
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 22),
                tooltip: 'Add images',
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              IconButton(
                onPressed: _images.isEmpty ? null : _toggleSelectAll,
                icon: Image.asset(
                  'assets/icons/select_all.png',
                  width: 22,
                  height: 22,
                  // Dim when everything is selected (the action now clears)
                  opacity: AlwaysStoppedAnimation(_allSelected ? 0.45 : 1.0),
                  errorBuilder: (_, __, ___) =>
                      Icon(_allSelected ? Icons.deselect : Icons.select_all,
                          size: 22),
                ),
                tooltip: _allSelected ? 'Clear selection' : 'Select all',
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              IconButton(
                onPressed: (_selectedImageIds.isEmpty || _isProcessing)
                    ? null
                    : _deleteSelectedImages,
                icon: const Icon(Icons.delete_outline, size: 22),
                tooltip: 'Delete selected',
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: (_selectedImageIds.isEmpty || _isProcessing)
                    ? null
                    : _runBatchFullPipeline,
                icon: const Icon(Icons.fast_forward, size: 18),
                label: Text(
                  _selectedImageIds.isEmpty
                      ? 'Run Full'
                      : 'Run Full (${_selectedImageIds.length})',
                  style: const TextStyle(fontSize: 13),
                ),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),

        // Image list
        Expanded(
          child: _images.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_library_outlined,
                          size: 48, color: Colors.grey[400]),
                      const SizedBox(height: 8),
                      Text(
                        'No images yet',
                        style: TextStyle(color: Colors.grey[600], fontSize: 13),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _images.length,
                  itemExtent: 44,
                  itemBuilder: (context, index) =>
                      _buildImageTile(_images[index]),
                ),
        ),

        if (_isProcessing)
          Container(
            padding: const EdgeInsets.all(10),
            width: double.infinity,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildImageTile(PipelineImageEntry image) {
    final isSelected = _selectedImageIds.contains(image.id);
    final isActive = _activeImage?.id == image.id;
    final scheme = Theme.of(context).colorScheme;
    final fileName = image.imagePath.split('/').last;

    Color? bg;
    if (isActive) {
      bg = scheme.secondaryContainer;
    } else if (isSelected) {
      bg = scheme.surfaceVariant;
    }

    return Material(
      color: bg,
      child: InkWell(
        onTap: () => setState(() => _activeImage = image),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedImageIds.add(image.id!);
                      } else {
                        _selectedImageIds.remove(image.id!);
                      }
                    });
                  },
                ),
              ),
              // Thumbnail
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: scheme.outlineVariant, width: 0.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: _lightImage(image.imagePath,
                    fit: BoxFit.cover,
                    cacheW: 160),
              ),
              const SizedBox(width: 6),
              _buildStatusIcon(image),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  fileName,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        isActive ? FontWeight.bold : FontWeight.normal,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 15, color: Colors.grey[500]),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Delete',
                  onPressed: () => _confirmDeleteImage(image),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Sidebar status column: only successful progress gets an icon (green/blue
  /// check per finished stage, purple for the full pipeline). Not-started and
  /// running images render nothing — running feedback lives in the processing
  /// status bar.
  Widget _buildStatusIcon(PipelineImageEntry image) {
    switch (image.overallStatus) {
      case 'stage1_done':
        return const Icon(Icons.check_circle, size: 16, color: Colors.green);
      case 'stage2_done':
        return const Icon(Icons.check_circle, size: 16, color: Colors.blue);
      case 'full_done':
        return const Icon(Icons.done_all, size: 16, color: Colors.purple);
      default:
        return const SizedBox.shrink();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Main content (right panel): large preview + per-stage controls
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildMainContent() {
    if (_activeImage == null) return const SizedBox.shrink();

    return Stack(
      children: [
        Column(
          children: [
            _buildImageHeader(),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12.0),
                children: [
                  // Run control sits at the very top of the detail panel so it
                  // is reachable without scrolling. Always present (disabled
                  // while processing) to keep the list structure constant.
                  _buildRunControl(),
                  const SizedBox(height: 12),
                  _buildOriginalPreview(),
                  const SizedBox(height: 12),
                  _buildStage1Card(),
                  const SizedBox(height: 12),
                  _buildStage2Card(),
                  const SizedBox(height: 12),
                  _buildStage3Card(),
                  const SizedBox(height: 12),
                  // The panel slot is ALWAYS present (placeholder until stage 3
                  // completes) so the list structure never changes mid-run —
                  // inserting/removing children while the user is dragging
                  // triggered render-object detach assertions.
                  _buildResultsPanel(_activeImage!),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ],
        ),
        if (_isProcessing) _buildProcessingOverlay(),
      ],
    );
  }

  Widget _buildImageHeader() {
    final image = _activeImage!;
    final fileName = image.imagePath.split('/').last;
    final statusIcon = _getStatusIconData(image.overallStatus);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (statusIcon != null) ...[
            Icon(statusIcon,
                size: 24, color: _getStatusColor(image.overallStatus)),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _getStatusLabel(image.overallStatus),
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Large tappable preview of the original photo
  Widget _buildOriginalPreview() {
    final image = _activeImage!;
    final fileName = image.imagePath.split('/').last;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: 220,
        width: double.infinity,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(_hasThumb(image.imagePath)
                    ? _thumbPathOf(image.imagePath)
                    : image.imagePath),
                fit: BoxFit.contain,
                cacheWidth: 800,
                errorBuilder: (_, __, ___) => Center(
                  child: Icon(Icons.broken_image,
                      size: 32, color: Colors.grey),
                ),
              ),
              _zoomBadge(() => _openViewerIfNotScrolling(
                  context, image.imagePath, 'Original — $fileName')),
            ],
          ),
        ),
      ),
    );
  }

  /// Small tappable magnifier badge pinned to a preview's corner — the only
  /// way to open the fullscreen viewer from a card.
  Widget _zoomBadge(VoidCallback onTap, {bool small = false}) {
    return Positioned(
      right: small ? 2 : 4,
      bottom: small ? 2 : 4,
      child: Material(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(small ? 4 : 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(small ? 4 : 6),
          child: Padding(
            padding: EdgeInsets.all(small ? 6 : 8),
            child: Icon(Icons.zoom_in,
                size: small ? 16 : 18, color: Colors.white),
          ),
        ),
      ),
    );
  }

  /// Fixed-height inline visualization for a completed stage card. Renders
  /// the thumbnail companion (never the multi-MB original) and offers the
  /// zoom badge as the only way into the fullscreen viewer.
  Widget _stagePreview(String? path, String title, {VoidCallback? onZoom}) {
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 200,
        width: double.infinity,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _lightImage(path, cacheW: 600),
              _zoomBadge(onZoom ?? () => _openViewerIfNotScrolling(context, path, title)),
            ],
          ),
        ),
      ),
    );
  }

  /// Nút chạy / chạy lại + nút phụ (chỉnh tay, reset). Wrap: nhiều nút vẫn vừa panel hẹp.
  Widget _stageActionButtons({
    required bool isComplete,
    required VoidCallback? onRun,
    required String label,
    required Color doneColor,
    bool showRerun = true,
    List<Widget> extra = const [],
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          FilledButton.icon(
            onPressed: _isProcessing ? null : (isComplete ? null : onRun),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(isComplete ? 'Done' : label),
            style: FilledButton.styleFrom(backgroundColor: isComplete ? doneColor : null),
          ),
          if (isComplete && showRerun)
            OutlinedButton.icon(
              onPressed: _isProcessing ? null : onRun,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Rerun'),
            ),
          ...extra,
        ],
      ),
    );
  }

  /// Chip cảnh báo chất lượng kết quả tự động (gợi ý chỉnh tay).
  Widget _warnChip(List<String> codes, String hint) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.amber.shade600),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber, size: 16, color: Colors.orange[800]),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Check result: ${codes.map(warningText).join(', ')}. $hint',
                  style: TextStyle(fontSize: 11, color: Colors.orange[900])),
            ),
          ],
        ),
      ),
    );
  }

  Widget _manualButton(String label, IconData icon, VoidCallback? onPressed) => OutlinedButton.icon(
        onPressed: _isProcessing ? null : onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label),
      );

  Widget _resetAutoButton(VoidCallback onPressed) => TextButton.icon(
        onPressed: _isProcessing ? null : onPressed,
        icon: const Icon(Icons.auto_fix_high, size: 16),
        label: const Text('Reset to auto'),
      );

  Widget _buildStage1Card() {
    final image = _activeImage!;
    final isComplete = image.stage1Status == 'completed';
    final m1 = isComplete ? Stage1Meta.parse(image.stage1Meta) : null;
    final manual = m1?.isManual == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.crop_rotate, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Stage 1 · Warp Grid',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (isComplete) const Icon(Icons.check_circle, color: Colors.green, size: 18),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              !isComplete
                  ? 'Detect corners and warp plate — or draw the corners yourself'
                  : (manual ? 'Plate warped with your corners (manual)' : 'Plate aligned & warped (auto)'),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            if (m1 != null && m1.warn.isNotEmpty)
              _warnChip(m1.warn, 'Use "Adjust corners" if the outline misses the plate.'),
            _stageActionButtons(
              isComplete: isComplete,
              onRun: () => _runTargetStage(image.id!, 1),
              label: 'Run Stage 1',
              doneColor: Colors.green,
              showRerun: !manual,
              extra: [
                _manualButton(isComplete ? 'Adjust corners' : 'Draw corners', Icons.open_with,
                    () => _openManualCorners(image)),
                if (manual) _resetAutoButton(() => _resetToAuto(image, 1)),
              ],
            ),
            if (isComplete)
              _stagePreview(image.stage1OutputPath, 'Stage 1 — Plate corners'),
          ],
        ),
      ),
    );
  }

  Widget _buildStage2Card() {
    final image = _activeImage!;
    final isComplete = image.stage2Status == 'completed';
    final canRun = image.stage1Status == 'completed';
    final m2 = isComplete ? Stage2Meta.parse(image.stage2Meta) : null;
    final manual = m2?.isManual == true;
    final String subtitle;
    if (!canRun) {
      subtitle = 'Run Stage 1 first';
    } else if (!isComplete) {
      subtitle = 'YOLO well detection on warped plate — or mark 3 wells yourself';
    } else if (m2 == null) {
      subtitle = 'Wells detected';
    } else if (!manual) {
      subtitle = 'Automatic detection · ${m2.rows}×${m2.cols} = ${m2.nWells} wells';
    } else if (m2.source == Stage2Meta.sourceHybrid) {
      subtitle = 'From your 3 wells, refined by the model · ${m2.rows}×${m2.cols} = ${m2.nWells} wells';
    } else {
      subtitle = 'Placed from your 3 wells · ${m2.rows}×${m2.cols} = ${m2.nWells} wells';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.grid_on, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Stage 2 · Detect Wells',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (isComplete) const Icon(Icons.check_circle, color: Colors.blue, size: 18),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                  fontSize: 12, color: canRun ? Colors.grey[600] : Colors.red),
            ),
            if (m2 != null) _stage2Stats(m2),
            if (m2 != null && m2.warn.isNotEmpty)
              _warnChip(m2.warn, 'Use "${manual ? 'Edit wells' : 'Manual wells'}" if the grid is off.'),
            _stageActionButtons(
              isComplete: isComplete,
              onRun:
                  (!canRun) ? null : () => _runTargetStage(image.id!, 2),
              label: 'Run Stage 2',
              doneColor: Colors.blue,
              showRerun: !manual,
              extra: [
                _manualButton(manual ? 'Edit wells' : 'Manual wells', Icons.grid_4x4,
                    canRun ? () => _openManualWells(image) : null),
                if (manual) _resetAutoButton(() => _resetToAuto(image, 2)),
              ],
            ),
            if (isComplete) ...[
              _stagePreview(image.stage2OutputPath, 'Stage 2 — Detected wells', onZoom: () {
                if (Scrollable.recommendDeferredLoadingForContext(context)) return;
                _openStage2Viewer(image);
              }),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Tap the magnifier to zoom in and change the box colours.',
                    style: TextStyle(fontSize: 10, color: Colors.grey[600])),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Số well model detect được + số box từng loại (màu = màu box trên ảnh Stage 2).
  Widget _stage2Stats(Stage2Meta m2) {
    final st = m2.stats;
    int n(String k) => (st[k] as num?)?.toInt() ?? 0;
    Widget item(String kind, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(border: Border.all(color: Color(_s2Style.color(kind)), width: 2.5)),
          ),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 11)),
        ]);
    if (m2.source == Stage2Meta.sourceGeom) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: item('manual', '${m2.nWells} placed from your 3 wells (model not used)'),
      );
    }
    if (st.isEmpty) return const SizedBox.shrink();
    final filled = n('n_interpolated'), moved = n('n_snapped'), dropped = n('n_dropped');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(style: const TextStyle(fontSize: 13), children: [
          const TextSpan(text: 'Model detected '),
          TextSpan(text: '${n('n_det')}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const TextSpan(text: ' wells'),
        ])),
        const SizedBox(height: 2),
        Wrap(spacing: 10, runSpacing: 2, children: [
          item('detected', '${m2.nWells - filled - moved} detected'),
          item('filled', '$filled filled from grid'),
          item('moved', '$moved moved onto grid'),
        ]),
        if (dropped > 0)
          Text('$dropped extra detection${dropped == 1 ? '' : 's'} off the grid ignored',
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
        if (st['stretched'] == true)
          Text('Dark / low-contrast image: contrast was boosted for detection',
              style: TextStyle(fontSize: 10, color: Colors.grey[600])),
      ]),
    );
  }

  /// Một dòng tóm tắt Stage 2 (snackbar, tiêu đề màn hình xem).
  String _stage2Summary(Stage2Meta m2) {
    if (m2.source == Stage2Meta.sourceGeom) return '${m2.nWells} wells placed from your 3 wells';
    final nDet = (m2.stats['n_det'] as num?)?.toInt();
    return nDet == null
        ? '${m2.nWells} wells in grid'
        : 'model detected $nDet wells · ${m2.nWells} wells in grid';
  }

  /// Stage 2 phóng to: box vẽ vector trên plate, đổi được màu / độ dày. Màu đổi -> vẽ lại ảnh preview.
  Future<void> _openStage2Viewer(PipelineImageEntry entry) async {
    final image = await _db.getPipelineImageById(entry.id!) ?? entry;
    final m1 = Stage1Meta.tryParse(image.stage1Meta);
    final m2 = Stage2Meta.tryParse(image.stage2Meta);
    final png = image.stage2OutputPath;
    if (!mounted) return;
    if (m1 == null || m2 == null) {
      // Hàng trước v7: chỉ có ảnh PNG
      if (png != null) _openImageViewer(context, png, 'Stage 2 — Detected wells');
      return;
    }
    // Lần đầu: tạo ảnh hiển thị ≤2048 px từ ảnh warp full-res (~1-2 s)
    final ownStatus = !_isProcessing;
    if (ownStatus) _setProcessing('Opening Stage 2 view...');
    EditImage? edit;
    var boxes = <Map<String, dynamic>>[];
    try {
      edit = await prepareEditImage(m1.warpedPath);
      boxes = await m2.readBoxes();
    } catch (e) {
      print('[Workspace] open stage 2 view failed: $e');
      edit = null;
    }
    if (ownStatus) _clearProcessing();
    if (!mounted) return;
    if (edit == null) {
      if (png != null) _openImageViewer(context, png, 'Stage 2 — Detected wells');
      return;
    }
    final before = _s2Style.key;
    final view = edit;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Stage2ViewerScreen(
          image: view,
          boxes: boxes,
          manualGeom: m2.source == Stage2Meta.sourceGeom,
          title: 'Stage 2 — ${image.imagePath.split(RegExp(r'[\\/]')).last}',
          summary: _stage2Summary(m2),
        ),
      ),
    );
    final style = await Stage2Style.load();
    if (!mounted) return;
    setState(() => _s2Style = style);
    if (style.key != before && !_isProcessing) await _rerenderStage2Preview(image, m2, view, boxes, style);
  }

  /// Vẽ lại ảnh preview Stage 2 theo màu mới, trên ảnh hiển thị ≤2048 px (ảnh preview vốn cũng ≤2048).
  Future<void> _rerenderStage2Preview(PipelineImageEntry image, Stage2Meta m2, EditImage edit,
      List<Map<String, dynamic>> boxes, Stage2Style style) async {
    _setProcessing('Updating Stage 2 preview...');
    try {
      final disp = await _inference.loadImage(edit.path);
      final sx = edit.dispW / edit.srcW, sy = edit.dispH / edit.srcH;
      final scaled = [
        for (final b in boxes)
          {
            ...b,
            'x1': (b['x1'] as num) * sx,
            'y1': (b['y1'] as num) * sy,
            'x2': (b['x2'] as num) * sx,
            'y2': (b['y2'] as num) * sy,
          }
      ];
      final vizPath = await _renderAndSaveViz(
          disp, scaled, ImageUtils.stage2VizCodes(boxes, manualGeom: m2.source == Stage2Meta.sourceGeom), 'stage2_detection',
          palette: style.vizPalette(), lineWidth: style.pngLineWidth);
      await _markStage(image.id!, 'stage2', 'completed', outputPath: vizPath);
      await _createThumb(vizPath, width: 900);
      final old = image.stage2OutputPath;
      if (old != null && old != vizPath) {
        for (final f in [old, _thumbPathOf(old)]) {
          try {
            await File(f).delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      print('[Workspace] stage 2 preview update failed: $e');
    }
    _clearProcessing();
    await _loadData();
  }

  Widget _buildStage3Card() {
    final image = _activeImage!;
    final isComplete = image.stage3Status == 'completed';
    final canRun = image.stage2Status == 'completed';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.science, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Stage 3 · Classify',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (isComplete) const Icon(Icons.check_circle, color: Colors.purple, size: 18),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              !canRun
                  ? 'Run Stage 2 first'
                  : (isComplete ? 'Classification finished' : 'Classify each well'),
              style: TextStyle(
                  fontSize: 12, color: canRun ? Colors.grey[600] : Colors.red),
            ),
            _stageActionButtons(
              isComplete: isComplete,
              onRun:
                  (!canRun) ? null : () => _runTargetStage(image.id!, 3),
              label: 'Run Stage 3',
              doneColor: Colors.purple,
            ),
            if (isComplete)
              _stagePreview(image.stage3OutputPath, 'Stage 3 — Classification'),
          ],
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Results panel: compact inline summary + modal detail sheet
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildResultsPanel(PipelineImageEntry image) {
    // Placeholder slot while stage 3 has not produced results yet — keeps
    // the list structure constant across pipeline runs (see build method).
    if (image.stage3Status != 'completed') {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(Icons.assessment, size: 20, color: Colors.grey[500]),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Results appear here after Stage 3',
                  style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final summary = _decodeStage3Summary(image);
    final total = ((summary?['total'] as num?) ?? 0).toInt();
    final growth = ((summary?['growth'] as num?) ?? 0).toInt();
    final noGrowth = ((summary?['no_growth'] as num?) ?? 0).toInt();
    final noAgar = ((summary?['no_agar'] as num?) ?? 0).toInt();

    // One-line summary + link to the full statistics page; the stage-3
    // visualization renders inline in the Stage 3 card above, like stages 1-2.
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assessment, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Results Overview',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const Icon(Icons.check_circle, color: Colors.purple, size: 18),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Growth $growth · NoGrowth $noGrowth · NoAgar $noAgar — $total wells',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openResultsDetailPage(image),
                icon: const Icon(Icons.insights, size: 18),
                label: const Text('View Detail Result',
                    style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _decodeStage3Summary(PipelineImageEntry image) {
    try {
      return image.stage3Summary != null
          ? jsonDecode(image.stage3Summary!) as Map<String, dynamic>
          : null;
    } catch (_) {
      return null;
    }
  }

  /// Full statistics (proportion bar, per-class chips, confidence histogram,
  /// overlay buttons) on a dedicated fullscreen page. A modal bottom sheet
  /// was tried first: on the MIUI/GLES test device its route opened (barrier
  /// dimmed, Back popped it) but the sheet surface never rendered — same
  /// raster-bug family as the Impeller stalls. Fullscreen routes are the
  /// only overlay mechanism proven reliable here.
  void _openResultsDetailPage(PipelineImageEntry image) {
    final summary = _decodeStage3Summary(image);
    final total = ((summary?['total'] as num?) ?? 0).toInt();
    final growth = ((summary?['growth'] as num?) ?? 0).toInt();
    final noGrowth = ((summary?['no_growth'] as num?) ?? 0).toInt();
    final noAgar = ((summary?['no_agar'] as num?) ?? 0).toInt();
    final confs = ((summary?['confs'] as List<dynamic>?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (pageContext) => Scaffold(
          appBar: AppBar(
            toolbarHeight: 44,
            title: const Text('Results Overview',
                style: TextStyle(fontSize: 15)),
          ),
          body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Stacked proportion bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 14,
                    child: Row(
                      children: [
                        if (total > 0)
                          Expanded(
                            flex: growth,
                            child: Container(color: const Color(0xFF00B400)),
                          ),
                        if (total > 0)
                          Expanded(
                            flex: noGrowth,
                            child: Container(color: const Color(0xFF0000DC)),
                          ),
                        if (total > 0)
                          Expanded(
                            flex: noAgar,
                            child: Container(color: const Color(0xFFC800C8)),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Stat cards
                Row(
                  children: [
                    _statChip('Growth', growth, total, const Color(0xFF00B400)),
                    const SizedBox(width: 8),
                    _statChip(
                        'NoGrowth', noGrowth, total, const Color(0xFF0000DC)),
                    const SizedBox(width: 8),
                    _statChip('NoAgar', noAgar, total, const Color(0xFFC800C8)),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Total wells detected: $total',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ),
                if (((summary?['brightness_gain'] as num?) ?? 1) > 1)
                  Text(
                      'Dark image: brightness ×${(summary!['brightness_gain'] as num).toStringAsFixed(2)} '
                      'normalized before classification',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                if (confs.isNotEmpty) ...[
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Icon(Icons.speed, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Classification confidence — avg ${(confs.reduce((a, b) => a + b) / confs.length).toStringAsFixed(2)}',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _confidenceHistogram(confs),
                ],

                // Stage-3 overlays render only on demand via these buttons —
                // the fullscreen viewer decodes them at screen resolution.
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            (image.stage3OutputPath?.isNotEmpty ?? false)
                                ? () => _openImageViewer(pageContext,
                                    image.stage3OutputPath!,
                                    'Stage 3 — Classification')
                                : null,
                        icon: const Icon(Icons.zoom_in, size: 18),
                        label: const Text('Result Detail',
                            style: TextStyle(fontSize: 13)),
                      ),
                    ),
                    if (image.stage3ConfPath?.isNotEmpty ?? false) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _openImageViewer(pageContext,
                              image.stage3ConfPath!,
                              'Stage 3 — Confidence per well'),
                          icon: const Icon(Icons.speed, size: 18),
                          label: const Text('Confidence',
                              style: TextStyle(fontSize: 13)),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
        ),
      ),
    );
  }

  Widget _statChip(String label, int count, int total, Color color) {
    final pct = total > 0 ? (count / total * 100).round() : 0;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 1),
        ),
        child: Column(
          children: [
            Text('$count',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style: TextStyle(fontSize: 10, color: Colors.grey[700])),
            Text('$pct%',
                style: TextStyle(fontSize: 10, color: Colors.grey[600])),
          ],
        ),
      ),
    );
  }

  /// Vertical bar histogram over 5 fixed confidence buckets.
  /// Bars use fixed pixel heights: the FractionallySizedBox version blanked
  /// the entire detail page on the GLES test device (build/layout fine, no
  /// exception, body never painted — same raster-bug family as the Impeller
  /// stalls).
  Widget _confidenceHistogram(List<double> confs) {
    final buckets = List<int>.filled(5, 0);
    for (final c in confs) {
      final idx = (c * 5).clamp(0, 4).toInt();
      buckets[idx]++;
    }
    final maxB = buckets.fold<int>(1, (a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 64,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(5, (i) {
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${buckets[i]}',
                          textAlign: TextAlign.center,
                          style:
                              const TextStyle(fontSize: 9, color: Colors.grey)),
                      const SizedBox(height: 2),
                      if (buckets[i] > 0)
                        Container(
                          height: 40 * buckets[i] / maxB,
                          decoration: BoxDecoration(
                            color: Color.lerp(const Color(0xFFE0E0E0),
                                const Color(0xFF43A047), i / 4),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3)),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: List.generate(5, (i) {
            final lo = (i * 20), hi = lo + 20;
            return Expanded(
              child: Center(
                child: Text('$lo-${hi == 100 ? 100 : hi}',
                    style:
                        TextStyle(fontSize: 8, color: Colors.grey[600])),
              ),
            );
          }),
        ),
      ],
    );
  }

  /// Full-width run control pinned as the first item of the detail panel.
  /// Disabled (never removed) while processing or with no image selected, so
  /// the list structure stays constant across runs.
  Widget _buildRunControl() {
    final image = _activeImage;
    final canRun = image != null && !_isProcessing;

    return FilledButton.icon(
      onPressed: canRun ? _runSingleFullPipeline : null,
      icon: const Icon(Icons.fast_forward),
      label: Text(image == null
          ? 'Run Stages'
          : (image.isFullDone ? 'Rerun Pipeline' : 'Run Remaining Stages')),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(44),
        backgroundColor: image?.isFullDone == true ? Colors.orange : null,
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            'Tap an image to view its stages',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _pickImages,
            icon: const Icon(Icons.upload),
            label: const Text('Upload Images'),
          ),
        ],
      ),
    );
  }

  Widget _buildProcessingOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _statusMessage,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────────

  /// Header icon: null for pending/running (only completed progress shows).
  IconData? _getStatusIconData(String status) {
    switch (status) {
      case 'stage1_done':
        return Icons.check_circle;
      case 'stage2_done':
        return Icons.check_circle;
      case 'full_done':
        return Icons.done_all;
      default:
        return null;
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.grey;
      case 'running':
        return Colors.orange;
      case 'stage1_done':
        return Colors.green;
      case 'stage2_done':
        return Colors.blue;
      case 'full_done':
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  String _getStatusLabel(String status) {
    switch (status) {
      case 'pending':
        return 'Not started';
      case 'running':
        return 'Processing...';
      case 'stage1_done':
        return 'Stage 1 complete';
      case 'stage2_done':
        return 'Stage 2 complete';
      case 'full_done':
        return 'All stages complete';
      default:
        return 'Unknown';
    }
  }

  List<PipelineImageEntry> get _selectedImages =>
      _images.where((i) => _selectedImageIds.contains(i.id)).toList();

  void _setProcessing(String message) {
    if (mounted) {
      setState(() {
        _isProcessing = true;
        _statusMessage = message;
      });
    }
  }

  void _clearProcessing() {
    if (mounted) {
      setState(() {
        _isProcessing = false;
        _statusMessage = '';
      });
    }
  }

  /// Thumbnail companion path ("<name>.thumb.jpg") for any stored image.
  String _thumbPathOf(String p) {
    final dot = p.lastIndexOf('.');
    return dot == -1 ? '$p.thumb.jpg' : '${p.substring(0, dot)}.thumb.jpg';
  }

  /// Paths known to have a thumbnail file (positive results are cached so
  /// builds never re-stat the filesystem; a path only flips original->thumb
  /// once, when its thumb first appears).
  final Set<String> _thumbKnown = {};

  bool _hasThumb(String path) {
    if (_thumbKnown.contains(path)) return true;
    if (File(_thumbPathOf(path)).existsSync()) {
      _thumbKnown.add(path);
      return true;
    }
    return false;
  }

  /// Create a small JPEG thumbnail next to [sourcePath] so lists/cards never
  /// need to decode multi-megabyte originals. Returns the thumb path or null.
  /// Decode/resize/encode run in an isolate (createThumbJob).
  Future<String?> _createThumb(String sourcePath, {int width = 900}) async {
    try {
      final res = await compute(createThumbJob,
          {'src': sourcePath, 'dst': _thumbPathOf(sourcePath), 'width': width});
      if (res['path'] == null) return null;
      _thumbKnown.add(sourcePath);
      return _thumbPathOf(sourcePath);
    } catch (e) {
      print('[Workspace] thumb failed for $sourcePath: $e');
      return null;
    }
  }

  /// Renders an image preferring its pre-made thumbnail (cheap decode);
  /// falls back to the original downsampled with cacheWidth.
  /// No gaplessPlayback: swapping providers on a live render object while
  /// the subtree is being torn down mid-scroll caused detach assertions.
  Widget _lightImage(String path, {double? cacheW, BoxFit fit = BoxFit.contain}) {
    final effective = _hasThumb(path) ? _thumbPathOf(path) : path;
    return Image.file(
      File(effective),
      fit: fit,
      cacheWidth: cacheW?.round(),
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Dialogs
  // ──────────────────────────────────────────────────────────────────────────

  /// Legend explaining which sidebar icon maps to which pipeline progress.
  /// Mirrors _buildStatusIcon: only completed progress has an icon.
  /// Content scrolls — landscape height plus the device's enlarged font scale
  /// made the fixed Column overflow.
  void _showStatusLegend() {
    showDialog(
      context: context,
      builder: (context) => MediaQuery.withNoTextScaling(
        // Plain Dialog with explicit paddings: AlertDialog's default title/
        // content/actions spacing is oversized on this device and pushed the
        // legend into a scrollable, mostly-empty box.
        child: Dialog(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Image Status Icons',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                _legendRow(Icons.remove, Colors.grey, 'Not started',
                    'no icon — no stage finished yet'),
                const SizedBox(height: 10),
                _legendRow(Icons.check_circle, Colors.green, 'Stage 1 complete',
                    'plate aligned & warped'),
                const SizedBox(height: 10),
                _legendRow(Icons.check_circle, Colors.blue, 'Stage 2 complete',
                    'wells detected'),
                const SizedBox(height: 10),
                _legendRow(Icons.done_all, Colors.purple, 'All stages complete',
                    'results ready'),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _legendRow(IconData icon, Color color, String title, String desc) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                    text: title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
                TextSpan(
                    text: '  ·  $desc',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey[600])),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteImage(PipelineImageEntry image) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text(
          'Move "${image.imagePath.split('/').last}" to the trash bin?\n\n'
          'The image and its pipeline results can be restored from the Trash tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _db.movePipelineImageToTrash(image.id!);
      _loadData();
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Actions
  // ──────────────────────────────────────────────────────────────────────────

  /// Add-images entry point: ask gallery vs camera first (a bottom sheet —
  /// proven to render on the test device by the trash restore picker), then
  /// fan out to the matching picker. Camera contributes a single photo.
  Future<void> _pickImages() async {
    final picker = ImagePicker();

    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(sheetContext, ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    final List<XFile> picked;
    if (source == ImageSource.camera) {
      final photo = await picker.pickImage(source: ImageSource.camera);
      picked = photo == null ? [] : [photo];
    } else {
      picked = await picker.pickMultiImage();
    }

    if (picked.isNotEmpty) {
      print('[Workspace] Picked ${picked.length} images');

      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (var xfile in picked) {
          final image = PipelineImageEntry(
            projectId: project.id,
            imagePath: xfile.path,
            createdAt: now,
            updatedAt: now,
          );
          final id = await _db.insertPipelineImage(image);
          print('[Workspace] Inserted image ID: $id');
          // Sidebar/list thumbnails so scrolling never decodes the originals
          await _createThumb(xfile.path, width: 900);
        }
        await _loadData();
      } catch (e) {
        print('[Workspace] Error inserting images: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error uploading images: $e')),
          );
        }
      }
    }
  }

  // ── Stage execution core ────────────────────────────────────────────────────

  Future<void> _markStage(int imageId, String stage, String status,
      {String? outputPath}) async {
    await _db.updatePipelineImageStageStatus(imageId, stage, status,
        outputPath: outputPath);
  }

  /// Render a well-box overlay onto the (potentially full-res) warped plate
  /// and save it as PNG — entirely off the UI isolate via renderAnnotatedVizJob
  /// (draw + downscale-to-2048 + encode).
  Future<String> _renderAndSaveViz(
    img.Image warpedImage,
    List<Map<String, dynamic>> boxes,
    List<int> classes,
    String prefix, {
    Map<int, double>? confidences,
    Map<int, List<int>>? palette,
    int lineWidth = 1,
  }) async {
    final bytes = await compute(renderAnnotatedVizJob, {
      'image': warpedImage,
      'boxes': boxes,
      'classes': classes,
      'confidences': confidences,
      'palette': palette,
      'lineWidth': lineWidth,
    });
    final file = await ImageUtils.saveImage(
        bytes, '${prefix}_${DateTime.now().millisecondsSinceEpoch}.png');
    return file.path;
  }

  /// Run exactly ONE target stage on an image (per-stage buttons).
  /// Prerequisite checks enforce ordering without touching other statuses.
  Future<void> _runTargetStage(int imageId, int targetStage) async {
    if (_isProcessing) return;

    final image = await _db.getPipelineImageById(imageId);
    if (image == null) return;

    if (targetStage >= 2 && image.stage1Status != 'completed') {
      _snack('Run Stage 1 first');
      return;
    }
    if (targetStage >= 3 && image.stage2Status != 'completed') {
      _snack('Run Stage 2 first');
      return;
    }

    _setProcessing('Running Stage $targetStage...');
    try {
      var done = 'Stage $targetStage completed';
      switch (targetStage) {
        case 1:
          await _executeStage1(image);
          break;
        case 2:
          final r = await _executeStage2(image);
          done = 'Stage 2 completed — ${_stage2Summary(r.meta)}';
          break;
        case 3:
          await _executeStage3(image);
          break;
      }
      // Clear first so _loadData's stale-'running' reset is not skipped by
      // the _isProcessing guard.
      _clearProcessing();
      await _loadData();
      _snack(done);
    } catch (e) {
      _clearProcessing();
      _snack('Stage $targetStage failed: $e');
    }
  }

  /// STAGE 1: corner regression (or the user's corners) + perspective warp.
  /// Stages 2-3 depend on the corners, so they are invalidated first.
  /// Failure demotes the stage back to 'pending': a stage left 'running'
  /// renders forever as the reloading icon + "Processing..." even though the
  /// image has no results.
  Future<_S1Run> _executeStage1(PipelineImageEntry image,
      {List<Map<String, double>>? manualCorners}) async {
    await _inference.initialize();
    await _db.resetStagesFrom(image.id!, 2);
    await _markStage(image.id!, 'stage1', 'running');
    try {
      return await _executeStage1Inner(image, manualCorners: manualCorners);
    } catch (e) {
      await _markStage(image.id!, 'stage1', 'pending');
      rethrow;
    }
  }

  Future<_S1Run> _executeStage1Inner(PipelineImageEntry image,
      {List<Map<String, double>>? manualCorners}) async {
    final prev = Stage1Meta.parse(image.stage1Meta);
    final out = await _inference.stage1Warp(image.imagePath, corners: manualCorners);

    // Annotated corners preview on the ORIGINAL image (draw + encode off the
    // UI isolate — a full-res photo takes seconds for each step).
    String visPath = out.warpedPath;
    try {
      final jpgBytes = await compute(renderCornersVizJob,
          {'image': out.image, 'corners': out.corners});
      if (jpgBytes.isNotEmpty) {
        final file = await ImageUtils.saveImage(jpgBytes,
            'stage1_corners_${DateTime.now().millisecondsSinceEpoch}.jpg');
        visPath = file.path;
      }
    } catch (_) {}

    final corners = [for (final c in out.corners) [c['x']!, c['y']!]];
    final meta = Stage1Meta(
      source: out.source,
      imageSize: [out.image.width, out.image.height],
      corners: corners,
      autoCorners: out.source == Stage1Meta.sourceAuto ? corners : prev?.autoCorners,
      warpedPath: out.warpedPath,
      warpedSize: [out.warped.width, out.warped.height],
      qc: out.qc.toJson(),
      warn: out.warn,
    );
    await _db.saveStageResult(image.id!, 1, outputPath: visPath, metaJson: jsonEncode(meta.toJson()));
    await _createThumb(visPath, width: 900);
    return _S1Run(meta, out.warped);
  }

  /// STAGE 2: wells on the warped plate — YOLO + lattice, or the user's 3
  /// boxes ([manual]). Reuses Stage 1's stored warp (no model rerun); legacy
  /// rows without stored Stage 1 data rebuild it automatically once.
  /// Same failure contract as stage 1: demote to 'pending' on error.
  Future<_S2Run> _executeStage2(PipelineImageEntry image,
      {ManualWells? manual, _S1Run? s1}) async {
    await _inference.initialize();
    await _db.resetStagesFrom(image.id!, 3);
    await _markStage(image.id!, 'stage2', 'running');
    try {
      return await _executeStage2Inner(image, manual: manual, s1: s1);
    } catch (e) {
      await _markStage(image.id!, 'stage2', 'pending');
      rethrow;
    }
  }

  Future<_S2Run> _executeStage2Inner(PipelineImageEntry image,
      {ManualWells? manual, _S1Run? s1}) async {
    var run1 = s1;
    if (run1 == null) {
      final m1 = Stage1Meta.tryParse(image.stage1Meta);
      run1 = m1 != null
          ? _S1Run(m1, await _inference.loadImage(m1.warpedPath))
          : await _executeStage1Inner(image); // hàng trước v7 / file warp mất
    }
    final out = await _inference.stage2Detect(run1.warped, manual: manual);

    final ts = DateTime.now().millisecondsSinceEpoch;
    final dir = await getApplicationDocumentsDirectory();
    final resultPath = '${dir.path}/stage2_wells_$ts.json';
    await Stage2Meta.writeBoxes(resultPath, out.boxes, out.grid.rows, out.grid.cols, run1.meta.warpedSize);

    final style = await Stage2Style.load();
    final vizPath = await _renderAndSaveViz(
        run1.warped,
        out.boxes,
        ImageUtils.stage2VizCodes(out.boxes, manualGeom: out.source == Stage2Meta.sourceGeom),
        'stage2_detection',
        palette: style.vizPalette(),
        lineWidth: style.pngLineWidth);

    final meta = Stage2Meta(
      source: out.source,
      resultPath: resultPath,
      rows: out.grid.rows,
      cols: out.grid.cols,
      manual: manual,
      stats: out.stats,
      warn: out.warn,
    );
    await _db.saveStageResult(image.id!, 2, outputPath: vizPath, metaJson: jsonEncode(meta.toJson()));
    await _createThumb(vizPath, width: 900);
    return _S2Run(run1.meta, meta, run1.warped, out.boxes);
  }

  /// STAGE 3: classification + stats/confidence persistence. Reuses the
  /// stored Stage 2 boxes (any R×C) — no model rerun.
  /// Same failure contract as stages 1-2: demote to 'pending' on error.
  Future<void> _executeStage3(PipelineImageEntry image, {_S2Run? reuse}) async {
    await _inference.initialize();
    await _db.resetStagesFrom(image.id!, 3); // also drops this image's old History rows
    await _markStage(image.id!, 'stage3', 'running');
    try {
      await _executeStage3Inner(image, reuse: reuse);
    } catch (e) {
      await _markStage(image.id!, 'stage3', 'pending');
      rethrow;
    }
  }

  Future<void> _executeStage3Inner(PipelineImageEntry image, {_S2Run? reuse}) async {
    var run = reuse;
    if (run == null) {
      final m1 = Stage1Meta.tryParse(image.stage1Meta);
      final m2 = Stage2Meta.tryParse(image.stage2Meta);
      run = (m1 != null && m2 != null)
          ? _S2Run(m1, m2, await _inference.loadImage(m1.warpedPath), await m2.readBoxes())
          : await _executeStage2Inner(image); // hàng trước v7: dựng lại Stage 1-2 tự động
    }
    final warped = run.warped;
    final boxes = run.boxes;
    final s3 = await _inference.classifyWellsDetailed(warped, boxes);
    final classes = s3.classes;

    // Độ tin cậy từng well = xác suất của class đã chọn (Stage 3), index-aligned với boxes.
    // (Không dùng conf YOLO: ô nội suy từ lưới không có detection nên conf YOLO = 0.)
    final confMap = <int, double>{};
    final confList = <double>[];
    final classConfs = s3.confidences;
    for (var i = 0; i < boxes.length; i++) {
      final c = classConfs[i];
      confMap[i] = c;
      confList.add(double.parse(c.toStringAsFixed(3)));
    }
    final nInterpolated = boxes.where((b) => b['interpolated'] == true).length;
    final nSnapped = boxes.where((b) => b['snapped'] == true).length;

    final counts = {'growth': 0, 'no_growth': 0, 'no_agar': 0};
    for (final cls in classes) {
      if (cls == 0) counts['growth'] = counts['growth']! + 1;
      if (cls == 1) counts['no_growth'] = counts['no_growth']! + 1;
      if (cls == 2) counts['no_agar'] = counts['no_agar']! + 1;
    }

    // Plain classification overlay
    final plainPath = await _renderAndSaveViz(warped, boxes, classes, 'annotated_warped');

    // Kết quả từng well (sidecar JSON) — để đối chiếu với Python (pipelines/42_compare_app_results.py)
    try {
      await File('$plainPath.wells.json').writeAsString(jsonEncode({
        'source_image': image.imagePath,
        'corners': run.s1.corners,
        'warped_size': [warped.width, warped.height],
        'stage1_source': run.s1.source,
        'stage2_source': run.meta.source,
        'rows': run.meta.rows,
        'cols': run.meta.cols,
        'manual': run.meta.manual?.toJson(),
        'boxes': [for (final b in boxes) [b['x1'], b['y1'], b['x2'], b['y2']]],
        'yolo_conf': [for (final b in boxes) b['conf']],
        'interpolated': [for (final b in boxes) b['interpolated'] == true],
        'snapped': [for (final b in boxes) b['snapped'] == true],
        'classes': classes,
        'probs': s3.probs,
        'stage3_gain': s3.gain,
      }));
    } catch (e) {
      print('[Workspace] wells json failed: $e');
    }

    // Confidence-labeled overlay
    String? confPath;
    try {
      confPath = await _renderAndSaveViz(warped, boxes, classes, 'annotated_conf',
          confidences: confMap);
    } catch (e) {
      print('[Workspace] conf viz failed: $e');
    }

    // Persist summary JSON (counts + confidences for the stats panel)
    final summaryJson = jsonEncode({
      'total': classes.length,
      ...counts,
      'confs': confList,
      'conf_source': 'stage3_prob',
      'brightness_gain': double.parse(s3.gain.toStringAsFixed(2)),
      'interpolated': nInterpolated,
      'snapped': nSnapped,
      'rows': run.meta.rows,
      'cols': run.meta.cols,
      'stage1_source': run.s1.source,
      'stage2_source': run.meta.source,
    });
    await _db.updatePipelineImageStage3Summary(image.id!, summaryJson);

    await _markStage(image.id!, 'stage3', 'completed', outputPath: plainPath);
    await _createThumb(plainPath, width: 900);
    if (confPath != null) {
      await _createThumb(confPath, width: 900);
    }

    // Keep stage3_conf_path alongside
    if (confPath != null) {
      final db = await _db.database;
      await db.rawUpdate(
          'UPDATE pipeline_images SET stage3_conf_path = ? WHERE id = ?',
          [confPath, image.id]);
    }

    // Record a history entry so it shows up in the History tab
    try {
      await _db.insertResult(HistoryEntry(
        imagePath: image.imagePath,
        annotatedPath: plainPath,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        totalWells: classes.length,
        growthCount: counts['growth']!,
        noGrowthCount: counts['no_growth']!,
        noAgarCount: counts['no_agar']!,
        projectId: image.projectId ?? project.id,
        processingTimeMs: null,
        pipelineImageId: image.id,
      ));
    } catch (e) {
      print('[Workspace] history insert failed: $e');
    }
  }

  // ── Manual mode ─────────────────────────────────────────────────────────────

  Future<bool> _confirm(String title, String message, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
        ],
      ),
    );
    return ok == true;
  }

  /// Stage 1 by hand: drag the 4 plate corners on the original photo, then warp with them.
  Future<void> _openManualCorners(PipelineImageEntry entry) async {
    if (_isProcessing) return;
    final image = await _db.getPipelineImageById(entry.id!) ?? entry;
    final m1 = Stage1Meta.parse(image.stage1Meta);
    final m2 = Stage2Meta.parse(image.stage2Meta);
    if (image.stage2Status == 'completed' || image.stage3Status == 'completed') {
      final ok = await _confirm(
          'Change plate corners?',
          'Stage 2 and Stage 3 results of this image will be cleared'
              '${m2?.isManual == true ? ', including your manual wells' : ''}. '
              'Run them again after saving the corners.',
          'Continue');
      if (!ok) return;
    }
    // Stage 1 đã chạy -> chỉnh từ kết quả đó (góc hiện tại: của model hoặc lần chỉnh tay trước);
    // chưa chạy -> hình chữ nhật mặc định, trong màn hình có nút "Detect with model".
    _setProcessing('Preparing photo...');
    EditImage? edit;
    List<Map<String, double>>? initial, model;
    try {
      await _inference.initialize(); // PipelineConfig: toạ độ góc theo ảnh làm việc (ảnh lớn được thu nhỏ)
      edit = await prepareEditImage(image.imagePath, workMax: PipelineConfig.I.maxImageSide);
      final e = edit;
      if (e != null && m1 != null && m1.imageSize[0] == e.srcW && m1.imageSize[1] == e.srcH) {
        initial = m1.cornerMaps;
        model = m1.autoCorners == null ? null : [for (final c in m1.autoCorners!) {'x': c[0], 'y': c[1]}];
      } else if (e != null && image.stage1Status == 'completed') {
        // Chạy trước bản v7 nên chưa lưu góc -> chạy lại model để lấy đúng kết quả đó
        _setProcessing('Detecting corners...');
        await _inference.initialize();
        final (c, w, h) = await _inference.detectCorners(image.imagePath);
        if (w == e.srcW && h == e.srcH) initial = model = c;
      }
    } catch (err) {
      print('[Workspace] prepare manual corners failed: $err');
    }
    _clearProcessing();
    if (edit == null) {
      _snack('Cannot open this photo');
      return;
    }
    if (!mounted) return;
    final editImage = edit;
    final res = await Navigator.push<ManualCornersResult>(
      context,
      MaterialPageRoute(
        builder: (_) => ManualCornersScreen(
          image: editImage,
          initial: initial,
          modelCorners: model,
          // Chưa chạy Stage 1: user bấm "Detect with model" -> chạy model rồi chỉnh tiếp từ kết quả đó
          detectModel: () async {
            await _inference.initialize();
            final (c, w, h) = await _inference.detectCorners(image.imagePath);
            if (w != editImage.srcW || h != editImage.srcH) throw Exception('photo size mismatch');
            return c;
          },
        ),
      ),
    );
    if (res == null) return;

    // Giữ nguyên góc model -> lưu như kết quả tự động (có cảnh báo QC); đã chỉnh -> nguồn "manual"
    _setProcessing(res.fromModel ? 'Warping plate...' : 'Warping plate with your corners...');
    try {
      await _executeStage1(image, manualCorners: res.fromModel ? null : res.corners);
      _clearProcessing();
      await _loadData();
      _snack('Corners saved — run Stage 2 next');
    } catch (e) {
      _clearProcessing();
      _snack('Stage 1 failed: $e');
    }
  }

  /// Stage 2 by hand: 3 well boxes + wells per direction on the warped plate.
  Future<void> _openManualWells(PipelineImageEntry entry) async {
    if (_isProcessing) return;
    var image = await _db.getPipelineImageById(entry.id!) ?? entry;
    if (image.stage1Status != 'completed') {
      _snack('Run Stage 1 first');
      return;
    }
    if (image.stage3Status == 'completed') {
      final ok = await _confirm('Replace wells?',
          'Stage 3 results of this image will be cleared. Run Stage 3 again after saving the wells.', 'Continue');
      if (!ok) return;
    }
    _setProcessing('Preparing warped plate...');
    try {
      await _inference.initialize(); // _inference.grid + PipelineConfig.I cho màn hình chỉnh tay
      var m1 = Stage1Meta.tryParse(image.stage1Meta);
      if (m1 == null) {
        // Hàng trước v7: chưa lưu ảnh warp -> chạy lại Stage 1 tự động một lần
        await _executeStage1(image);
        image = await _db.getPipelineImageById(image.id!) ?? image;
        m1 = Stage1Meta.tryParse(image.stage1Meta);
      }
      final edit = m1 == null ? null : await prepareEditImage(m1.warpedPath);
      final m2 = Stage2Meta.tryParse(image.stage2Meta);
      final initial = m2?.manual ?? (m2 != null ? prefillFromGrid(await m2.readBoxes(), m2.rows, m2.cols) : null);
      _clearProcessing();
      if (edit == null) {
        _snack('Cannot open the warped plate');
        return;
      }
      if (!mounted) return;
      final res = await Navigator.push<ManualWells>(
        context,
        MaterialPageRoute(
          builder: (_) => ManualWellsScreen(
            image: edit,
            grid: _inference.grid,
            initial: initial,
            // YOLO trên ảnh hiển thị ≤2048 px -> px ảnh warp gốc: chấm well + chạm hút box
            detectWells: () => _inference.detectWellBoxes(edit.path,
                scaleX: edit.srcW / edit.dispW, scaleY: edit.srcH / edit.dispH),
          ),
        ),
      );
      if (res == null) {
        await _loadData();
        return;
      }
      _setProcessing('Building well grid...');
      final r = await _executeStage2(image, manual: res);
      _clearProcessing();
      await _loadData();
      _snack('Wells saved (${_stage2Summary(r.meta)}) — run Stage 3 next');
    } catch (e) {
      _clearProcessing();
      await _loadData();
      _snack('Manual wells failed: $e');
    }
  }

  /// Drop manual input of [stage] and rerun it automatically.
  Future<void> _resetToAuto(PipelineImageEntry image, int stage) async {
    final ok = await _confirm(
        'Reset to automatic?',
        stage == 1
            ? 'Your corners will be replaced by the detected ones. Stage 2 and 3 results will be cleared.'
            : 'Your wells will be replaced by automatic detection. Stage 3 results will be cleared.',
        'Reset');
    if (ok) await _runTargetStage(image.id!, stage);
  }

  // ── Orchestration ───────────────────────────────────────────────────────────

  /// Run remaining stages (from the first incomplete one) for the active image.
  Future<void> _runSingleFullPipeline() async {
    final image = _activeImage;
    if (image == null || _isProcessing) return;

    if (image.isFullDone) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rerun Pipeline?'),
          content: const Text('This image already has complete results.\n\n'
              'Rerun and overwrite? Corners / wells you set by hand are kept '
              '(use "Reset to auto" on a stage to drop them).'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Rerun'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    _setProcessing('Running remaining stages...');
    try {
      await _runThrough(image.id!,
          forceAll: image.isFullDone); // confirmed reruns everything
      _clearProcessing();
      await _loadData();
      _snack('Pipeline finished');
    } catch (e) {
      _clearProcessing();
      _snack('Pipeline failed: $e');
    }
  }

  /// Sequentially execute all stages the image has not finished yet, in order,
  /// passing intermediate data between them in memory. When [forceAll] is true
  /// everything is rerun and overwritten — manual inputs (corners, 3 well
  /// boxes) are reused, not discarded.
  Future<void> _runThrough(int imageId, {bool forceAll = false}) async {
    var image = await _db.getPipelineImageById(imageId);
    if (image == null) return;

    // Status messages name the file so a sequential batch is readable
    // ("which image, which stage").
    final name = image.imagePath.split('/').last;

    final start = forceAll ? 1 : _firstIncompleteStage(image);
    if (start > 3) return; // already fully complete and not forcing

    final prev1 = Stage1Meta.parse(image.stage1Meta);
    final prev2 = Stage2Meta.parse(image.stage2Meta);
    _S1Run? run1;
    _S2Run? run2;

    if (start <= 1) {
      _setProcessing('$name · Stage 1 · warping plate...');
      await _loadLight();
      run1 = await _executeStage1(image,
          manualCorners: prev1?.isManual == true ? prev1!.cornerMaps : null);

      image = await _db.getPipelineImageById(imageId);
      if (image?.stage1Status != 'completed') {
        throw Exception('Stage 1 failed');
      }
    }

    if (start <= 2) {
      // 3 box tay nằm trong toạ độ ảnh warp: chỉ dùng lại khi góc (-> ảnh warp) không đổi
      final keep = (prev2?.manual != null && (run1 == null || _sameCorners(run1.meta.corners, prev1?.corners)))
          ? prev2!.manual
          : null;
      _setProcessing('$name · Stage 2 · ${keep != null ? 'building your well grid' : 'detecting wells'}...');
      await _loadLight();
      run2 = await _executeStage2(image!, manual: keep, s1: run1);
    }

    image = await _db.getPipelineImageById(imageId);
    if (image == null || image.stage2Status != 'completed') {
      throw Exception('Stage 2 failed');
    }

    _setProcessing('$name · Stage 3 · classifying wells...');
    await _loadLight();
    await _executeStage3(image, reuse: run2);
  }

  int _firstIncompleteStage(PipelineImageEntry image) {
    if (image.stage1Status != 'completed') return 1;
    if (image.stage2Status != 'completed') return 2;
    if (image.stage3Status != 'completed') return 3;
    return 4; // nothing to do
  }

  /// Lightweight reload that keeps processing spinner visible
  Future<void> _loadLight() async {
    if (project.id == null) return;
    final images = await _db.getPipelineImagesByProject(project.id!);
    if (mounted) {
      setState(() {
        _images = images;
        _selectedImageIds.retainWhere((id) => images.any((i) => i.id == id));
        if (_activeImage != null &&
            images.any((i) => i.id == _activeImage!.id)) {
          _activeImage = images.firstWhere((i) => i.id == _activeImage!.id);
        }
      });
    }
  }

  // ── Batch ───────────────────────────────────────────────────────────────────

  /// Batch: run the full pipeline on every selected image, resuming from each
  /// image's current progress. Images already complete are confirmed once upfront.
  Future<void> _runBatchFullPipeline() async {
    final selected = _selectedImages;
    if (selected.isEmpty || _isProcessing) return;

    final alreadyDone = selected.where((i) => i.isFullDone).length;
    if (alreadyDone > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Rerun Completed Images?'),
          content: Text(
            '$alreadyDone of ${selected.length} selected images already have '
            'complete results.\n\nThey will be rerun and overwritten. The rest '
            'continue from their current progress.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Run'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    _setProcessing('Running full pipeline (${selected.length} images)...');

    try {
      final ids = selected.map((i) => i.id!).toList();
      final forceAllIds =
          selected.where((i) => i.isFullDone).map((i) => i.id!).toSet();

      // Strictly sequential — concurrent pipelines share the single ONNX
      // Runtime session of the InferenceService singleton, and two parallel
      // runs corrupt native state (observed SIGSEGV in libonnxruntime.so
      // with as few as 2 selected images).
      var doneCount = 0;
      for (final id in ids) {
        try {
          await _runThrough(id, forceAll: forceAllIds.contains(id));
        } catch (e) {
          print('[Batch] Error for image $id: $e');
        }
        doneCount++;
        _setProcessing(
            'Running full pipeline ($doneCount/${ids.length})...');
      }

      _clearProcessing();
      await _loadData();

      _snack('Full pipeline finished for ${ids.length} images');
    } catch (e) {
      _clearProcessing();
      _snack('Batch failed: $e');
    }
  }

  /// Move every selected image to the trash (soft delete) after confirmation.
  Future<void> _deleteSelectedImages() async {
    final selected = _selectedImages;
    if (selected.isEmpty || _isProcessing) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to Trash'),
        content: Text(
          'Move ${selected.length} image(s) to the trash bin?\n\n'
          'They and their results can be restored from the Trash tab.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Move to Trash'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    for (final image in selected) {
      await _db.movePipelineImageToTrash(image.id!);
    }
    if (mounted) setState(() => _selectedImageIds.clear());
    await _loadData();
    _snack('Moved ${selected.length} image(s) to trash');
  }

  void _snack(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
