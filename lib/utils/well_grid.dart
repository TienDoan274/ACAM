/// Hoàn thiện lưới 16x24 -> ĐÚNG 384 well từ detection của Stage 2.
///
/// Port 1-1 của `acam/grid.py` (Python) — cùng thuật toán, cùng thứ tự xử lý hoà, để app và
/// code eval cho cùng kết quả (kiểm bằng test/well_grid_test.dart với fixtures sinh từ Python).
///   1. Lưới ban đầu từ template (4 well góc trong khung plate đã warp) + căn thô: chỉnh tỉ lệ
///      theo pitch thật của detection, căn pha lưới bằng detection gần tâm (bù lệch < 1 ô do sai số Stage 1).
///      Rồi ghép lan từ tâm ([WellGrid.growFromCenter]): plate warp xiên / méo phối cảnh vẫn khớp đúng tới mép.
///   2. Lặp: ghép detection <-> nút lưới (greedy, gate theo pitch), fit lại (vòng đầu affine,
///      sau đó homography) bằng least squares.
///   3. Thử dịch cả lưới ±1 hàng/cột, giữ phương án ghép được nhiều nhất.
///   4. 384 box: box YOLO nếu khớp và gần nút; lệch > snapTol pitch -> vị trí nút lưới;
///      nút không có detection -> nội suy từ lưới. Detection thừa (FP) bị loại.
/// Không đánh index A1..P24 — app chỉ cần đủ 384 well.
///
/// Chế độ tay (khi tự động sai): 3 box ①②③ + số well mỗi chiều -> [WellGrid.anchorHomography].
/// 16x24: H ban đầu cho [WellGrid.complete] (lai với YOLO, [WellGrid.fromAnchorsRefined]);
/// kích thước khác / tắt YOLO: [WellGrid.fromAnchors] (thuần hình học, rows x cols bất kỳ).
library well_grid;

import 'dart:math' as math;

/// Một detection (toạ độ trên canvas plate đã warp).
class Det {
  final double x1, y1, x2, y2, conf;
  const Det(this.x1, this.y1, this.x2, this.y2, this.conf);
  double get cx => (x1 + x2) / 2;
  double get cy => (y1 + y2) / 2;
}

class GridResult {
  final List<List<double>> boxes; // rows*cols x [x1,y1,x2,y2], thứ tự lưới (hàng trước)
  final List<double> conf; // conf YOLO, 0 nếu nội suy
  final List<bool> detected; // có detection ghép vào nút
  final List<bool> snapped; // có detection nhưng lệch -> dùng vị trí lưới
  final List<int> detIndex; // chỉ số detection gốc, -1 nếu nội suy
  final double pitch;
  final int nDet;
  final List<int> shift; // [dc, dr]
  final int rows, cols; // 16x24; khác chỉ khi sinh tay (fromAnchors)

  GridResult(this.boxes, this.conf, this.detected, this.snapped, this.detIndex, this.pitch, this.nDet, this.shift,
      {required this.rows, required this.cols});

  int get nInterpolated => detected.where((d) => !d).length;
  int get nSnapped => snapped.where((s) => s).length;
  int get nDropped => nDet - detected.where((d) => d).length;
}

class GridParamsDyn {
  final int rows, cols;
  final List<List<double>> templateCornersUv; // A1, A24, P24, P1
  final double margin;
  final List<double> gates;
  final double snapTol;
  final double minConf;
  final double scaleMin, scaleMax;
  final int maxRefine;
  final double phaseRadius; // căn pha: chỉ detection trong bán kính này (ô) quanh tâm lưới, nếu đủ 16
  final List<double> growRadii; // ghép lan từ tâm: bán kính (ô) các vòng
  final double growHomographyFrom; // từ bán kính này fit homography (nhỏ hơn: affine)
  const GridParamsDyn({
    required this.rows,
    required this.cols,
    required this.templateCornersUv,
    required this.margin,
    required this.gates,
    required this.snapTol,
    this.minConf = 0.25,
    this.scaleMin = 0.8,
    this.scaleMax = 1.25,
    this.maxRefine = 8,
    this.phaseRadius = double.infinity,
    this.growRadii = const [],
    this.growHomographyFrom = double.infinity,
  });
}

