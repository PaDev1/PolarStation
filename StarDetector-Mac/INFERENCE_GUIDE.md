# StarDetector CoreML Inference Guide

## Model Overview

**StarDetector.mlpackage** — ELUNet star detection model for grayscale starfield images.

- Architecture: Efficient Lightweight UNet (4-stage encoder/decoder with skip connections)
- Parameters: 1,811,729
- Precision: float16 (Neural Engine optimized)
- Minimum deployment: macOS 14+
- Expected inference: ~3-5ms on Apple Neural Engine

| Property | Value |
|----------|-------|
| Input name | `image` |
| Input type | `MLMultiArray` Float32 |
| Input shape | `[1, 1, 256, 256]` (batch, channel, height, width) |
| Output name | `heatmap` |
| Output type | `MLMultiArray` Float16 |
| Output shape | `[1, 1, 256, 256]` |

## Sample Training Data

![Training sample](sample_training.png)

Left: input starfield (contrast-stretched for display, actual pixel range [0,1]).
Center: ground truth Gaussian heatmap labels. Right: model prediction.

## Critical: Input Preprocessing

**This is where things break when moving to a real camera pipeline on Mac.** The model was trained on specifically normalized data. If your input does not match, the model will produce garbage.

### Step 1: Convert to grayscale float [0, 1]

The model expects a single-channel float32 image. If your source is a camera buffer (CVPixelBuffer, vImage, CGImage), convert to grayscale first.

```swift
// Example: from CVPixelBuffer (kCVPixelFormatType_OneComponent8)
let width = 256
let height = 256
var floatPixels = [Float](repeating: 0, count: width * height)
for i in 0..<(width * height) {
    floatPixels[i] = Float(rawBytes[i]) / 255.0
}
```

If your camera produces 16-bit or 32-bit data, scale accordingly:
```swift
// 16-bit unsigned
floatPixels[i] = Float(rawUInt16[i]) / 65535.0
```

### Step 2: Percentile normalization (REQUIRED)

**This is the most common source of failure.** The training data was normalized using 99.9th percentile scaling, NOT simple min-max or clipping to [0,1]. Raw starfield images have a wide dynamic range — bright stars may be 10-50x the background level. Simple clipping at 1.0 destroys star structure and produces flat-topped blobs the model has never seen.

```swift
// Sort or compute 99.9th percentile
let sorted = floatPixels.sorted()
let idx999 = Int(Float(sorted.count) * 0.999)
let vmax = sorted[idx999]

// Normalize
if vmax > 0 {
    for i in 0..<floatPixels.count {
        floatPixels[i] = min(floatPixels[i] / vmax, 1.0)
    }
}
```

For efficiency, you can approximate the percentile with a histogram instead of sorting:
```swift
// Histogram-based percentile (faster for large images)
var histogram = [Int](repeating: 0, count: 1000)
for px in floatPixels {
    let bin = min(Int(px * 999), 999)
    histogram[bin] += 1
}
var cumulative = 0
let target = Int(Float(floatPixels.count) * 0.999)
var vmax: Float = 1.0
for (bin, count) in histogram.enumerated() {
    cumulative += count
    if cumulative >= target {
        vmax = Float(bin + 1) / 1000.0
        break
    }
}
```

### Step 3: Resize to 256x256

The model accepts exactly 256x256. If your image is larger, resize with bilinear interpolation. Do this AFTER normalization.

```swift
// Using vImage or Core Graphics
// Bilinear interpolation, NOT nearest-neighbor
```

If your FOV is large and contains many stars, consider tiling: run the model on overlapping 256x256 crops and merge the heatmaps.

### Step 4: Create MLMultiArray and run inference

```swift
import CoreML

let model = try StarDetector(configuration: .init())

// Shape: [1, 1, 256, 256]
let input = try MLMultiArray(shape: [1, 1, 256, 256], dataType: .float32)
for i in 0..<floatPixels.count {
    input[i] = NSNumber(value: floatPixels[i])
}

let result = try model.prediction(image: input)
let heatmap = result.heatmap  // [1, 1, 256, 256] Float16
```

## Post-processing: Extracting Star Positions

The output heatmap has values in [0, 1]. Star locations are peaks (local maxima) above a confidence threshold.

```swift
// 1. Threshold the heatmap (0.3 works well, lower = more sensitive)
let threshold: Float = 0.3

// 2. Find local maxima (non-maximum suppression with 5x5 window)
var stars: [(x: Float, y: Float, confidence: Float)] = []
let heatmapPtr = UnsafeMutablePointer<Float16>(/* from MLMultiArray */)

for y in 2..<254 {
    for x in 2..<254 {
        let val = Float(heatmapPtr[y * 256 + x])
        if val < threshold { continue }

        // Check if local maximum in 5x5 neighborhood
        var isMax = true
        for dy in -2...2 {
            for dx in -2...2 {
                if dx == 0 && dy == 0 { continue }
                if Float(heatmapPtr[(y + dy) * 256 + (x + dx)]) >= val {
                    isMax = false
                    break
                }
            }
            if !isMax { break }
        }

        if isMax {
            stars.append((x: Float(x), y: Float(y), confidence: val))
        }
    }
}
```

