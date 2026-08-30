"""
Phase 1 — Corrected Preprocessing Pipeline
Fixes:
  1. Time alignment: zero both S and V timelines independently, no extrapolation
  2. GPS Speed = m/s (verified per-trip), no /3.6 conversion
  3. Non-monotonic timestamps: segment at jumps, keep longest monotonic segment
  4. Sanity assertions before saving any .npz
"""
import pandas as pd
import numpy as np
import json
from pathlib import Path
from scipy.interpolate import interp1d

DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
PROCESSED_DIR = PROJECT_ROOT / "data" / "processed"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
    manifest = json.load(f)

# The 12 sensor channels for Feature Set E (order matters — must be consistent)
SENSOR_COLS = [
    'Accelerometer X', 'Accelerometer Y', 'Accelerometer Z',
    'Gravity X', 'Gravity Y', 'Gravity Z',
    'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
    'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
]


def map_s_columns(df):
    """Map S-file columns to canonical names using explicit matching."""
    col_map = {}
    for c in df.columns:
        cl = c.lower().strip()
        # GPS
        if cl.startswith('gps speed'):
            col_map[c] = 'GPS Speed'
        elif cl.startswith('gps latitude'):
            col_map[c] = 'GPS Latitude'
        elif cl.startswith('gps longitude'):
            col_map[c] = 'GPS Longitude'
        elif cl.startswith('gps accuracy'):
            col_map[c] = 'GPS Accuracy'
        elif cl.startswith('gps orientation'):
            col_map[c] = 'GPS Heading'
        elif cl.startswith('time since start'):
            col_map[c] = 'Time_ms'
        # IMU — use exact prefix matching, order doesn't matter since each is unique
        elif cl.startswith('accelerometer x'):
            col_map[c] = 'Accelerometer X'
        elif cl.startswith('accelerometer y'):
            col_map[c] = 'Accelerometer Y'
        elif cl.startswith('accelerometer z'):
            col_map[c] = 'Accelerometer Z'
        elif cl.startswith('gravity x'):
            col_map[c] = 'Gravity X'
        elif cl.startswith('gravity y'):
            col_map[c] = 'Gravity Y'
        elif cl.startswith('gravity z'):
            col_map[c] = 'Gravity Z'
        elif cl.startswith('gyroscope') and 'yaw' in cl:
            col_map[c] = 'Gyroscope Yaw'
        elif cl.startswith('gyroscope') and 'pitch' in cl:
            col_map[c] = 'Gyroscope Pitch'
        elif cl.startswith('gyroscope') and 'roll' in cl:
            col_map[c] = 'Gyroscope Roll'
        elif cl.startswith('orientation') and 'yaw' in cl:
            col_map[c] = 'Orientation Yaw'
        elif cl.startswith('orientation') and 'pitch' in cl:
            col_map[c] = 'Orientation Pitch'
        elif cl.startswith('orientation') and 'roll' in cl:
            col_map[c] = 'Orientation Roll'
    return df.rename(columns=col_map)


def fix_monotonic_time(df, trip_id):
    """Detect non-monotonic timestamps. Segment at jumps, keep longest segment."""
    time_ms = df['Time_ms'].values.astype(float)
    diffs = np.diff(time_ms)
    jump_indices = np.where(diffs < 0)[0]  # backward jumps

    if len(jump_indices) == 0:
        # Already monotonic — just zero it
        df = df.copy()
        df['Time_ms'] = time_ms - time_ms[0]
        return df

    # Segment at each backward jump
    boundaries = [0] + list(jump_indices + 1) + [len(time_ms)]
    segments = []
    for i in range(len(boundaries) - 1):
        start, end = boundaries[i], boundaries[i + 1]
        segments.append((start, end, end - start))

    # Keep the longest segment
    longest = max(segments, key=lambda s: s[2])
    start, end, length = longest
    discarded = len(time_ms) - length
    print(f"    {trip_id}: {len(jump_indices)} backward jump(s). "
          f"Keeping rows {start}-{end} ({length} rows), discarding {discarded} rows.")

    df_seg = df.iloc[start:end].copy().reset_index(drop=True)
    t = df_seg['Time_ms'].values.astype(float)
    df_seg['Time_ms'] = t - t[0]
    return df_seg


