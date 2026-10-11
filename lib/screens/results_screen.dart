import 'dart:io';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:csv/csv.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/inference_service.dart';
import '../models/database_helper.dart';
import '../utils/constants.dart';

class ResultsScreen extends StatefulWidget {
  final PipelineResult result;

  const ResultsScreen({super.key, required this.result});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  bool _isSaving = false;
  bool _isInTrash = false;
  int? _selectedProjectId;
  List<ProjectEntry> _projects = [];
  final DatabaseHelper _db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _loadCurrentAssignment();
  }

  Future<void> _loadProjects() async {
    try {
      final projects = await _db.getAllProjects();
      if (mounted) {
        setState(() {
          _projects = projects;
          // If the assigned project was deleted (or result removed from it), reset
          if (_selectedProjectId != null &&
              !projects.any((p) => p.id == _selectedProjectId)) {
            _selectedProjectId = null;
          }
        });
      }
    } catch (e) {
      print('[ResultsScreen] Error loading projects: $e');
    }
  }

  /// If this result is already assigned to a project (auto-saved entry), reflect it on the button.
  /// A trashed result instead shows "In trash bin" — the trash state lives on
  /// the owning pipeline image (the single source of truth).
  Future<void> _loadCurrentAssignment() async {
    try {
      final image = await _db.getPipelineImageByPath(widget.result.imagePath);
      final inTrash = image?.deletedAt != null;
      final entry = await _db.getLatestResultByAnnotatedPath(widget.result.annotatedPath);
      if (mounted) {
        setState(() {
          _isInTrash = inTrash;
          if (!inTrash && entry?.projectId != null) {
            _selectedProjectId = entry!.projectId;
          }
        });
      }
    } catch (e) {
      print('[ResultsScreen] Error loading assignment: $e');
    }
  }

  /// Show project picker sheet → returns selected project id, -2 = move to trash
  Future<void> _showProjectPicker() async {
    // No projects to pick from — the picker only reassigns between existing
    // projects (project creation lives in the Projects tab).
    if (_projects.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No projects yet — create one in the Projects tab')),
        );
      }
      return;
    }

    final result = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true, // Allow full height
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7, // 70% screen height
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  _selectedProjectId == null ? 'Add to Project' : 'Manage Project',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _projects.length,
                  itemBuilder: (context, index) {
                    final project = _projects[index];
                    final isAssigned = _selectedProjectId == project.id;
                    return ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(project.name),
                      trailing: isAssigned
                          ? const Icon(Icons.check_circle, color: Colors.green)
                          : null,
                      onTap: () => Navigator.pop(context, project.id),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text(
                  'Move to Trash Bin',
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () => Navigator.pop(context, -2),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );

    if (!mounted || result == null) return; // dismissed

    if (result == -2) {
      await _moveToTrash();
      return;
    }

    await _assignToProject(result);
  }

  /// Find the auto-saved history entry for this result; insert one if missing.
  /// Returns the entry id (or null on failure).
  Future<int?> _ensureHistoryEntry() async {
    final existing = await _db.getLatestResultByAnnotatedPath(widget.result.annotatedPath);
    if (existing?.id != null) return existing!.id;

    // No auto-saved entry found (e.g. opened from old history) → insert one
    return await _db.insertResult(HistoryEntry(
      imagePath: widget.result.imagePath,
      annotatedPath: widget.result.annotatedPath,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      totalWells: widget.result.totalWells,
      growthCount: widget.result.getCount('growth'),
      noGrowthCount: widget.result.getCount('no_growth'),
      noAgarCount: widget.result.getCount('no_agar'),
      processingTimeMs: widget.result.processingTimeMs,
    ));
  }

  /// Assign the current result to a project (updates the auto-saved history
  /// entry AND the owning pipeline image, so the project's workspace image
  /// list matches what History reports).
  Future<void> _assignToProject(int projectId) async {
    setState(() => _isSaving = true);
    try {
      final entryId = await _ensureHistoryEntry();
      if (entryId != null) {
        await _db.updateResultProject(entryId, projectId);
      }
      // Keep the workspace in sync: the pipeline image follows its result.
      await _db.updatePipelineImageProjectByPath(widget.result.imagePath, projectId);

      if (mounted) {
        setState(() => _selectedProjectId = projectId);
        final project = _projects.where((p) => p.id == projectId).firstOrNull;
        final projectName = project?.name ?? 'project';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added to $projectName'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add to project: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  /// Move this result to the trash bin (soft delete) and close the viewer.
  /// The trash is image-centric: the pipeline image behind the result goes to
  /// the trash (its results follow), so it can be restored or inspected there.
  Future<void> _moveToTrash() async {
    setState(() => _isSaving = true);
    try {
      final entry = await _db.getLatestResultByAnnotatedPath(widget.result.annotatedPath);
      final imageId = entry?.pipelineImageId ??
          (await _db.getPipelineImageByPath(widget.result.imagePath))?.id;
      if (imageId != null) {
        await _db.movePipelineImageToTrash(imageId);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Moved to trash bin')),
        );
        Navigator.pop(context); // back to History, which refreshes on return
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to move to trash: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          // More options
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'export_csv', child: Text('Export CSV')),
              const PopupMenuItem(value: 'export_pdf', child: Text('Export PDF')),
              const PopupMenuItem(value: 'view_details', child: Text('View Details')),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Stats cards
            _buildStatsCards(result),

            const SizedBox(height: 20),

            // Processing time
            Card(
              child: ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Processing Time'),
                trailing: Text(
                  '${result.processingTimeMs.toStringAsFixed(0)} ms',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // Annotated image
            _buildAnnotatedImage(result),

            const SizedBox(height: 20),

            // Legend
            _buildLegend(),

            // Add padding at bottom for button bar
            const SizedBox(height: 80),
          ],
        ),
      ),
      // Bottom button bar with Add to Project and Share
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Expanded(
              child: Builder(builder: (context) {
                final assignedProject = _projects
                    .where((p) => p.id == _selectedProjectId)
                    .firstOrNull;
                final isInProject = assignedProject != null;

                return ElevatedButton.icon(
                  onPressed: (_isSaving || _isInTrash) ? null : _showProjectPicker,
                  icon: _isSaving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(_isInTrash
                          ? Icons.delete_outline
                          : (isInProject ? Icons.folder : Icons.create_new_folder)),
                  label: Text(
                    _isSaving
                        ? 'Saving...'
                        : (_isInTrash
                            ? 'In trash bin'
                            : (isInProject
                                ? 'In project: ${assignedProject.name}'
                                : 'Add to Project')),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                    backgroundColor: _isInTrash ? Colors.grey : Colors.green,
                    foregroundColor: Colors.white,
                  ),
                );
              }),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _shareResult,
                icon: const Icon(Icons.share),
                label: const Text('Share'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCards(PipelineResult result) {
    return Column(
      children: [
        // Total wells
        Card(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Total Wells',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${result.totalWells}',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 12),

        // Class breakdown
        Row(
          children: [
            Expanded(
              child: _ClassCard(
                total: result.totalWells,
                label: WellClasses.growthLabel,
                count: result.getCount('growth'),
                color: Color(WellClasses.growthColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ClassCard(
                total: result.totalWells,
                label: WellClasses.noGrowthLabel,
                count: result.getCount('no_growth'),
                color: Color(WellClasses.noGrowthColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ClassCard(
                total: result.totalWells,
                label: WellClasses.noAgarLabel,
                count: result.getCount('no_agar'),
                color: Color(WellClasses.noAgarColor),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAnnotatedImage(PipelineResult result) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Annotated Image',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            FutureBuilder<File>(
              future: Future.value(File(result.annotatedPath)),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError || !snapshot.hasData) {
                  return const Text('Failed to load image');
                }

                return Image.file(
                  snapshot.data!,
                  fit: BoxFit.contain,
                  // Decode at screen resolution — full-res annotated PNGs
                  // (~4000px) stall the raster thread and freeze scrolling.
                  cacheWidth: (MediaQuery.sizeOf(context).width *
                          MediaQuery.devicePixelRatioOf(context))
                      .round(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Legend',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _LegendItem(
              color: Color(WellClasses.growthColor),
              label: WellClasses.growthLabel,
            ),
            const SizedBox(height: 8),
            _LegendItem(
              color: Color(WellClasses.noGrowthColor),
              label: WellClasses.noGrowthLabel,
            ),
            const SizedBox(height: 8),
            _LegendItem(
              color: Color(WellClasses.noAgarColor),
              label: WellClasses.noAgarLabel,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shareResult() async {
    try {
      final file = File(widget.result.annotatedPath);
      await Share.shareXFiles([XFile(file.path)], text: widget.result.countsDisplay);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: $e')),
        );
      }
    }
  }

  Future<void> _handleMenuAction(String action) async {
    switch (action) {
      case 'export_csv':
        await _exportCSV();
        break;
      case 'export_pdf':
        await _exportPDF();
        break;
      case 'view_details':
        _viewDetails();
        break;
    }
  }

  Future<void> _exportCSV() async {
    try {
      final rows = [
        ['Class', 'Count'],
        ['Growth', widget.result.getCount('growth')],
        ['NoGrowth', widget.result.getCount('no_growth')],
        ['NoAgar', widget.result.getCount('no_agar')],
        ['Total', widget.result.totalWells],
        ['Processing Time (ms)', widget.result.processingTimeMs.toStringAsFixed(2)],
      ];

      final csvString = const ListToCsvConverter().convert(rows);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/microplate_results_${DateTime.now().millisecondsSinceEpoch}.csv');
      await file.writeAsString(csvString);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('CSV saved: ${file.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export CSV: $e')),
        );
      }
    }
  }

  Future<void> _exportPDF() async {
    // Placeholder for PDF export
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PDF export not yet implemented')),
      );
    }
  }

  void _viewDetails() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Pipeline Details'),
        content: SingleChildScrollView(
          child: MarkdownBody(
            data: '''
## Processing Details

**Input Image**: ${widget.result.imagePath}

**Detected Wells**: ${widget.result.totalWells}

### Corners (pixel coordinates)
- TL: (${widget.result.corners[0]['x']!.toStringAsFixed(1)}, ${widget.result.corners[0]['y']!.toStringAsFixed(1)})
- TR: (${widget.result.corners[1]['x']!.toStringAsFixed(1)}, ${widget.result.corners[1]['y']!.toStringAsFixed(1)})
- BR: (${widget.result.corners[2]['x']!.toStringAsFixed(1)}, ${widget.result.corners[2]['y']!.toStringAsFixed(1)})
- BL: (${widget.result.corners[3]['x']!.toStringAsFixed(1)}, ${widget.result.corners[3]['y']!.toStringAsFixed(1)})

### Class Distribution
- Growth: ${widget.result.getCount('growth')} (${(widget.result.getCount('growth') * 100 / widget.result.totalWells).toStringAsFixed(1)}%)
- NoGrowth: ${widget.result.getCount('no_growth')} (${(widget.result.getCount('no_growth') * 100 / widget.result.totalWells).toStringAsFixed(1)}%)
- NoAgar: ${widget.result.getCount('no_agar')} (${(widget.result.getCount('no_agar') * 100 / widget.result.totalWells).toStringAsFixed(1)}%)

### Performance
- Processing Time: ${widget.result.processingTimeMs.toStringAsFixed(2)} ms
- Inference Engine: TensorFlow Lite (on-device)
            ''',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _ClassCard extends StatelessWidget {
  final String label;
  final int count;
  final int total; // số well của plate (R×C khi chỉnh tay, không cố định 384)
  final Color color;

  const _ClassCard({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final percentage = count > 0 && total > 0
        ? (count / total * 100).toStringAsFixed(1)
        : '0.0';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '$count',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '$percentage%',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendItem({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}
