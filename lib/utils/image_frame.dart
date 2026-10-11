/// Chuẩn hoá ảnh đầu vào từ mọi nguồn (máy ảnh 40+ MP, điện thoại, ảnh dọc, khung 4:3 / 16:9 / vuông) —
/// port của `acam/inference.py` (working_size, stage1_frame, border_median) ở repo cha.
///
/// - [workingSize]: ảnh có cạnh dài > max_image_side được thu nhỏ ngay sau khi decode ("ảnh làm việc"); mọi toạ
///   độ pipeline (góc Stage 1, Stage1Meta.imageSize, màn hình chỉnh góc) theo ảnh này.
/// - [stage1Frame] + [borderMedian]: Stage 1 chỉ train trên khung 3:2 ngang rồi resize 896x896 không giữ tỉ lệ ->
///   ảnh dọc xoay 90° cùng chiều kim đồng hồ, khung lệch 3:2 thêm nền (trung vị viền) trước khi resize.
/// Chỉ phụ thuộc kích thước ảnh / mảng byte -> kiểm bằng fixture Python (test/image_frame_test.dart).
library image_frame;

import 'dart:math' as math;
import 'dart:typed_data';

/// Làm tròn .5 lên — như `round_half_up` của acam/geometry.py.
int _rhu(double x) => (x + 0.5).floor();

/// Kích thước ảnh làm việc: cạnh dài > [maxSide] -> thu về [maxSide]; không thì giữ nguyên.
(int, int) workingSize(int w, int h, int maxSide) {
  final m = math.max(w, h);
  if (m <= maxSide) return (w, h);
  final s = maxSide / m;
  return (_rhu(w * s), _rhu(h * s));
}

/// Hình học khung Stage 1. [t]: ma trận 3x3 (hàng trước) px khung -> px ảnh.
class Stage1Frame {
  final bool rotate; // xoay 90° cùng chiều kim đồng hồ (cv::ROTATE_90_CLOCKWISE)
  final int top, bottom, left, right; // nền thêm vào (sau khi xoay)
  final int canvasW, canvasH;
  final List<double> t;
  const Stage1Frame(this.rotate, this.top, this.bottom, this.left, this.right, this.canvasW, this.canvasH, this.t);

  bool get padded => top + bottom + left + right > 0;

  /// px khung -> px ảnh.
  (double, double) toImage(double x, double y) => (t[0] * x + t[1] * y + t[2], t[3] * x + t[4] * y + t[5]);
}

/// Như `acam.inference.stage1_frame`: ảnh dọc -> xoay; tỉ lệ lệch > [tol] so với [aspect] -> thêm nền 2 bên
/// (khung hẹp) hoặc trên / dưới (khung rộng), chia đều (phần lẻ về phải / dưới).
Stage1Frame stage1Frame(int w, int h, double aspect, double tol) {
  var t = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];
  final rotate = h > w;
  if (rotate) {
    // (x, y) -> (h-1-y, x); ngược lại x = y', y = h-1-x'
    t = [0, 1, 0, -1, 0, h - 1.0, 0, 0, 1];
    final tmp = w;
    w = h;
    h = tmp;
  }
  var top = 0, bottom = 0, left = 0, right = 0;
  final a = w / h;
  if ((a / aspect - 1).abs() > tol) {
    final int nw, nh;
    if (a < aspect) {
      nw = _rhu(h * aspect);
      nh = h;
    } else {
      nw = w;
      nh = _rhu(w / aspect);
    }
    left = (nw - w) ~/ 2;
    top = (nh - h) ~/ 2;
    right = nw - w - left;
    bottom = nh - h - top;
    // t · [[1,0,-left],[0,1,-top],[0,0,1]]
    t = [t[0], t[1], t[2] - t[0] * left - t[1] * top, t[3], t[4], t[5] - t[3] * left - t[4] * top, 0, 0, 1];
    w = nw;
    h = nh;
  }
  return Stage1Frame(rotate, top, bottom, left, right, w, h, t);
}

/// Như `acam.inference.border_median`: trung vị dưới các pixel trong viền rộng b = round(frac * cạnh ngắn) px
/// của ảnh gray [gray] (w x h, hàng trước, liên tục).
int borderMedian(Uint8List gray, int w, int h, double frac) {
  final b = math.max(1, math.min(_rhu(frac * math.min(w, h)), math.min(w, h) ~/ 2));
  final hist = List<int>.filled(256, 0);
  var n = 0;
  void add(int y0, int y1, int x0, int x1) {
    for (var y = y0; y < y1; y++) {
      final row = y * w;
      for (var x = x0; x < x1; x++) {
        hist[gray[row + x]]++;
      }
    }
    n += math.max(0, y1 - y0) * math.max(0, x1 - x0);
  }

  add(0, b, 0, w);
  add(h - b, h, 0, w);
  add(b, h - b, 0, b);
  add(b, h - b, w - b, w);
  final k = (n + 1) ~/ 2;
  var cum = 0;
  for (var v = 0; v < 256; v++) {
    cum += hist[v];
    if (cum >= k) return v;
  }
  return 255;
}

/// Như `acam.inference.contrast_stretch`: kéo giãn tuyến tính percentile [lo]..[hi] % của ảnh gray về 0..255.
/// Percentile theo histogram (giá trị nhỏ nhất có tần suất tích luỹ >= n*p/100), LUT số nguyên làm tròn .5 lên
/// -> giống hệt bit Python. Trả về chính [gray] khi ảnh phẳng (hi <= lo).
Uint8List contrastStretch(Uint8List gray, double lo, double hi) {
  final hist = List<int>.filled(256, 0);
  for (final v in gray) {
    hist[v]++;
  }
  final cum = List<int>.filled(256, 0);
  var c = 0;
  for (var v = 0; v < 256; v++) {
    c += hist[v];
    cum[v] = c;
  }
  int pct(double p) {
    final t = c * p / 100.0;
    for (var v = 0; v < 256; v++) {
      if (cum[v] >= t) return v;
    }
    return 255;
  }

  final a = pct(lo), b = pct(hi);
  if (b <= a) return gray;
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    final x = (v - a) * 510 + (b - a);
    lut[v] = x <= 0 ? 0 : math.min(255, x ~/ (2 * (b - a)));
  }
  final out = Uint8List(gray.length);
  for (var i = 0; i < gray.length; i++) {
    out[i] = lut[gray[i]];
  }
  return out;
}

/// Như `acam.models.stage3.plate_gain`: chuẩn hoá độ sáng theo plate trước Stage 3. [sums] = tổng gray uint8 của
/// từng crop, [pixels] = số pixel mỗi crop. Trung vị độ sáng crop < [ref] (ảnh tối) -> ref / trung vị, kẹp
/// [1, gmax]; ảnh bình thường -> 1. ref <= 0: tắt. Tổng nguyên / số pixel -> trung vị giống hệt Python.
double plateGain(List<int> sums, int pixels, double ref, double gmax) {
  if (ref <= 0 || sums.isEmpty) return 1.0;
  final m = [for (final s in sums) s / pixels]..sort();
  final n = m.length;
  final med = n.isOdd ? m[n ~/ 2] : (m[n ~/ 2 - 1] + m[n ~/ 2]) / 2;
  if (med <= 0) return gmax;
  return math.min(math.max(ref / med, 1.0), gmax);
}

/// Như `acam.models.stage3.gain_lut`: LUT nhân độ sáng v -> min(255, floor(v * gain + 0.5)).
Uint8List gainLut(double gain) {
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = math.min(255, (v * gain + 0.5).floor());
  }
  return lut;
}