def load_s_file(filepath, trip_id):
    """Load and clean an S-file CSV."""
    df = pd.read_csv(filepath, encoding='latin-1')
    is_kmh = False
    df.columns = [c.strip() for c in df.columns]
    df = map_s_columns(df)
    
    # Auto-detect if GPS Speed is actually in km/h (max value > 60 implies km/h since 60m/s = 216 km/h which is implausible)
    if 'GPS Speed' in df.columns:
        gps_max = np.nanmax(df['GPS Speed'].values)
        if gps_max > 60.0:
            print(f"    {trip_id}: Auto-detected GPS Speed in km/h (max {gps_max:.1f}). Converting to m/s.")
            df['GPS Speed'] = df['GPS Speed'] / 3.6
    missing = []
    for col in ['Time_ms', 'GPS Speed'] + SENSOR_COLS:
        if col not in df.columns:
            missing.append(col)
    if missing:
        for col in missing:
            if col in SENSOR_COLS:
                print(f"    {trip_id}: Missing sensor column '{col}', padding with 0.")
                df[col] = 0.0
            else:
                raise ValueError(f"{trip_id}: Missing required column '{col}'")
    df = fix_monotonic_time(df, trip_id)
    return df


def load_v_file(filepath, trip_id):
    """Load and clean a V-file CSV."""
    df = pd.read_csv(filepath, encoding='latin-1')
    df.columns = [c.strip() for c in df.columns]

    # Find the vehicle velocity column (must be exactly 'Velocity (km/hr)')
    vel_col = None
    for c in df.columns:
        cl = c.lower().strip()
        if cl in ['velocity (km/hr)', 'velocity(km/h)', 'velocity (km/h)']:
            vel_col = c
            break
    if vel_col is None:
        raise ValueError(f"{trip_id}: Could not find CAN velocity column. "
                         f"Columns: {list(df.columns)}")

    # Find time column
    time_col = None
    for c in df.columns:
        if 'time since start' in c.lower():
            time_col = c
            break
    if time_col is None:
        raise ValueError(f"{trip_id}: Could not find time column in V-file")

    result = pd.DataFrame()
    result['Time_s'] = pd.to_numeric(df[time_col], errors='coerce')
    result['Velocity_kmh'] = pd.to_numeric(df[vel_col], errors='coerce')

    # Zero the time
    result['Time_s'] = result['Time_s'] - result['Time_s'].iloc[0]

    return result


def gravity_compensate(df):
    """Subtract gravity vector from raw accelerometer to get linear acceleration."""
    df = df.copy()
    df['Linear Accel X'] = df['Accelerometer X'] - df['Gravity X']
    df['Linear Accel Y'] = df['Accelerometer Y'] - df['Gravity Y']
    df['Linear Accel Z'] = df['Accelerometer Z'] - df['Gravity Z']
    return df


def synchronize(s_df, v_df, has_can_velocity, trip_id):
    """
    Resample to common 10Hz grid. Zero both timelines independently.
    Use interp1d with fill_value=NaN (NO extrapolation). Drop NaN rows.
    """
    s_time_s = s_df['Time_ms'].values / 1000.0  # Already zeroed in load_s_file

    # Build 10Hz grid over S-file range
    start_t = np.ceil(s_time_s[0] * 10) / 10
    end_t = np.floor(s_time_s[-1] * 10) / 10
    target_time = np.arange(start_t, end_t, 0.1)

    # Interpolate sensor channels
    # Use Linear Accel (gravity-compensated) instead of raw Accelerometer
    interp_cols = [
        'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
        'Gravity X', 'Gravity Y', 'Gravity Z',
        'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
        'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
    ]

    resampled = {'Time_s': target_time}
    for col in interp_cols:
        f_interp = interp1d(s_time_s, s_df[col].values, kind='linear',
                            bounds_error=False, fill_value=np.nan)
        resampled[col] = f_interp(target_time)

    # Interpolate GPS speed (already in m/s)
    gps_speed_ms = s_df['GPS Speed'].values
    
    f_gps = interp1d(s_time_s, gps_speed_ms, kind='linear',
                     bounds_error=False, fill_value=np.nan)
    resampled['GPS_Speed_ms'] = f_gps(target_time)

    # Velocity label
    if has_can_velocity and v_df is not None:
        v_time_s = v_df['Time_s'].values  # Already zeroed in load_v_file
        v_vel_ms = v_df['Velocity_kmh'].values / 3.6  # CAN is genuinely km/h -> m/s

        f_vel = interp1d(v_time_s, v_vel_ms, kind='linear',
                         bounds_error=False, fill_value=np.nan)  # NO extrapolation
        resampled['Velocity_ms'] = f_vel(target_time)
        
        # Add permanent regression assertion to catch corrupted GPS speed units
        gps_kmh_equiv = resampled['GPS_Speed_ms'] * 3.6
        can_kmh_equiv = resampled['Velocity_ms'] * 3.6
        # Only compare where both are valid and speed is > 10 km/h (to avoid division by zero or extreme ratios at near-zero speeds)
        valid_idx = (can_kmh_equiv > 10.0) & ~np.isnan(gps_kmh_equiv) & ~np.isnan(can_kmh_equiv)
        if np.any(valid_idx):
            mean_gps = np.mean(gps_kmh_equiv[valid_idx])
            mean_can = np.mean(can_kmh_equiv[valid_idx])
            ratio = mean_gps / mean_can
            mean_error = np.abs(ratio - 1.0)
            if mean_error > 0.20:  # Allow 20% margin for GPS vs CAN inaccuracies
                print(f"WARNING {trip_id}: GPS Speed vs CAN Velocity mismatch! Mean ratio error: {mean_error*100:.1f}%. "
                      f"Check if GPS Speed is corrupted (e.g., divided by 3.6 incorrectly).")
                assert mean_error <= 0.20, f"{trip_id}: GPS Speed appears corrupted. Mean ratio error vs CAN is {mean_error*100:.1f}%."
    else:
        # Test trips: use GPS speed as ground truth (already m/s)
        resampled['Velocity_ms'] = resampled['GPS_Speed_ms'].copy()

    result = pd.DataFrame(resampled)

    # Drop rows where interpolation produced NaN (edges or misalignment)
    n_before = len(result)
    result = result.dropna().reset_index(drop=True)
    n_dropped = n_before - len(result)
    if n_dropped > 0:
        print(f"    {trip_id}: Dropped {n_dropped} NaN rows "
              f"({n_dropped / n_before * 100:.1f}%) from interpolation edges")

    return result


