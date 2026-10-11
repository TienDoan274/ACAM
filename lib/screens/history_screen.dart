import 'dart:io';
import 'package:flutter/material.dart';

import '../models/database_helper.dart';
import '../models/inference_service.dart';
import '../utils/constants.dart';
import 'results_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => HistoryScreenState();
}

class HistoryScreenState extends State<HistoryScreen> {
  late Future<List<HistoryEntry>> _entriesFuture;
  final DatabaseHelper _db = DatabaseHelper();
  List<ProjectEntry> _projects = [];
  int? _selectedProjectId; // null = All, >0 = specific project

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _refreshHistory();
  }

  /// Called by MainScreen whenever the History tab becomes visible again
  void refresh() {
    _loadProjects();
    _refreshHistory();
  }

  Future<void> _loadProjects() async {
    try {
      final projects = await _db.getAllProjects();
      if (mounted) {
        setState(() => _projects = projects);
      }
    } catch (e) {
      print('[HistoryScreen] Error loading projects: $e');
    }
  }

  void _refreshHistory() {
    setState(() {
      if (_selectedProjectId == null) {
        // All results
        _entriesFuture = _db.getAllResults();
      } else {
        // Specific project
        _entriesFuture = _db.getResultsByProject(_selectedProjectId!);
      }
    });
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

    _refreshHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: const Text('History', style: TextStyle(fontSize: 16)),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep, size: 20),
            onPressed: _clearAllHistory,
            tooltip: 'Clear All',
          ),
        ],
        bottom: _projects.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(50),
                child: SizedBox(
                  height: 50,
                  child: _buildFilterChips(),
                ),
              )
            : null,
      ),
      body: FutureBuilder<List<HistoryEntry>>(
        future: _entriesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _refreshHistory,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final entries = snapshot.data ?? [];

          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.history,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No history yet',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Results will be saved here',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: entries.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _HistoryCard(
                entry: entry,
                onView: () => _viewEntry(entry),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _clearAllHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History'),
        content: const Text('Are you sure you want to delete all entries?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _db.moveAllResultsToTrash();
      _refreshHistory();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('History cleared (moved to trash)')),
        );
      }
    }
  }

  Widget _buildFilterChips() {
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      children: [
        // "All" chip
        _FilterChip(
          label: 'All',
          isSelected: _selectedProjectId == null,
          onSelected: () {
            setState(() => _selectedProjectId = null);
            _refreshHistory();
          },
        ),
        // Project chips
        ..._projects.map((project) => _FilterChip(
              label: project.name,
              isSelected: _selectedProjectId == project.id,
              onSelected: () {
                setState(() => _selectedProjectId = project.id);
                _refreshHistory();
              },
            )),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onSelected;

  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) => onSelected(),
        labelStyle: TextStyle(
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final HistoryEntry entry;
  final VoidCallback onView;

  const _HistoryCard({
    required this.entry,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: Text('${entry.totalWells}'),
        ),
        title: Text(
          entry.imagePath.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${entry.countsDisplay} · ${entry.formattedDate}'
          '${entry.inTrash ? ' · In trash bin' : ''}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.visibility),
          onPressed: onView,
          tooltip: 'View',
        ),
      ),
    );
  }
}
