"""
Data Sanity Check Script — Phase 0
Validates all assumptions from the spec before any model code runs.
Generates plots saved to results/figures/ and prints diagnostics to stdout.
"""

import pandas as pd
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import json
import os
import sys
from pathlib import Path

# ============================================================
# Configuration
# ============================================================
PROJECT_ROOT = Path(r"D:\Nandhu\dead reckoning\idr-project")
DATASET_ROOT = Path(r"D:\Nandhu\dead reckoning\IO-VNBD-master")
FIGURES_DIR = PROJECT_ROOT / "results" / "figures"
FIGURES_DIR.mkdir(parents=True, exist_ok=True)

with open(PROJECT_ROOT / "data" / "manifest.json", "r") as f:
    manifest = json.load(f)

# Column name mapping: spec names -> actual CSV header names
# The CSV headers have formatting quirks (degree symbols, extra spaces, parentheses)
S_COLUMN_MAP = {
    'GPS_LAT': 'GPS LATITUDE (degrees)',
    'GPS_LON': 'GPS LONGITUDE (degrees)',
    'GPS_ALT': 'GPS ALTITUDE (m)',
    'GPS_SPEED': 'GPS SPEED (Kmh)',
    'GPS_ACCURACY': 'GPS ACCURACY (m)',
    'GPS_ORIENTATION': None,  # will detect
    'GPS_SATELLITES': 'GPS SATELLITES IN RANGE',
    'TIME_MS': 'TIME SINCE START (ms)',
    'DATE': None,  # will detect
    'ACCEL_X': None,
    'ACCEL_Y': None,
    'ACCEL_Z': None,
    'GRAVITY_X': None,
    'GRAVITY_Y': None,
    'GRAVITY_Z': None,
    'GYRO_YAW': None,
    'GYRO_PITCH': None,
    'GYRO_ROLL': None,
    'MAG_X': None,
    'MAG_Y': None,
    'MAG_Z': None,
    'ORIENT_YAW': None,
    'ORIENT_PITCH': None,
    'ORIENT_ROLL': None,
}

V_COLUMN_MAP = {
    'TIME_S': 'Time Since Start of Day (seconds)',
    'LAT': 'Latitude (degrees)',
    'LON': 'Longitude (degrees)',
    'VELOCITY_KMH': 'Velocity (km/hr)',
    'HEADING': 'Heading (degrees)',
}


