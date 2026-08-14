/// SQLite database helper cho lưu history
library database_helper;

import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../utils/constants.dart';

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
  });

  /// Convert từ database row
  factory HistoryEntry.fromMap(Map<String, dynamic> map) {
    return HistoryEntry(
      id: map[DatabaseSchema.colId] as int?,
      imagePath: map[DatabaseSchema.colImagePath] as String,
      annotatedPath: map[DatabaseSchema.colAnnotatedPath] as String?,
      timestamp: map[DatabaseSchema.colTimestamp] as int,
      totalWells: map[DatabaseSchema.colTotal] as int,
      growthCount: map[DatabaseSchema.colGrowth] as int,
      noGrowthCount: map[DatabaseSchema.colNoGrowth] as int,
      noAgarCount: map[DatabaseSchema.colNoAgar] as int,
      processingTimeMs: map[DatabaseSchema.colProcessingTime] as double?,
    );
  }

  /// Convert to database row
  Map<String, dynamic> toMap() {
    return {
      if (id != null) DatabaseSchema.colId: id,
      DatabaseSchema.colImagePath: imagePath,
      DatabaseSchema.colAnnotatedPath: annotatedPath,
      DatabaseSchema.colTimestamp: timestamp,
      DatabaseSchema.colTotal: totalWells,
      DatabaseSchema.colGrowth: growthCount,
      DatabaseSchema.colNoGrowth: noGrowthCount,
      DatabaseSchema.colNoAgar: noAgarCount,
      DatabaseSchema.colProcessingTime: processingTimeMs,
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
        await db.execute(DatabaseSchema.createTableSQL);
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

  /// Get all results (ordered by timestamp desc)
  Future<List<HistoryEntry>> getAllResults() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      DatabaseSchema.tableResults,
      orderBy: '${DatabaseSchema.colTimestamp} DESC',
    );

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
}
