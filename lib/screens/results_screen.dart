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

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Results'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: _shareResult,
            tooltip: 'Share',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _isSaving ? null : _saveToHistory,
            tooltip: 'Save to History',
          ),
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
                  '${result.boxes.length}',
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
                label: WellClasses.growthLabel,
                count: result.getCount('growth'),
                color: Color(WellClasses.growthColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ClassCard(
                label: WellClasses.noGrowthLabel,
                count: result.getCount('no_growth'),
                color: Color(WellClasses.noGrowthColor),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ClassCard(
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

  Future<void> _saveToHistory() async {
    setState(() {
      _isSaving = true;
    });

    try {
      final dbHelper = DatabaseHelper();
      final entry = HistoryEntry(
        imagePath: widget.result.imagePath,
        annotatedPath: widget.result.annotatedPath,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        totalWells: widget.result.boxes.length,
        growthCount: widget.result.getCount('growth'),
        noGrowthCount: widget.result.getCount('no_growth'),
        noAgarCount: widget.result.getCount('no_agar'),
        processingTimeMs: widget.result.processingTimeMs,
      );

      await dbHelper.insertResult(entry);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Saved to history'),
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
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
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
        ['Total', widget.result.boxes.length],
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

**Detected Wells**: ${widget.result.boxes.length}

### Corners (pixel coordinates)
- TL: (${widget.result.corners[0]['x']!.toStringAsFixed(1)}, ${widget.result.corners[0]['y']!.toStringAsFixed(1)})
- TR: (${widget.result.corners[1]['x']!.toStringAsFixed(1)}, ${widget.result.corners[1]['y']!.toStringAsFixed(1)})
- BR: (${widget.result.corners[2]['x']!.toStringAsFixed(1)}, ${widget.result.corners[2]['y']!.toStringAsFixed(1)})
- BL: (${widget.result.corners[3]['x']!.toStringAsFixed(1)}, ${widget.result.corners[3]['y']!.toStringAsFixed(1)})

### Class Distribution
- Growth: ${widget.result.getCount('growth')} (${(widget.result.getCount('growth') * 100 / widget.result.boxes.length).toStringAsFixed(1)}%)
- NoGrowth: ${widget.result.getCount('no_growth')} (${(widget.result.getCount('no_growth') * 100 / widget.result.boxes.length).toStringAsFixed(1)}%)
- NoAgar: ${widget.result.getCount('no_agar')} (${(widget.result.getCount('no_agar') * 100 / widget.result.boxes.length).toStringAsFixed(1)}%)

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
  final Color color;

  const _ClassCard({
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final percentage = count > 0
        ? (count / 384 * 100).toStringAsFixed(1)
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
