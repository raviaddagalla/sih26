"""
Robust per-window reference dataset for dead-reckoning evaluation and the
webapp replay.

The corrected preprocess.py .npz files carry normalized windows + velocity but
DROP the GPS lat/lon. This module re-runs the corrected synchronization for a
requested trip and produces a per-window aligned reference record:

    For window index i:
        raw window          : RAW (unnormalized) IMU window [Linear accel, gyro, ...]
        window_i_start_time : time at row i*stride in the synced 10 Hz grid
        ref_lat, ref_lon    : GPS lat/lon at the window start (last valid GPS)
        ref_velocity        : ground-truth velocity (m/s)
        ref_heading         : GPS course (deg) or estimated heading

This is more robust than the earlier linspace-based index matching in
export_sample_trip.py / drift_benchmark.py.
"""
import json
import sys
from pathlib import Path
import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
import preprocess
import common


def load_synced_trip(trip_id):
    """
    Re-run the corrected preprocessing for a single trip and return the
    10 Hz synchronized DataFrame WITH GPS lat/lon and heading carried through.
    """
    manifest = json.load(open(common.PROJECT_ROOT / "data" / "manifest.json"))
    info = manifest["trips"][trip_id]
    s_path = common.DATASET_ROOT / info["s_file"]
    s_df = preprocess.load_s_file(s_path, trip_id)

    # Also load GPS lat/lon/heading raw for interpolation
    lat_col = [c for c in s_df.columns
               if c.lower().startswith('gps latitude')][0]
    lon_col = [c for c in s_df.columns
               if c.lower().startswith('gps longitude')][0]

    # GPS course/heading column (GPS Orientation)
    head_col = None
    for c in s_df.columns:
        if c.lower().startswith('gps orientation') or \
           ('gps' in c.lower() and 'heading' in c.lower()):
            head_col = c
            break

    s_df = preprocess.gravity_compensate(s_df)

    v_df = None
    has_can = info["has_can_velocity"]
    if has_can and info.get("v_file"):
        v_path = common.DATASET_ROOT / info["v_file"]
        v_df = preprocess.load_v_file(v_path, trip_id)

    sync = preprocess.synchronize(s_df, v_df, has_can, trip_id)

    # ---- carry GPS lat/lon/heading through the same 10 Hz grid ----
    s_time_s = s_df["Time_ms"].values / 1000.0
    # align GPS onto the SAME retained grid times as the sync DataFrame
    target_time = sync["Time_s"].values

    from scipy.interpolate import interp1d

    def interp_grid(vals):
        f = interp1d(s_time_s, np.asarray(vals, dtype=float), kind="linear",
                     bounds_error=False, fill_value=np.nan)
        return f(target_time)

    sync["ref_lat"] = interp_grid(s_df[lat_col].values)
    sync["ref_lon"] = interp_grid(s_df[lon_col].values)

    if head_col is not None:
        sync["ref_heading"] = interp_grid(s_df[head_col].values)
    else:
        sync["ref_heading"] = np.nan

    # Force forward-fill of ref lat/lon to avoid NaN at interpolation edges,
    # then drop rows where the essential IMU/velocity are still NaN.
    sync["ref_lat"] = sync["ref_lat"].ffill()
    sync["ref_lon"] = sync["ref_lon"].ffill()
    sync["ref_heading"] = sync["ref_heading"].ffill()

    sync = sync.dropna(subset=["Velocity_ms"]).reset_index(drop=True)
    return sync


def build_trip_windows(sync_df, trip_id):
    """
    Slice the synced DataFrame into windows with aligned reference record.
    Mirrors the stride/window used by preprocess.window_trip.
    Returns dict of arrays (n_windows, ...).
    """
    W = common.WINDOW_LENGTH
    S = common.WINDOW_STRIDE

    # Column order matching preprocess.synchronize output (Linear Accel replaces
    # raw Accelerometer; Orientation channels kept but unused for Feature Set C).
    _SENSOR_COLS = [
        'Linear Accel X', 'Linear Accel Y', 'Linear Accel Z',
        'Gravity X', 'Gravity Y', 'Gravity Z',
        'Gyroscope Yaw', 'Gyroscope Pitch', 'Gyroscope Roll',
        'Orientation Yaw', 'Orientation Pitch', 'Orientation Roll'
    ]
    data = sync_df[_SENSOR_COLS].values  # raw 12-ch
    vel = sync_df["Velocity_ms"].values
    lat = sync_df["ref_lat"].values
    lon = sync_df["ref_lon"].values
    head = sync_df["ref_heading"].values
    t = sync_df["Time_s"].values

    out = {"raw": [], "vel": [], "lat": [], "lon": [], "heading": [],
           "time": [], "gyro_z": [], "trip": []}
    n = len(data)
    for i in range(0, n - W + 1, S):
        w = data[i:i + W]
        if np.isnan(w).any():
            continue
        out["raw"].append(w)
        out["vel"].append(vel[i:i + W].mean())
        out["lat"].append(lat[i])
        out["lon"].append(lon[i])
        out["heading"].append(head[i])
        out["time"].append(t[i])
        # gyro yaw at window center (index S -> t=1.0s)
        gyro_yaw_col = preprocess.SENSOR_COLS.index("Gyroscope Yaw")
        out["gyro_z"].append(w[S, gyro_yaw_col])
        out["trip"].append(trip_id)

    return {k: (np.array(v) if k != "trip" else np.array(v))
            for k, v in out.items()}


def build_dataset(trip_ids):
    """Build and cache per-window reference dataset for the given trips."""
    cache = {}
    for trip in trip_ids:
        sync = load_synced_trip(trip)
        cache[trip] = build_trip_windows(sync, trip)
        print(f"  {trip}: {len(cache[trip]['raw'])} windows")
    return cache


if __name__ == "__main__":
    trips = common.SPLIT_TRIPS["train"] + \
            common.SPLIT_TRIPS["val"] + common.SPLIT_TRIPS["test"]
    data = build_dataset(trips)
    import pickle
    cache_path = common.PROCESSED_DIR / "reference_cache.pkl"
    with open(cache_path, "wb") as f:
        pickle.dump(data, f)
    print(f"\nSaved reference cache to {cache_path}")
