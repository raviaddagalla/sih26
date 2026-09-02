"""
Phase 3: Drift Benchmark
Evaluate the IDR pipeline during a simulated GNSS blackout on held-out test trips.
"""
import torch
import numpy as np
import pandas as pd
import json
from pathlib import Path

import common
import dataset
from benchmark_core import evaluate_blackout_window
from fetch_osm_roads import fetch_road_network
from map_matching import SimpleMapMatcher

PROJECT_ROOT = common.PROJECT_ROOT
REPORTS_DIR = common.REPORTS_DIR

DEVICE = torch.device('cuda' if torch.cuda.is_available() else 'cpu')

def run_benchmark():
    print("="*60)
    print("IDR DRIFT BENCHMARK (Multi-Window Randomized)")
    print("="*60)
    
    # Evaluate ensemble model
    import evaluate_all
    model, channels, predict_fn = evaluate_all.load_model("ensemble")
    
    # Compute ensemble provenance hash (GRU + XGBoost)
    gru_path = PROJECT_ROOT / "models" / "gru" / "gru.pt"
    xgb_path = PROJECT_ROOT / "models" / "xgboost" / "xgboost_v1.json"
    gru_hash = common.hash_file(gru_path)
    xgb_hash = common.hash_file(xgb_path)
    
    # Combined hash to uniquely identify this ensemble pair
    import hashlib
    ensemble_hash = hashlib.sha256((gru_hash + xgb_hash).encode()).hexdigest() if gru_hash != "FILE_NOT_FOUND" else "N/A"
    
    dt_seconds = 1.0 # 10 samples at 10Hz stride
    all_results = []
    
    seeds = [42, 123, 2024]
    
    for trip in ['A5', 'T2']:
        print(f"\nEvaluating Trip {trip}...")
        sync_df = dataset.load_synced_trip(trip)
        windows = dataset.build_trip_windows(sync_df, trip)
        
        if len(windows['raw']) == 0:
            continue
            
        road_network_path = PROJECT_ROOT / "data" / "processed" / f"road_network_{trip}.json"
        if not road_network_path.exists():
            print(f"Fetching road network for {trip}...")
            osm_data = fetch_road_network(trip_id=trip)
        else:
            with open(road_network_path, 'r') as f:
                osm_data = json.load(f)
                
        if isinstance(osm_data, dict):
            segments = osm_data.get("segments", [])
            buildings = osm_data.get("buildings", [])
        else:
            segments = osm_data
            buildings = []
                
        from map_matching import HMMMapMatcher, RBPFMapMatcher
        map_matcher = SimpleMapMatcher(segments)
        hmm_matcher = HMMMapMatcher(segments)
        rbpf_matcher = RBPFMapMatcher(segments, buildings)
            
        # Normalize and predict
        norm = common.load_norm_params()
        X_raw = windows['raw']
        Xn = (X_raw - np.array(norm["means"])) / np.array(norm["stds"])
        
        pred_vel_full = predict_fn(Xn)
        raw_yaw_rates_full = windows['gyro_z']
        gt_lats = windows['lat']
        gt_lons = windows['lon']
        gt_headings = windows['heading']
        
        for duration_s in [30, 60, 90]:
            duration_steps = int(duration_s / dt_seconds)
            
            if len(X_raw) <= duration_steps:
                continue
                
            valid_starts = list(range(0, len(X_raw) - duration_steps))
            
            for seed in seeds:
                np.random.seed(seed)
                picks = np.random.choice(valid_starts, size=min(15, len(valid_starts)), replace=False)
                
                for start_idx in picks:
                    # Run the canonical benchmark core!
                    res = evaluate_blackout_window(
                        pred_velocity=pred_vel_full[start_idx : start_idx + duration_steps],
                        gyro_yaw_rate=raw_yaw_rates_full[start_idx : start_idx + duration_steps],
                        gt_lat=gt_lats[start_idx : start_idx + duration_steps],
                        gt_lon=gt_lons[start_idx : start_idx + duration_steps],
                        gt_heading_deg=gt_headings[start_idx : start_idx + duration_steps],
                        start_idx=start_idx,
                        duration_steps=duration_steps,
                        dt_seconds=dt_seconds,
                        min_reference_distance_m=300.0,
                        map_matcher=map_matcher,
                        hmm_matcher=hmm_matcher
                    )
                    
                    if res is None:
                        # Rejected (e.g., path < 300m)
                        all_results.append({
                            "trip": trip,
                            "duration_s": duration_s,
                            "seed": seed,
                            "start_idx": start_idx,
                            "excluded": True
                        })
                    else:
                        res["trip"] = trip
                        res["duration_s"] = duration_s
                        res["seed"] = seed
                        res["excluded"] = False
                        all_results.append(res)
                        
    # Process results
    df = pd.DataFrame(all_results)
    
    # Save raw CSV
    csv_path = REPORTS_DIR / "multi_window_drift_results.csv"
    df.to_csv(csv_path, index=False)
    
    # Save summary JSON
    valid_df = df[df['excluded'] == False]
    excluded_count = len(df[df['excluded'] == True])
    
    summary = {
        "metadata": {
            "generated_at_utc": common.get_utc_timestamp(),
            "model_checkpoint_path": "models/gru/gru.pt + models/xgboost/xgboost_v1.json",
            "model_checkpoint_sha256": ensemble_hash,
            "benchmark_core_version": common.hash_file(PROJECT_ROOT / "src" / "benchmark_core.py"),
            "manifest_sha256": common.hash_file(PROJECT_ROOT / "data" / "manifest.json"),
            "seeds_used": seeds
        },
        "stats": {
            "excluded_count": excluded_count,
            "valid_count": len(valid_df),
        }
    }
    
    for trip in ['A5', 'T2']:
        trip_df = valid_df[valid_df['trip'] == trip]
        for dur in [30, 60, 90]:
            dur_df = trip_df[trip_df['duration_s'] == dur]
            if len(dur_df) == 0:
                continue
            
            key = f"{trip}_{dur}s"
            
            med_ol = float(dur_df['open_loop_drift_pct'].median())
            med_ekf = float(dur_df['ekf_drift_pct'].median())
            med_ekf_mm = float(dur_df['map_matched_ekf_drift_pct'].median())
            
            summary["stats"][key] = {
                "count": len(dur_df),
                "median_drift_pct": med_ekf,
                "median_map_matched_drift_pct": med_ekf_mm,
                "mean_drift_pct": float(dur_df['ekf_drift_pct'].mean()),
                "std_drift_pct": float(dur_df['ekf_drift_pct'].std()),
                "median_error_m": float(dur_df['ekf_final_error_m'].median()),
                "low_motion_count": int(dur_df['is_low_motion'].sum())
            }
            
            delta_pct = med_ekf - med_ekf_mm
            delta_rel = (delta_pct / med_ekf) * 100 if med_ekf > 0 else 0
            
            print(f"Trip {trip} | {dur}s blackout | {len(dur_df)} valid | "
                  f"OL: {med_ol:.2f}% | EKF: {med_ekf:.2f}% | EKF+MM: {med_ekf_mm:.2f}% "
                  f"(Delta: {delta_pct:.2f}% abs, {delta_rel:.1f}% rel)")
                  
    with open(REPORTS_DIR / "multi_window_drift_summary.json", "w") as f:
        json.dump(summary, f, indent=2)
        
    print(f"\nSaved raw records to {csv_path}")
    print(f"Saved summary to {REPORTS_DIR / 'multi_window_drift_summary.json'}")

if __name__ == "__main__":
    run_benchmark()
