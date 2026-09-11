"""
VelocityCNN Training Script
Trains 1D Temporal CNN on IO-VNBD sequences for forward speed and stationary prediction.
Input: 6-channel normalized IMU [ax, ay, az, gx, gy, gz] of length 200 (2.0s @ 100Hz).
Outputs: Forward velocity (m/s) + Stationary detection logit.
"""

import os
import sys
import json
import time
import argparse
from pathlib import Path
import numpy as np
import pandas as pd
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader

from model import VelocityCNN

# Configuration & Paths
SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
NORM_PARAMS_PATH = PROJECT_ROOT / "app_updated" / "app" / "assets" / "models" / "norm_params.json"
DEFAULT_DATA_PATH = PROJECT_ROOT / "app_updated" / "app" / "assets" / "demo" / "test_dataset.csv"
CHECKPOINT_DIR = SCRIPT_DIR / "checkpoints"
CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)


class ImuWindowDataset(Dataset):
    """
    Constructs normalized sliding windows of size 200 (2.0 seconds at 100 Hz)
    from calibrated vehicular IMU sequences.
    """
    def __init__(self, df: pd.DataFrame, window_size: int = 200, step_size: int = 10,
                 means: list = None, stds: list = None):
        self.window_size = window_size
        
        # 6 IMU Channels: Linear Accel (ax, ay, az) + Gyro (gx, gy, gz)
        imu_cols = ['accel_x', 'accel_y', 'accel_z', 'gyro_x', 'gyro_y', 'gyro_z']
        raw_imu = df[imu_cols].values.astype(np.float32)

        # Ground truth speeds and stationary states
        if 'gt_speed' in df.columns:
            speeds = df['gt_speed'].values.astype(np.float32)
        elif 'gnss_speed' in df.columns:
            speeds = df['gnss_speed'].values.astype(np.float32)
        else:
            speeds = np.zeros(len(df), dtype=np.float32)

        # Normalization using pre-calculated statistics
        if means is not None and stds is not None:
            means = np.array(means, dtype=np.float32)
            stds = np.array(stds, dtype=np.float32)
            norm_imu = (raw_imu - means) / stds
        else:
            norm_imu = raw_imu

        self.windows = []
        self.targets_vel = []
        self.targets_stat = []

        n_samples = len(df)
        for start in range(0, n_samples - window_size + 1, step_size):
            end = start + window_size
            # Shape: [200, 6] -> transpose to [6, 200] (channels-first)
            win = norm_imu[start:end].T
            self.windows.append(win)

            # Target is the vehicle speed at the end of the window
            target_speed = max(0.0, float(speeds[end - 1]))
            self.windows.append(win)
            self.targets_vel.append(target_speed)
            # Stationary label: speed < 0.2 m/s
            self.targets_stat.append(1.0 if target_speed < 0.2 else 0.0)

        # Deduplicate window entries
        self.windows = np.array(self.windows[::2], dtype=np.float32)
        self.targets_vel = np.array(self.targets_vel, dtype=np.float32)
        self.targets_stat = np.array(self.targets_stat, dtype=np.float32)

    def __len__(self):
        return len(self.windows)

    def __getitem__(self, idx):
        return (
            torch.tensor(self.windows[idx], dtype=torch.float32),
            torch.tensor(self.targets_vel[idx], dtype=torch.float32),
            torch.tensor(self.targets_stat[idx], dtype=torch.float32),
        )


def load_norm_params():
    if NORM_PARAMS_PATH.exists():
        with open(NORM_PARAMS_PATH, 'r') as f:
            params = json.load(f)
        return params['means'], params['stds']
    # Default fallbacks
    return [0.0] * 6, [1.0] * 6


