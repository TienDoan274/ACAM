/// Canvas chỉnh tay dùng chung cho màn hình chỉnh góc plate (Stage 1) và vẽ 3 box well (Stage 2).
///
/// - Ảnh hiển thị là bản JPEG ≤2048 px ([prepareEditImage]) — ảnh >4096 px vượt giới hạn texture
///   GLES và làm treo raster thread trên máy test. Mọi toạ độ vào/ra đều là px ảnh NGUỒN (full-res),
///   map theo tỉ lệ từng trục srcW/dispW, srcH/dispH.
/// - Hệ toạ độ = ảnh sau `img.decodeImage` (như pipeline): JPEG được xoay theo EXIF lúc decode và bỏ tag
///   orientation. Ảnh hiển thị được encode lại KHÔNG EXIF để Flutter không xoay thêm lần nữa. Kích thước
///   nguồn lấy từ ảnh đã decode (cache ở `.edit.json`), không đọc header: header JPEG là kích thước chưa
///   xoay, lệch với ảnh chụp dọc có EXIF xoay 90°.
/// - Cử chỉ tự xử lý bằng [Listener] (không InteractiveViewer / GestureDetector): 1 ngón = chỉnh sửa;
///   ngón thứ 2 chạm vào giữa chừng -> huỷ thao tác đang sửa ([onEditCancel], màn hình khôi phục
///   trạng thái trước đó) và chuyển sang zoom/pan tới khi nhấc hết tay. (ScaleGestureRecognizer kết thúc
///   rồi bắt đầu lại khi số ngón đổi, nên sẽ lỡ ghi một lần kéo handle khi user định zoom.)
library plate_edit_canvas;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../utils/image_frame.dart';

/// Ảnh để chỉnh tay: file JPEG hiển thị + kích thước ảnh nguồn (hệ toạ độ lưu trữ).
class EditImage {
  final String path;
  final int srcW, srcH;
  final int dispW, dispH;
  const EditImage(this.path, this.srcW, this.srcH, this.dispW, this.dispH);
}

/// Isolate job: `<nguồn>.edit.jpg` (cạnh dài ≤ maxDim, không EXIF) + `<nguồn>.edit.json` (kích thước
/// nguồn đã decode / kích thước hiển thị). Lần sau dùng lại cả hai, không decode lại ảnh gốc.
/// workMax (ảnh chụp): kích thước nguồn = kích thước ẢNH LÀM VIỆC của pipeline ([workingSize]: ảnh > max_image_side
/// được thu nhỏ sau khi decode) -> toạ độ góc chỉnh tay cùng hệ với Stage 1. null: ảnh warp / ảnh đã lưu (giữ nguyên).
Future<Map<String, Object?>> prepareEditImageJob(Map<String, Object?> a) async {
  final src = a['src'] as String, dst = a['dst'] as String, maxDim = a['maxDim'] as int;
  final workMax = a['workMax'] as int?;
  final metaFile = File('${dst.substring(0, dst.length - 4)}.json');
  try {
    final dstFile = File(dst);
    if (dstFile.existsSync() && metaFile.existsSync()) {
      final m = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      if (m['maxDim'] == maxDim && m['workMax'] == workMax) return {'path': dst, ...m};
    }
    final im = img.decodeImage(await File(src).readAsBytes()); // JPEG: đã xoay theo EXIF
    if (im == null) return {'path': null};
    final s = math.min(1.0, maxDim / math.max(im.width, im.height));
    final out = s < 1.0
        ? img.copyResize(im,
            width: (im.width * s).round(), height: (im.height * s).round(), interpolation: img.Interpolation.average)
        : img.Image.from(im);
    out.exif = img.ExifData(); // pixel đã đúng hướng -> không để Flutter xoay thêm theo EXIF
    await dstFile.writeAsBytes(Uint8List.fromList(img.encodeJpg(out, quality: 90)));
    final (sw, sh) = workMax == null ? (im.width, im.height) : workingSize(im.width, im.height, workMax);
    final m = {'srcW': sw, 'srcH': sh, 'dispW': out.width, 'dispH': out.height, 'maxDim': maxDim, 'workMax': workMax};
    await metaFile.writeAsString(jsonEncode(m));
    return {'path': dst, ...m};
  } catch (_) {
    return {'path': null};
  }
}

/// Tạo (hoặc dùng lại) ảnh chỉnh tay cạnh file nguồn. null nếu không đọc được ảnh.
/// [workMax]: ảnh chụp gốc -> PipelineConfig.maxImageSide (toạ độ theo ảnh làm việc của pipeline).
Future<EditImage?> prepareEditImage(String src, {int maxDim = 2048, int? workMax}) async {
  final dot = src.lastIndexOf('.');
  final dst = '${dot == -1 ? src : src.substring(0, dot)}.edit.jpg';
  final r = await compute(prepareEditImageJob, {'src': src, 'dst': dst, 'maxDim': maxDim, 'workMax': workMax});
  if (r['path'] == null) return null;
  return EditImage(r['path'] as String, r['srcW'] as int, r['srcH'] as int, r['dispW'] as int, r['dispH'] as int);
}

