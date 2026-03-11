#!/usr/bin/env python3
"""
Train the ELUNet star detection model.

Architecture: ELUNet (Efficient Lightweight UNet)
- ~0.8M parameters
- Input: 1x256x256 grayscale
- Output: 1x256x256 heatmap (star positions as Gaussian peaks)
- Target inference: ~3-5ms on Apple Neural Engine

Reference: Zhao et al., "Star Detection and Centroiding with CNNs"
"""

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import Dataset, DataLoader
import numpy as np
from pathlib import Path


class ConvBlock(nn.Module):
    """Conv → BatchNorm → ELU"""

    def __init__(self, in_ch, out_ch):
        super().__init__()
        self.conv = nn.Sequential(
            nn.Conv2d(in_ch, out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ELU(inplace=True),
            nn.Conv2d(out_ch, out_ch, 3, padding=1, bias=False),
            nn.BatchNorm2d(out_ch),
            nn.ELU(inplace=True),
        )

    def forward(self, x):
        return self.conv(x)


class ELUNet(nn.Module):
    """
    Efficient Lightweight UNet for star detection.

    Encoder: 4 stages with max pooling
    Decoder: 4 stages with bilinear upsampling + skip connections
    """

    def __init__(self, in_channels=1, out_channels=1, base_filters=16):
        super().__init__()
        f = base_filters  # 16

        # Encoder
        self.enc1 = ConvBlock(in_channels, f)      # 16
        self.enc2 = ConvBlock(f, f * 2)             # 32
        self.enc3 = ConvBlock(f * 2, f * 4)         # 64
        self.enc4 = ConvBlock(f * 4, f * 8)         # 128

        # Bottleneck
        self.bottleneck = ConvBlock(f * 8, f * 16)  # 256

        # Decoder
        self.up4 = nn.Conv2d(f * 16, f * 8, 1)
        self.dec4 = ConvBlock(f * 16, f * 8)

        self.up3 = nn.Conv2d(f * 8, f * 4, 1)
        self.dec3 = ConvBlock(f * 8, f * 4)

        self.up2 = nn.Conv2d(f * 4, f * 2, 1)
        self.dec2 = ConvBlock(f * 4, f * 2)

        self.up1 = nn.Conv2d(f * 2, f, 1)
        self.dec1 = ConvBlock(f * 2, f)

        # Output
        self.out_conv = nn.Conv2d(f, out_channels, 1)

        self.pool = nn.MaxPool2d(2)

    def forward(self, x):
        # Encoder
        e1 = self.enc1(x)
        e2 = self.enc2(self.pool(e1))
        e3 = self.enc3(self.pool(e2))
        e4 = self.enc4(self.pool(e3))

        # Bottleneck
        b = self.bottleneck(self.pool(e4))

        # Decoder with skip connections
        d4 = self.up4(F.interpolate(b, scale_factor=2, mode="bilinear", align_corners=False))
        d4 = self.dec4(torch.cat([d4, e4], dim=1))

        d3 = self.up3(F.interpolate(d4, scale_factor=2, mode="bilinear", align_corners=False))
        d3 = self.dec3(torch.cat([d3, e3], dim=1))

        d2 = self.up2(F.interpolate(d3, scale_factor=2, mode="bilinear", align_corners=False))
        d2 = self.dec2(torch.cat([d2, e2], dim=1))

        d1 = self.up1(F.interpolate(d2, scale_factor=2, mode="bilinear", align_corners=False))
        d1 = self.dec1(torch.cat([d1, e1], dim=1))

        return torch.sigmoid(self.out_conv(d1))


class StarfieldDataset(Dataset):
    """Loads pre-generated .npy starfield images and heatmap labels."""

    def __init__(self, data_dir: str):
        self.images_dir = Path(data_dir) / "images"
        self.labels_dir = Path(data_dir) / "labels"
        self.files = sorted(self.images_dir.glob("*.npy"))

    def __len__(self):
        return len(self.files)

    def __getitem__(self, idx):
        fname = self.files[idx].name
        image = np.load(self.images_dir / fname).astype(np.float32)
        label = np.load(self.labels_dir / fname).astype(np.float32)

        # Add channel dimension: (H, W) → (1, H, W)
        image = image[np.newaxis, ...]
        label = label[np.newaxis, ...]

        return torch.from_numpy(image), torch.from_numpy(label)


def train(
    data_dir: str = "data/train",
    val_dir: str = "data/val",
    epochs: int = 50,
    batch_size: int = 32,
    lr: float = 1e-3,
    device_str: str = "mps",  # Apple Silicon GPU
    save_path: str = "checkpoints/star_detector.pth",
):
    device = torch.device(device_str if torch.backends.mps.is_available() else "cpu")
    print(f"Training on {device}")

    model = ELUNet().to(device)
    param_count = sum(p.numel() for p in model.parameters())
    print(f"Model parameters: {param_count:,}")

    train_dataset = StarfieldDataset(data_dir)
    train_loader = DataLoader(train_dataset, batch_size=batch_size, shuffle=True, num_workers=0)

    val_dataset = StarfieldDataset(val_dir) if Path(val_dir).exists() else None
    val_loader = DataLoader(val_dataset, batch_size=batch_size, num_workers=0) if val_dataset else None

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=epochs)

    # Combined loss: BCE + Dice for heatmap regression
    bce_loss = nn.BCELoss()

    def dice_loss(pred, target, smooth=1e-6):
        pred_flat = pred.view(-1)
        target_flat = target.view(-1)
        intersection = (pred_flat * target_flat).sum()
        return 1 - (2.0 * intersection + smooth) / (pred_flat.sum() + target_flat.sum() + smooth)

    Path(save_path).parent.mkdir(parents=True, exist_ok=True)
    best_val_loss = float("inf")

    for epoch in range(epochs):
        model.train()
        train_loss = 0.0

        for images, labels in train_loader:
            images, labels = images.to(device), labels.to(device)

            pred = model(images)
            loss = bce_loss(pred, labels) + dice_loss(pred, labels)

            optimizer.zero_grad()
            loss.backward()
            optimizer.step()

            train_loss += loss.item()

        scheduler.step()
        avg_train = train_loss / len(train_loader)

        # Validation
        if val_loader:
            model.eval()
            val_loss = 0.0
            with torch.no_grad():
                for images, labels in val_loader:
                    images, labels = images.to(device), labels.to(device)
                    pred = model(images)
                    loss = bce_loss(pred, labels) + dice_loss(pred, labels)
                    val_loss += loss.item()
            avg_val = val_loss / len(val_loader)

            if avg_val < best_val_loss:
                best_val_loss = avg_val
                torch.save(model.state_dict(), save_path)
                print(f"Epoch {epoch+1}/{epochs}: train={avg_train:.4f} val={avg_val:.4f} [saved]")
            else:
                print(f"Epoch {epoch+1}/{epochs}: train={avg_train:.4f} val={avg_val:.4f}")
        else:
            torch.save(model.state_dict(), save_path)
            print(f"Epoch {epoch+1}/{epochs}: train={avg_train:.4f} [saved]")

    print(f"Training complete. Best model saved to {save_path}")


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Train star detection UNet")
    parser.add_argument("--data", default="data/train", help="Training data directory")
    parser.add_argument("--val", default="data/val", help="Validation data directory")
    parser.add_argument("--epochs", type=int, default=50)
    parser.add_argument("--batch-size", type=int, default=32)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--save", default="checkpoints/star_detector.pth")
    args = parser.parse_args()

    train(args.data, args.val, args.epochs, args.batch_size, args.lr, args.device, args.save)
