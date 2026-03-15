#!/usr/bin/env python3
"""
Test StarDetector CoreML model on macOS.

Generates synthetic starfields, runs inference through CoreML,
and reports detection metrics (precision, recall, F1, position error).

Requirements: pip install coremltools numpy scipy
Runs on macOS only (CoreML prediction requires macOS).
"""

import numpy as np
import coremltools as ct
from scipy.ndimage import maximum_filter, label as ndlabel
import argparse
import time


def add_star_psf(image, x, y, fwhm, peak, pad=5):
    """Add a star PSF to image using a local patch."""
    sigma = fwhm / 2.355
    size = image.shape[0]
    radius = int(np.ceil(sigma * 4)) + pad
    x0 = max(0, int(x) - radius)
    x1 = min(size, int(x) + radius + 1)
    y0 = max(0, int(y) - radius)
    y1 = min(size, int(y) + radius + 1)
    yy, xx = np.mgrid[y0:y1, x0:x1]
    psf = np.exp(-((xx - x) ** 2 + (yy - y) ** 2) / (2 * sigma ** 2))
    image[y0:y1, x0:x1] += peak * psf


def generate_test_starfield(size, n_stars, snr, fwhm, sky_bg=0.1, read_noise=0.02, rng=None):
    """Generate a single test starfield with known star positions."""
    if rng is None:
        rng = np.random.default_rng()

    yy, xx = np.mgrid[0:size, 0:size] / size
    gradient = rng.uniform(0, 0.05) * (rng.uniform(-1, 1) * xx + rng.uniform(-1, 1) * yy)
    sky = sky_bg + gradient
    sky = np.clip(sky, 0, None)
    image = sky.copy().astype(np.float64)

    star_positions = []
    for _ in range(n_stars):
        x = rng.uniform(10, size - 10)
        y = rng.uniform(10, size - 10)
        noise_level = np.sqrt(sky_bg + read_noise ** 2)
        peak = snr * noise_level
        add_star_psf(image, x, y, fwhm, peak)
        star_positions.append((x, y))

    # Poisson + read noise
    adu_scale = 1000.0
    image_adu = np.clip(image * adu_scale, 0, None)
    image_noisy = rng.poisson(image_adu).astype(np.float64) / adu_scale
    image_noisy += rng.normal(0, read_noise, (size, size))

    # Hot pixels
    n_hot = int(size * size * 0.0005)
    hx = rng.integers(0, size, n_hot)
    hy = rng.integers(0, size, n_hot)
    image_noisy[hy, hx] = rng.uniform(0.5, 1.0, n_hot)

    # Percentile normalization (must match training pipeline)
    image_noisy = np.clip(image_noisy, 0, None)
    vmax = np.percentile(image_noisy, 99.9)
    if vmax > 0:
        image_noisy = image_noisy / vmax
    image_noisy = np.clip(image_noisy, 0, 1).astype(np.float32)

    return image_noisy, star_positions


def detect_stars(heatmap, threshold=0.3):
    """Extract star coordinates from heatmap via local maxima."""
    pred_peaks = (heatmap > threshold) & (heatmap == maximum_filter(heatmap, size=5))
    labels, n = ndlabel(pred_peaks)
    coords = []
    for j in range(1, n + 1):
        ys, xs = np.where(labels == j)
        coords.append((xs.mean(), ys.mean(), heatmap[ys[0], xs[0]]))
    return coords


def match_stars(pred_coords, gt_coords, match_radius=5.0):
    """Match predicted to ground truth within radius."""
    matched_gt = set()
    tp = 0
    errors = []
    for px, py, _ in pred_coords:
        best_dist = match_radius
        best_k = -1
        for k, (gx, gy) in enumerate(gt_coords):
            if k in matched_gt:
                continue
            d = np.hypot(px - gx, py - gy)
            if d < best_dist:
                best_dist = d
                best_k = k
        if best_k >= 0:
            matched_gt.add(best_k)
            tp += 1
            errors.append(best_dist)
    fp = len(pred_coords) - tp
    fn = len(gt_coords) - tp
    return tp, fp, fn, errors


