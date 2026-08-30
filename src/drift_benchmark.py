"""
Phase 3: Drift Benchmark
Evaluate the IDR pipeline during a simulated 60s GNSS blackout on a held-out test trip (A5).
"""
import torch
import numpy as np
import pandas as pd
import json
from ekf import EKF
from pathlib import Path
from models import VelocityCNN
from dead_reckoning import DeadReckoningIntegrator
from map_matching import haversine
import common

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
CHECKPOINT_DIR = PROJECT_ROOT / "results" / "model_checkpoints"

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def load_test_trip(trip_id='A5'):
    """Load the raw synchronized data for the test trip."""
    with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
        manifest = json.load(f)
        
    info = manifest['trips'][trip_id]
    
    # We need the raw GPS coordinates and the model inputs
    # To get this, we'll use the processed .npz to ensure we test exactly what the model sees
    test_data = np.load(PROCESSED_DIR / "test.npz")
    
    mask = test_data['trip_id'] == trip_id
    X = test_data['X'][mask]
    y_true = test_data['y'][mask] # Ground truth velocity
    
    # We also need the raw S-file to get the ground truth GPS coordinates
    # to evaluate drift against.
    s_path = DATASET_ROOT / info['s_file']
    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]
    
    lat_col = [c for c in s_df.columns if 'latitude' in c.lower()][0]
    lon_col = [c for c in s_df.columns if 'longitude' in c.lower()][0]
    head_col = [c for c in s_df.columns if 'orientation' in c.lower() and 'gps' in c.lower()][0]
    
    lats = pd.to_numeric(s_df[lat_col], errors='coerce').values
    lons = pd.to_numeric(s_df[lon_col], errors='coerce').values
    headings = pd.to_numeric(s_df[head_col], errors='coerce').values
    
    # Align windows to raw GPS using timestamps.
    # Processed timestamps (ms) were saved in the .npz file.
    raw_time_col = [c for c in s_df.columns if ('time' in c.lower() and ('ms' in c.lower() or 'since' in c.lower()))][0]
    raw_timestamps = pd.to_numeric(s_df[raw_time_col], errors='coerce').values
    # Ensure raw timestamps are sorted; if not, sort together with lat/lon/headings.
    sort_idx = np.argsort(raw_timestamps)
    raw_times_sorted = raw_timestamps[sort_idx]
    lats = lats[sort_idx]
    lons = lons[sort_idx]
    headings = headings[sort_idx]

    # Load processed timestamps for the windows
    timestamps = test_data['timestamps'][mask]

    # Find nearest raw index for each window timestamp
    indices = np.searchsorted(raw_times_sorted, timestamps, side='left')
    # Clip to valid range
    indices = np.clip(indices, 0, len(raw_times_sorted)-1)

    gt_lats = lats[indices]
    gt_lons = lons[indices]
    gt_headings = headings[indices]
    
    return X, y_true, gt_lats, gt_lons, gt_headings

