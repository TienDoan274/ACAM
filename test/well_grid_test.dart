// So khớp WellGrid (Dart) với acam/grid.py (Python) trên fixtures sinh bởi
// `python pipelines/40_export_models.py --fixtures 3` (ở repo cha).
// mode: auto (complete), manual_refine (fromAnchorsRefined), manual_geom (fromAnchors).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:microplate_analyzer/utils/well_grid.dart';

void main() {
  final files = Directory('test/fixtures')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json') && f.uri.pathSegments.last.startsWith('grid_'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('co fixtures', () => expect(files, isNotEmpty));

  List<List<double>> boxes(List raw) => [
        for (final b in raw) [for (final v in b as List) (v as num).toDouble()]
      ];

  for (final f in files) {
    test('WellGrid khop Python: ${f.uri.pathSegments.last}', () {
      final d = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final g = d['grid_config'] as Map<String, dynamic>;
      final grid = WellGrid(GridParamsDyn(
        rows: g['rows'],
        cols: g['cols'],
        templateCornersUv: [
          for (final p in g['template_corners_uv'] as List) [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
        ],
        margin: (g['margin'] as num).toDouble(),
        gates: [for (final x in g['gates_pitch'] as List) (x as num).toDouble()],
        snapTol: (g['snap_tol_pitch'] as num).toDouble(),
        maxRefine: (g['max_refine'] as num).toInt(),
        minConf: (g['coarse_align_min_conf'] as num).toDouble(),
        scaleMin: (g['coarse_align_scale_clip'][0] as num).toDouble(),
        scaleMax: (g['coarse_align_scale_clip'][1] as num).toDouble(),
        phaseRadius: (g['phase_radius'] as num?)?.toDouble() ?? double.infinity,
        growRadii: [for (final r in (g['grow_radii'] as List?) ?? const []) (r as num).toDouble()],
        growHomographyFrom: (g['grow_homography_from'] as num?)?.toDouble() ?? double.infinity,
      ));
      final dets = [
        for (final b in d['detections'] as List)
          Det((b[0] as num).toDouble(), (b[1] as num).toDouble(), (b[2] as num).toDouble(),
              (b[3] as num).toDouble(), (b[4] as num).toDouble())
      ];
      final w = (d['image_w'] as num).toDouble(), h = (d['image_h'] as num).toDouble();
      final mode = d['mode'] as String? ?? 'auto';
      final GridResult r;
      if (mode == 'auto') {
        r = grid.complete(dets, w, h);
      } else {
        final anchors = boxes(d['anchors'] as List);
        final counts = [for (final x in d['counts'] as List) x as int];
        r = mode == 'manual_refine'
            ? grid.fromAnchorsRefined(dets, w, h, anchors, counts[0], counts[1])
            : grid.fromAnchors(anchors, counts[0], counts[1]);
      }

      final exp = d['expected_boxes'] as List;
      expect(r.boxes.length, exp.length);
      expect(r.rows, d['expected_rows'] ?? 16);
      expect(r.cols, d['expected_cols'] ?? 24);
      expect(r.shift, [for (final x in d['expected_shift'] as List) x as int]);
      expect(r.detected, [for (final x in d['expected_detected'] as List) x == 1]);
      expect(r.snapped, [for (final x in d['expected_snapped'] as List) x == 1]);
      var maxErr = 0.0;
      for (var i = 0; i < exp.length; i++) {
        for (var k = 0; k < 4; k++) {
          final diff = (r.boxes[i][k] - ((exp[i] as List)[k] as num).toDouble()).abs();
          if (diff > maxErr) maxErr = diff;
        }
      }
      expect(maxErr, lessThan(0.05), reason: 'sai lech box lon nhat $maxErr px');
    });
  }
}