def load_s_csv(filepath):
    """Load smartphone CSV with robust column name handling."""
    df = pd.read_csv(filepath, encoding='latin-1')
    # Strip whitespace from column names
    df.columns = [c.strip() for c in df.columns]

    # Print actual columns for diagnostic
    print(f"  S-file columns ({len(df.columns)}): {list(df.columns)[:5]}...")

    # Build a normalized column name mapping
    col_lower = {c.lower().replace(' ', '').replace('(', '').replace(')', ''): c for c in df.columns}
    # Map to standardized names based on actual CSV header patterns
    rename = {}
    for col in df.columns:
        cl = col.lower().strip()
        # GPS columns
        if cl.startswith('gps latitude'):
            rename[col] = 'GPS Latitude'
        elif cl.startswith('gps longitude'):
            rename[col] = 'GPS Longitude'
        elif cl.startswith('gps altitude'):
            rename[col] = 'GPS Altitude'
        elif cl.startswith('gps speed'):
            rename[col] = 'GPS Speed'
        elif cl.startswith('gps accuracy'):
            rename[col] = 'GPS Accuracy'
        elif cl.startswith('gps orientation'):
            rename[col] = 'GPS Orientation'
        elif cl.startswith('gps satellite'):
            rename[col] = 'GPS Satellites'
        elif cl.startswith('time since start'):
            rename[col] = 'Time_ms'
        elif cl.startswith('date'):
            rename[col] = 'Date'
        # Accelerometer — must come before gravity since both have X/Y/Z
        elif cl.startswith('accelerometer x'):
            rename[col] = 'Accelerometer X'
        elif cl.startswith('accelerometer y'):
            rename[col] = 'Accelerometer Y'
        elif cl.startswith('accelerometer z'):
            rename[col] = 'Accelerometer Z'
        # Gravity
        elif cl.startswith('gravity x'):
            rename[col] = 'Gravity X'
        elif cl.startswith('gravity y'):
            rename[col] = 'Gravity Y'
        elif cl.startswith('gravity z'):
            rename[col] = 'Gravity Z'
        # Gyroscope
        elif cl.startswith('gyroscope') and 'yaw' in cl:
            rename[col] = 'Gyroscope Yaw'
        elif cl.startswith('gyroscope') and 'pitch' in cl:
            rename[col] = 'Gyroscope Pitch'
        elif cl.startswith('gyroscope') and 'roll' in cl:
            rename[col] = 'Gyroscope Roll'
        # Magnetic Field
        elif cl.startswith('magnetic field x') or cl.startswith('magnetic') and ' x' in cl:
            rename[col] = 'Magnetic Field X'
        elif cl.startswith('magnetic field y') or cl.startswith('magnetic') and ' y' in cl:
            rename[col] = 'Magnetic Field Y'
        elif cl.startswith('magnetic field z') or cl.startswith('magnetic') and ' z' in cl:
            rename[col] = 'Magnetic Field Z'
        # Orientation
        elif cl.startswith('orientation') and 'yaw' in cl:
            rename[col] = 'Orientation Yaw'
        elif cl.startswith('orientation') and 'pitch' in cl:
            rename[col] = 'Orientation Pitch'
        elif cl.startswith('orientation') and 'roll' in cl:
            rename[col] = 'Orientation Roll'

    df = df.rename(columns=rename)
    return df


def load_v_csv(filepath):
    """Load vehicle CAN-bus CSV."""
    df = pd.read_csv(filepath, encoding='latin-1')
    df.columns = [c.strip() for c in df.columns]
    print(f"  V-file columns ({len(df.columns)}): {list(df.columns)[:5]}...")

    rename = {}
    for col in df.columns:
        cl = col.lower()
        if 'velocity' in cl and 'km' in cl:
            rename[col] = 'Velocity_kmh'
        elif 'latitude' in cl:
            rename[col] = 'Latitude'
        elif 'longitude' in cl:
            rename[col] = 'Longitude'
        elif 'heading' in cl:
            rename[col] = 'Heading'
        elif 'time since start' in cl:
            rename[col] = 'Time_s'

    df = df.rename(columns=rename)
    return df


