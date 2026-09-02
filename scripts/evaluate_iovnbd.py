import os
import numpy as np
from pathlib import Path
import torch
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import StatefulCNNGRU
from benchmark_core import haversine

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

def evaluate_iovnbd():
    print("Loading test split from IO-VNBD...")
    
    test_data = np.load(PROCESSED_DIR / "iovnbd_test.npz")
    X = test_data['X']
    y_gt_windows = test_data['y']
    trajectory = test_data['traj']
    
    X_tensor = torch.tensor(X, dtype=torch.float32)
    
    print(f"Loaded {len(X)} test windows ({(len(X)):.1f} seconds).")
    
    # Load model
    device = torch.device('cpu')
    model = StatefulCNNGRU(in_channels=6, cnn_channels=32, hidden=64, num_layers=2)
    model.load_state_dict(torch.load(PROCESSED_DIR / "best_iovnbd_model.pth", weights_only=True))
    model.eval()
    
    with torch.no_grad():
        vel_preds, _ = model(X_tensor)
        vel_preds = vel_preds.mean(dim=1).numpy()
        
    # Velocity RMSE:
    rmse_vel = np.sqrt(np.mean((vel_preds - y_gt_windows)**2))
    print(f"DL Model Velocity RMSE: {rmse_vel:.3f} m/s")
    
    # 2D Integration
    # We will simulate the drift by using DL speed + Ground Truth heading (if available).
    # Since IO-VNBD didn't provide a reliable GT heading, we'll extract it from the GT trajectory!
    
    # Let's compute a simple open loop drift using consecutive ground truth headings
    R_earth = 6378137.0
    
    lat_ol = trajectory[0, 0]
    lon_ol = trajectory[0, 1]
    
    for i in range(len(X) - 1):
        v = vel_preds[i]
        
        # Calculate true heading between this frame and next from GT lat/lon
        lat1, lon1 = trajectory[i, 0:2]
        lat2, lon2 = trajectory[i+1, 0:2]
        
        dlon = np.radians(lon2 - lon1)
        lat1_rad = np.radians(lat1)
        lat2_rad = np.radians(lat2)
        
        y_hdg = np.sin(dlon) * np.cos(lat2_rad)
        x_hdg = np.cos(lat1_rad) * np.sin(lat2_rad) - np.sin(lat1_rad) * np.cos(lat2_rad) * np.cos(dlon)
        true_heading = np.arctan2(y_hdg, x_hdg)
        
        # Open loop integration using predicted speed and true heading
        dt = 1.0 # The stride was 100 samples = 1 second
        d_east = v * np.sin(true_heading) * dt
        d_north = v * np.cos(true_heading) * dt
        
        lat_ol += np.degrees(d_north / R_earth)
        lon_ol += np.degrees(d_east / (R_earth * np.cos(np.radians(lat_ol))))
        
    final_gt_lat = trajectory[len(X)-1, 0]
    final_gt_lon = trajectory[len(X)-1, 1]
    
    ref_dist = 0.0
    for i in range(len(X) - 1):
        ref_dist += haversine(trajectory[i, 0], trajectory[i, 1], trajectory[i+1, 0], trajectory[i+1, 1])
        
    err_ol = haversine(final_gt_lat, final_gt_lon, lat_ol, lon_ol)
    
    print("\n" + "="*60)
    print("FINAL SIH PROPOSAL EVALUATION (IO-VNBD Dataset)")
    print("="*60)
    print(f"Test Case Duration: {len(X)} seconds")
    print(f"Test Case Distance Traveled: {ref_dist:.1f} meters")
    print(f"Velocity Prediction RMSE: {rmse_vel:.2f} m/s ({(rmse_vel*3.6):.1f} km/h)")
    print("-" * 60)
    print(f"Position Error (using DL Velocity + GT Heading): {err_ol:.2f} meters")
    print(f"Drift Percentage: {(err_ol / max(ref_dist, 1.0)) * 100:.2f} %")
    print("="*60)

if __name__ == "__main__":
    evaluate_iovnbd()
