import numpy as np
import pandas as pd
from pathlib import Path
import json

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "pvs"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"

def load_trip(trip_num):
    folder = RAW_DATA_DIR / f"PVS {trip_num}"
    if not folder.exists():
        folder = RAW_DATA_DIR / f"PVS_{trip_num}"
    
    imu_file = folder / "dataset_mpu_right.csv"
    gps_file = folder / "dataset_gps.csv"
    
    imu_df = pd.read_csv(imu_file)
    gps_df = pd.read_csv(gps_file)
    
    imu_df['timestamp'] = pd.to_datetime(imu_df['timestamp'])
    gps_df['timestamp'] = pd.to_datetime(gps_df['timestamp'])
    
    imu_df = imu_df.sort_values('timestamp')
    gps_df = gps_df.sort_values('timestamp')
    
    gps_df = gps_df.rename(columns={'speed_meters_per_second': 'speed'})
    
    # Forward fill GPS data to IMU timestamps
    merged_df = pd.merge_asof(imu_df, gps_df, on='timestamp', direction='backward')
    merged_df = merged_df.dropna(subset=['latitude', 'longitude', 'speed'])
    
    return merged_df

def extract_windows(df, window_size=200, stride=100):
    # Features: dashboard IMU
    cols = ['acc_x_dashboard', 'acc_y_dashboard', 'acc_z_dashboard', 'gyro_x_dashboard', 'gyro_y_dashboard', 'gyro_z_dashboard']
    
    X, y = [], []
    lat, lon, gyro_z_out, heading_out = [], [], [], []
    
    # We need sequential extraction
    n_samples = len(df)
    
    # Need heading from GPS coordinates (approximate)
    lats_rad = np.radians(df['latitude'].values)
    lons_rad = np.radians(df['longitude'].values)
    
    for i in range(0, n_samples - window_size, stride):
        window = df.iloc[i:i+window_size]
        X.append(window[cols].values)
        
        # Ground truth speed at the end of the window
        y.append(window['speed'].iloc[-1])
        
        # Ground truth lat/lon at the end of the window
        lat.append(window['latitude'].iloc[-1])
        lon.append(window['longitude'].iloc[-1])
        
        # Raw Gyro Z over the window (for Dead Reckoning)
        gyro_z_out.append(window['gyro_z_dashboard'].values)
        
        # Calculate heading at the end of window using last two GPS points
        if i + window_size > 1:
            lat1 = lats_rad[i+window_size-2]
            lon1 = lons_rad[i+window_size-2]
            lat2 = lats_rad[i+window_size-1]
            lon2 = lons_rad[i+window_size-1]
            dlon = lon2 - lon1
            y_h = np.sin(dlon) * np.cos(lat2)
            x_h = np.cos(lat1) * np.sin(lat2) - np.sin(lat1) * np.cos(lat2) * np.cos(dlon)
            brng = np.arctan2(y_h, x_h)
            heading_out.append(np.degrees(brng))
        else:
            heading_out.append(0.0)

    return np.array(X), np.array(y), np.array(lat), np.array(lon), np.array(gyro_z_out), np.array(heading_out)

def main():
    print("Loading PVS Trip 1...")
    df = load_trip(1)
    
    print(f"Total points: {len(df)}")
    
    # Split 75/25 Chronologically
    split_idx = int(len(df) * 0.75)
    train_df = df.iloc[:split_idx]
    test_df = df.iloc[split_idx:]
    
    print(f"Extracting Train windows...")
    X_train, y_train, lat_train, lon_train, gz_train, h_train = extract_windows(train_df)
    
    print(f"Extracting Test windows...")
    X_test, y_test, lat_test, lon_test, gz_test, h_test = extract_windows(test_df)
    
    # Calculate normalization on train set only
    means = X_train.mean(axis=(0, 1)).tolist()
    stds = X_train.std(axis=(0, 1)).tolist()
    
    norm_params = {"means": means, "stds": stds}
    with open(PROCESSED_DIR / "norm_params_single.json", "w") as f:
        json.dump(norm_params, f)
        
    np.savez_compressed(PROCESSED_DIR / "train_single.npz", X=X_train, y=y_train)
    np.savez_compressed(PROCESSED_DIR / "test_single.npz", 
                        X=X_test, y=y_test, 
                        lat=lat_test, lon=lon_test, 
                        gyro_z=gz_test, heading=h_test)
    
    print(f"Train Windows: {len(X_train)} (First 18 minutes)")
    print(f"Test Windows: {len(X_test)} (Last 6 minutes)")
    print("Done!")

if __name__ == "__main__":
    main()