def check_1_gps_trajectories():
    """Check 1: Plot GPS lat/lon for each selected trip."""
    print("\n" + "="*60)
    print("CHECK 1: GPS Trajectory Plots")
    print("="*60)

    trips_to_plot = {k: v for k, v in manifest['trips'].items()
                     if v['split'] in ('train', 'val', 'test')}

    fig, axes = plt.subplots(2, 4, figsize=(24, 12))
    axes = axes.flatten()

    for idx, (trip_id, trip_info) in enumerate(trips_to_plot.items()):
        if idx >= 8:
            break
        s_path = DATASET_ROOT / trip_info['s_file']
        print(f"\n  Loading {trip_id}: {s_path.name} ({s_path.stat().st_size / 1e6:.1f} MB)")
        df = load_s_csv(str(s_path))

        lat = df['GPS Latitude'].values
        lon = df['GPS Longitude'].values
        n_samples = len(df)
        duration_s = (df['Time_ms'].iloc[-1] - df['Time_ms'].iloc[0]) / 1000.0

        print(f"    Samples: {n_samples}, Duration: {duration_s:.0f}s ({duration_s/60:.1f} min)")
        print(f"    Lat range: [{lat.min():.6f}, {lat.max():.6f}]")
        print(f"    Lon range: [{lon.min():.6f}, {lon.max():.6f}]")

        # Check for degenerate GPS (all same point)
        lat_range = lat.max() - lat.min()
        lon_range = lon.max() - lon.min()
        if lat_range < 0.0001 and lon_range < 0.0001:
            print(f"    WARNING: GPS appears stationary/degenerate (range < 0.0001 deg)")

        ax = axes[idx]
        ax.plot(lon, lat, linewidth=0.5, alpha=0.8)
        ax.plot(lon[0], lat[0], 'go', markersize=8, label='Start')
        ax.plot(lon[-1], lat[-1], 'r^', markersize=8, label='End')
        ax.set_title(f'{trip_id} (Driver {trip_info["driver"]}, {trip_info["split"]})\n'
                     f'{n_samples} pts, {duration_s/60:.1f} min', fontsize=10)
        ax.set_xlabel('Longitude')
        ax.set_ylabel('Latitude')
        ax.legend(fontsize=8)
        ax.set_aspect('equal')

    # Hide unused axes
    for idx in range(len(trips_to_plot), 8):
        axes[idx].set_visible(False)

    plt.tight_layout()
    fig.savefig(FIGURES_DIR / "check1_gps_trajectories.png", dpi=150)
    plt.close(fig)
    print(f"\n  Saved: {FIGURES_DIR / 'check1_gps_trajectories.png'}")


def check_2_gravity_stationary():
    """Check 2: Gravity magnitude on stationary segments."""
    print("\n" + "="*60)
    print("CHECK 2: Gravity Magnitude on Stationary Segments")
    print("="*60)

    stationary_trips = {k: v for k, v in manifest['trips'].items() if v['split'] == 'stationary'}
    bias_results = {}

    for trip_id, trip_info in stationary_trips.items():
        s_path = DATASET_ROOT / trip_info['s_file']
        print(f"\n  Loading stationary trip {trip_id}: {s_path.name}")
        df = load_s_csv(str(s_path))

        n_samples = len(df)
        duration_s = (df['Time_ms'].iloc[-1] - df['Time_ms'].iloc[0]) / 1000.0
        print(f"    Samples: {n_samples}, Duration: {duration_s:.0f}s ({duration_s/60:.1f} min)")

        # Gravity magnitude
        gx = df['Gravity X'].values
        gy = df['Gravity Y'].values
        gz = df['Gravity Z'].values
        gravity_mag = np.sqrt(gx**2 + gy**2 + gz**2)
        mean_g = np.mean(gravity_mag)
        std_g = np.std(gravity_mag)
        print(f"    Gravity magnitude: mean={mean_g:.4f} m/s², std={std_g:.6f}")
        print(f"    PASS" if abs(mean_g - 9.81) < 0.3 else f"    FAIL: |{mean_g} - 9.81| > 0.3")

        # Accel bias/noise
        ax_vals = df['Accelerometer X'].values
        ay_vals = df['Accelerometer Y'].values
        az_vals = df['Accelerometer Z'].values
        print(f"    Accel bias (mean): X={np.mean(ax_vals):.6f}, Y={np.mean(ay_vals):.6f}, Z={np.mean(az_vals):.6f}")
        print(f"    Accel noise (std):  X={np.std(ax_vals):.6f}, Y={np.std(ay_vals):.6f}, Z={np.std(az_vals):.6f}")

        # Gyro bias/noise
        gyaw = df['Gyroscope Yaw'].values
        gpitch = df['Gyroscope Pitch'].values
        groll = df['Gyroscope Roll'].values
        print(f"    Gyro bias (mean): Yaw={np.mean(gyaw):.6f}, Pitch={np.mean(gpitch):.6f}, Roll={np.mean(groll):.6f}")
        print(f"    Gyro noise (std):  Yaw={np.std(gyaw):.6f}, Pitch={np.std(gpitch):.6f}, Roll={np.std(groll):.6f}")

        # Also check V-file velocity to confirm stationary
        v_path = DATASET_ROOT / trip_info['v_file']
        v_df = load_v_csv(str(v_path))
        v_vel = v_df['Velocity_kmh'].values
        print(f"    CAN-bus velocity: mean={np.mean(v_vel):.3f} km/h, max={np.max(v_vel):.3f} km/h")
        if np.mean(v_vel) > 1.0:
            print(f"    WARNING: Vehicle not truly stationary! Mean velocity > 1 km/h")

        bias_results[trip_id] = {
            'gravity_magnitude_mean': float(mean_g),
            'gravity_magnitude_std': float(std_g),
            'accel_bias_x': float(np.mean(ax_vals)),
            'accel_bias_y': float(np.mean(ay_vals)),
            'accel_bias_z': float(np.mean(az_vals)),
            'accel_noise_x': float(np.std(ax_vals)),
            'accel_noise_y': float(np.std(ay_vals)),
            'accel_noise_z': float(np.std(az_vals)),
            'gyro_bias_yaw': float(np.mean(gyaw)),
            'gyro_bias_pitch': float(np.mean(gpitch)),
            'gyro_bias_roll': float(np.mean(groll)),
            'gyro_noise_yaw': float(np.std(gyaw)),
            'gyro_noise_pitch': float(np.std(gpitch)),
            'gyro_noise_roll': float(np.std(groll)),
            'duration_s': float(duration_s),
            'n_samples': int(n_samples),
        }

    # Save bias estimates for later use
    with open(PROJECT_ROOT / "data" / "stationary_bias_estimates.json", "w") as f:
        json.dump(bias_results, f, indent=2)
    print(f"\n  Saved bias estimates to: data/stationary_bias_estimates.json")

    return bias_results