def train(epochs: int = 25, batch_size: int = 64, lr: float = 1e-3, data_path: Path = DEFAULT_DATA_PATH):
    device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
    print(f"Training VelocityCNN on device: {device}")

    means, stds = load_norm_params()
    print(f"Loaded normalization parameters from {NORM_PARAMS_PATH}")

    # Load dataset
    print(f"Loading sequence from {data_path}...")
    df = pd.read_csv(data_path)
    print(f"Loaded {len(df)} rows.")

    # 80/20 train/val split by chronological sequence
    split_idx = int(len(df) * 0.8)
    train_df = df.iloc[:split_idx].reset_index(drop=True)
    val_df = df.iloc[split_idx:].reset_index(drop=True)

    train_ds = ImuWindowDataset(train_df, means=means, stds=stds)
    val_ds = ImuWindowDataset(val_df, means=means, stds=stds)

    print(f"Train windows: {len(train_ds)}, Val windows: {len(val_ds)}")

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size, shuffle=False)

    model = VelocityCNN(in_channels=6, seq_len=200).to(device)
    criterion_mse = nn.MSELoss()
    criterion_bce = nn.BCEWithLogitsLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.ReduceLROnPlateau(optimizer, mode='min', factor=0.5, patience=3)

    best_val_rmse = float('inf')
    best_checkpoint = CHECKPOINT_DIR / "velocity_cnn_best.pt"

    for epoch in range(1, epochs + 1):
        model.train()
        train_loss = 0.0
        train_sq_err = 0.0
        total_train = 0

        for x_b, vel_b, stat_b in train_loader:
            x_b, vel_b, stat_b = x_b.to(device), vel_b.to(device), stat_b.to(device)

            optimizer.zero_grad()
            pred_vel, pred_stat_logit = model(x_b)

            loss_v = criterion_mse(pred_vel, vel_b)
            loss_s = criterion_bce(pred_stat_logit, stat_b)
            loss = loss_v + 0.5 * loss_s

            loss.backward()
            optimizer.step()

            train_loss += loss.item() * len(vel_b)
            train_sq_err += ((pred_vel - vel_b) ** 2).sum().item()
            total_train += len(vel_b)

        train_rmse = np.sqrt(train_sq_err / max(1, total_train))

        # Validation
        model.eval()
        val_sq_err = 0.0
        total_val = 0
        with torch.no_grad():
            for x_b, vel_b, stat_b in val_loader:
                x_b, vel_b, stat_b = x_b.to(device), vel_b.to(device), stat_b.to(device)
                pred_vel, _ = model(x_b)
                val_sq_err += ((pred_vel - vel_b) ** 2).sum().item()
                total_val += len(vel_b)

        val_rmse = np.sqrt(val_sq_err / max(1, total_val))
        scheduler.step(val_rmse)

        is_best = val_rmse < best_val_rmse
        if is_best:
            best_val_rmse = val_rmse
            torch.save({
                'epoch': epoch,
                'model_state_dict': model.state_dict(),
                'val_rmse': val_rmse,
                'means': means,
                'stds': stds,
            }, best_checkpoint)

        best_mark = " (★ Best)" if is_best else ""
        print(f"Epoch {epoch:2d}/{epochs:2d} | Train RMSE: {train_rmse:5.2f} m/s ({train_rmse*3.6:5.2f} km/h) | "
              f"Val RMSE: {val_rmse:5.2f} m/s ({val_rmse*3.6:5.2f} km/h){best_mark}")

    print(f"\nTraining Complete. Best model saved to: {best_checkpoint}")
    return best_checkpoint


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Train VelocityCNN on IO-VNBD dataset")
    parser.add_argument('--epochs', type=int, default=15, help="Number of training epochs")
    parser.add_argument('--batch_size', type=int, default=64, help="Batch size")
    parser.add_argument('--lr', type=float, default=1e-3, help="Learning rate")
    parser.add_argument('--data', type=str, default=str(DEFAULT_DATA_PATH), help="Path to input CSV dataset")
    args = parser.parse_args()

    train(epochs=args.epochs, batch_size=args.batch_size, lr=args.lr, data_path=Path(args.data))