/// Phép chiếu px ảnh nguồn -> px màn hình của canvas: screen = offset + src * scale.
class PlateView {
  final double scale;
  final Offset offset;
  const PlateView(this.scale, this.offset);
  Offset toScreen(Offset src) => offset + src * scale;
  Offset toSrc(Offset screen) => (screen - offset) / scale;
}

typedef OverlayPaint = void Function(Canvas canvas, PlateView view);

/// `fit()`: đưa ảnh về vừa khung; `focus()`: phóng tới 1 vùng (cả hai có hiệu ứng); [zoomed]: true khi
/// ảnh không ở khung vừa ảnh (màn hình chỉ hiện nút "Show whole ..." lúc đó).
class PlateEditController {
  VoidCallback? _fit;
  void Function(Offset, double)? _focus;
  final ValueNotifier<bool> zoomed = ValueNotifier(false);
  void fit() => _fit?.call();

  /// [srcCenter] (px ảnh nguồn) vào giữa khung, [srcSpan] px nguồn vừa cạnh ngắn của khung.
  void focus(Offset srcCenter, double srcSpan) => _focus?.call(srcCenter, srcSpan);
}

class PlateEditCanvas extends StatefulWidget {
  final EditImage image;
  final OverlayPaint paintOverlay;
  final void Function(Offset src, PlateView view) onEditStart;
  final void Function(Offset src, PlateView view) onEditUpdate;
  final VoidCallback onEditEnd;
  final VoidCallback onEditCancel;

  /// Điểm (px nguồn) phóng to trong kính lúp, thường là handle đang kéo; null = ẩn kính lúp.
  final Offset? loupeAt;
  final PlateEditController? controller;

  const PlateEditCanvas({
    super.key,
    required this.image,
    required this.paintOverlay,
    required this.onEditStart,
    required this.onEditUpdate,
    required this.onEditEnd,
    required this.onEditCancel,
    this.loupeAt,
    this.controller,
  });

  @override
  State<PlateEditCanvas> createState() => _PlateEditCanvasState();
}

enum _Mode { idle, edit, transform }

class _PlateEditCanvasState extends State<PlateEditCanvas> with SingleTickerProviderStateMixin {
  static const double _loupeSize = 132, _loupeZoom = 3;

  Size? _size;
  double _fitScale = 1, _scale = 1;
  Offset _offset = Offset.zero;
  final Map<int, Offset> _pointers = {};
  _Mode _mode = _Mode.idle;
  Offset _lastEditPos = Offset.zero;

  // Mốc zoom/pan: scale + điểm nguồn dưới tâm các ngón + khoảng cách 2 ngón lúc bắt đầu
  double _s0 = 1, _span0 = 0;
  Offset _srcFocal0 = Offset.zero;

  PlateView get _view => PlateView(_scale, _offset);
  late final FileImage _provider = FileImage(File(widget.image.path));