def window_trip(df, trip_id, window_size=20, stride=10):
    """Slice into windows of 20 samples (2.0s at 10Hz) with 50% overlap (stride=10).
    Also capture the start timestamp (in ms) of each window for later alignment.
    If Time_ms column is not available, timestamps will be set to -1.
    """
    feature_cols = [
        'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
        'Gravity X', 'Gravity Y', 'Gravity Z',
        'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
        'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
    ]

    data = df[feature_cols].values
    velocities = df['Velocity_ms'].values
    # Try to get timestamps; if column doesn't exist, use -1 as default
    if 'Time_ms' in df.columns:
        timestamps = df['Time_ms'].values  # already zeroed
    else:
        timestamps = np.full(len(df), -1, dtype=float)

    X, y, ids, ts = [], [], [], []
    for i in range(0, len(data) - window_size + 1, stride):
        window_x = data[i:i + window_size]
        window_y = np.mean(velocities[i:i + window_size])  # Mean velocity over window
        window_ts = timestamps[i]  # start time of window
        # Sanity: skip windows with any remaining NaN
        if np.isnan(window_x).any() or np.isnan(window_y):
            continue

        X.append(window_x)
        y.append(window_y)
        ids.append(trip_id)
        ts.append(window_ts)

    return np.array(X), np.array(y), np.array(ids), np.array(ts)


