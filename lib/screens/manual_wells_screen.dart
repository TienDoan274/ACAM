/// Stage 2 chỉnh tay: đánh dấu 3 well ① đầu-trái, ② cuối hàng trên cùng (phải), ③ cuối cột trái (dưới)
/// trên plate đã warp + số well mỗi chiều -> app sinh toàn bộ lưới (khi detect tự động sai).
///
/// Luồng từng bước: bước ①/②/③ tự phóng tới góc tương ứng của plate; user CHẠM vào well -> box hút vào
/// detection YOLO gần nhất (chấm xanh = well model tìm được) hoặc box cỡ mặc định, rồi tự sang bước sau.
/// Bước cuối: xem trước lưới trên cả plate + số well mỗi chiều + xác nhận. Đã có đủ 3 box (từ kết quả tự
/// động hoặc lần chỉnh trước) -> mở thẳng bước cuối; chạm ①/②/③ (danh sách hoặc box trên ảnh) để làm lại.
///
/// Trả về [ManualWells] (px ảnh warp). Lưới 16x24 + "Refine with detector": InferenceService dùng 3 box làm
/// lưới ban đầu rồi khớp với YOLO (chính xác ~1 px); kích thước khác: lưới thuần hình học từ 3 box.
library manual_wells_screen;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/stage_meta.dart';
import '../utils/pipeline_config.dart';
import '../utils/well_grid.dart';
import '../widgets/help_example.dart';
import '../widgets/plate_edit_canvas.dart';

/// Điền sẵn ①②③ từ lưới đã có (vd. kết quả tự động): 4 well góc của lưới -> chọn theo vị trí trên ảnh.
ManualWells? prefillFromGrid(List<Map<String, dynamic>> boxes, int rows, int cols) {
  if (boxes.length != rows * cols || rows < 2 || cols < 2) return null;
  final idx = [0, cols - 1, (rows - 1) * cols, rows * cols - 1];
  Offset c(int i) => Offset(((boxes[i]['x1'] as num) + (boxes[i]['x2'] as num)) / 2,
      ((boxes[i]['y1'] as num) + (boxes[i]['y2'] as num)) / 2);
  int pick(double Function(Offset) score) => idx.reduce((a, b) => score(c(a)) >= score(c(b)) ? a : b);
  final tl = pick((p) => -(p.dx + p.dy)), tr = pick((p) => p.dx - p.dy), bl = pick((p) => p.dy - p.dx);
  List<double> box(int i) => [for (final k in ['x1', 'y1', 'x2', 'y2']) (boxes[i][k] as num).toDouble()];
  final sameRow = tl ~/ cols == tr ~/ cols;
  return ManualWells([box(tl), box(tr), box(bl)], sameRow ? cols : rows, sameRow ? rows : cols, true);
}

class ManualWellsScreen extends StatefulWidget {
  final EditImage image; // plate đã warp
  final WellGrid grid; // lưới cấu hình (16x24: vị trí dự kiến, preview)
  final ManualWells? initial;

  /// YOLO thô trên plate (px ảnh warp gốc): chấm "well model tìm được" + chạm hút box vào đó. null = không có.
  final Future<List<Det>> Function()? detectWells;

  const ManualWellsScreen({super.key, required this.image, required this.grid, this.initial, this.detectWells});

  @override
  State<ManualWellsScreen> createState() => _ManualWellsScreenState();
}

enum _Op { none, draw, move, resize }

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

class _ManualWellsScreenState extends State<ManualWellsScreen> {
  static const double _hitRadius = 26; // px màn hình
  static const _review = 3; // bước cuối: xem lại lưới + số well
  static const _labels = ['①', '②', '③'];
  static const _titles = ['First well', 'Last well of the top row', 'Last well of the left column'];
  static const _where = ['top-left corner of the grid', 'right end of that row', 'bottom end of that column'];
  static const _colors = [Color(0xFFFF9800), Color(0xFF00E5FF), Color(0xFFFF4081)];
  static const _dotColor = Color(0xFF69F0AE);

