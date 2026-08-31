import os
import sys
import json
import torch
import torch.nn as nn
from torch.utils.data import TensorDataset, DataLoader
import numpy as np
import pandas as pd
from pathlib import Path

# Add project root to path so we can import modules
from models_lib import VelocityCNN, apply_random_rotation
from benchmark_core import evaluate_blackout_window
import dataset


DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
PROJECT_ROOT = Path(__file__).resolve().parent.parent
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

def load_data():
    train = np.load(PROCESSED_DIR / "train.npz")
    val = np.load(PROCESSED_DIR / "val.npz")
    test = np.load(PROCESSED_DIR / "test.npz")
    return train['X'], train['y'], val['X'], val['y'], test['X'], test['y']

def get_norm_stats():
    with open(PROCESSED_DIR / "norm_params.json", "r") as f:
        norm_params = json.load(f)
    return (
        torch.tensor(norm_params['means'], dtype=torch.float32, device=DEVICE),
        torch.tensor(norm_params['stds'], dtype=torch.float32, device=DEVICE)
    )

def evaluate_drift(model, use_zupt):
    model.eval()
    
    trip_id = "T2"
    sync_df = dataset.load_synced_trip(trip_id)
    if sync_df is None or len(sync_df) == 0:
        return 0, 0
        
    windows = dataset.build_trip_windows(sync_df, trip_id)
    if not windows or len(windows['raw']) == 0:
        return 0, 0
        
    X_tensor = torch.tensor(windows['raw'], dtype=torch.float32, device=DEVICE)
    means, stds = get_norm_stats()
    X_tensor = (X_tensor - means) / stds
    
    with torch.no_grad():
        vel_preds, stat_logits = model(X_tensor)
        vel_preds = vel_preds.cpu().numpy()
        stat_probs = torch.sigmoid(stat_logits).cpu().numpy()
        
    if use_zupt:
        vel_preds[stat_probs > 0.95] = 0.0
        
    dt_seconds = 1.0
    duration_s = 60
    duration_steps = int(duration_s / dt_seconds)
    
    drifts = []
    
    max_start = len(windows['raw']) - duration_steps
    if max_start > 0:
        for seed in [42, 123, 2024]:
            import random
            random.seed(seed)
            np.random.seed(seed)
            valid_starts = list(range(0, max_start))
            picks = np.random.choice(valid_starts, size=min(15, len(valid_starts)), replace=False)
            
            for start_idx in picks:
                res = evaluate_blackout_window(
                    pred_velocity=vel_preds[start_idx : start_idx + duration_steps],
                    gyro_yaw_rate=windows['gyro_z'][start_idx : start_idx + duration_steps],
                    gt_lat=windows['lat'][start_idx : start_idx + duration_steps],
                    gt_lon=windows['lon'][start_idx : start_idx + duration_steps],
                    gt_heading_deg=windows['heading'][start_idx : start_idx + duration_steps],
                    start_idx=start_idx,
                    duration_steps=duration_steps,
                    dt_seconds=dt_seconds,
                    min_reference_distance_m=300.0
                )
                if res is not None:
                    drifts.append(res["ekf_drift_pct"])
                
    if not drifts:
        return 0, 0
    return np.median(drifts), np.mean(drifts)

def run_ablation():
    X_train, y_train, X_val, y_val, X_test, y_test = load_data()
    means, stds = get_norm_stats()
    
    train_loader = DataLoader(
        TensorDataset(torch.tensor(X_train, dtype=torch.float32), 
                      torch.tensor(y_train, dtype=torch.float32)), 
        batch_size=128, shuffle=True
    )
    val_loader = DataLoader(
        TensorDataset(torch.tensor(X_test, dtype=torch.float32), 
                      torch.tensor(y_test, dtype=torch.float32)), 
        batch_size=128, shuffle=False
    )
    
    configs = [
        {"name": "Baseline", "use_zupt": False, "use_aug": False, "use_pinn": False},
        {"name": "+ ZUPT", "use_zupt": True, "use_aug": False, "use_pinn": False},
        {"name": "+ Domain Aug", "use_zupt": True, "use_aug": True, "use_pinn": False}
    ]
    
    results = []
    
    for config in configs:
        print(f"\nTraining {config['name']}...")
        model = VelocityCNN(in_channels=12).to(DEVICE)
        optimizer = torch.optim.Adam(model.parameters(), lr=1e-3)
        bce_criterion = nn.BCEWithLogitsLoss()
        
        # Train for just 15 epochs for rapid ablation testing
        for epoch in range(15):
            model.train()
            for X_b, y_b in train_loader:
                X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
                
                if config["use_aug"]:
                    X_b = apply_random_rotation(X_b, means, stds, max_angle_deg=15.0)
                
                optimizer.zero_grad()
                vel_preds, stat_logits = model(X_b)
                
                loss = torch.mean((vel_preds - y_b) ** 2)
                
                if config["use_zupt"]:
                    y_stat = (y_b < 0.2).float()
                    stat_loss = bce_criterion(stat_logits, y_stat)
                    loss += 0.1 * stat_loss
                    
                if config["use_pinn"]:
                    pred_disp = vel_preds * 2.0
                    true_disp = y_b * 2.0
                    physics_loss = torch.mean(torch.abs(pred_disp - true_disp))
                    loss += 0.5 * physics_loss
                    
                loss.backward()
                optimizer.step()
                
        # Eval Test RMSE
        model.eval()
        val_loss = 0.0
        with torch.no_grad():
            for X_b, y_b in val_loader:
                X_b, y_b = X_b.to(DEVICE), y_b.to(DEVICE)
                vel_preds, stat_logits = model(X_b)
                if config["use_zupt"]:
                    stat_probs = torch.sigmoid(stat_logits)
                    vel_preds[stat_probs > 0.95] = 0.0
                val_loss += torch.sum((vel_preds - y_b) ** 2).item()
                
        test_rmse = np.sqrt(val_loss / len(val_loader.dataset)) * 3.6
        
        median_drift, mean_drift = evaluate_drift(model, config["use_zupt"])
        
        results.append({
            "Model": config["name"],
            "Test RMSE (km/h)": test_rmse,
            "Median Drift (%)": median_drift,
            "Mean Drift (%)": mean_drift
        })
        print(f"  RMSE: {test_rmse:.2f} km/h | Median Drift: {median_drift:.2f}%")
        
    df = pd.DataFrame(results)
    print("\n" + "="*60)
    print("Ablation Study Results")
    print("="*60)
    print(df.to_string(index=False))
    
    df.to_csv(PROJECT_ROOT / "reports" / "ablation_metrics.csv", index=False)

if __name__ == "__main__":
    run_ablation()
