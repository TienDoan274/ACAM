/// Constants cho microplate analysis app
library constants;

/// Grid parameters (384-well plate)
class GridParams {
  static const int rows = 16;
  static const int cols = 24;
  static const double margin = 0.08;
  static const int expectedWells = 384;
}

/// Class names và colors cho visualization
class WellClasses {
  static const int growth = 0;
  static const int noGrowth = 1;
  static const int noAgar = 2;

  static const String growthLabel = 'Growth';
  static const String noGrowthLabel = 'NoGrowth';
  static const String noAgarLabel = 'NoAgar';

  // Colors (ARGB)
  static const int growthColor = 0xFF00B400; // Green
  static const int noGrowthColor = 0xFF0000DC; // Red
  static const int noAgarColor = 0xFFC800C8; // Purple
}

/// Stage 1 parameters
class Stage1Params {
  static const int imgSize = 896;
  static const double mean = 0.485;
  static const double std = 0.229;
}

/// Stage 2 parameters
class Stage2Params {
  static const double conf = 0.05;
  static const double iou = 0.15;
  static const int maxDet = 384;
}

/// Stage 3 parameters
class Stage3Params {
  static const int cropSize = 64;
}

/// App settings keys
class SettingsKeys {
  static const String detectionMode = 'detection_mode';
  static const String gridRows = 'grid_rows';
  static const String gridCols = 'grid_cols';
  static const String autoSave = 'auto_save';
  static const String exportFormat = 'export_format';
}

/// Detection modes (3-mode pipeline)
enum DetectionMode {
  autoGrid('Auto Grid', 'Stage 1 corners + bilinear grid (default)'),
  manualGrid('Manual Adjust', '5-DOF grid adjustment'),
  yoloDetect('YOLO Detect', 'ML-based well detection');

  final String label;
  final String description;

  const DetectionMode(this.label, this.description);
}

/// 5-DOF grid transform (similarity transform — NO perspective / corner drag).
/// Applied around the grid centroid: translate + uniform scale + rotate + margin.
class GridTransform {
  final double translateX; // pixels
  final double translateY; // pixels
  final double scale; // multiplier (1.0 = no zoom)
  final double rotation; // degrees
  final double margin; // ratio (expand/shrink grid from edge)

  const GridTransform({
    this.translateX = 0.0,
    this.translateY = 0.0,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.margin = GridParams.margin,
  });

  /// Identity transform (same as auto grid)
  static const identity = GridTransform();

  bool get isIdentity =>
      translateX == 0.0 &&
      translateY == 0.0 &&
      scale == 1.0 &&
      rotation == 0.0 &&
      margin == GridParams.margin;

  GridTransform copyWith({
    double? translateX,
    double? translateY,
    double? scale,
    double? rotation,
    double? margin,
  }) {
    return GridTransform(
      translateX: translateX ?? this.translateX,
      translateY: translateY ?? this.translateY,
      scale: scale ?? this.scale,
      rotation: rotation ?? this.rotation,
      margin: margin ?? this.margin,
    );
  }

  Map<String, double> toMap() => {
        'translateX': translateX,
        'translateY': translateY,
        'scale': scale,
        'rotation': rotation,
        'margin': margin,
      };

  factory GridTransform.fromMap(Map<String, double> m) => GridTransform(
        translateX: m['translateX'] ?? 0.0,
        translateY: m['translateY'] ?? 0.0,
        scale: m['scale'] ?? 1.0,
        rotation: m['rotation'] ?? 0.0,
        margin: m['margin'] ?? GridParams.margin,
      );

  @override
  String toString() =>
      'GridTransform(tx=${translateX.toStringAsFixed(1)}, ty=${translateY.toStringAsFixed(1)}, '
      's=${scale.toStringAsFixed(3)}, rot=${rotation.toStringAsFixed(1)}, m=${margin.toStringAsFixed(3)})';
}