  final _canvas = PlateEditController();
  final List<Rect?> _boxes = [null, null, null];
  int _step = 0;
  int? _n12, _n13;
  bool _countsTouched = false;
  bool _refine = true;
  bool _dirty = false;
  int _rememberLong = 0, _rememberShort = 0;

  List<Det> _dets = const [];
  bool _detecting = false;
  late final List<Offset> _expected; // vị trí dự kiến ①②③ theo template lưới -> phóng tới đúng góc
  late final double _pitch; // bước lưới dự kiến (px ảnh warp)

  _Op _op = _Op.none;
  int? _editK; // box đang sửa
  Offset _start = Offset.zero, _moveOffset = Offset.zero;
  Offset _downSrc = Offset.zero, _downScreen = Offset.zero;
  double _maxMove = 0; // px màn hình: < 10 -> chạm, không phải kéo
  double _lastScale = 1;
  List<Rect?>? _snap;

  PipelineConfig get _cfg => PipelineConfig.I;
  double get _w => widget.image.srcW.toDouble();
  double get _h => widget.image.srcH.toDouble();

  @override
  void initState() {
    super.initState();
    final m = widget.initial;
    if (m != null) {
      for (var k = 0; k < 3; k++) {
        final a = m.anchors[k];
        _boxes[k] = Rect.fromLTRB(a[0], a[1], a[2], a[3]);
      }
      _n12 = m.n12;
      _n13 = m.n13;
      _refine = m.refine;
      _countsTouched = true;
    }
    // Plate đã warp về khung chuẩn -> template lưới cho vị trí dự kiến của 3 well góc + bước lưới
    final g = widget.grid;
    final nodes = g.nodes(g.initialHomography(_w, _h));
    _pitch = g.pitch(nodes);
    final rows = g.p.rows, cols = g.p.cols;
    final corner = [
      for (final i in [0, cols - 1, (rows - 1) * cols, rows * cols - 1]) Offset(nodes[i][0], nodes[i][1])
    ];
    Offset pick(double Function(Offset) score) => corner.reduce((a, b) => score(a) >= score(b) ? a : b);
    _expected = [pick((p) => -(p.dx + p.dy)), pick((p) => p.dx - p.dy), pick((p) => p.dy - p.dx)];
    _step = _nextMissing(2) ?? _review;

    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _rememberLong = p.getInt('manual_wells_long') ?? 0;
        _rememberShort = p.getInt('manual_wells_short') ?? 0;
      });
    });
    final detect = widget.detectWells;
    if (detect != null) {
      _detecting = true;
      detect().then<void>((d) {
        if (mounted) {
          setState(() {
            _dets = d;
            _detecting = false;
          });
        }
      }, onError: (Object e) {
        if (mounted) setState(() => _detecting = false);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusStep();
    });
  }

  // ── Bước ──────────────────────────────────────────────────────────────────
  /// Box chưa đặt đầu tiên sau [after] (vòng ①②③), null nếu đủ cả 3.
  int? _nextMissing(int after) {
    for (var i = 1; i <= 3; i++) {
      final k = (after + i) % 3;
      if (_boxes[k] == null) return k;
    }
    return null;
  }

  void _goTo(int step) {
    setState(() {
      _step = step;
      _op = _Op.none;
      _editK = null;
    });
    _focusStep();
  }

  /// Bước ①②③: phóng tới well đó (box đã có, hoặc vị trí dự kiến), lệch vào trong plate để thấy cả mép
  /// plate lẫn vài hàng / cột well; bước cuối: cả plate.
  void _focusStep() {
    if (_step == _review) {
      _canvas.fit();
      return;
    }
    final target = _boxes[_step]?.center ?? _expected[_step];
    final toMid = Offset(_w / 2, _h / 2) - target;
    final d = toMid.distance;
    _canvas.focus(d > 0 ? target + toMid / d * (2 * _pitch) : target, 9 * _pitch);
  }

  // ── Số well mỗi chiều ─────────────────────────────────────────────────────
  /// Mặc định: chiều dài hơn nhận số well lớn hơn (lần nhập trước, hoặc lưới cấu hình). Chưa đủ 3 box thì
  /// theo hướng ảnh: plate ngang -> hàng trên cùng (①→②) là chiều dài.
  (int, int) get _counts {
    if (_countsTouched && _n12 != null && _n13 != null) return (_n12!, _n13!);
    final long = _rememberLong >= 2 ? _rememberLong : math.max(_cfg.rows, _cfg.cols);
    final short = _rememberShort >= 2 ? _rememberShort : math.min(_cfg.rows, _cfg.cols);
    final b = _boxes;
    if (b[0] != null && b[1] != null && b[2] != null) {
      final d12 = (b[1]!.center - b[0]!.center).distance, d13 = (b[2]!.center - b[0]!.center).distance;
      return d12 >= d13 ? (long, short) : (short, long);
    }
    return _w >= _h ? (long, short) : (short, long);
  }

  void _setCounts(int n12, int n13) => setState(() {
        final mx = _cfg.manualMaxPerAxis;
        _n12 = n12.clamp(2, mx);
        _n13 = n13.clamp(2, mx);
        _countsTouched = true;
        _dirty = true;
      });

  List<List<double>>? get _anchors =>
      _boxes.any((b) => b == null) ? null : [for (final b in _boxes) [b!.left, b.top, b.right, b.bottom]];

  bool get _hybridPossible {
    final (n12, n13) = _counts;
    return widget.grid.isHybridCounts(n12, n13);
  }

  // ── Kiểm tra ──────────────────────────────────────────────────────────────
  (List<String>, List<String>) _check() {
    final missing = [for (var k = 0; k < 3; k++) if (_boxes[k] == null) _labels[k]];
    if (missing.isNotEmpty) return (['mark well ${missing.join(' ')}'], <String>[]);
    final c = [for (final b in _boxes) b!.center];
    final e1 = c[1] - c[0], e2 = c[2] - c[0];
    final errors = <String>[], warns = <String>[];
    if (e1.distance < 1 || e2.distance < 1) return (['boxes overlap'], warns);
    final ang = math.acos(((e1.dx * e2.dx + e1.dy * e2.dy) / (e1.distance * e2.distance)).clamp(-1.0, 1.0)) * 180 / math.pi;
    if (ang < 60 || ang > 120) errors.add('② and ③ must be on different sides of ① (angle ${ang.round()}°)');
    final (n12, n13) = _counts;
    final ratio = (e1.distance / (n12 - 1)) / (e2.distance / (n13 - 1));
    if (ratio < _cfg.manualPitchRatioMin || ratio > _cfg.manualPitchRatioMax) {
      warns.add('well spacing differs between the two directions (×${ratio.toStringAsFixed(2)}) — counts swapped?');
    }
    return (errors, warns);
  }

  // ── Chỉnh sửa ─────────────────────────────────────────────────────────────
  Offset _clamp(Offset p) => Offset(p.dx.clamp(0.0, _w - 1), p.dy.clamp(0.0, _h - 1));

  double get _defaultSide {
    if (_dets.isNotEmpty) return _median([for (final d in _dets) ((d.x2 - d.x1) + (d.y2 - d.y1)) / 2]);
    final set = _boxes.whereType<Rect>().toList();
    if (set.isNotEmpty) return set.map((r) => (r.width + r.height) / 2).reduce((a, b) => a + b) / set.length;
    return 0.8 * _pitch;
  }

  /// Chạm tại [p]: box YOLO có tâm gần nhất (trong 0.6 bước lưới), không có thì box vuông cỡ mặc định.
  void _place(int k, Offset p) {
    Det? best;
    var bd = 0.6 * _pitch;
    for (final d in _dets) {
      final dist = (Offset(d.cx, d.cy) - p).distance;
      if (dist < bd) {
        bd = dist;
        best = d;
      }
    }
    _boxes[k] = best != null
        ? Rect.fromLTRB(best.x1, best.y1, best.x2, best.y2)
        : Rect.fromCenter(center: p, width: _defaultSide, height: _defaultSide);
  }

  void _onStart(Offset src, PlateView v) {
    _lastScale = v.scale;
    _snap = List.of(_boxes);
    _downSrc = _clamp(src);
    _downScreen = v.toScreen(src);
    _maxMove = 0;
    setState(() {
      _op = _Op.none;
      _editK = null;
      if (_step < _review) {
        // Bước ①②③: góc box -> đổi cỡ; trong box -> dời; chỗ trống -> box mới (chạm hoặc kéo để vẽ).
        // Chỉ box của bước hiện tại sửa được, box khác không bị đụng nhầm khi đặt well kề bên.
        final a = _boxes[_step];
        if (a != null) {
          final corners = [a.topLeft, a.topRight, a.bottomRight, a.bottomLeft];
          for (var i = 0; i < 4; i++) {
            if ((v.toScreen(corners[i]) - _downScreen).distance < _hitRadius) {
              _op = _Op.resize;
              _editK = _step;
              _start = corners[(i + 2) % 4]; // góc đối diện đứng yên
              return;
            }
          }
          if (a.inflate(8 / v.scale).contains(src)) {
            _op = _Op.move;
            _editK = _step;
            _moveOffset = a.topLeft - src;
            return;
          }
        }
        _op = _Op.draw;
        _editK = _step;
        _start = _downSrc;
        _boxes[_step] = Rect.fromPoints(_start, _start);
        return;
      }
      // Bước cuối: kéo box để tinh chỉnh (lưới xem trước chạy theo), chạm box -> làm lại bước đó
      for (var k = 0; k < 3; k++) {
        final b = _boxes[k];
        if (b != null && b.inflate(8 / v.scale).contains(src)) {
          _op = _Op.move;
          _editK = k;
          _moveOffset = b.topLeft - src;
          return;
        }
      }
    });
  }

  void _onUpdate(Offset src, PlateView v) {
    final k = _editK;
    if (k == null) return;
    _maxMove = math.max(_maxMove, (v.toScreen(src) - _downScreen).distance);
    setState(() {
      switch (_op) {
        case _Op.draw:
        case _Op.resize:
          _boxes[k] = Rect.fromPoints(_start, _clamp(src));
        case _Op.move:
          final b = _boxes[k];
          if (b == null) return;
          _boxes[k] = (src + _moveOffset) & b.size;
        case _Op.none:
          return;
      }
      _dirty = true;
    });
  }

  void _onEnd() {
    final k = _editK, op = _op;
    final tap = _maxMove < 10;
    int? next;
    setState(() {
      _op = _Op.none;
      _editK = null;
      if (k == null) return;
      if (_step < _review) {
        // Chạm (kể cả chạm vào box cũ) = đặt box tại điểm chạm; kéo chỗ trống = box vẽ tay. Xong -> bước sau.
        if (op == _Op.draw || (op == _Op.move && tap)) {
          final b = _boxes[k];
          if (op == _Op.move || b == null || b.width * _lastScale < 10 || b.height * _lastScale < 10) _place(k, _downSrc);
          _dirty = true;
          next = _nextMissing(k) ?? _review;
        }
      } else if (op == _Op.move && tap) {
        _boxes[k] = _snap![k];
        next = k;
      }
    });
    final n = next;
    if (n != null) _goTo(n);
  }

  void _onCancel() => setState(() {
        final s = _snap;
        if (s != null) {
          for (var k = 0; k < 3; k++) {
            _boxes[k] = s[k];
          }
        }
        _op = _Op.none;
        _editK = null;
      });

  void _startOver() {
    setState(() {
      for (var k = 0; k < 3; k++) {
        _boxes[k] = null;
      }
      _dirty = true;
    });
    _goTo(0);
  }

  // ── Vẽ ────────────────────────────────────────────────────────────────────
  void _paint(Canvas canvas, PlateView v) {
    // Well model tìm được (YOLO): chấm nhỏ — chạm gần chấm thì box hút vào đó
    if (_dets.isNotEmpty) {
      final dot = Paint()..color = _dotColor.withValues(alpha: 0.9);
      final r = (0.1 * _pitch * v.scale).clamp(1.5, 4.0);
      for (final d in _dets) {
        canvas.drawCircle(v.toScreen(Offset(d.cx, d.cy)), r, dot);
      }
    }
    final anchors = _anchors;
    final (errors, _) = _check();
    if (anchors != null && errors.isEmpty) {
      final (n12, n13) = _counts;
      final g = widget.grid.fromAnchors(anchors, n12, n13);
      final p = Paint()
        ..color = Colors.white.withValues(alpha: _step == _review ? 0.8 : 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      for (final b in g.boxes) {
        canvas.drawRect(Rect.fromPoints(v.toScreen(Offset(b[0], b[1])), v.toScreen(Offset(b[2], b[3]))), p);
      }
    }
    for (var k = 0; k < 3; k++) {
      final b = _boxes[k];
      if (b == null) continue;
      final current = k == _step;
      final r = Rect.fromPoints(v.toScreen(b.topLeft), v.toScreen(b.bottomRight));
      canvas.drawRect(
          r,
          Paint()
            ..color = _colors[k]
            ..style = PaintingStyle.stroke
            ..strokeWidth = current ? 3 : 2);
      final tp = TextPainter(
        text: TextSpan(
            text: _labels[k],
            style: TextStyle(color: _colors[k], fontSize: 16, fontWeight: FontWeight.bold, shadows: const [
              Shadow(color: Colors.black, blurRadius: 3),
            ])),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, r.topLeft - Offset(0, tp.height + 1));
      if (current) {
        for (final c in [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft]) {
          canvas.drawCircle(c, 6, Paint()..color = _colors[k]);
        }
      }
    }
  }

  Future<void> _confirm() async {
    final (n12, n13) = _counts;
    final p = await SharedPreferences.getInstance();
    await p.setInt('manual_wells_long', math.max(n12, n13));
    await p.setInt('manual_wells_short', math.min(n12, n13));
    if (!mounted) return;
    Navigator.pop(context, ManualWells(_anchors!, n12, n13, _refine && _hybridPossible));
  }

  Future<void> _maybePop() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your well boxes will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  // ── Panel ─────────────────────────────────────────────────────────────────
  Color _stepColor(int k) => k < 3 ? _colors[k] : Colors.teal;

  Widget _stepTile(int k) {
    final active = _step == k;
    final done = k < 3 && _boxes[k] != null;
    final color = _stepColor(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _goTo(k),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.15) : null,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? color : Colors.transparent),
          ),
          child: Row(children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: k < 3
                  ? Text('${k + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black))
                  : const Icon(Icons.grid_on, size: 12, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(k < 3 ? _titles[k] : 'Check grid & confirm',
                  style: TextStyle(fontSize: 12, fontWeight: active ? FontWeight.w700 : FontWeight.normal)),
            ),
            if (done) const Icon(Icons.check, size: 16, color: Colors.green),
          ]),
        ),
      ),
    );
  }

  Widget _stepper(String label, int value, void Function(int) onChanged) => Row(children: [
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12))),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          onPressed: () => onChanged(value - 1),
        ),
        SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_circle_outline, size: 20),
          onPressed: () => onChanged(value + 1),
        ),
      ]);

  Widget _note(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        ]),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text(text, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
      );

  List<Widget> _placeBody(int k) => [
        Text('Tap the ${_titles[k].toLowerCase()} — ${_where[k]}.',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (_detecting)
          _hint('Finding wells…')
        else if (_dets.isNotEmpty)
          _hint('Green dots = wells the model found. Your tap snaps to the nearest dot.')
        else
          _hint('Your tap places a box on that well.'),
        if (_boxes[k] != null) _hint('Wrong well? Just tap the right one. Drag the box to move it, its corners to resize.'),
        const SizedBox(height: 6),
        Row(children: [
          if (k > 0) TextButton(onPressed: () => _goTo(k - 1), child: const Text('Back')),
          const Spacer(),
          FilledButton.tonal(
            onPressed: _boxes[k] != null ? () => _goTo(k < 2 ? k + 1 : _review) : null,
            child: Text(k < 2 ? 'Next' : 'Check grid'),
          ),
        ]),
      ];

  List<Widget> _reviewBody() {
    final (errors, warns) = _check();
    final (n12, n13) = _counts;
    final hybrid = _hybridPossible;
    return [
      const Text('Every white box should sit on a well.', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      _hint('Tap ①②③ on the photo to redo one, or drag it to fine-tune.'),
      const SizedBox(height: 4),
      _stepper('Wells in the top row (① → ②)', n12, (v) => _setCounts(v, n13)),
      _stepper('Wells in the left column (① → ③)', n13, (v) => _setCounts(n12, v)),
      Row(children: [
        Expanded(child: Text('${n12 * n13} wells in total', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        TextButton.icon(
          onPressed: () => _setCounts(n13, n12),
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Swap', style: TextStyle(fontSize: 12)),
        ),
      ]),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: _refine && hybrid,
        onChanged: hybrid ? (v) => setState(() => _refine = v) : null,
        title: const Text('Refine with detector', style: TextStyle(fontSize: 12)),
        subtitle: Text(
            hybrid
                ? 'Snap the grid to wells found by the model (recommended)'
                : 'Only for ${_cfg.rows}×${_cfg.cols} plates — boxes will be placed from your 3 wells',
            style: const TextStyle(fontSize: 10)),
      ),
      for (final e in errors) _note(Icons.error_outline, Colors.red, e),
      for (final w in warns) _note(Icons.warning_amber, Colors.orange, w),
      if (errors.isEmpty && warns.isEmpty) _note(Icons.check_circle_outline, Colors.green, 'Grid preview looks consistent'),
      const SizedBox(height: 4),
      FilledButton.icon(
        onPressed: errors.isEmpty ? _confirm : null,
        icon: const Icon(Icons.check, size: 18),
        label: const Text('Use this grid'),
      ),
      const SizedBox(height: 4),
      OutlinedButton.icon(
        onPressed: _startOver,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: const Text('Start over'),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final (n12, n13) = _counts;
    final insets = MediaQuery.of(context).systemGestureInsets;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybePop();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(toolbarHeight: 44, title: const Text('Manual wells', style: TextStyle(fontSize: 15))),
        body: Row(children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: insets.left),
              child: PlateEditCanvas(
                image: widget.image,
                controller: _canvas,
                paintOverlay: _paint,
                onEditStart: _onStart,
                onEditUpdate: _onUpdate,
                onEditEnd: _onEnd,
                onEditCancel: _onCancel,
                loupeAt: switch (_op) {
                  _Op.draw || _Op.resize => _nonStartCorner(_editK == null ? null : _boxes[_editK!]),
                  _Op.move => _editK == null ? null : _boxes[_editK!]?.center,
                  _Op.none => null,
                },
              ),
            ),
          ),
          SizedBox(
            width: 260,
            child: Padding(
              padding: EdgeInsets.fromLTRB(10, 8, 10 + insets.right, 8),
              child: ListView(children: [
                _WellsDiagram(nx: n12, ny: n13, step: _step, done: [for (final b in _boxes) b != null]),
                const SizedBox(height: 6),
                for (var k = 0; k <= _review; k++) _stepTile(k),
                const Divider(height: 12),
                ...(_step < _review ? _placeBody(_step) : _reviewBody()),
                ValueListenableBuilder<bool>(
                  valueListenable: _canvas.zoomed,
                  builder: (_, zoomed, __) {
                    if (zoomed) {
                      return TextButton.icon(
                        onPressed: _canvas.fit,
                        icon: const Icon(Icons.zoom_out_map, size: 16),
                        label: const Text('Show whole plate', style: TextStyle(fontSize: 12)),
                      );
                    }
                    if (_step < _review) {
                      return TextButton.icon(
                        onPressed: _focusStep,
                        icon: const Icon(Icons.zoom_in, size: 16),
                        label: Text('Zoom to well ${_labels[_step]}', style: const TextStyle(fontSize: 12)),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                TextButton.icon(
                  onPressed: () => HelpExample.show(context, 'assets/help/wells_example.jpg', 'Which 3 wells to mark'),
                  icon: const Icon(Icons.photo_outlined, size: 16),
                  label: const Text('Example on a real plate', style: TextStyle(fontSize: 12)),
                ),
                _hint('Two fingers: zoom and pan.'),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  /// Góc box đang kéo (không phải góc cố định [_start]) — tâm kính lúp khi vẽ / đổi cỡ.
  Offset? _nonStartCorner(Rect? b) {
    if (b == null) return null;
    Offset far = b.topLeft;
    var best = -1.0;
    for (final c in [b.topLeft, b.topRight, b.bottomRight, b.bottomLeft]) {
      final d = (c - _start).distance;
      if (d > best) {
        best = d;
        far = c;
      }
    }
    return far;
  }
}

/// Sơ đồ plate nhỏ trong panel: lưới nx x ny chấm, 3 well ①②③ tô màu (bước hiện tại có viền trắng);
/// bước cuối thêm số well mỗi chiều.
class _WellsDiagram extends StatelessWidget {
  final int nx, ny, step;
  final List<bool> done;
  const _WellsDiagram({required this.nx, required this.ny, required this.step, required this.done});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final cell = math.min(c.maxWidth / (nx + 1), 100 / (ny + 1));
      return SizedBox(
        width: c.maxWidth,
        height: cell * (ny + 1),
        child: CustomPaint(painter: _DiagramPainter(nx, ny, step, done)),
      );
    });
  }
}

class _DiagramPainter extends CustomPainter {
  final int nx, ny, step;
  final List<bool> done;
  _DiagramPainter(this.nx, this.ny, this.step, this.done);

  static const _colors = _ManualWellsScreenState._colors;

  void _text(Canvas canvas, String s, Offset center, double size, Color color, {Color? bg}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(fontSize: size, fontWeight: FontWeight.bold, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    if (bg != null) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromCenter(center: center, width: tp.width + 8, height: tp.height + 2), const Radius.circular(4)),
          Paint()..color = bg);
    }
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final cell = math.min(size.width / (nx + 1), size.height / (ny + 1));
    final pw = cell * (nx + 1), ph = cell * (ny + 1);
    final o = Offset((size.width - pw) / 2, (size.height - ph) / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(o & Size(pw, ph), Radius.circular(cell * 0.6)),
        Paint()..color = const Color(0xFF37474F));
    Offset at(int c, int r) => o + Offset((c + 1) * cell, (r + 1) * cell);
    final dot = Paint()..color = const Color(0xFF90A4AE);
    final rd = math.max(0.7, cell * 0.28);
    for (var r = 0; r < ny; r++) {
      for (var c = 0; c < nx; c++) {
        canvas.drawCircle(at(c, r), rd, dot);
      }
    }
    if (step == 3) {
      final line = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.5;
      canvas.drawLine(at(0, 0), at(nx - 1, 0), line);
      canvas.drawLine(at(0, 0), at(0, ny - 1), line);
      _text(canvas, '$nx', (at(0, 0) + at(nx - 1, 0)) / 2, 10, Colors.white, bg: Colors.black87);
      _text(canvas, '$ny', (at(0, 0) + at(0, ny - 1)) / 2, 10, Colors.white, bg: Colors.black87);
    }
    final pos = [at(0, 0), at(nx - 1, 0), at(0, ny - 1)];
    for (var k = 0; k < 3; k++) {
      final current = k == step;
      final r = current ? math.max(7.0, cell * 0.9) : math.max(5.5, cell * 0.7);
      canvas.drawCircle(pos[k], r, Paint()..color = _colors[k].withValues(alpha: current || done[k] ? 1 : 0.5));
      if (current) {
        canvas.drawCircle(
            pos[k],
            r + 1.5,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
      _text(canvas, '${k + 1}', pos[k], r * 1.2, Colors.black);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagramPainter old) =>
      old.nx != nx || old.ny != ny || old.step != step || old.done.join() != done.join();
}
