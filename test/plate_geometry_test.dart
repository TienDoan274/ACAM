// So khớp plate_geometry.dart với acam/quality.py (fixture sinh bởi `python pipelines/40_export_models.py
// --fixtures 3` ở repo cha) + round-trip JSON của Stage1Meta / Stage2Meta.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microplate_analyzer/models/stage_meta.dart';
import 'package:microplate_analyzer/utils/pipeline_config.dart';
import 'package:microplate_analyzer/utils/plate_geometry.dart';

void main() {
  final cfg = PipelineConfig.fromJson(
      jsonDecode(File('assets/models/pipeline_config.json').readAsStringSync()) as Map<String, dynamic>);
  final d = jsonDecode(File('test/fixtures/quality_cases.json').readAsStringSync()) as Map<String, dynamic>;

  for (final c in d['cases'] as List) {
    test('quadMetrics khop Python: ${c['name']}', () {
      final corners = [
        for (final p in c['corners'] as List) {'x': (p[0] as num).toDouble(), 'y': (p[1] as num).toDouble()}
      ];
      final m = quadMetrics(corners, (c['image_w'] as num).toDouble(), (c['image_h'] as num).toDouble());
      final e = c['expected'] as Map<String, dynamic>;
      expect(m.aspect, closeTo((e['aspect'] as num).toDouble(), 1e-9));
      expect(m.areaFrac, closeTo((e['area_frac'] as num).toDouble(), 1e-9));
      expect(m.minAngle, closeTo((e['min_angle'] as num).toDouble(), 1e-6));
      expect(m.maxAngle, closeTo((e['max_angle'] as num).toDouble(), 1e-6));
      expect(m.convex, e['convex']);
      expect(stage1Warnings(m, cfg), [for (final w in c['expected_warnings'] as List) w as String]);
    });
  }

  for (final c in (d['stage2_cases'] as List?) ?? const []) {
    test('stage2Warnings khop Python: ${c['n_wells']} o, ${c['n_interpolated']} noi suy, pitch ${c['pitch']}', () {
      final geom = c['geometric'] as bool;
      final w = stage2Warnings(c['n_wells'] as int, geom ? 0 : c['n_interpolated'] as int, geom ? 0 : c['n_snapped'] as int,
          (c['pitch'] as num).toDouble(), cfg);
      expect(w, [for (final x in c['expected_warnings'] as List) x as String]);
    });
  }

  test('orderCorners: TL, TR, BR, BL bat ke thu tu vao', () {
    final o = orderCorners([
      {'x': 90.0, 'y': 80.0},
      {'x': 10.0, 'y': 12.0},
      {'x': 8.0, 'y': 85.0},
      {'x': 95.0, 'y': 10.0},
    ]);
    expect([for (final c in o) [c['x'], c['y']]], [
      [10.0, 12.0],
      [95.0, 10.0],
      [90.0, 80.0],
      [8.0, 85.0],
    ]);
  });

  test('Stage1Meta / Stage2Meta round-trip JSON', () {
    final m1 = Stage1Meta(
      source: Stage1Meta.sourceManual,
      imageSize: [4000, 3000],
      corners: [
        [1.5, 2.5],
        [3.0, 4.0],
        [5.0, 6.0],
        [7.0, 8.0]
      ],
      autoCorners: null,
      warpedPath: '/x/warped.png',
      warpedSize: [100, 60],
      qc: const {'aspect': 1.5},
      warn: const ['aspect'],
    );
    final r1 = Stage1Meta.parse(jsonEncode(m1.toJson()))!;
    expect(r1.isManual, isTrue);
    expect(r1.corners, m1.corners);
    expect(r1.cornerMaps.first, {'x': 1.5, 'y': 2.5});
    expect(r1.warn, ['aspect']);

    const man = ManualWells([
      [1, 2, 3, 4],
      [5, 6, 7, 8],
      [9, 10, 11, 12]
    ], 11, 7, false);
    final m2 = Stage2Meta(
        source: Stage2Meta.sourceGeom, resultPath: '/x/r.json', rows: 7, cols: 11, manual: man, stats: const {'n_det': 0});
    final r2 = Stage2Meta.parse(jsonEncode(m2.toJson()))!;
    expect(r2.isManual, isTrue);
    expect(r2.nWells, 77);
    expect(r2.manual!.anchors, man.anchors);
    expect([r2.manual!.n12, r2.manual!.n13, r2.manual!.refine], [11, 7, false]);
    expect(Stage2Meta.parse('not json'), isNull);
  });

  test('Stage2Meta box file round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('s2meta');
    final path = '${dir.path}/r.json';
    final boxes = [
      {'x1': 1.0, 'y1': 2.0, 'x2': 3.0, 'y2': 4.0, 'conf': 0.9, 'interpolated': false, 'snapped': true},
      {'x1': 5.0, 'y1': 6.0, 'x2': 7.0, 'y2': 8.0, 'conf': 0.0, 'interpolated': true, 'snapped': false},
    ];
    await Stage2Meta.writeBoxes(path, boxes, 1, 2, [10, 10]);
    final m = Stage2Meta(source: Stage2Meta.sourceAuto, resultPath: path, rows: 1, cols: 2);
    expect(await m.readBoxes(), boxes);
    await dir.delete(recursive: true);
  });
}
