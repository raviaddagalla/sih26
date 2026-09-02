import os
import numpy as np
import pandas as pd
from pathlib import Path
import torch
import json
import pickle
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import StatefulGRU
from benchmark_core import evaluate_blackout_window
from fetch_osm_roads import fetch_road_network
from map_matching import SimpleMapMatcher, RBPFMapMatcher, HMMMapMatcher
import common

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
REPORTS_DIR = PROJECT_ROOT / "reports"

def predict_velocity(model, X_raw):
    norm = common.load_norm_params()
    Xn = (X_raw - np.array(norm["means"])) / np.array(norm["stds"])
    X_tensor = torch.tensor(Xn, dtype=torch.float32)
    
    with torch.no_grad():
        # StatefulGRU forward returns vel, h_new. Vel shape is (batch, seq_len)
        vel, _ = model(X_tensor)
        
    return vel.mean(dim=1).numpy()

def evaluate_10hz_baseline():
    print("="*60)
    print("EVALUATING 10Hz IO-VNBD BASELINE (ESKF + RBPF)")
    print("="*60)
    
    # Load StatefulGRU model
    model = StatefulGRU(in_channels=12, hidden=64, num_layers=2)
    model.load_state_dict(torch.load(PROJECT_ROOT / "models" / "stateful_gru" / "model.pt", weights_only=True))
    model.eval()
    
    # Load reference cache for full trips A5 and T2
    with open(PROCESSED_DIR / "reference_cache.pkl", "rb") as f:
        ref_cache = pickle.load(f)
        
    for trip_id in ["A5", "T2"]:
        print(f"\nProcessing Trip {trip_id} (True 10Hz IO-VNBD Data)...")
        d = ref_cache[trip_id]
        
        X_raw = np.array(d["raw"])
        vel_preds = predict_velocity(model, X_raw)
        
        y_gt = np.array(d["vel"])
        
        rmse_ms = np.sqrt(np.mean((vel_preds - y_gt)**2))
        print(f"  Velocity RMSE: {rmse_ms:.2f} m/s ({rmse_ms*3.6:.1f} km/h)")
        
        gyro_z = np.array(d["gyro_z"])
        ref_lat = np.array(d["lat"])
        ref_lon = np.array(d["lon"])
        
        init_head_deg = float(np.array(d["heading"])[0])
        if not np.isfinite(init_head_deg):
            init_head_deg = 0.0
            
        # Get OSM Map Matcher
        road_network_path = PROCESSED_DIR / f"road_network_{trip_id}.json"
        if not road_network_path.exists():
            print(f"  Fetching OSM network for {trip_id}...")
            osm_data = fetch_road_network(trip_id=trip_id)
        else:
            with open(road_network_path, 'r') as f:
                osm_data = json.load(f)
                
        if isinstance(osm_data, dict):
            segments = osm_data.get("segments", [])
            buildings = osm_data.get("buildings", [])
        else:
            segments = osm_data
            buildings = []
            
        map_matcher = SimpleMapMatcher(segments)
        hmm_matcher = HMMMapMatcher(segments)
        rbpf_matcher = RBPFMapMatcher(segments, buildings)
        
        duration = len(X_raw)
        
        print("  Running ESKF + RBPF Map Matching over full trip...")
        res = evaluate_blackout_window(
            pred_velocity=vel_preds,
            gyro_yaw_rate=gyro_z,
            gt_lat=ref_lat,
            gt_lon=ref_lon,
            gt_heading_deg=np.array([init_head_deg]*len(ref_lat)),
            start_idx=0,
            duration_steps=duration,
            dt_seconds=1.0,
            min_reference_distance_m=0.0,
            map_matcher=map_matcher,
            hmm_matcher=hmm_matcher
        )
        
        print("\n  RESULTS:")
        print(f"  Test Case Duration: {duration} seconds")
        print(f"  Test Case Distance Traveled: {res['reference_distance_m']:.1f} meters")
        print("-" * 50)
        print(f"  Raw Open Loop Error (No Filters): {res['open_loop_final_error_m']:.1f} m (Drift: {res['open_loop_drift_pct']:.2f}%)")
        print(f"  ESKF Error (with NHC): {res['ekf_final_error_m']:.1f} m (Drift: {res['ekf_drift_pct']:.2f}%)")
        print(f"  ESKF + Map Matching Error: {res['map_matched_ekf_drift_m']:.1f} m (Drift: {res['map_matched_ekf_drift_pct']:.2f}%)")

if __name__ == "__main__":
    evaluate_10hz_baseline()