def run_benchmark():
    print("="*60)
    print("IDR DRIFT BENCHMARK (Multi-Window Randomized)")
    print("="*60)
    print("Evaluating over trips A5 and T2 with random blackout windows.")
    
    # 1. Evaluate only the ensemble model
    import evaluate_all
    _, _, predict_fn = evaluate_all.load_model("ensemble")

    
    with open(PROCESSED_DIR / "norm_params.json", "r") as f:
        norm_params = json.load(f)
    yaw_idx = norm_params['channels'].index('Gyroscope Yaw')
    yaw_mean = norm_params['means'][yaw_idx]
    yaw_std = norm_params['stds'][yaw_idx]
    
    all_results = []
    
    for trip in ['A5', 'T2']:
        print(f"\nEvaluating Trip {trip}...")
        X, y_true, gt_lats, gt_lons, gt_headings = load_test_trip(trip)
        
        X_raw = X
        norm = common.load_norm_params()
        Xn = (X_raw - np.array(norm["means"])) / np.array(norm["stds"])
        pred_vel_full = predict_fn(Xn)
        raw_yaw_rates_full = X[:, 10, yaw_idx] * yaw_std + yaw_mean
        
        for duration_s in [30, 60, 90]:
            if len(X) <= duration_s:
                continue
                
            # Compute cumulative ground-truth distance to filter windows
            cum_dist = np.concatenate([[0.0], np.cumsum([haversine(gt_lons[i], gt_lats[i],
                                                             gt_lons[i+1], gt_lats[i+1])
                                                  for i in range(len(gt_lats)-1)])])
                                                  
            valid_starts = [s for s in range(0, len(X) - duration_s)
                            if cum_dist[s + duration_s] - cum_dist[s] >= 0.0]
                            
            if not valid_starts:
                continue
                
            np.random.seed(42)  # For reproducibility
            picks = np.random.choice(valid_starts, size=min(15, len(valid_starts)), replace=False)
            
            for start_idx in picks:
                end_idx = start_idx + duration_s
                
                init_lat = gt_lats[start_idx]
                init_lon = gt_lons[start_idx]
                init_heading_rad = np.radians(gt_headings[start_idx])
                
                dr = DeadReckoningIntegrator(init_lat, init_lon, init_heading_rad)
                ekf = EKF(init_lat, init_lon, init_heading_rad)
                
                total_distance_traveled = 0.0
                for i in range(len(X)):
                    dt = 1.0
                    ekf.predict(dt=dt, ml_velocity=pred_vel_full[i], gyro_yaw_rate=raw_yaw_rates_full[i])
                    if i < start_idx or i >= end_idx:
                        ekf.update_gps(gt_lats[i], gt_lons[i])
                    if start_idx <= i < end_idx:
                        dr.step(pred_vel_full[i], raw_yaw_rates_full[i], dt)
                        total_distance_traveled += y_true[i] * dt
                        
                final_dr_lat, final_dr_lon = dr.lat, dr.lon
                final_ekf_lat, final_ekf_lon = ekf.get_latlon()
                final_gt_lat = gt_lats[end_idx]
                final_gt_lon = gt_lons[end_idx]
                
                drift_m_open = haversine(final_dr_lon, final_dr_lat, final_gt_lon, final_gt_lat)
                drift_m_ekf = haversine(final_ekf_lon, final_ekf_lat, final_gt_lon, final_gt_lat)
                
                drift_pct_open = (drift_m_open / total_distance_traveled) * 100 if total_distance_traveled > 0 else 0
                drift_pct_ekf = (drift_m_ekf / total_distance_traveled) * 100 if total_distance_traveled > 0 else 0
                
                all_results.append({
                    "trip": trip,
                    "duration_s": duration_s,
                    "ekf_drift_pct": drift_pct_ekf,
                    "open_drift_pct": drift_pct_open
                })
                
    df_res = pd.DataFrame(all_results)
    
    print("\n" + "="*60)
    print("MULTI-WINDOW DRIFT RESULTS")
    print("="*60)
    
    overall_median = df_res['ekf_drift_pct'].median()
    overall_mean = df_res['ekf_drift_pct'].mean()
    overall_std = df_res['ekf_drift_pct'].std()
    
    print(f"Overall EKF Drift: {overall_mean:.2f}% ± {overall_std:.2f}% (Median: {overall_median:.2f}%)")
    
    for trip in df_res['trip'].unique():
        for duration in df_res['duration_s'].unique():
            sub = df_res[(df_res['trip'] == trip) & (df_res['duration_s'] == duration)]
            if len(sub) > 0:
                print(f"  {trip} - {duration}s: {sub['ekf_drift_pct'].mean():.2f}% ± {sub['ekf_drift_pct'].std():.2f}% (n={len(sub)})")
                
    overall_pass = overall_median < 10.0
    print("\nBENCHMARK STATUS:")
    if overall_pass:
        print("  PASS: Median EKF drift < 10% (SIH target)")
    else:
        print("  FAIL: Median EKF drift exceeds 10% target")

if __name__ == "__main__":
    run_benchmark()
