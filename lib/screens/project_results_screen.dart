/// ProjectResultsScreen - View results for a specific project
library project_results_screen;

import 'dart:io';
import 'package:flutter/material.dart';

import '../models/database_helper.dart';
import '../models/inference_service.dart';
import '../utils/constants.dart';
import 'results_screen.dart';

class ProjectResultsScreen extends StatefulWidget {
  final ProjectEntry project;

  const ProjectResultsScreen({super.key, required this.project});

  @override
  State<ProjectResultsScreen> createState() => _ProjectResultsScreenState();
}

class _ProjectResultsScreenState extends State<ProjectResultsScreen> {
  late Future<List<HistoryEntry>> _entriesFuture;
  final DatabaseHelper _db = DatabaseHelper();

  @override
  void initState() {
    super.initState();
    _refreshResults();
  }

  void _refreshResults() {
    if (widget.project.id != null) {
      setState(() {
        _entriesFuture = _db.getResultsByProject(widget.project.id!);
      });
    }
  }

  Future<void> _deleteEntry(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this entry?'),
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
      _refreshResults();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Entry deleted')),
        );
      }
    }
  }

  Future<void> _viewEntry(HistoryEntry entry) async {
    // Reconstruct PipelineResult from HistoryEntry
    final result = PipelineResult(
      imagePath: entry.imagePath,
      annotatedPath: entry.annotatedPath ?? '',
      boxes: [], // Not stored in database
      classes: [], // Not stored in database
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

    _refreshResults();
  }

  Future<void> _deleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Results'),
        content: Text(
          'Are you sure you want to delete all results from "${widget.project.name}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      // Delete all results for this project
      if (widget.project.id != null) {
        final results = await _entriesFuture;
        for (final result in results) {
          if (result.id != null) {
            await _db.deleteResult(result.id!);
          }
        }
        _refreshResults();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('All results deleted')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project.name),
        backgroundColor: Color(widget.project.color),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep),
            tooltip: 'Delete All',
            onPressed: _deleteAll,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _refreshResults,
          ),
        ],
      ),
      body: FutureBuilder<List<HistoryEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error: ${snapshot.error}'),
            );
          }

          final entries = snapshot.data ?? [];

          if (entries.isEmpty) {
            return _buildEmptyState();
          }

          return _buildResultsList(entries);
        },
      ),
    );
  }

  Widget _buildEmptyState() {
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
            'Run analyses to see results here',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList(List<HistoryEntry> entries) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: Color(widget.project.color),
              child: Text(
                '${entry.totalWells}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            title: Text(entry.formattedDate),
            subtitle: Text(entry.countsDisplay),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility),
                  onPressed: () => _viewEntry(entry),
                  tooltip: 'View',
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => _deleteEntry(entry.id!),
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
}