def process_all():
    splits = {s: {'X': [], 'y': [], 'trip_id': [], 'timestamps': []} for s in ['train', 'val', 'test']}

    print("=" * 70)
    print("PREPROCESSING PIPELINE (CORRECTED)")
    print("=" * 70)

    for trip_id, info in manifest['trips'].items():
        if info['split'] == 'stationary':
            continue

        split = info['split']
        print(f"\n  Processing {trip_id} (split={split})...")

        # Load S-file
        s_path = DATASET_ROOT / info['s_file']
        s_df = load_s_file(s_path, trip_id)

        # Sanity: GPS speed (in m/s) should be 0-60 m/s (~216 km/h)
        gps_speed = s_df['GPS Speed'].values
        gps_max_ms = np.nanmax(gps_speed)
        assert gps_max_ms < 60, (f"{trip_id}: GPS speed max = {gps_max_ms:.2f} m/s "
                                  f"= {gps_max_ms * 3.6:.1f} km/h — implausible!")
        print(f"    GPS speed (m/s): max={gps_max_ms:.2f} ({gps_max_ms * 3.6:.1f} km/h)")

        # Load V-file if available
        v_df = None
        if info['has_can_velocity'] and info.get('v_file'):
            v_path = DATASET_ROOT / info['v_file']
            v_df = load_v_file(v_path, trip_id)
            can_max = v_df['Velocity_kmh'].max()
            assert can_max < 250, (f"{trip_id}: CAN velocity max = {can_max:.2f} km/h — implausible!")
            print(f"    CAN velocity (km/h): max={can_max:.2f}")

            # Cross-check: GPS*3.6 should approximate CAN
            ratio = (gps_max_ms * 3.6) / can_max if can_max > 0 else 0
            print(f"    GPS*3.6/CAN ratio: {ratio:.3f} (expect ~0.9-1.1)")

        # Gravity compensate
        s_df = gravity_compensate(s_df)

        # Synchronize to 10Hz
        sync_df = synchronize(s_df, v_df, info['has_can_velocity'], trip_id)

        # Assert velocity labels are sane AFTER synchronization
        vel = sync_df['Velocity_ms'].values
        assert vel.max() < 60, (f"{trip_id}: Post-sync velocity max = {vel.max():.2f} m/s "
                                 f"= {vel.max() * 3.6:.1f} km/h — still corrupted!")
        assert vel.min() >= 0, f"{trip_id}: Negative velocity = {vel.min():.2f}"
        print(f"    Synced velocity (m/s): min={vel.min():.2f}, max={vel.max():.2f}, "
              f"mean={vel.mean():.2f} ({vel.mean() * 3.6:.1f} km/h)")

        # Window
        X, y, ids, ts = window_trip(sync_df, trip_id)
        print(f"    Windows: {len(X)} (shape {X.shape[1:]})")

        splits[split]['X'].append(X)
        splits[split]['y'].append(y)
        splits[split]['trip_id'].append(ids)
        splits[split]['timestamps'].append(ts)

    # Concatenate
    print("\n" + "=" * 70)
    print("CONCATENATION AND NORMALIZATION")
    print("=" * 70)

    for split in ['train', 'val', 'test']:
        if splits[split]['X']:
            splits[split]['X'] = np.concatenate(splits[split]['X'])
            splits[split]['y'] = np.concatenate(splits[split]['y'])
            splits[split]['trip_id'] = np.concatenate(splits[split]['trip_id'])
            splits[split]['timestamps'] = np.concatenate(splits[split]['timestamps'])


    # Final assertions
    for split in ['train', 'val', 'test']:
        X = splits[split]['X']
        y = splits[split]['y']
        print(f"\n  {split}: X={X.shape}, y={y.shape}")
        print(f"    y (m/s): min={y.min():.2f}, max={y.max():.2f}, mean={y.mean():.2f}")
        print(f"    y (km/h): min={y.min()*3.6:.1f}, max={y.max()*3.6:.1f}, mean={y.mean()*3.6:.1f}")
        assert y.max() < 60, f"{split}: y.max() = {y.max():.2f} m/s — FAILED"
        assert y.min() >= 0, f"{split}: y.min() = {y.min():.2f} — FAILED"
        assert not np.isnan(X).any(), f"{split}: NaN in X"
        assert not np.isnan(y).any(), f"{split}: NaN in y"
        assert X.shape[2] == 12, f"{split}: X channels = {X.shape[2]}, expected 12"
        print(f"    All assertions PASSED")

    # Normalization (fit on train only)
    X_train = splits['train']['X']
    channel_means = np.mean(X_train, axis=(0, 1))  # shape (12,)
    channel_stds = np.std(X_train, axis=(0, 1))
    channel_stds[channel_stds == 0] = 1.0

    norm_params = {
        'means': channel_means.tolist(),
        'stds': channel_stds.tolist(),
        'channels': [
            'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
            'Gravity X', 'Gravity Y', 'Gravity Z',
            'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
            'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
        ]
    }

    print("\n  Normalization parameters:")
    for i, (ch, m, s) in enumerate(zip(norm_params['channels'],
                                        norm_params['means'],
                                        norm_params['stds'])):
        print(f"    [{i:2d}] {ch:25s}: mean={m:10.4f}, std={s:10.4f}")

    with open(PROCESSED_DIR / "norm_params.json", "w") as f:
        json.dump(norm_params, f, indent=2)

    # Apply normalization and save
    for split in ['train', 'val', 'test']:
        X_norm = (splits[split]['X'] - channel_means) / channel_stds
        np.savez_compressed(
            PROCESSED_DIR / f"{split}.npz",
            X=X_norm.astype(np.float32),
            y=splits[split]['y'].astype(np.float32),
            trip_id=splits[split]['trip_id'],
            timestamps=splits[split]['timestamps'].astype(np.float32)
        )
        print(f"\n  Saved {split}.npz: X={X_norm.shape}, y={splits[split]['y'].shape}")

    print("\n" + "=" * 70)
    print("PREPROCESSING COMPLETE — ALL ASSERTIONS PASSED")
    print("=" * 70)


if __name__ == "__main__":
    process_all()