/// Database schema
class DatabaseSchema {
  static const String dbName = 'microplate_history.db';
  static const int dbVersion = 7;

  // Projects table
  static const String tableProjects = 'projects';
  static const String colProjectId = 'id';
  static const String colProjectName = 'name';
  static const String colProjectDescription = 'description';
  static const String colProjectCreatedAt = 'created_at';
  static const String colProjectUpdatedAt = 'updated_at';
  static const String colProjectColor = 'color';

  // Project images table
  static const String tableProjectImages = 'project_images';
  static const String colImageId = 'id';
  static const String colImageProjectId = 'project_id';
  static const String colImagePath = 'image_path';
  static const String colImageStatus = 'status';
  static const String colImageCreatedAt = 'created_at';

  // Results table
  static const String tableResults = 'results';
  static const String colId = 'id';
  static const String colResultImagePath = 'image_path';
  static const String colAnnotatedPath = 'annotated_path';
  static const String colTimestamp = 'timestamp';
  static const String colTotal = 'total_wells';
  static const String colGrowth = 'growth_count';
  static const String colNoGrowth = 'no_growth_count';
  static const String colNoAgar = 'no_agar_count';
  static const String colProcessingTime = 'processing_time_ms';
  static const String colResultProjectId = 'project_id';
  static const String colResultImageId = 'image_id';
  static const String colResultPipelineImageId = 'pipeline_image_id';
  static const String colResultDeletedAt = 'deleted_at';

  // Pipeline folders table
  static const String tablePipelineFolders = 'pipeline_folders';
  static const String colFolderId = 'id';
  static const String colFolderName = 'name';
  static const String colFolderParentId = 'parent_id';
  static const String colFolderPosition = 'position';
  static const String colFolderCreatedAt = 'created_at';

  // Pipeline images table
  static const String tablePipelineImages = 'pipeline_images';
  static const String colPipelineImageId = 'id';
  static const String colPipelineImageFolderId = 'folder_id';
  static const String colPipelineImageProjectId = 'project_id';
  static const String colPipelineImagePath = 'image_path';
  static const String colPipelineStage1Status = 'stage1_status';
  static const String colPipelineStage2Status = 'stage2_status';
  static const String colPipelineStage3Status = 'stage3_status';
  static const String colPipelineStage1Output = 'stage1_output_path';
  static const String colPipelineStage2Output = 'stage2_output_path';
  static const String colPipelineStage3Output = 'stage3_output_path';
  static const String colPipelineStage3Summary = 'stage3_summary';
  static const String colPipelineStage3ConfPath = 'stage3_conf_path';
  // v7: JSON kết quả từng stage (StageMeta trong lib/models/stage_meta.dart): nguồn auto/manual,
  // góc Stage 1 + ảnh warp, đường dẫn file box Stage 2 — để Stage 2/3 không phải chạy lại model
  static const String colPipelineStage1Meta = 'stage1_meta';
  static const String colPipelineStage2Meta = 'stage2_meta';
  static const String colPipelineImageCreatedAt = 'created_at';
  static const String colPipelineImageUpdatedAt = 'updated_at';
  static const String colPipelineImageDeletedAt = 'deleted_at';

  // Create table SQL statements
  static const String createPipelineFoldersTableSQL = '''
    CREATE TABLE $tablePipelineFolders (
      $colFolderId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colFolderName TEXT NOT NULL,
      $colFolderParentId INTEGER,
      $colFolderPosition INTEGER NOT NULL DEFAULT 0,
      $colFolderCreatedAt INTEGER NOT NULL,
      FOREIGN KEY ($colFolderParentId) REFERENCES $tablePipelineFolders($colFolderId) ON DELETE CASCADE
    )
  ''';