For sub-pixel accuracy, fit a 2D quadratic to the 3x3 neighborhood around each peak:
```swift
// Quadratic refinement for sub-pixel centroid
func refine(heatmap: UnsafePointer<Float16>, x: Int, y: Int) -> (Float, Float) {
    let c  = Float(heatmap[y * 256 + x])
    let dx = (Float(heatmap[y * 256 + x + 1]) - Float(heatmap[y * 256 + x - 1])) / 2
    let dy = (Float(heatmap[(y + 1) * 256 + x]) - Float(heatmap[(y - 1) * 256 + x])) / 2
    let dxx = Float(heatmap[y * 256 + x + 1]) + Float(heatmap[y * 256 + x - 1]) - 2 * c
    let dyy = Float(heatmap[(y + 1) * 256 + x]) + Float(heatmap[(y - 1) * 256 + x]) - 2 * c

    let subX = dxx != 0 ? Float(x) - dx / dxx : Float(x)
    let subY = dyy != 0 ? Float(y) - dy / dyy : Float(y)
    return (subX, subY)
}
```

## Common Issues & Fixes

### Model outputs all zeros or uniform values

**Cause:** Input not normalized correctly. Most likely the image was clipped to [0,1] directly from raw camera values without percentile scaling, so all stars appear as flat 1.0 blobs.

**Fix:** Apply 99.9th percentile normalization as described in Step 2.

### Model detects noise as stars (many false positives)

**Cause:** Input image values are too low (e.g., raw camera values not scaled up, so the entire image sits near 0). The model amplifies faint patterns.

**Fix:** Ensure the 99.9th percentile normalization stretches the signal properly. The brightest star should be near 1.0, background near 0.01-0.10.

### Stars detected but positions are offset

**Cause:** Image was resized before normalization, or the coordinate system is flipped (origin top-left vs bottom-left).

**Fix:** Normalize first, then resize. The model uses top-left origin (row 0 = top of image, standard image convention). If your camera uses bottom-left origin, flip vertically before inference.

### Fewer stars detected than expected

**Cause:** Threshold too high, or stars are overlapping at high density.

**Fix:** Lower the detection threshold from 0.3 to 0.2. For dense fields (>40 stars in 256x256), consider using a smaller NMS window (3x3 instead of 5x5).

### Performance is slow (>10ms on M1/M2)

**Cause:** Model running on CPU instead of Neural Engine.

**Fix:** Set compute units to `.all` (default) or `.cpuAndNeuralEngine`:
```swift
let config = MLModelConfiguration()
config.computeUnits = .all  // Lets CoreML pick ANE when available
let model = try StarDetector(configuration: config)
```

## Test Results

### Native 256x256 (SNR sweep, 3000 images, 70,000 stars)

| Metric | Value |
|--------|-------|
| Precision | 99.98% |
| Recall | 99.4% |
| F1 Score | 99.7% |
| Position Error | 0.385 px (average) |

Detection remains robust down to SNR 3 (barely above noise floor). The ~0.6% missed detections occur primarily in dense fields where stars overlap within 5 pixels.

### Multi-resolution realistic test (600 images, 17,000 stars)

Images generated at native resolution, then preprocessed through the full pipeline (percentile norm + bilinear resize to 256x256). SNR range 3-50, varying sky background and noise.

| Native Size | Stars | Precision | Recall | F1 | Pos Error |
|-------------|-------|-----------|--------|-----|-----------|
| 128 | 10 | 35.4% | 99.8% | 52.2% | 0.86 px |
| 128 | 25 | 75.6% | 99.6% | 86.0% | 0.83 px |
| 128 | 50 | 88.4% | 98.9% | 93.4% | 0.83 px |
| **256** | **10** | **100%** | **99.8%** | **99.9%** | **0.39 px** |
| **256** | **25** | **100%** | **99.3%** | **99.6%** | **0.39 px** |
| **256** | **50** | **100%** | **98.9%** | **99.5%** | **0.38 px** |
| 512 | 10 | 100% | 99.8% | 99.9% | 0.53 px |
| 512 | 25 | 100% | 99.6% | 99.8% | 0.54 px |
| 512 | 50 | 100% | 98.7% | 99.3% | 0.53 px |
| 1024 | 10 | 100% | 99.8% | 99.9% | 0.68 px |
| 1024 | 25 | 100% | 99.2% | 99.6% | 0.67 px |
| 1024 | 50 | 100% | 98.9% | 99.5% | 0.68 px |

**Key findings:**

- **256x256 and above**: excellent performance, zero false positives, sub-pixel accuracy.
- **Downscaling from 512/1024**: works perfectly. Position error increases slightly (0.5-0.7 px in 256-space) due to resize interpolation, but still sub-pixel in native coordinates.
- **Upscaling from 128**: DO NOT USE. Interpolation artifacts from 128→256 upscaling create false star-like patterns. The model was not trained on upscaled data. Minimum native resolution is 256x256.
