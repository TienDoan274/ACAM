/// SQLite database helper cho lưu history
library database_helper;

import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../utils/constants.dart';

/// Project entry
class ProjectEntry {
  final int? id;
  final String name;
  final String? description;
  final int createdAt;
  final int updatedAt;
  final int color;

  ProjectEntry({
    this.id,
    required this.name,
    this.description,
    required this.createdAt,
    required this.updatedAt,
    this.color = 0xFF4CAF50,
  });

  factory ProjectEntry.fromMap(Map<String, dynamic> map) {
    return ProjectEntry(
      id: map[DatabaseSchema.colProjectId] as int?,
      name: map[DatabaseSchema.colProjectName] as String,
      description: map[DatabaseSchema.colProjectDescription] as String?,
      createdAt: map[DatabaseSchema.colProjectCreatedAt] as int,
      updatedAt: map[DatabaseSchema.colProjectUpdatedAt] as int,
      color: map[DatabaseSchema.colProjectColor] as int? ?? 0xFF4CAF50,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colProjectId: id,
      DatabaseSchema.colProjectName: name,
      DatabaseSchema.colProjectDescription: description,
      DatabaseSchema.colProjectCreatedAt: createdAt,
      DatabaseSchema.colProjectUpdatedAt: updatedAt,
      DatabaseSchema.colProjectColor: color,
    };
  }

  String get formattedDate {
    final date = DateTime.fromMillisecondsSinceEpoch(createdAt);
    return '${date.day}/${date.month}/${date.year}';
  }

  ProjectEntry copyWith({
    int? id,
    String? name,
    String? description,
    int? createdAt,
    int? updatedAt,
    int? color,
  }) {
    return ProjectEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      color: color ?? this.color,
    );
  }
}

/// Project image entry
class ProjectImageEntry {
  final int? id;
  final int projectId;
  final String imagePath;
  final String status;
  final int createdAt;

  ProjectImageEntry({
    this.id,
    required this.projectId,
    required this.imagePath,
    this.status = 'pending',
    required this.createdAt,
  });

  factory ProjectImageEntry.fromMap(Map<String, dynamic> map) {
    return ProjectImageEntry(
      id: map[DatabaseSchema.colImageId] as int?,
      projectId: map[DatabaseSchema.colImageProjectId] as int,
      imagePath: map[DatabaseSchema.colImagePath] as String,
      status: map[DatabaseSchema.colImageStatus] as String? ?? 'pending',
      createdAt: map[DatabaseSchema.colImageCreatedAt] as int,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colImageId: id,
      DatabaseSchema.colImageProjectId: projectId,
      DatabaseSchema.colImagePath: imagePath,
      DatabaseSchema.colImageStatus: status,
      DatabaseSchema.colImageCreatedAt: createdAt,
    };
  }
}

/// Pipeline folder entry
class PipelineFolderEntry {
  final int? id;
  final String name;
  final int? parentId;
  final int position;
  final int createdAt;

  PipelineFolderEntry({
    this.id,
    required this.name,
    this.parentId,
    this.position = 0,
    required this.createdAt,
  });

  factory PipelineFolderEntry.fromMap(Map<String, dynamic> map) {
    return PipelineFolderEntry(
      id: map[DatabaseSchema.colFolderId] as int?,
      name: map[DatabaseSchema.colFolderName] as String,
      parentId: map[DatabaseSchema.colFolderParentId] as int?,
      position: map[DatabaseSchema.colFolderPosition] as int? ?? 0,
      createdAt: map[DatabaseSchema.colFolderCreatedAt] as int,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colFolderId: id,
      DatabaseSchema.colFolderName: name,
      DatabaseSchema.colFolderParentId: parentId,
      DatabaseSchema.colFolderPosition: position,
      DatabaseSchema.colFolderCreatedAt: createdAt,
    };
  }