  // Hiệu ứng fit / focus: nội suy scale + điểm nguồn ở giữa khung
  late final AnimationController _anim =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320))..addListener(_tick);
  double _aS0 = 1, _aS1 = 1;
  Offset _aC0 = Offset.zero, _aC1 = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.controller?._fit = () => _animateTo(_fitScale, _srcCenterOf(_fitScale, _fitOffset));
    widget.controller?._focus = (c, span) {
      final size = _size;
      if (size == null) return;
      final s = (math.min(size.width, size.height) / span).clamp(_fitScale, _fitScale * 16);
      _animateTo(s, c);
    };
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _fit() {
    final size = _size;
    if (size == null) return;
    final im = widget.image;
    _fitScale = math.min(size.width / im.srcW, size.height / im.srcH) * 0.96;
    _scale = _fitScale;
    _offset = Offset((size.width - im.srcW * _scale) / 2, (size.height - im.srcH * _scale) / 2);
    _fitOffset = _offset;
    // _fit có thể chạy trong build (đổi kích thước) -> báo cho listener sau frame, không trong build
    final c = widget.controller;
    if (c != null) WidgetsBinding.instance.addPostFrameCallback((_) => c.zoomed.value = false);
  }

  Offset _fitOffset = Offset.zero;

  Offset get _mid => Offset((_size?.width ?? 0) / 2, (_size?.height ?? 0) / 2);
  Offset _srcCenterOf(double scale, Offset offset) => (_mid - offset) / scale;

  void _animateTo(double scale, Offset srcCenter) {
    if (_size == null) return;
    _aS0 = _scale;
    _aC0 = _srcCenterOf(_scale, _offset);
    _aS1 = scale;
    _aC1 = srcCenter;
    _anim.forward(from: 0);
  }

  void _tick() {
    final t = Curves.easeInOut.transform(_anim.value);
    final s = lerpDouble(_aS0, _aS1, t)!;
    final c = Offset.lerp(_aC0, _aC1, t)!;
    setState(() {
      _scale = s;
      _offset = _mid - c * s;
    });
    _reportZoomed();
  }

  void _reportZoomed() =>
      widget.controller?.zoomed.value = (_scale - _fitScale).abs() > 1e-3 * _fitScale || (_offset - _fitOffset).distance > 2;

  (Offset, double) _focalSpan() {
    final pts = _pointers.values.take(2).toList();
    final focal = pts.length == 1 ? pts[0] : (pts[0] + pts[1]) / 2;
    return (focal, pts.length == 1 ? 0 : (pts[0] - pts[1]).distance);
  }

  void _startTransform() {
    final (focal, span) = _focalSpan();
    _s0 = _scale;
    _span0 = span;
    _srcFocal0 = _view.toSrc(focal);
  }

  void _updateTransform() {
    final (focal, span) = _focalSpan();
    final s = (_span0 > 0 && span > 0) ? (_s0 * span / _span0).clamp(_fitScale * 0.5, _fitScale * 16) : _s0;
    setState(() {
      _scale = s;
      _offset = focal - _srcFocal0 * s;
    });
    _reportZoomed();
  }

  void _down(PointerDownEvent e) {
    if (_anim.isAnimating) _anim.stop(); // user chạm -> dừng hiệu ứng, sửa trên khung hiện tại
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      _mode = _Mode.edit;
      _lastEditPos = e.localPosition;
      widget.onEditStart(_view.toSrc(e.localPosition), _view);
    } else {
      if (_mode == _Mode.edit) widget.onEditCancel();
      _mode = _Mode.transform;
      _startTransform();
    }
  }

  void _move(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_mode == _Mode.edit) {
      _lastEditPos = e.localPosition;
      widget.onEditUpdate(_view.toSrc(e.localPosition), _view);
    } else if (_mode == _Mode.transform) {
      _updateTransform();
    }
  }

  void _up(PointerEvent e) {
    if (_pointers.remove(e.pointer) == null) return;
    if (_pointers.isEmpty) {
      if (_mode == _Mode.edit) {
        if (e is PointerCancelEvent) {
          widget.onEditCancel();
        } else {
          widget.onEditEnd();
        }
      }
      _mode = _Mode.idle;
    } else if (_mode == _Mode.transform) {
      _startTransform(); // còn 1 ngón: tiếp tục pan từ vị trí hiện tại
    }
  }

  Widget _imageLayer(PlateView v) {
    final im = widget.image;
    return Positioned(
      left: 0,
      top: 0,
      width: im.dispW.toDouble(),
      height: im.dispH.toDouble(),
      child: Transform(
        transform: Matrix4.identity()
          ..translateByDouble(v.offset.dx, v.offset.dy, 0, 1)
          ..scaleByDouble(v.scale * im.srcW / im.dispW, v.scale * im.srcH / im.dispH, 1, 1),
        child: Image(image: _provider, fit: BoxFit.fill, filterQuality: FilterQuality.medium, gaplessPlayback: true),
      ),
    );
  }

  Widget _loupe(Size size, Offset src) {
    final finger = _lastEditPos;
    final left = finger.dx < size.width / 2 ? size.width - _loupeSize - 8 : 8.0;
    const center = Offset(_loupeSize / 2, _loupeSize / 2);
    final s = _scale * _loupeZoom;
    final v = PlateView(s, center - src * s);
    return Positioned(
      left: left,
      top: 8,
      width: _loupeSize,
      height: _loupeSize,
      child: IgnorePointer(
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)],
          ),
          child: ClipOval(
            child: ColoredBox(
              color: Colors.black,
              child: Stack(children: [
                _imageLayer(v),
                Positioned.fill(child: CustomPaint(painter: _OverlayPainter(v, widget.paintOverlay, crosshair: center))),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      if (_size != size) {
        _size = size;
        _fit();
      }
      final v = _view;
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: ClipRect(
          child: ColoredBox(
            color: const Color(0xFF202020),
            child: Stack(children: [
              _imageLayer(v),
              Positioned.fill(child: CustomPaint(painter: _OverlayPainter(v, widget.paintOverlay))),
              if (widget.loupeAt != null && _mode == _Mode.edit) _loupe(size, widget.loupeAt!),
            ]),
          ),
        ),
      );
    });
  }
}

class _OverlayPainter extends CustomPainter {
  final PlateView view;
  final OverlayPaint paintFn;
  final Offset? crosshair;
  _OverlayPainter(this.view, this.paintFn, {this.crosshair});

  @override
  void paint(Canvas canvas, Size size) {
    paintFn(canvas, view);
    final c = crosshair;
    if (c != null) {
      final p = Paint()
        ..color = Colors.white
        ..strokeWidth = 1;
      canvas.drawLine(c - const Offset(10, 0), c + const Offset(10, 0), p);
      canvas.drawLine(c - const Offset(0, 10), c + const Offset(0, 10), p);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
