// So khớp lib/utils/image_frame.dart với acam/inference.py (working_size, stage1_frame, border_median) — fixture sinh
// bởi `python pipelines/40_export_models.py --fixtures 3` ở repo cha.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:microplate_analyzer/utils/image_frame.dart';

void main() {
  final d = jsonDecode(File('test/fixtures/image_frame_cases.json').readAsStringSync()) as Map<String, dynamic>;
  final maxSide = (d['max_image_side'] as num).toInt();
  final aspect = (d['canvas_aspect'] as num).toDouble(), tol = (d['aspect_tol'] as num).toDouble();

  for (final c in d['frames'] as List) {
    test('workingSize + stage1Frame khop Python: ${c['w']}x${c['h']}', () {
      final w = c['w'] as int, h = c['h'] as int;
      final (ww, wh) = workingSize(w, h, maxSide);
      expect([ww, wh], c['working']);
      final f = stage1Frame(w, h, aspect, tol);
      expect(f.rotate, c['rotate']);
      expect([f.top, f.bottom, f.left, f.right], c['pad']);
      expect([f.canvasW, f.canvasH], c['canvas']);
      final t = [for (final v in c['T'] as List) (v as num).toDouble()];
      for (var i = 0; i < 9; i++) {
        expect(f.t[i], closeTo(t[i], 1e-6));
      }
    });
  }

  for (final c in (d['contrast_stretch'] as List?) ?? const []) {
    test('contrastStretch khop Python: ${c['w']}x${c['h']} p${c['lo']}-${c['hi']}', () {
      final px = Uint8List.fromList([for (final v in c['pixels'] as List) v as int]);
      final out = contrastStretch(px, (c['lo'] as num).toDouble(), (c['hi'] as num).toDouble());
      expect(out.toList(), [for (final v in c['expected'] as List) v as int]);
    });
  }

  for (final c in (d['plate_gain'] as List?) ?? const []) {
    test('plateGain + gainLut khop Python: ${(c['sums'] as List).length} crop', () {
      final g = plateGain([for (final v in c['sums'] as List) v as int], c['pixels'] as int,
          (d['plate_ref_gray'] as num).toDouble(), (d['plate_gain_max'] as num).toDouble());
      expect(g, (c['gain'] as num).toDouble());
      expect(gainLut(g).toList(), [for (final v in c['lut'] as List) v as int]);
    });
  }

  for (final c in d['border_median'] as List) {
    test('borderMedian khop Python: ${c['w']}x${c['h']}', () {
      final px = Uint8List.fromList([for (final v in c['pixels'] as List) v as int]);
      expect(borderMedian(px, c['w'] as int, c['h'] as int, (d['pad_border_frac'] as num).toDouble()), c['expected']);
    });
  }
}
