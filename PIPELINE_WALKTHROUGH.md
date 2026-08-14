# Quy trình chạy Pipeline phân tích Microplate trên ứng dụng Android

> Tài liệu mô tả thao tác chạy pipeline 3 stages **trực tiếp trên điện thoại Android**
> (toàn bộ suy luận chạy on-device bằng ONNX Runtime, không cần máy chủ/server).

---

## 1. Tổng quan

Ứng dụng **Microplate Analyzer** triển khai lại pipeline của `full_pipeline.ipynb` lên
thiết bị di động. Từ một ảnh cháy microplate chụp bằng điện thoại, ứng dụng tự động:

1. **Căn chỉnh plate** (detect 4 góc + warp làm phẳng)
2. **Detect các giếng (wells)** bằng YOLO
3. **Phân loại** từng giếng: *Growth / NoGrowth / NoAgar*

| Đặc điểm | Mô tả |
|----------|-------|
| Nơi chạy | **Trực tiếp trên điện thoại** (CPU ARM), không gửi ảnh đi đâu |
| Thư viện suy luận | ONNX Runtime (Flutter plugin) |
| Số model | 3 file ONNX (~76 MB tổng) nhúng sẵn trong app |
| Thao tác | Chạm nút ▶ cho từng stage, xem kết quả visualize ngay |
| Bảo mật dữ liệu | Ảnh không rời thiết bị — phù hợp môi trường phòng lab |

**Sơ đồ pipeline:**

```
  Ảnh microplate (camera/thư viện)
            │
            ▼
  ┌─────────────────────┐
  │ STAGE 1: ALIGN       │  EfficientNet-B3 → 4 corners → perspective warp
  │  Output: plate đã    │
  │  căn chính diện      │
  └─────────┬───────────┘
            ▼
  ┌─────────────────────┐
  │ STAGE 2: DETECT      │  YOLOv8 (1 kênh) → NMS → ~384 bounding box
  │  Output: boxes quanh │
  │  từng giếng          │
  └─────────┬───────────┘
            ▼
  ┌─────────────────────┐
  │ STAGE 3: CLASSIFY    │  RandomForest → Growth/NoGrowth/NoAgar
  │  Output: overlay màu │
  │  + bảng đếm          │
  └─────────────────────┘
```

---

## 2. Chuẩn bị

- Điện thoại đã cài app **Microplate Analyzer**.
- Có sẵn 1 ảnh microplate (chụp bằng camera điện thoại hoặc có sẵn trong thư viện).
- Mở app → vào màn hình **Pipeline** (tab đầu tiên, thanh dưới).

> App hoạt động ở **chế độ ngang (landscape)** vì ảnh microplate dạng rộng.

---

## 3. Thao tác chạy từng bước

### Bước 0 — Chọn ảnh đầu vào

1. Mở menu (☰ góc trên-trái) → chọn **Select Image**.
2. Chạm nút **Select Image** → mở thư viện ảnh của điện thoại.
3. Chọn ảnh microplate.

**Kết quả:** ảnh được chọn hiện ngay full màn hình (có thể pinch-zoom để xem kỹ),
kèm tên file ở góc trên-trái và nút **Change Image** để đổi ảnh khác nếu cần.

> Khi chọn ảnh mới, toàn bộ kết quả các stage trước sẽ được xoá — pipeline reset sạch.

---

### Bước 1 — Stage 1: Căn chỉnh plate (Align & Warp)

**Mục đích:** Biến ảnh chụp nghiêng/méo thành ảnh plate nhìn chính diện, để các
stage sau detect chính xác.

**Thao tác:**
1. Mở menu (☰) → chọn **Stage 1: Warp**.
2. Chạm nút **▶ Run** trên thanh công cụ phía trên.

**Ứng dụng tự động làm:**
- Load model **EfficientNet-B3** (ONNX), tiền xử lý ảnh về grayscale 896×896.
- Model hồi quy ra **4 toạ độ góc** của plate (TL, TR, BR, BL).
- Dùng 4 góc đó tính **ma trận biến đổi phối cảnh (perspective transform)**
  và warp ảnh về một plate hình chữ nhật chuẩn, có biên đệm (margin 8%).
- Nội suy song tuyến (bilinear) để ảnh ra mượt.

**Kết quả hiển thị — 2 ảnh cạnh nhau:**
| Bên trái | Bên phải |
|----------|----------|
| Ảnh gốc + **4 góc được detect** (chấm vàng + viền polygon nối 4 góc) | Ảnh **plate đã warp** — nhìn chính diện, phẳng |

> Có thể pinch-zoom từng ảnh để kiểm tra góc detect có khớp không. Nếu sai, chạm
> **Reset (↻)** rồi chạy lại.

---

### Bước 2 — Stage 2: Detect các giếng (Well Detection)

**Mục đích:** Tìm vị trí tất cả giếng trên plate đã căn chỉnh.

**Thao tác:**
1. Mở menu (☰) → chọn **Stage 2: Detect**.
2. Chạm nút **▶ Run**.

**Ứng dụng tự động làm:**
- Lấy ảnh plate đã warp từ Stage 1.
- Load model **YOLOv8 (1 kênh grayscale)**, letterbox về 640×640.
- Chạy suy luận → hàng ngàn box thô → lọc theo độ tin cậy (conf > 0.05).
- Áp dụng **Non-Maximum Suppression (NMS, IoU 0.15)** loại box trùng lặp.
- Giới hạn tối đa 384 box.