  PipelineFolderEntry copyWith({
    int? id,
    String? name,
    int? parentId,
    int? position,
    int? createdAt,
  }) {
    return PipelineFolderEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: parentId ?? this.parentId,
      position: position ?? this.position,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Pipeline image entry with stage statuses
class PipelineImageEntry {
  final int? id;
  final int? folderId;
  final int? projectId;
  final String imagePath;
  final String stage1Status;
  final String stage2Status;
  final String stage3Status;
  final String? stage1OutputPath;
  final String? stage2OutputPath;
  final String? stage3OutputPath;
  final String? stage3Summary; // JSON: {total,growth,no_growth,no_agar,confs:[...]}
  final String? stage3ConfPath; // annotated PNG with per-well confidence
  final String? stage1Meta; // JSON Stage1Meta (v7): source, corners, warped_path, qc
  final String? stage2Meta; // JSON Stage2Meta (v7): source, result_path, rows/cols, manual input, stats
  final int? deletedAt; // non-null while the image sits in the trash bin
  final int createdAt;
  final int updatedAt;

  PipelineImageEntry({
    this.id,
    this.folderId,
    this.projectId,
    required this.imagePath,
    this.stage1Status = 'pending',
    this.stage2Status = 'pending',
    this.stage3Status = 'pending',
    this.stage1OutputPath,
    this.stage2OutputPath,
    this.stage3OutputPath,
    this.stage3Summary,
    this.stage3ConfPath,
    this.stage1Meta,
    this.stage2Meta,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  factory PipelineImageEntry.fromMap(Map<String, dynamic> map) {
    return PipelineImageEntry(
      id: map[DatabaseSchema.colPipelineImageId] as int?,
      folderId: map[DatabaseSchema.colPipelineImageFolderId] as int?,
      projectId: map[DatabaseSchema.colPipelineImageProjectId] as int?,
      imagePath: map[DatabaseSchema.colPipelineImagePath] as String,
      stage1Status: map[DatabaseSchema.colPipelineStage1Status] as String? ?? 'pending',
      stage2Status: map[DatabaseSchema.colPipelineStage2Status] as String? ?? 'pending',
      stage3Status: map[DatabaseSchema.colPipelineStage3Status] as String? ?? 'pending',
      stage1OutputPath: map[DatabaseSchema.colPipelineStage1Output] as String?,
      stage2OutputPath: map[DatabaseSchema.colPipelineStage2Output] as String?,
      stage3OutputPath: map[DatabaseSchema.colPipelineStage3Output] as String?,
      stage3Summary: map[DatabaseSchema.colPipelineStage3Summary] as String?,
      stage3ConfPath: map[DatabaseSchema.colPipelineStage3ConfPath] as String?,
      stage1Meta: map[DatabaseSchema.colPipelineStage1Meta] as String?,
      stage2Meta: map[DatabaseSchema.colPipelineStage2Meta] as String?,
      deletedAt: map[DatabaseSchema.colPipelineImageDeletedAt] as int?,
      createdAt: map[DatabaseSchema.colPipelineImageCreatedAt] as int,
      updatedAt: map[DatabaseSchema.colPipelineImageUpdatedAt] as int,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colPipelineImageId: id,
      if (folderId != null) DatabaseSchema.colPipelineImageFolderId: folderId,
      if (projectId != null) DatabaseSchema.colPipelineImageProjectId: projectId,
      DatabaseSchema.colPipelineImagePath: imagePath,
      DatabaseSchema.colPipelineStage1Status: stage1Status,
      DatabaseSchema.colPipelineStage2Status: stage2Status,
      DatabaseSchema.colPipelineStage3Status: stage3Status,
      DatabaseSchema.colPipelineStage1Output: stage1OutputPath,
      DatabaseSchema.colPipelineStage2Output: stage2OutputPath,
      DatabaseSchema.colPipelineStage3Output: stage3OutputPath,
      DatabaseSchema.colPipelineStage3Summary: stage3Summary,
      DatabaseSchema.colPipelineStage3ConfPath: stage3ConfPath,
      DatabaseSchema.colPipelineStage1Meta: stage1Meta,
      DatabaseSchema.colPipelineStage2Meta: stage2Meta,
      DatabaseSchema.colPipelineImageCreatedAt: createdAt,
      DatabaseSchema.colPipelineImageUpdatedAt: updatedAt,
    };
  }

  /// Get overall status (highest stage completed)
  String get overallStatus {
    if (stage3Status == 'completed') return 'full_done';
    if (stage2Status == 'completed') return 'stage2_done';
    if (stage1Status == 'completed') return 'stage1_done';
    if (stage1Status == 'running' || stage2Status == 'running' || stage3Status == 'running') {
      return 'running';
    }
    return 'pending';
  }

  /// Check if all stages are completed
  bool get isFullDone => stage1Status == 'completed' &&
      stage2Status == 'completed' &&
      stage3Status == 'completed';

  PipelineImageEntry copyWith({
    int? id,
    int? folderId,
    int? projectId,
    String? imagePath,
    String? stage1Status,
    String? stage2Status,
    String? stage3Status,
    String? stage1OutputPath,
    String? stage2OutputPath,
    String? stage3OutputPath,
    String? stage3Summary,
    String? stage3ConfPath,
    String? stage1Meta,
    String? stage2Meta,
    int? deletedAt,
    int? createdAt,
    int? updatedAt,
  }) {
    return PipelineImageEntry(
      id: id ?? this.id,
      folderId: folderId ?? this.folderId,
      projectId: projectId ?? this.projectId,
      imagePath: imagePath ?? this.imagePath,
      stage1Status: stage1Status ?? this.stage1Status,
      stage2Status: stage2Status ?? this.stage2Status,
      stage3Status: stage3Status ?? this.stage3Status,
      stage1OutputPath: stage1OutputPath ?? this.stage1OutputPath,
      stage2OutputPath: stage2OutputPath ?? this.stage2OutputPath,
      stage3OutputPath: stage3OutputPath ?? this.stage3OutputPath,
      stage3Summary: stage3Summary ?? this.stage3Summary,
      stage3ConfPath: stage3ConfPath ?? this.stage3ConfPath,
      stage1Meta: stage1Meta ?? this.stage1Meta,
      stage2Meta: stage2Meta ?? this.stage2Meta,
      deletedAt: deletedAt ?? this.deletedAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}


/// Result entry từ database
class HistoryEntry {
  final int? id;
  final String imagePath;
  final String? annotatedPath;
  final int timestamp;
  final int totalWells;
  final int growthCount;
  final int noGrowthCount;
  final int noAgarCount;
  final double? processingTimeMs;
  final int? projectId;
  final int? imageId;
  final int? pipelineImageId;

  /// Computed by History queries (not a column): the result's pipeline image
  /// sits in the trash bin. Trashed results stay listed in History until the
  /// trash entry is permanently deleted.
  final bool inTrash;

  HistoryEntry({
    this.id,
    required this.imagePath,
    this.annotatedPath,
    required this.timestamp,
    required this.totalWells,
    required this.growthCount,
    required this.noGrowthCount,
    required this.noAgarCount,
    this.processingTimeMs,
    this.projectId,
    this.imageId,
    this.pipelineImageId,
    this.inTrash = false,
  });

  /// Convert từ database row
  factory HistoryEntry.fromMap(Map<String, dynamic> map) {
    return HistoryEntry(
      id: map[DatabaseSchema.colId] as int?,
      imagePath: map[DatabaseSchema.colResultImagePath] as String,
      annotatedPath: map[DatabaseSchema.colAnnotatedPath] as String?,
      timestamp: map[DatabaseSchema.colTimestamp] as int,
      totalWells: map[DatabaseSchema.colTotal] as int,
      growthCount: map[DatabaseSchema.colGrowth] as int,
      noGrowthCount: map[DatabaseSchema.colNoGrowth] as int,
      noAgarCount: map[DatabaseSchema.colNoAgar] as int,
      processingTimeMs: map[DatabaseSchema.colProcessingTime] as double?,
      projectId: map[DatabaseSchema.colResultProjectId] as int?,
      imageId: map[DatabaseSchema.colResultImageId] as int?,
      pipelineImageId: map[DatabaseSchema.colResultPipelineImageId] as int?,
      inTrash: (map['in_trash'] as int? ?? 0) == 1,
    );
  }

  /// Convert to database row
  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colId: id,
      DatabaseSchema.colResultImagePath: imagePath,
      DatabaseSchema.colAnnotatedPath: annotatedPath,
      DatabaseSchema.colTimestamp: timestamp,
      DatabaseSchema.colTotal: totalWells,
      DatabaseSchema.colGrowth: growthCount,
      DatabaseSchema.colNoGrowth: noGrowthCount,
      DatabaseSchema.colNoAgar: noAgarCount,
      DatabaseSchema.colProcessingTime: processingTimeMs,
      DatabaseSchema.colResultProjectId: projectId,
      DatabaseSchema.colResultImageId: imageId,
      DatabaseSchema.colResultPipelineImageId: pipelineImageId,
    };
  }

  /// Format timestamp
  String get formattedDate {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  /// Get counts display
  String get countsDisplay {
    return 'Growth: $growthCount | NoGrowth: $noGrowthCount | NoAgar: $noAgarCount';
  }

  HistoryEntry copyWith({
    int? id,
    String? imagePath,
    String? annotatedPath,
    int? timestamp,
    int? totalWells,
    int? growthCount,
    int? noGrowthCount,
    int? noAgarCount,
    double? processingTimeMs,
    int? projectId,
    int? imageId,
    int? pipelineImageId,
  }) {
    return HistoryEntry(
      id: id ?? this.id,
      imagePath: imagePath ?? this.imagePath,
      annotatedPath: annotatedPath ?? this.annotatedPath,
      timestamp: timestamp ?? this.timestamp,
      totalWells: totalWells ?? this.totalWells,
      growthCount: growthCount ?? this.growthCount,
      noGrowthCount: noGrowthCount ?? this.noGrowthCount,
      noAgarCount: noAgarCount ?? this.noAgarCount,
      processingTimeMs: processingTimeMs ?? this.processingTimeMs,
      projectId: projectId ?? this.projectId,
      imageId: imageId ?? this.imageId,
      pipelineImageId: pipelineImageId ?? this.pipelineImageId,
    );
  }
}

/// Database helper
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, DatabaseSchema.dbName);

    return await openDatabase(
      path,
      version: DatabaseSchema.dbVersion,
      onCreate: (db, version) async {
        // Create all tables for new installs
        await db.execute(DatabaseSchema.createPipelineFoldersTableSQL);
        await db.execute(DatabaseSchema.createPipelineImagesTableSQL);
        await db.execute(DatabaseSchema.createProjectsTableSQL);
        await db.execute(DatabaseSchema.createProjectImagesTableSQL);
        await db.execute(DatabaseSchema.createResultsTableSQL);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Handle migration from v1 to v2
        if (oldVersion < 2) {
          // Add new columns to existing results table
          try {
            await db.execute('ALTER TABLE ${DatabaseSchema.tableResults} ADD COLUMN ${DatabaseSchema.colResultProjectId} INTEGER');
          } catch (e) {
            // Column might already exist
          }
          try {
            await db.execute('ALTER TABLE ${DatabaseSchema.tableResults} ADD COLUMN ${DatabaseSchema.colResultImageId} INTEGER');
          } catch (e) {
            // Column might already exist
          }

          // Create projects table
          await db.execute(DatabaseSchema.createProjectsTableSQL);

          // Create project_images table
          await db.execute(DatabaseSchema.createProjectImagesTableSQL);
        }

        // Handle migration from v2 to v3
        if (oldVersion < 3) {
          // Add pipeline_image_id column to results table
          try {
            await db.execute('ALTER TABLE ${DatabaseSchema.tableResults} ADD COLUMN ${DatabaseSchema.colResultPipelineImageId} INTEGER');
          } catch (e) {
            // Column might already exist
          }

          // Create pipeline folders and images tables
          await db.execute(DatabaseSchema.createPipelineFoldersTableSQL);
          await db.execute(DatabaseSchema.createPipelineImagesTableSQL);
        }

        // Handle migration from v3 to v4: project binding + stage3 detail data
        if (oldVersion < 4) {
          final alterCols = [
            'ALTER TABLE ${DatabaseSchema.tablePipelineImages} ADD COLUMN ${DatabaseSchema.colPipelineImageProjectId} INTEGER',
            'ALTER TABLE ${DatabaseSchema.tablePipelineImages} ADD COLUMN ${DatabaseSchema.colPipelineStage3Summary} TEXT',
            'ALTER TABLE ${DatabaseSchema.tablePipelineImages} ADD COLUMN ${DatabaseSchema.colPipelineStage3ConfPath} TEXT',
          ];
          for (final sql in alterCols) {
            try {
              await db.execute(sql);
            } catch (e) {
              // Column might already exist
            }
          }
        }

        // Handle migration from v4 to v5: trash bin (soft delete) + pipeline
        // binding on results. pipeline_image_id is guarded too: fresh installs
        // created at v3/v4 via onCreate never had it (it only existed in the
        // v3 ALTER path for upgraded databases).
        if (oldVersion < 5) {
          final alterCols = [
            'ALTER TABLE ${DatabaseSchema.tableResults} ADD COLUMN ${DatabaseSchema.colResultDeletedAt} INTEGER',
            'ALTER TABLE ${DatabaseSchema.tableResults} ADD COLUMN ${DatabaseSchema.colResultPipelineImageId} INTEGER',
          ];
          for (final sql in alterCols) {
            try {
              await db.execute(sql);
            } catch (e) {
              // Column might already exist
            }
          }
          // Backfill: bind pre-v5 results to their pipeline image so existing
          // full-pipeline results keep showing in History (paths are unique).
          try {
            await db.execute('''
              UPDATE ${DatabaseSchema.tableResults} SET ${DatabaseSchema.colResultPipelineImageId} = (
                SELECT ${DatabaseSchema.colPipelineImageId} FROM ${DatabaseSchema.tablePipelineImages}
                WHERE ${DatabaseSchema.tablePipelineImages}.${DatabaseSchema.colPipelineImagePath}
                  = ${DatabaseSchema.tableResults}.${DatabaseSchema.colResultImagePath}
                LIMIT 1
              )
              WHERE ${DatabaseSchema.colResultPipelineImageId} IS NULL
            ''');
          } catch (e) {
            // Non-fatal: unmatched rows simply stay unbound (hidden in History)
          }
        }

        // Handle migration from v5 to v6: soft delete for pipeline images
        // (workspace delete moves images to the trash bin instead of dropping
        // them permanently)
        if (oldVersion < 6) {
          try {
            await db.execute(
                'ALTER TABLE ${DatabaseSchema.tablePipelineImages} ADD COLUMN ${DatabaseSchema.colPipelineImageDeletedAt} INTEGER');
          } catch (e) {
            // Column might already exist
          }
        }

        // Handle migration from v6 to v7: per-stage result metadata (corners, warped plate,
        // well boxes file, auto/manual source) so stages 2/3 reuse stored results instead of
        // re-running earlier models. Old rows have NULL meta -> rebuilt on their next run.
        if (oldVersion < 7) {
          for (final col in [DatabaseSchema.colPipelineStage1Meta, DatabaseSchema.colPipelineStage2Meta]) {
            try {
              await db.execute('ALTER TABLE ${DatabaseSchema.tablePipelineImages} ADD COLUMN $col TEXT');
            } catch (e) {
              // Column might already exist
            }
          }
        }
      },
    );
  }

  /// Insert new result
  Future<int> insertResult(HistoryEntry entry) async {
    final db = await database;
    return await db.insert(
      DatabaseSchema.tableResults,
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all results shown in History (ordered by timestamp desc).
  /// History lists only full-pipeline results: rows bound to a pipeline image
  /// whose stage 3 completed. Trashed results STAY listed (flagged in_trash)
  /// until the trash entry is permanently deleted.
  Future<List<HistoryEntry>> getAllResults() async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT r.*,
             CASE WHEN p.${DatabaseSchema.colPipelineImageDeletedAt} IS NOT NULL
                       OR r.${DatabaseSchema.colResultDeletedAt} IS NOT NULL
                  THEN 1 ELSE 0 END AS in_trash
      FROM ${DatabaseSchema.tableResults} r
      INNER JOIN ${DatabaseSchema.tablePipelineImages} p
        ON r.${DatabaseSchema.colResultPipelineImageId} = p.${DatabaseSchema.colPipelineImageId}
      WHERE p.${DatabaseSchema.colPipelineStage3Status} = 'completed'
      ORDER BY r.${DatabaseSchema.colTimestamp} DESC
    ''');
    return maps.map((map) => HistoryEntry.fromMap(map)).toList();
  }

  /// Get result by ID
  Future<HistoryEntry?> getResultById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableResults,
      where: '${DatabaseSchema.colId} = ?',
      whereArgs: [id],
    );

    if (maps.isEmpty) return null;
    return HistoryEntry.fromMap(maps.first);
  }

  /// Get latest result by annotated image path (paths are timestamped → unique).
  /// Trashed rows are ignored so a deleted result cannot be resurrected by
  /// merely viewing it.
  Future<HistoryEntry?> getLatestResultByAnnotatedPath(String path) async {
    if (path.isEmpty) return null;
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableResults,
      where:
          '${DatabaseSchema.colAnnotatedPath} = ? AND ${DatabaseSchema.colResultDeletedAt} IS NULL',
      whereArgs: [path],
      orderBy: '${DatabaseSchema.colTimestamp} DESC',
      limit: 1,
    );

    if (maps.isEmpty) return null;
    return HistoryEntry.fromMap(maps.first);
  }

  /// Delete result
  Future<int> deleteResult(int id) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tableResults,
      where: '${DatabaseSchema.colId} = ?',
      whereArgs: [id],
    );
  }

  /// Delete all results
  Future<int> deleteAllResults() async {
    final db = await database;
    return await db.delete(DatabaseSchema.tableResults);
  }

  /// Update result
  Future<int> updateResult(HistoryEntry entry) async {
    if (entry.id == null) return 0;
    final db = await database;
    return await db.update(
      DatabaseSchema.tableResults,
      entry.toMap(),
      where: '${DatabaseSchema.colId} = ?',
      whereArgs: [entry.id],
    );
  }

  /// Update only the project assignment of a result (projectId can be null → unassigned)
  Future<int> updateResultProject(int resultId, int? projectId) async {
    final db = await database;
    return await db.update(
      DatabaseSchema.tableResults,
      {DatabaseSchema.colResultProjectId: projectId},
      where: '${DatabaseSchema.colId} = ?',
      whereArgs: [resultId],
    );
  }

  /// Get statistics
  Future<Map<String, int>> getStatistics() async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT
        COUNT(*) as total,
        SUM(${DatabaseSchema.colGrowth}) as total_growth,
        SUM(${DatabaseSchema.colNoGrowth}) as total_no_growth,
        SUM(${DatabaseSchema.colNoAgar}) as total_no_agar
      FROM ${DatabaseSchema.tableResults}
    ''');

    return {
      'total_entries': result.first['total'] as int? ?? 0,
      'total_growth': result.first['total_growth'] as int? ?? 0,
      'total_no_growth': result.first['total_no_growth'] as int? ?? 0,
      'total_no_agar': result.first['total_no_agar'] as int? ?? 0,
    };
  }

  /// Close database
  Future<void> close() async {
    final db = await database;
    await db.close();
  }

  // ────────────────────────────────────────────────────────────────
  // Project CRUD operations
  // ────────────────────────────────────────────────────────────────

  /// Insert new project
  Future<int> insertProject(ProjectEntry project) async {
    final db = await database;
    return await db.insert(
      DatabaseSchema.tableProjects,
      project.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all projects
  Future<List<ProjectEntry>> getAllProjects() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableProjects,
      orderBy: '${DatabaseSchema.colProjectUpdatedAt} DESC',
    );
    return maps.map((map) => ProjectEntry.fromMap(map)).toList();
  }

  /// Get project by ID
  Future<ProjectEntry?> getProjectById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableProjects,
      where: '${DatabaseSchema.colProjectId} = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return ProjectEntry.fromMap(maps.first);
  }

  /// Update project
  Future<int> updateProject(ProjectEntry project) async {
    if (project.id == null) return 0;
    final db = await database;
    return await db.update(
      DatabaseSchema.tableProjects,
      project.toMap(),
      where: '${DatabaseSchema.colProjectId} = ?',
      whereArgs: [project.id],
    );
  }

  /// Delete project
  Future<int> deleteProject(int id) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tableProjects,
      where: '${DatabaseSchema.colProjectId} = ?',
      whereArgs: [id],
    );
  }

  /// Get results by project ID (full-pipeline — same rules as
  /// [getAllResults], trashed rows stay listed flagged in_trash)
  Future<List<HistoryEntry>> getResultsByProject(int projectId) async {
    final db = await database;
    final maps = await db.rawQuery('''
      SELECT r.*,
             CASE WHEN p.${DatabaseSchema.colPipelineImageDeletedAt} IS NOT NULL
                       OR r.${DatabaseSchema.colResultDeletedAt} IS NOT NULL
                  THEN 1 ELSE 0 END AS in_trash
      FROM ${DatabaseSchema.tableResults} r
      INNER JOIN ${DatabaseSchema.tablePipelineImages} p
        ON r.${DatabaseSchema.colResultPipelineImageId} = p.${DatabaseSchema.colPipelineImageId}
      WHERE p.${DatabaseSchema.colPipelineStage3Status} = 'completed'
        AND r.${DatabaseSchema.colResultProjectId} = ?
      ORDER BY r.${DatabaseSchema.colTimestamp} DESC
    ''', [projectId]);
    return maps.map((map) => HistoryEntry.fromMap(map)).toList();
  }

  // ────────────────────────────────────────────────────────────────
  // Trash bin (soft delete) operations — image-centric: results always
  // follow their pipeline image into/out of the trash (see the cascade
  // methods at the bottom of this class).
  // ────────────────────────────────────────────────────────────────

  /// Soft-delete every non-trashed result by trashing the pipeline image
  /// behind it (Clear All History feeds the trash). Legacy rows without a
  /// pipeline image are soft-deleted directly.
  Future<void> moveAllResultsToTrash() async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.update(
      DatabaseSchema.tablePipelineImages,
      {
        DatabaseSchema.colPipelineImageDeletedAt: now,
        DatabaseSchema.colPipelineImageUpdatedAt: now,
      },
      where:
          '${DatabaseSchema.colPipelineImageDeletedAt} IS NULL AND '
          '${DatabaseSchema.colPipelineImageId} IN (SELECT DISTINCT '
          '${DatabaseSchema.colResultPipelineImageId} FROM '
          '${DatabaseSchema.tableResults} WHERE '
          '${DatabaseSchema.colResultDeletedAt} IS NULL AND '
          '${DatabaseSchema.colResultPipelineImageId} IS NOT NULL)',
    );
    batch.update(
      DatabaseSchema.tableResults,
      {DatabaseSchema.colResultDeletedAt: now},
      where: '${DatabaseSchema.colResultDeletedAt} IS NULL',
    );
    await batch.commit(noResult: true);
  }

  /// Permanently delete every trashed result row (covers legacy rows whose
  /// pipeline image is unknown — cascaded rows are removed with their image)
  Future<int> emptyTrash() async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tableResults,
      where: '${DatabaseSchema.colResultDeletedAt} IS NOT NULL',
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Trash bin: pipeline images (workspace delete)
  // ────────────────────────────────────────────────────────────────

  /// Soft-delete a pipeline image; its results follow into the trash so
  /// History and the workspace stay consistent.
  Future<void> movePipelineImageToTrash(int imageId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.update(
      DatabaseSchema.tablePipelineImages,
      {
        DatabaseSchema.colPipelineImageDeletedAt: now,
        DatabaseSchema.colPipelineImageUpdatedAt: now,
      },
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [imageId],
    );
    batch.update(
      DatabaseSchema.tableResults,
      {DatabaseSchema.colResultDeletedAt: now},
      where:
          '${DatabaseSchema.colResultPipelineImageId} = ? AND ${DatabaseSchema.colResultDeletedAt} IS NULL',
      whereArgs: [imageId],
    );
    await batch.commit(noResult: true);
  }

  /// Restore a trashed pipeline image and its results, assigning them to
  /// [projectId] — any existing project the user picks in the trash UI (the
  /// results follow so History's project filter stays consistent)
  Future<void> restorePipelineImageFromTrash(int imageId, int projectId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    batch.update(
      DatabaseSchema.tablePipelineImages,
      {
        DatabaseSchema.colPipelineImageDeletedAt: null,
        DatabaseSchema.colPipelineImageProjectId: projectId,
        DatabaseSchema.colPipelineImageUpdatedAt: now,
      },
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [imageId],
    );
    batch.update(
      DatabaseSchema.tableResults,
      {
        DatabaseSchema.colResultDeletedAt: null,
        DatabaseSchema.colResultProjectId: projectId,
      },
      where: '${DatabaseSchema.colResultPipelineImageId} = ?',
      whereArgs: [imageId],
    );
    await batch.commit(noResult: true);
  }

  /// Get all trashed pipeline images (ordered by delete time desc)
  Future<List<PipelineImageEntry>> getTrashedPipelineImages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageDeletedAt} IS NOT NULL',
      orderBy: '${DatabaseSchema.colPipelineImageDeletedAt} DESC',
    );
    return maps.map((map) => PipelineImageEntry.fromMap(map)).toList();
  }

  /// Permanently delete one trashed pipeline image and its results
  Future<void> deletePipelineImagePermanently(int imageId) async {
    final db = await database;
    final batch = db.batch();
    batch.delete(
      DatabaseSchema.tableResults,
      where: '${DatabaseSchema.colResultPipelineImageId} = ?',
      whereArgs: [imageId],
    );
    batch.delete(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [imageId],
    );
    await batch.commit(noResult: true);
  }

  /// Permanently delete every trashed pipeline image and its results.
  /// Returns how many image rows were purged.
  Future<int> purgeTrashedPipelineImages() async {
    final db = await database;
    final ids = await db.query(
      DatabaseSchema.tablePipelineImages,
      columns: [DatabaseSchema.colPipelineImageId],
      where: '${DatabaseSchema.colPipelineImageDeletedAt} IS NOT NULL',
    );
    if (ids.isEmpty) return 0;
    final idList = ids.map((m) => m[DatabaseSchema.colPipelineImageId] as int).toList();
    final batch = db.batch();
    batch.delete(
      DatabaseSchema.tableResults,
      where:
          '${DatabaseSchema.colResultPipelineImageId} IN (${List.filled(idList.length, '?').join(',')})',
      whereArgs: idList,
    );
    batch.delete(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageDeletedAt} IS NOT NULL',
    );
    await batch.commit(noResult: true);
    return idList.length;
  }

  /// Get result count for a project
  Future<int> getProjectResultCount(int projectId) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${DatabaseSchema.tableResults}
      WHERE ${DatabaseSchema.colResultProjectId} = ?
    ''', [projectId]);
    return result.first['count'] as int? ?? 0;
  }

  /// Get image count for a project — the Projects tab shows how many images
  /// the workspace manages, so this counts pipeline_images (not results);
  /// trashed images don't count.
  Future<int> getProjectImageCount(int projectId) async {
    final db = await database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as count
      FROM ${DatabaseSchema.tablePipelineImages}
      WHERE ${DatabaseSchema.colPipelineImageProjectId} = ?
        AND ${DatabaseSchema.colPipelineImageDeletedAt} IS NULL
    ''', [projectId]);
    return result.first['count'] as int? ?? 0;
  }

  /// Move the pipeline image owning [imagePath] to another project. Keeps the
  /// workspace image list in sync when a result is reassigned from History.
  Future<int> updatePipelineImageProjectByPath(String imagePath, int? projectId) async {
    final db = await database;
    return await db.update(
      DatabaseSchema.tablePipelineImages,
      {
        DatabaseSchema.colPipelineImageProjectId: projectId,
        DatabaseSchema.colPipelineImageUpdatedAt: DateTime.now().millisecondsSinceEpoch,
      },
      where: '${DatabaseSchema.colPipelineImagePath} = ?',
      whereArgs: [imagePath],
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Project Image operations
  // ────────────────────────────────────────────────────────────────

  /// Add image to project
  Future<int> addImageToProject(ProjectImageEntry image) async {
    final db = await database;
    return await db.insert(
      DatabaseSchema.tableProjectImages,
      image.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get images for a project
  Future<List<ProjectImageEntry>> getProjectImages(int projectId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableProjectImages,
      where: '${DatabaseSchema.colImageProjectId} = ?',
      whereArgs: [projectId],
      orderBy: '${DatabaseSchema.colImageCreatedAt} DESC',
    );
    return maps.map((map) => ProjectImageEntry.fromMap(map)).toList();
  }

  /// Update image status
  Future<int> updateImageStatus(int imageId, String status) async {
    final db = await database;
    return await db.update(
      DatabaseSchema.tableProjectImages,
      {DatabaseSchema.colImageStatus: status},
      where: '${DatabaseSchema.colImageId} = ?',
      whereArgs: [imageId],
    );
  }

  /// Delete image from project
  Future<int> deleteImageFromProject(int imageId) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tableProjectImages,
      where: '${DatabaseSchema.colImageId} = ?',
      whereArgs: [imageId],
    );
  }

  // ────────────────────────────────────────────────────────────────
  // Pipeline Folders CRUD operations
  // ────────────────────────────────────────────────────────────────

  /// Insert new pipeline folder
  Future<int> insertPipelineFolder(PipelineFolderEntry folder) async {
    final db = await database;
    return await db.insert(
      DatabaseSchema.tablePipelineFolders,
      folder.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all pipeline folders (ordered by position)
  Future<List<PipelineFolderEntry>> getAllPipelineFolders() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineFolders,
      orderBy: '${DatabaseSchema.colFolderPosition} ASC',
    );
    return maps.map((map) => PipelineFolderEntry.fromMap(map)).toList();
  }

  /// Get folder by ID
  Future<PipelineFolderEntry?> getPipelineFolderById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineFolders,
      where: '${DatabaseSchema.colFolderId} = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return PipelineFolderEntry.fromMap(maps.first);
  }

  /// Get child folders of a parent
  Future<List<PipelineFolderEntry>> getChildFolders(int? parentId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineFolders,
      where: '${DatabaseSchema.colFolderParentId} ${parentId == null ? 'IS NULL' : '= ?'}',
      whereArgs: parentId != null ? [parentId] : null,
      orderBy: '${DatabaseSchema.colFolderPosition} ASC',
    );
    return maps.map((map) => PipelineFolderEntry.fromMap(map)).toList();
  }

  /// Update pipeline folder
  Future<int> updatePipelineFolder(PipelineFolderEntry folder) async {
    if (folder.id == null) return 0;
    final db = await database;
    return await db.update(
      DatabaseSchema.tablePipelineFolders,
      folder.toMap(),
      where: '${DatabaseSchema.colFolderId} = ?',
      whereArgs: [folder.id],
    );
  }

  /// Delete pipeline folder
  Future<int> deletePipelineFolder(int id) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tablePipelineFolders,
      where: '${DatabaseSchema.colFolderId} = ?',
      whereArgs: [id],
    );
  }

  /// Reorder folders (update positions)
  Future<void> reorderFolders(List<int> folderIds) async {
    final db = await database;
    final batch = db.batch();
    for (int i = 0; i < folderIds.length; i++) {
      batch.update(
        DatabaseSchema.tablePipelineFolders,
        {DatabaseSchema.colFolderPosition: i},
        where: '${DatabaseSchema.colFolderId} = ?',
        whereArgs: [folderIds[i]],
      );
    }
    await batch.commit(noResult: true);
  }

  // ────────────────────────────────────────────────────────────────
  // Pipeline Images CRUD operations
  // ────────────────────────────────────────────────────────────────

  /// Insert new pipeline image
  Future<int> insertPipelineImage(PipelineImageEntry image) async {
    final db = await database;
    return await db.insert(
      DatabaseSchema.tablePipelineImages,
      image.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Get all pipeline images
  Future<List<PipelineImageEntry>> getAllPipelineImages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      orderBy: '${DatabaseSchema.colPipelineImageCreatedAt} DESC',
    );
    return maps.map((map) => PipelineImageEntry.fromMap(map)).toList();
  }

  /// Get images by folder
  Future<List<PipelineImageEntry>> getImagesByFolder(int? folderId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageFolderId} ${folderId == null ? 'IS NULL' : '= ?'}',
      whereArgs: folderId != null ? [folderId] : null,
      orderBy: '${DatabaseSchema.colPipelineImageCreatedAt} DESC',
    );
    return maps.map((map) => PipelineImageEntry.fromMap(map)).toList();
  }

  /// Get pipeline image by path
  Future<PipelineImageEntry?> getPipelineImageByPath(String imagePath) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImagePath} = ?',
      whereArgs: [imagePath],
    );
    if (maps.isEmpty) return null;
    return PipelineImageEntry.fromMap(maps.first);
  }

  /// Get pipeline image by ID
  Future<PipelineImageEntry?> getPipelineImageById(int id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return PipelineImageEntry.fromMap(maps.first);
  }

  /// Update pipeline image
  Future<int> updatePipelineImage(PipelineImageEntry image) async {
    if (image.id == null) return 0;
    final db = await database;
    return await db.update(
      DatabaseSchema.tablePipelineImages,
      image.toMap(),
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [image.id],
    );
  }

  /// Update stage status for pipeline image
  Future<int> updatePipelineImageStageStatus(
    int imageId,
    String stage,
    String status,
    {String? outputPath}
  ) async {
    final db = await database;
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    Map<String, dynamic> data = {
      'updated_at': timestamp,
    };

    // Update specific stage status and output
    switch (stage) {
      case 'stage1':
        data[DatabaseSchema.colPipelineStage1Status] = status;
        if (outputPath != null) {
          data[DatabaseSchema.colPipelineStage1Output] = outputPath;
        }
        break;
      case 'stage2':
        data[DatabaseSchema.colPipelineStage2Status] = status;
        if (outputPath != null) {
          data[DatabaseSchema.colPipelineStage2Output] = outputPath;
        }
        break;
      case 'stage3':
        data[DatabaseSchema.colPipelineStage3Status] = status;
        if (outputPath != null) {
          data[DatabaseSchema.colPipelineStage3Output] = outputPath;
        }
        break;
    }

    return await db.update(
      DatabaseSchema.tablePipelineImages,
      data,
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [imageId],
    );
  }

  /// Mark a stage completed and store its output preview + meta JSON (v7).
  Future<void> saveStageResult(int imageId, int stage, {String? outputPath, String? metaJson}) async {
    final db = await database;
    final data = <String, dynamic>{
      'updated_at': DateTime.now().millisecondsSinceEpoch,
      'stage${stage}_status': 'completed',
      if (outputPath != null) 'stage${stage}_output_path': outputPath,
      if (stage == 1 && metaJson != null) DatabaseSchema.colPipelineStage1Meta: metaJson,
      if (stage == 2 && metaJson != null) DatabaseSchema.colPipelineStage2Meta: metaJson,
    };
    await db.update(DatabaseSchema.tablePipelineImages, data,
        where: '${DatabaseSchema.colPipelineImageId} = ?', whereArgs: [imageId]);
  }

  /// Invalidate stages >= [fromStage]: status back to pending, outputs / meta / stage3 summary
  /// set to NULL and this image's History rows removed (they would reappear once stage 3
  /// completes again). Used whenever an upstream result changes (rerun or manual edit).
  Future<void> resetStagesFrom(int imageId, int fromStage) async {
    final db = await database;
    await db.transaction((txn) async {
      final data = <String, dynamic>{'updated_at': DateTime.now().millisecondsSinceEpoch};
      for (var s = fromStage; s <= 3; s++) {
        data['stage${s}_status'] = 'pending';
        data['stage${s}_output_path'] = null;
      }
      if (fromStage <= 1) data[DatabaseSchema.colPipelineStage1Meta] = null;
      if (fromStage <= 2) data[DatabaseSchema.colPipelineStage2Meta] = null;
      data[DatabaseSchema.colPipelineStage3Summary] = null;
      data[DatabaseSchema.colPipelineStage3ConfPath] = null;
      await txn.update(DatabaseSchema.tablePipelineImages, data,
          where: '${DatabaseSchema.colPipelineImageId} = ?', whereArgs: [imageId]);
      await txn.delete(DatabaseSchema.tableResults,
          where: '${DatabaseSchema.colResultPipelineImageId} = ?', whereArgs: [imageId]);
    });
  }

  /// Delete pipeline image
  Future<int> deletePipelineImage(int id) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [id],
    );
  }

  /// Delete all images in a folder
  Future<int> deleteImagesInFolder(int? folderId) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageFolderId} ${folderId == null ? 'IS NULL' : '= ?'}',
      whereArgs: folderId != null ? [folderId] : null,
    );
  }

  /// Get status summary for images
  Future<Map<String, int>> getPipelineImagesStatusSummary(List<int> imageIds) async {
    if (imageIds.isEmpty) {
      return {'pending': 0, 'running': 0, 'stage1_done': 0, 'stage2_done': 0, 'full_done': 0};
    }

    final db = await database;
    final images = await db.query(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageId} IN (${List.filled(imageIds.length, '?').join(',')})',
      whereArgs: imageIds,
    );

    int pending = 0, running = 0, stage1 = 0, stage2 = 0, full = 0;

    for (var map in images) {
      final image = PipelineImageEntry.fromMap(map);
      switch (image.overallStatus) {
        case 'pending':
          pending++;
          break;
        case 'running':
          running++;
          break;
        case 'stage1_done':
          stage1++;
          break;
        case 'stage2_done':
          stage2++;
          break;
        case 'full_done':
          full++;
          break;
      }
    }

    return {'pending': pending, 'running': running, 'stage1_done': stage1, 'stage2_done': stage2, 'full_done': full};
  }

  /// Get pipeline images belonging to a project (trashed images excluded —
  /// they live in the trash bin until restored or purged)
  Future<List<PipelineImageEntry>> getPipelineImagesByProject(int projectId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tablePipelineImages,
      where:
          '${DatabaseSchema.colPipelineImageProjectId} = ? AND ${DatabaseSchema.colPipelineImageDeletedAt} IS NULL',
      whereArgs: [projectId],
      orderBy: '${DatabaseSchema.colPipelineImageCreatedAt} DESC',
    );
    return maps.map((map) => PipelineImageEntry.fromMap(map)).toList();
  }

  /// Persist stage-3 detail (counts JSON + confidence distribution)
  Future<int> updatePipelineImageStage3Summary(int imageId, String summaryJson) async {
    final db = await database;
    return await db.update(
      DatabaseSchema.tablePipelineImages,
      {
        DatabaseSchema.colPipelineStage3Summary: summaryJson,
        DatabaseSchema.colPipelineImageUpdatedAt: DateTime.now().millisecondsSinceEpoch,
      },
      where: '${DatabaseSchema.colPipelineImageId} = ?',
      whereArgs: [imageId],
    );
  }

  /// Delete all pipeline images of a project
  Future<int> deletePipelineImagesByProject(int projectId) async {
    final db = await database;
    return await db.delete(
      DatabaseSchema.tablePipelineImages,
      where: '${DatabaseSchema.colPipelineImageProjectId} = ?',
      whereArgs: [projectId],
    );
  }
}
