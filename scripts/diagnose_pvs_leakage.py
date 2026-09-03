import numpy as np
import pandas as pd
from pathlib import Path
import matplotlib.pyplot as plt

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "pvs"

def diagnose():
    print("=== PVS Data Leakage Diagnostics ===")
    
    # 1. Check Stationary Bias
    test_data = np.load(PROCESSED_DIR / "iovnbd_test.npz")
    y_test = test_data['y']
    
    zero_pct = np.mean(y_test < 0.5) * 100
    mean_speed = np.mean(y_test)
    max_speed = np.max(y_test)
    
    print(f"\n1. Test Set Speed Distribution:")
    print(f"   - Windows < 0.5 m/s (Stationary/Traffic): {zero_pct:.1f}%")
    print(f"   - Mean Speed: {mean_speed:.2f} m/s ({mean_speed*3.6:.1f} km/h)")
    print(f"   - Max Speed: {max_speed:.2f} m/s ({max_speed*3.6:.1f} km/h)")
    
    # 2. Naive Baselines
    train_data = np.load(PROCESSED_DIR / "iovnbd_train.npz")
    train_mean = np.mean(train_data['y'])
    
    rmse_naive_mean = np.sqrt(np.mean((y_test - train_mean)**2))
    rmse_naive_zero = np.sqrt(np.mean((y_test - 0.0)**2))
    
    print(f"\n2. Naive Baselines (RMSE):")
    print(f"   - Our CNN-GRU Model: 0.65 m/s")
    print(f"   - Predict Train Mean ({train_mean:.2f} m/s): {rmse_naive_mean:.2f} m/s")
    print(f"   - Predict Zero (0 m/s): {rmse_naive_zero:.2f} m/s")
    
    # 3. Spatial Overlap (Are train and test trips the same route?)
    print("\n3. Spatial Route Overlap Analysis:")
    
    def get_trip_bounds(trip_num):
        csv_file = RAW_DATA_DIR / f"PVS {trip_num}" / "dataset_gps_mpu_right.csv"
        df = pd.read_csv(csv_file, usecols=['latitude', 'longitude'])
        lat_min, lat_max = df['latitude'].min(), df['latitude'].max()
        lon_min, lon_max = df['longitude'].min(), df['longitude'].max()
        return (lat_min, lat_max, lon_min, lon_max)
        
    train_bounds = [get_trip_bounds(t) for t in [3, 4, 5, 6, 7]]
    test_bounds = [get_trip_bounds(t) for t in [8, 9]]
    
    # Print center points roughly
    for idx, b in enumerate(train_bounds):
        print(f"   - Train Trip {idx+3} Center: {np.mean(b[0:2]):.4f}, {np.mean(b[2:4]):.4f}")
    for idx, b in enumerate(test_bounds):
        print(f"   - Test Trip {idx+8} Center: {np.mean(b[0:2]):.4f}, {np.mean(b[2:4]):.4f}")

    # 4. Check for IMU feature variance when stationary (Sensor Fusion Leakage Check)
    # If the IMU data was filtered by the smartphone's internal Kalman filter (which uses GPS),
    # the IMU will perfectly reflect zero acceleration when GPS says zero.
    print("\n4. Sensor Fusion Leakage Check:")
    X_test = test_data['X']
    
    stationary_idx = np.where(y_test < 0.1)[0]
    moving_idx = np.where(y_test > 5.0)[0]
    
    if len(stationary_idx) > 0 and len(moving_idx) > 0:
        stat_var = np.mean(np.var(X_test[stationary_idx], axis=1))
        move_var = np.mean(np.var(X_test[moving_idx], axis=1))
        print(f"   - Mean IMU Variance (Stationary): {stat_var:.4f}")
        print(f"   - Mean IMU Variance (Moving > 18km/h): {move_var:.4f}")
        if stat_var < 1e-4:
            print("     WARNING: Stationary variance is extremely low. The IMU data might have been artificially smoothed/zeroed by a smartphone Kalman filter using GPS!")

if __name__ == "__main__":
    diagnose()
