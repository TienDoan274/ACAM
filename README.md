# Microplate Analyzer — Mobile App

Ứng dụng Flutter Android chạy pipeline phân tích microplate 3 stages bằng ONNX Runtime,
tương đương với `full_pipeline.ipynb` nhưng chạy trực tiếp trên điện thoại.

## Kiến trúc pipeline (3 stages)

| Stage | Mô tả | Model ONNX | Output |
|-------|-------|------------|--------|
| **Stage 1 — Warp** | Detect 4 góc plate (EfficientNet-B3 regression) → perspective warp → làm phẳng | `assets/models/stage1_grid_fp32.onnx` | Ảnh gốc (có góc) + ảnh plate đã warp |
| **Stage 2 — Detect** | YOLOv8 (1 kênh) detect các giếng (wells) trên ảnh đã warp | `assets/models/stage2_yolo.onnx` | Ảnh warp với bounding box từng well (~384 wells) |
| **Stage 3 — Classify** | RandomForest/ExtraTrees phân loại mỗi well: Growth / NoGrowth / NoAgar | `assets/models/stage3_rf_fp32.onnx` | Ảnh warp với overlay màu theo lớp + bảng đếm |

> **Lưu ý quan trọng (coordinate space):** Stage 2 và 3 thao tác trong **warped space** —
> bounding box được vẽ trực tiếp lên ảnh đã warp, KHÔNG unwrap về tọa độ gốc. Điều này
> đảm bảo box khớp hoàn toàn với ảnh hiển thị (giống `full_pipeline.ipynb`).

---

## 1. Yêu cầu (Prerequisites)

- **Flutter** ≥ 3.x (`flutter doctor` không lỗi)
- **Android SDK** + **platform-tools** (có `adb`)
- **Điện thoại Android**: bật **Developer Options** → **USB Debugging**
- Cáp USB (hoặc `adb` qua WiFi)
- Cáp nối điện thoại với máy tính, xác nhận trên điện thoại khi có hộp thoại "Allow USB debugging"

Kiểm tra thiết bị đã kết nối:

```bash
adb devices
# phải thấy 1 dòng dạng:  f9dcc4ba  device
```

---

## 2. Build APK

Từ thư mục `mobile_app/microplate_analyzer`:

```bash
flutter pub get
flutter build apk --release
```

Kết quả:

```
√ Built build\app\outputs\flutter-apk\app-release.apk (~128 MB)
```

> Bundle lớn (~128 MB) vì chứa 3 model ONNX (~76 MB tổng) + `onnxruntime` native libs.

---

## 3. Cài app lên điện thoại