**Kết quả hiển thị:**
- Ảnh plate warp **full màn hình**, mỗi giếng có **bounding box** vẽ quanh.
- Badge góc trên-trái: **"N wells"** (thường ~384 wells cho plate 16×24).

> Toạ độ box nằm trong **không gian ảnh warp** (warped space) — khớp hoàn toàn với
> ảnh đang hiển thị, không bị lệch.

---

### Bước 3 — Stage 3: Phân loại (Classification)

**Mục đích:** Xác định trạng thái sinh học của từng giếng.

**Thao tác:**
1. Mở menu (☰) → chọn **Stage 3: Classify**.
2. Chạm nút **▶ Run**.

**Ứng dụng tự động làm:**
- Với từng box (giếng) từ Stage 2: cắt vùng ảnh → resize về 64×64 → grayscale.
- Ghép thành ma trận đặc trưng **[N × 4096]**.
- Load model **RandomForest/ExtraTrees (ONNX)**, suy luận ra nhãn lớp cho từng giếng.
- Vẽ **overlay màu** lên từng giếng theo kết quả phân loại.

**Kết quả hiển thị:**
- Ảnh plate warp với overlay màu theo lớp:
  - 🟢 **Xanh lá — Growth** (có sinh trưởng)
  - 🔴 **Đỏ — NoGrowth** (không sinh trưởng)
  - 🟣 **Tím — NoAgar** (không có thạch/agar)
- Badge góc trên-trái: `G:N  N:N  A:N` (số lượng mỗi lớp).
- Hộp thoại **Pipeline Complete** tổng kết → chạm **View Results**.

---

### Bước 4 — Xem kết quả chi tiết & lưu

Sau khi Stage 3 xong, chạm **View Results** (trong menu khi đã xong, hoặc nút dưới
cùng màn hình Stage 3):

- Màn hình kết quả chi tiết: ảnh annotated lớn + thống kê từng lớp.
- Có thể **xuất kết quả** (CSV/PDF) và **lưu vào History** (cơ sở dữ liệu SQLite cục bộ).
- Vào tab **History** (thanh dưới) để xem lại các lần chạy trước.

---

## 4. Bảng tóm tắt 3 stages

| Stage | Việc làm | Model ONNX | Input | Output | Hiển thị |
|-------|----------|-----------|-------|--------|----------|
| **1. Align** | Detect góc + warp phẳng | EfficientNet-B3 (896², 1 kênh) | Ảnh gốc | 4 góc + ảnh warp | Ảnh gốc(kẻ góc) ‖ ảnh warp |
| **2. Detect** | Tìm các giếng | YOLOv8 (640², 1 kênh) | Ảnh warp | ~384 box | Ảnh warp + box mỗi giếng |
| **3. Classify** | Phân loại giếng | RandomForest (4096 đặc trưng) | Crop từng giếng | Nhãn 0/1/2 | Ảnh warp + overlay màu |

**Nhãn lớp:** `0 = Growth`, `1 = NoGrowth`, `2 = NoAgar`.

---

## 5. Điểm kỹ thuật đáng chú ý (cho báo cáo)

- **Toàn bộ suy luận on-device:** 3 model ONNX chạy bằng ONNX Runtime ngay trên CPU
  điện thoại — không cần Internet, không gửi ảnh lên server. Đảm bảo riêng tư dữ liệu
  phòng lab và hoạt động được ngoài hiện trường.
- **Một pipeline, không gian toạ độ thống nhất:** từ Stage 2 trở đi mọi thao tác
  (detect, crop, classify, vẽ overlay) đều trong *warped space* — cùng một khung ảnh
  warp — nên các box và màu luôn khớp vị trí, không lệch.
- **Tương đương notebook:** kết quả trên app khớp với pipeline tham chiếu
  `full_pipeline.ipynb`, chỉ khác là chạy trên thiết bị di động thay vì Python/PC.
- **Tương tác trực quan:** mỗi stage có thể chạy lại (▶) hoặc reset (↻) độc lập,
  xem ảnh kết quả pinch-zoom toàn màn hình, đổi ảnh đầu vào bất cứ lúc nào.

---

## 6. Kịch bản lướt (dùng cho video demo / thuyết trình ngắn)

> Tổng ~60–90 giây.

1. *(0–10s)* Mở app → **Pipeline**. Chạm **Select Image** → chọn ảnh microplate.
   → Ảnh hiện lên màn hình.
2. *(10–25s)* Vào **Stage 1** → bấm ▶. → Hiện ảnh gốc có 4 góc vàng cạnh ảnh plate
   đã căn thẳng. *"Bước 1: app tự tìm góc và làm phẳng plate."*
3. *(25–45s)* Vào **Stage 2** → bấm ▶. → Hiện từng giếng được đóng khung, badge
   ~384 wells. *"Bước 2: detect tất cả giếng bằng YOLO."*
4. *(45–70s)* Vào **Stage 3** → bấm ▶. → Giếng chuyển màu xanh/đỏ/tím, badge đếm
   số lượng. *"Bước 3: phân loại Growth/NoGrowth/NoAgar."*
5. *(70–90s)* Bấm **View Results** → bảng thống kê + xuất/lưu. *"Tất cả chạy trên
   máy, không cần mạng."*