// ─────────────────────────────────────────────
// Đại số tuyến tính nhỏ
// ─────────────────────────────────────────────
typedef Mat3 = List<double>; // 9 phần tử, hàng trước

List<double> _solve(List<List<double>> A, List<double> b) {
  final n = b.length;
  final m = [for (var i = 0; i < n; i++) [...A[i], b[i]]];
  for (var col = 0; col < n; col++) {
    var piv = col;
    for (var r = col + 1; r < n; r++) {
      if (m[r][col].abs() > m[piv][col].abs()) piv = r;
    }
    final t = m[piv];
    m[piv] = m[col];
    m[col] = t;
    final d = m[col][col];
    if (d.abs() < 1e-300) continue;
    for (var r = 0; r < n; r++) {
      if (r == col) continue;
      final f = m[r][col] / d;
      if (f == 0) continue;
      for (var c = col; c <= n; c++) {
        m[r][c] -= f * m[col][c];
      }
    }
  }
  return [for (var i = 0; i < n; i++) m[i][n] / m[i][i]];
}

/// Nghiệm least squares của A x = b qua phương trình chuẩn (AᵀA) x = Aᵀb.
List<double> _lstsq(List<List<double>> A, List<double> b) {
  final k = A[0].length;
  final ata = List.generate(k, (_) => List.filled(k, 0.0));
  final atb = List.filled(k, 0.0);
  for (var r = 0; r < A.length; r++) {
    final row = A[r];
    for (var i = 0; i < k; i++) {
      atb[i] += row[i] * b[r];
      for (var j = 0; j < k; j++) {
        ata[i][j] += row[i] * row[j];
      }
    }
  }
  return _solve(ata, atb);
}

Mat3 _mul(Mat3 a, Mat3 b) => [
      for (var i = 0; i < 3; i++)
        for (var j = 0; j < 3; j++) a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
    ];