  static const String createPipelineImagesTableSQL = '''
    CREATE TABLE IF NOT EXISTS $tablePipelineImages (
      $colPipelineImageId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colPipelineImageFolderId INTEGER,
      $colPipelineImageProjectId INTEGER,
      $colPipelineImagePath TEXT NOT NULL UNIQUE,
      $colPipelineStage1Status TEXT DEFAULT 'pending',
      $colPipelineStage2Status TEXT DEFAULT 'pending',
      $colPipelineStage3Status TEXT DEFAULT 'pending',
      $colPipelineStage1Output TEXT,
      $colPipelineStage2Output TEXT,
      $colPipelineStage3Output TEXT,
      $colPipelineStage3Summary TEXT,
      $colPipelineStage3ConfPath TEXT,
      $colPipelineStage1Meta TEXT,
      $colPipelineStage2Meta TEXT,
      $colPipelineImageCreatedAt INTEGER NOT NULL,
      $colPipelineImageUpdatedAt INTEGER NOT NULL,
      $colPipelineImageDeletedAt INTEGER,
      FOREIGN KEY ($colPipelineImageFolderId) REFERENCES $tablePipelineFolders($colFolderId) ON DELETE SET NULL
    )
  ''';

  static const String createProjectsTableSQL = '''
    CREATE TABLE $tableProjects (
      $colProjectId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colProjectName TEXT NOT NULL,
      $colProjectDescription TEXT,
      $colProjectCreatedAt INTEGER NOT NULL,
      $colProjectUpdatedAt INTEGER NOT NULL,
      $colProjectColor INTEGER DEFAULT 0xFF4CAF50
    )
  ''';

  static const String createProjectImagesTableSQL = '''
    CREATE TABLE $tableProjectImages (
      $colImageId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colImageProjectId INTEGER NOT NULL,
      $colImagePath TEXT NOT NULL,
      $colImageStatus TEXT DEFAULT 'pending',
      $colImageCreatedAt INTEGER NOT NULL,
      FOREIGN KEY ($colImageProjectId) REFERENCES $tableProjects($colProjectId) ON DELETE CASCADE
    )
  ''';

  static const String createResultsTableSQL = '''
    CREATE TABLE $tableResults (
      $colId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colResultImagePath TEXT NOT NULL,
      $colAnnotatedPath TEXT,
      $colTimestamp INTEGER NOT NULL,
      $colTotal INTEGER NOT NULL,
      $colGrowth INTEGER NOT NULL,
      $colNoGrowth INTEGER NOT NULL,
      $colNoAgar INTEGER NOT NULL,
      $colProcessingTime REAL,
      $colResultProjectId INTEGER,
      $colResultImageId INTEGER,
      $colResultPipelineImageId INTEGER,
      $colResultDeletedAt INTEGER,
      FOREIGN KEY ($colResultProjectId) REFERENCES $tableProjects($colProjectId),
      FOREIGN KEY ($colResultImageId) REFERENCES $tableProjectImages($colImageId)
    )
  ''';

  // Migration SQL
  static const String migrateV1ToV2 = '''
    -- Add project_id and image_id columns to results table
    ALTER TABLE $tableResults ADD COLUMN $colResultProjectId INTEGER;
    ALTER TABLE $tableResults ADD COLUMN $colResultImageId INTEGER;

    -- Create projects table
    CREATE TABLE IF NOT EXISTS $tableProjects (
      $colProjectId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colProjectName TEXT NOT NULL,
      $colProjectDescription TEXT,
      $colProjectCreatedAt INTEGER NOT NULL,
      $colProjectUpdatedAt INTEGER NOT NULL,
      $colProjectColor INTEGER DEFAULT 0xFF4CAF50
    );

    -- Create project_images table
    CREATE TABLE IF NOT EXISTS $tableProjectImages (
      $colImageId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colImageProjectId INTEGER NOT NULL,
      $colImagePath TEXT NOT NULL,
      $colImageStatus TEXT DEFAULT 'pending',
      $colImageCreatedAt INTEGER NOT NULL,
      FOREIGN KEY ($colImageProjectId) REFERENCES $tableProjects($colProjectId) ON DELETE CASCADE
    );
  ''';
}
