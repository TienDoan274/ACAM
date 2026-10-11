/// Xem kết quả Stage 2 phóng to: plate đã warp + box vẽ vector (nét giữ nguyên độ dày khi zoom), tô màu
/// theo nguồn box (model / nội suy từ lưới / dời về lưới / từ 3 box tay).
///
/// Panel: số box từng loại, đổi màu + độ dày nét (lưu [Stage2Style]; màn hình workspace vẽ lại ảnh preview
/// trong card theo màu mới khi quay về), ẩn / hiện từng loại để soát riêng (vd. chỉ các ô nội suy).
/// Ảnh hiển thị là bản ≤2048 px (prepareEditImage): ảnh >4096 px vượt giới hạn texture GLES trên máy test.
library stage2_viewer_screen;

import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/stage2_style.dart';
import '../widgets/plate_edit_canvas.dart' show EditImage;

class Stage2ViewerScreen extends StatefulWidget {
  final EditImage image; // plate đã warp
  final List<Map<String, dynamic>> boxes; // px ảnh warp gốc
  final bool manualGeom;
  final String title;
  final String? summary;

  const Stage2ViewerScreen({
    super.key,
    required this.image,
    required this.boxes,
    required this.manualGeom,
    required this.title,
    this.summary,
  });

  @override
  State<Stage2ViewerScreen> createState() => _Stage2ViewerScreenState();
}

class _Stage2ViewerScreenState extends State<Stage2ViewerScreen> {
  final _tc = TransformationController();
  Stage2Style _style = Stage2Style.standard;
  final Set<String> _hidden = {};
  bool _panel = true;

  late final List<String> _kinds = [for (final b in widget.boxes) Stage2Style.kindOf(b, manualGeom: widget.manualGeom)];
  late final Map<String, int> _counts = {
    for (final k in Stage2Style.kinds) k: _kinds.where((x) => x == k).length,
  };

  @override
  void initState() {
    super.initState();
    Stage2Style.load().then((s) {
      if (mounted) setState(() => _style = s);
    });
  }

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _update(Stage2Style s) {
    setState(() => _style = s);
    s.save();
  }

  Widget _swatch(int argb, {required bool selected, double size = 22, VoidCallback? onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Color(argb),
            shape: BoxShape.circle,
            border: Border.all(color: selected ? Colors.blue : Colors.grey, width: selected ? 3 : 1),
          ),
        ),
      );

  /// 1 loại box: ô tick ẩn/hiện + tên + số lượng, bên dưới là dải màu luôn hiện (chạm 1 màu = đổi ngay).
  Widget _kindRow(String k) {
    final visible = !_hidden.contains(k);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 32,
            height: 32,
            child: Checkbox(
              value: visible,
              onChanged: (v) => setState(() => v == true ? _hidden.remove(k) : _hidden.add(k)),
            ),
          ),
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(border: Border.all(color: Color(_style.color(k)), width: 3)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${Stage2Style.labels[k]} (${_counts[k]})',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ]),
        SizedBox(
          height: 30,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final c in Stage2Style.palette)
              Padding(
                padding: const EdgeInsets.only(right: 5, top: 2, bottom: 2),
                child:
                    _swatch(c, selected: c == _style.color(k), size: 24, onTap: () => _update(_style.withColor(k, c))),
              ),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final im = widget.image;
    final insets = MediaQuery.of(context).systemGestureInsets;
    final shown = widget.manualGeom ? const ['manual'] : const ['detected', 'filled', 'moved'];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        toolbarHeight: 44,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            onPressed: () => setState(() => _panel = !_panel),
            icon: const Icon(Icons.palette_outlined, size: 18),
            label: Text(_panel ? 'Hide panel' : 'Box colors'),
          ),
        ],
      ),
      body: Row(children: [
        Expanded(
          child: InteractiveViewer(
            transformationController: _tc,
            minScale: 1,
            maxScale: 12,
            child: Center(
              child: AspectRatio(
                aspectRatio: im.dispW / im.dispH,
                child: Stack(fit: StackFit.expand, children: [
                  Image.file(File(im.path), fit: BoxFit.fill, filterQuality: FilterQuality.medium),
                  CustomPaint(
                    painter: _BoxesPainter(widget.boxes, _kinds, _style, Set.of(_hidden), _tc, im.srcW, im.srcH),
                  ),
                ]),
              ),
            ),
          ),
        ),
        if (_panel)
          Container(
            width: 230,
            color: Theme.of(context).colorScheme.surface,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.1,
              child: ListView(
                padding: EdgeInsets.fromLTRB(10, 10, 10 + insets.right, 10),
                children: [
                  const Text('Box colors', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  if (widget.summary != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(widget.summary!, style: TextStyle(fontSize: 11, color: Colors.grey[700])),
                    ),
                  const SizedBox(height: 6),
                  for (final k in shown) _kindRow(k),
                  const Divider(height: 16),
                  const Text('Line width', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, children: [
                    for (final e in Stage2Style.widths.entries)
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(e.key, style: const TextStyle(fontSize: 11)),
                        selected: _style.lineWidth == e.value,
                        onSelected: (_) => _update(_style.withLineWidth(e.value)),
                      ),
                  ]),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => _update(Stage2Style.standard),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('Default colors', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                  Text(
                    'Tap a colour to recolour that kind of box (swipe the colour strip for more); untick to hide them. '
                    'Colours are saved and also used for the Stage 2 preview. Pinch to zoom.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
      ]),
    );
  }
}

class _BoxesPainter extends CustomPainter {
  final List<Map<String, dynamic>> boxes;
  final List<String> kinds;
  final Stage2Style style;
  final Set<String> hidden;
  final TransformationController tc;
  final int srcW, srcH;

  _BoxesPainter(this.boxes, this.kinds, this.style, this.hidden, this.tc, this.srcW, this.srcH) : super(repaint: tc);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / srcW, sy = size.height / srcH;
    // Nét tính theo px màn hình: chia cho mức zoom để không dày lên khi phóng to
    final zoom = tc.value.getMaxScaleOnAxis();
    final paints = {
      for (final k in Stage2Style.kinds)
        k: Paint()
          ..color = Color(style.color(k))
          ..style = PaintingStyle.stroke
          ..strokeWidth = style.lineWidth / zoom,
    };
    for (var i = 0; i < boxes.length; i++) {
      final k = kinds[i];
      if (hidden.contains(k)) continue;
      final b = boxes[i];
      canvas.drawRect(
          Rect.fromLTRB((b['x1'] as num) * sx, (b['y1'] as num) * sy, (b['x2'] as num) * sx, (b['y2'] as num) * sy),
          paints[k]!);
    }
  }

  @override
  bool shouldRepaint(covariant _BoxesPainter old) => true;
}
