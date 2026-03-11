#!/usr/bin/env python3
"""
Export trained PyTorch ELUNet to Core ML format.

Output: StarDetector.mlpackage (float16, optimized for Neural Engine)
"""

import numpy as np
import torch
import coremltools as ct
from train import ELUNet


def export(
    checkpoint_path: str = "checkpoints/star_detector.pth",
    output_path: str = "StarDetector.mlpackage",
    input_size: int = 256,
):
    # Load model
    model = ELUNet()
    model.load_state_dict(torch.load(checkpoint_path, map_location="cpu"))
    model.eval()

    param_count = sum(p.numel() for p in model.parameters())
    print(f"Model parameters: {param_count:,}")

    # Trace model
    example_input = torch.randn(1, 1, input_size, input_size)
    traced = torch.jit.trace(model, example_input)

    # Convert to Core ML
    # Use TensorType for input so Swift can pass MLMultiArray directly.
    # Neural Engine is still used when computeUnits = .all.
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="image",
                shape=(1, 1, input_size, input_size),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name="heatmap")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )

    # Set model metadata
    mlmodel.author = "PolarAligner"
    mlmodel.short_description = "Star detection heatmap from grayscale starfield image"
    mlmodel.version = "1.0"

    mlmodel.save(output_path)
    print(f"Core ML model saved to {output_path}")

    # Verify
    print("\nModel spec:")
    spec = mlmodel.get_spec()
    for inp in spec.description.input:
        print(f"  Input: {inp.name} {inp.type}")
    for out in spec.description.output:
        print(f"  Output: {out.name} {out.type}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Export star detector to Core ML")
    parser.add_argument("--checkpoint", default="checkpoints/star_detector.pth")
    parser.add_argument("--output", default="StarDetector.mlpackage")
    parser.add_argument("--size", type=int, default=256)
    args = parser.parse_args()

    export(args.checkpoint, args.output, args.size)
