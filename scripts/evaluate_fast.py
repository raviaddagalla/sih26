import os
import glob
import numpy as np
from pathlib import Path
import torch
import sys

sys.path.append(r"D:\Nandhu\dead reckoning\idr-project\src")
from models_lib import StatefulCNNGRU
from eskf import ESKF
from benchmark_core import haversine

DATA_DIR = Path(r"D:\Nandhu\dead reckoning\idr-project\data\raw\kitti\oxts\oxts_00\oxts\data")

def evaluate_fast():
    print("Loading 2000 frames from KITTI for fast evaluation...")
    txt_files = sorted(glob.glob(os.path.join(DATA_DIR, "*.txt")))[:2000]
    
    features = []
    trajectory = []
    
    for fpath in txt_files:
        with open(fpath, 'r') as f:
            line = f.readline().strip().split()
            if not line: continue
            vals = [float(x) for x in line]
            
            feat = [
                vals[14], vals[15], vals[16], 
                0.0, 0.0, 0.0,                
                vals[19], vals[18], vals[17], 
                vals[5], vals[4], vals[3]     
            ]
            features.append(feat)
            trajectory.append([vals[0], vals[1], vals[5]]) # lat, lon, yaw
            
    features = np.array(features)
    trajectory = np.array(trajectory)
    
    print(f"Loaded {len(features)} frames.")
    
    # Run through CNN-GRU
    device = torch.device('cpu')
    model = StatefulCNNGRU(in_channels=12, cnn_channels=32, hidden=64, num_layers=2)
    model.load_state_dict(torch.load(r"D:\Nandhu\dead reckoning\idr-project\data\processed\best_kitti_model.pth"))
    model.eval()
    
    # Create single batch of windowed features
    window_size = 200
    X = []
    for i in range(0, len(features) - window_size + 1, 100):
        X.append(features[i:i+window_size])
    X = torch.tensor(np.array(X), dtype=torch.float32)
    
    with torch.no_grad():
        vel_preds, _ = model(X)
        vel_preds = vel_preds.mean(dim=1).numpy()
        
    print(f"Generated {len(vel_preds)} velocity predictions.")
    
    # Run ESKF integration
    # Since ESKF integrates at IMU rate, and we have vel_preds at 1Hz (stride 100),
    # we will run ESKF on the first 1000 frames (10 seconds)
    
    init_lat, init_lon, init_yaw = trajectory[0]
    eskf = ESKF(init_lat, init_lon, init_yaw, vel_preds[0])
    
    # For baseline, also do open-loop DR
    ol_x, ol_y = 0.0, 0.0
    ol_theta = init_yaw
    
    for i in range(len(features) - window_size):
        dt = 0.01 # 100Hz
        accel = features[i, 0:3]
        gyro = features[i, 6:9]
        
        eskf.predict(dt, accel, gyro)
        eskf.update_nhc()
        
        if i % 100 == 0:
            # 1Hz ML velocity update
            idx = i // 100
            if idx < len(vel_preds):
                v_ml = vel_preds[idx]
                eskf.update_ml_velocity(v_ml, R_ml=1.0)
                
        # Open Loop
        v = vel_preds[min(i // 100, len(vel_preds)-1)]
        omega = gyro[0] # yaw rate
        ol_x += v * np.cos(ol_theta) * dt
        ol_y += v * np.sin(ol_theta) * dt
        ol_theta += omega * dt
        
    final_eskf_lat, final_eskf_lon = eskf.get_latlon()
    final_gt_lat, final_gt_lon = trajectory[len(features) - window_size - 1, 0:2]
    
    eskf_error = haversine(final_gt_lat, final_gt_lon, final_eskf_lat, final_eskf_lon)
    ref_dist = haversine(init_lat, init_lon, final_gt_lat, final_gt_lon)
    
    print("\n" + "="*50)
    print("FAST DRIFT EVALUATION RESULTS")
    print("="*50)
    print(f"Trajectory Length: {ref_dist:.2f} meters (over 20 seconds)")
    print(f"ESKF + ML Drift Error: {eskf_error:.2f} meters")
    print(f"ESKF + ML Drift Percentage: {(eskf_error / max(ref_dist, 1.0)) * 100:.2f} %")
    print("="*50)
    
if __name__ == "__main__":
    evaluate_fast()
