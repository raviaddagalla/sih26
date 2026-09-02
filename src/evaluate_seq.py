import torch
import numpy as np
import json
import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent))
import common
import dataset
from models_lib import StatefulGRU
from benchmark_core import evaluate_blackout_window
from fetch_osm_roads import fetch_road_network
from map_matching import SimpleMapMatcher, HMMMapMatcher

def load_model():
    save_dir = common.MODELS_DIR / "stateful_gru"
    
    with open(save_dir / "metadata.json", "r") as f:
        meta = json.load(f)
        
    model = StatefulGRU(in_channels=12, hidden=64, num_layers=2)
    model.load_state_dict(torch.load(save_dir / "model.pt", weights_only=True, map_location="cpu"))
    model.eval()
    
    return model, meta

def benchmark_trip_seq(model, meta, trip_id, outage_frac=1.0/3.0, duration_seconds=60):
    print(f"\nBenchmarking sequence GRU on {trip_id}...")
    sync = dataset.load_synced_trip(trip_id)
    n = len(sync)
    
    duration = duration_seconds * 10 # 10Hz
    start = min(int(n * outage_frac), n - duration)
    end = start + duration
    
    # Extract features
    feature_cols = [
        'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
        'Gravity X', 'Gravity Y', 'Gravity Z',
        'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
        'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
    ]
    
    X_raw = sync[feature_cols].values
    
    # Normalize using training stats
    means = np.array(meta['means'])
    stds = np.array(meta['stds'])
    X_norm = (X_raw - means) / stds
    
    X_tensor = torch.tensor(X_norm, dtype=torch.float32).unsqueeze(0) # (1, seq_len, 12)
    
    with torch.no_grad():
        # Spin up hidden state using at most the last 5 minutes (3000 steps) before blackout
        # Must match the training sequence length to stay in-distribution
        spinup_len = min(start, 3000)
        if spinup_len > 0:
            X_history = X_tensor[:, start - spinup_len:start, :]
            _, h_spinup = model(X_history)
        else:
            h_spinup = None
            
        # Predict blackout window using the spun-up hidden state
        X_blackout = X_tensor[:, start:end, :]
        vels, _ = model(X_blackout, h_spinup)
        vels = vels.squeeze(0).numpy()
        
    ref_lat = sync['ref_lat'].values
    ref_lon = sync['ref_lon'].values
    gyro_z = sync['Gyroscope Yaw'].values
    init_head_deg = sync['ref_heading'].iloc[start]
    if not np.isfinite(init_head_deg):
        init_head_deg = 0.0
    
    # Pre-slice arrays to the blackout window (benchmark_core indexes from 0)
    gyro_z_window = gyro_z[start:end]
    ref_lat_window = ref_lat[start:end + 1]
    ref_lon_window = ref_lon[start:end + 1]
    
    # Load map segments
    road_network_path = common.PROCESSED_DIR / f"road_network_{trip_id}.json"
    if not road_network_path.exists():
        segments = fetch_road_network(trip_id=trip_id)
    else:
        with open(road_network_path, 'r') as f:
            segments = json.load(f)
            
    map_matcher = SimpleMapMatcher(segments)
    hmm_matcher = HMMMapMatcher(segments)
    
    res = evaluate_blackout_window(
        pred_velocity=vels,
        gyro_yaw_rate=gyro_z_window,
        gt_lat=ref_lat_window,
        gt_lon=ref_lon_window,
        gt_heading_deg=np.array([init_head_deg] * (duration + 1)),
        start_idx=start,
        duration_steps=duration,
        dt_seconds=0.1,  # Data is 10Hz
        min_reference_distance_m=0.0,
        map_matcher=map_matcher,
        hmm_matcher=hmm_matcher
    )
    
    # Calculate RMSE for the blackout window
    gt_vels = sync['Velocity_ms'].values[start:end]
    rmse = np.sqrt(np.mean((vels - gt_vels)**2)) * 3.6
    mae = np.mean(np.abs(vels - gt_vels)) * 3.6
    
    print(f"  BLACKOUT RMSE = {rmse:.2f} km/h | MAE = {mae:.2f} km/h")
    print(f"  DR {trip_id}: final err = {res['open_loop_final_error_m']:.1f} m | "
          f"drift = {res['open_loop_drift_pct']:.1f}% | "
          f"EKF = {res['ekf_drift_pct']:.1f}% | "
          f"MM EKF = {res['map_matched_ekf_drift_pct']:.1f}%")

if __name__ == "__main__":
    model, meta = load_model()
    for test_trip in common.SPLIT_TRIPS["test"]:
        try:
            benchmark_trip_seq(model, meta, test_trip)
        except Exception as e:
            print(f"Failed to benchmark {test_trip}: {e}")