def check_3_sample_rate():
    """Check 3: Validate 10Hz sample rate, flag gaps > 500ms."""
    print("\n" + "="*60)
    print("CHECK 3: Sample Rate Validation")
    print("="*60)

    all_trips = {k: v for k, v in manifest['trips'].items()
                 if v['split'] in ('train', 'val')}

    fig, axes = plt.subplots(2, 3, figsize=(18, 10))
    axes = axes.flatten()

    for idx, (trip_id, trip_info) in enumerate(all_trips.items()):
        if idx >= 6:
            break
        s_path = DATASET_ROOT / trip_info['s_file']
        df = load_s_csv(str(s_path))

        time_ms = df['Time_ms'].values
        deltas = np.diff(time_ms)

        mean_dt = np.mean(deltas)
        median_dt = np.median(deltas)
        std_dt = np.std(deltas)
        gaps_500 = np.sum(deltas > 500)
        max_gap = np.max(deltas)

        print(f"\n  {trip_id}: mean_dt={mean_dt:.1f}ms, median={median_dt:.1f}ms, "
              f"std={std_dt:.1f}ms, max_gap={max_gap:.0f}ms, gaps>500ms={gaps_500}")

        if abs(mean_dt - 100) > 20:
            print(f"    WARNING: Mean sample interval deviates significantly from 100ms")
        if gaps_500 > 0:
            gap_indices = np.where(deltas > 500)[0]
            gap_times = time_ms[gap_indices] / 1000.0
            print(f"    Gaps >500ms at t={gap_times[:5]} seconds (showing first 5)")

        ax = axes[idx]
        ax.hist(deltas, bins=100, range=(0, min(500, max_gap)), alpha=0.7, color='steelblue')
        ax.axvline(100, color='red', linestyle='--', label='Target 100ms')
        ax.set_title(f'{trip_id}: dt histogram\n'
                     f'mean={mean_dt:.0f}ms, gaps>500ms={gaps_500}', fontsize=10)
        ax.set_xlabel('Time delta (ms)')
        ax.set_ylabel('Count')
        ax.legend()

    for idx in range(len(all_trips), 6):
        axes[idx].set_visible(False)

    plt.tight_layout()
    fig.savefig(FIGURES_DIR / "check3_sample_rate.png", dpi=150)
    plt.close(fig)
    print(f"\n  Saved: {FIGURES_DIR / 'check3_sample_rate.png'}")


