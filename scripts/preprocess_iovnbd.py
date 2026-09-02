import pandas as pd
import numpy as np
from pathlib import Path

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "pvs"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

def preprocess_iovnbd():
    print("Preprocessing IO-VNBD dataset (100Hz) for CNN-GRU...")
    
    train_trips = [3, 4, 5, 6, 7]
    test_trips = [8, 9]
    
    splits = {'train': {'X': [], 'y': [], 'traj': []}, 'test': {'X': [], 'y': [], 'traj': []}}
    
    for trip_num in train_trips + test_trips:
        trip_dir = RAW_DATA_DIR / f"PVS {trip_num}"
        csv_file = trip_dir / "dataset_gps_mpu_right.csv"
        
        if not csv_file.exists():
            print(f"Skipping {trip_dir.name}: CSV not found.")
            continue
            
        print(f"Loading {trip_dir.name}...")
        df = pd.read_csv(csv_file)
        
        # Features: accel + gyro (6 channels)
        feature_cols = [
            'acc_x_dashboard', 'acc_y_dashboard', 'acc_z_dashboard',
            'gyro_x_dashboard', 'gyro_y_dashboard', 'gyro_z_dashboard'
        ]
        
        # Drop rows where GPS speed is missing
        df = df.dropna(subset=['speed'] + feature_cols).reset_index(drop=True)
        
        features = df[feature_cols].values
        
        # Speed is in km/h, convert to m/s
        velocities = df['speed'].values / 3.6
        
        trajectory = df[['latitude', 'longitude']].values
        # Add a dummy yaw (0) since IO-VNBD doesn't have a reliable heading column
        trajectory = np.hstack([trajectory, np.zeros((len(trajectory), 1))])
        
        window_size = 200
        stride = 100
        
        X, y, traj = [], [], []
        for i in range(0, len(features) - window_size + 1, stride):
            window_x = features[i:i+window_size]
            window_y = np.mean(velocities[i:i+window_size])
            window_traj = trajectory[i+window_size-1]
            
            X.append(window_x)
            y.append(window_y)
            traj.append(window_traj)
            
        split = 'train' if trip_num in train_trips else 'test'
        splits[split]['X'].append(np.array(X))
        splits[split]['y'].append(np.array(y))
        splits[split]['traj'].append(np.array(traj))
        print(f"  {split} - Added {len(X)} windows.")
        
    for split in ['train', 'test']:
        if not splits[split]['X']:
            continue
        X = np.concatenate(splits[split]['X'])
        y = np.concatenate(splits[split]['y'])
        traj = np.concatenate(splits[split]['traj'])
        
        print(f"{split} total shape: X={X.shape}, y={y.shape}")
        
        # Normalize
        if split == 'train':
            c_means = np.mean(X, axis=(0, 1))
            c_stds = np.std(X, axis=(0, 1))
            c_stds[c_stds == 0] = 1.0
            np.savez(PROCESSED_DIR / "iovnbd_norm.npz", means=c_means, stds=c_stds)
        
        X_norm = (X - c_means) / c_stds
        np.savez_compressed(PROCESSED_DIR / f"iovnbd_{split}.npz", X=X_norm.astype(np.float32), y=y.astype(np.float32), traj=traj.astype(np.float64))

if __name__ == "__main__":
    preprocess_iovnbd()
