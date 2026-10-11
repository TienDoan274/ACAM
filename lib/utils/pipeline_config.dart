/// Cấu hình pipeline đọc từ `assets/models/pipeline_config.json`.
///
/// File này do Python sinh ra (`pipelines/40_export_models.py`, nguồn: `acam/config.py`)
/// cùng lúc với 3 model ONNX, nên app và code train luôn dùng CÙNG hằng số tiền xử lý /
/// hậu xử lý. Không sửa tay các giá trị ở đây — sửa ở `acam/config.py` rồi export lại.
library pipeline_config;

import 'dart:convert';

import 'package:flutter/services.dart';

class PipelineConfig {
  // Lưới
  final int rows;
  final int cols;
  final List<List<double>> templateCornersUv; // A1, A24, P24, P1 trong khung plate đã warp
  final List<double> gatesPitch;
  final double snapTolPitch;
  final int maxRefine;
  final double coarseAlignMinConf;
  final double coarseScaleMin;
  final double coarseScaleMax;
  final double phaseRadius; // căn pha chỉ bằng detection gần tâm lưới (ô)
  final List<double> growRadii; // ghép lan từ tâm (ô)
  final double growHomographyFrom;

  // Class
  final List<String> classNames;
  final List<int> classColorsArgb;

  // Stage 1
  final String stage1Model;
  final int stage1Size;
  final double stage1Mean;
  final double stage1Std;
  // Khung Stage 1 (ảnh dọc xoay 90°, khung lệch 3:2 thêm nền) + giới hạn độ phân giải ảnh chụp
  final double stage1CanvasAspect, stage1AspectTol, stage1PadBorderFrac;
  final int maxImageSide;

  // Warp
  final double plateMargin;

  // Stage 2
  final String stage2Model;
  final int stage2Size;
  final int stage2Pad;
  final double stage2Conf;
  final double stage2Iou;
  final int stage2MaxDet;
  final double stage2RetryInterpFrac; // lưới nội suy > tỉ lệ này -> chạy lại YOLO trên ảnh kéo giãn tương phản
  final List<double> stage2RetryStretch; // percentile (lo, hi) % của lần chạy lại

  // Stage 3
  final String stage3Model;
  final String stage3Family; // 'cnn' | 'trees'
  final int stage3InCh; // cnn: 1 (gray) hoặc 3 (BGR)
  final String stage3FeatureSet; // trees
  final int stage3CropSize;
  final double stage3WellMargin;
  final double stage3PlateRefGray; // plate tối (trung vị gray crop < giá trị này) -> nhân độ sáng; 0 = tắt
  final double stage3PlateGainMax;
  final List<double> classProbWeights;

  // Kiểm tra chất lượng (cảnh báo nên chỉnh tay) — mục "quality"
  final double qcS1AspectMin, qcS1AspectMax;
  final double qcS1MinAreaFrac;
  final double qcS1AngleMin, qcS1AngleMax;
  final double qcS2MaxInterpFrac;
  final double qcS2MaxSnapFrac;
  final double qcS2MinPitchPx; // bước lưới (px ảnh warp) nhỏ hơn -> ảnh độ phân giải thấp, phân loại kém chính xác

  // Chế độ tay — mục "manual"
  final int manualMaxPerAxis;
  final double manualPitchRatioMin, manualPitchRatioMax;

