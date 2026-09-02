import pandas as pd
import numpy as np
from pathlib import Path

PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
RAW_DATA_DIR = PROJECT_ROOT / "data" / "raw" / "pvs"

def validate_trip(trip_dir):
    csv_file = trip_dir / "dataset_gps_mpu_right.csv"
    if not csv_file.exists():
        return
        
    print(f"\n--- Validating {trip_dir.name} ---")
    df = pd.read_csv(csv_file)
    row_count = len(df)
    
    print(f"Row count: {row_count}")
    
    time_col = next((c for c in df.columns if 'time' in c.lower()), None)
    speed_col = next((c for c in df.columns if 'speed' in c.lower()), None)
    
    if time_col:
        time_diffs = df[time_col].diff().dropna()
        median_diff = time_diffs.median()
        # In PVS, timestamp is usually in seconds (e.g. 0.01)
        print(f"Median timestamp diff: {median_diff:.4f}s")
        if np.isclose(median_diff, 0.01, atol=0.002):
            print("Sampling rate looks consistent with 100Hz.")
        else:
            print(f"FLAG: Unusual sampling rate delta: {median_diff}")
            
    if speed_col:
        speeds = df[speed_col]
        # Max speed check to infer units
        max_speed = speeds.max()
        if max_speed > 55:
            # likely km/h
            speeds_ms = speeds / 3.6
        else:
            speeds_ms = speeds
            
        print(f"Speed range: 0.00 - {speeds_ms.max():.2f} m/s")
        
        buckets = [0, 2, 5, 10, float('inf')]
        labels = ["0-2 m/s", "2-5 m/s", "5-10 m/s", "10+ m/s"]
        
        for i in range(len(buckets)-1):
            lo, hi = buckets[i], buckets[i+1]
            mask = (speeds_ms >= lo) & (speeds_ms < hi)
            pct = (mask.sum() / row_count) * 100
            print(f"  {labels[i]}: {pct:.1f}% ({mask.sum()} samples)")
            
    # NaN check
    # Check for columns that sound like sensors
    sensor_cols = [c for c in df.columns if any(x in c.lower() for x in ['acc', 'gyro', 'speed'])]
    if sensor_cols:
        nans = df[sensor_cols].isna().sum()
        nan_cols = nans[nans > 0]
        if len(nan_cols) > 0:
            print("FLAG: NaNs found in sensor columns:")
            print(nan_cols)
        else:
            print("No NaNs found in sensor columns.")

def main():
    if not RAW_DATA_DIR.exists():
        print(f"{RAW_DATA_DIR} not found.")
        return
        
    for trip_dir in sorted(RAW_DATA_DIR.iterdir()):
        if trip_dir.is_dir():
            validate_trip(trip_dir)

if __name__ == '__main__':
    main()
