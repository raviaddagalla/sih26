import numpy as np
import pytest
import sys
import pandas as pd
from pathlib import Path
import importlib

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT / "src"))

import common
import dataset
from ekf import EKF
from dead_reckoning import DeadReckoningIntegrator
from benchmark_core import evaluate_blackout_window

def test_gravity_magnitude():
    sync_df = dataset.load_synced_trip("Vw1")
    gx = sync_df["Gravity X"].values
    gy = sync_df["Gravity Y"].values
    gz = sync_df["Gravity Z"].values
    
    mag = np.sqrt(gx**2 + gy**2 + gz**2)
    assert 9.5 < mag.mean() < 10.1, "Gravity magnitude is outside sane physical bounds"

def test_gps_unit_crosscheck():
    with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
        manifest = importlib.import_module('json').load(f)
    info = manifest["trips"]["S2"]
    assert info["has_can_velocity"]
    
    s_path = common.DATASET_ROOT / info["s_file"]
    s_df = pd.read_csv(s_path, encoding='latin-1')
    s_df.columns = [c.strip() for c in s_df.columns]
    gps_speed_kmh = s_df[[c for c in s_df.columns if 'speed' in c.lower()][0]].values
    gps_speed_ms = gps_speed_kmh / 3.6
    
    sync_df = dataset.load_synced_trip("S2")
    can_velocity_ms = sync_df["Velocity_ms"].values
    
    gps_col = [c for c in sync_df.columns if 'GPS_Speed' in c or 'GPS Speed' in c]
    if len(gps_col) > 0:
        gps_speed = sync_df[gps_col[0]].values
        moving = can_velocity_ms > 2.0
        ratio = (gps_speed[moving] / can_velocity_ms[moving]).mean()
        assert 0.85 <= ratio <= 1.15, f"GPS vs CAN unit crosscheck failed! Ratio: {ratio}"

def test_dr_integrator():
    v = 10.0 # m/s
    omega = 0.0 # rad/s
    dt = 1.0 # s
    N = 100
    
    dr = DeadReckoningIntegrator(0.0, 0.0, 0.0)
    for _ in range(N):
        dr.step(v, omega, dt)
        
    expected_dist = v * dt * N
    from benchmark_core import haversine
    actual_dist = haversine(0.0, 0.0, dr.lat, dr.lon)
    
    assert abs(expected_dist - actual_dist) < 1.0, f"Integrator mismatch: {expected_dist} vs {actual_dist}"

def test_ekf_convergence():
    ekf = EKF(0.0, 0.0, 0.0)
    for _ in range(10):
        ekf.predict(1.0, 0.0, 0.0)
        ekf.update_gps(0.0, 0.0)
        
    lat, lon = ekf.get_latlon()
    assert abs(lat) < 1e-6 and abs(lon) < 1e-6
    
    P1 = ekf.P.copy()
    ekf.predict(1.0, 10.0, 0.0)
    P2 = ekf.P.copy()
    
    assert np.trace(P2) > np.trace(P1), "Covariance did not increase during prediction"

def test_evaluate_blackout_window_gating():
    N = 60
    res = evaluate_blackout_window(
        pred_velocity=np.zeros(N),
        gyro_yaw_rate=np.zeros(N),
        gt_lat=np.zeros(N),
        gt_lon=np.zeros(N),
        gt_heading_deg=np.zeros(N),
        start_idx=0,
        duration_steps=N,
        dt_seconds=1.0,
        min_reference_distance_m=300.0
    )
    assert res is None, "Function should return None for stationary windows, not 0% drift"

def test_timestamp_alignment():
    # Load A5 NPZ, get timestamps
    test_data = np.load(common.PROCESSED_DIR / "test.npz")
    mask = test_data['trip_id'] == "A5"
    processed_timestamps = test_data['timestamps'][mask]
    
    # Load raw S-file
    with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
        manifest = importlib.import_module('json').load(f)
    s_path = common.DATASET_ROOT / manifest["trips"]["A5"]["s_file"]
    s_df = pd.read_csv(s_path, encoding='latin-1')
    raw_time_col = [c for c in s_df.columns if ('time' in c.lower() and ('ms' in c.lower() or 'since' in c.lower()))][0]
    raw_timestamps = pd.to_numeric(s_df[raw_time_col], errors='coerce').values
    raw_times_sorted = np.sort(raw_timestamps)
    
    # Find nearest
    indices = np.searchsorted(raw_times_sorted, processed_timestamps, side='left')
    indices = np.clip(indices, 0, len(raw_times_sorted)-1)
    
    nearest_raw = raw_times_sorted[indices]
    diffs = np.abs(nearest_raw - processed_timestamps)
    
    # Tolerance of 1 sample period ~ 100ms
    assert (diffs <= 101).all(), "Processed timestamps drift more than 1 sample period from raw data!"

def test_ensemble_routing():
    import evaluate_all
    original_load_model = evaluate_all.load_model
    
    def mock_load_model(mid):
        if mid == "gru":
            return None, "E", lambda X: np.array([2.0, 10.0]) 
        elif mid == "xgboost":
            return None, "tabular", lambda X: np.array([1.0, 8.0]) 
        else:
            return original_load_model(mid)
            
    evaluate_all.load_model = mock_load_model
    try:
        _, _, predict_fn = evaluate_all.load_model("ensemble")
        dummy_X = np.zeros((2, 10, 12))
        res = predict_fn(dummy_X)
        assert np.isclose(res[0], 2.0), f"Expected GRU output (2.0), got {res[0]}"
        assert np.isclose(res[1], 8.0), f"Expected XGB output (8.0), got {res[1]}"
    finally:
        evaluate_all.load_model = original_load_model
