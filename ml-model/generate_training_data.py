#!/usr/bin/env python3
"""
Generate synthetic starfield training data for the star detection UNet.

Each sample consists of:
- Input: 256x256 grayscale image with synthetic stars + realistic noise
- Label: 256x256 heatmap with Gaussian peaks at star positions

Stars are modeled as 2D Gaussians with varying FWHM (1.5-5 pixels),
brightness (SNR 3-50), and sky background levels. Noise includes:
- Poisson shot noise
- Gaussian read noise
- Hot pixels
- Gradient background (light pollution)
"""

import numpy as np
import os
from pathlib import Path


def generate_psf(size: int, fwhm: float, x: float, y: float) -> np.ndarray:
    """Generate a 2D Gaussian PSF centered at (x, y) within a (size x size) grid."""
    sigma = fwhm / 2.355
    yy, xx = np.mgrid[0:size, 0:size]
    psf = np.exp(-((xx - x) ** 2 + (yy - y) ** 2) / (2 * sigma**2))
    return psf


def generate_starfield(
    size: int = 256,
    n_stars_range: tuple = (5, 50),
    fwhm_range: tuple = (1.5, 5.0),
    snr_range: tuple = (3.0, 50.0),
    sky_background: float = 0.1,
    read_noise: float = 0.02,
    hot_pixel_fraction: float = 0.0005,
    gradient_strength: float = 0.05,
    rng: np.random.Generator = None,
) -> tuple:
    """
    Generate a synthetic starfield image and corresponding heatmap label.

    Returns:
        (image, heatmap, star_positions)
        image: (size, size) float32, normalized [0, 1]
        heatmap: (size, size) float32, Gaussian peaks at star positions
        star_positions: list of (x, y, brightness, fwhm)
    """
    if rng is None:
        rng = np.random.default_rng()

    # Sky background with gradient (light pollution simulation)
    yy, xx = np.mgrid[0:size, 0:size] / size
    gradient = gradient_strength * (
        rng.uniform(-1, 1) * xx + rng.uniform(-1, 1) * yy
    )
    sky = sky_background + gradient
    sky = np.clip(sky, 0, None)

    image = sky.copy().astype(np.float64)
    heatmap = np.zeros((size, size), dtype=np.float32)

    # Generate stars
    n_stars = rng.integers(n_stars_range[0], n_stars_range[1] + 1)
    star_positions = []
    label_sigma = 1.5  # Sigma for heatmap Gaussian labels

    for _ in range(n_stars):
        x = rng.uniform(5, size - 5)
        y = rng.uniform(5, size - 5)
        fwhm = rng.uniform(fwhm_range[0], fwhm_range[1])
        snr = rng.uniform(snr_range[0], snr_range[1])

        # Convert SNR to peak brightness
        sigma = fwhm / 2.355
        noise_level = np.sqrt(sky_background + read_noise**2)
        peak_brightness = snr * noise_level

        # Add star PSF to image
        psf = generate_psf(size, fwhm, x, y)
        image += peak_brightness * psf

        # Add Gaussian label to heatmap
        label = generate_psf(size, label_sigma * 2.355, x, y)
        heatmap = np.maximum(heatmap, label.astype(np.float32))

        star_positions.append((x, y, peak_brightness, fwhm))

    # Add Poisson shot noise (signal-dependent)
    # Scale to ADU counts for Poisson sampling
    adu_scale = 1000.0
    image_adu = np.clip(image * adu_scale, 0, None)
    image_noisy = rng.poisson(image_adu).astype(np.float64) / adu_scale

    # Add Gaussian read noise
    image_noisy += rng.normal(0, read_noise, (size, size))

    # Add hot pixels
    n_hot = int(size * size * hot_pixel_fraction)
    hot_x = rng.integers(0, size, n_hot)
    hot_y = rng.integers(0, size, n_hot)
    image_noisy[hot_y, hot_x] = rng.uniform(0.5, 1.0, n_hot)

    # Normalize to [0, 1]
    image_noisy = np.clip(image_noisy, 0, 1).astype(np.float32)

    return image_noisy, heatmap, star_positions


def generate_dataset(
    output_dir: str,
    n_samples: int = 10000,
    size: int = 256,
    seed: int = 42,
):
    """Generate a training dataset of synthetic starfields."""
    output_path = Path(output_dir)
    images_dir = output_path / "images"
    labels_dir = output_path / "labels"
    images_dir.mkdir(parents=True, exist_ok=True)
    labels_dir.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(seed)

    # Vary parameters to cover different observing conditions
    for i in range(n_samples):
        # Randomize conditions
        sky_bg = rng.uniform(0.02, 0.25)  # Light pollution range
        read_noise = rng.uniform(0.005, 0.04)  # Camera noise
        fwhm_base = rng.uniform(1.5, 4.0)  # Seeing conditions
        gradient = rng.uniform(0, 0.1)

        image, heatmap, _ = generate_starfield(
            size=size,
            sky_background=sky_bg,
            read_noise=read_noise,
            fwhm_range=(fwhm_base, fwhm_base + 1.5),
            gradient_strength=gradient,
            rng=rng,
        )

        np.save(images_dir / f"{i:06d}.npy", image)
        np.save(labels_dir / f"{i:06d}.npy", heatmap)

        if (i + 1) % 1000 == 0:
            print(f"Generated {i + 1}/{n_samples} samples")

    print(f"Dataset saved to {output_dir}")
    print(f"  Images: {images_dir}")
    print(f"  Labels: {labels_dir}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate synthetic starfield training data")
    parser.add_argument("--output", default="data/train", help="Output directory")
    parser.add_argument("--samples", type=int, default=10000, help="Number of samples")
    parser.add_argument("--size", type=int, default=256, help="Image size")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    args = parser.parse_args()

    generate_dataset(args.output, args.samples, args.size, args.seed)
