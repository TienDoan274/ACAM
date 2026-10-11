/// Stage 1 chỉnh tay: kéo 4 handle vào 4 góc NGOÀI của plate trên ảnh gốc (khi căn tự động sai).
///
/// Điểm bắt đầu: kết quả Stage 1 hiện có (model hoặc lần chỉnh tay trước); chưa chạy Stage 1 thì hình chữ
/// nhật mặc định — user có thể bấm "Detect with model" để lấy góc của model rồi chỉnh tiếp.
/// Trả về (Navigator.pop) [ManualCornersResult]: 4 góc `{'x','y'}` px ảnh gốc, sắp TL, TR, BR, BL (đúng
/// thứ tự `_warpPlate` dùng) + cờ fromModel (giữ nguyên góc model -> lưu như kết quả tự động).
/// Chặn xác nhận nếu tứ giác không lồi; góc lệch / quá nhỏ / tỉ lệ lạ chỉ nhắc.
library manual_corners_screen;

import 'package:flutter/material.dart';

import '../utils/pipeline_config.dart';
import '../utils/plate_geometry.dart';
import '../widgets/help_example.dart';
import '../widgets/plate_edit_canvas.dart';

class ManualCornersResult {
  final List<Map<String, double>> corners;
  final bool fromModel; // đúng góc model, không chỉnh gì
  const ManualCornersResult(this.corners, this.fromModel);
}

class ManualCornersScreen extends StatefulWidget {
  final EditImage image;

  /// Góc bắt đầu (px ảnh gốc): kết quả Stage 1 hiện tại; null -> hình chữ nhật lùi vào 10% (chưa chạy).
  final List<Map<String, double>>? initial;

  /// Góc model đã biết (null: chưa chạy model -> [detectModel] chạy khi user bấm).
  final List<Map<String, double>>? modelCorners;
  final Future<List<Map<String, double>>> Function()? detectModel;

  const ManualCornersScreen({super.key, required this.image, this.initial, this.modelCorners, this.detectModel});

  @override
  State<ManualCornersScreen> createState() => _ManualCornersScreenState();
}

class _ManualCornersScreenState extends State<ManualCornersScreen> {
  static const double _hitRadius = 28; // px màn hình

  final _canvas = PlateEditController();
  List<Offset>? _initial; // điểm lúc mở (kết quả Stage 1 hiện có)
  List<Offset>? _model; // góc model (biết trước hoặc vừa chạy)
  late List<Offset> _pts;
  bool _placing = false; // "Tap 4 corners": mỗi lần chạm đặt 1 góc
  List<Offset> _placeBackup = const [];
  bool _detecting = false;
  int? _drag;
  Offset _dragOffset = Offset.zero;
  List<Offset>? _snapPts;
  bool _snapPlacing = false;
  bool _dirty = false;

  double get _w => widget.image.srcW.toDouble();
  double get _h => widget.image.srcH.toDouble();

  static List<Offset>? _offsets(List<Map<String, double>>? c) => c == null ? null : [for (final p in c) Offset(p['x']!, p['y']!)];