  PipelineConfig._(Map<String, dynamic> j)
      : rows = j['grid']['rows'],
        cols = j['grid']['cols'],
        templateCornersUv = [
          for (final p in j['grid']['template_corners_uv'] as List)
            [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
        ],
        gatesPitch = [for (final g in j['grid']['gates_pitch'] as List) (g as num).toDouble()],
        snapTolPitch = (j['grid']['snap_tol_pitch'] as num).toDouble(),
        maxRefine = (j['grid']['max_refine'] as num?)?.toInt() ?? 8,
        coarseAlignMinConf = (j['grid']['coarse_align_min_conf'] as num).toDouble(),
        coarseScaleMin = (j['grid']['coarse_align_scale_clip'][0] as num).toDouble(),
        coarseScaleMax = (j['grid']['coarse_align_scale_clip'][1] as num).toDouble(),
        // Asset cũ (trước khi có ghép lan từ tâm): phaseRadius vô hạn + không lan = thuật toán cũ
        phaseRadius = (j['grid']['phase_radius'] as num?)?.toDouble() ?? double.infinity,
        growRadii = [for (final r in (j['grid']['grow_radii'] as List?) ?? const []) (r as num).toDouble()],
        growHomographyFrom = (j['grid']['grow_homography_from'] as num?)?.toDouble() ?? double.infinity,
        classNames = [for (final c in j['classes'] as List) c['name'] as String],
        classColorsArgb = [
          for (final c in j['classes'] as List)
            0xFF000000 | int.parse((c['color_rgb'] as String).substring(1), radix: 16)
        ],
        stage1Model = j['stage1']['model'],
        stage1Size = j['stage1']['img_size'],
        stage1Mean = (j['stage1']['normalize']['mean'] as num).toDouble(),
        stage1Std = (j['stage1']['normalize']['std'] as num).toDouble(),
        stage1CanvasAspect = _num(j, 'stage1', 'canvas_aspect', null, 1.5),
        stage1AspectTol = _num(j, 'stage1', 'aspect_tol', null, 0.03),
        stage1PadBorderFrac = _num(j, 'stage1', 'pad_border_frac', null, 0.02),
        maxImageSide = _num(j, 'input', 'max_image_side', null, 4800).toInt(),
        plateMargin = (j['warp']['plate_margin'] as num).toDouble(),
        stage2Model = j['stage2']['model'],
        stage2Size = j['stage2']['img_size'],
        stage2Pad = j['stage2']['letterbox_pad'],
        stage2Conf = (j['stage2']['conf'] as num).toDouble(),
        stage2Iou = (j['stage2']['nms_iou'] as num).toDouble(),
        stage2MaxDet = j['stage2']['max_det'],
        stage2RetryInterpFrac = _num(j, 'stage2', 'retry_interp_frac', null, 1.0),
        stage2RetryStretch = [_num(j, 'stage2', 'retry_stretch', 0, 1), _num(j, 'stage2', 'retry_stretch', 1, 99)],
        stage3Model = j['stage3']['model'],
        stage3Family = j['stage3']['family'],
        stage3InCh = (j['stage3']['in_ch'] as num?)?.toInt() ?? 1,
        stage3FeatureSet = (j['stage3']['feature_set'] as String?) ?? '',
        stage3CropSize = j['stage3']['crop_size'],
        stage3WellMargin = (j['stage3']['well_margin'] as num).toDouble(),
        stage3PlateRefGray = _num(j, 'stage3', 'plate_ref_gray', null, 0),
        stage3PlateGainMax = _num(j, 'stage3', 'plate_gain_max', null, 1),
        classProbWeights = [
          for (final w in (j['stage3']['class_prob_weights'] as List? ?? const [1, 1, 1])) (w as num).toDouble()
        ],
        // Asset cũ (version < 3) không có 2 mục dưới -> giá trị mặc định = acam/config.py
        qcS1AspectMin = _num(j, 'quality', 's1_aspect_range', 0, 1.2),
        qcS1AspectMax = _num(j, 'quality', 's1_aspect_range', 1, 1.85),
        qcS1MinAreaFrac = _num(j, 'quality', 's1_min_area_frac', null, 0.02),
        qcS1AngleMin = _num(j, 'quality', 's1_angle_range_deg', 0, 70),
        qcS1AngleMax = _num(j, 'quality', 's1_angle_range_deg', 1, 110),
        qcS2MaxInterpFrac = _num(j, 'quality', 's2_max_interp_frac', null, 0.20),
        qcS2MaxSnapFrac = _num(j, 'quality', 's2_max_snap_frac', null, 0.05),
        qcS2MinPitchPx = _num(j, 'quality', 's2_min_pitch_px', null, 0),
        manualMaxPerAxis = _num(j, 'manual', 'max_per_axis', null, 64).toInt(),
        manualPitchRatioMin = _num(j, 'manual', 'pitch_ratio_range', 0, 0.8),
        manualPitchRatioMax = _num(j, 'manual', 'pitch_ratio_range', 1, 1.25);

  static double _num(Map<String, dynamic> j, String sec, String key, int? idx, num def) {
    final s = j[sec];
    if (s is! Map) return def.toDouble();
    final v = idx == null ? s[key] : (s[key] is List ? (s[key] as List)[idx] : null);
    return v is num ? v.toDouble() : def.toDouble();
  }

  factory PipelineConfig.fromJson(Map<String, dynamic> j) => PipelineConfig._(j);

  static PipelineConfig? _instance;

  /// Cấu hình đã nạp (gọi [load] trước, trong InferenceService.initialize()).
  static PipelineConfig get I {
    final c = _instance;
    if (c == null) throw StateError('PipelineConfig chua duoc nap - goi PipelineConfig.load() truoc');
    return c;
  }

  static Future<PipelineConfig> load({String asset = 'assets/models/pipeline_config.json'}) async {
    _instance ??= PipelineConfig._(jsonDecode(await rootBundle.loadString(asset)) as Map<String, dynamic>);
    return _instance!;
  }

  String modelAsset(String file) => 'assets/models/$file';
  int get nWells => rows * cols;
}
