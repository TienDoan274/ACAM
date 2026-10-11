/// ProjectsScreen - Manage analysis projects
library projects_screen;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/database_helper.dart';
import 'pipeline_screen_v2.dart';
import 'project_create_edit_screen.dart';
import 'project_detail_screen.dart';

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => ProjectsScreenState();
}

class ProjectsScreenState extends State<ProjectsScreen> {
  final DatabaseHelper _db = DatabaseHelper();
  List<ProjectEntry> _projects = [];
  bool _isLoading = true;
  Map<int, int> _projectImageCounts = {};
  String _searchQuery = '';

  /// Projects filtered by the search field (name, case-insensitive).
  List<ProjectEntry> get _filteredProjects {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _projects;
    return _projects
        .where((p) => p.name.toLowerCase().contains(q))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  /// Called by MainScreen whenever the Projects tab becomes visible again
  void refresh() => _loadProjects();

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);

    try {
      final projects = await _db.getAllProjects();

      // Count images managed by each project's workspace (pipeline_images) so
      // the outer count always matches what the user sees inside the project.
      final counts = <int, int>{};
      for (final project in projects) {
        if (project.id != null) {
          counts[project.id!] = await _db.getProjectImageCount(project.id!);
        }
      }

      if (mounted) {
        setState(() {
          _projects = projects;
          _projectImageCounts = counts;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('[ProjectsScreen] Error loading projects: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _deleteProject(ProjectEntry project) async {
    if (project.id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Project'),
        content: Text(
          'Are you sure you want to delete "${project.name}"?\n\n'
          'This will also delete all results associated with this project.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && project.id != null) {
      try {
        await _db.deleteProject(project.id!);
        _loadProjects();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Project deleted')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error deleting project: $e')),
          );
        }
      }
    }
  }

  void _navigateToCreate() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ProjectCreateEditScreen(),
      ),
    ).then((_) => _loadProjects());
  }

  void _navigateToEdit(ProjectEntry project) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectCreateEditScreen(project: project),
      ),
    ).then((_) => _loadProjects());
  }

  void _navigateToResults(ProjectEntry project) {
    if (project.id == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProjectDetailScreen(project: project),
      ),
    ).then((_) => _loadProjects());
  }

  /// Open the working pipeline workspace for this project
  void _openWorkspace(ProjectEntry project) {
    if (project.id == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PipelineWorkspaceScreen(project: project),
      ),
    ).then((_) => _loadProjects());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: const Text('Projects', style: TextStyle(fontSize: 16)),
        actions: [
          // New Project moved up from the FAB so it stays visible beside
          // Refresh (kept the + icon and label from the old FAB).
          FilledButton.icon(
            onPressed: _navigateToCreate,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Project',
                style: TextStyle(fontSize: 13)),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 32),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loadProjects,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? _buildEmptyState()
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: TextField(
                        onChanged: (value) =>
                            setState(() => _searchQuery = value),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search projects by name',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _searchQuery.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () =>
                                      setState(() => _searchQuery = ''),
                                  tooltip: 'Clear',
                                ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _filteredProjects.isEmpty
                          ? Center(
                              child: Text(
                                'No projects match "${_searchQuery.trim()}"',
                                style: TextStyle(
                                    fontSize: 14, color: Colors.grey[600]),
                              ),
                            )
                          : _buildProjectsList(),
                    ),
                  ],
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No projects yet',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.grey[600],
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a project to organize your analyses',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[500],
                ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _navigateToCreate,
            icon: const Icon(Icons.add),
            label: const Text('Create First Project'),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectsList() {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: _filteredProjects.length,
      itemBuilder: (context, index) {
        final project = _filteredProjects[index];
        final imageCount = _projectImageCounts[project.id] ?? 0;

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            onTap: () => _openWorkspace(project),
            onLongPress: () => _navigateToResults(project),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 36,
                      color: Colors.green),
                  const SizedBox(width: 16),
                  // Project info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.name,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        if (project.description != null && project.description!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              project.description!,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(
                              Icons.image_outlined,
                              size: 16,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$imageCount ${imageCount == 1 ? 'image' : 'images'}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                            ),
                            const SizedBox(width: 16),
                            Icon(
                              Icons.calendar_today,
                              size: 16,
                              color: Colors.grey[600],
                            ),
                            const SizedBox(width: 4),
                            Text(
                              project.formattedDate,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.grey[600],
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Actions
                  IconButton(
                    icon: const Icon(Icons.edit),
                    onPressed: () => _navigateToEdit(project),
                    tooltip: 'Edit',
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete),
                    onPressed: () => _deleteProject(project),
                    tooltip: 'Delete',
                    color: Colors.red,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
