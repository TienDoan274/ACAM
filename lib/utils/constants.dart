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
  static const int dbVersion = 1;

  static const String tableResults = 'results';
  static const String colId = 'id';
  static const String colImagePath = 'image_path';
  static const String colAnnotatedPath = 'annotated_path';
  static const String colTimestamp = 'timestamp';
  static const String colTotal = 'total_wells';
  static const String colGrowth = 'growth_count';
  static const String colNoGrowth = 'no_growth_count';
  static const String colNoAgar = 'no_agar_count';
  static const String colProcessingTime = 'processing_time_ms';

  static const String createTableSQL = '''
    CREATE TABLE $tableResults (
      $colId INTEGER PRIMARY KEY AUTOINCREMENT,
      $colImagePath TEXT NOT NULL,
      $colAnnotatedPath TEXT,
      $colTimestamp INTEGER NOT NULL,
      $colTotal INTEGER NOT NULL,
      $colGrowth INTEGER NOT NULL,
      $colNoGrowth INTEGER NOT NULL,
      $colNoAgar INTEGER NOT NULL,
      $colProcessingTime REAL
    )
  ''';
}
