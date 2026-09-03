import numpy as np
import pandas as pd
from pathlib import Path
import json
import math

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "roadsens" / "csv_files" / "Combined CSV with GIS and Weather Data" / "Road Anomalies" / "extracted"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

def haversine(lat1, lon1, lat2, lon2):
    R = 6371000  # radius of Earth in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    a = math.sin(delta_phi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def calculate_velocity_and_heading(df):
    # GPS updates at ~1Hz, so values are repeated for ~100 rows
    speeds = np.zeros(len(df))
    headings = np.zeros(len(df))
    
    lats = df['location_latitude'].values
    lons = df['location_longitude'].values
    times = df['seconds_elapsed'].values
    
    # Identify indices where GPS location actually changes
    change_idx = [0]
    for i in range(1, len(df)):
        # Treat NaN or same value as no change
        if not np.isnan(lats[i]) and not np.isnan(lons[i]):
            if np.isnan(lats[change_idx[-1]]) or (lats[i] != lats[change_idx[-1]] or lons[i] != lons[change_idx[-1]]):
                change_idx.append(i)
                
    for k in range(1, len(change_idx)):
        idx_prev = change_idx[k-1]
        idx_curr = change_idx[k]
        
        if np.isnan(lats[idx_prev]) or np.isnan(lons[idx_prev]):
            continue
            
        dist = haversine(lats[idx_prev], lons[idx_prev], lats[idx_curr], lons[idx_curr])
        dt = times[idx_curr] - times[idx_prev]
        
        speed = dist / dt if dt > 0 else 0.0
        
        # Calculate heading
        lat1, lon1 = math.radians(lats[idx_prev]), math.radians(lons[idx_prev])
        lat2, lon2 = math.radians(lats[idx_curr]), math.radians(lons[idx_curr])
        dlon = lon2 - lon1
        y_h = math.sin(dlon) * math.cos(lat2)
        x_h = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
        brng = math.degrees(math.atan2(y_h, x_h))
        
        # Assign speed and heading to the entire interval
        speeds[idx_prev:idx_curr] = speed
        headings[idx_prev:idx_curr] = brng

    # Forward fill the last segment
    if len(change_idx) > 1:
        speeds[change_idx[-1]:] = speeds[change_idx[-2]]
        headings[change_idx[-1]:] = headings[change_idx[-2]]
        
    df['calculated_speed'] = speeds
    df['calculated_heading'] = headings
    
    # Forward fill NaNs in lat/lon for continuous map matching
    df['location_latitude'] = df['location_latitude'].ffill().bfill()
    df['location_longitude'] = df['location_longitude'].ffill().bfill()
    return df

def extract_windows(df, window_size=200, stride=100):
    # Features: acc_x, acc_y, acc_z, gyro_x, gyro_y, gyro_z
    cols = ['accelerometer_x', 'accelerometer_y', 'accelerometer_z', 
            'gyroscope_x', 'gyroscope_y', 'gyroscope_z']
            
    X, y = [], []
    lat, lon, gyro_z_out, heading_out = [], [], [], []
    
    n_samples = len(df)
    
    for i in range(0, n_samples - window_size, stride):
        window = df.iloc[i:i+window_size]
        # Skip windows with too many NaNs in sensors
        if window[cols].isna().sum().sum() > 0:
            continue
            
        X.append(window[cols].values)
        y.append(window['calculated_speed'].iloc[-1])
        lat.append(window['location_latitude'].iloc[-1])
        lon.append(window['location_longitude'].iloc[-1])
        gyro_z_out.append(window['gyroscope_z'].values)
        heading_out.append(window['calculated_heading'].iloc[-1])

    return X, y, lat, lon, gyro_z_out, heading_out

def main():
    print("Finding RoadSens-4M CSV files...")
    csv_files = list(RAW_DATA_DIR.glob("*.csv"))
    print(f"Found {len(csv_files)} files.")
    
    # Split files into 80% Train, 20% Test (prevents spatial/temporal leakage)
    split_idx = int(len(csv_files) * 0.8)
    train_files = csv_files[:split_idx]
    test_files = csv_files[split_idx:]
    
    X_train, y_train = [], []
    print("Processing Train Files...")
    for f in train_files:
        df = pd.read_csv(f)
        if 'location_latitude' not in df.columns:
            continue
        df = calculate_velocity_and_heading(df)
        X, y, _, _, _, _ = extract_windows(df)
        X_train.extend(X)
        y_train.extend(y)
        
    X_test, y_test, lat_test, lon_test, gz_test, h_test = [], [], [], [], [], []
    print("Processing Test Files...")
    for f in test_files:
        df = pd.read_csv(f)
        if 'location_latitude' not in df.columns:
            continue
        df = calculate_velocity_and_heading(df)
        X, y, lat, lon, gz, h = extract_windows(df)
        X_test.extend(X)
        y_test.extend(y)
        lat_test.extend(lat)
        lon_test.extend(lon)
        gz_test.extend(gz)
        h_test.extend(h)
        
    X_train = np.array(X_train)
    y_train = np.array(y_train)
    X_test = np.array(X_test)
    y_test = np.array(y_test)
    
    # Calculate normalization on train set
    means = X_train.mean(axis=(0, 1)).tolist()
    stds = X_train.std(axis=(0, 1)).tolist()
    # Prevent division by zero
    stds = [s if s > 1e-6 else 1.0 for s in stds]
    
    norm_params = {"means": means, "stds": stds}
    with open(PROCESSED_DIR / "norm_params_roadsens.json", "w") as f:
        json.dump(norm_params, f)
        
    np.savez_compressed(PROCESSED_DIR / "train_roadsens.npz", X=X_train, y=y_train)
    np.savez_compressed(PROCESSED_DIR / "test_roadsens.npz", 
                        X=X_test, y=y_test, 
                        lat=np.array(lat_test), lon=np.array(lon_test), 
                        gyro_z=np.array(gz_test), heading=np.array(h_test))
    
    print(f"Train Windows: {len(X_train)}")
    print(f"Test Windows: {len(X_test)}")
    print("Done!")

if __name__ == "__main__":
    main()
