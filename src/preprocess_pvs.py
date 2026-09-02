import pandas as pd
import numpy as np
from pathlib import Path
from scipy.signal import butter, filtfilt
import json

PROJECT_ROOT = Path(__file__).parent.parent
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "pvs"
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

def lowpass_filter(data, cutoff_hz, fs_hz, order=4):
    """Zero-phase Butterworth low-pass filter."""
    nyq = 0.5 * fs_hz
    normal_cutoff = cutoff_hz / nyq
    b, a = butter(order, normal_cutoff, btype='low', analog=False)
    # Pad to handle edge effects
    return filtfilt(b, a, data)

def preprocess_pvs_trip(trip_dir):
    # Normalize name: "PVS 3" -> "PVS_3"
    trip_id = trip_dir.name.replace(" ", "_")
    csv_file = trip_dir / "dataset_gps_mpu_right.csv"
    if not csv_file.exists():
        print(f"Skipping {trip_id} (No GPS/MPU CSV)")
        return
        
    print(f"Processing {trip_id}...")
    df = pd.read_csv(csv_file)
    
    # 1. Timeline (already 100Hz in PVS, roughly)
    time_col = next((c for c in df.columns if 'time' in c.lower()), None)
    t = df[time_col].values
    time_s = t - t[0]
    
    start_t = np.ceil(time_s[0] * 10) / 10
    end_t = np.floor(time_s[-1] * 10) / 10
    target_time = np.arange(start_t, end_t, 0.1)
    
    resampled = {'Time_s': target_time}
    
    from scipy.interpolate import interp1d
    
    def resample_col(col_data):
        f = interp1d(time_s, col_data, kind='linear', bounds_error=False, fill_value=np.nan)
        return f(target_time)

    # 3. Extract Gravity from Accel (1Hz lowpass)
    fs = 100.0
    cutoff = 1.0 # 1Hz
    
    raw_ax = df['acc_x_dashboard'].values
    raw_ay = df['acc_y_dashboard'].values
    raw_az = df['acc_z_dashboard'].values
    
    grav_x = lowpass_filter(raw_ax, cutoff, fs)
    grav_y = lowpass_filter(raw_ay, cutoff, fs)
    grav_z = lowpass_filter(raw_az, cutoff, fs)
    
    lin_ax = raw_ax - grav_x
    lin_ay = raw_ay - grav_y
    lin_az = raw_az - grav_z
    
    resampled['Linear Accel X'] = resample_col(lin_ax)
    resampled['Linear Accel Y'] = resample_col(lin_ay)
    resampled['Linear Accel Z'] = resample_col(lin_az)
    
    resampled['Gravity X'] = resample_col(grav_x)
    resampled['Gravity Y'] = resample_col(grav_y)
    resampled['Gravity Z'] = resample_col(grav_z)
    
    # 4. Gyroscope (Yaw is Z, Pitch is Y, Roll is X typically, or vice versa)
    resampled['Gyroscope Yaw'] = resample_col(df['gyro_z_dashboard'].values)
    resampled['Gyroscope Pitch'] = resample_col(df['gyro_y_dashboard'].values)
    resampled['Gyroscope Roll'] = resample_col(df['gyro_x_dashboard'].values)
    
    # 5. Orientation (Missing, pad with 0)
    zeros = np.zeros_like(target_time)
    resampled['Orientation Yaw'] = zeros
    resampled['Orientation Pitch'] = zeros
    resampled['Orientation Roll'] = zeros
    
    # 6. GPS and Velocity
    resampled['ref_lat'] = resample_col(df['latitude'].values)
    resampled['ref_lon'] = resample_col(df['longitude'].values)
    
    # Compute heading (simple forward difference)
    lat_r = np.radians(resampled['ref_lat'])
    lon_r = np.radians(resampled['ref_lon'])
    dlon = np.diff(lon_r)
    dlat = np.diff(lat_r)
    y = np.sin(dlon) * np.cos(lat_r[1:])
    x = np.cos(lat_r[:-1]) * np.sin(lat_r[1:]) - np.sin(lat_r[:-1]) * np.cos(lat_r[1:]) * np.cos(dlon)
    heading_rad = np.arctan2(y, x)
    heading_deg = np.degrees(heading_rad)
    heading_deg = np.append(heading_deg, heading_deg[-1]) # pad last
    heading_deg = (heading_deg + 360) % 360
    resampled['ref_heading'] = heading_deg
    
    # Velocity
    speed_col = next((c for c in df.columns if 'speed' in c.lower()), None)
    speeds = df[speed_col].values
    if speeds.max() > 60:
        # km/h
        speeds = speeds / 3.6
    resampled['Velocity_ms'] = resample_col(speeds)
    
    # Convert to DataFrame
    res_df = pd.DataFrame(resampled)
    n_before = len(res_df)
    res_df = res_df.dropna().reset_index(drop=True)
    if n_before - len(res_df) > 0:
        print(f"  Dropped {n_before - len(res_df)} NaN rows.")
        
    out_path = PROCESSED_DIR / f"sync_{trip_id}.csv"
    res_df.to_csv(out_path, index=False)
    print(f"  Saved {out_path} ({len(res_df)} 10Hz windows)")

def main():
    if not RAW_DATA_DIR.exists():
        print(f"{RAW_DATA_DIR} not found.")
        return
        
    for trip_dir in sorted(RAW_DATA_DIR.iterdir()):
        if trip_dir.is_dir() and trip_dir.name.upper().startswith("PVS"):
            trip_id_norm = trip_dir.name.replace(" ", "_")
            out_path = PROCESSED_DIR / f"sync_{trip_id_norm}.csv"
            if out_path.exists():
                print(f"Skipping {trip_id_norm} (already processed)")
                continue
            preprocess_pvs_trip(trip_dir)

if __name__ == '__main__':
    main()
