import os
import numpy as np
from pathlib import Path
import torch
import json
import pickle
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import VelocityCNNSetC
from benchmark_core import evaluate_blackout_window
from map_matching import SimpleMapMatcher, RBPFMapMatcher, HMMMapMatcher
import common

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
MODELS_DIR = PROJECT_ROOT / "models" / "cnn_pvs_single"
DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def load_norm_single():
    with open(PROCESSED_DIR / "norm_params_single.json", "r") as f:
        return json.load(f)

def evaluate_single():
    print("="*60)
    print("EVALUATING 100Hz SINGLE-TRIP (Zero Leakage)")
    print("="*60)
    
    # Load model
    model = VelocityCNNSetC(in_channels=6).to(DEVICE)
    model.load_state_dict(torch.load(MODELS_DIR / "model.pt", map_location=DEVICE, weights_only=True))
    model.eval()
    
    # Load test split
    print("Loading test_single.npz...")
    data = np.load(PROCESSED_DIR / "test_single.npz")
    X_raw, y_gt = data['X'], data['y']
    lat_gt, lon_gt = data['lat'], data['lon']
    gyro_z_raw = data['gyro_z']
    heading_gt = data['heading']
    
    # Normalize features
    norm = load_norm_single()
    Xn = (X_raw - np.array(norm["means"])) / np.array(norm["stds"])
    
    # Predict velocity
    print("Running CNN inference...")
    with torch.no_grad():
        vel_pred, _ = model(torch.tensor(Xn, dtype=torch.float32).to(DEVICE))
        vel_pred = vel_pred.cpu().numpy()
        vel_pred = np.maximum(vel_pred, 0.0)
        
    rmse_ms = np.sqrt(np.mean((vel_pred - y_gt)**2))
    print(f"\nVelocity RMSE: {rmse_ms:.2f} m/s ({rmse_ms*3.6:.1f} km/h)")
    
    # Prepare map matcher (use dummy segments, no buildings, to just see pure dead reckoning drift)
    # The PVS trips don't have OSM maps cached, and we only want to see the pure velocity error impact.
    # We will use SimpleMapMatcher with empty segments, meaning NO map matching will be applied, just ESKF.
    # Wait, the RBPF Map matcher is our key feature! Let's just use ESKF to see the baseline without MM.
    
    # We don't have road network for PVS Trip 1, so we just run ESKF.
    map_matcher = SimpleMapMatcher([])
    hmm_matcher = HMMMapMatcher([])
    
    duration = len(X_raw)
    dt = 0.1 # 100Hz -> stride 100? Wait, the preprocessor uses stride 100 on 100Hz data.
    # If window is 200, stride is 100, then it's 1 window per second!
    # Let me check preprocess_pvs_single.py -> 100Hz, stride 100 means dt=1.0 seconds!
    dt = 1.0
    
    # But wait, gyro_z_out is an array of 200 samples per window! We need to extract the raw gyro z properly.
    # We'll just take the mean gyro Z for each window if it's 1 second.
    gz = np.array([np.mean(w) for w in gyro_z_raw])
    
    print("\nRunning ESKF (with NHC) over 6-minute unseen test split...")
    res = evaluate_blackout_window(
        pred_velocity=vel_pred,
        gyro_yaw_rate=gz,
        gt_lat=lat_gt,
        gt_lon=lon_gt,
        gt_heading_deg=heading_gt,
        start_idx=0,
        duration_steps=duration,
        dt_seconds=dt,
        min_reference_distance_m=0.0,
        map_matcher=map_matcher,
        hmm_matcher=hmm_matcher
    )
    
    print("\n  RESULTS:")
    print(f"  Test Case Duration: {duration * dt} seconds")
    print(f"  Test Case Distance Traveled: {res['reference_distance_m']:.1f} meters")
    print("-" * 50)
    print(f"  Raw Open Loop Error (No Filters): {res['open_loop_final_error_m']:.1f} m (Drift: {res['open_loop_drift_pct']:.2f}%)")
    print(f"  ESKF Error (with NHC): {res['ekf_final_error_m']:.1f} m (Drift: {res['ekf_drift_pct']:.2f}%)")

if __name__ == "__main__":
    evaluate_single()