def run_test(model_path="StarDetector.mlpackage", samples_per_level=50):
    print(f"Loading model: {model_path}")
    model = ct.models.MLModel(model_path)

    # Verify input shape
    spec = model.get_spec()
    for inp in spec.description.input:
        shape = [s for s in inp.type.multiArrayType.shape]
        print(f"  Input: {inp.name} shape={shape}")
    for out in spec.description.output:
        shape = [s for s in out.type.multiArrayType.shape]
        print(f"  Output: {out.name} shape={shape}")

    input_size = int(spec.description.input[0].type.multiArrayType.shape[2])
    print(f"  Model size: {input_size}x{input_size}")
    print()

    rng = np.random.default_rng(777)
    snr_levels = np.linspace(3, 50, 10)
    star_counts = [10, 25, 50]
    fwhm_values = [1.0, 2.0, 3.5]  # tight, medium, blurred

    print(f"{'SNR':>6}  {'N★':>4}  {'FWHM':>5}  {'TP':>5}  {'FP':>5}  {'FN':>5}  {'Prec':>6}  {'Recall':>6}  {'F1':>6}  {'PosErr':>7}  {'ms/img':>7}")
    print("-" * 82)

    grand_tp, grand_fp, grand_fn = 0, 0, 0
    grand_errors = []
    total_time = 0
    total_images = 0

    for snr in snr_levels:
        for n_stars in star_counts:
            for fwhm in fwhm_values:
                tp_total, fp_total, fn_total = 0, 0, 0
                pos_errors = []

                for _ in range(samples_per_level):
                    sky_bg = rng.uniform(0.02, 0.25)
                    read_noise = rng.uniform(0.005, 0.04)

                    image, gt = generate_test_starfield(
                        input_size, n_stars, snr, fwhm,
                        sky_bg=sky_bg, read_noise=read_noise, rng=rng,
                    )

                    # CoreML inference
                    input_array = image.reshape(1, 1, input_size, input_size)
                    t0 = time.perf_counter()
                    result = model.predict({"image": input_array})
                    t1 = time.perf_counter()
                    total_time += (t1 - t0)
                    total_images += 1

                    heatmap = np.array(result["heatmap"]).reshape(input_size, input_size).astype(np.float32)

                    pred_coords = detect_stars(heatmap, threshold=0.3)
                    tp, fp, fn, errs = match_stars(pred_coords, gt)
                    tp_total += tp
                    fp_total += fp
                    fn_total += fn
                    pos_errors.extend(errs)

                prec = tp_total / (tp_total + fp_total) if (tp_total + fp_total) > 0 else 0
                rec = tp_total / (tp_total + fn_total) if (tp_total + fn_total) > 0 else 0
                f1 = 2 * prec * rec / (prec + rec) if (prec + rec) > 0 else 0
                avg_err = np.mean(pos_errors) if pos_errors else 0
                avg_ms = (total_time / total_images) * 1000

                grand_tp += tp_total
                grand_fp += fp_total
                grand_fn += fn_total
                grand_errors.extend(pos_errors)

    # Summary
    prec = grand_tp / (grand_tp + grand_fp) if (grand_tp + grand_fp) > 0 else 0
    rec = grand_tp / (grand_tp + grand_fn) if (grand_tp + grand_fn) > 0 else 0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) > 0 else 0
    avg_err = np.mean(grand_errors) if grand_errors else 0
    avg_ms = (total_time / total_images) * 1000
    total_gt = grand_tp + grand_fn

    print("-" * 82)
    print(f"TOTAL: {total_images} images, {total_gt} stars")
    print(f"  Precision:  {prec:.4f} ({grand_fp} false positives)")
    print(f"  Recall:     {rec:.4f} ({grand_fn} missed)")
    print(f"  F1:         {f1:.4f}")
    print(f"  Pos Error:  {avg_err:.3f} px (avg)")
    print(f"  Inference:  {avg_ms:.1f} ms/image (avg)")
    print()

    # Per-SNR summary
    print("Per-SNR summary (all star counts and FWHMs combined):")
    print(f"{'SNR':>6}  {'Prec':>6}  {'Recall':>6}  {'F1':>6}")
    print("-" * 30)

    rng2 = np.random.default_rng(777)
    for snr in snr_levels:
        tp_s, fp_s, fn_s = 0, 0, 0
        for n_stars in star_counts:
            for fwhm in fwhm_values:
                for _ in range(samples_per_level):
                    sky_bg = rng2.uniform(0.02, 0.25)
                    read_noise = rng2.uniform(0.005, 0.04)
                    image, gt = generate_test_starfield(
                        input_size, n_stars, snr, fwhm,
                        sky_bg=sky_bg, read_noise=read_noise, rng=rng2,
                    )
                    input_array = image.reshape(1, 1, input_size, input_size)
                    result = model.predict({"image": input_array})
                    heatmap = np.array(result["heatmap"]).reshape(input_size, input_size).astype(np.float32)
                    pred_coords = detect_stars(heatmap, threshold=0.3)
                    tp, fp, fn, _ = match_stars(pred_coords, gt)
                    tp_s += tp
                    fp_s += fp
                    fn_s += fn
        p = tp_s / (tp_s + fp_s) if (tp_s + fp_s) > 0 else 0
        r = tp_s / (tp_s + fn_s) if (tp_s + fn_s) > 0 else 0
        f = 2 * p * r / (p + r) if (p + r) > 0 else 0
        print(f"{snr:6.1f}  {p:6.3f}  {r:6.3f}  {f:6.3f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test StarDetector CoreML model on macOS")
    parser.add_argument("--model", default="StarDetector.mlpackage", help="Path to .mlpackage")
    parser.add_argument("--samples", type=int, default=50, help="Samples per SNR/stars/FWHM combo")
    args = parser.parse_args()

    run_test(args.model, args.samples)