def check_4_velocity_crosscheck():
    """Check 4: Cross-check V-file CAN velocity vs S-file GPS speed."""
    print("\n" + "="*60)
    print("CHECK 4: CAN-Bus Velocity vs GPS Speed Cross-Check")
    print("="*60)

    # Use S2 (Driver A) as the cross-check trip
    trip_id = 'S2'
    trip_info = manifest['trips'][trip_id]

    s_path = DATASET_ROOT / trip_info['s_file']
    v_path = DATASET_ROOT / trip_info['v_file']

    print(f"\n  Loading {trip_id} S-file...")
    s_df = load_s_csv(str(s_path))
    print(f"  Loading {trip_id} V-file...")
    v_df = load_v_csv(str(v_path))

    # Create time axes
    s_time_s = s_df['Time_ms'].values / 1000.0
    gps_speed = s_df['GPS Speed'].values

    # V-file time: "Time Since Start of Day (seconds)" -> relative time
    v_time_raw = v_df['Time_s'].values
    v_time_s = v_time_raw - v_time_raw[0]
    can_vel = v_df['Velocity_kmh'].values

    # Trim to matching duration
    max_time = min(s_time_s[-1], v_time_s[-1])

    fig, ax = plt.subplots(figsize=(16, 5))
    ax.plot(s_time_s[s_time_s <= max_time],
            gps_speed[s_time_s <= max_time],
            alpha=0.6, linewidth=0.8, label='S-file GPS Speed (km/h)')
    ax.plot(v_time_s[v_time_s <= max_time],
            can_vel[v_time_s <= max_time],
            alpha=0.6, linewidth=0.8, label='V-file CAN Velocity (km/h)')
    ax.set_xlabel('Time (s)')
    ax.set_ylabel('Speed (km/h)')
    ax.set_title(f'Trip {trip_id}: CAN-Bus Velocity vs GPS Speed')
    ax.legend()
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    fig.savefig(FIGURES_DIR / "check4_velocity_crosscheck.png", dpi=150)
    plt.close(fig)
    print(f"\n  Saved: {FIGURES_DIR / 'check4_velocity_crosscheck.png'}")

    # Compute correlation on resampled data
    from scipy.interpolate import interp1d
    common_time = np.arange(0, min(max_time, s_time_s[-1]), 0.1)
    try:
        gps_interp = interp1d(s_time_s, gps_speed, kind='nearest', fill_value='extrapolate')(common_time)
        can_interp = interp1d(v_time_s, can_vel, kind='nearest', fill_value='extrapolate')(common_time)
        corr = np.corrcoef(gps_interp, can_interp)[0, 1]
        rmse = np.sqrt(np.mean((gps_interp - can_interp)**2))
        print(f"\n  Correlation: {corr:.4f}")
        print(f"  RMSE (GPS vs CAN): {rmse:.2f} km/h")
        print(f"  {'PASS' if corr > 0.9 else 'WARNING'}: correlation {'>' if corr > 0.9 else '<'} 0.9")
    except Exception as e:
        print(f"  Could not compute correlation: {e}")


if __name__ == "__main__":
    print("="*60)
    print("IDR-GNSS FUSION — DATA SANITY CHECKS")
    print("="*60)

    check_1_gps_trajectories()
    bias_results = check_2_gravity_stationary()
    check_3_sample_rate()
    check_4_velocity_crosscheck()

    print("\n" + "="*60)
    print("ALL SANITY CHECKS COMPLETE")
    print("="*60)
    print(f"\nFigures saved to: {FIGURES_DIR}")
    print(f"Bias estimates saved to: {PROJECT_ROOT / 'data' / 'stationary_bias_estimates.json'}")
