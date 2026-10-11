/// TrashScreen - soft-deleted workspace images. The trash is image-centric:
/// a trashed image carries its pipeline results with it (restore brings both
/// back, delete-forever removes both). Tapping an image opens a read-only
/// viewer of its stage progress; restoring asks which project receives it
/// (the card keeps showing "was in <original project>").
library trash_screen;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/database_helper.dart';
import 'pipeline_screen_v2.dart' show ImageViewerScreen;

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => TrashScreenState();
}

class TrashScreenState extends State<TrashScreen> {
  late Future<List<PipelineImageEntry>> _imagesFuture;
  Map<int, String> _projectNames = {};
  final Set<String> _thumbKnown = {};
  final DatabaseHelper _db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  /// Called by MainScreen whenever the Trash tab becomes visible again
  void refresh() => _refresh();

  void _refresh() {
    setState(() {
      _imagesFuture = _db.getTrashedPipelineImages();
    });
    _loadProjectNames();
  }

  Future<void> _loadProjectNames() async {
    try {
      final projects = await _db.getAllProjects();
      if (mounted) {
        setState(() {
          _projectNames = {
            for (final p in projects)
              if (p.id != null) p.id!: p.name,
          };
        });
      }
    } catch (_) {}
  }

  String _statusLabel(PipelineImageEntry image) {
    switch (image.overallStatus) {
      case 'full_done':
        return 'Full pipeline';
      case 'stage2_done':
        return 'Stages 1-2 done';
      case 'stage1_done':
        return 'Stage 1 done';
      case 'running':
        return 'Interrupted';
      default:
        return 'Not started';
    }
  }

  /// Restore into a project the user picks from the list of existing
  /// projects — not necessarily the original one (which is still displayed
  /// as "was in ..." on the card).
  Future<void> _restoreImage(PipelineImageEntry image) async {
    final projects = await _db.getAllProjects();
    if (!mounted) return;
    if (projects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No projects yet — create one in the Projects tab')));
      return;
    }

    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('Restore to Project',
                    style: Theme.of(sheetContext).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: projects.length,
                  itemBuilder: (context, index) {
                    final project = projects[index];
                    final isOriginal = project.id == image.projectId;
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(project.name),
                      subtitle: isOriginal
                          ? const Text('was in this project')
                          : null,
                      onTap: () => Navigator.pop(context, project.id),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;

    await _db.restorePipelineImageFromTrash(image.id!, selected);
    _refresh();

    ProjectEntry? target;
    for (final p in projects) {
      if (p.id == selected) target = p;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Restored to "${target?.name ?? 'project'}"')),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: Text(action),
              ),
            ],
          ),
        ) ==
        true;
  }

  Future<void> _deleteImagePermanently(PipelineImageEntry image) async {
    if (!await _confirm(
        'Delete Permanently',
        '"${_fileName(image)}" and its results will be removed forever. This cannot be undone.',
        'Delete Forever')) {
      return;
    }
    await _db.deletePipelineImagePermanently(image.id!);
    _refresh();
  }

  Future<void> _emptyTrash() async {
    if (!await _confirm(
        'Empty Trash',
        'Permanently delete all images in the trash bin (with their results)? This cannot be undone.',
        'Empty Trash')) {
      return;
    }
    final imageCount = await _db.purgeTrashedPipelineImages();
    await _db.emptyTrash(); // legacy rows without a pipeline image
    _refresh();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$imageCount image(s) deleted permanently')),
      );
    }
  }

  String _fileName(PipelineImageEntry image) =>
      image.imagePath.split('/').last;

  /// Deletion timestamp formatted d/M/y HH:mm (epoch ms stored in deleted_at).
  String _deletedLabel(PipelineImageEntry image) {
    if (image.deletedAt == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(image.deletedAt!);
    return '${d.day}/${d.month}/${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _thumbPathOf(String p) {
    final dot = p.lastIndexOf('.');
    return dot == -1 ? '$p.thumb.jpg' : '${p.substring(0, dot)}.thumb.jpg';
  }

  bool _hasThumb(String path) {
    if (_thumbKnown.contains(path)) return true;
    if (File(_thumbPathOf(path)).existsSync()) {
      _thumbKnown.add(path);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: const Text('Trash Bin', style: TextStyle(fontSize: 16)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_forever, size: 20),
            onPressed: _emptyTrash,
            tooltip: 'Empty Trash',
          ),
        ],
      ),
      body: FutureBuilder<List<PipelineImageEntry>>(
        future: _imagesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final images = snapshot.data ?? [];

          if (images.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.delete_outline, size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  Text(
                    'Trash is empty',
                    style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Deleted images appear here before being removed forever',
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(8),
            children: [
              for (final image in images) _buildImageCard(image),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImageCard(PipelineImageEntry image) {
    final projectName = _projectNames[image.projectId];
    final imagePath = image.imagePath;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
                width: 0.5),
          ),
          child: Image.file(
            File(_hasThumb(imagePath) ? _thumbPathOf(imagePath) : imagePath),
            fit: BoxFit.cover,
            cacheWidth: 160,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.image_outlined, size: 24),
          ),
        ),
        title: Text(_fileName(image),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${_statusLabel(image)}'
          '${projectName == null ? '' : ' · was in $projectName'}'
          '${image.deletedAt == null ? '' : ' · Deleted ${_deletedLabel(image)}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => _openImageDetail(image),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.restore),
              onPressed: () => _restoreImage(image),
              tooltip: 'Restore',
            ),
            IconButton(
              icon: const Icon(Icons.delete_forever),
              onPressed: () => _deleteImagePermanently(image),
              tooltip: 'Delete Forever',
              color: Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  /// Read-only viewer of a trashed image's stage progress: which stages ran,
  /// their visualizations, and the classification summary when complete.
  void _openImageDetail(PipelineImageEntry image) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _TrashedImageDetailScreen(image: image),
      ),
    );
  }
}