### Cách A — qua `adb` (khuyến nghị, nhanh)

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
# → Success
```

### Cách B — copy thủ công

1. Copy file `app-release.apk` sang điện thoại.
2. Trên điện thoại mở file `.apk` → cấp quyền "Install from unknown sources".
3. Cài đặt.

### Mở app

```bash
adb shell monkey -p com.example.microplate_analyzer -c android.intent.category.LAUNCHER 1
```

hoặc chạm icon **Microplate Analyzer** trên màn hình điện thoại.

> App **khóa landscape** (ngang) vì ảnh microplate dạng rộng.

---

## 4. Chạy pipeline từng bước

Mở app → màn hình chính là **Pipeline**. Thanh điều hướng nằm trong **Drawer** (icon ☰ góc trên-trái).

### Bước 0 — Chọn ảnh

1. Mở Drawer (☰) → **Select Image**.
2. Chạm **Select Image** → chọn ảnh microplate từ thư viện.
3. Sau khi chọn, các stage phía sau tự reset.

### Bước 1 — Stage 1: Warp (Corner detection + warp)

1. Mở Drawer → **Stage 1: Warp**.
2. Chạm **Run Stage 1**. (lần đầu có thể chậm vài giây để load model)
3. Output: **hai ảnh cạnh nhau**
   - **Trái** — *Original + Corners*: ảnh gốc với 4 góc được detect (chấm vàng + viền polygon).
   - **Phải** — *Warped Plate*: ảnh plate đã được crop + làm phẳng.

> Có thể **pinch-zoom / pan** từng ảnh. Chạm **Reset** để chạy lại Stage 1 (sẽ reset cả 2 & 3).

### Bước 2 — Stage 2: Detect (Well detection)

1. Mở Drawer → **Stage 2: Detect** (chỉ kích hoạt sau Stage 1 xong).
2. Chạm **Run Stage 2**.
3. Output: **ảnh warp full-screen** với bounding box quanh mỗi well + badge góc trên "N wells"
   (thường ~384 wells cho plate 16×24).

### Bước 3 — Stage 3: Classify (Phân loại)

1. Mở Drawer → **Stage 3: Classify** (chỉ kích hoạt sau Stage 2 xong).
2. Chạm **Run Stage 3**.
3. Output: **ảnh warp full-screen** với overlay màu theo lớp:
   - 🟢 Xanh lá — **Growth**
   - 🔴 Đỏ — **NoGrowth**
   - 🟣 Tím — **NoAgar**
4. Badge góc trên-trái: `G:N  N:N  A:N` (số lượng mỗi lớp).
5. Hộp thoại **Pipeline Complete** hiện tổng kết → chạm **View Results** để xem chi tiết
   (bảng phân loại, xuất CSV/PDF, lưu vào History).

---

## 5. Xem kết quả & History

- **View Results** (từ Drawer khi đã xong Stage 3, hoặc nút cuối màn hình Stage 3):
  màn hình chi tiết với ảnh annotated + thống kê + xuất file.
- Tab **History** (thanh dưới): lưu lại các lần chạy (SQLite cục bộ trên máy).
- Tab **Settings**: cấu hình model/tham số.

---

## 6. Xem log khi debug

```bash
adb logcat -c                       # clear
adb logcat -v time Pipeline:V flutter:V AndroidRuntime:E *:S
```

Từ mã nguồn có các log dấu vết:
- `[Pipeline] Stage 2 detected N wells (warped space)`
- `[Pipeline] Stage 2 visualization saved to: .../stage2_detection_*.png`

---

## 7. Khắc phục sự cố (Troubleshooting)

| Triệu chứng | Nguyên nhân / Khắc phục |
|-------------|------------------------|
| `no devices/emulators found` | Kiểm tra cáp, bật USB Debugging, đồng ý hộp thoại "Allow debugging" trên điện thoại. `adb kill-server && adb devices` |
| App cũ vẫn chạy (không thấy fix) | Chạy `adb install -r ...` lại; đảm bảo build mới nhất đã cài (`adb shell am force-stop com.example.microplate_analyzer` rồi mở lại) |
| Stage không kích hoạt | Phải làm tuần tự: Stage 1 → 2 → 3. Mỗi stage cần stage trước hoàn tất. |
| Ảnh visualize không hiện | Kiểm tra logcat xem có `visualization saved to:` không; nếu có mà vẫn không thấy → đang chạy bản build cũ, build + install lại |
| Load model chậm/lỗi lần đầu | Model load ở `main()`; lần mở đầu có thể mất vài giây. Nếu crash → kiểm tra 3 file ONNX còn trong `assets/models/` |
| App crash | `adb logcat -v time AndroidRuntime:E *:S` để xem stack trace |

---

## 8. Cấu trúc mã nguồn chính

```
lib/
├── main.dart                      # Khởi tạo app, load model, landscape lock
├── screens/
│   ├── pipeline_screen.dart       # UI 3 stages + Drawer điều hướng
│   ├── results_screen.dart        # Màn hình kết quả chi tiết
│   ├── history_screen.dart        # Lịch sử (SQLite)
│   └── settings_screen.dart       # Cấu hình
├── models/
│   ├── inference_service.dart     # ONNX: detectAutoGrid, detectYoloWarped,
│   │                              #       classifyWarpedWells, warpPlateAndSave
│   └── database_helper.dart       # SQLite history
└── utils/
    ├── image_utils.dart           # drawCorners, drawWellBoxes, warp, save
    └── constants.dart             # Tham số (PLATE_MARGIN, rows/cols, ...)
```

### Các hàm pipeline cốt lõi (trong `inference_service.dart`)

- `detectAutoGrid(imagePath)` → `Detection` (4 góc, grid positions) — Stage 1
- `warpPlateAndSave(imagePath, corners)` → đường dẫn ảnh warp — Stage 1
- `detectYoloWarped(imagePath, corners)` → `WarpedDetection` (boxes trong warped space) — Stage 2
- `classifyWarpedWells(WarpedDetection)` → classes + counts + ảnh annotated — Stage 3
