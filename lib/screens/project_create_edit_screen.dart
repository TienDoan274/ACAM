/// ProjectCreateEditScreen - Create or edit a project
library project_create_edit_screen;

import 'package:flutter/material.dart';

import '../models/database_helper.dart';

class ProjectCreateEditScreen extends StatefulWidget {
  final ProjectEntry? project;

  const ProjectCreateEditScreen({super.key, this.project});

  @override
  State<ProjectCreateEditScreen> createState() =>
      _ProjectCreateEditScreenState();
}

class _ProjectCreateEditScreenState extends State<ProjectCreateEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final DatabaseHelper _db = DatabaseHelper();

  bool _isSaving = false;

  /// Normalized names of every other project — duplicate names are rejected
  /// (case/whitespace-insensitive) so projects stay uniquely identifiable.
  final List<String> _existingNames = [];

  @override
  void initState() {
    super.initState();
    if (widget.project != null) {
      _nameController.text = widget.project!.name;
      _descriptionController.text = widget.project!.description ?? '';
    }
    _loadExistingNames();
  }

  Future<void> _loadExistingNames() async {
    try {
      final projects = await _db.getAllProjects();
      if (mounted) {
        setState(() {
          _existingNames
            ..clear()
            ..addAll(projects
                .where((p) => p.id != widget.project?.id) // own name is fine
                .map((p) => p.name.trim().toLowerCase()));
        });
      }
    } catch (e) {
      print('[ProjectCreateEdit] Error loading projects: $e');
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      if (widget.project == null) {
        // Create new project — pop with its ID so caller can assign results
        final project = ProjectEntry(
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          createdAt: now,
          updatedAt: now,
        );
        final newId = await _db.insertProject(project);
        if (mounted) {
          Navigator.pop(context, newId);
          return;
        }
      } else {
        // Update existing project
        final updatedProject = widget.project!.copyWith(
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          updatedAt: now,
        );
        await _db.updateProject(updatedProject);
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      print('[ProjectCreateEdit] Error saving project: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving project: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.project != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Project' : 'New Project'),
        actions: [
          if (!_isSaving)
            TextButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          if (_isSaving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Project name
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Project Name',
                hintText: 'Enter project name',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter a project name';
                }
                if (_existingNames.contains(value.trim().toLowerCase())) {
                  return 'A project with this name already exists';
                }
                return null;
              },
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),

            // Description
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                hintText: 'Enter project description',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
          ],
        ),
      ),
    );
  }
}