class _TrashedImageDetailScreen extends StatelessWidget {
  final PipelineImageEntry image;
  const _TrashedImageDetailScreen({required this.image});

  String get _fileName => image.imagePath.split('/').last;

  /// Only completed stages show an icon; not-run/interrupted render none.
  IconData? _statusIcon(String status) {
    switch (status) {
      case 'completed':
        return Icons.check_circle;
      default:
        return null;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return Colors.green;
      case 'running':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String _statusText(String status) {
    switch (status) {
      case 'completed':
        return 'Completed';
      case 'running':
        return 'Interrupted';
      default:
        return 'Not run';
    }
  }

  Widget _preview(String? path, String title, BuildContext context) {
    if (path == null || path.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 200,
        width: double.infinity,
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    ImageViewerScreen(imagePath: path, title: title),
              ),
            ),
            child: Image.file(
              File(path),
              fit: BoxFit.contain,
              cacheWidth: 600,
              errorBuilder: (_, __, ___) => const Icon(Icons.broken_image,
                  size: 32, color: Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stageCard(String title, String status, String? outputPath,
      String viewerTitle, BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (_statusIcon(status) != null) ...[
                  Icon(_statusIcon(status),
                      size: 18, color: _statusColor(status)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Text(_statusText(status),
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey[600])),
              ],
            ),
            _preview(outputPath, viewerTitle, context),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? summary;
    try {
      summary = image.stage3Summary != null
          ? jsonDecode(image.stage3Summary!) as Map<String, dynamic>
          : null;
    } catch (_) {}

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(_fileName,
            style: const TextStyle(fontSize: 15),
            overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _preview(image.imagePath, 'Original — $_fileName', context),
          const SizedBox(height: 12),
          _stageCard('Stage 1 · Warp Grid', image.stage1Status,
              image.stage1OutputPath, 'Stage 1 — Warped plate', context),
          const SizedBox(height: 12),
          _stageCard('Stage 2 · Detect Wells', image.stage2Status,
              image.stage2OutputPath, 'Stage 2 — Detected wells', context),
          const SizedBox(height: 12),
          _stageCard('Stage 3 · Classify', image.stage3Status,
              image.stage3OutputPath, 'Stage 3 — Classification', context),
          if (summary != null) ...[
            const SizedBox(height: 12),
            Card(
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
                          child: Text('Results',
                              style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Growth ${summary['growth'] ?? 0} · '
                      'NoGrowth ${summary['no_growth'] ?? 0} · '
                      'NoAgar ${summary['no_agar'] ?? 0} — '
                      '${summary['total'] ?? 0} wells',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}