  static bool _same(List<Offset>? a, List<Offset>? b) {
    if (a == null || b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).distance > 0.5) return false;
    }
    return true;
  }

  bool get _showingModel => !_placing && _same(_pts, _model);
  bool get _startIsModel => _same(_initial, _model);

  @override
  void initState() {
    super.initState();
    _initial = _offsets(widget.initial);
    _model = _offsets(widget.modelCorners);
    _pts = List.of(_initial ??
        [Offset(0.1 * _w, 0.1 * _h), Offset(0.9 * _w, 0.1 * _h), Offset(0.9 * _w, 0.9 * _h), Offset(0.1 * _w, 0.9 * _h)]);
  }

  Offset _clamp(Offset p) => Offset(p.dx.clamp(0.0, _w - 1), p.dy.clamp(0.0, _h - 1));

  List<Corner> get _maps => [for (final p in _pts) {'x': p.dx, 'y': p.dy}];

  // ── Nút ───────────────────────────────────────────────────────────────────
  Future<void> _useModel() async {
    if (_model == null) {
      final detect = widget.detectModel;
      if (detect == null) return;
      setState(() => _detecting = true);
      try {
        _model = _offsets(await detect());
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Corner detection failed: $e')));
        }
      }
      if (!mounted) return;
      setState(() => _detecting = false);
      if (_model == null) return;
    }
    setState(() {
      _pts = List.of(_model!);
      _placing = false;
      _drag = null;
      _dirty = true;
    });
  }

  // Nút bên panel có thể được bấm bằng ngón thứ 2 trong lúc ngón 1 còn giữ handle trên ảnh -> mọi nút đổi
  // danh sách điểm phải bỏ handle đang kéo (_drag trỏ vào điểm không còn tồn tại -> RangeError).
  void _startTapping() => setState(() {
        _placeBackup = List.of(_pts);
        _pts = [];
        _placing = true;
        _drag = null;
        _dirty = true;
      });

  void _cancelTapping() => setState(() {
        _pts = List.of(_placeBackup);
        _placing = false;
        _drag = null;
      });

  void _backToSaved() => setState(() {
        _pts = List.of(_initial!);
        _drag = null;
      });

  // ── Chỉnh sửa ─────────────────────────────────────────────────────────────
  void _onStart(Offset src, PlateView view) {
    _snapPts = List.of(_pts);
    _snapPlacing = _placing;
    setState(() {
      if (_placing) {
        if (_pts.length >= 4) return;
        _pts.add(_clamp(src));
        _drag = _pts.length - 1;
        _dragOffset = Offset.zero;
        return; // góc thứ 4: thoát chế độ đặt điểm khi nhấc tay (_onEnd), panel không đổi nút giữa chừng
      }
      _drag = null;
      var best = _hitRadius;
      for (var i = 0; i < _pts.length; i++) {
        final d = (view.toScreen(_pts[i]) - view.toScreen(src)).distance;
        if (d < best) {
          best = d;
          _drag = i;
        }
      }
      if (_drag != null) _dragOffset = _pts[_drag!] - src;
    });
  }

  void _onUpdate(Offset src, PlateView view) {
    final i = _drag;
    if (i == null || i >= _pts.length) return;
    setState(() {
      _pts[i] = _clamp(src + _dragOffset);
      _dirty = true;
    });
  }

  void _onEnd() => setState(() {
        _drag = null;
        if (_placing && _pts.length == 4) _placing = false;
      });

  void _onCancel() => setState(() {
        if (_snapPts != null) _pts = _snapPts!;
        _placing = _snapPlacing;
        _drag = null;
      });

  // ── Kiểm tra ──────────────────────────────────────────────────────────────
  /// (lỗi chặn xác nhận, gợi ý không chặn)
  (List<String>, List<String>) _check() {
    if (_pts.length < 4) return (['tap ${4 - _pts.length} more corner(s)'], <String>[]);
    // Tứ giác không lồi thì warp vô nghĩa -> chặn; góc lệch (chụp nghiêng mạnh) / plate nhỏ / tỉ lệ lạ chỉ nhắc
    const hard = {'not_convex'};
    final warn = stage1Warnings(quadMetrics(_maps, _w, _h), PipelineConfig.I);
    return (
      warn.where(hard.contains).map(warningText).toList(),
      warn.where((w) => !hard.contains(w)).map(warningText).toList(),
    );
  }

  // ── Vẽ ────────────────────────────────────────────────────────────────────
  void _paint(Canvas canvas, PlateView v) {
    final (blocking, _) = _check();
    final line = Paint()
      ..color = blocking.isEmpty ? const Color(0xFFFFC107) : Colors.redAccent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final pts = _pts.length == 4 ? [for (final c in orderCorners(_maps)) Offset(c['x']!, c['y']!)] : _pts;
    if (pts.length >= 2) {
      final path = Path()..moveTo(v.toScreen(pts[0]).dx, v.toScreen(pts[0]).dy);
      for (final p in pts.skip(1)) {
        final s = v.toScreen(p);
        path.lineTo(s.dx, s.dy);
      }
      if (pts.length == 4) path.close();
      canvas.drawPath(path, line);
    }
    for (var i = 0; i < _pts.length; i++) {
      final s = v.toScreen(_pts[i]);
      final active = i == _drag;
      final color = active ? Colors.lightBlueAccent : Colors.white;
      canvas.drawCircle(s, active ? 14 : 11, Paint()..color = color.withValues(alpha: 0.28));
      canvas.drawCircle(
          s,
          active ? 14 : 11,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      final cross = Paint()
        ..color = Colors.black
        ..strokeWidth = 1;
      canvas.drawLine(s - const Offset(5, 0), s + const Offset(5, 0), cross);
      canvas.drawLine(s - const Offset(0, 5), s + const Offset(0, 5), cross);
    }
  }

  Future<void> _maybePop() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your corner edits will be lost.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (leave == true && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final (blocking, hints) = _check();
    final insets = MediaQuery.of(context).systemGestureInsets;
    final canModel = _model != null || widget.detectModel != null;
    final String instruction;
    if (_placing) {
      instruction = _pts.length < 4
          ? 'Tap corner ${_pts.length + 1} of 4 — the OUTER corners of the plate, in any order.'
          : 'Slide to fine-tune corner 4, then lift your finger.';
    } else if (_showingModel) {
      instruction = 'Model result shown. Drag a handle if it misses a plate corner.';
    } else if (_initial != null) {
      instruction = 'Your saved corners are shown. Drag the handles onto the OUTER corners of the plate.';
    } else {
      instruction = 'Drag the 4 handles onto the OUTER corners of the plate, or let the model detect them.';
    }
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _maybePop();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(toolbarHeight: 44, title: const Text('Plate corners', style: TextStyle(fontSize: 15))),
        body: Row(children: [
          Expanded(
            child: Padding(
              // Chừa lề cử chỉ hệ thống: kéo handle sát mép trái không bị Android hiểu là "Back"
              padding: EdgeInsets.only(left: insets.left),
              child: PlateEditCanvas(
                image: widget.image,
                controller: _canvas,
                paintOverlay: _paint,
                onEditStart: _onStart,
                onEditUpdate: _onUpdate,
                onEditEnd: _onEnd,
                onEditCancel: _onCancel,
                loupeAt: (_drag != null && _drag! < _pts.length) ? _pts[_drag!] : null,
              ),
            ),
          ),
          SizedBox(
            width: 240,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 10, 12 + insets.right, 10),
              child: ListView(children: [
                Text(instruction, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const HelpExample(
                  thumbAsset: 'assets/help/corners_example_thumb.jpg',
                  fullAsset: 'assets/help/corners_example.jpg',
                  title: 'Where the 4 corner points go',
                  caption: 'Correct placement — tap to compare with a wrong one',
                ),
                const SizedBox(height: 10),
                if (blocking.isNotEmpty)
                  _note(Icons.error_outline, Colors.red, 'Fix: ${blocking.join(', ')}')
                else if (hints.isNotEmpty)
                  _note(Icons.warning_amber, Colors.orange, 'Check: ${hints.join(', ')}')
                else
                  _note(Icons.check_circle_outline, Colors.green, 'Corners look valid'),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: blocking.isEmpty
                      ? () => Navigator.pop(context, ManualCornersResult(orderCorners(_maps), _showingModel))
                      : null,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Use these corners'),
                ),
                if (canModel && !_showingModel) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _detecting ? null : _useModel,
                    icon: _detecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.auto_fix_high, size: 18),
                    label: Text(_detecting ? 'Detecting...' : (_model != null ? 'Use model result' : 'Detect with model')),
                  ),
                ],
                // Chỉ khi điểm lúc mở là góc chỉnh tay đã lưu (khác kết quả model) — tránh 2 nút cùng tác dụng
                if (_initial != null && !_startIsModel && !_placing && !_same(_pts, _initial)) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _backToSaved,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Back to saved corners'),
                  ),
                ],
                const SizedBox(height: 8),
                if (_placing)
                  OutlinedButton.icon(
                    onPressed: _cancelTapping,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel tapping'),
                  )
                else ...[
                  OutlinedButton.icon(
                    onPressed: _startTapping,
                    icon: const Icon(Icons.touch_app, size: 18),
                    label: const Text('Tap 4 corners'),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, left: 4),
                    child: Text('Clears the points; then tap the 4 plate corners one by one.',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                  ),
                ],
                ValueListenableBuilder<bool>(
                  valueListenable: _canvas.zoomed,
                  builder: (_, zoomed, __) => zoomed
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                            onPressed: _canvas.fit,
                            icon: const Icon(Icons.zoom_out_map, size: 18),
                            label: const Text('Show whole photo'),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 10),
                Text('Two fingers: zoom and pan. While you drag, the loupe shows the point under your finger.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _note(IconData icon, Color color, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
      ]);
}