Mat3 _inv(Mat3 m) {
  final a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  final k = 1.0 / det;
  return [
    (e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k,
    (f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k,
    (d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k,
  ];
}

List<double> applyH(Mat3 H, double x, double y) {
  final w = H[6] * x + H[7] * y + H[8];
  return [(H[0] * x + H[1] * y + H[2]) / w, (H[3] * x + H[4] * y + H[5]) / w];
}

(List<List<double>>, Mat3) _normalize(List<List<double>> p) {
  var mx = 0.0, my = 0.0;
  for (final q in p) {
    mx += q[0];
    my += q[1];
  }
  mx /= p.length;
  my /= p.length;
  var d = 0.0;
  for (final q in p) {
    d += math.sqrt((q[0] - mx) * (q[0] - mx) + (q[1] - my) * (q[1] - my));
  }
  d /= p.length;
  final s = math.sqrt2 / math.max(d, 1e-12);
  return ([for (final q in p) [(q[0] - mx) * s, (q[1] - my) * s]], [s, 0, -s * mx, 0, s, -s * my, 0, 0, 1]);
}

/// Homography least squares (h33 = 1, chuẩn hoá Hartley): dst ≈ H·src.
Mat3 fitHomography(List<List<double>> src, List<List<double>> dst) {
  final (s, ts) = _normalize(src);
  final (d, td) = _normalize(dst);
  final A = <List<double>>[];
  final b = <double>[];
  for (var i = 0; i < s.length; i++) {
    final x = s[i][0], y = s[i][1], u = d[i][0], v = d[i][1];
    A.add([x, y, 1, 0, 0, 0, -u * x, -u * y]);
    b.add(u);
    A.add([0, 0, 0, x, y, 1, -v * x, -v * y]);
    b.add(v);
  }
  final h = _lstsq(A, b);
  final hn = [...h, 1.0];
  final H = _mul(_mul(_inv(td), hn), ts);
  return [for (final v in H) v / H[8]];
}

/// Affine least squares (6 ẩn): dst ≈ A·src.
Mat3 fitAffine(List<List<double>> src, List<List<double>> dst) {
  final X = [for (final p in src) [p[0], p[1], 1.0]];
  final px = _lstsq(X, [for (final q in dst) q[0]]);
  final py = _lstsq(X, [for (final q in dst) q[1]]);
  return [px[0], px[1], px[2], py[0], py[1], py[2], 0, 0, 1];
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

// ─────────────────────────────────────────────
// Lưới
// ─────────────────────────────────────────────
class WellGrid {
  final GridParamsDyn p;
  late final List<List<double>> lattice; // (c, r) theo idx hàng trước
  late final List<List<double>> cornerLattice;
  late final List<double> centerDist; // khoảng cách (ô) từ mỗi nút tới tâm lưới

  double get _cx => (p.cols - 1) / 2;
  double get _cy => (p.rows - 1) / 2;

  WellGrid(this.p) {
    lattice = [
      for (var r = 0; r < p.rows; r++)
        for (var c = 0; c < p.cols; c++) [c.toDouble(), r.toDouble()]
    ];
    centerDist = [
      for (final l in lattice) math.sqrt((l[0] - _cx) * (l[0] - _cx) + (l[1] - _cy) * (l[1] - _cy))
    ];
    cornerLattice = [
      [0, 0],
      [p.cols - 1.0, 0],
      [p.cols - 1.0, p.rows - 1.0],
      [0, p.rows - 1.0],
    ];
  }

  List<List<double>> nodes(Mat3 H, [double dc = 0, double dr = 0]) =>
      [for (final l in lattice) applyH(H, l[0] + dc, l[1] + dr)];

  double pitch(List<List<double>> nodes) {
    var sx = 0.0, sy = 0.0;
    var nx = 0, ny = 0;
    for (var r = 0; r < p.rows; r++) {
      for (var c = 0; c < p.cols; c++) {
        final a = nodes[r * p.cols + c];
        if (c + 1 < p.cols) {
          final b = nodes[r * p.cols + c + 1];
          sx += math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
          nx++;
        }
        if (r + 1 < p.rows) {
          final b = nodes[(r + 1) * p.cols + c];
          sy += math.sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
          ny++;
        }
      }
    }
    return (sx / nx + sy / ny) / 2;
  }

  /// Ghép 1-1 nút <-> detection: cặp gần nhất trước (hoà: nút nhỏ hơn, rồi detection nhỏ hơn).
  (List<int>, List<int>) matchGreedy(List<List<double>> nodes, List<List<double>> centers, double gate) {
    final pairs = <(double, int, int)>[];
    for (var i = 0; i < nodes.length; i++) {
      for (var j = 0; j < centers.length; j++) {
        final dx = nodes[i][0] - centers[j][0], dy = nodes[i][1] - centers[j][1];
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < gate) pairs.add((d, i, j));
      }
    }
    pairs.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      if (c != 0) return c;
      final c2 = a.$2.compareTo(b.$2);
      return c2 != 0 ? c2 : a.$3.compareTo(b.$3);
    });
    final usedN = List.filled(nodes.length, false);
    final usedD = List.filled(centers.length, false);
    final ni = <int>[], dj = <int>[];
    for (final (_, i, j) in pairs) {
      if (!usedN[i] && !usedD[j]) {
        usedN[i] = usedD[j] = true;
        ni.add(i);
        dj.add(j);
      }
    }
    return (ni, dj);
  }

  Mat3 initialHomography(double imgW, double imgH) {
    final pw = imgW / (1 + 2 * p.margin), ph = imgH / (1 + 2 * p.margin);
    final padX = pw * p.margin, padY = ph * p.margin;
    final dst = [
      for (final uv in p.templateCornersUv)
        imgW >= imgH ? [padX + uv[0] * pw, padY + uv[1] * ph] : [padX + uv[1] * pw, padY + uv[0] * ph]
    ];
    return fitHomography(cornerLattice, dst);
  }

  Mat3 _latticeOp(Mat3 H, {double scale = 1.0, double sx = 0, double sy = 0}) {
    final cx = (p.cols - 1) / 2, cy = (p.rows - 1) / 2;
    return _mul(H, [scale, 0, cx - scale * cx + sx, 0, scale, cy - scale * cy + sy, 0, 0, 1]);
  }

  Mat3 coarseAlign(Mat3 H, List<List<double>> centers, List<double> conf) {
    final n = centers.length;
    if (n < 16) return H;
    final nn = <double>[];
    for (var i = 0; i < n; i++) {
      var best = double.infinity;
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final dx = centers[i][0] - centers[j][0], dy = centers[i][1] - centers[j][1];
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < best) best = d;
      }
      nn.add(best);
    }
    final s = (_median(nn) / pitch(nodes(H))).clamp(p.scaleMin, p.scaleMax);
    H = _latticeOp(H, scale: s);
    final strong = [for (var i = 0; i < n; i++) if (conf[i] >= p.minConf) centers[i]];
    final use = strong.length < 50 ? centers : strong;
    final Hi = _inv(H);
    final us = [for (final c in use) applyH(Hi, c[0], c[1])];
    bool inside(List<double> u) => u[0] > -1 && u[0] < p.cols && u[1] > -1 && u[1] < p.rows;
    bool near(List<double> u) =>
        math.sqrt((u[0] - _cx) * (u[0] - _cx) + (u[1] - _cy) * (u[1] - _cy)) <= p.phaseRadius;
    // Pha chỉ từ detection gần tâm lưới (nếu đủ 16): plate xiên / phối cảnh -> pha đổi dần ra mép
    final nIn = us.where(inside).length;
    final useNear = nIn >= 16 && us.where((u) => inside(u) && near(u)).length >= 16;
    var sinX = 0.0, cosX = 0.0, sinY = 0.0, cosY = 0.0;
    var k = 0;
    for (final u in us) {
      if (inside(u) && (!useNear || near(u))) {
        final ax = 2 * math.pi * (u[0] - u[0].roundToDouble());
        final ay = 2 * math.pi * (u[1] - u[1].roundToDouble());
        sinX += math.sin(ax);
        cosX += math.cos(ax);
        sinY += math.sin(ay);
        cosY += math.cos(ay);
        k++;
      }
    }
    if (k < 16) return H;
    return _latticeOp(H, sx: math.atan2(sinX / k, cosX / k) / (2 * math.pi), sy: math.atan2(sinY / k, cosY / k) / (2 * math.pi));
  }

  (List<List<double>>, List<int>, List<int>) _matchOn(Mat3 H, List<List<double>> centers, double gateK,
      [double dc = 0, double dr = 0]) {
    final nd = nodes(H, dc, dr);
    final (ni, dj) = matchGreedy(nd, centers, gateK * pitch(nd));
    return (nd, ni, dj);
  }

  /// Ghép lan từ tâm: mỗi vòng chỉ ghép nút lưới trong bán kính rad (ô) quanh tâm rồi fit lại (affine; từ
  /// p.growHomographyFrom: homography). Template sai ít nhất ở tâm, sai dần ra mép -> tránh khớp nhầm well bên
  /// cạnh ở mép (lưới hội tụ lệch 1 cột ở một đầu plate).
  Mat3 growFromCenter(Mat3 H, List<List<double>> centers, double gate) {
    for (final rad in p.growRadii) {
      final sel = [for (var i = 0; i < lattice.length; i++) if (centerDist[i] <= rad) i];
      final full = nodes(H);
      final (ni, dj) = matchGreedy([for (final i in sel) full[i]], centers, gate * pitch(full));
      final homog = rad >= p.growHomographyFrom;
      if (ni.length >= (homog ? 12 : 8)) {
        final src = [for (final i in ni) lattice[sel[i]]];
        final dst = [for (final j in dj) centers[j]];
        H = homog ? fitHomography(src, dst) : fitAffine(src, dst);
      }
    }
    return H;
  }

  /// [initH]: lưới ban đầu có sẵn (chế độ tay: [anchorHomography]) -> bỏ template + căn thô + lan từ tâm.
  /// [fallbackWh]: [w, h] box khi không ghép được detection nào (mặc định 0.8 pitch).
  GridResult complete(List<Det> dets, double imgW, double imgH, {Mat3? initH, List<double>? fallbackWh}) {
    final centers = [for (final d in dets) [d.cx, d.cy]];
    final conf = [for (final d in dets) d.conf];
    var H = initH ?? growFromCenter(coarseAlign(initialHomography(imgW, imgH), centers, conf), centers, p.gates.first);

    for (var k = 0; k < p.gates.length; k++) {
      final (_, ni, dj) = _matchOn(H, centers, p.gates[k]);
      if (ni.length >= 8) {
        final src = [for (final i in ni) lattice[i]];
        final dst = [for (final j in dj) centers[j]];
        H = k == 0 ? fitAffine(src, dst) : fitHomography(src, dst);
      }
    }
    // Lặp tiếp ở gate cuối tới khi số cặp ghép không tăng (lưới ban đầu méo khi góc Stage 1 lệch nhiều)
    var prev = -1;
    for (var it = 0; it < p.maxRefine; it++) {
      final (_, ni, dj) = _matchOn(H, centers, p.gates.last);
      if (ni.length <= prev || ni.length < 8) break;
      prev = ni.length;
      H = fitHomography([for (final i in ni) lattice[i]], [for (final j in dj) centers[j]]);
    }

    var best = -1;
    var bestShift = [0, 0];
    for (final dr in const [0, -1, 1]) {
      for (final dc in const [0, -1, 1]) {
        final (_, ni, _) = _matchOn(H, centers, p.gates.last, dc.toDouble(), dr.toDouble());
        if (ni.length > best) {
          best = ni.length;
          bestShift = [dc, dr];
        }
      }
    }
    if (bestShift[0] != 0 || bestShift[1] != 0) {
      H = _mul(H, [1, 0, bestShift[0].toDouble(), 0, 1, bestShift[1].toDouble(), 0, 0, 1]);
      final (_, ni, dj) = _matchOn(H, centers, p.gates.last);
      if (ni.length >= 8) {
        H = fitHomography([for (final i in ni) lattice[i]], [for (final j in dj) centers[j]]);
      }
    }

    final (nd, ni, dj) = _matchOn(H, centers, p.gates.last);
    final pt = pitch(nd);
    double bw, bh;
    if (dj.isNotEmpty) {
      bw = _median([for (final j in dj) dets[j].x2 - dets[j].x1]);
      bh = _median([for (final j in dj) dets[j].y2 - dets[j].y1]);
    } else if (fallbackWh != null) {
      bw = fallbackWh[0];
      bh = fallbackWh[1];
    } else {
      bw = bh = 0.8 * pt;
    }
    final n = lattice.length;
    final boxes = [for (final q in nd) [q[0] - bw / 2, q[1] - bh / 2, q[0] + bw / 2, q[1] + bh / 2]];
    final cf = List.filled(n, 0.0);
    final detected = List.filled(n, false);
    final snapped = List.filled(n, false);
    final detIndex = List.filled(n, -1);
    for (var k = 0; k < ni.length; k++) {
      final i = ni[k], j = dj[k];
      final d = dets[j];
      final dx = d.cx - nd[i][0], dy = d.cy - nd[i][1];
      if (math.sqrt(dx * dx + dy * dy) < p.snapTol * pt) {
        boxes[i] = [d.x1, d.y1, d.x2, d.y2];
      } else {
        snapped[i] = true;
      }
      cf[i] = d.conf;
      detected[i] = true;
      detIndex[i] = j;
    }
    return GridResult(boxes, cf, detected, snapped, detIndex, pt, dets.length, bestShift, rows: p.rows, cols: p.cols);
  }

  // ─────────────────────────────────────────────
  // Chế độ tay: 3 box ① đầu-trái, ② đầu-phải cùng hàng, ③ cuối-trái cùng cột + số well mỗi chiều
  // ─────────────────────────────────────────────
  /// Số well nhập tay đúng lưới cấu hình (hướng nào cũng được) -> tinh chỉnh được bằng YOLO.
  bool isHybridCounts(int n12, int n13) => (n12 == p.cols && n13 == p.rows) || (n12 == p.rows && n13 == p.cols);

  /// -> (H, cols, rows): affine dạng đóng lưới (c, r) -> px. n12 = số well ①→② (kể cả 2 đầu), n13 = ①→③.
  /// Trục c là trục có p.cols well: nếu (n12, n13) == (rows, cols) (plate dọc) thì c theo ①→③.
  (Mat3, int, int) anchorHomography(List<List<double>> anchors, int n12, int n13) {
    final (c, _) = anchorCentersWh(anchors);
    int cols, rows;
    List<double> ex, ey;
    if (n12 == p.rows && n13 == p.cols) {
      cols = n13;
      rows = n12;
      ex = [(c[2][0] - c[0][0]) / (cols - 1), (c[2][1] - c[0][1]) / (cols - 1)];
      ey = [(c[1][0] - c[0][0]) / (rows - 1), (c[1][1] - c[0][1]) / (rows - 1)];
    } else {
      cols = n12;
      rows = n13;
      ex = [(c[1][0] - c[0][0]) / (cols - 1), (c[1][1] - c[0][1]) / (cols - 1)];
      ey = [(c[2][0] - c[0][0]) / (rows - 1), (c[2][1] - c[0][1]) / (rows - 1)];
    }
    return ([ex[0], ey[0], c[0][0], ex[1], ey[1], c[0][1], 0, 0, 1], cols, rows);
  }

  /// Thuần hình học: rows x cols box đều nhau, kích thước = trung bình 3 box tay; detected = false.
  GridResult fromAnchors(List<List<double>> anchors, int n12, int n13) {
    final (H, cols, rows) = anchorHomography(anchors, n12, n13);
    final (_, wh) = anchorCentersWh(anchors);
    final bw = wh[0], bh = wh[1];
    final boxes = <List<double>>[];
    for (var r = 0; r < rows; r++) {
      for (var cc = 0; cc < cols; cc++) {
        final q = applyH(H, cc.toDouble(), r.toDouble());
        boxes.add([q[0] - bw / 2, q[1] - bh / 2, q[0] + bw / 2, q[1] + bh / 2]);
      }
    }
    final n = rows * cols;
    final pt = affinePitch(H);
    return GridResult(boxes, List.filled(n, 0.0), List.filled(n, false), List.filled(n, false), List.filled(n, -1), pt, 0,
        [0, 0],
        rows: rows, cols: cols);
  }

  /// Mỗi box tay -> box YOLO có tâm gần nhất nếu cách < gates[0] * pitch (sai số tay bị khuếch đại khi ngoại suy).
  List<List<double>> snapAnchors(List<List<double>> anchors, List<Det> dets, double pitch) {
    final out = [for (final a in anchors) [...a]];
    if (dets.isEmpty) return out;
    for (var k = 0; k < out.length; k++) {
      final cx = (out[k][0] + out[k][2]) / 2, cy = (out[k][1] + out[k][3]) / 2;
      var best = double.infinity;
      var bj = -1;
      for (var j = 0; j < dets.length; j++) {
        final dx = dets[j].cx - cx, dy = dets[j].cy - cy;
        final d = math.sqrt(dx * dx + dy * dy);
        if (d < best) {
          best = d;
          bj = j;
        }
      }
      if (best < p.gates.first * pitch) {
        final d = dets[bj];
        out[k] = [d.x1, d.y1, d.x2, d.y2];
      }
    }
    return out;
  }

  /// Lai: 3 box tay hút về YOLO -> lưới ban đầu -> ghép / fit / dịch ±1 / snap với YOLO như tự động.
  /// Chỉ khi [isHybridCounts].
  GridResult fromAnchorsRefined(List<Det> dets, double imgW, double imgH, List<List<double>> anchors, int n12, int n13) {
    final (H, _, _) = anchorHomography(anchors, n12, n13);
    final (H0, _, _) = anchorHomography(snapAnchors(anchors, dets, affinePitch(H)), n12, n13);
    final (_, wh) = anchorCentersWh(anchors);
    return complete(dets, imgW, imgH, initH: H0, fallbackWh: wh);
  }
}

/// Bước lưới (px) của H affine: trung bình độ dài 2 vector trục.
double affinePitch(Mat3 H) => (math.sqrt(H[0] * H[0] + H[3] * H[3]) + math.sqrt(H[1] * H[1] + H[4] * H[4])) / 2;

/// 3 box [x1,y1,x2,y2] -> (tâm, [w, h] trung bình).
(List<List<double>>, List<double>) anchorCentersWh(List<List<double>> anchors) {
  final c = [for (final b in anchors) [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]];
  var w = 0.0, h = 0.0;
  for (final b in anchors) {
    w += b[2] - b[0];
    h += b[3] - b[1];
  }
  return (c, [w / anchors.length, h / anchors.length]);
}
