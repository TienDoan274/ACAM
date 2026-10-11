

https://github.com/user-attachments/assets/41e40dbf-7ac8-47a6-9cff-475079512d81





# Microplate Analyzer — Mobile App

Flutter Android application running a 3-stage microplate analysis pipeline using ONNX Runtime,
equivalent to `full_pipeline.ipynb` but running directly on the phone.

> 📘 **How to use the app:** see [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) (English, with screenshots).

## Pipeline Architecture (3 Stages)

| Stage | Description | ONNX Model | Output |
|-------|-------------|------------|--------|
| **Stage 1 — Warp** | Detect 4 plate corners (EfficientNet-B3 regression) → perspective warp → flatten | `assets/models/stage1_grid_fp32.onnx` | Original image (with corners) + warped plate image |
| **Stage 2 — Detect** | YOLOv8 (1 channel) detect wells on warped image | `assets/models/stage2_yolo.onnx` | Warped image with bounding boxes for each well (~384 wells) |
| **Stage 3 — Classify** | RandomForest/ExtraTrees classify each well: Growth / NoGrowth / NoAgar | `assets/models/stage3_rf_fp32.onnx` | Warped image with color overlay by class + count table |

> **Important Note (coordinate space):** Stages 2 and 3 operate in **warped space** —
> bounding boxes are drawn directly on the warped image, NOT unwrapped back to original coordinates.
> This ensures boxes perfectly match the displayed image (same as `full_pipeline.ipynb`).

---

## 1. Prerequisites

- **Flutter** ≥ 3.x (`flutter doctor` with no errors)
- **Android SDK** + **platform-tools** (with `adb`)
- **Android phone**: enable **Developer Options** → **USB Debugging**
- USB cable (or `adb` over WiFi)
- Connect phone to computer, confirm "Allow USB debugging" dialog on phone

Check connected device:

```bash
adb devices
# should see a line like:  f9dcc4ba  device
```

---

## 2. Build APK

From `mobile_app/microplate_analyzer` directory:

```bash
flutter pub get
flutter build apk --release
```

Result:

```
√ Built build\app\outputs\flutter-apk\app-release.apk (~128 MB)
```

> Large bundle (~128 MB) because it contains 3 ONNX models (~76 MB total) + `onnxruntime` native libs.

---

## 3. Install App on Phone

### Method A — via `adb` (recommended, fast)

```bash
adb install -r build/app/outputs/flutter-apk/app-release.apk
# → Success
```

### Method B — manual copy

1. Copy `app-release.apk` file to phone.
2. On phone, open the `.apk` file → grant "Install from unknown sources" permission.
3. Install.

### Launch App

```bash
adb shell monkey -p com.example.microplate_analyzer -c android.intent.category.LAUNCHER 1
```

or tap the **Microplate Analyzer** icon on phone screen.

> App is **locked to landscape** mode because microplate images are wide format.

---

## 4. Running Pipeline Step by Step

Open app → main screen is **Pipeline**. Navigation menu is in **Drawer** (☰ icon at top-left).

### Step 0 — Select Image

1. Open Drawer (☰) → **Select Image**.
2. Tap **Select Image** → choose microplate image from gallery.
3. After selection, subsequent stages are automatically reset.

### Step 1 — Stage 1: Warp (Corner detection + warp)

1. Open Drawer → **Stage 1: Warp**.
2. Tap **Run Stage 1**. (first run may be slow, loading model takes a few seconds)
3. Output: **two images side by side**
   - **Left** — *Original + Corners*: original image with 4 detected corners (yellow dots + polygon border).
   - **Right** — *Warped Plate*: plate image after crop + flatten.

> You can **pinch-zoom / pan** each image. Tap **Reset** to re-run Stage 1 (will also reset stages 2 & 3).

### Step 2 — Stage 2: Detect (Well detection)

1. Open Drawer → **Stage 2: Detect** (only enabled after Stage 1 completes).
2. Tap **Run Stage 2**.
3. Output: **full-screen warped image** with bounding boxes around each well + badge at top "N wells"
   (usually ~384 wells for a 16×24 plate).

### Step 3 — Stage 3: Classify (Classification)

1. Open Drawer → **Stage 3: Classify** (only enabled after Stage 2 completes).
2. Tap **Run Stage 3**.
3. Output: **full-screen warped image** with color overlay by class:
   - 🟢 Green — **Growth**
   - 🔴 Red — **NoGrowth**
   - 🟣 Purple — **NoAgar**
4. Badge at top-left: `G:N  N:N  A:N` (count for each class).
5. **Pipeline Complete** dialog shows summary → tap **View Results** to see details
   (classification table, export CSV/PDF, save to History).

---

## 5. Viewing Results & History

- **View Results** (from Drawer after Stage 3 completes, or button at bottom of Stage 3 screen):
  detailed screen with annotated image + statistics + file export.
- Tab **History** (bottom bar): saves previous runs (local SQLite on device).
- Tab **Settings**: model configuration/parameters.

---

## 6. Viewing Logs When Debugging

```bash
adb logcat -c                       # clear
adb logcat -v time Pipeline:V flutter:V AndroidRuntime:E *:S
```

From source code, look for trace logs:
- `[Pipeline] Stage 2 detected N wells (warped space)`
- `[Pipeline] Stage 2 visualization saved to: .../stage2_detection_*.png`

---

## 7. Troubleshooting

| Symptom | Cause / Fix |
|---------|--------------|
| `no devices/emulators found` | Check cable, enable USB Debugging, accept "Allow debugging" dialog on phone. `adb kill-server && adb devices` |
| Old app still running (don't see fixes) | Run `adb install -r ...` again; ensure latest build is installed (`adb shell am force-stop com.example.microplate_analyzer` then reopen) |
| Stages not enabled | Must run sequentially: Stage 1 → 2 → 3. Each stage requires previous stage completion. |
| Visualization images not showing | Check logcat for `visualization saved to:`; if exists but still not visible → running old build, rebuild + reinstall |
| Slow model load/error on first run | Models load in `main()`; first launch may take a few seconds. If crash → check 3 ONNX files still in `assets/models/` |
| App crash | `adb logcat -v time AndroidRuntime:E *:S` to view stack trace |

---

## 8. Main Source Code Structure

```
lib/
├── main.dart                      # App initialization, model loading, landscape lock
├── screens/
│   ├── pipeline_screen.dart       # 3-stage UI + Drawer navigation
│   ├── results_screen.dart        # Detailed results screen
│   ├── history_screen.dart        # History (SQLite)
│   └── settings_screen.dart       # Configuration
├── models/
│   ├── inference_service.dart     # ONNX: detectAutoGrid, detectYoloWarped,
│   │                              #       classifyWarpedWells, warpPlateAndSave
│   └── database_helper.dart       # SQLite history
└── utils/
    ├── image_utils.dart           # drawCorners, drawWellBoxes, warp, save
    └── constants.dart             # Parameters (PLATE_MARGIN, rows/cols, ...)
```

### Core Pipeline Functions (in `inference_service.dart`)

- `detectAutoGrid(imagePath)` → `Detection` (4 corners, grid positions) — Stage 1
- `warpPlateAndSave(imagePath, corners)` → warped image path — Stage 1
- `detectYoloWarped(imagePath, corners)` → `WarpedDetection` (boxes in warped space) — Stage 2
- `classifyWarpedWells(WarpedDetection)` → classes + counts + annotated image — Stage 3
